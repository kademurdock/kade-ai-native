import Foundation

/// Nov 14 2026, her report: "when I go into an app conversation with someone,
/// voiceover on my phone gets quieter, and when I get into another app, it
/// goes back to being louder again", and while auditioning voices "it plays
/// the first few seconds of the clip audio ducked even though voiceover isn't
/// talking. But if I turn voiceover off, the clip audio plays normally."
///
/// What the app did: once anything had played, its audio session stayed
/// switched on for as long as the app was open, with nothing playing.
/// VoiceService switched it on before every clip and nothing switched it off,
/// and with streamed speech on, the streamed voice's engine kept running
/// (playing silence) after its first clip, so nobody could switch it off.
/// iOS treats an app with a switched-on session as the app that is playing
/// and mixes VoiceOver against it. In another app Kade-AI is suspended and its
/// session is off, which is why VoiceOver came back up there. An audition
/// starts right after VoiceOver has spoken (the new name on the wheel, a
/// button's new label, the delivery sentence); VoiceOver's Audio Ducking was
/// still holding the session that had been left on, so the clip started
/// ducked.
///
/// The rules, one state at a time (KadeAudioSession.swift applies them):
/// - idle: no session of the app's own. It is let go, and other audio is told
///   it may come back up, a moment after the last sound ends.
/// - playing (speech, auditions, samples): playback, default mode, mixes with
///   others. No voice processing; it never ducks anything.
/// - feedback (earcons, the thinking bubbles): ambient only when nothing else
///   has set the session up, so the ring switch still silences the bubbles
///   (her choice); otherwise the session that is already set.
/// - listening (a recording or dictation): play-and-record only while the
///   microphone is open, default mode, the hands-free Bluetooth profile so the
///   AirPods' own microphone is the one used (Amber's AirPods bug, Aug 13
///   2026), and the loudspeaker when there is no headset.
/// - call (a live voice call): the only voice processing (voiceChat), because
///   the character's voice would otherwise reach the microphone.
///   StreamingCallService keeps its own identical setup.
/// - face (a live video face, sighted accounts only, never under VoiceOver):
///   as playing, and kept while the page is up.
/// - backgroundListen (listen while made, the Library, a family story):
///   playback for spoken audio, not mixed, so the lock screen and headphone
///   buttons work and it carries on with the screen locked; let go after it.
///
/// Plain Foundation, so run-audio-session-tests.sh can test it without a phone.
/// Phone switch: KadeAppSwitches.audioSessionRelease
/// (UserDefaults kade.switch.audioSessionRelease = false puts back the old
/// session that stays on).
enum KadeAudioActivity: String, CaseIterable {
    case idle
    case playing
    case feedback
    case listening
    case call
    case face
    case backgroundListen
}

/// What the session should be in one state. The names follow AVAudioSession;
/// KadeAudioSession.swift turns them into the real values.
struct KadeAudioSessionPlan: Equatable {
    enum Category: String, CaseIterable {
        case ambient, soloAmbient, playback, record, playAndRecord, multiRoute
    }

    /// `standard` is AVAudioSession's `.default` mode.
    enum Mode: String, CaseIterable {
        case standard, spokenAudio, voicePrompt, moviePlayback
        case voiceChat, videoChat, gameChat, videoRecording, measurement
    }

    /// `allowBluetoothHFP` is AVAudioSession's `.allowBluetooth` (the
    /// hands-free profile: the headset's microphone, phone-call sound).
    enum Option: String, CaseIterable {
        case mixWithOthers, duckOthers, interruptSpokenAudioAndMixWithOthers
        case allowBluetoothHFP, allowBluetoothA2DP, allowAirPlay, defaultToSpeaker
    }

    var category: Category
    var mode: Mode
    var options: Set<Option>
    /// The session is switched on while in this state.
    var active: Bool
    /// When it is switched off, other audio (VoiceOver, a music app) is told
    /// it may come back up.
    var notifyOthersOnDeactivation: Bool

    /// Voice processing: the echo canceller, with its own gain control and
    /// ducking of every other sound.
    var voiceProcessing: Bool {
        mode == .voiceChat || mode == .videoChat || mode == .gameChat
    }

    /// Turns other audio down (or stops spoken audio) while it plays.
    var ducksOthers: Bool {
        options.contains(.duckOthers) || options.contains(.interruptSpokenAudioAndMixWithOthers)
    }

    /// Plays alongside other audio instead of stopping it.
    var mixes: Bool {
        category == .ambient || options.contains(.mixWithOthers) || ducksOthers
    }

    /// The microphone is open.
    var records: Bool {
        category == .playAndRecord || category == .record
    }
}

enum KadeAudioSessionPolicy {
    /// Seconds after the last sound ends before the session is let go. Long
    /// enough that the next sentence of a reply, or the reply after the
    /// received bloop, never makes it churn; short enough that VoiceOver is
    /// back to its own level before her next swipe.
    static let releaseDelay: TimeInterval = 1.5

    /// How long a clip has, once the session is set up for it, to report
    /// itself playing before the session may be let go anyway (a clip that
    /// never started must not leave the session on).
    static let startWindow: TimeInterval = 4

    /// A release that failed because something was still running is tried
    /// once more after this many seconds; after that the next sound to end
    /// tries again.
    static let retryDelay: TimeInterval = 3

    /// The longest a "short sound" holds the session by itself. Anything
    /// longer, or looping, holds it by name instead.
    static let longestShortSound: TimeInterval = 30

