import Foundation

// Nov 14 2026: the app's audio-session rules (KadeAudioSessionPolicy and
// KadeAudioHolds), and source checks that keep the app to them. Her report:
// VoiceOver quieter inside a conversation and louder in any other app, and an
// audition's first seconds ducked. Pure Foundation; no audio is played and no
// session is touched. The source checks read Sources/ under the folder given
// as the first argument (run-audio-session-tests.sh passes the repository).

var count = 0
func check(_ ok: Bool, _ label: String) {
    if !ok { print("FAILED: \(label)"); exit(1) }
    count += 1
}

typealias Policy = KadeAudioSessionPolicy
typealias Plan = KadeAudioSessionPlan
typealias Moment = KadeAudioSessionPolicy.Moment

// --- what each state asks the session for ---
check(KadeAudioActivity.allCases.count == 7,
      "seven states: idle, playing, feedback, listening, call, background listen, film")

do {
    let idle = Policy.plan(for: .idle)
    check(!idle.active, "idle: the app holds no session")
    check(idle.notifyOthersOnDeactivation, "idle: letting go tells other audio it may come back up")
    check(idle.category == .playback && idle.mode == .standard && idle.options == [.mixWithOthers],
          "idle parks on mixing playback, so a sound that forgets to ask still mixes and uses the speaker")
}

do {
    let playing = Policy.plan(for: .playing)
    check(playing.active, "playing: switched on")
    check(playing.category == .playback && playing.mode == .standard, "playing: playback, default mode")
    check(playing.options == [.mixWithOthers], "playing: mixes with others and nothing else")
    check(playing.mixes, "playing mixes with VoiceOver and music")
    check(!playing.ducksOthers, "playing never ducks VoiceOver")
    check(!playing.voiceProcessing, "playing has no voice processing")
    check(!playing.records, "playing opens no microphone")
}

do {
    let feedback = Policy.plan(for: .feedback)
    check(feedback.category == .ambient && feedback.mode == .standard && feedback.options.isEmpty,
          "earcons: ambient, so the ring switch still silences the bubbles")
    check(feedback.mixes && !feedback.ducksOthers && !feedback.voiceProcessing && !feedback.records,
          "earcons mix, never duck, no voice processing, no microphone")
    check(Policy.feedbackCategory(current: .soloAmbient) == .ambient, "untouched session: earcons make it ambient")
    check(Policy.feedbackCategory(current: .playback) == nil, "a session already set up is left as it is for an earcon")
    check(Policy.feedbackCategory(current: .playAndRecord) == nil, "an earcon never changes a call's or a recording's session")
    check(Policy.feedbackCategory(current: nil) == nil, "an unknown session is left alone")
}

do {
    let listening = Policy.plan(for: .listening)
    check(listening.category == .playAndRecord && listening.records, "listening: play-and-record, the microphone open")
    check(listening.mode == .standard && !listening.voiceProcessing,
          "listening: default mode named outright, so no call mode carries voice processing into a recording")
    check(listening.options.contains(.allowBluetoothHFP), "listening: the AirPods' own microphone (Amber's AirPods bug)")
    check(listening.options.contains(.defaultToSpeaker), "listening: the loudspeaker, not the ear speaker, without a headset")
    check(listening.options == [.allowBluetoothHFP, .defaultToSpeaker], "listening: exactly the recording lane's two options")
    check(!listening.ducksOthers && !listening.mixes, "listening neither ducks nor mixes")
}

do {
    let call = Policy.plan(for: .call)
    check(call.category == .playAndRecord && call.mode == .voiceChat,
          "call: play-and-record in voiceChat, as StreamingCallService sets it")
    check(call.voiceProcessing, "call: voice processing, so the character's voice is not heard by the microphone")
    check(call.options == [.allowBluetoothHFP, .defaultToSpeaker], "call: the headset or the loudspeaker, as before")
    check(!call.ducksOthers, "call: never asks to duck others itself")
}

do {
    let listen = Policy.plan(for: .backgroundListen)
    check(listen.category == .playback && listen.mode == .spokenAudio && listen.options.isEmpty,
          "background listen: spoken-audio playback, not mixed (lock screen and headphone buttons, screen locked)")
    check(!listen.mixes && !listen.ducksOthers && !listen.voiceProcessing && !listen.records,
          "background listen: no ducking, no voice processing, no microphone")
    check(!listen.notifyOthersOnDeactivation,
          "background listen: letting go afterwards does not wake a podcast it stopped (as before Nov 14)")
}

do {
    let film = Policy.plan(for: .film)
    check(film.category == .playback && film.mode == .moviePlayback && film.options.isEmpty,
          "film: movie playback, not mixed (the lock screen and headphone buttons)")
    check(!film.mixes && !film.ducksOthers && !film.voiceProcessing && !film.records,
          "film: no ducking, no voice processing, no microphone")
    check(!film.notifyOthersOnDeactivation, "film: letting go afterwards does not wake a podcast it stopped")
}

