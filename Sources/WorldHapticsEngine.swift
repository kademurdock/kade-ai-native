import Foundation
import AVFoundation
import CoreHaptics
import UIKit

/// Build 197 — HAPTICS THAT TRACE THE SOUND, her Swordy Quest reference:
/// "picking flowers and berries where the haptic follows the shape of the
/// sound." Before this, every world event got one canned buzz from a fixed
/// list — a footstep and a dropped coin felt identical, which throws away
/// the one channel that can carry shape without ever competing with
/// VoiceOver for the ears.
///
/// THE APPROACH, and why it is this one: the haptic is MEASURED off the
/// actual audio file, not hand-authored per event. That matters because her
/// sounds arrive at runtime from the manifest — install a new `@sound` and
/// the world plays it with no rebuild. Anything hand-authored would go stale
/// the moment she installs a sound; a measured envelope cannot. Every sound
/// she ever adds gets a matching haptic for free, forever.
///
/// It also inherits the sound forge's hardest-won lesson, in code: CUT ON
/// MEASURED ATTACKS, NEVER BY EYE. The forge learned that placing a cut by
/// eye landed it in the gap between two footsteps and she heard it instantly.
/// Same rule here — transients land where the waveform actually spikes, so
/// her dock-step PAIR feels like a pair instead of one lump.
///
/// DELIBERATELY NOT AN ACTOR. There is no Swift compiler in this workspace,
/// so the safest shape is the one with no isolation to get wrong at a call
/// site: a plain class with a lock, callable from anywhere, exactly like the
/// enum it replaces. `WorldHaptics.play(kind)` keeps its old signature and
/// every existing call site got the upgrade without being touched.
///
/// Falls back, always: no Taptic hardware, no analysed pattern yet, or an
/// engine that died — the old UIImpactFeedbackGenerator shape still fires.
/// The hand is never left with nothing.
final class WorldHapticsEngine: @unchecked Sendable {
    static let shared = WorldHapticsEngine()

    private let lock = NSLock()
    private var engine: CHHapticEngine?
    private var patterns: [String: CHHapticPattern] = [:]
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {}

    // MARK: - Engine life

