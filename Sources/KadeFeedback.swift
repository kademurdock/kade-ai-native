import SwiftUI
import UIKit
import AVFoundation
import CoreHaptics

// MARK: - FeedbackPrefs
//
// Session 20 (Kade: "new cool features... Visual flare without effecting
// voiceover? Auditory flare by doing haptics and sounds? Earcons, nothing
// crazy obnoxious"). This is the one place the whole app reaches for
// non-speech feedback, so it can be turned off in ONE place and can never
// step on VoiceOver.
//
// Three user-facing switches, all OPT-OUT (default on) so the flair is there
// the first time you open the app, not something you have to go find:
//   - Sound effects  -> the earcons below
//   - Haptics        -> gates every `.sensoryFeedback` in the app
//   - Reduce motion  -> a user override ON TOP OF the system switch, never the
//                       other way round (we can force motion off, never force
//                       it back on for someone who set the system switch).
//
// Everything is on-device UserDefaults only -- same storage story as
// AppearancePreferences, no server, nothing to sync.

@MainActor
final class FeedbackPrefs: ObservableObject {
    static let shared = FeedbackPrefs()

    private enum Keys {
        static let sound = "kade.feedback.sound"
        static let haptics = "kade.feedback.haptics"
        static let reduceMotion = "kade.feedback.reduceMotion"
        static let sensorySync = "kade.feedback.sensorySync"
    }

    /// Register first-run defaults (all ON). Must run before `shared` first
    /// reads them -- called at the very top of KadeAIApp.init().
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.sound: true,
            Keys.haptics: true,
            Keys.reduceMotion: false,
            Keys.sensorySync: true
        ])
    }

    @Published var soundEffects: Bool {
        didSet { UserDefaults.standard.set(soundEffects, forKey: Keys.sound) }
    }
    @Published var haptics: Bool {
        didSet { UserDefaults.standard.set(haptics, forKey: Keys.haptics) }
    }
    /// A user override that forces reduced motion even when the system switch
    /// is off. Effective reduce-motion = system value OR this. See
    /// `View.kadeReduceMotion(_:)`.
    @Published var forceReduceMotion: Bool {
        didSet { UserDefaults.standard.set(forceReduceMotion, forKey: Keys.reduceMotion) }
    }
    /// Session 23 (Kade: "make them pulse with the visuals? Some of us neuro
    /// divergent nerd types like that and you could always turn it off").
    /// Gates the soft heartbeat that KadePulseDot fires in time with its
    /// visual pulse -- touch and sight moving together. A SUB-switch under
    /// Haptics: the master switch off silences everything regardless; this
    /// one lets someone keep single-moment haptics (sent, landed, error)
    /// while turning off only the rhythmic kind. Default on, per her
    /// framing.
    @Published var sensorySync: Bool {
        didSet { UserDefaults.standard.set(sensorySync, forKey: Keys.sensorySync) }
    }

    private init() {
        let d = UserDefaults.standard
        soundEffects = d.bool(forKey: Keys.sound)
        haptics = d.bool(forKey: Keys.haptics)
        forceReduceMotion = d.bool(forKey: Keys.reduceMotion)
        sensorySync = d.bool(forKey: Keys.sensorySync)
    }

    /// Gate a SwiftUI `SensoryFeedback` through the Haptics switch. Returns
    /// nil (no buzz) when the user has haptics off. Existing call sites wrap
    /// their return value in this so the toggle is honoured everywhere without
    /// each site re-reading the pref.
    func haptic(_ value: SensoryFeedback?) -> SensoryFeedback? {
        haptics ? value : nil
    }

    /// Nonisolated gate for `.sensoryFeedback` closures. Those must return a
    /// value synchronously and are not guaranteed to be main-actor isolated,
    /// so they can't safely touch this `@MainActor` object. This reads the
    /// same UserDefaults key `haptics` writes, so it always reflects the live
    /// toggle. Defaults to ON (registerDefaults), so a never-touched install
    /// still buzzes.
    nonisolated static func gate(_ value: SensoryFeedback?) -> SensoryFeedback? {
        UserDefaults.standard.bool(forKey: "kade.feedback.haptics") ? value : nil
    }
}

// MARK: - KadeHaptics
//
// Session 22: imperative haptics for async completion points (a save
// finishing, a delete landing, a test alert going out) where a
// `.sensoryFeedback` trigger would need a synthetic @State just to fire
// once. Same UserDefaults gate as FeedbackPrefs.gate, so the Haptics
// switch controls these too.