for activity in KadeAudioActivity.allCases {
    let plan = Policy.plan(for: activity)
    check(!plan.ducksOthers, "\(activity.rawValue): never ducks VoiceOver")
    check(plan.voiceProcessing == (activity == .call), "\(activity.rawValue): voice processing only on a call")
    check(plan.records == (activity == .listening || activity == .call), "\(activity.rawValue): a microphone only while listening or on a call")
    check(plan.active == (activity != .idle), "\(activity.rawValue): switched on unless idle")
    check(plan.notifyOthersOnDeactivation == (plan.mixes || plan.records),
          "\(activity.rawValue): only a not-mixed book or film keeps quiet when it lets go")
    check(!plan.options.contains(.allowBluetoothHFP) || plan.records,
          "\(activity.rawValue): the hands-free Bluetooth profile only with a microphone open")
}

// --- when the session is let go ---
let quietChat = Moment(switchOn: true, quiet: true, micHeld: false, liveFaceUp: false,
                       category: .playback, mode: .standard)
check(Policy.release(quietChat) == .release, "a quiet chat lets the session go (VoiceOver back to its own level)")
do {
    var m = quietChat; m.switchOn = false
    check(Policy.release(m) != .release, "the phone switch off keeps the old session that stays on")
    m = quietChat; m.quiet = false
    check(Policy.release(m) != .release, "never while a voice, the bubbles or an earcon still sounds")
    m = quietChat; m.micHeld = true
    check(Policy.release(m) != .release, "never under a call, a room or a recording")
    m = quietChat; m.liveFaceUp = true
    check(Policy.release(m) != .release, "never while a live face page is up")
    m = quietChat; m.mode = .spokenAudio
    check(Policy.release(m) != .release, "never under a book, a family story or listen-while-made")
    m = quietChat; m.mode = .moviePlayback
    check(Policy.release(m) != .release, "never under a described film")
    m = quietChat; m.category = .ambient
    check(Policy.release(m) == .release, "earcons alone: let go")
    m = quietChat; m.category = .soloAmbient
    check(Policy.release(m) == .release, "an untouched session that something switched on: let go")
    m = quietChat; m.category = .playAndRecord; m.mode = .voiceChat
    check(Policy.release(m) == .release, "a two-way session left behind with nobody on the microphone: let go")
    m = quietChat; m.category = .record
    check(Policy.release(m) != .release, "a session this app never uses is left alone")
    m = quietChat; m.category = nil
    check(Policy.release(m) != .release, "an unknown category is left alone")
    m = quietChat; m.mode = nil
    check(Policy.release(m) != .release, "an unknown mode is left alone")
}
check(Policy.parkedActivity(after: .playAndRecord) == .idle, "a leftover two-way session is parked on playback after letting go")
check(Policy.parkedActivity(after: .playback) == nil, "playback is left as it is")
check(Policy.parkedActivity(after: .ambient) == nil, "ambient is left as it is (the ring switch keeps silencing the bubbles)")
check(Policy.parkedActivity(after: nil) == nil, "nothing known, nothing parked")

check(Policy.notifyOthers(ownerTookOver: false), "after mixing sounds only, letting go tells the others (nothing was stopped)")
check(!Policy.notifyOthers(ownerTookOver: true), "after a book, a film, a story or listen-while-made, it does not")

check(Policy.releaseDelay >= 0.5 && Policy.releaseDelay <= 3, "let go within a few seconds, never between two sentences")
check(Policy.startWindow >= 2 && Policy.startWindow <= 10, "a clip has a few seconds to start before the session may go")
check(Policy.longestShortSound >= 5, "an earcon or a tone always fits a short sound")
check(Policy.longestTimedHold >= 120, "a full-length ringtone preview (about a minute) fits a timed hold")
check(Policy.voiceOverSettle >= 1 && Policy.voiceOverSettle <= 2.5,
      "an audition after a swipe waits for VoiceOver's name, but never long")

// --- a voice: the speech floor and the session are different flags ---
check(Policy.voiceFloorBusy(speaking: true, clipOnDeck: true, paused: false), "a voice speaking holds the floor")
check(!Policy.voiceFloorBusy(speaking: true, clipOnDeck: true, paused: true), "a paused voice gives the floor back (VoiceOver may talk)")
check(Policy.voiceHolds(speaking: true, clipOnDeck: true, paused: true),
      "a paused voice still holds the session: no release under a paused streamed clip")
check(Policy.voiceHolds(speaking: false, clipOnDeck: true, paused: true), "a paused audition (no queue) still holds it")
check(Policy.voiceHolds(speaking: true, clipOnDeck: false, paused: false), "a voice fetching its next sentence holds it")
check(!Policy.voiceHolds(speaking: false, clipOnDeck: false, paused: false), "a voice with nothing at all lets go")
check(!Policy.voiceHolds(speaking: false, clipOnDeck: false, paused: true), "a stale paused flag with no clip lets go")
for speaking in [false, true] {
    for clip in [false, true] {
        for paused in [false, true] {
            check(!Policy.voiceFloorBusy(speaking: speaking, clipOnDeck: clip, paused: paused)
                  || Policy.voiceHolds(speaking: speaking, clipOnDeck: clip, paused: paused),
                  "speaking \(speaking), clip \(clip), paused \(paused): whatever holds the floor holds the session")
        }
    }
}

