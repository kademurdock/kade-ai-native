import Foundation
import AVFoundation

/* Part 98 (Aug 29 2026) — STREAMING PLAYBACK: PLAY BYTES AS THEY ARRIVE.
 *
 * WHY. The pump fetches a WHOLE WAV per sentence and only then plays it, so
 * ding→first-word carries a hard floor of one full synthesis — measured
 * 1.4–2.1s healthy on her voice, 3.5–5.6s in provider wobble (Part 97.3).
 * The proxy's new streamed lane (commit b6494b6) starts sending audio at
 * ~0.25–0.7s; this file is the app half that starts PLAYING it then, instead
 * of waiting for the last byte before the first word.
 *
 * WHAT THIS FILE DELIBERATELY IS NOT. It is not a second pump. The pump in
 * VoiceService keeps sole ownership of the queue, the cancel generation, the
 * prefetch depth, the opener's clear lane and the one-earcon rule — all the
 * freeze-hunt scar tissue (91.9/91.10/92.12/92.13/94/97.3) stays exactly
 * where it is. This class plays exactly ONE clip when the pump says so and
 * reports how that went. It cannot start itself, and nothing here touches
 * speakQueue.
 *
 * THE UNTESTABLE HALF, said plainly (same honesty as SpeechPipelineTests):
 * AVAudioEngine scheduling, session routing and pause/stop behaviour need a
 * device. The pure logic — header parse, torn-sample carry — lives in
 * StreamingWavParser.swift and runs in the Linux suite. Her ear on a real
 * phone gates this before any family build, per the standing rule.
 */

/// One streamed synthesis request: starts the HTTP call immediately (so a
/// prefetched piece is already downloading while an earlier piece plays) and
/// hands bytes out in arrival order. All consumption happens on the main
/// actor (the pump, then the player), one consumer at a time.
final class StreamingClipFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Serialises every touch of the mutable state below. The URLSession
    /// delegate callbacks land on a background queue; the main actor reads.
    private let lock = NSLock()
    private var pending = Data()
    private var finished = false
    private var httpOK: Bool?
    private var waiter: CheckedContinuation<Void, Never>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    /// Total audio bytes handed out — zero means "safe to fall back".
    private(set) var deliveredBytes = 0
    /// The HTTP status, once known, and any transport error text. Exists so a
    /// fallback can say WHY in a breadcrumb — the Aug-29 lesson: her report
    /// was "an error sound," and a sound cannot be debugged. A named status
    /// in the diagnostics trail can.
    private(set) var lastStatus: Int?
    private(set) var lastErrorText: String?
    var failureNote: String {
        if let s = lastStatus, !(200 ..< 300).contains(s) { return "HTTP \(s)" }
        if let e = lastErrorText { return e }
        if lastStatus == nil { return "no response" }
        return "empty stream"
    }

    /// The request is built asynchronously (voice resolution is a network
    /// call) but the fetch object exists synchronously so the pump's inflight
    /// bookkeeping never has to await creation — same shape as prefetch().
    init(requestProvider: @escaping @Sendable () async -> URLRequest?) {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        Task { [weak self] in
            guard let self else { return }
            guard let request = await requestProvider() else {
                self.finish(ok: false)
                return
            }
            self.lock.lock()
            let cancelled = self.finished
            if !cancelled {
                let t = session.dataTask(with: request)
                self.task = t
                self.lock.unlock()
                t.resume()
            } else {
                self.lock.unlock()
            }
        }
    }

    /// Next chunk of audio bytes, nil when the stream has ended. Waits when
    /// nothing has arrived yet. Single consumer, main actor.
    func next() async -> Data? {
        while true {
            lock.lock()
            if !pending.isEmpty {
                let out = pending
                pending = Data()
                deliveredBytes += out.count
                lock.unlock()
                return out
            }
            if finished {
                lock.unlock()
                return nil
            }
            lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if !pending.isEmpty || finished {
                    lock.unlock()
                    c.resume()
                } else {
                    waiter = c
                    lock.unlock()
                }
            }
        }
    }

    /// True once the response is known good and the first audio bytes exist;
    /// false when the fetch failed before delivering anything (the caller
    /// falls back to the buffered path — nothing has been heard yet).
    func waitForFirstAudio() async -> Bool {
        while true {
            lock.lock()
            if !pending.isEmpty { lock.unlock(); return true }
            if finished { let any = deliveredBytes > 0; lock.unlock(); return any }
            lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if !pending.isEmpty || finished {
                    lock.unlock()
                    c.resume()
                } else {
                    waiter = c
                    lock.unlock()
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        let t = task
        finish(ok: false, alreadyLocked: true)
        lock.unlock()
        t?.cancel()
    }

    private func finish(ok: Bool, alreadyLocked: Bool = false) {
        if !alreadyLocked { lock.lock() }
        finished = true
        if httpOK == nil { httpOK = ok }
        let w = waiter
        waiter = nil
        session?.finishTasksAndInvalidate()
        session = nil
        if !alreadyLocked { lock.unlock() }
        w?.resume()
    }

    // MARK: URLSessionDataDelegate (background queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? true
        lock.lock()
        httpOK = ok
        lastStatus = (response as? HTTPURLResponse)?.statusCode
        lock.unlock()
        completionHandler(ok ? .allow : .cancel)
        if !ok { finish(ok: false) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending.append(data)
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            lastErrorText = error.localizedDescription
            lock.unlock()
        }
        // An error after bytes were delivered means a SHORT clip, not a dead
        // one — the pump's piece just ends early, the same shape as the
        // proxy's own mid-stream death. Only a byte-less failure reads as
        // fallback-worthy, and waitForFirstAudio() derives that itself.
        finish(ok: error == nil)
    }
}

