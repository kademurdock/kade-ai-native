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
/// ducked. (Not proven on her phone: VoiceOver's own "When Speaking" ducking
/// is known to move VoiceOver's level by itself on some phones.)
///
/// Nov 14 2026, the review of that fix (each point is a rule below):
/// - Switching a session off while any of the app's players is running or
///   paused stops that player (Apple: the session goes off anyway and the
///   call reports "busy"). So nothing may be let go underneath a sound the
///   keeper does not know about: every player in the app reports to it
///   (AudioSessionTests checks the source for players nobody registered).
/// - A paused voice still holds the session: letting go under a paused
///   streamed clip stopped its engine, and the rest of the reply was lost or
///   the queue stalled.
/// - A book, a film, a family story and listen-while-made own the session's
///   category while they are open and hold it while they play. One closing
///   never changes the category under another, and letting go after them
///   does not tell other apps (a podcast they stopped) to start by themselves.
/// - An audition started by a swipe VoiceOver reads out waits until
///   VoiceOver has had time to say the name.
///
/// The rules, one state at a time (KadeAudioSession.swift applies them):
/// - idle: no session of the app's own. It is let go a moment after the last
///   sound ends, with the category parked on mixing playback.
/// - playing (speech, auditions, samples): playback, default mode, mixes with
///   others. No voice processing; it never ducks anything.
/// - feedback (earcons, the thinking bubbles): ambient only when nothing else
///   has set the session up, so the ring switch still silences the bubbles
///   (her choice); otherwise the session that is already set
///   (KadeFeedback's prepareFeedbackSession, checked against this plan).
/// - listening (a recording or dictation): play-and-record only while the
///   microphone is open, default mode, the hands-free Bluetooth profile so the
///   AirPods' own microphone is the one used (Amber's AirPods bug, Aug 13
///   2026), and the loudspeaker when there is no headset.
/// - call (a live voice call): the only voice processing (voiceChat), because
///   the character's voice would otherwise reach the microphone.
///   StreamingCallService keeps its own setup, checked against this plan.
/// - backgroundListen (listen while made, the Library, a family story):
///   playback for spoken audio, not mixed, so the lock screen and headphone
///   buttons work and it carries on with the screen locked.
/// - film (a described video): the same for a film, in movie playback.
/// A live video face (sighted accounts only) plays through its own web page;
/// the session is never let go while its page is up.
///
/// Plain Foundation, so run-audio-session-tests.sh can test it without a phone.
/// Phone switch: Settings > Troubleshooting > "Let go of audio when quiet"
/// (UserDefaults kade.switch.audioSessionRelease; off puts back the old
/// session that stays on).
enum KadeAudioActivity: String, CaseIterable {
    case idle
    case playing
    case feedback
    case listening
    case call
    case backgroundListen
    case film
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
    /// When it is switched off after this state, other apps it stopped (a
    /// music or podcast app) are told they may start again by themselves.
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

    /// The longest a "short sound" (an earcon, a chime) holds the session by
    /// itself. Anything longer, or looping, holds it by name instead.
    static let longestShortSound: TimeInterval = 30

    /// The longest a timed hold (a sound whose end the app is not told about,
    /// such as a ringtone preview) keeps the session by itself.
    static let longestTimedHold: TimeInterval = 300

    /// An audition started by a swipe that VoiceOver reads out (the voice
    /// wheel) starts no sooner than this after the swipe, so it does not
    /// begin under VoiceOver's words and their duck.
    static let voiceOverSettle: TimeInterval = 1.5

    static func plan(for activity: KadeAudioActivity) -> KadeAudioSessionPlan {
        switch activity {
        case .idle:
            // Off, with the category parked on mixing playback, so a sound
            // that forgets to ask still mixes and still uses the speaker.
            return KadeAudioSessionPlan(category: .playback, mode: .standard, options: [.mixWithOthers],
                                        active: false, notifyOthersOnDeactivation: true)
        case .playing:
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
            // Before Nov 14 these never switched the session off, so a
            // podcast they stopped stayed stopped; it still does.
            return KadeAudioSessionPlan(category: .playback, mode: .spokenAudio, options: [],
                                        active: true, notifyOthersOnDeactivation: false)
        case .film:
            return KadeAudioSessionPlan(category: .playback, mode: .moviePlayback, options: [],
                                        active: true, notifyOthersOnDeactivation: false)
        }
    }

    /// Earcons keep to whatever session is set up; only the untouched default
    /// becomes ambient (KadeFeedback's prepareFeedbackSession). nil = leave it.
    static func feedbackCategory(current: KadeAudioSessionPlan.Category?) -> KadeAudioSessionPlan.Category? {
        current == .soloAmbient ? .ambient : nil
    }

    /// The speech floor (KadeSpeechFloor): VoiceOver's own announcements
    /// wait while a voice is audible. A paused clip is silent, so it gives
    /// the floor back.
    static func voiceFloorBusy(speaking: Bool, clipOnDeck: Bool, paused: Bool) -> Bool {
        (speaking || clipOnDeck) && !paused
    }