@MainActor
enum KadeHaptics {
    // Session 23 (Kade: "Your hapteks need to be a lot longer and harder.
    // We like bass... you're dealing with people that would turn music
    // hapteks for deaf people on just for the sensory experience"): the
    // polite one-shot UIKit taps became real CoreHaptics PATTERNS -- hard
    // transients plus low-sharpness continuous rumbles that read as bass
    // in the hand and run a few tenths of a second instead of a blink.
    // Devices without a Taptic Engine (or if the engine fails) fall back
    // to the old UIKit one-shots, so nothing ever goes silent-by-crash.
    // Same single gate as always: the Haptics switch.
    static func success()   { play(pattern: .success)   { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func warning()   { play(pattern: .warning)   { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }
    static func error()     { play(pattern: .error)     { UINotificationFeedbackGenerator().notificationOccurred(.error) } }
    static func tap()       { play(pattern: .tap)       { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() } }
    /// The heartbeat's single LUB-DUB -- the same two-thump pattern
    /// KadePulseDot fires in rhythm with its visual pulse, exposed so the
    /// Settings audition list can play one beat on demand.
    static func pulseBeat() { play(pattern: .pulseBeat) { UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8) } }
    /// The thud-plus-rumble for the app's one deliberately big action
    /// (starting a Spotter call).
    static func press()     { play(pattern: .press)     { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() } }

    private enum Pattern { case success, warning, error, tap, pulseBeat, press }

    private static func play(pattern: Pattern, fallback: () -> Void) {
        guard UserDefaults.standard.bool(forKey: "kade.feedback.haptics") else { return }
        if KadeHapticEngine.shared.play(events: events(for: pattern)) { return }
        fallback()
    }

    /// (relativeTime, duration, intensity, sharpness) -- duration 0 means a
    /// transient knock; anything longer is a continuous rumble. Low
    /// sharpness = the bassy, chesty end of the Taptic Engine's range.
    private static func events(for pattern: Pattern) -> [(TimeInterval, TimeInterval, Float, Float)] {
        switch pattern {
        case .tap:
            return [(0, 0, 1.0, 0.6)]
        case .press:
            return [(0, 0, 1.0, 0.5), (0.02, 0.34, 0.9, 0.1)]
        case .success:
            return [(0, 0, 0.85, 0.35), (0.09, 0, 1.0, 0.55), (0.16, 0.24, 0.75, 0.1)]
        case .warning:
            return [(0, 0.42, 1.0, 0.1), (0.44, 0, 1.0, 0.7)]
        case .error:
            return [(0, 0, 1.0, 0.7), (0.11, 0, 0.95, 0.4), (0.22, 0, 0.9, 0.2), (0.3, 0.4, 0.95, 0.05)]
        case .pulseBeat:
            return [(0, 0, 0.95, 0.25), (0.13, 0, 0.7, 0.15)]
        }
    }
}

/// Owns the one CHHapticEngine. Lazily started, restarted after the system
/// stops it (audio-session churn from calls/recording does this), and
/// honest about failure: `play` returns false so callers fall back to the
/// UIKit generators instead of dropping the moment silently.
@MainActor
final class KadeHapticEngine {
    static let shared = KadeHapticEngine()
    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private init() {}

    func play(events specs: [(TimeInterval, TimeInterval, Float, Float)]) -> Bool {
        guard supported else { return false }
        do {
            if engine == nil {
                let fresh = try CHHapticEngine()
                fresh.resetHandler = { [weak self] in Task { @MainActor in self?.engine = nil } }
                try fresh.start()
                engine = fresh
            }
            guard let engine else { return false }
            let events: [CHHapticEvent] = specs.map { (time, duration, intensity, sharpness) in
                let params = [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ]
                if duration > 0 {
                    return CHHapticEvent(eventType: .hapticContinuous, parameters: params,
                                         relativeTime: time, duration: duration)
                }
                return CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: time)
            }
            let player = try engine.makePlayer(with: try CHHapticPattern(events: events, parameters: []))
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            engine = nil
            return false
        }
    }
}

// MARK: - Earcon
//
// Short, synthesized non-speech sounds -- no bundled audio files, generated
// exactly the way StreamingCallService already synthesizes its connect/live
// tones (sine blips faded in/out so they never click), just played through a
// plain AVAudioPlayer off an in-memory WAV instead of the call's audio engine.
// Deliberately quiet and brief; these COMPLEMENT VoiceOver (which speaks the
// same events), they don't replace or talk over it.

enum Earcon: CaseIterable {
    case messageSent
    case messageReceived
    case actionStart
    case actionDone
    case error