    /// CoreHaptics engines die the same ways AVAudioEngine does — a call,
    /// Siri, a media-server reset, backgrounding. Build 195 paid for this
    /// lesson on the audio side and the cure is the same trio: a handler for
    /// every way it dies, never trust a cached "started" flag, re-check
    /// before every use. Caller must hold the lock.
    private func ensureEngineLocked() -> CHHapticEngine? {
        guard supported else { return nil }
        if let engine { return engine }
        do {
            let e = try CHHapticEngine()
            e.isAutoShutdownEnabled = true
            e.stoppedHandler = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.engine = nil
                self.lock.unlock()
            }
            e.resetHandler = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.engine = nil
                self.lock.unlock()
            }
            try e.start()
            engine = e
            return e
        } catch {
            engine = nil
            return nil
        }
    }

    // MARK: - Install

    /// Analyse one of her sounds and keep the haptic shape it implies.
    /// Called from the same place the audio file is installed, so sound and
    /// touch can never end up describing two different events.
    func installEnvelope(kind: String, fileURL: URL) async {
        guard supported else { return }
        let pattern: CHHapticPattern? = await Task.detached(priority: .utility) {
            guard let shape = WorldHapticsEngine.analyse(fileURL: fileURL) else { return nil }
            return WorldHapticsEngine.pattern(from: shape)
        }.value
        guard let pattern else { return }
        lock.lock()
        patterns[kind] = pattern
        lock.unlock()
    }

    // MARK: - Play

    func play(_ kind: String) {
        guard UserDefaults.standard.bool(forKey: "kade.feedback.haptics") else { return }
        guard supported else {
            WorldHapticsFallback.play(kind)
            return
        }
        lock.lock()
        let pattern = patterns[kind]
        let engine = pattern == nil ? nil : ensureEngineLocked()
        lock.unlock()

        guard let pattern, let engine else {
            WorldHapticsFallback.play(kind)
            return
        }
        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A dead engine or a rejected pattern must still be felt.
            lock.lock()
            self.engine = nil
            lock.unlock()
            engine.stop(completionHandler: nil)
            WorldHapticsFallback.play(kind)
        }
    }

    // MARK: - Measurement

    /// What a sound's shape reduces to: where it hits, and how loud it is
    /// over time. Times are seconds from the start of the file.
    struct SoundShape {
        var attackTimes: [Double]
        var attackIntensities: [Float]
        var attackSharpnesses: [Float]
        var envelopeTimes: [Double]
        var envelopeLevels: [Float]
        var duration: Double
    }

    /// Haptics longer than this stop reading as one event and start reading
    /// as a malfunction. Only short event sounds are ever analysed here —
    /// ward beds and room tones are loops and never come through this lane.
    private static let maxHapticDuration: Double = 1.6

    static func analyse(fileURL: URL) -> SoundShape? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        guard frameCount > 0, sampleRate > 0, channelCount > 0 else { return nil }

        // RMS in ~5.8ms windows at 44.1k: fine enough to separate the two
        // halves of a footstep pair, coarse enough to stay cheap.
        let hop = 256
        var levels: [Float] = []
        levels.reserveCapacity(frameCount / hop + 1)
        var index = 0
        while index < frameCount {
            let end = min(index + hop, frameCount)
            var sum: Float = 0
            for c in 0..<channelCount {
                let data = channels[c]
                var i = index
                while i < end {
                    let v = data[i]
                    sum += v * v
                    i += 1
                }
            }
            let count = Float(max((end - index) * channelCount, 1))
            levels.append((sum / count).squareRoot())
            index += hop
        }
        guard levels.count >= 2, let peak = levels.max(), peak > 0.0001 else { return nil }
        let normalized = levels.map { $0 / peak }
        let secondsPerWindow = Double(hop) / sampleRate
        let minGapWindows = max(Int(0.04 / secondsPerWindow), 1)

        // ATTACKS, measured: a window that jumps well above its predecessor
        // and stands clear of the floor. Sharpness comes from HOW fast it
        // jumped — a click is sharp, a thud is not.
        var attackTimes: [Double] = []
        var attackIntensities: [Float] = []
        var attackSharpnesses: [Float] = []
        var lastAttackWindow = -1000
        var w = 1
        while w < normalized.count {
            let rise = normalized[w] - normalized[w - 1]
            if normalized[w] > 0.18, rise > 0.10, w - lastAttackWindow > minGapWindows {
                let t = Double(w) * secondsPerWindow
                if t > maxHapticDuration { break }
                lastAttackWindow = w
                attackTimes.append(t)
                attackIntensities.append(min(max(normalized[w], 0.25), 1.0))
                attackSharpnesses.append(min(max(rise * 2.2, 0.25), 1.0))
                if attackTimes.count >= 8 { break }
            }
            w += 1
        }

        // The body: the envelope itself, thinned to something CoreHaptics
        // will accept as a parameter curve.
        let duration = min(Double(normalized.count) * secondsPerWindow, maxHapticDuration)
        let usableWindows = min(max(Int(duration / secondsPerWindow), 2), normalized.count)
        let step = max(usableWindows / 24, 1)
        var envelopeTimes: [Double] = []
        var envelopeLevels: [Float] = []
        var k = 0
        while k < usableWindows {
            envelopeTimes.append(Double(k) * secondsPerWindow)
            envelopeLevels.append(normalized[k])
            k += step
        }
        if let last = envelopeTimes.last, last < duration {
            envelopeTimes.append(duration)
            envelopeLevels.append(0)
        }
        guard envelopeTimes.count >= 2 else { return nil }

        return SoundShape(
            attackTimes: attackTimes,
            attackIntensities: attackIntensities,
            attackSharpnesses: attackSharpnesses,
            envelopeTimes: envelopeTimes,
            envelopeLevels: envelopeLevels,
            duration: duration
        )
    }

    /// Turn a measured shape into something the Taptic Engine can play: one
    /// transient per attack, plus a continuous event whose intensity curve is
    /// the sound's own envelope.
    static func pattern(from shape: SoundShape) -> CHHapticPattern? {
        var events: [CHHapticEvent] = []

        var i = 0
        while i < shape.attackTimes.count {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: shape.attackIntensities[i]),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: shape.attackSharpnesses[i]),
                ],
                relativeTime: shape.attackTimes[i]
            ))
            i += 1
        }

        var curves: [CHHapticParameterCurve] = []
        if shape.duration > 0.06 {
            events.append(CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                    // Rounded, not buzzy — the body of a sound is felt, not
                    // clicked. The transients above carry the edges.
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                ],
                relativeTime: 0,
                duration: shape.duration
            ))
            var points: [CHHapticParameterCurve.ControlPoint] = []
            var j = 0
            while j < shape.envelopeTimes.count {
                points.append(CHHapticParameterCurve.ControlPoint(
                    relativeTime: shape.envelopeTimes[j],
                    value: min(max(shape.envelopeLevels[j] * 0.7, 0), 1)
                ))
                j += 1
            }
            curves.append(CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: points,
                relativeTime: 0
            ))
        }

        guard !events.isEmpty else { return nil }
        return try? CHHapticPattern(events: events, parameterCurves: curves)
    }
}

/// The old fixed shapes, kept exactly as they were. This is what plays on a
/// device with no Taptic Engine, before a sound has been analysed, or if the
/// haptic engine dies mid-session. UIFeedbackGenerator is a UIKit class, so
/// it is always poked on the main thread.
enum WorldHapticsFallback {
    static func play(_ kind: String) {
        DispatchQueue.main.async {
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
}