// --- the bookkeeping ---
do {
    var holds = KadeAudioHolds()
    check(holds.isQuiet(now: 0), "nothing has played: quiet")
    check(holds.hold("voice A"), "a voice starts: it holds")
    check(!holds.hold("voice A"), "holding twice is one hold")
    check(!holds.isQuiet(now: 100), "a holder keeps it however long it plays")
    holds.hold("the thinking bubbles")
    check(holds.letGo("voice A"), "the voice stops")
    check(!holds.isQuiet(now: 100), "the bubbles still hold it")
    check(holds.letGo("the thinking bubbles"), "the bubbles stop")
    check(!holds.letGo("the thinking bubbles"), "letting go twice is harmless")
    check(holds.isQuiet(now: 100), "everything stopped: quiet")
    check(holds.releaseDelay(now: 100) == Policy.releaseDelay, "then let go after the release delay")
}

do {
    var holds = KadeAudioHolds()
    holds.shortSound(now: 10, seconds: 0.4)
    check(!holds.isQuiet(now: 10.2), "an earcon holds it while it sounds")
    check(holds.isQuiet(now: 10.4), "and not after it ends")
    check(abs(holds.releaseDelay(now: 10) - (0.4 + Policy.releaseDelay)) < 0.0001, "let go the release delay after the earcon ends")
    holds.shortSound(now: 10.1, seconds: 0.1)
    check(!holds.isQuiet(now: 10.3), "a shorter earcon on top never shortens the first one")
    holds.shortSound(now: 20, seconds: 9_999)
    check(holds.isQuiet(now: 20 + Policy.longestShortSound), "a runaway length is capped")
    holds.shortSound(now: 100, seconds: -5)
    check(holds.isQuiet(now: 100), "a negative length counts as none")
}

do {
    var holds = KadeAudioHolds()
    holds.starting("voice A", now: 50)
    check(!holds.isQuiet(now: 51), "a clip being set up holds it for the start window")
    holds.settled("voice A")
    check(holds.isQuiet(now: 51), "once the clip reports itself (or is stopped) its window is over")
    holds.starting("voice A", now: 60)
    check(holds.isQuiet(now: 60 + Policy.startWindow), "a clip that never started does not keep the session on")
    holds.starting("voice A", now: 70)
    holds.starting("the picker's voice", now: 70.5)
    holds.settled("voice A")
    check(!holds.isQuiet(now: 71), "one voice's clip being heard never ends another voice's start window")
    holds.settled("the picker's voice")
    check(holds.isQuiet(now: 71), "both settled: quiet")
}

// A short last sentence: the session goes 1.5 s after it, not up to 5.5 s.
do {
    var holds = KadeAudioHolds()
    let voice = "a voice A"
    holds.hold(voice)                                    // the queue starts speaking
    for start in [0.0, 5.0, 10.0] {                      // three sentences, the last 1 s long
        holds.starting(voice, now: start)                // the session set up for it
        holds.settled(voice)                             // heard (onPlaybackStarted, confirmBufferedStart)
    }
    holds.letGo(voice)                                   // the last one ends at 11
    check(abs(holds.releaseDelay(now: 11) - Policy.releaseDelay) < 0.0001,
          "a short last sentence: let go the release delay after it, the start window closed when it was heard")
}

// A ringtone preview: a timed hold, past the short-sound cap.
do {
    var holds = KadeAudioHolds()
    holds.hold("a ringtone preview", now: 0, seconds: 58)
    check(!holds.isQuiet(now: 40), "a full-length preview holds the session past the 30 s short-sound cap")
    check(holds.isQuiet(now: 58), "and lets it go when it ends")
    check(abs(holds.releaseDelay(now: 10) - (48 + Policy.releaseDelay)) < 0.0001, "the release waits for the preview's end")
    check(holds.letGo("a ringtone preview"), "Stop preview ends the hold early")
    check(holds.isQuiet(now: 10), "stopped: quiet")
    holds.hold("a ringtone preview", now: 0, seconds: 99_999)
    check(holds.isQuiet(now: Policy.longestTimedHold), "a runaway length is capped")
    holds.hold("a ringtone preview", now: 0, seconds: 50)
    holds.hold("a ringtone preview", now: 10, seconds: 5)
    check(holds.isQuiet(now: 15), "a new preview under the same name replaces the old one (the old one was stopped)")
    holds.starting("voice A", now: 0)
    holds.prune(now: 1_000)
    check(holds.timed.isEmpty && holds.startWindows.isEmpty, "finished timed sounds and start windows are forgotten")
}