    /// Session 23 (Kade: "for the you sent a message, a fun tone sliding
    /// up, and for agent sent, the reverse maybe? It would be cool if you
    /// could make them sound like bubbles"): fixed beeps became GLIDES --
    /// (startHz, endHz, durationSeconds) segments rendered with a
    /// continuous exponential pitch bend, a soft second harmonic, and a
    /// per-segment decay envelope, which together read as watery little
    /// bloops rather than pager beeps. Sent slides UP, the reply slides
    /// DOWN -- her exact spec -- and everything else keeps the family
    /// resemblance (up-ish = good, falling = problem).
    fileprivate var segments: [(Double, Double, Double)] {
        switch self {
        case .messageSent:     return [(280, 720, 0.10), (720, 980, 0.06)]   // bubble UP
        case .messageReceived: return [(900, 520, 0.10), (520, 330, 0.08)]   // bubble DOWN
        case .actionStart:     return [(350, 520, 0.06)]                      // tiny up-blip
        case .actionDone:      return [(420, 840, 0.09), (840, 700, 0.05)]   // plip!
        case .error:           return [(520, 300, 0.16), (330, 240, 0.14)]   // sinking wobble
        }
    }

    fileprivate var amplitude: Float {
        switch self {
        case .error: return 0.30
        default:     return 0.28
        }
    }
}

@MainActor
final class Earcons {
    static let shared = Earcons()
    private init() {}

    private let sampleRate: Double = 44_100
    private var cache: [Earcon: Data] = [:]
    /// Keep players alive until they finish -- an AVAudioPlayer deallocated
    /// mid-play just stops. Small pool, pruned as clips end.
    private var players: [AVAudioPlayer] = []

    /// Synthesize every earcon once, off the main actor's hot path, so the
    /// first real play() is never a synthesis hitch. Called at launch.
    func prewarm() {
        for e in Earcon.allCases where cache[e] == nil {
            cache[e] = Self.renderWAV(segments: e.segments, amplitude: e.amplitude, sampleRate: sampleRate)
        }
    }

    /// Play an earcon, honouring the Sound effects switch. Safe to call from
    /// anywhere on the main actor; a no-op if sound is off or synthesis fails.
    func play(_ earcon: Earcon) {
        guard FeedbackPrefs.shared.soundEffects else { return }
        let data: Data
        if let cached = cache[earcon] {
            data = cached
        } else {
            let rendered = Self.renderWAV(segments: earcon.segments, amplitude: earcon.amplitude, sampleRate: sampleRate)
            cache[earcon] = rendered
            data = rendered
        }
        players.removeAll { !$0.isPlaying }
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 1.0
        player.prepareToPlay()
        players.append(player)
        player.play()
    }

    /// Convenience for the chat composer: map a send-state transition to the
    /// right earcon in one call, mirroring the existing haptic mapping.
    func onSend(sent: Bool = false, received: Bool = false, failed: Bool = false) {
        if failed { play(.error) }
        else if received { play(.messageReceived) }
        else if sent { play(.messageSent) }
    }

    // MARK: WAV synthesis (16-bit PCM mono)

    /// Glide renderer: exponential pitch bend per segment with PHASE carried
    /// across the whole sound (no clicks at segment joins), a quiet second
    /// harmonic for watery warmth, and a gentle per-segment decay so each
    /// bloop rounds off like a bubble surfacing rather than cutting out.
    private static func renderWAV(segments: [(Double, Double, Double)], amplitude: Float, sampleRate: Double) -> Data {
        var samples: [Int16] = []
        let fadeSeconds = 0.006
        let fadeLen = Int(sampleRate * fadeSeconds)
        var phase = 0.0
        var phase2 = 0.0
        let totalCount = segments.reduce(0) { $0 + max(1, Int(sampleRate * $1.2)) }
        var produced = 0
        for (f0, f1, dur) in segments {
            let count = max(1, Int(sampleRate * dur))
            let ratio = f1 / max(1.0, f0)
            for i in 0..<count {
                let u = Double(i) / Double(count)
                let f = f0 * pow(ratio, u)
                phase += 2.0 * Double.pi * f / sampleRate
                phase2 += 2.0 * Double.pi * (f * 2.0) / sampleRate
                // Fundamental + a soft octave-up harmonic = rounder, more
                // liquid than a bare sine.
                let raw = sin(phase) + 0.28 * sin(phase2)
                // Per-segment decay (each bloop softens toward its end).
                let decay = 1.0 - 0.35 * u
                // Whole-sound edge fades so nothing ever clicks.
                let edge = Double(min(min(produced, totalCount - produced), fadeLen)) / Double(max(1, fadeLen))
                let v = Float(raw) * amplitude * Float(decay * min(1.0, edge)) / 1.28
                samples.append(Int16(max(-1.0, min(1.0, v)) * 32767.0))
                produced += 1
            }
        }
        return encodeWAV(samples: samples, sampleRate: Int(sampleRate))
    }

