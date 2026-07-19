import Foundation
import AVFoundation

/// Real-time voice (and, once the caller enables Spotter, video) calling —
/// the native port of the fork's `useStreamingCall.ts` + `video-live.js`
/// bridge relay. Kade's ask (session 13, after the message-actions/VoiceOver
/// batch): "work on calling and spotters and shit too... I'd like to be
/// fully featured soon."
///
/// ARCHITECTURE (mirrors the web client's `useStreamingCall.ts` exactly —
/// same wire protocol, same server, just a different audio stack on this
/// end):
///   1. Fetch a short-lived ticket: `GET /api/kade/web-voice/ticket?agentId=`
///      via the existing `KadeAPIClient` (kademurdock.com, JWT-authorized).
///      Response: `{ticket, wsUrl}` — `wsUrl` points at kade-ai-bridge's
///      `/ws/web-voice`, NOT kademurdock.com, so the actual call socket
///      deliberately does NOT go through `KadeAPIClient` (same reasoning
///      already established for `PushService` -> the bridge is a different
///      host with its own lifecycle, not subject to the site's pacing gate).
///   2. Open a `URLSessionWebSocketTask` to that `wsUrl`, send
///      `{type:'hello', ticket, spotterDirect}`.
///   3. Mic: tapped continuously off `AVAudioEngine.inputNode` (never
///      pauses, even while the agent is "speaking" -- that's what makes
///      barge-in possible server-side, exactly like the web client's
///      comment: "talk over the agent and the server stops her mid-word").
///      Each tap buffer is converted (`AVAudioConverter`) from the
///      hardware's native format down to 16kHz mono Int16 and sent as a
///      RAW BINARY WebSocket frame -- no JSON envelope, no base64; the
///      server (`voice-stream.js`'s `/ws/web-voice` handler) forwards
///      binary frames straight to Deepgram.
///   4. Agent audio: binary frames come back as either a WAV clip (Inworld
///      TTS, starts with the ASCII bytes "RIFF") or, once Spotter/Live mode
///      is on, a raw 24kHz PCM16 chunk prefixed with the 4-byte magic
///      "LIVE" (`video-live.js`'s `LIVE_AUDIO_MAGIC`). Both get converted to
///      one fixed playback format and scheduled on a single
///      `AVAudioPlayerNode`. Unlike the web client (which hand-tracks a
///      `nextTime` playhead over Web Audio's `AudioBufferSourceNode`s to
///      keep clips gapless), `AVAudioPlayerNode.scheduleBuffer` already
///      queues buffers back-to-back with no gap once the node is playing --
///      genuinely simpler here than the workaround the browser needs.
///   5. JSON control messages (`ready`/`state`/`caption`/`clear`/`table`/
///      `error`/`live-notice`/`live-state`/`video-notice`/`video-state`)
///      drive `@Published` state the SwiftUI call screen renders/announces.
///
/// HONEST RISK NOTE (worth reading before touching this file again): this
/// is real-time duplex audio over a raw WebSocket, built with zero access to
/// a compiler AND zero access to a real device or simulator in this sandbox
/// -- unlike every other native-app change this project has shipped, this
/// one cannot be meaningfully hand-verified beyond "does the code read as
/// correct against Apple's documented AVAudioConverter/AVAudioEngine
/// contracts." Codemagic passing proves it COMPILES, nothing more. The
/// specific things most likely to need a real-device tuning pass (matching
/// `video-live.js`'s own "first activation is expected to need a tuning
/// session" honesty about the server side): whether the mic tap's actual
/// delivered buffer size behaves as expected across real hardware, and
/// general first-call latency feel. None of this can be confirmed until
/// someone is actually on a call.
///
/// CONFIRMED LIVE (first real call, build 116): the predicted echo risk
/// above was real -- the caller heard the agent fine and the agent
/// understood the caller fine, but the agent kept cutting herself off
/// mid-sentence, because she was hearing her OWN played-back voice loop
/// back through the mic and tripping the server's barge-in detection.
/// Root cause: `.voiceChat` AVAudioSession MODE alone (the original code
/// here) configures session-level hints but does NOT turn on real acoustic
/// echo cancellation for a custom `AVAudioEngine` graph -- that needs the
/// engine's Voice-Processing I/O unit explicitly enabled via
/// `inputNode.setVoiceProcessingEnabled(true)`, which `startAudioEngine()`
/// now does. Not yet re-confirmed live (this fix itself is unverified the
/// same "no device" way everything here is) -- if the cutting-herself-off
/// behavior is EVER reported again after this fix, this specific API is
/// the first thing to re-check, not the barge-in logic itself (the server
/// behaved completely correctly given what it was actually hearing).
@MainActor
final class StreamingCallService: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case ended(graceful: Bool)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var agentName: String = ""
    @Published private(set) var userCaption: String = ""
    @Published private(set) var agentCaption: String = ""
    @Published private(set) var liveOn: Bool = false
    @Published private(set) var liveNotice: String?
    @Published private(set) var spotterName: String?
    @Published private(set) var liveMinutesLeft: Int?
    @Published private(set) var errorMessage: String?

    /// True once `start()` has fully wired the engine/socket and the call
    /// screen should be showing live controls rather than a spinner.
    var isActive: Bool { webSocketTask != nil }

    private let apiClient: KadeAPIClient
    private let socketSession = URLSession(configuration: .default)
    private var webSocketTask: URLSessionWebSocketTask?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Every incoming clip (WAV or raw LIVE PCM) is converted to this one
    /// fixed format before scheduling, so `playerNode` only ever sees one
    /// consistent format regardless of what arrives. 24kHz mono Float32:
    /// matches the LIVE lane's native rate exactly (no resampling needed
    /// there) and is a clean, standard rate for the WAV clips to convert to.
    private let playerFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false
    )!
    /// What the server's Deepgram STT wants from us, per `voice-stream.js`.
    private let sendFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    private var engineRunning = false

    private var byeSent = false
    private var receiveLoopTask: Task<Void, Never>?

    /// Set right before a deliberate `stop()` so the receive-loop's own
    /// "socket closed" handling knows not to report it as a dropped call.
    private var stopping = false

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        super.init()
    }

    // MARK: - Lifecycle

    /// Fetches a ticket, opens the call socket, starts the mic. Throws with
    /// a user-presentable message on any failure; the caller (CallView)
    /// shows it and never leaves the screen in a half-started state --
    /// mirrors `useStreamingCall.ts`'s own `start()` contract exactly
    /// (ticket fetch fails -> throw; mic fails -> throw; socket fails ->
    /// throw), including tearing everything back down on any failure.
    func start(agentId: String?, spotterDirect: Bool) async throws {
        guard webSocketTask == nil else { return }
        status = .connecting
        errorMessage = nil
        byeSent = false
        stopping = false

        let (ticket, wsUrl) = try await fetchTicket(agentId: agentId)

        do {
            try startAudioEngine()
        } catch {
            status = .failed("Microphone access is blocked. Enable mic permission in Settings, then try the call again.")
            throw error
        }

        guard let url = URL(string: wsUrl) else {
            teardownAudio()
            status = .failed("Couldn't reach the call service.")
            throw URLError(.badURL)
        }

        let task = socketSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        sendJSON(["type": "hello", "ticket": ticket, "spotterDirect": spotterDirect])
        startReceiveLoop()
    }

    /// Graceful hangup (sends `bye` first, same as the web client) unless
    /// `graceful` is false (used internally when tearing down after an
    /// error, where the socket may already be gone).
    func stop(graceful: Bool = true) {
        stopping = true
        if graceful, let task = webSocketTask, !byeSent {
            byeSent = true
            sendJSON(["type": "bye"])
            task.cancel(with: .normalClosure, reason: nil)
        } else {
            webSocketTask?.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        teardownAudio()
        status = .ended(graceful: graceful)
    }

    /// Manual "stop talking" / barge-in button — same as the web client's
    /// Stop button: flush whatever's queued for playback locally AND tell
    /// the server to cut the agent off server-side.
    func barge() {
        flushPlayback()
        sendJSON(["type": "barge"])
    }

    /// Toggle Spotter/Live mode. `ack` must be true only on the SECOND call
    /// after the caller has heard/accepted the first-use cost notice
    /// (`live-notice`) — mirrors the server's own `handleLiveMsg` gate in
    /// `video-live.js`, which re-sends the notice every time until `ack`
    /// comes back true.
    func setLive(on: Bool, ack: Bool = false, direct: Bool = false) {
        sendJSON(["type": "live", "on": on, "ack": ack, "direct": direct])
    }

    /// Dismisses the first-use cost notice without accepting it (the
    /// caller tapped "Not now" or swiped the alert away) -- `liveNotice`
    /// is `private(set)` on purpose (only this service decides when a
    /// fresh notice arrives), so the view needs this rather than assigning
    /// nil directly.
    func clearLiveNotice() {
        liveNotice = nil
    }

    /// One camera frame while Spotter/Live (or the plain video-sight lane)
    /// is active. `jpegData` should already be resized/compressed by the
    /// caller (`CameraCaptureController`) -- this just base64-wraps and
    /// ships it, matching the server's `{type:'frame', data: <base64 jpeg>}`
    /// contract exactly (`video-sight.js`/`video-live.js` both read it).
    func sendFrame(jpegData: Data) {
        sendJSON(["type": "frame", "data": jpegData.base64EncodedString()])
    }

    // MARK: - Ticket

    private func fetchTicket(agentId: String?) async throws -> (ticket: String, wsUrl: String) {
        var query: [URLQueryItem] = []
        if let agentId { query.append(URLQueryItem(name: "agentId", value: agentId)) }
        let req = apiClient.request(
            path: "api/kade/web-voice/ticket", authorized: true,
            queryItems: query.isEmpty ? nil : query
        )
        let (data, http) = try await apiClient.send(req)
        guard http.statusCode == 200 else {
            throw CallError.message("Couldn't start the call (server said \(http.statusCode)).")
        }
        struct TicketResponse: Decodable { let ticket: String?; let wsUrl: String? }
        let decoded = try JSONDecoder().decode(TicketResponse.self, from: data)
        guard let ticket = decoded.ticket, let wsUrl = decoded.wsUrl else {
            throw CallError.message("Couldn't start the call (bad ticket response).")
        }
        return (ticket, wsUrl)
    }

    enum CallError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return "Call error."
        }
    }

    // MARK: - WebSocket send/receive

    private func sendJSON(_ obj: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in /* fail-soft: one dropped control message ≠ dead call */ }
    }

    private func startReceiveLoop() {
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while let task = await self.webSocketTask {
                do {
                    let message = try await task.receive()
                    await self.handle(message: message)
                } catch {
                    if await self.stopping { return }
                    await self.handleSocketClosed()
                    return
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleBinary(data)
        case .string(let text):
            handleControl(text)
        @unknown default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        // "LIVE" magic = 0x4C 0x49 0x56 0x45 -- matches `LIVE_AUDIO_MAGIC`
        // in video-live.js exactly. Anything else is a WAV clip (starts
        // "RIFF"); the web client checks the same 4 bytes the same way.
        if data.count > 4, data[0] == 0x4C, data[1] == 0x49, data[2] == 0x56, data[3] == 0x45 {
            enqueueLivePCM(data)
        } else {
            enqueueWav(data)
        }
    }

    private func handleControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(CallServerMessage.self, from: data) else { return }
        switch msg.type {
        case "ready":
            status = .listening
        case "state":
            switch msg.state {
            case "speaking": status = .speaking
            case "thinking": status = .thinking
            default: status = .listening
            }
        case "caption":
            if msg.role == "user" { userCaption = msg.text ?? "" } else { agentCaption = msg.text ?? "" }
        case "clear":
            flushPlayback()
        case "live-state":
            liveOn = msg.on ?? false
            if let name = msg.spotterName { spotterName = name }
            liveMinutesLeft = msg.minutesLeft
            if let m = msg.message { liveNotice = m }
        case "live-notice":
            liveNotice = msg.text
        case "video-notice", "video-state":
            break // native call screen doesn't build the snapshot video lane yet
        case "error":
            errorMessage = msg.message ?? "Call error."
        default:
            break // "table" (Game Parlor) and anything future: ignore quietly
        }
    }

    private func handleSocketClosed() {
        webSocketTask = nil
        teardownAudio()
        if case .failed = status { return }
        status = .ended(graceful: byeSent)
    }

    // MARK: - Audio engine (mic capture)

    private func startAudioEngine() throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .denied:
            throw CallError.message("Microphone access is off for Kade-AI.")
        case .undetermined, .granted:
            break
        @unknown default:
            break
        }
        // `.voiceChat` mode is Apple's documented mode for exactly this
        // shape of duplex call audio (continuous simultaneous record+
        // playback with the system doing its own echo/gain assistance) --
        // the closest native equivalent to `getUserMedia`'s
        // echoCancellation/noiseSuppression/autoGainControl flags the web
        // client requests explicitly.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)

        let input = audioEngine.inputNode
        // FIX (live-tested, first real call): the caller heard the agent
        // hearing HERSELF -- the agent's own played-back voice looping back
        // through the mic and tripping the server's barge-in detection,
        // cutting her off mid-sentence every time. The caller heard the
        // agent fine and the agent understood the caller fine, so this was
        // never the WebSocket/mic-send path -- it was acoustic echo, the
        // exact risk flagged (but not yet guarded against) in this file's
        // original top comment. `.voiceChat` MODE alone configures session-
        // level hints; it does NOT turn on real acoustic echo cancellation
        // for a custom AVAudioEngine graph like this one. The actual fix is
        // enabling the engine's Voice-Processing I/O unit directly on the
        // input node -- this cancels whatever the engine is CURRENTLY
        // playing (the agent's own clips, scheduled on `playerNode` into
        // this same engine's mixer) out of what the input node captures,
        // which is exactly the loop that was tripping the server's VAD.
        // Enabling it can change the node's own delivered format, so the
        // format is read AFTER enabling, not before -- reading it first
        // (the original bug) risked building the mic converter against a
        // format that was about to change out from under it.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Fail-soft: a handful of audio route configurations don't
            // support voice processing. The call still works without it --
            // just back to the original echo risk -- never worth failing
            // the whole call over.
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CallError.message("No microphone input available.")
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        // FIX (live-tested): the first echo fix (enabling voice processing
        // above) broke mic capture entirely on the very next call -- Kiana
        // greeted, then never responded, because the converter built here
        // from `inputFormat` (read right after `setVoiceProcessingEnabled`)
        // silently stopped matching the format actually delivered to the
        // tap once the engine was really running, so every conversion call
        // was failing quietly (`pcm16Data` returning nil) and NOTHING ever
        // reached the server -- Deepgram had nothing to transcribe, so
        // there was never a turn to reply to. Rather than guess at the
        // exact timing voice processing settles its format (unverifiable
        // without a device), `MicConverterBox` below is self-healing: it
        // rebuilds its converter from whatever format the REAL buffer
        // reports on each tap callback, so there is no "read the format at
        // the right moment" question left to get wrong. Rebuilding only
        // happens when the format actually changes (cheap after the first
        // call in the overwhelmingly common case).
        let box = MicConverterBox(outputFormat: sendFormat)
        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let pcmData = box.convert(buffer) else { return }
            Task { @MainActor in
                self?.sendMicData(pcmData)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()
        engineRunning = true
    }

    private func sendMicData(_ pcmData: Data) {
        guard let task = webSocketTask else { return }
        task.send(.data(pcmData)) { _ in /* fail-soft: one dropped mic chunk ≠ dead call */ }
    }

    /// Pure conversion, no actor isolation, safe to call from the real-time
    /// audio thread: one input `AVAudioPCMBuffer` in a source format, one
    /// `Data` of little-endian Int16 samples in `outputFormat` out. The
    /// "provide the buffer once, then `.noDataNow`" input-block shape is
    /// the standard `AVAudioConverter` pull pattern for converting exactly
    /// one already-in-memory buffer (used identically for playback in
    /// `schedule(_:from:)` below).
    nonisolated fileprivate static func pcm16Data(
        from buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat, using converter: AVAudioConverter
    ) -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return nil }
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        guard status != .error, convError == nil, outBuffer.frameLength > 0,
              let channelData = outBuffer.int16ChannelData else { return nil }
        let byteCount = Int(outBuffer.frameLength) * 2 // Int16 = 2 bytes, mono
        return Data(bytes: channelData[0], count: byteCount)
    }

    // MARK: - Playback

    /// WAV clip (Inworld TTS): written to a temp file and read back via
    /// `AVAudioFile` rather than hand-parsing the RIFF header -- leans on
    /// Apple's own parser instead of a hand-rolled one for something that
    /// can't be tested on-device before shipping. Mirrors the temp-file
    /// pattern `VoiceService`/`MessageSendingService` already use elsewhere
    /// in this app for audio.
    private func enqueueWav(_ data: Data) {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kade-call-clip-\(UUID().uuidString).wav")
        do {
            try data.write(to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            let file = try AVAudioFile(forReading: tmpURL)
            guard let raw = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            ) else { return }
            try file.read(into: raw)
            schedule(raw, from: file.processingFormat)
        } catch {
            // One bad clip must never kill the call -- same fail-soft
            // philosophy as every other audio path in this app.
        }
    }

    /// LIVE lane: raw 24kHz PCM16 mono, no header, prefixed with the 4-byte
    /// "LIVE" magic already consumed by the caller. Reconstructed byte-by-
    /// byte (little-endian, matching both this platform's native layout and
    /// the JS client's own `Int16Array` read of the same bytes) rather than
    /// an aligned pointer cast, since `Data` received off the wire carries
    /// no alignment guarantee.
    private func enqueueLivePCM(_ data: Data) {
        let sampleCount = (data.count - 4) / 2
        guard sampleCount > 0 else { return }
        let liveFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true
        )!
        guard let liveBuffer = AVAudioPCMBuffer(pcmFormat: liveFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channelData = liveBuffer.int16ChannelData else { return }
        liveBuffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let dst = channelData[0]
            for i in 0..<sampleCount {
                let lo = UInt16(raw[4 + i * 2])
                let hi = UInt16(raw[4 + i * 2 + 1])
                dst[i] = Int16(bitPattern: lo | (hi << 8))
            }
        }
        schedule(liveBuffer, from: liveFormat)
    }

    /// Converts any incoming buffer to the one fixed `playerFormat` and
    /// schedules it. `AVAudioPlayerNode.scheduleBuffer` (no explicit `at:`
    /// time) queues gaplessly behind whatever's already scheduled as long
    /// as the node is playing -- no manual playhead-tracking needed here,
    /// unlike the web client's Web Audio workaround.
    private func schedule(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) {
        guard engineRunning else { return }
        guard let converter = AVAudioConverter(from: sourceFormat, to: playerFormat) else { return }
        let ratio = playerFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: outCapacity) else { return }
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        guard status != .error, convError == nil, outBuffer.frameLength > 0 else { return }
        playerNode.scheduleBuffer(outBuffer, completionHandler: nil)
    }

    /// Barge-in / `{type:'clear'}`: stop whatever's queued immediately.
    /// `AVAudioPlayerNode.stop()` clears its entire internal queue (unlike
    /// pausing); re-arming with `play()` leaves it ready for the next
    /// scheduled buffer, same net effect as the web client's
    /// `flushPlayback()` stopping every live `AudioBufferSourceNode`.
    private func flushPlayback() {
        guard engineRunning else { return }
        playerNode.stop()
        playerNode.play()
    }

    private func teardownAudio() {
        guard engineRunning else { return }
        engineRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Self-healing mic converter, deliberately NOT `@MainActor`: lives only
/// inside the tap closure's captured state and is touched only from the
/// real-time audio thread, which `AVAudioEngine` guarantees calls a given
/// tap's callback serially (never concurrently with itself) -- same
/// single-threaded-by-construction safety as `CameraCaptureController`'s
/// `FrameSampler`. Rebuilds its `AVAudioConverter` whenever the incoming
/// buffer's format differs from the last one it converted, so it can never
/// go stale against whatever the input node is ACTUALLY delivering --
/// see `startAudioEngine()`'s comment for the live bug this replaced (a
/// converter built once from a format read at the wrong moment, which
/// silently broke every mic chunk after voice processing was enabled).
private final class MicConverterBox {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || lastInputFormat != buffer.format {
            lastInputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }
        return StreamingCallService.pcm16Data(from: buffer, to: outputFormat, using: converter)
    }
}

/// Loose envelope covering every `{type: ...}` JSON message the bridge
/// sends on `/ws/web-voice` (`ready`/`state`/`caption`/`clear`/`table`/
/// `error`/`live-notice`/`live-state`/`video-notice`/`video-state`) --
/// every field beyond `type` is optional since each message type only
/// populates a subset, mirroring how the web client just reads `any` off
/// the parsed JSON and switches on `m.type`.
private struct CallServerMessage: Decodable {
    let type: String
    let state: String?
    let role: String?
    let text: String?
    let id: String?
    let message: String?
    let on: Bool?
    let reason: String?
    let spotterName: String?
    let minutesLeft: Int?
}