    static func plan(for activity: KadeAudioActivity) -> KadeAudioSessionPlan {
        switch activity {
        case .idle:
            // Off, with the category parked on mixing playback, so a sound
            // that forgets to ask still mixes and still uses the speaker.
            return KadeAudioSessionPlan(category: .playback, mode: .standard, options: [.mixWithOthers],
                                        active: false, notifyOthersOnDeactivation: true)
        case .playing, .face:
            return KadeAudioSessionPlan(category: .playback, mode: .standard, options: [.mixWithOthers],
                                        active: true, notifyOthersOnDeactivation: true)
        case .feedback:
            return KadeAudioSessionPlan(category: .ambient, mode: .standard, options: [],
                                        active: true, notifyOthersOnDeactivation: true)
        case .listening:
            return KadeAudioSessionPlan(category: .playAndRecord, mode: .standard,
                                        options: [.allowBluetoothHFP, .defaultToSpeaker],
                                        active: true, notifyOthersOnDeactivation: true)
        case .call:
            return KadeAudioSessionPlan(category: .playAndRecord, mode: .voiceChat,
                                        options: [.allowBluetoothHFP, .defaultToSpeaker],
                                        active: true, notifyOthersOnDeactivation: true)
        case .backgroundListen:
            return KadeAudioSessionPlan(category: .playback, mode: .spokenAudio, options: [],
                                        active: true, notifyOthersOnDeactivation: true)
        }
    }

    /// Earcons keep to whatever session is set up; only the untouched default
    /// becomes ambient (KadeFeedback's prepareFeedbackSession). nil = leave it.
    static func feedbackCategory(current: KadeAudioSessionPlan.Category?) -> KadeAudioSessionPlan.Category? {
        current == .soloAmbient ? .ambient : nil
    }

    /// Everything the release decision looks at, read at the moment it is made.
    struct Moment: Equatable {
        /// KadeAppSwitches.audioSessionRelease.
        var switchOn: Bool
        /// Nothing of the app's own is sounding or about to (KadeAudioHolds).
        var quiet: Bool
        /// A call, a room or a recording holds the microphone (KadeAudioLanes).
        var micHeld: Bool
        /// A live video face page is up (sighted accounts only).
        var liveFaceUp: Bool
        /// The session as it is set now; nil when it is something unknown.
        var category: KadeAudioSessionPlan.Category?
        var mode: KadeAudioSessionPlan.Mode?
    }

    enum Release: Equatable {
        case release
        case keep(String)
    }

    /// Whether to switch the app's session off now.
    static func release(_ moment: Moment) -> Release {
        guard moment.switchOn else { return .keep("the old behaviour is switched on") }
        guard !moment.micHeld else { return .keep("the microphone is in use") }
        guard moment.quiet else { return .keep("something is still sounding") }
        guard !moment.liveFaceUp else { return .keep("a live face is up") }
        guard let category = moment.category, let mode = moment.mode else {
            return .keep("a session this app does not know")
        }
        switch mode {
        case .spokenAudio, .moviePlayback:
            // A book, a film or listen-while-made owns it, with the lock
            // screen and headphone buttons; it hands it back when it stops.
            return .keep("a book or a film holds it")
        default:
            break
        }
        switch category {
        case .playback, .ambient, .soloAmbient, .playAndRecord:
            return .release
        case .record, .multiRoute:
            return .keep("a session this app does not use")
        }
    }

    /// After letting go: the state whose category the next sound starts
    /// from. A two-way session left behind with nobody holding the microphone
    /// goes back to playback, so nothing plays from the ear speaker; anything
    /// else is left as it is (ambient keeps the ring switch on the bubbles).
    static func parkedActivity(after category: KadeAudioSessionPlan.Category?) -> KadeAudioActivity? {
        category == .playAndRecord ? .idle : nil
    }
}

/// Who is sounding right now, as KadeAudioSession counts it. Plain Swift so
/// the bookkeeping is tested. Times are seconds on one steady clock (the
/// phone's uptime).
struct KadeAudioHolds: Equatable {
    /// Things that sound until they say they are done: a voice, the thinking
    /// bubbles, a screen with its own loops.
    private(set) var holders: Set<String> = []
    /// Short sounds that end by themselves (an earcon) are over by this time.
    private(set) var quietAt: TimeInterval = 0
    /// A clip the session was just set up for has until this time to report
    /// itself playing (then it holds by name), or to be stopped.
    private(set) var startingUntil: TimeInterval = 0

    /// True when `who` was not already holding.
    @discardableResult
    mutating func hold(_ who: String) -> Bool {
        holders.insert(who).inserted
    }

    /// True when `who` was holding.
    @discardableResult
    mutating func letGo(_ who: String) -> Bool {
        holders.remove(who) != nil
    }

    /// A sound of `seconds` started at `now`.
    mutating func shortSound(now: TimeInterval, seconds: TimeInterval) {
        let length = min(max(0, seconds), KadeAudioSessionPolicy.longestShortSound)
        quietAt = max(quietAt, now + length)
    }

    /// The session was just set up for a clip at `now`.
    mutating func starting(now: TimeInterval) {
        startingUntil = max(startingUntil, now + KadeAudioSessionPolicy.startWindow)
    }

    /// The clip reported itself playing, or was stopped: nothing is starting.
    mutating func settled() {
        startingUntil = 0
    }

    /// Nothing holds the session, every short sound is over and no clip is
    /// still starting.
    func isQuiet(now: TimeInterval) -> Bool {
        holders.isEmpty && now >= quietAt && now >= startingUntil
    }

    /// Seconds from `now` until the session may be let go, if nothing else
    /// starts: the rest of any short sound or start, then the release delay.
    func releaseDelay(now: TimeInterval) -> TimeInterval {
        max(0, max(quietAt, startingUntil) - now) + KadeAudioSessionPolicy.releaseDelay
    }
}