    private static func encodeWAV(samples: [Int16], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataBytes))
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }
}

// MARK: - KadeAnnounce
//
// Session 22, fixing the exact soft-flag session 17 wrote down: in Quick
// Dictate, the focus move to the transcript and the "Transcript copied."
// announcement fire back to back, and default-priority announcements can be
// stepped on by the focus move's own readback -- so the one piece of
// information that matters right then (it's on the clipboard, go paste it)
// could get cut off. A HIGH-priority announcement interrupts the readback
// and cannot itself be interrupted. Use sparingly, only for short
// confirmations whose moment is NOW; default announcements stay the right
// tool everywhere else.

@MainActor
enum KadeAnnounce {
    static func high(_ text: String) {
        var attributed = AttributedString(text)
        attributed.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(attributed).post()
    }
}

// MARK: - Reduced motion helper

extension View {
    /// Effective reduced-motion for this app: the system switch OR the user's
    /// in-app override. Decorative animations should collapse to a static
    /// state when this is true. Pass in the environment value read by the
    /// caller (`@Environment(\.accessibilityReduceMotion)`).
    func kadeReduceMotion(_ systemReduceMotion: Bool) -> Bool {
        systemReduceMotion || FeedbackPrefs.shared.forceReduceMotion
    }
}

// MARK: - Decorative pulse
//
// Purely visual flair for sighted glances (family, a companion looking over a
// shoulder). ALWAYS `accessibilityHidden(true)` so VoiceOver never sees it,
// and it collapses to a plain static dot the instant reduced motion is on --
// so it can never become a motion problem for anyone.

struct KadePulseDot: View {
    var color: Color = .accentColor
    var diameter: CGFloat = 9
    /// Whether the pulse is "live" (animating). When false, or when reduced
    /// motion is on, it renders as a calm static dot.
    var active: Bool = true
    /// Session 21 (Kade: "if something is pulsing visually, we could get a
    /// matching little haptic that feels sensory cool. Nothing too
    /// obnoxious"). Opt-in: a soft haptic "heartbeat" fired in time with the
    /// visual pulse's expansion. Deliberately only turned on for SHORT-LIVED
    /// pulses (the "replying" wait), never a whole-call indicator, so it can
    /// never become a buzz-every-two-seconds-for-ten-minutes annoyance.
    /// Honours the Haptics switch and both reduced-motion signals.
    var haptic: Bool = false

    /// The full pulse period: one grow + shrink of the 0.85s easeInOut
    /// autoreversing animation below. The heartbeat fires once per period,
    /// offset to land on the expansion, so touch and sight pulse together.
    private let period: Double = 1.7

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var pulsing = false
    @State private var beat: Task<Void, Never>? = nil

    var body: some View {
        let reduce = systemReduceMotion || FeedbackPrefs.shared.forceReduceMotion
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .scaleEffect((active && !reduce && pulsing) ? 1.25 : 1.0)
            .opacity((active && !reduce && pulsing) ? 0.5 : 1.0)
            .animation(
                (active && !reduce)
                    ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear {
                if active && !reduce { pulsing = true }
                syncBeat(active: active, reduce: reduce)
            }
            .onChange(of: active) { _, now in
                pulsing = now && !reduce
                syncBeat(active: now, reduce: reduce)
            }
            .onDisappear { beat?.cancel(); beat = nil }
            .accessibilityHidden(true)
    }

    /// Start or stop the heartbeat to match the current pulse state. Only
    /// runs when haptics are wanted here, the pulse is active, motion is
    /// allowed, and the app-wide Haptics switch is on.
    private func syncBeat(active: Bool, reduce: Bool) {
        beat?.cancel(); beat = nil
        // Session 23: rhythmic beats are gated by BOTH the Haptics master
        // switch and the new "Pulse with the visuals" sub-switch.
        guard haptic, active, !reduce,
              UserDefaults.standard.bool(forKey: "kade.feedback.haptics"),
              UserDefaults.standard.bool(forKey: "kade.feedback.sensorySync") else { return }
        let period = self.period
        beat = Task { @MainActor in
            // Session 23: the beat grew up -- a real two-thump LUB-DUB
            // (KadeHaptics.pulseBeat, CoreHaptics with UIKit fallback)
            // once per visual period, landing on the pulse's peak. Touch
            // and sight breathe together, and it finally has the bass
            // Kade asked for.
            try? await Task.sleep(nanoseconds: UInt64(period / 2 * 1_000_000_000))
            while !Task.isCancelled {
                KadeHaptics.pulseBeat()
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
            }
        }
    }
}
