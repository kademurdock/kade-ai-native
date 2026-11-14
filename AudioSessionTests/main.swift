import Foundation

// Nov 14 2026: the app's audio-session rules (KadeAudioSessionPolicy and
// KadeAudioHolds). Her report: VoiceOver quieter inside a conversation and
// louder in any other app, and an audition's first seconds ducked. Pure
// Foundation; no audio is played and no session is touched.

var count = 0
func check(_ ok: Bool, _ label: String) {
    if !ok { print("FAILED: \(label)"); exit(1) }
    count += 1
}

typealias Policy = KadeAudioSessionPolicy
typealias Plan = KadeAudioSessionPlan
typealias Moment = KadeAudioSessionPolicy.Moment

// --- what each state asks the session for ---
check(KadeAudioActivity.allCases.count == 7, "seven states: idle, playing, feedback, listening, call, face, background listen")

do {
    let idle = Policy.plan(for: .idle)
    check(!idle.active, "idle: the app holds no session")
    check(idle.notifyOthersOnDeactivation, "idle: letting go tells VoiceOver and other audio they may come back up")
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

check(Policy.plan(for: .face) == Policy.plan(for: .playing), "a live face plays like any clip")

do {
    let listen = Policy.plan(for: .backgroundListen)
    check(listen.category == .playback && listen.mode == .spokenAudio && listen.options.isEmpty,
          "background listen: spoken-audio playback, not mixed (lock screen and headphone buttons, screen locked)")
    check(!listen.mixes && !listen.ducksOthers && !listen.voiceProcessing && !listen.records,
          "background listen: no ducking, no voice processing, no microphone")
}

for activity in KadeAudioActivity.allCases {
    let plan = Policy.plan(for: activity)
    check(!plan.ducksOthers, "\(activity.rawValue): never ducks VoiceOver")
    check(plan.voiceProcessing == (activity == .call), "\(activity.rawValue): voice processing only on a call")
    check(plan.records == (activity == .listening || activity == .call), "\(activity.rawValue): a microphone only while listening or on a call")
    check(plan.active == (activity != .idle), "\(activity.rawValue): switched on unless idle")
    check(plan.notifyOthersOnDeactivation, "\(activity.rawValue): letting go always tells the others")
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

check(Policy.releaseDelay >= 0.5 && Policy.releaseDelay <= 3, "let go within a few seconds, never between two sentences")
check(Policy.startWindow >= 2 && Policy.startWindow <= 10, "a clip has a few seconds to start before the session may go")
check(Policy.retryDelay > 0, "a failed release is tried again")
check(Policy.longestShortSound >= 5, "an earcon or a tone always fits a short sound")

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
    holds.starting(now: 50)
    check(!holds.isQuiet(now: 51), "a clip being set up holds it for the start window")
    holds.settled()
    check(holds.isQuiet(now: 51), "once the clip reports itself (or is stopped) the window is over")
    holds.starting(now: 60)
    check(holds.isQuiet(now: 60 + Policy.startWindow), "a clip that never started does not keep the session on")
}

// --- a chat turn, start to finish ---
do {
    var holds = KadeAudioHolds()
    holds.shortSound(now: 0, seconds: 0.3)              // the send bloop
    holds.hold("the thinking bubbles")                   // the bubbles, half a second later
    check(!holds.isQuiet(now: 2), "waiting for the reply: the bubbles hold it")
    holds.hold("a voice")                                // the reply starts speaking
    holds.letGo("the thinking bubbles")                  // the bubbles stop for the voice
    holds.starting(now: 3)
    holds.settled()                                      // the first clip is heard
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
    holds.starting(now: 0)                               // audition A set up
    holds.settled()
    holds.hold("the picker's voice")                     // A is heard
    holds.letGo("the picker's voice")                    // she moves on: A stops
    holds.settled()
    check(holds.isQuiet(now: 1), "the old audition stopped: the session can be let go at once")
    let moment = Moment(switchOn: true, quiet: holds.isQuiet(now: 1), micHeld: false, liveFaceUp: false,
                        category: .playback, mode: .standard)
    check(Policy.release(moment) == .release, "so the next audition starts on a fresh session, not one VoiceOver ducked")
}

print("Audio session policy: \(count) checks passed; no audio played.")
