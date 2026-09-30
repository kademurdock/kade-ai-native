import Foundation
import AVFoundation
import CryptoKit
import UIKit

/// Aug 8 2026 — THE WORLD CLIENT (native). The direct lane into the city
/// beyond the Threshold Gate: POST /api/world/command with one engine
/// command, get back the FACTS — no model anywhere in the loop, which is the
/// whole point (her correction: serious play cannot run through a narrator).
/// The engine returns structured KINDS per event; kinds drive earcons and
/// haptics here, per her own BASSLINE law: the screen reader announces, the
/// earcons carry the gameplay.
@MainActor
final class WorldService: ObservableObject {
    @Published private(set) var isSending = false
    @Published private(set) var isLive = false
    @Published private(set) var liveStatus = "Live listening off"
    private var listeningTask: Task<Void, Never>?
    private var listeningGeneration = UUID()
    private var listener: (([WorldEvent]) -> Void)?
    private var cursor: Int?
    private var seenSeqs = Set<Int>()
    private var pendingEvents: [WorldEvent] = []

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct WorldRoom: Decodable, Equatable {
        /// Build 197: the room's own id, so the manifest's `room` scope can
        /// finally be reached. Optional because older servers don't send it —
        /// a phone on build 197 talking to a pre-197 server just gets no room
        /// tone, never a crash.
        let roomId: String?
        let name: String
        let desc: String
        let district: String?
        let exits: [String]
        let items: [String]
        let people: [String]
        let outdoor: Bool?
        let furniture: [String]?
        let sensory: WorldPictureRoom.Senses?
        let home: WorldPictureRoom.Home?
        let weather: String?
        let washhouse: WorldPictureRoom.Washhouse?
        let peopleDetail: [WorldPerson]?
        var picture: WorldPictureRoom {
            WorldPictureRoom(roomId: roomId, name: name, desc: desc, district: district, outdoor: outdoor,
                furniture: furniture, sensory: sensory, home: home, weather: weather, washhouse: washhouse,
                peopleDetail: peopleDetail)
        }
    }

    struct WorldResult: Decodable {
        let ok: Bool?
        let lines: [String]?
        let room: WorldRoom?
        let kinds: [String]?
        let district: String?
        let error: String?
        let hud: WorldHUD?
        let actions: [WorldAction]?
        let people: [WorldPerson]?
        let exits: [WorldExit]?
        let choices: [WorldAction]?
        let mode: String?
        let step: String?
        let freeText: Bool?
        let seenSeqs: [Int]?
    }

    struct WorldError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Build 195 — THE SOUND MANIFEST (the queued "195 material" from the
    /// Reverie plan 16.1): her designed audio as data. One fetch per screen
    /// open; files cache in Caches/world-sounds by stable digest, so every
    /// sound downloads once per device, ever. New sound installed in-world
    /// via @sound -> the manifest changes -> next open picks it up. Native
    /// never rebuilds for a sound again.
    struct WorldSoundManifest: Decodable {
        let event: [String: String]?
        let room: [String: String]?
        let district: [String: String]?
        let versions: [String: String]?
    }

    func fetchSoundManifest() async -> WorldSoundManifest? {
        let req = client.request(path: "api/world/sounds", method: "GET", authorized: true)
        guard let out = try? await client.send(req), out.1.statusCode == 200 else { return nil }
        return try? decoder.decode(WorldSoundManifest.self, from: out.0)
    }

    /// Download-once cache. Stable SHA-256 name (hashValue changes every
    /// launch — learned class, not repeated). Returns nil quietly on any
    /// trouble: a missing sound file must never cost more than silence.
    nonisolated static func cachedSoundFile(for urlString: String, revision: String? = nil) async -> URL? {
        await WorldSoundCache.shared.file(for: urlString, revision: revision)
    }

    func send(command: String) async throws -> WorldResult {
        guard !isSending else { throw WorldError(message: "A command is already on its way. Give it a moment.") }
        isSending = true
        defer { isSending = false; deliverPending() }
        var req = client.request(path: "api/world/command", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["command": command, "live": isLive])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let server = (try? decoder.decode(WorldResult.self, from: data))?.error
            throw WorldError(message: server ?? "The world flickered (\(http.statusCode)). Try again.")
        }
        let result = try decoder.decode(WorldResult.self, from: data)
        seenSeqs.formUnion(result.seenSeqs ?? [])
        return result
    }

