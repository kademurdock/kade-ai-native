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

    // Aug 6 2026 (Kade: "interesting hapteks to match visuals or something"):
    // the GAME TABLE vocabulary + message moments. Every Parlor sound cue
    // ([sound:card_deal] and kin) now has a felt twin, fired as the reply
    // lands — cards flick, dice rattle, chips knock, a battleship hit SLAMS,
    // the win fanfare rises in the hand. Built to her session-23 spec:
    // longer, harder, bassy. Same master Haptics switch; devices without a
    // Taptic Engine fall back to polite UIKit taps like everything else.
    /// Felt twin of the reply bloop — a soft double-knock, bass-forward.
    static func replyLanded() { play(pattern: .replyLanded) { UIImpactFeedbackGenerator(style: .soft).impactOccurred() } }
    /// Featherweight tick as a message leaves.
    static func sentTick()   { play(pattern: .sentTick)   { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) } }

    // ── PART 87 §2.5: TACTILE MESSAGE RHYTHM ────────────────────────────────
    //
    // "Distinct haptic patterns per event type so identity reaches the hand
    // before VoiceOver speaks." A notification arriving has always felt
    // identical whatever it was; now a message, a call, a reminder and an
    // alert each have their own shape, and the shapes are built to be told
    // apart by hand alone, not by being louder:
    //
    //   message   two even knocks, close together  (the spec's double-tap)
    //   call      two long bass rumbles, one second (the spec's long buzz)
    //   reminder  one knock that fades out
    //   alert     three quick sharp ticks
    //
    // ⚠️ THE HAPTICS SCAR IS RESPECTED BY LOCATION. Build 216 traced the
    // freeze era to `.sensoryFeedback` firing inside the SEND-COMMIT path;
    // the standing law is haptics on completed actions, never inside a
    // transcript mutation. These fire from AppDelegate when a push ARRIVES —
    // not from any SwiftUI body, not near a transcript commit, and they ride
    // the same next-main-queue-turn hop and the same Haptics switch as every
    // other haptic in the app.
    static func arrival(_ kind: KadeArrivalKind) {
        switch kind {
        case .message:
            play(pattern: .arrivalMessage) { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        case .call:
            play(pattern: .arrivalCall) { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        case .reminder:
            play(pattern: .arrivalReminder) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        case .alert:
            play(pattern: .arrivalAlert) { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
    }

    /// Map one Parlor sound-cue name to a felt pattern. Unknown cue names
    /// get a soft tick — never silence-by-crash, never a wrong big blast.
    static func gameCue(_ name: String) {
        let n = name.lowercased()
        let pattern: Pattern
        if n.hasPrefix("card_shuffle") { pattern = .cardShuffle }
        else if n.hasPrefix("card_slap") || n.hasPrefix("battleship_boom") { pattern = .boom }
        else if n.hasPrefix("card_") || n == "page_turn" { pattern = .cardFlick }
        else if n.hasPrefix("dice_") { pattern = .diceRoll }
        else if n.hasPrefix("chip_") || n.hasPrefix("bingo_") || n == "coin_flip" { pattern = .chipKnock }
        else if n == "win_fanfare" || n == "jackpot_win" || n == "coin_shower" { pattern = .winRise }
        else if n == "lose_trombone" || n == "draw_game" { pattern = .loseSlump }
        else if n == "wrong_buzz" { pattern = .buzz }
        else if n == "correct_ding" { pattern = .ding }
        else if n == "your_turn" { pattern = .yourTurn }
        else if n == "battleship_splash" { pattern = .splash }
        else if n == "timer_up" { pattern = .gong }
        else if n == "uno_sting" || n == "drumroll_short" { pattern = .sting }
        else { pattern = .sentTick }
        play(pattern: pattern) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    /// Parse a raw (unsanitized) reply for [sound:x] cues and fire their felt
    /// twins in reading order — staggered so they land as a little scene in
    /// the hand, capped so a cue-spammy reply can't turn the phone into a
    /// massage chair. Safe to call with any text; no cues = no-op.
    static func gameCues(from rawText: String) {
        guard UserDefaults.standard.bool(forKey: "kade.feedback.haptics") else { return }
        guard rawText.contains("[sound:") else { return }
        let regex = try? NSRegularExpression(pattern: "\\[sound:([a-z0-9_]+)\\]", options: [.caseInsensitive])
        guard let regex else { return }
        let range = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
        let names: [String] = regex.matches(in: rawText, range: range).prefix(4).compactMap { m in
            guard let r = Range(m.range(at: 1), in: rawText) else { return nil }
            return String(rawText[r])
        }
        for (i, name) in names.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * Double(i)) {
                gameCue(name)
            }
        }
    }

    private enum Pattern {
        case success, warning, error, tap, pulseBeat, press
        case replyLanded, sentTick
        case cardFlick, cardShuffle, diceRoll, chipKnock, winRise, loseSlump, buzz, ding, yourTurn, boom, splash, gong, sting
        case arrivalMessage, arrivalCall, arrivalReminder, arrivalAlert
    }

    /* ⭐ BUILD 216. Every haptic now lands on the NEXT main-queue turn, not
     * the one that asked for it. The 215 crash died inside a single SwiftUI
     * state-change turn -- `sendState = .sending` -- and this call was in it.
     * Hardware handshakes do not belong inside a view update: SwiftUI charges
     * the whole thing to the scene-update watchdog, which is exactly the
     * 0x8BADF00D she has been eating. One hop is imperceptible for touch (a
     * frame at most) and ordering is preserved, so nothing about how the app
     * FEELS changes -- only what the watchdog is holding the bag for. */
    private static func play(pattern: Pattern, fallback: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "kade.feedback.haptics") else { return }
        Task { @MainActor in
            if KadeHapticEngine.shared.play(events: events(for: pattern)) { return }
            fallback()
        }
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
        case .replyLanded:
            return [(0, 0, 0.75, 0.2), (0.11, 0, 1.0, 0.3), (0.2, 0.16, 0.55, 0.08)]
        case .sentTick:
            return [(0, 0, 0.6, 0.45)]
        case .cardFlick:
            return [(0, 0, 0.8, 0.7), (0.07, 0, 0.6, 0.5)]
        case .cardShuffle:
            return [(0, 0, 0.6, 0.6), (0.06, 0, 0.7, 0.55), (0.12, 0, 0.8, 0.5), (0.18, 0, 0.7, 0.45), (0.26, 0.14, 0.5, 0.2)]
        case .diceRoll:
            return [(0, 0, 0.9, 0.6), (0.08, 0, 0.75, 0.5), (0.17, 0, 0.6, 0.4), (0.27, 0, 0.5, 0.3), (0.36, 0.22, 0.65, 0.12)]
        case .chipKnock:
            return [(0, 0, 0.95, 0.35), (0.1, 0, 0.8, 0.3), (0.18, 0.18, 0.6, 0.1)]
        case .winRise:
            return [(0, 0, 0.6, 0.2), (0.12, 0, 0.8, 0.3), (0.24, 0, 1.0, 0.45), (0.34, 0.5, 0.95, 0.1)]
        case .loseSlump:
            return [(0, 0, 0.9, 0.4), (0.14, 0, 0.7, 0.25), (0.3, 0.45, 0.6, 0.05)]
        case .buzz:
            return [(0, 0.38, 1.0, 0.55)]
        case .ding:
            return [(0, 0, 0.9, 0.6), (0.09, 0.14, 0.6, 0.3)]
        case .yourTurn:
            return [(0, 0, 1.0, 0.3), (0.16, 0, 1.0, 0.3), (0.3, 0.2, 0.7, 0.1)]
        case .boom:
            return [(0, 0, 1.0, 0.4), (0.03, 0.55, 1.0, 0.05)]
        case .splash:
            return [(0, 0.42, 0.55, 0.08)]
        case .gong:
            return [(0, 0, 1.0, 0.25), (0.05, 0.6, 0.8, 0.05)]
        case .sting:
            return [(0, 0, 0.9, 0.65), (0.11, 0, 1.0, 0.7)]
        // Part 87 arrivals. Told apart by SHAPE, not by volume: two even
        // knocks, two long rumbles, one fading knock, three sharp ticks.
        case .arrivalMessage:
            return [(0, 0, 0.9, 0.35), (0.13, 0, 0.9, 0.35)]
        case .arrivalCall:
            return [(0, 0.5, 1.0, 0.05), (0.62, 0.5, 1.0, 0.05)]
        case .arrivalReminder:
            return [(0, 0, 0.85, 0.3), (0.1, 0.3, 0.55, 0.1)]
        case .arrivalAlert:
            return [(0, 0, 1.0, 0.7), (0.09, 0, 1.0, 0.7), (0.18, 0, 1.0, 0.7)]
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

    /* ⭐ BUILD 216 -- THE CALL THE 215 CRASH CORNERED (Aug 18 2026).
     *
     * `CHHapticEngine.start()` is a SYNCHRONOUS handshake with the haptic
     * server, and the media server it talks to is the same one VoiceOver is
     * using to speak. This engine was created and started LAZILY -- meaning
     * the first start of the app's life happened on whatever turn first
     * asked for a haptic, and for her that turn is the send: the crumb trail
     * on builds 214 and 215 both stop dead between `sendState = .sending`
     * and the next main-queue hop, with 17% application CPU across the hang
     * (blocked, not busy) and ~7.4s of CPU burned OUTSIDE the app. Worse,
     * `play` called `engine.start()` AGAIN on every single tick even when
     * the engine was already running -- a redundant synchronous handshake
     * per haptic, forever.
     *
     * So: start it ONCE, at launch, next to the earcon prewarm, off the send
     * path entirely. `playsHapticsOnly` tells CoreHaptics this engine will
     * never render audio, which keeps it out of the audio-session
     * negotiation that VoiceOver is already holding. `stoppedHandler` drops
     * our reference when the system stops the engine (audio-session churn
     * from a call or a recording does this), so the next play rebuilds it
     * rather than throwing forever. */
    func prewarm() {
        guard supported, engine == nil else { return }
        engine = Self.makeEngine { [weak self] in self?.engine = nil }
    }

    // `onDead` is @MainActor because it touches this class's isolated
    // `engine` -- CoreHaptics calls its handlers on its own queue, so the
    // hop through `Task { @MainActor in }` below is what makes that legal.
    private static func makeEngine(onDead: @escaping @MainActor () -> Void) -> CHHapticEngine? {
        guard let fresh = try? CHHapticEngine() else { return nil }
        fresh.playsHapticsOnly = true
        fresh.resetHandler = { Task { @MainActor in onDead() } }
        fresh.stoppedHandler = { _ in Task { @MainActor in onDead() } }
        guard (try? fresh.start()) != nil else { return nil }
        return fresh
    }

    func play(events specs: [(TimeInterval, TimeInterval, Float, Float)]) -> Bool {
        guard supported else { return false }
        do {
            // Build 216: normally already warm from launch. This lazy path
            // survives only for the case the system killed the engine
            // mid-session -- it is the exception now, not the send path.
            if engine == nil {
                engine = Self.makeEngine { [weak self] in self?.engine = nil }
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
            // Build 216: the second `engine.start()` that used to sit here
            // ran a full synchronous handshake on EVERY tick. The engine is
            // started once, at launch, in prewarm() above.
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

    /// July 22 2026 — Kade's OWN recordings take over where a bundled file
    /// exists (masters live in her folder's ui_sounds/; XcodeGen bundles
    /// anything dropped in Sources/ automatically). The synthesized glides
    /// above stay as the permanent fallback: a missing or undecodable file
    /// means the old sound, never accidental silence. Only the two chat
    /// moments have real recordings so far; action/error stay synth.
    fileprivate var bundleFile: (name: String, ext: String)? {
        switch self {
        case .messageSent:     return ("EarconSent", "mp3")
        case .messageReceived: return ("EarconReceived", "mp3")
        default:               return nil
        }
    }

    /// Per-file playback volume: her Sent master peaks hot (-4.7 dBFS), the
    /// reply cue is gentler. One constant each — retune by ear here.
    fileprivate var bundleVolume: Float {
        switch self {
        case .messageSent: return 0.6
        default:           return 0.9
        }
    }
}

@MainActor
final class Earcons {
    static let shared = Earcons()
    private init() {}

    private let sampleRate: Double = 44_100
    private var cache: [Earcon: Data] = [:]
    /// Build 216: one ready, already-`prepareToPlay()`d player per bundled
    /// earcon, built at launch. `prepareToPlay()` is the expensive half of
    /// starting a sound -- it allocates buffers and readies the audio
    /// hardware, and it was running on the send turn, right beside the
    /// haptic handshake the 215 crash cornered. Firing a warm player is a
    /// seek plus a play.
    private var readyPlayers: [Earcon: AVAudioPlayer] = [:]
    /// Keep players alive until they finish -- an AVAudioPlayer deallocated
    /// mid-play just stops. Small pool, pruned as clips end.
    private var players: [AVAudioPlayer] = []

    /// Synthesize every earcon once, off the main actor's hot path, so the
    /// first real play() is never a synthesis hitch. Called at launch.
    func prewarm() {
        for e in Earcon.allCases where cache[e] == nil {
            cache[e] = Self.renderWAV(segments: e.segments, amplitude: e.amplitude, sampleRate: sampleRate)
        }
        // Build 216: and the real recordings get their players built and
        // prepared here too, so no send ever pays for that again.
        for e in Earcon.allCases {
            guard readyPlayers[e] == nil, let file = e.bundleFile,
                  let url = Bundle.main.url(forResource: file.name, withExtension: file.ext),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = e.bundleVolume
            player.prepareToPlay()
            readyPlayers[e] = player
        }
    }

    /// Play an earcon, honouring the Sound effects switch. Safe to call from
    /// anywhere on the main actor; a no-op if sound is off or synthesis fails.
    /// Cache of the real recordings' bytes, loaded lazily per earcon.
    private var fileCache: [Earcon: Data] = [:]

    /* ⭐ BUILD 216. Same reasoning as KadeHaptics.play: the sound now starts
     * on the next main-queue turn instead of inside the SwiftUI update that
     * asked for it, so the scene-update watchdog is never holding an
     * AVAudioPlayer's hardware setup. Imperceptible for a send bloop. */
    func play(_ earcon: Earcon) {
        guard FeedbackPrefs.shared.soundEffects else { return }
        Task { @MainActor in self.fire(earcon) }
    }

    private func fire(_ earcon: Earcon) {
        // Build 216: warm player from prewarm() -- the whole point.
        if let ready = readyPlayers[earcon] {
            ready.currentTime = 0
            ready.play()
            return
        }
        // Real recording first (July 22 2026); the synth path below is the
        // fail-soft fallback and still owns every earcon with no file.
        if let file = earcon.bundleFile {
            if fileCache[earcon] == nil,
               let url = Bundle.main.url(forResource: file.name, withExtension: file.ext) {
                fileCache[earcon] = try? Data(contentsOf: url)
            }
            if let fileData = fileCache[earcon], let player = try? AVAudioPlayer(data: fileData) {
                player.volume = earcon.bundleVolume
                player.prepareToPlay()
                players.removeAll { !$0.isPlaying }
                players.append(player)
                player.play()
                return
            }
        }
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

    /// Session 23 (Kade: "the space between the send sound, and the
    /// thinking sound, is huge"): text chat had NO waiting sound at all —
    /// send bloop, then dead air for the whole generation (and on voice
    /// messages, the TTS fetch too) until the reply bloop. This is the
    /// chat lane's soft waiting loop: two gentle low ticks about once a
    /// second, quiet enough to sit under speech, looped by the player
    /// itself (numberOfLoops = -1) so it costs nothing per cycle. Started
    /// a breath after the send bloop (see ConversationDetailView's
    /// sendState watcher), stopped the moment the reply lands or the send
    /// fails. Same Sound-effects switch as every other earcon.
    private var waitingPlayer: AVAudioPlayer?
    private var waitingData: Data?

    func startWaitingLoop() {
        guard FeedbackPrefs.shared.soundEffects, waitingPlayer == nil else { return }
        // July 22 2026: Kade's bubbling Thinking loop (shipped pre-trimmed —
        // the raw master carries ~1.16s of MP3 encoder silence that made
        // every loop cycle hiccup, so the bundled WAV is the trimmed decode;
        // recipe in ui_sounds/README). Quiet enough to sit under speech and
        // VoiceOver. Synth ticks below remain the fail-soft fallback.
        if let url = Bundle.main.url(forResource: "EarconThinkingLoop", withExtension: "wav"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            // July 22: 0.55 -> 0.22. Aug 4 2026 (Kade: bubbles "quieter than the
            // received sound by quite a bit... turned up a bit"): 0.22 -> 0.4, to
            // match the web loop. Still under the received bloop.
            player.volume = 0.4
            player.prepareToPlay()
            player.play()
            waitingPlayer = player
            return
        }
        if waitingData == nil {
            // Two soft ticks (short falling glides) with REAL zero-sample
            // silence between and after — a 0 Hz "segment" through the
            // glide renderer would hold a DC value, not silence, and could
            // click at the joins. Each tick edge-fades inside
            // renderSamples, so the seams stay clean. Loop period ~1.1s,
            // low amplitude on purpose: it sits under speech.
            let tickA = Self.renderSamples(
                segments: [(880, 760, 0.045)], amplitude: 0.16, sampleRate: sampleRate
            )
            let tickB = Self.renderSamples(
                segments: [(760, 660, 0.045)], amplitude: 0.16, sampleRate: sampleRate
            )
            var samples: [Int16] = []
            samples.append(contentsOf: tickA)
            samples.append(contentsOf: [Int16](repeating: 0, count: Int(sampleRate * 0.12)))
            samples.append(contentsOf: tickB)
            samples.append(contentsOf: [Int16](repeating: 0, count: Int(sampleRate * 0.9)))
            waitingData = Self.encodeWAV(samples: samples, sampleRate: Int(sampleRate))
        }
        guard let data = waitingData, let player = try? AVAudioPlayer(data: data) else { return }
        player.numberOfLoops = -1
        player.volume = 0.9
        player.prepareToPlay()
        player.play()
        waitingPlayer = player
    }

    func stopWaitingLoop() {
        waitingPlayer?.stop()
        waitingPlayer = nil
    }

    /// Clubhouse room chimes (Aug 4 2026, Kade: "make it play the connect and
    /// disconnect chimes when people enter and leave clubhouse rooms. I still
    /// want it to announce, but I like the chime also.") Reuses the call
    /// connect/disconnect recordings; the PA announcement is separate and
    /// unaffected. Gated on the Sound-effects switch. Mixes into the room the
    /// same way the PA's TTS clips already do.
    private var chimeCache: [String: Data] = [:]
    func playRoomChime(join: Bool) {
        guard FeedbackPrefs.shared.soundEffects else { return }
        let name = join ? "CallConnected" : "CallDisconnected"
        if chimeCache[name] == nil,
           let url = Bundle.main.url(forResource: name, withExtension: "mp3") {
            chimeCache[name] = try? Data(contentsOf: url)
        }
        guard let data = chimeCache[name], let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.7
        player.prepareToPlay()
        players.removeAll { !$0.isPlaying }
        players.append(player)
        player.play()
    }

    /// July 24 2026 (Kade: the thinking loop "continues playing to the
    /// finish of the file instead of stopping when the bloop starts") --
    /// native twin of the web duck: dip the loop to silence UNDER the reply
    /// bloop (120ms fade), then -- when the wait continues into the TTS
    /// fetch -- ease back up to its original volume (350ms) once the bloop
    /// has had the floor (~1.1s). Full stop stays with the existing callers
    /// (voice starts / TTS fails / watchdog). Safe if the loop is already
    /// gone; the resume guards against a NEW loop instance.
    func duckWaitingLoop(resume: Bool) {
        guard let player = waitingPlayer else { return }
        let restoreVolume = player.volume
        player.setVolume(0.0, fadeDuration: 0.03)  // Aug 4: 0.12 -> 0.03, the louder 0.4 loop can't bleed under the reply bloop
        guard resume else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard let self, let p = self.waitingPlayer, p === player else { return }
            p.setVolume(restoreVolume, fadeDuration: 0.35)
        }
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
        encodeWAV(samples: renderSamples(segments: segments, amplitude: amplitude, sampleRate: sampleRate), sampleRate: Int(sampleRate))
    }

    private static func renderSamples(segments: [(Double, Double, Double)], amplitude: Float, sampleRate: Double) -> [Int16] {
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
        return samples
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
    /* ⭐ BUILD 217. VoiceOver stills the VISUAL but NOT the heartbeat, and the
     * split is the whole point. This dot's `.repeatForever` animation is
     * driven by `pulsing`, which `onAppear` sets DURING the commit that
     * inserts the row -- and every crash in the freeze hunt burned ~10.0s of
     * application CPU against a 10.00s watchdog allowance, i.e. a pegged core
     * for the entire window. Build 205 gated the thinking bubbles for exactly
     * this reason and called it "main-thread cost that its user cannot
     * perceive by any means"; this dot is `accessibilityHidden(true)` too, so
     * the same sentence applies word for word.
     *
     * The haptic heartbeat is a DIFFERENT question: she can feel that, she
     * asked for it, and it is hers to keep. So `stillVisual` gates the
     * animation and `reduce` alone still gates the beat. */
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var pulsing = false

    var body: some View {
        let reduce = systemReduceMotion || FeedbackPrefs.shared.forceReduceMotion
        let stillVisual = reduce || voiceOverOn
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .scaleEffect((active && !stillVisual && pulsing) ? 1.25 : 1.0)
            .opacity((active && !stillVisual && pulsing) ? 0.5 : 1.0)
            .animation(
                (active && !stillVisual)
                    ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear {
                if active && !stillVisual { pulsing = true }
            }
            .onChange(of: active) { _, now in
                pulsing = now && !stillVisual
            }
            /* ⭐⭐ BUILD 221 -- THE HEARTBEAT NO LONGER WRITES STATE INSIDE THE
             * COMMIT THAT INSERTS IT. This is the engine build 220's bisect
             * finally exposed.
             *
             * 220 added crumbs either side of every candidate and her trail
             * ran clean through ALL of them -- `send tapped`, `draft cleared`,
             * `optimistic row painted`, `focus anchored`, `send feedback
             * queued` -- and then died before `send feedback done` (a
             * `Task { @MainActor }`, so main never freed) and before `sending
             * state painted`. The composer teardown, the row insert and the
             * VoiceOver focus move are all EXONERATED by her own instrument.
             * What is left in that turn is the `replyingRow` insert, and this
             * dot goes in with it.
             *
             * The old `onAppear` called `syncBeat`, whose FIRST line was
             * `beat?.cancel(); beat = nil` -- an UNCONDITIONAL `@State` write,
             * executed before any guard, during the view-graph commit that
             * installs this row. A state write inside a commit schedules
             * another update, and `Task<Void, Never>?` is not Equatable so
             * SwiftUI cannot short-circuit it as a no-op. No toggle could stop
             * it either: the Haptics and "Pulse with the visuals" switches are
             * checked AFTER that line, so turning them off changed nothing.
             *
             * That is exactly what her 220 stack looks like: 27 frames, ZERO
             * recursion, leaf in AttributeGraph, under a CFRunLoop observer
             * rather than an UpdateCycle -- a flat loop re-servicing an update
             * queue that keeps refilling, burning 10.290s of application CPU
             * against a 10.00s allowance. 219's 91-frame, 59-SwiftUICore
             * triple-nested layout recursion is GONE (220 removed it); this
             * was the engine underneath it the whole time, and the layout
             * negotiation was only the amplifier.
             *
             * `.task(id:)` is the cure and it is smaller than the disease:
             * SwiftUI installs it AFTER the commit, owns its lifetime, and
             * cancels it on disappear and on any id change. `@State beat` is
             * deleted outright, so there is no state to write. Her heartbeat
             * is byte-for-byte the same rhythm -- same period, same offset
             * onto the pulse peak, same two-thump `KadeHaptics.pulseBeat`,
             * same two switches. Build 217 kept this dot in the tree on
             * purpose so she keeps the beat she asked for; that decision
             * stands, it just stopped costing a commit. */
            .task(id: "\(active)-\(reduce)-\(haptic)") {
                guard haptic, active, !reduce,
                      UserDefaults.standard.bool(forKey: "kade.feedback.haptics"),
                      UserDefaults.standard.bool(forKey: "kade.feedback.sensorySync") else { return }
                try? await Task.sleep(nanoseconds: UInt64(period / 2 * 1_000_000_000))
                while !Task.isCancelled {
                    KadeHaptics.pulseBeat()
                    try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
                }
            }
            .accessibilityHidden(true)
    }

    /// Start or stop the heartbeat to match the current pulse state. Only
    /// runs when haptics are wanted here, the pulse is active, motion is
    /// allowed, and the app-wide Haptics switch is on.
}
