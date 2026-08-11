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
    }

    struct WorldResult: Decodable {
        let ok: Bool?
        let lines: [String]?
        let room: WorldRoom?
        let kinds: [String]?
        let district: String?
        let error: String?
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
    }

    func fetchSoundManifest() async -> WorldSoundManifest? {
        let req = client.request(path: "api/world/sounds", method: "GET", authorized: true)
        guard let out = try? await client.send(req), out.1.statusCode == 200 else { return nil }
        return try? decoder.decode(WorldSoundManifest.self, from: out.0)
    }

    /// Download-once cache. Stable SHA-256 name (hashValue changes every
    /// launch — learned class, not repeated). Returns nil quietly on any
    /// trouble: a missing sound file must never cost more than silence.
    nonisolated static func cachedSoundFile(for urlString: String) async -> URL? {
        guard let remote = URL(string: urlString), remote.scheme?.hasPrefix("http") == true else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("world-sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(urlString.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let ext = remote.pathExtension.isEmpty ? "snd" : remote.pathExtension
        let local = dir.appendingPathComponent("\(digest).\(ext)")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let out = try? await URLSession.shared.download(from: remote),
              (out.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.removeItem(at: local)
        do { try FileManager.default.moveItem(at: out.0, to: local) } catch { return nil }
        return local
    }

    func send(command: String) async throws -> WorldResult {
        isSending = true
        defer { isSending = false }
        var req = client.request(path: "api/world/command", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["command": command])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let server = (try? decoder.decode(WorldResult.self, from: data))?.error
            throw WorldError(message: server ?? "The world flickered (\(http.statusCode)). Try again.")
        }
        return try decoder.decode(WorldResult.self, from: data)
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
        ) { [weak self] _ in self?.engineReset() }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.engineReset() }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.engineReset() }
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

    /// Swap a synth earcon for one of her real sounds (the manifest lane).
    func installEventSound(kind: String, fileURL: URL) {
        guard let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        p.prepareToPlay()
        filePlayers[kind] = p
    }

    /// The ward bed — one low looping ambience for the district she stands
    /// in (16.1's first layer). Same key = leave it playing; nil = quiet.
    func setAmbience(key: String?, fileURL: URL?) {
        guard ambienceKey != key else { return }
        ambienceKey = key
        ambiencePlayer?.stop()
        ambiencePlayer = nil
        guard let fileURL, let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        p.numberOfLoops = -1
        p.volume = 0.22
        p.prepareToPlay()
        p.play()
        ambiencePlayer = p
    }

    /// The room tone — layer two, under the ward bed. Same contract as
    /// setAmbience: same key = leave it alone, nil = silence.
    func setRoomTone(key: String?, fileURL: URL?) {
        guard roomToneKey != key else { return }
        roomToneKey = key
        roomTonePlayer?.stop()
        roomTonePlayer = nil
        guard let fileURL, let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        p.numberOfLoops = -1
        // Quieter than the ward bed (0.22) on purpose: the room sits INSIDE
        // the ward, so it must never drown the neighbourhood out.
        p.volume = 0.16
        p.prepareToPlay()
        p.play()
        roomTonePlayer = p
    }

    func play(_ kind: String) {
        // Real file first: independent player, immune to engine state.
        if let file = filePlayers[kind] {
            file.currentTime = 0
            file.play()
            return
        }
        guard let buffer = buffers[kind] else { return }
        // CRASH FIX: never trust `started` — ask the engine itself, every
        // time, and re-check before each call that would throw on a dead one.
        if !engine.isRunning {
            started = false
            do {
                try engine.start()
                started = true
            } catch {
                return
            }
        }
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        guard engine.isRunning else { return }
        player.play()
    }

    func stop() {
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