// Not quiet yet only because of something that ends by itself: look again.
do {
    var holds = KadeAudioHolds()
    holds.shortSound(now: 0, seconds: 0.3)               // an earcon, then an audition asks to let go
    check(!holds.isQuiet(now: 0.1), "not quiet while the earcon sounds")
    if let wait = holds.nextCheck(now: 0.1) {
        check(abs(wait - (0.2 + Policy.releaseDelay)) < 0.0001,
              "the keeper looks again once the earcon is over (a failed audition fetch used to leave the session on)")
    } else {
        check(false, "a short sound alone always gets another look")
    }
    holds.hold("the thinking bubbles")
    check(holds.nextCheck(now: 0.1) == nil, "a holder by name looks again itself when it lets go")
}

// A paused streamed voice keeps the session.
do {
    var holds = KadeAudioHolds()
    let voice = "a voice A"
    holds.hold(voice)                                    // the reply speaks
    holds.starting(voice, now: 0)
    holds.settled(voice)                                 // heard
    // Magic Tap pauses it: voiceHolds stays true, so the voice keeps its hold.
    check(Policy.voiceHolds(speaking: true, clipOnDeck: true, paused: true), "paused: the voice keeps its hold")
    check(!holds.isQuiet(now: 600), "ten minutes paused: still not quiet")
    let paused = Moment(switchOn: true, quiet: holds.isQuiet(now: 600), micHeld: false, liveFaceUp: false,
                        category: .playback, mode: .standard)
    check(Policy.release(paused) != .release, "so the session is never let go under a paused clip's engine")
    holds.letGo(voice)                                   // she stops it, or it plays out
    check(holds.isQuiet(now: 601), "stopped: quiet, and let go a moment later")
}

// Books, films and listen-while-made.
do {
    var holds = KadeAudioHolds()
    holds.take("listening while it is made")
    holds.hold("listening while it is made")             // playing (not paused)
    holds.take("the Library player")                     // a book open, paused for the described video
    check(holds.ownerTookOver, "an owner took the session")
    check(!Policy.notifyOthers(ownerTookOver: holds.ownerTookOver), "letting go after them does not wake a podcast they stopped")
    check(!holds.handBack("the Library player"),
          "Stop and close on the Library bar while listen-while-made plays: another owner is left, so the category is not changed under it")
    check(!holds.isQuiet(now: 5), "listen-while-made, still holding, keeps the session on")
    let underIt = Moment(switchOn: true, quiet: holds.isQuiet(now: 5), micHeld: false, liveFaceUp: false,
                         category: .playback, mode: .spokenAudio)
    check(Policy.release(underIt) != .release, "so its sections and its waiting chime never stop")
    holds.letGo("listening while it is made")            // she pauses it
    check(holds.isQuiet(now: 6), "paused: nothing sounds")
    let paused = Moment(switchOn: true, quiet: true, micHeld: false, liveFaceUp: false,
                        category: .playback, mode: .spokenAudio)
    check(Policy.release(paused) != .release, "but its spoken-audio mode still keeps the session (the second guard)")
    check(holds.handBack("listening while it is made"), "it stops: the last owner, so the category goes back to mixing playback")
    check(holds.owners.isEmpty, "nobody owns the session")
    check(holds.handBack("nobody"), "a hand-back with no owner left parks the category, as the old stop paths did")
    holds.released()
    check(!holds.ownerTookOver && Policy.notifyOthers(ownerTookOver: holds.ownerTookOver),
          "after a release, letting go tells the others again")
    holds.take("a family story")
    holds.hold("a family story")
    check(!holds.handBack("the described video player"), "a film closing while a story is open leaves the story's category")
    check(!holds.isQuiet(now: 1), "and the playing story keeps the session")
    check(holds.handBack("a family story") && holds.isQuiet(now: 1), "the story stops: quiet")
}

// --- auditions after a swipe VoiceOver reads ---
do {
    check(Policy.auditionNotBefore(landedAt: 100, voiceOver: false) == nil, "without VoiceOver an audition plays as soon as it is fetched")
    let notBefore = Policy.auditionNotBefore(landedAt: 100, voiceOver: true)
    check(notBefore == 100 + Policy.voiceOverSettle, "with VoiceOver it waits from the moment she landed")
    check(abs(Policy.auditionWait(now: 100.4, notBefore: notBefore) - (Policy.voiceOverSettle - 0.4)) < 0.0001,
          "a sample back in 0.4 s waits out the rest")
    check(Policy.auditionWait(now: 103, notBefore: notBefore) == 0, "a sample that took longer than VoiceOver's name plays at once")
    check(Policy.auditionWait(now: 0, notBefore: notBefore) == Policy.voiceOverSettle,
          "a clock gone wrong never makes it wait longer than the settle time")
    check(Policy.auditionWait(now: 100, notBefore: nil) == 0, "no start time, no wait")
}

