import Foundation
import AVFoundation
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

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.attach(player)
        if let format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
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

    func play(_ kind: String) {
        guard let buffer = buffers[kind] else { return }
        if !started {
            do {
                try engine.start()
                started = true
            } catch {
                return
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    func stop() {
        if started {
            player.stop()
            engine.stop()
            started = false
        }
    }
}

/// Kind -> haptic, respecting the app-wide haptics switch (same UserDefaults
/// key KadeFeedback writes). Sound and touch land together; either alone
/// still tells the story.
enum WorldHaptics {
    static func play(_ kind: String) {
        guard UserDefaults.standard.bool(forKey: "kade.feedback.haptics") else { return }
        switch kind {
        case "move":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "take", "drop":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "enter", "leave":
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case "err":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        default:
            break
        }
    }
}