    func here() async -> WorldResult? {
        let req = client.request(path: "api/world/here", authorized: true)
        guard let (data, response) = try? await client.send(req), response.statusCode == 200 else { return nil }
        return try? decoder.decode(WorldResult.self, from: data)
    }

    func startListening(onEvents: @escaping ([WorldEvent]) -> Void) {
        guard listeningTask == nil else { return }
        listener = onEvents
        let generation = UUID()
        listeningGeneration = generation
        listeningTask = Task { [weak self] in
            guard let self else { return }
            var delay: UInt64 = 2
            while !Task.isCancelled {
                liveStatus = "Connecting to the room"
                do {
                    let query = cursor.map { [URLQueryItem(name: "after", value: String($0))] }
                    var req = client.request(path: "api/world/stream", authorized: true, queryItems: query)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await client.streamBytes(req)
                    guard !Task.isCancelled, listeningGeneration == generation else { return }
                    guard response.statusCode == 200 else {
                        if response.statusCode == 401 || response.statusCode == 403 {
                            liveStatus = "Live listening unavailable. Commands still work."
                            break
                        }
                        throw URLError(.badServerResponse)
                    }
                    isLive = true
                    liveStatus = "Hearing the room live"
                    delay = 2
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:"), let data = line.dropFirst(5).data(using: .utf8),
                              let update = try? decoder.decode(WorldStreamUpdate.self, from: data) else { continue }
                        if update.end != nil { break }
                        if let received = update.cursor { cursor = received }
                        pendingEvents.append(contentsOf: update.events ?? [])
                        if !isSending { deliverPending() }
                    }
                } catch {
                    if Task.isCancelled { break }
                }
                guard !Task.isCancelled, listeningGeneration == generation else { break }
                isLive = false
                liveStatus = "Reconnecting. Commands still work."
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { break }
                delay = min(delay * 2, 30)
            }
            if listeningGeneration == generation { isLive = false; listeningTask = nil }
        }
    }

    func stopListening() {
        listeningTask?.cancel()
        listeningGeneration = UUID()
        listeningTask = nil
        listener = nil
        isLive = false
        liveStatus = "Live listening off"
    }

    private func deliverPending() {
        let fresh = pendingEvents.filter { event in
            guard let seq = event.seq else { return true }
            return seenSeqs.insert(seq).inserted
        }
        pendingEvents.removeAll(keepingCapacity: true)
        if seenSeqs.count > 300 { seenSeqs = Set(seenSeqs.sorted().suffix(200)) }
        if !fresh.isEmpty { listener?(fresh) }
    }
}