    /// The session: a voice holds it while it speaks or has a clip on deck,
    /// paused or not. Letting go under a paused streamed clip stopped its
    /// engine (the rest of the sentence lost, or the queue stuck behind a
    /// clip that never finished), and a paused player may be stopped too.
    static func voiceHolds(speaking: Bool, clipOnDeck: Bool, paused: Bool) -> Bool {
        speaking || clipOnDeck
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
            // A second guard behind the owners' own holds: a book, a film or
            // listen-while-made set this mode and hand it back when they stop.
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

    /// Letting go tells other apps they may start again, unless a book, a
    /// film, a family story or listen-while-made took the session since the
    /// last time it was let go: those stopped other apps' audio on purpose,
    /// and before Nov 14 nothing told those apps to start by themselves.
    static func notifyOthers(ownerTookOver: Bool) -> Bool {
        !ownerTookOver
    }

    /// When an audition may start: a swipe VoiceOver reads out (`voiceOver`)
    /// waits `voiceOverSettle` from the moment she landed; without VoiceOver
    /// it starts as soon as it is fetched (nil).
    static func auditionNotBefore(landedAt: TimeInterval, voiceOver: Bool) -> TimeInterval? {
        voiceOver ? landedAt + voiceOverSettle : nil
    }

    /// Seconds still to wait at `now` before an audition with that start
    /// time plays. Never more than `voiceOverSettle`, whatever the clocks say.
    static func auditionWait(now: TimeInterval, notBefore: TimeInterval?) -> TimeInterval {
        guard let notBefore else { return 0 }
        return min(voiceOverSettle, max(0, notBefore - now))
    }
}

/// Who is sounding right now, as KadeAudioSession counts it. Plain Swift so
/// the bookkeeping is tested. Times are seconds on one steady clock (the
/// phone's uptime).
struct KadeAudioHolds: Equatable {
    /// Things that sound until they say they are done: a voice, the thinking
    /// bubbles, a player sheet, a book while it plays.
    private(set) var holders: Set<String> = []
    /// Sounds that end by themselves at a known time unless they let go first
    /// (a ringtone preview), by name.
    private(set) var timed: [String: TimeInterval] = [:]
    /// Short sounds that end by themselves (an earcon) are over by this time.
    private(set) var quietAt: TimeInterval = 0
    /// A clip the session was just set up for has until this time to report
    /// itself playing, or to be stopped; one window per voice.
    private(set) var startWindows: [String: TimeInterval] = [:]
    /// A book, a film, a family story or listen-while-made, while open: they
    /// own the session's category (spoken audio or movie playback).
    private(set) var owners: Set<String> = []
    /// An owner took the session since it was last let go.
    private(set) var ownerTookOver = false

    /// True when `who` was not already holding.
    @discardableResult
    mutating func hold(_ who: String) -> Bool {
        holders.insert(who).inserted
    }

    /// `who` sounds for `seconds` from `now` and then stops by itself, unless
    /// it lets go first. A new one under the same name replaces the old.
    mutating func hold(_ who: String, now: TimeInterval, seconds: TimeInterval) {
        let length = min(max(0, seconds), KadeAudioSessionPolicy.longestTimedHold)
        timed[who] = now + length
    }

    /// True when `who` was holding, by name or for a time.
    @discardableResult
    mutating func letGo(_ who: String) -> Bool {
        let named = holders.remove(who) != nil
        let timedOne = timed.removeValue(forKey: who) != nil
        return named || timedOne
    }

    /// `who` takes the session as its own (not mixed, the lock screen),
    /// stopping other apps' audio. Called each time it switches it on.
    mutating func take(_ who: String) {
        owners.insert(who)
        ownerTookOver = true
    }

    /// `who` hands the session back and stops holding it. True when no other
    /// owner is left, so the category may go back to the app's usual one.
    @discardableResult
    mutating func handBack(_ who: String) -> Bool {
        owners.remove(who)
        letGo(who)
        return owners.isEmpty
    }

    /// The session was let go: the next owner takes it afresh.
    mutating func released() {
        ownerTookOver = false
    }

    /// A sound of `seconds` started at `now`.
    mutating func shortSound(now: TimeInterval, seconds: TimeInterval) {
        let length = min(max(0, seconds), KadeAudioSessionPolicy.longestShortSound)
        quietAt = max(quietAt, now + length)
    }

    /// The session was just set up at `now` for a clip of `who`'s.
    mutating func starting(_ who: String, now: TimeInterval) {
        startWindows[who] = now + KadeAudioSessionPolicy.startWindow
    }

    /// `who`'s clip reported itself playing, will not play, or was stopped.
    mutating func settled(_ who: String) {
        startWindows.removeValue(forKey: who)
    }

    /// Forgets timed holds and start windows that are over.
    mutating func prune(now: TimeInterval) {
        timed = timed.filter { $0.value > now }
        startWindows = startWindows.filter { $0.value > now }
    }

    /// Nothing holds the session, every short or timed sound is over and no
    /// clip is still starting.
    func isQuiet(now: TimeInterval) -> Bool {
        holders.isEmpty && now >= quietAt
            && timed.values.allSatisfy { now >= $0 }
            && startWindows.values.allSatisfy { now >= $0 }
    }

    /// When the last thing that ends by itself (a short sound, a timed hold,
    /// a clip's start window) is over.
    var lastEnd: TimeInterval {
        max(quietAt, timed.values.max() ?? 0, startWindows.values.max() ?? 0)
    }

    /// Seconds from `now` until the session may be let go, if nothing else
    /// starts: the rest of anything that ends by itself, then the release delay.
    func releaseDelay(now: TimeInterval) -> TimeInterval {
        max(0, lastEnd - now) + KadeAudioSessionPolicy.releaseDelay
    }

    /// After a release that had to wait because things were not quiet yet:
    /// seconds until it is worth asking again, or nil when a holder by name
    /// will ask again itself when it lets go.
    func nextCheck(now: TimeInterval) -> TimeInterval? {
        holders.isEmpty ? releaseDelay(now: now) : nil
    }
}