// --- a chat turn, start to finish ---
do {
    var holds = KadeAudioHolds()
    holds.shortSound(now: 0, seconds: 0.3)              // the send bloop
    holds.hold("the thinking bubbles")                   // the bubbles, half a second later
    check(!holds.isQuiet(now: 2), "waiting for the reply: the bubbles hold it")
    holds.hold("a voice")                                // the reply starts speaking
    holds.letGo("the thinking bubbles")                  // the bubbles stop for the voice
    holds.starting("a voice", now: 3)
    holds.settled("a voice")                             // the first clip is heard
    check(!holds.isQuiet(now: 8), "the reply speaking holds it, sentence after sentence")
    holds.letGo("a voice")                               // the last sentence ends
    check(holds.isQuiet(now: 9), "the reply has ended: quiet")
    let moment = Moment(switchOn: true, quiet: holds.isQuiet(now: 9 + holds.releaseDelay(now: 9)),
                        micHeld: false, liveFaceUp: false, category: .playback, mode: .standard)
    check(Policy.release(moment) == .release, "a moment later the session is let go: VoiceOver at its own level in the chat")
}

// --- flicking through voices ---
do {
    var holds = KadeAudioHolds()
    let picker = "the picker's voice"
    holds.starting(picker, now: 0)                       // audition A set up
    holds.settled(picker)
    holds.hold(picker)                                   // A is heard
    holds.letGo(picker)                                  // she swipes on at 3 s: A stops 0.35 s later
    holds.settled(picker)
    check(holds.isQuiet(now: 3.35), "the old audition stopped: the session can be let go at once")
    let moment = Moment(switchOn: true, quiet: holds.isQuiet(now: 3.35), micHeld: false, liveFaceUp: false,
                        category: .playback, mode: .standard)
    check(Policy.release(moment) == .release, "so the next audition starts on a fresh session")
    let wait = Policy.auditionWait(now: 3.8, notBefore: Policy.auditionNotBefore(landedAt: 3, voiceOver: true))
    check(wait > 0.6, "and a sample fetched in under half a second still waits for VoiceOver to finish the name")
}

// ============================================================================
// The source. Every player in the app reports to the keeper (switching the
// session off under a player it does not know about stops that player), and
// the plans above are the ones the code really asks for.
// ============================================================================

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let sourcesDir = (root as NSString).appendingPathComponent("Sources")

func read(_ name: String) -> String {
    let path = (sourcesDir as NSString).appendingPathComponent(name)
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("FAILED: could not read Sources/\(name) under \(root)")
        exit(1)
    }
    return text
}

/// The text without comments (block comments, then line comments).
func code(_ text: String) -> String {
    let noBlocks = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    return noBlocks.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
}

/// The code with every space and line break taken out, so a check does not
/// depend on how a call is wrapped.
func compact(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines).joined()
}

var compactCache: [String: String] = [:]
func compactCode(_ name: String) -> String {
    if let done = compactCache[name] { return done }
    let made = compact(code(read(name)))
    compactCache[name] = made
    return made
}

func groups(_ pattern: String, in text: String) -> [[String?]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        print("FAILED: bad pattern \(pattern)")
        exit(1)
    }
    let range = NSRange(text.startIndex..., in: text)
    var out: [[String?]] = []
    for match in regex.matches(in: text, range: range) {
        var found: [String?] = []
        for i in 0..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) {
                found.append(String(text[r]))
            } else {
                found.append(nil)
            }
        }
        out.append(found)
    }
    return out
}

let swiftFiles = ((try? FileManager.default.contentsOfDirectory(atPath: sourcesDir)) ?? [])
    .filter { $0.hasSuffix(".swift") }
    .sorted()
check(swiftFiles.count > 100, "the app's sources are found under \(sourcesDir)")

// --- every player has an owner ---
let playerPattern = #"\b(AVAudioPlayer|AVPlayer|AVQueuePlayer|AVPlayerLooper|AVAudioEngine|AVAudioRecorder|AVSpeechSynthesizer|AVSampleBufferAudioRenderer|WKWebView|VideoPlayer|AudioServicesPlaySystemSound|AudioServicesPlayAlertSound)\s*\("#

struct Owner {
    /// Why the keeper can never let go under this file's sounds.
    let reason: String
    /// Calls that must be in the code of the named file (compared with every
    /// space taken out of both).
    let marks: [(file: String, text: String)]
}

