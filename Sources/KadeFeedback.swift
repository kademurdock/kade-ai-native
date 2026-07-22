import SwiftUI
import UIKit
import AVFoundation

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
    static func success() { fire { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func warning() { fire { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }
    static func error()   { fire { UINotificationFeedbackGenerator().notificationOccurred(.error) } }
    static func tap()     { fire { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    /// The exact soft beat KadePulseDot's heartbeat uses (style .soft,
    /// intensity 0.55) -- exists so the Settings audition list can let
    /// someone FEEL the pulse rhythm's single beat before deciding whether
    /// to keep "Pulse with the visuals" on.
    static func pulseBeat() { fire { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.55) } }
    /// Medium impact for the app's one deliberately big action (starting a
    /// Spotter call). Everything else stays light -- "lots of hapteks"
    /// per Kade, but graded, never uniform thumping.
    static func press()   { fire { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    private static func fire(_ body: () -> Void) {
        guard UserDefaults.standard.bool(forKey: "kade.feedback.haptics") else { return }
        body()
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

    /// (frequencyHz, durationSeconds) note sequence. Kept short and gentle --
    /// rising pairs read as "good/forward", a falling pair reads as "problem".
    fileprivate var notes: [(Double, Double)] {
        switch self {
        case .messageSent:     return [(659.25, 0.055)]                    // E5 tick up
        case .messageReceived: return [(880.0, 0.070), (1318.51, 0.090)]  // A5 -> E6, reply landed
        case .actionStart:     return [(392.0, 0.060)]                    // G4, quiet "working"
        case .actionDone:      return [(587.33, 0.070), (880.0, 0.090)]   // D5 -> A5, done
        case .error:           return [(440.0, 0.100), (349.23, 0.130)]   // A4 -> F4, gentle fall
        }
    }

    fileprivate var amplitude: Float {
        switch self {
        case .error: return 0.18
        default:     return 0.22
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
            cache[e] = Self.renderWAV(notes: e.notes, amplitude: e.amplitude, sampleRate: sampleRate)
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
            let rendered = Self.renderWAV(notes: earcon.notes, amplitude: earcon.amplitude, sampleRate: sampleRate)
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

    private static func renderWAV(notes: [(Double, Double)], amplitude: Float, sampleRate: Double) -> Data {
        var samples: [Int16] = []
        let fadeSeconds = 0.008
        let fadeLen = Int(sampleRate * fadeSeconds)
        for (freq, dur) in notes {
            let count = max(1, Int(sampleRate * dur))
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let raw = sin(2.0 * Double.pi * freq * t)
                // Short linear fade in/out so blips don't click.
                let fade = Double(min(min(i, count - i), fadeLen)) / Double(max(1, fadeLen))
                let v = Float(raw) * amplitude * Float(min(1.0, fade))
                samples.append(Int16(max(-1.0, min(1.0, v)) * 32767.0))
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
            let generator = UIImpactFeedbackGenerator(style: .soft)
            // Land the first beat on the pulse's peak (~half a period in),
            // then one per period so touch tracks sight.
            try? await Task.sleep(nanoseconds: UInt64(period / 2 * 1_000_000_000))
            while !Task.isCancelled {
                generator.prepare()
                generator.impactOccurred(intensity: 0.55)
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
            }
        }
    }
}
