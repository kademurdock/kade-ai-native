import Foundation

// Nov 13 2026: the "still waiting" chime for listening to a described video
// while it is made. Pure Foundation; no audio is played. The player is driven
// here by a small stand-in that does exactly what ListenAheadPlayer does with
// the keeper: look at the state, start one loop or stop it.

var count = 0
func check(_ ok: Bool, _ label: String) {
    if !ok { print("FAILED: \(label)"); exit(1) }
    count += 1
}

typealias State = WaitingChime.State

/// Stands in for the looping sound player.
struct Rig {
    var keeper = WaitingChimeKeeper()
    var loops = 0          // loops playing right now
    var starts = 0
    var stops = 0
    var mostAtOnce = 0
    mutating func look(_ state: State) {
        switch keeper.next(state) {
        case .start: loops += 1; starts += 1
        case .stop: loops -= 1; stops += 1
        case .nothing: break
        }
        mostAtOnce = max(mostAtOnce, loops)
    }
}

let playing = State(listening: true, waiting: false, making: true, paused: false, enabled: true)
var caughtUp = playing; caughtUp.waiting = true

// --- when it may sound ---
check(!WaitingChime.shouldSound(State()), "idle: silent")
check(!WaitingChime.shouldSound(playing), "a section is playing: silent")
check(WaitingChime.shouldSound(caughtUp), "caught up while the job runs: sounds")
do {
    var s = caughtUp; s.making = false
    check(!WaitingChime.shouldSound(s), "the job ended or failed: silent")
    s = caughtUp; s.paused = true
    check(!WaitingChime.shouldSound(s), "she paused: silent")
    s = caughtUp; s.listening = false
    check(!WaitingChime.shouldSound(s), "she stopped listening or left: silent")
    s = caughtUp; s.enabled = false
    check(!WaitingChime.shouldSound(s), "switched off: silent")
}

// --- starts when the wait begins, never before ---
do {
    var rig = Rig()
    rig.look(State())
    rig.look(playing)
    check(rig.starts == 0 && rig.loops == 0, "nothing starts while nothing is waiting")
    rig.look(caughtUp)
    check(rig.starts == 1 && rig.loops == 1, "the wait begins: one loop starts")
}

// --- never stacks: thirty looks at the same wait are still one loop ---
do {
    var rig = Rig()
    for _ in 0..<30 { rig.look(caughtUp) }
    check(rig.starts == 1 && rig.loops == 1 && rig.mostAtOnce == 1, "repeated looks never start a second loop")
}

// --- stops on the next part ---
do {
    var rig = Rig()
    rig.look(caughtUp)
    rig.look(playing)
    check(rig.stops == 1 && rig.loops == 0, "the next section starts: the loop stops")
    rig.look(playing)
    check(rig.stops == 1, "and is stopped only once")
    rig.look(caughtUp)
    check(rig.starts == 2 && rig.loops == 1 && rig.mostAtOnce == 1, "caught up again: one fresh loop")
}

// --- stops when the job ends or fails ---
do {
    var rig = Rig()
    rig.look(caughtUp)
    var ended = caughtUp; ended.making = false
    rig.look(ended)
    check(rig.loops == 0 && rig.stops == 1, "the job finished or failed: the loop stops")
    ended.waiting = false
    rig.look(ended)
    check(rig.loops == 0 && rig.starts == 1, "and stays stopped")
}

// --- stops on pause, comes back on carry on ---
do {
    var rig = Rig()
    rig.look(caughtUp)
    var paused = caughtUp; paused.paused = true
    rig.look(paused)
    check(rig.loops == 0, "pause while waiting: the loop stops")
    rig.look(caughtUp)
    check(rig.loops == 1 && rig.starts == 2 && rig.mostAtOnce == 1, "carry on: one loop again")
}

// --- stops when she stops listening or leaves the screen ---
do {
    var rig = Rig()
    rig.look(caughtUp)
    rig.look(State())
    check(rig.loops == 0 && rig.stops == 1, "stop listening: the loop stops")
}

// --- a section arriving while paused does not bring the chime back ---
do {
    var rig = Rig()
    var paused = caughtUp; paused.paused = true
    rig.look(caughtUp); rig.look(paused)
    var arrived = paused; arrived.waiting = false
    rig.look(arrived)
    arrived.paused = false
    rig.look(arrived)
    check(rig.loops == 0 && rig.starts == 1, "paused, then the section arrived: no chime over it")
}

// --- a loop that did not start, or that a phone call stopped, is tried again once ---
do {
    var keeper = WaitingChimeKeeper()
    check(keeper.next(caughtUp) == .start, "asks for a start")
    keeper.lost()
    check(!keeper.sounding, "a lost loop is not counted as sounding")
    check(keeper.next(caughtUp) == .start, "the next look starts it again")
    check(keeper.next(caughtUp) == .nothing, "and only once")
    keeper.lost()
    check(keeper.next(playing) == .nothing, "a lost loop is not restarted over a playing section")
}