let arcadeHold: (file: String, text: String) = ("ArcadeGameView.swift", #"KadeAudioSession.shared.hold("the Arcade")"#)
let roomLane: (file: String, text: String) = ("ClubhouseService.swift", #"KadeAudioLanes.beginDuplex("room")"#)
let worldHold: (file: String, text: String) = ("WorldService.swift", #"KadeAudioSession.shared.hold("the World")"#)
func owned(_ file: String) -> [(file: String, text: String)] {
    [(file, "KadeAudioSession.shared.take(Self.sessionName)"),
     (file, "KadeAudioSession.shared.hold(Self.sessionName)"),
     (file, "KadeAudioSession.shared.handBack(Self.sessionName)")]
}

let owners: [String: Owner] = [
    "ArcadeGameView.swift": Owner(
        reason: "a game holds the session while it runs; its web game and its speech play inside that",
        marks: [arcadeHold, ("ArcadeGameView.swift", #"KadeAudioSession.shared.letGo("the Arcade")"#)]),
    "ArcadePadPracticeView.swift": Owner(
        reason: "pad practice is a cover over a running game (the Arcade's hold); it speaks only without VoiceOver",
        marks: [arcadeHold, ("ArcadeGameView.swift", "ArcadePadPracticeView(host:host)")]),
    "ArcadeTouchPad.swift": Owner(
        reason: "the pad's chimes are short sounds, inside the Arcade",
        marks: [("ArcadeTouchPad.swift", "KadeAudioSession.shared.shortSound(seconds:player.duration)")]),
    "CharacterLoopView.swift": Owner(
        reason: "silent painted loops, encoded without an audio track and muted: nothing to cut",
        marks: [("CharacterLoopView.swift", "player.isMuted=true")]),
    "ClubhouseEngine.swift": Owner(
        reason: "a room's web engine: only inside a room, which holds the two-way lane",
        marks: [roomLane]),
    "ClubhouseLibrary.swift": Owner(
        reason: "the room's shared recordings: only inside a room; leaving stops them",
        marks: [roomLane, ("ClubhouseService.swift", "library.stop()")]),
    "ClubhouseMusicRenderer.swift": Owner(
        reason: "the room's music: only inside a room",
        marks: [roomLane]),
    "ClubhouseService.swift": Owner(
        reason: "the house PA: only inside a room; leaving stops it",
        marks: [roomLane, ("ClubhouseService.swift", "pa.stop()")]),
    "CreationsView.swift": Owner(
        reason: "the My Creations player sheet holds while it is up",
        marks: [("CreationsView.swift", "KadeAudioSession.shared.hold(sessionHold)"),
                ("CreationsView.swift", "KadeAudioSession.shared.letGo(sessionHold)")]),
    "DescribedListenAhead.swift": Owner(
        reason: "listen-while-made owns the session while listening and holds it while not paused (sections and the waiting chime)",
        marks: owned("DescribedListenAhead.swift")),
    "DescribedVideoPlayer.swift": Owner(
        reason: "the film owns and holds the session while it is open",
        marks: owned("DescribedVideoPlayer.swift")),
    "DescribedVideoView.swift": Owner(
        reason: "the narrator sample is a short sound",
        marks: [("DescribedVideoView.swift", "KadeAudioSession.shared.shortSound(seconds:player.duration)")]),
    "FamilyStoryPlayer.swift": Owner(
        reason: "a family story owns the session while taken and holds it while it plays",
        marks: owned("FamilyStoryPlayer.swift")),
    "KadeFeedback.swift": Owner(
        reason: "earcons and room chimes are short sounds; the thinking bubbles hold by name",
        marks: [("KadeFeedback.swift", "KadeAudioSession.shared.shortSound(seconds:player.duration)"),
                ("KadeFeedback.swift", "KadeAudioSession.shared.hold(Self.waitingLoopHolder)"),
                ("KadeFeedback.swift", "KadeAudioSession.shared.letGo(Self.waitingLoopHolder)")]),
    "LiveFaceSession.swift": Owner(
        reason: "a live face's page: the keeper never lets go while it is up",
        marks: [("KadeAudioSession.swift", "liveFaceUp:LiveFaceSession.shared.state!=.idle"),
                ("LiveFaceSession.swift", "KadeAudioSession.shared.releaseSoon(")]),
    "ParlorService.swift": Owner(
        reason: "the Parlor's house voice holds while it talks; its table cues are short sounds",
        marks: [("ParlorService.swift", "KadeAudioSession.shared.hold(Self.sessionName)"),
                ("ParlorService.swift", "KadeAudioSession.shared.letGo(Self.sessionName)"),
                ("ParlorService.swift", "KadeAudioSession.shared.shortSound(seconds:p.duration)")]),
    "ReadingRoomLibrary.swift": Owner(
        reason: "shows the Library player's own video; the Library holds it",
        marks: [("ReadingRoomService.swift", "KadeAudioSession.shared.hold(Self.sessionName)")]),
    "ReadingRoomService.swift": Owner(
        reason: "the Library owns the session while a book is open and holds it while it plays",
        marks: owned("ReadingRoomService.swift")),
    "ReadingRoomView.swift": Owner(
        reason: "the Library's spoken extras hold while they play",
        marks: [("ReadingRoomView.swift", "KadeAudioSession.shared.hold(Self.sessionName)"),
                ("ReadingRoomView.swift", "KadeAudioSession.shared.letGo(Self.sessionName)")]),
    "SettingsView.swift": Owner(
        reason: "a ringtone preview holds for its length or until Stop preview; the sound samples are earcons",
        marks: [("SettingsView.swift", "KadeAudioSession.shared.hold(Self.previewHold,seconds:player.duration)"),
                ("SettingsView.swift", "KadeAudioSession.shared.letGo(Self.previewHold)")]),
    "SoundBoothView.swift": Owner(
        reason: "the Sound Booth's take player sheet holds while it is up",
        marks: [("SoundBoothView.swift", "KadeAudioSession.shared.hold(sessionHold)"),
                ("SoundBoothView.swift", "KadeAudioSession.shared.letGo(sessionHold)")]),
    "StreamingCallService.swift": Owner(
        reason: "a call holds the two-way lane from before its engine starts; the hang-up tone is a short sound",
        marks: [("StreamingCallService.swift", #"KadeAudioLanes.beginDuplex("call")"#),
                ("StreamingCallService.swift", "KadeAudioSession.shared.shortSound(seconds:player.duration)")]),
    "StreamingClipPlayer.swift": Owner(
        reason: "the streamed voice: its VoiceService holds by name, and its idle engine stops before a release",
        marks: [("StreamingClipPlayer.swift", "KadeAudioSession.shared.preparePlayback(sessionName)"),
                ("StreamingClipPlayer.swift", "funcstopEngineIfIdle()"),
                ("VoiceService.swift", "streamingPlayer.stopEngineIfIdle()")]),
    "VoiceService.swift": Owner(
        reason: "a voice holds while it speaks, has a clip on deck or has one paused; a recording holds the microphone lane",
        marks: [("VoiceService.swift", "KadeAudioSession.shared.speech(busy:holdsSession,source:ObjectIdentifier(self))"),
                ("VoiceService.swift", #"KadeAudioLanes.beginRecording("a recording")"#)]),
    "WorldPictureView.swift": Owner(
        reason: "the World's room picture, drawn inside the World, which holds the session while it is up",
        marks: [worldHold]),
    "WorldService.swift": Owner(
        reason: "the World holds the session while it is up",
        marks: [worldHold, ("WorldService.swift", #"KadeAudioSession.shared.letGo("the World")"#)]),
]

var filesWithPlayers: Set<String> = []
for file in swiftFiles {
    let found = groups(playerPattern, in: code(read(file))).compactMap { $0[1] }
    guard !found.isEmpty else { continue }
    filesWithPlayers.insert(file)
    check(owners[file] != nil,
          "\(file) makes a sound object (\(Set(found).sorted().joined(separator: ", "))) that KadeAudioSession does not know about: give it a hold, a short sound or an owner, and list it here")
}
for (file, owner) in owners.sorted(by: { $0.key < $1.key }) {
    check(filesWithPlayers.contains(file), "\(file) is listed as a player's owner but makes no sound object any more: take it off the list")
    for mark in owner.marks {
        check(compactCode(mark.file).contains(compact(mark.text)),
              "\(file): \(owner.reason). Missing in \(mark.file): \(mark.text)")
    }
}

// --- the plans match the code that sets the session up ---
struct Setup: Equatable {
    let category: String
    let mode: String
    let options: Set<String>
}

func spelled(_ category: Plan.Category) -> String { "." + category.rawValue }
func spelled(_ mode: Plan.Mode) -> String { mode == .standard ? ".default" : "." + mode.rawValue }
func spelled(_ option: Plan.Option) -> String { option == .allowBluetoothHFP ? ".allowBluetooth" : "." + option.rawValue }
func spelled(_ plan: Plan) -> Setup {
    Setup(category: spelled(plan.category), mode: spelled(plan.mode), options: Set(plan.options.map { spelled($0) }))
}

/// Every literal setCategory(...) call in a file.
func setups(in file: String) -> [Setup] {
    let pattern = #"setCategory\((\.[A-Za-z]+)(?:,mode:(\.[A-Za-z]+))?(?:,options:\[([^\]]*)\])?\)"#
    return groups(pattern, in: compactCode(file)).map { g in
        let options = (g[3] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return Setup(category: g[1] ?? "", mode: g[2] ?? ".default", options: Set(options))
    }
}

check(setups(in: "StreamingCallService.swift").contains(spelled(Policy.plan(for: .call))),
      "the call plan is exactly what StreamingCallService sets up (voiceChat, the headset, the loudspeaker)")
check(setups(in: "VoiceService.swift").contains(spelled(Policy.plan(for: .playing))),
      "the playing plan is the old voice setup the phone switch puts back")
check(setups(in: "StreamingClipPlayer.swift").contains(spelled(Policy.plan(for: .playing))),
      "the streamed voice's old setup is the playing plan too")
check(setups(in: "VoiceService.swift").contains(spelled(Policy.plan(for: .listening))),
      "the listening plan is the old recording setup (play-and-record, hands-free Bluetooth, the loudspeaker)")
check(setups(in: "KadeFeedback.swift").contains(spelled(Policy.plan(for: .feedback))),
      "the feedback plan is what the earcons set up")
check(compactCode("KadeFeedback.swift").contains("guardsession.category==.soloAmbientelse{returntrue}")
      && Policy.feedbackCategory(current: .soloAmbient) == Policy.plan(for: .feedback).category,
      "earcons only make an untouched session ambient, as feedbackCategory says")
for file in ["ArcadeGameView.swift", "WorldService.swift", "DescribedVideoView.swift"] {
    check(setups(in: file).allSatisfy { $0 == spelled(Policy.plan(for: .playing)) },
          "\(file) sets up only the playing plan (mixing playback)")
}
for (file, activity) in [("ReadingRoomService.swift", "backgroundListen"), ("FamilyStoryPlayer.swift", "backgroundListen"),
                         ("DescribedListenAhead.swift", "backgroundListen"), ("DescribedVideoPlayer.swift", "film")] {
    check(compactCode(file).contains("KadeAudioSession.setCategory(for:.\(activity))"),
          "\(file) takes its not-mixed session from the \(activity) plan")
}
var everySetup: [(file: String, setup: Setup)] = []
for file in swiftFiles {
    for setup in setups(in: file) { everySetup.append((file: file, setup: setup)) }
}
check(everySetup.count >= 10, "the session setups in the app are found (\(everySetup.count))")
for (file, setup) in everySetup {
    check(!setup.options.contains(".duckOthers") && !setup.options.contains(".interruptSpokenAudioAndMixWithOthers"),
          "\(file): nothing in the app asks to duck VoiceOver or other audio")
    check(![".voiceChat", ".videoChat", ".gameChat"].contains(setup.mode)
          || ["StreamingCallService.swift", "ClubhouseService.swift"].contains(file),
          "\(file): voice processing only on a call or in a room")
    check(![".spokenAudio", ".moviePlayback"].contains(setup.mode),
          "\(file): a book's or a film's session comes from its plan, never written out by hand")
}

// The plan's names turn into the right AVAudioSession values.
do {
    let keeper = compactCode("KadeAudioSession.swift")
    for category in Plan.Category.allCases {
        check(keeper.contains("case\(spelled(category)):return\(spelled(category))"), "category \(category.rawValue) maps to AVAudioSession")
    }
    for mode in Plan.Mode.allCases {
        check(keeper.contains("case.\(mode.rawValue):return\(spelled(mode))"), "mode \(mode.rawValue) maps to AVAudioSession")
    }
    for option in Plan.Option.allCases {
        check(keeper.contains("case.\(option.rawValue):out.insert(\(spelled(option)))"), "option \(option.rawValue) maps to AVAudioSession")
    }
    check(keeper.contains("KadeAudioSessionPolicy.notifyOthers(ownerTookOver:holds.ownerTookOver)"),
          "the keeper asks the policy whether to tell other apps")
    check(keeper.contains("ifmoment.switchOn,!quiet,letwait=holds.nextCheck(now:t)"),
          "a release that waits on a short sound looks again later")
    check(!keeper.contains("retry"), "no retry: a busy switch-off has already switched the session off")
    check(keeper.contains("holds.handBack(who)") && keeper.contains("iflastOwner||!KadeAppSwitches.audioSessionRelease"),
          "a hand-back parks the category only when no other book, film or story is open (always with the old behaviour)")
}

// Only three places ever switch the session off.
do {
    let switchesOff = Set(swiftFiles.filter { compactCode($0).contains("setActive(false") })
    check(switchesOff == ["KadeAudioSession.swift", "StreamingCallService.swift", "VoiceService.swift"],
          "only the keeper, a call's end and a recording's end switch the session off (found: \(switchesOff.sorted().joined(separator: ", ")))")
}

// The media-session trait stays on controls whose sound starts at once and
// that say nothing more while it plays.
do {
    let withTrait = Set(swiftFiles.filter { compactCode($0).contains(".startsMediaSession") })
    check(withTrait.isSubset(of: ["VoicePickerView.swift", "SettingsView.swift", "BriefView.swift"]),
          "the media-session trait only on the audition button, the sound and ringtone samples and Brief Listen (found: \(withTrait.sorted().joined(separator: ", ")))")
    check(withTrait.contains("VoicePickerView.swift"), "the audition button keeps the trait (VoiceOver quiet as the audition starts)")
}

// The voice's wiring.
do {
    let voice = compactCode("VoiceService.swift")
    check(voice.contains("KadeAudioSessionPolicy.voiceFloorBusy(speaking:isSpeaking,clipOnDeck:isClipPlaying,paused:isPaused)"),
          "the speech floor follows voiceFloorBusy (a paused clip gives the floor back)")
    check(voice.contains("KadeAudioSessionPolicy.voiceHolds(speaking:isSpeaking,clipOnDeck:isClipPlaying,paused:isPaused)"),
          "the session follows voiceHolds (a paused clip keeps it)")
    check(voice.components(separatedBy: "KadeAudioSession.shared.clipSettled(").count - 1 >= 4,
          "a heard clip closes its start window (streamed, buffered, the live face and a failed start)")
    check(voice.contains("KadeAudioSession.shared.preparePlayback(sessionName)"), "a voice's clip opens its own start window")
    check(voice.contains("forName:KadeAudioSession.willRelease"), "the streamed voice's idle engine stops before a release")
    check(voice.contains("KadeAudioSessionPolicy.auditionWait(now:"), "an audition waits for VoiceOver's name when asked to")
    check(compactCode("VoicePickerView.swift").contains("KadeAudioSessionPolicy.auditionNotBefore(")
          && compactCode("VoicePickerView.swift").contains("startNotBefore:notBefore"),
          "the voice wheel asks its auditions to wait for VoiceOver's name")
    check(compactCode("ReadingRoomService.swift").contains("forName:KadeAudioSession.willRelease"),
          "a paused book's engine stops before a release")
}

print("Audio session policy and sources: \(count) checks passed; no audio played.")