/// Plays one streamed clip through AVAudioEngine, scheduling PCM buffers as
/// chunks arrive. Owned by VoiceService; one clip at a time, always on the
/// main actor.
@MainActor
final class StreamingClipPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// AVAudioPlayerNode has no `rate`; the buffered path's
    /// AVAudioPlayer.enableRate time-stretches without pitch change, and
    /// AVAudioUnitTimePitch is the engine-graph equivalent of exactly that.
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedSampleRate: Double = 0
    private var graphBuilt = false
    private var activeFetch: StreamingClipFetch?
    private var playbackDone: CheckedContinuation<Void, Never>?
    private var stopped = false

    /// How much audio must be banked before playback starts. Starting on the
    /// very first chunk risks an immediate underrun stutter on a bursty
    /// connection; a third of a second still lands the first word ~4x sooner
    /// than the ~2s whole-clip floor. Underruns after start are quiet gaps
    /// (the node waits for the next buffer), which wobble minutes already
    /// taught everyone to survive — but smaller now, because playback began
    /// on the first bytes instead of after the last.
    private static let primerSeconds: Double = 0.30

    var isPlaying: Bool { node.isPlaying }

    func setRate(_ rate: Float) {
        timePitch.rate = max(0.25, min(4.0, rate))
    }

    /// Play one streamed clip to its end. Returns true when any audio
    /// actually played, false when the clip produced no sound (the pump
    /// counts that as a failed piece). A stop() mid-clip resumes the await
    /// and still returns true — something was heard.
    func play(fetch: StreamingClipFetch, rate: Float, onPlaybackStarted: @MainActor () -> Void) async -> Bool {
        stopped = false
        activeFetch = fetch
        defer { activeFetch = nil }

        // Header first: accumulate until parseable. The proxy's first flush
        // is the 44-byte header plus the opening PCM, so one chunk normally
        // does it; the loop covers a torn header anyway.
        var headerData = Data()
        var format: StreamingWavFormat?
        var pcmTail = Data()
        while format == nil {
            guard !stopped, let chunk = await fetch.next() else { return false }
            headerData.append(chunk)
            if let parsed = StreamingWavParser.parseHeader(headerData) {
                format = parsed.format
                pcmTail = headerData.subdata(in: headerData.startIndex + parsed.pcmStart ..< headerData.endIndex)
            } else if headerData.count > 64 * 1024 {
                // 64KB without a parseable header is not a WAV stream; bail
                // so the pump can count the piece honestly.
                KadeBreadcrumbs.drop("tts-stream: no parseable header in \(headerData.count) bytes")
                return false
            }
        }
        guard let fmt = format, fmt.bitsPerSample == 16, fmt.numChannels == 1 else {
            KadeBreadcrumbs.drop("tts-stream: unsupported format \(String(describing: format))")
            return false
        }

        guard let avFormat = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1) else {
            return false
        }
        rebuildGraphIfNeeded(sampleRate: fmt.sampleRate, avFormat: avFormat)
        setRate(rate)

        /* ⭐ THE BUG THAT MADE HER FIRST STREAMED REPLY BOOP (Aug 29 2026, her
         * report minutes after build 250: "the voice clip gave me an error
         * when I switched the toggle on"). THIS PATH NEVER SET THE AUDIO
         * SESSION. The buffered lane calls prepareOutputSession() inside
         * playAudio() and has since session 14 — `.playback` + `.mixWithOthers`,
         * which routes to the SPEAKER instead of the earpiece and keeps the
         * app from ducking VoiceOver. The streamed lane went straight to
         * engine.start().
         *
         * Why it bit immediately and not in any test: she had just been
         * TALKING to it. Recording leaves the session on `.playAndRecord`
         * (and a call leaves `.voiceChat` mode), and starting an engine
         * against that inherited session is exactly the session-14 scar one
         * layer down — the engine either refuses to start or plays into a
         * route nobody can hear. Same category of bug, same fix, and the
         * comment in prepareOutputSession() called it a month ago.
         *
         * Fail-soft on purpose, same as the buffered path: if the category
         * cannot be set, still try to play. Wrong-sounding beats silent. */
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            KadeBreadcrumbs.drop("tts-stream: engine start failed (\(error.localizedDescription))")
            return false
        }

        var accumulator = PcmSampleAccumulator()
        var bankedSeconds: Double = 0
        var started = false
        var scheduledAnything = false

        func schedule(_ samples: [Float]) {
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channel = buffer.floatChannelData?[0] {
                for i in 0 ..< samples.count { channel[i] = samples[i] }
            }
            outstandingBuffers += 1
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in self?.bufferPlayedBack() }
            }
            scheduledAnything = true
            bankedSeconds += Double(samples.count) / fmt.sampleRate
        }

        schedule(accumulator.append(pcmTail))

        // Feed until the stream ends, starting playback once the primer is
        // banked. The completion continuation parks AFTER feeding finishes,
        // so a fast network can outrun playback with no special case.
        while !stopped {
            if !started && (bankedSeconds >= Self.primerSeconds) {
                node.play()
                started = true
                onPlaybackStarted()
            }
            guard let chunk = await fetch.next() else { break }
            schedule(accumulator.append(chunk))
        }
        if stopped { return started || scheduledAnything }
        if !scheduledAnything {
            // Stream ended having produced a header and no audible PCM.
            return false
        }
        if !started {
            // Whole (short) clip arrived under the primer: play it now.
            node.play()
            started = true
            onPlaybackStarted()
        }

        // Everything is scheduled; wait for the LAST buffer to be heard.
        // bufferPlayedBack() resumes this when outstanding hits zero after
        // the feed loop set `draining`.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if outstandingBuffers == 0 || stopped {
                c.resume()
            } else {
                draining = true
                playbackDone = c
            }
        }
        return true
    }

    /// Pause is NOT stop: scheduled buffers stay queued, the engine keeps
    /// running, and resume() picks up exactly where the voice left off —
    /// the same contract the buffered path's pauseSpeaking() keeps.
    func pause() {
        guard node.isPlaying else { return }
        node.pause()
    }

    func resume() {
        node.play()
    }

    /// Stop the current clip and drop everything scheduled. Safe to call
    /// when idle. The parked play() continuation resumes so the pump can
    /// run its cancel check — never a stranded await (the playAudio lesson).
    func stop() {
        stopped = true
        activeFetch?.cancel()
        if graphBuilt { node.stop() }
        outstandingBuffers = 0
        draining = false
        if let c = playbackDone {
            playbackDone = nil
            c.resume()
        }
    }

    // MARK: - Buffer completion bookkeeping (main actor)

    private var outstandingBuffers = 0
    private var draining = false

    private func bufferPlayedBack() {
        if outstandingBuffers > 0 { outstandingBuffers -= 1 }
        if draining, outstandingBuffers == 0, let c = playbackDone {
            draining = false
            playbackDone = nil
            c.resume()
        }
    }

    private func rebuildGraphIfNeeded(sampleRate: Double, avFormat: AVAudioFormat) {
        if graphBuilt, connectedSampleRate == sampleRate { return }
        if graphBuilt {
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
        } else {
            engine.attach(node)
            engine.attach(timePitch)
        }
        engine.connect(node, to: timePitch, format: avFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: avFormat)
        connectedSampleRate = sampleRate
        graphBuilt = true
    }
}