// --- the loop itself: the timing lives in the samples ---
let rate = WaitingChime.sampleRate
let loop = WaitingChime.loopSamples()
let chime = WaitingChime.chimeSamples()
check(WaitingChime.period == 20, "the spacing is 20 seconds")
check(loop.count == 20 * rate, "the loop is exactly 20 seconds long")
check(chime.count > Int(0.25 * Double(rate)) && chime.count < Int(0.45 * Double(rate)), "the chime is about a third of a second")
let chimeStart = loop.count - chime.count
check(!loop[0..<chimeStart].contains { $0 != 0 }, "everything before the chime is true silence")
check(Array(loop[chimeStart...]) == chime, "the chime is the end of the loop")
check(Double(chimeStart) / Double(rate) > 19.5, "the first chime comes about 20 seconds after the wait begins, not over the caught-up sentence")
check(loop.first == 0 && loop.last == 0, "the loop starts and ends on silence, so the seam does not click")
// Chime onsets over three turns of the loop are one period apart.
do {
    let onsets = (0..<3).map { Double($0 * loop.count + chimeStart) / Double(rate) }
    check(abs((onsets[1] - onsets[0]) - 20) < 0.001 && abs((onsets[2] - onsets[1]) - 20) < 0.001, "it repeats every 20 seconds")
}
// One chime per loop: after its first sound there is no half-second gap of
// silence followed by more sound.
do {
    var gap = 0, longestGap = 0, sounded = false
    for sample in loop[chimeStart...] {
        if abs(Int(sample)) > 40 { sounded = true; gap = 0 } else if sounded { gap += 1; longestGap = max(longestGap, gap) }
    }
    check(sounded && longestGap < rate / 4, "one chime per loop, its two notes together")
}

// --- soft: well under speech level, and no clicks ---
do {
    let loudest = chime.map { abs(Int($0)) }.max() ?? 0
    check(loudest <= Int(0.1 * 32_767), "the loudest sample is under a tenth of full level")
    check(loudest >= Int(0.03 * 32_767), "and it is not so quiet it cannot be heard")
    check(abs(Int(chime[0])) < 40 && abs(Int(chime[chime.count - 1])) < 40, "the chime fades in from and out to silence")
    var biggestStep = 0
    for index in 1..<chime.count { biggestStep = max(biggestStep, abs(Int(chime[index]) - Int(chime[index - 1]))) }
    // A full-level 784 Hz tone moves under 0.23 of its height per sample at 22.05 kHz.
    check(biggestStep < Int(0.25 * 0.1 * 32_767), "no sudden jump between samples (no click, also where the notes join)")
    // Two notes: the second half is the higher note (more zero crossings).
    func crossings(_ part: ArraySlice<Int16>) -> Int {
        var n = 0, last = 0
        for sample in part where sample != 0 {
            let sign = sample > 0 ? 1 : -1
            if last != 0 && sign != last { n += 1 }
            last = sign
        }
        return n
    }
    let half = chime.count / 2
    check(crossings(chime[half...]) > crossings(chime[..<half]), "two notes, the second higher")
}

// --- the WAV file ---
do {
    let data = WaitingChime.wav(loop)
    let bytes = [UInt8](data)
    func le32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
    func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    check(bytes.count == 44 + loop.count * 2, "header plus two bytes a sample")
    check(String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF" && String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE", "a RIFF WAVE file")
    check(le32(4) == bytes.count - 8 && le32(40) == loop.count * 2, "sizes are right")
    check(le16(20) == 1 && le16(22) == 1 && le32(24) == rate && le32(28) == rate * 2 && le16(32) == 2 && le16(34) == 16, "16-bit mono PCM at the loop's rate")
    let lastSample = Int16(bitPattern: UInt16(le16(bytes.count - 2)))
    let midIndex = chimeStart + chime.count / 4
    let mid = Int16(bitPattern: UInt16(le16(44 + midIndex * 2)))
    check(lastSample == loop[loop.count - 1] && mid == loop[midIndex], "samples are written little-endian, in order")
    check(Double(loop.count) / Double(le32(24)) == 20, "the file plays for 20 seconds")
}

// --- the words ---
do {
    let withChime = WaitingChime.caughtUpSentence(section: 4, of: 9, chime: true)
    check(withChime.hasPrefix("You have caught up. Section 4 of 9 is still being made."), "says where she is")
    check(withChime.contains("chime about every 20 seconds"), "says what the chime means")
    let without = WaitingChime.caughtUpSentence(section: 4, of: 9, chime: false)
    check(without == "You have caught up. Section 4 of 9 is still being made. It will start by itself while this app is open. If your phone locks, come back to this app to carry on.", "with the chime off the sentence is the old one")
    check(!without.contains("chime"), "and does not promise a chime")
    check(WaitingChime.caughtUpSentence(section: 5, of: 0, chime: false).contains("Section 5 of 5"), "an unknown count never reads smaller than the section")
}

print("Waiting chime: \(count) checks passed; no audio played.")