/// The world's synth voice — one short pre-rendered tone phrase per event
/// kind, played through a tiny AVAudioEngine. These are deliberate
/// PLACEHOLDERS with the same shape as the web client's: when Kade designs
/// the real sounds, each buffer swaps for her audio file and the world keeps
/// the same reflexes. Rendered once at init; playing is schedule-and-go.
final class WorldTones {
    static let shared = WorldTones()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 22050
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var started = false
    /// Build 195: real sounds from the manifest play through independent
    /// AVAudioPlayers — file playback never touches engine state, so a
    /// stopped engine can never take an earcon down with it.
    private var filePlayers: [String: AVAudioPlayer] = [:]
    private var ambiencePlayer: AVAudioPlayer?
    private var ambienceKey: String?
    /// Build 197 — LAYER TWO of 16.1's three-layer design. The ward bed says
    /// which part of town you're in; the room tone says which room. They play
    /// together, the room tone quieter, because that is how a real room sounds
    /// on top of a real neighbourhood.
    private var roomTonePlayer: AVAudioPlayer?
    private var roomToneKey: String?
    /// Sep 29 2026: which file (url plus revision) each installed event
    /// player came from, so a repeat earcon plays the loaded player instead
    /// of re-checking the cache and building a new one on the main thread.
    private var eventSources: [String: String] = [:]
    private var active = false
    private var interrupted = false
    /// Sep 29 2026: the session is set up and active. Every earcon used to
    /// call setActive twice; now it runs on activate(), after an
    /// interruption or media reset, or after a category change.
    private var sessionReady = false
    /// Sep 29 2026: headphones or a Bluetooth device went away. The loops
    /// stay paused until she comes back to the screen or a new device
    /// arrives, so an earcon never restarts them on the loudspeaker.
    private var pausedForRoute = false

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.attach(player)
        if let format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        /* ── BUILD 195 CRASH FIX (the "native crash issues" report) ──
         * iOS stops an AVAudioEngine BEHIND THE APP'S BACK: a phone call,
         * Siri, VoiceOver's own audio, a route change to Bluetooth or
         * speaker, mediaserverd resetting. The old play() trusted the
         * `started` flag, so the next earcon called scheduleBuffer()/play()
         * on a dead engine — an Objective-C exception Swift cannot catch,
         * a hard crash every time. This app juggles the audio session
         * constantly (calls, TTS, VoiceOver), and the Aug 10 Reverie carve
         * multiplied earcon traffic, which is why it started biting daily.
         * The fix is threefold: listen for every way the engine dies (below),
         * never trust `started` (play() asks engine.isRunning), and re-check
         * before each engine call. STANDING LESSON: any AVAudioEngine user
         * needs exactly this trio — grep for scheduleBuffer when touching
         * audio code. */
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self.engineReset()
            self.sessionReady = false
            if type == .began {
                /* Sep 29 2026: a .began that only reports the app was
                 * suspended (phone locked, app switched) arrives late, on
                 * the way back, and never gets a matching .ended. Taking it
                 * as a real interruption kept the world silent for good.
                 * The session was only deactivated while suspended, so set
                 * it up again. Reason 1 is .appWasSuspended, matched by raw
                 * value because that case is deprecated; the old boolean key
                 * is read by its name for the same reason. */
                let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                let wasSuspended = note.userInfo?["AVAudioSessionInterruptionWasSuspendedKey"] as? Bool ?? false
                if reason == 1 || wasSuspended {
                    self.resumeLoops()
                    return
                }
                self.interrupted = true
                self.ambiencePlayer?.pause()
                self.roomTonePlayer?.pause()
            } else {
                self.interrupted = false
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                    self.resumeLoops()
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.engineReset()
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                self.pausedForRoute = true
                self.ambiencePlayer?.pause()
                self.roomTonePlayer?.pause()
                return
            }
            if reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue {
                // Sep 29 2026: a call, the Library or a voice note changed
                // the shared session; set it up again before the next sound.
                self.sessionReady = false
            } else if reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                self.pausedForRoute = false
            }
            self.resumeLoops()
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.engineReset() }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.engineReset()
            // Sep 29 2026: the old session is gone, and with it any
            // interruption it was in; WorldView calls activate() next.
            self?.interrupted = false
            self?.sessionReady = false
            self?.filePlayers.removeAll()
            self?.eventSources.removeAll()
            self?.ambiencePlayer = nil
            self?.ambienceKey = nil
            self?.roomTonePlayer = nil
            self?.roomToneKey = nil
        }
        // (frequency, duration seconds, start offset seconds)
        buffers["move"] = render([(150, 0.05, 0.00), (130, 0.05, 0.09)])
        buffers["look"] = render([(520, 0.07, 0.00)])
        buffers["take"] = render([(330, 0.05, 0.00), (540, 0.06, 0.05)])
        buffers["drop"] = render([(220, 0.05, 0.00), (110, 0.09, 0.05)])
        buffers["say"] = render([(660, 0.06, 0.00), (880, 0.08, 0.07)])
        buffers["emote"] = render([(440, 0.09, 0.00)])
        buffers["enter"] = render([(392, 0.06, 0.00), (494, 0.06, 0.06), (587, 0.08, 0.12)])
        buffers["leave"] = render([(587, 0.06, 0.00), (494, 0.06, 0.06), (392, 0.08, 0.12)])
        buffers["err"] = render([(110, 0.16, 0.00)])
    }

    private func render(_ notes: [(Double, Double, Double)]) -> AVAudioPCMBuffer? {
        let total = (notes.map { $0.1 + $0.2 }.max() ?? 0.2) + 0.05
        let frames = AVAudioFrameCount(total * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            samples[i] = 0
        }
        for (freq, dur, offset) in notes {
            let start = Int(offset * sampleRate)
            let count = Int(dur * sampleRate)
            for i in 0..<count {
                let idx = start + i
                guard idx < Int(frames) else { break }
                let t = Double(i) / sampleRate
                // quick attack, exponential-ish decay — soft and rounded
                let progress = Double(i) / Double(max(count, 1))
                let envelope = Float(min(progress * 12, 1.0) * pow(1.0 - progress, 1.5))
                samples[idx] += Float(sin(2.0 * Double.pi * freq * t)) * envelope * 0.16
            }
        }
        return buffer
    }

    /// The engine died (interruption / route change / config change) or is
    /// about to be reconfigured: fold our tent cleanly so the next play()
    /// starts it fresh instead of scheduling into a corpse.
    private func engineReset() {
        engine.stop()
        started = false
    }

    func activate() {
        active = true
        // Sep 29 2026: coming back to the screen or the app starts clean. A
        // .began that never got its .ended, or headphones pulled earlier,
        // must not keep the world silent. Known cost: World's session mixes,
        // and a mixing session can usually be activated during a phone call,
        // so coming back to the app mid-call may bring the loops back under
        // the call (build 319 kept them paused until .ended).
        interrupted = false
        pausedForRoute = false
        sessionReady = false
        resumeLoops()
    }

    /// Sets the session up once; later calls return at once until
    /// sessionReady is cleared. While interrupted nothing asks for the
    /// session back (Sep 29 2026): a mixing session can usually be activated
    /// during a phone call, so asking would play the world under the call.
    /// .ended, activate() and a media reset clear `interrupted`.
    private func prepareSession() -> Bool {
        guard active, !interrupted else { return false }
        if sessionReady { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            // Sep 29 2026: only the untouched default (.soloAmbient) or
            // .ambient is switched. A voice call's .playAndRecord and the
            // Library's or a described video's own .playback stay theirs;
            // the earcons play inside whatever session is already there.
            if session.category == .soloAmbient || session.category == .ambient {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            sessionReady = true
            return true
        } catch {
            sessionReady = false
            return false
        }
    }

    private func resumeLoops() {
        guard !pausedForRoute, prepareSession() else { return }
        if let ambiencePlayer, !ambiencePlayer.isPlaying { ambiencePlayer.play() }
        if let roomTonePlayer, !roomTonePlayer.isPlaying { roomTonePlayer.play() }
    }

    /// True when `kind` already has a player loaded from this exact source
    /// (url plus revision), so the caller can play it straight away.
    func hasEventSound(kind: String, source: String) -> Bool {
        filePlayers[kind] != nil && eventSources[kind] == source
    }

    /// Swap a synth earcon for one of her real sounds (the manifest lane).
    func installEventSound(kind: String, fileURL: URL, source: String? = nil) {
        guard let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        p.prepareToPlay()
        filePlayers[kind] = p
        eventSources[kind] = source
    }

    /// The ward bed — one low looping ambience for the district she stands
    /// in (16.1's first layer). Same key = leave it playing; nil = quiet.
    func setAmbience(key: String?, fileURL: URL?) {
        if ambienceKey == key, ambiencePlayer != nil { resumeLoops(); return }
        ambienceKey = nil
        ambiencePlayer?.stop()
        ambiencePlayer = nil
        guard let fileURL, let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        p.numberOfLoops = -1
        p.volume = 0.22
        p.prepareToPlay()
        // Sep 29 2026: after headphones come out a new place's bed waits,
        // paused, like the old one (resumeLoops starts it later).
        if !pausedForRoute && prepareSession() { p.play() }
        ambiencePlayer = p
        ambienceKey = key
    }

    /// The room tone — layer two, under the ward bed. Same contract as
    /// setAmbience: same key = leave it alone, nil = silence.
    func setRoomTone(key: String?, fileURL: URL?) {
        if roomToneKey == key, roomTonePlayer != nil { resumeLoops(); return }
        roomToneKey = nil
        roomTonePlayer?.stop()
        roomTonePlayer = nil
        guard let fileURL, let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        p.numberOfLoops = -1
        // Quieter than the ward bed (0.22) on purpose: the room sits INSIDE
        // the ward, so it must never drown the neighbourhood out.
        p.volume = 0.16
        p.prepareToPlay()
        if !pausedForRoute && prepareSession() { p.play() }
        roomTonePlayer = p
        roomToneKey = key
    }

    func play(_ kind: String) {
        /* Sep 29 2026: while interrupted an earcon stays quiet and does not
         * ask for the session back (see prepareSession). Once the session
         * is ready it restarts the loops, as in build 319, so an .ended
         * without shouldResume does not leave the world bare. resumeLoops()
         * waits while headphones are out (pausedForRoute), so it never
         * starts the loops on the loudspeaker. */
        guard prepareSession() else { return }
        resumeLoops()
        // Real file first: independent player, immune to engine state.
        if let file = filePlayers[kind] {
            file.currentTime = 0
            if file.play() { return }
            // Sep 29 2026: sessionReady can be stale if another part of the
            // app deactivated the shared session. Set it up once more; a
            // player that still will not start is dropped, so the next
            // earcon of this kind loads the file fresh.
            sessionReady = false
            if prepareSession(), file.play() { return }
            filePlayers[kind] = nil
            eventSources[kind] = nil
            return
        }
        let fallback = kind.hasPrefix("move.step.") ? "move" : kind.hasPrefix("ui.") ? "look" : kind.hasPrefix("social.") ? "emote" : kind
        guard let buffer = buffers[fallback] else { return }
        // CRASH FIX: never trust `started` — ask the engine itself, every
        // time, and re-check before each call that would throw on a dead one.
        if !engine.isRunning {
            started = false
            do {
                try engine.start()
            } catch {
                // Sep 29 2026: same stale-session retry as the file lane.
                sessionReady = false
                guard prepareSession() else { return }
                do { try engine.start() } catch { return }
            }
            started = true
        }
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        guard engine.isRunning else { return }
        player.play()
    }

    func stop() {
        active = false
        sessionReady = false
        for file in filePlayers.values { file.stop() }
        ambiencePlayer?.stop()
        ambiencePlayer = nil
        ambienceKey = nil
        roomTonePlayer?.stop()
        roomTonePlayer = nil
        roomToneKey = nil
        if engine.isRunning {
            player.stop()
        }
        engine.stop()
        started = false
    }
}

/// Kind -> haptic, respecting the app-wide haptics switch (same UserDefaults
/// key KadeFeedback writes). Sound and touch land together; either alone
/// still tells the story.
///
/// Build 197: the shape now comes from the SOUND ITSELF where one has been
/// installed (WorldHapticsEngine measures the file's envelope), and from the
/// old fixed table everywhere else. Call sites are unchanged on purpose —
/// every `WorldHaptics.play(kind)` in the app got the upgrade for free.
enum WorldHaptics {
    static func play(_ kind: String) {
        WorldHapticsEngine.shared.play(kind)
    }
}
