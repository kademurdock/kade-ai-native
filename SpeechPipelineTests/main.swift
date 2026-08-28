// SPEECH PIPELINE TESTS — the gate that did not exist on August 23 2026.
//
// WHY THIS FILE IS HERE. On the evening of Aug 23 2026 four builds went to
// TestFlight in a row — 153, 154, 155, 156 (App Store Connect calls them 237,
// 238, 239, 240). Every one of them compiled clean. Every one of them was
// reviewed. Every one of them was WRONG on Kade's phone within minutes of
// installing, and every one was found the same way: by a blind woman listening
// to her own phone and saying so.
//
//   153 — a @State struct mutated from a streaming closure. Two chunks landing
//         in one run-loop turn read the same pre-mutation value and one push
//         overwrote the other. Text vanished; what survived arrived out of order.
//   154 — `spokenSoFar = 0` placed at a reset site that fires mid-turn, so the
//         completion path read the whole reply out a second time.
//   154 — a short opener ("Okay.") deadlocked the splitter: the piece was under
//         the minimum, so it returned nil, and the buffer still began with that
//         same short sentence — every later push bailed identically until the
//         320-character cap fired and cut at an arbitrary comma.
//   155 — two pumps racing one queue; the second player overwrote the first and
//         ARC deallocated a player that was still speaking.
//   156 — strictly serial fetch-then-play, so every sentence boundary cost a
//         full synthesis round trip of dead air.
//
// NOT ONE OF THE FIVE IS VISIBLE TO A COMPILER. The compile gate proves the app
// builds. The accessibility audit walks static screens. The page checker reads
// the web. NOTHING ran the speech path and checked what came out of it.
//
// Three of the five are pure logic in `SpeechStreamer` — no SwiftUI, no actors,
// no audio hardware — which means they were catchable here, for free, before a
// build was ever cut. That is what this file does. The other two live in
// `VoiceService`'s pump and are not reachable from a pure-logic harness; they
// are named at the bottom of this file so nobody mistakes this for full cover.
//
// HOW TO RUN IT — no Mac, no Codemagic minutes, no Xcode:
//
//     ./run-speech-tests.sh
//
// `SpeechStreamer.swift` is pure Foundation, so it compiles with the
// open-source Swift toolchain on Linux. The whole suite runs in about a second
// in the same sandbox a session already has. There is deliberately no XCTest
// and no Package.swift: either one would put a second build system next to
// project.yml, and this needs to stay something anybody can run in one command
// without touching the release lane.
//
// THE HOUSE RULE APPLIES HERE TOO: a regression test nobody has watched fail is
// decoration. Every guard below was proven red by reverting the fix it guards
// and watching this suite go red — receipts in PROJECT_STATUS.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// A very small harness. Not a framework — twenty lines that print what broke.
// ─────────────────────────────────────────────────────────────────────────────

var failures: [String] = []
var checks = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !condition {
        let d = detail()
        failures.append(d.isEmpty ? name : "\(name)\n      \(d)")
    }
}

/// True when a piece is a steering direction with no words after it — the
/// shape that reached the synthesiser twice on build 241 and boop'd.
func isBareDirection(_ piece: String) -> Bool {
    guard piece.hasPrefix("%%%"),
          let close = piece.range(of: "%%%", range: piece.index(piece.startIndex, offsetBy: 3)..<piece.endIndex)
    else { return false }
    return piece[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got:  \(got)\n      want: \(want)")
}

/// Seeded so a failure reproduces. `SystemRandomNumberGenerator` cannot be
/// seeded, and a chunking test that cannot be replayed is a test that reports
/// "sometimes broken" — which is how the 153 race survived review in the first
/// place.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Whitespace-insensitive comparison. `prepare()` trims every piece on purpose,
/// so spaces at piece boundaries are legitimately gone; what must survive is
/// every letter, digit and mark, in order.
func normalized(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Strip the `%%%direction%%%` prefix the streamer adds when carrying steering
/// forward, so a content comparison compares content.
func stripCarry(_ piece: String) -> String {
    guard piece.hasPrefix("%%%") else { return piece }
    let afterOpen = piece.index(piece.startIndex, offsetBy: 3)
    guard let close = piece.range(of: "%%%", range: afterOpen..<piece.endIndex) else { return piece }
    return String(piece[close.upperBound...]).trimmingCharacters(in: .whitespaces)
}

/// Feed `text` through a fresh streamer in fixed-size chunks.
func run(_ text: String, chunk size: Int) -> [String] {
    var s = SpeechStreamer()
    var out: [String] = []
    var idx = text.startIndex
    while idx < text.endIndex {
        let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
        out += s.push(String(text[idx..<end]))
        idx = end
    }
    return out + s.flush()
}

/// Feed `text` through in ragged chunks, the way a network actually delivers it.
func runRagged(_ text: String, seed: UInt64, low: Int = 3, high: Int = 22) -> [String] {
    var rng = SeededRNG(seed: seed)
    var s = SpeechStreamer()
    var out: [String] = []
    var idx = text.startIndex
    while idx < text.endIndex {
        let n = Int.random(in: low...high, using: &rng)
        let end = text.index(idx, offsetBy: n, limitedBy: text.endIndex) ?? text.endIndex
        out += s.push(String(text[idx..<end]))
        idx = end
    }
    return out + s.flush()
}

// A reply shaped like one Kiana actually writes: varied sentence lengths, a
// short opener, an abbreviation, a decimal, a domain, and a paragraph break.
let reply = """
Okay. So here is where that landed, and I want to be straight with you about \
the part that is still open. Dr. Marlowe moved the dose to 3.5 milligrams and \
wants to see how you sleep on it for a week before anybody touches it again.

The appointment is 9 a.m. Thursday, not Wednesday like the card says — I \
checked kade.ai and the calendar both, and Thursday is the one that is real. \
Bring the list you started. You do not have to have it finished.
"""

// ─────────────────────────────────────────────────────────────────────────────
// T1 — NOTHING IS LOST, NOTHING IS DUPLICATED, ORDER IS PRESERVED.
//
// This is the invariant the 153 @State race broke. Text vanished and what
// survived arrived in whatever order the writes settled. Fed ragged, across
// twelve seeds, every character must come out exactly once, in order.
// ─────────────────────────────────────────────────────────────────────────────

for seed in UInt64(1)...12 {
    let pieces = runRagged(reply, seed: seed)
    let rebuilt = normalized(pieces.map(stripCarry).joined(separator: " "))
    checkEqual("T1 seed \(seed): every character survives, in order", rebuilt, normalized(reply))
}

// ─────────────────────────────────────────────────────────────────────────────
// T2 — CHUNK-SIZE INDEPENDENCE.
//
// The splitter's output must not depend on how the network happened to
// fragment the stream. If it does, the lane is not a splitter, it is a race
// with an opinion — and every review that reads it at one chunk size passes it.
// This is the reason to have written the harness even if 153 had never shipped.
// ─────────────────────────────────────────────────────────────────────────────

let wholeReply = run(reply, chunk: reply.count)
for size in [1, 2, 3, 5, 13, 40, 200] {
    checkEqual("T2 chunk \(size): same pieces as one-shot", run(reply, chunk: size), wholeReply)
}
for seed in UInt64(1)...12 {
    checkEqual("T2 ragged seed \(seed): same pieces as one-shot", runRagged(reply, seed: seed), wholeReply)
}

// ─────────────────────────────────────────────────────────────────────────────
// T3 — A SHORT OPENER MUST NOT DEADLOCK THE LANE.
//
// The 154 bug exactly. "Okay." is under minPieceChars, so the first version
// returned nil and waited — but the buffer still began with "Okay.", so every
// later push hit the same too-short piece and bailed identically. Nothing came
// out until the 320-character cap fired and cut mid-clause at a comma. Her
// pieces broke in strange places for exactly this reason.
//
// The fix is that a short sentence absorbs the next one. So: the first piece
// must CONTAIN the opener AND the sentence after it, and it must arrive long
// before 320 characters have been fed.
// ─────────────────────────────────────────────────────────────────────────────

do {
    let text = "Okay. That one is handled and you do not need to think about it again tonight. "
    var s = SpeechStreamer()
    var emitted: [String] = []
    var fed = 0
    var idx = text.startIndex
    while idx < text.endIndex, emitted.isEmpty {
        let end = text.index(idx, offsetBy: 5, limitedBy: text.endIndex) ?? text.endIndex
        fed += text.distance(from: idx, to: end)
        emitted += s.push(String(text[idx..<end]))
        idx = end
    }
    check("T3: a short opener eventually emits", !emitted.isEmpty)
    check("T3: the opener is carried, not dropped",
          emitted.first?.hasPrefix("Okay.") == true, "first piece: \(emitted.first ?? "nil")")
    check("T3: the opener absorbed the sentence after it",
          emitted.first?.contains("handled") == true, "first piece: \(emitted.first ?? "nil")")
    check("T3: it did NOT wait for the 320-char cap",
          fed < 320, "waited \(fed) chars before emitting")
    check("T3: it did NOT cut at a comma mid-clause",
          emitted.first?.hasSuffix(",") != true, "first piece: \(emitted.first ?? "nil")")
}

// ─────────────────────────────────────────────────────────────────────────────
// T4 — ABBREVIATIONS, DECIMALS AND DOMAINS STAY WHOLE.
//
// Splitting naively on a period is how "Dr. Marlowe" becomes two sentences and
// the voice stumbles over a name. The phone lane hit this and fixed it the same
// way; this locks it down on the app side so a future edit to the terminator
// logic cannot quietly undo it.
// ─────────────────────────────────────────────────────────────────────────────

do {
    let cases: [(String, String)] = [
        ("Dr. Marlowe", "Dr. Marlowe called this afternoon about the appointment time and the dose."),
        ("3.5",         "The pharmacist said 3.5 milligrams is the number on the new bottle, not 35."),
        ("9 a.m.",      "Thursday at 9 a.m. is the real one, whatever the appointment card happens to say."),
        ("kade.ai",     "I checked kade.ai against the calendar and both of them agree with each other."),
        ("etc.",        "Bring the list, the bottle, the card, etc. and anything else already in the bag."),
    ]
    for (label, text) in cases {
        for size in [1, 4, 9, text.count] {
            let pieces = run(text, chunk: size)
            checkEqual("T4 \(label) @\(size): stays in one piece", pieces.count, 1)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// T5 — STEERING DIRECTION CARRIES; NON-VERBAL CUES DO NOT.
//
// Each piece is synthesised as its own stateless call, so without carrying the
// direction forward only the first sentence of a reply gets steered and the
// rest comes out flat. The inverse matters just as much: carrying "laugh"
// forward would make her laugh through the entire reply.
// ─────────────────────────────────────────────────────────────────────────────

do {
    let warm = "%%%warm%%% This is the first sentence and it is comfortably long enough to speak. " +
               "This is the second sentence and it should still sound warm when it is spoken."
    let pieces = run(warm, chunk: 7)
    check("T5: more than one piece came out", pieces.count >= 2, "pieces: \(pieces)")
    check("T5: the first piece keeps its own tag",
          pieces.first?.hasPrefix("%%%warm%%%") == true, "first: \(pieces.first ?? "nil")")
    check("T5: the direction carries to later pieces",
          pieces.dropFirst().allSatisfy { $0.hasPrefix("%%%warm%%%") },
          "later: \(Array(pieces.dropFirst()))")

    let laugh = "%%%laugh%%% This is the first sentence and it is comfortably long enough to speak. " +
                "This is the second sentence and she must not still be laughing through it."
    let lp = run(laugh, chunk: 7)
    check("T5: a non-verbal cue does NOT carry forward",
          lp.dropFirst().allSatisfy { !$0.hasPrefix("%%%laugh%%%") },
          "later: \(Array(lp.dropFirst()))")
}

// ─────────────────────────────────────────────────────────────────────────────
// T6 — NOTHING IS SPOKEN THAT IS ONLY PUNCTUATION.
//
// A lone "---" or "**" costs a whole synthesis round trip to say nothing, and
// on the phone it lands as a gap the listener reads as the app having died.
// ─────────────────────────────────────────────────────────────────────────────

do {
    let text = "Here is the first real sentence and it is long enough to be spoken out loud.\n" +
               "---\n" +
               "**\n" +
               "Here is the second real sentence and it is also long enough to be spoken."
    for size in [1, 6, 25, text.count] {
        let pieces = run(text, chunk: size)
        check("T6 @\(size): no piece is punctuation-only",
              pieces.allSatisfy { $0.contains(where: { $0.isLetter || $0.isNumber }) },
              "pieces: \(pieces)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// T7 — A RUNAWAY CLAUSE IS CUT, AND CUT SOMEWHERE A PERSON WOULD BREATHE.
//
// If the model writes a long clause with no terminator, holding the whole
// paragraph hostage is the old silence coming back by another door.
// ─────────────────────────────────────────────────────────────────────────────

do {
    let runaway = String(repeating: "and then another clause arrives, ", count: 40)
    let pieces = run(runaway, chunk: 11)
    check("T7: a terminator-free clause still gets spoken", !pieces.isEmpty)
    check("T7: no piece runs away past the cap",
          pieces.allSatisfy { $0.count <= 340 },
          "longest: \(pieces.map(\.count).max() ?? 0)")
    let rebuilt = normalized(pieces.joined(separator: " "))
    checkEqual("T7: the runaway loses nothing either", rebuilt, normalized(runaway))
}

// ─────────────────────────────────────────────────────────────────────────────
// T8 — THE EMPTY AND DEGENERATE CASES.
//
// flush() on a drained streamer must return nothing. An empty reply must not
// produce a piece. This is what the "speak the tail" path does at the end of
// every single turn, so a stray empty piece here is a synthesis call on every
// reply the platform ever sends.
// ─────────────────────────────────────────────────────────────────────────────

do {
    var s = SpeechStreamer()
    checkEqual("T8: flush on an untouched streamer is empty", s.flush().count, 0)

    var t = SpeechStreamer()
    _ = t.push("This is a complete sentence that is long enough to be spoken on its own. ")
    let tail = t.flush()
    check("T8: flush after a clean boundary adds nothing", tail.isEmpty, "tail: \(tail)")

    var u = SpeechStreamer()
    checkEqual("T8: whitespace-only input speaks nothing", (u.push("   \n  ") + u.flush()).count, 0)
}

// ─────────────────────────────────────────────────────────────────────────────
// T9 — THE TAIL IS NEVER SWALLOWED.
//
// A reply that ends without a terminator — the model just stops — must still be
// spoken by flush(). If this regresses, the last thing she hears is a sentence
// that stops short, which is indistinguishable from the app crashing.
// ─────────────────────────────────────────────────────────────────────────────

do {
    let text = "This first sentence is complete and long enough to be spoken by itself. " +
               "and this trailing thought just stops without any punctuation at all"
    for size in [1, 8, 30, text.count] {
        let pieces = run(text, chunk: size)
        let rebuilt = normalized(pieces.map(stripCarry).joined(separator: " "))
        checkEqual("T9 @\(size): the unterminated tail still gets spoken", rebuilt, normalized(text))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// T12 — A STEERING TAG IS NOT A SENTENCE. FOUND ON BUILD 241, BY HER EAR.
//
// Her report, minutes after installing 241: the order was right and everything
// got spoken, but "every now and then it would play the error sound tone in the
// middle — first section, error sound, more words, error sound, more words."
//
// The production logs named it exactly. Two of the twenty-nine synthesis calls
// for that one reply were sent with NOTHING BUT A DIRECTION IN THEM:
//
//     input len=65, after strip len=61 : "%%%settling in like i've been…%%%"
//     input len=77, after strip len=73 : "%%%picking up a little momentum…%%%"
//
// The synthesiser strips the tag, finds no words left, and returns nothing.
// VoiceService gets `nil` back and plays the error boop on purpose — session 23
// added it so a failed synth would stop being indistinguishable from silence.
// It was doing its job. It was reporting a real failure that should never have
// been requested.
//
// ⚠️ AND THE GUARD THAT SHOULD HAVE CAUGHT IT WAS ALREADY THERE, one line up,
// with a comment describing this exact job: "refuse anything that would only
// make the voice say punctuation." It tests `isLetter || isNumber` — and
// "settling in like i've been waiting for somebody to ask this" is ALL letters.
// A direction reads as speech to a check that only knows about symbols.
//
// These tags run 60-80 characters, which clears minPieceChars, so a tag sitting
// alone at the top of a paragraph is a legal piece by every rule the splitter
// had. The direction must still be REMEMBERED — dropping it is what makes a
// streamed reply go emotionally flat after sentence one — it just must not be
// spoken by itself.

do {
    var s = SpeechStreamer()
    let emitted = s.push("%%%settling in like i've been waiting for somebody to ask this%%%\n\n")
        + s.push("Somebody born in 1885 saw horse-drawn everything and died after the moon landing. ")
        + s.push("That is the whole argument in one sentence and I will defend it. ")
    let tagOnly = emitted.filter { piece -> Bool in
        guard piece.hasPrefix("%%%"),
              let close = piece.range(of: "%%%", range: piece.index(piece.startIndex, offsetBy: 3)..<piece.endIndex)
        else { return false }
        return piece[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    check("T12: no piece is a steering tag with nothing to say",
          tagOnly.isEmpty, "would have booped on: \(tagOnly)")
    check("T12: the words still got spoken",
          emitted.contains { $0.contains("horse-drawn") }, "emitted: \(emitted)")
    check("T12: the direction is still carried onto the speech",
          emitted.contains { $0.contains("settling in") && $0.contains("horse-drawn") },
          "emitted: \(emitted)")
}

do {
    // The second one from the same reply, and a longer tag, fed as one chunk.
    var s = SpeechStreamer()
    var emitted = s.push("%%%picking up a little momentum because here's the part i actually believe%%% ")
    emitted += s.push("Your generation got the internet and that is a real answer. ")
    emitted += s.flush()
    let speakable = emitted.filter { piece -> Bool in
        guard piece.hasPrefix("%%%"),
              let close = piece.range(of: "%%%", range: piece.index(piece.startIndex, offsetBy: 3)..<piece.endIndex)
        else { return true }
        return !piece[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    checkEqual("T12: every emitted piece has words after its tag", speakable.count, emitted.count)
    check("T12: flush does not leave a bare direction behind",
          !(emitted.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%%%")
          || emitted.last?.contains("generation") == true,
          "last piece: \(emitted.last ?? "nil")")
}

do {
    // A tag with no speech AFTER IT AT ALL must be dropped, never spoken —
    // this is the end-of-reply case, where flush() takes whatever is left.
    var s = SpeechStreamer()
    var emitted = s.push("%%%warm and a little amused%%%")
    emitted += s.flush()
    check("T12: a reply ending on a bare direction emits nothing at all",
          emitted.allSatisfy { $0.contains(where: { $0.isLetter }) && !isBareDirection($0) },
          "emitted: \(emitted)")
}

// ─────────────────────────────────────────────────────────────────────────────
// T13 — PART 92.12. THE TWO-FLOOR RULE, AND THE FAST START IT MUST NOT EAT.
//
// Why the floor moved at all: measured against the live endpoint Aug 24-25
// 2026, Inworld's FIXED per-request overhead ran ~1.31s normally and ~5.9s
// during a ~30-minute spike. Audio is ~62ms/char. So a 60-char piece is ~3.3s
// of speech bought with ~6.3s of synthesis during a spike — a deficit, paid
// in silence. A 160-char floor stays ahead even then.
//
// Why the opener is exempt: 91.6 exists because she said there was "a hell of
// a break between ding and tts speaking." A 160-char opener would hand that
// straight back.
//
// ⚠️ These two rules fight, and this test is the referee. The floor is enforced
// by ABSORB-FORWARD — a piece under the floor swallows the next sentence. If
// the opener were ever measured against the big floor it would absorb sentence
// two and the fast start would be gone with every other test still green.
func testTwoFloors() {
    // Six clean sentences, each ~70 chars: over the opener's floor, under the
    // running floor. Exactly the shape that separates the two rules.
    let sentences = [
        "The first thing she said was short enough to get moving quickly here.",
        "The second sentence is also about seventy characters long in total ok.",
        "A third one follows it with roughly the same length as all the others.",
        "The fourth continues the pattern so the absorb rule has room to work..",
        "Number five keeps going with the same approximate size as before now.",
        "And the sixth one closes the reply out at about the same length too..",
    ]
    let text = sentences.joined(separator: " ")

    for size in [1, 7, 40, 400] {
        let pieces = run(text, chunk: size).map(stripCarry)
        guard !pieces.isEmpty else {
            check("T13 @\(size): something was emitted", false)
            continue
        }
        // The opener may not absorb: it clears 60 on its own, so it must be
        // ONE sentence, not two glued together.
        let first = normalized(pieces[0])
        check("T13 @\(size): the opener is a single sentence (fast start intact)",
              first.count < 140,
              "opener was \(first.count) chars: \(first)")

        // Everything after the opener must clear the running floor, or be the
        // last piece (a genuine remainder at flush time is allowed to be short).
        for (i, p) in pieces.enumerated() where i > 0 && i < pieces.count - 1 {
            let n = normalized(p)
            check("T13 @\(size): piece \(i) clears the 160 floor",
                  n.count >= 160,
                  "piece \(i) was \(n.count) chars: \(n)")
        }
        // Nothing may be lost or reordered by the new floor.
        let rebuilt = normalized(pieces.joined(separator: " "))
        checkEqual("T13 @\(size): every word survives, in order", rebuilt, normalized(text))
    }
}
testTwoFloors()

// ─────────────────────────────────────────────────────────────────────────────
// T14 — the opener exemption is spent exactly once, and a dropped piece does
// not spend it. A reply that OPENS on a bare direction (92.11 drops it, no
// synthesis) must still get its fast first spoken piece.
func testOpenerExemptionSurvivesADroppedPiece() {
    let text = "%%%settling in like you have all night%%%\n"
        + "Short one first, just to get the sound started for her here.\n"
        + "Then a second sentence that is long enough to be its own piece easily.\n"
        + "And a third that keeps the reply going for a good while after that..\n"
    let pieces = run(text, chunk: 5).filter { !isBareDirection($0) }
    guard let first = pieces.first.map(stripCarry).map(normalized) else {
        check("T14: something was spoken", false); return
    }
    check("T14: a bare opening direction does not spend the fast-start allowance",
          first.count < 140,
          "first spoken piece was \(first.count) chars: \(first)")
}
testOpenerExemptionSurvivesADroppedPiece()

// ─────────────────────────────────────────────────────────────────────────────
// T15 — HER AUG-28 REPORT: "a single tag carried over the entire message."
// One authored direction, six sentences, and every one of them came out
// steered. The carry now spends itself after the thought it opened plus the
// next beat or two, and the rest of the reply returns to her own register.
//
// RED-PROOF: delete the two bounds in prepare() and this goes red at 6 stamped.
let steeredReply = "%%%slow and soothing like you are talking somebody down%%%"
    + " Hey, I need you to actually breathe with me for a second here before we go anywhere near the rest of it, because you have been holding your shoulders up by your ears since Tuesday.\n"
    + "The number came back and it moved the wrong direction, which is not nothing and I am not going to sit here and tell you that it is nothing, because you would know I was lying.\n"
    + "But it is also not the thing you have been quietly afraid of all week, and I want that said out loud before your brain runs off and writes the whole ending by itself tonight.\n"
    + "Your doctor wants a second draw on Friday morning before she is willing to say one single word about what any of it means, and honestly that is the right call for her to make.\n"
    + "So Friday is the day that actually decides something, and today is just a day you have to get through, which is a much smaller job than the one you have been doing all week.\n"
    + "Between now and then you can put the whole thing down for a few hours and go do something with your hands, and that is not denial, that is just you pacing yourself properly.\n"

func testCarryDecays() {
    let pieces = run(steeredReply, chunk: 7).filter { !isBareDirection($0) }
    let stamped = pieces.filter { $0.hasPrefix("%%%") }.count
    check("T15: the carry stops instead of haunting the whole reply",
          stamped < pieces.count,
          "\(stamped) of \(pieces.count) pieces carried the direction")
    check("T15: it stops after the authored piece plus two beats",
          stamped <= 3,
          "\(stamped) pieces steered — the bound is the authored one plus 2")
    // The steered pieces are the EARLY ones. A direction colours the thought
    // it opened, never a passage three sentences downstream.
    let firstClean = pieces.firstIndex { !$0.hasPrefix("%%%") } ?? pieces.count
    let lastStamped = pieces.lastIndex { $0.hasPrefix("%%%") } ?? -1
    check("T15: the carry is contiguous from the top, never resumed later",
          lastStamped < firstClean,
          "last stamped at \(lastStamped), first clean at \(firstClean)")
}
testCarryDecays()

// ─────────────────────────────────────────────────────────────────────────────
// T16 — a NEW authored direction re-arms the carry. The decay must not become
// "the back half of every reply is flat": the author is still in charge.
//
// ⚠️ HONEST LABEL: this one is a NO-REGRESSION guard, not a red-proof. It
// passes against the old code too, by design — it exists to catch a future
// change that makes the decay too eager, not to convict the Aug-28 bug.
func testReTaggingReArmsTheCarry() {
    let text = "%%%dry as hell like you are already unimpressed%%%"
        + " One, and this is the first real thing said here, written long enough that it stands on its own as a spoken piece instead of getting absorbed into the sentence after it.\n"
        + "Two, which is also long enough to stand alone as its own spoken piece, and it should still be carrying the first direction because it is the very next beat after it.\n"
        + "Three, still long enough to be its own piece, and by this point the first direction has spent its budget completely and this text should be going out perfectly clean.\n"
        + "%%%warmer now like you actually mean this part%%% Four, said a different way entirely, and long enough on its own that the splitter will hand it over as one piece.\n"
        + "Five, which should be carrying the SECOND direction now and must never go back to carrying the first one, because that one was finished several sentences ago.\n"
    let pieces = run(text, chunk: 9).filter { !isBareDirection($0) }
    let carriedWarm = pieces.filter { $0.hasPrefix("%%%warmer now") }.count
    check("T16: a re-tag re-arms the carry", carriedWarm >= 2,
          "only \(carriedWarm) pieces carried the second direction, of \(pieces.count)")
    let afterWarm = pieces.drop(while: { !$0.contains("warmer now") })
    let staleDry = afterWarm.filter { $0.hasPrefix("%%%dry as hell") }.count
    check("T16: the old direction never comes back after a new one", staleDry == 0,
          "\(staleDry) pieces carried the stale direction past the re-tag")
}
testReTaggingReArmsTheCarry()

// ─────────────────────────────────────────────────────────────────────────────
// T17 — %%%reset%%% ends the carry instead of BECOMING it. The proxy has
// honoured reset since Aug 25; this lane treated it as an ordinary direction,
// so the literal word got stamped onto every later piece and the real
// direction was never actually ended.
func testResetEndsTheCarryAndIsNeverCarried() {
    let text = "%%%cracking up barely able to get it out%%%"
        + " Girl. GIRL. No you did not, and I am going to need every single detail of that in order, starting from the part where you thought this was a reasonable plan.\n"
        + "%%%reset%%% Anyway, here is the real part of it, which is the actual reason I brought the whole thing up with you in the first place instead of just quietly letting it go by.\n"
        + "And this sentence right after that one, which has to come out completely clean of every single tag, because the author already said stop and she meant it when she said it.\n"
        + "And one more after that as well, still clean, because a reset does not wear off after a sentence or two the way an ordinary steering direction is supposed to wear off.\n"
    let pieces = run(text, chunk: 6).filter { !isBareDirection($0) }
    let resetSeen = pieces.filter { $0.contains("%%%reset%%%") }.count
    check("T17: reset appears once — where she wrote it, never carried", resetSeen <= 1,
          "\(resetSeen) pieces carried a literal reset tag")
    let afterReset = pieces.drop(while: { !$0.contains("%%%reset%%%") }).dropFirst()
    let stale = afterReset.filter { $0.hasPrefix("%%%") }.count
    check("T17: nothing after a reset is steered", stale == 0,
          "\(stale) of \(afterReset.count) pieces after the reset were still steered")
}
testResetEndsTheCarryAndIsNeverCarried()

// ─────────────────────────────────────────────────────────────────────────────
// T18 — the fix does not undo 91.10. A steered passage must STILL be steered
// past its first sentence, which is the entire reason the carry exists. The
// cure for "it never stops" is not "it never starts."
func testCarryStillWorksAtAll() {
    let text = "%%%quick and animated still a little spooked by it%%%"
        + " So I am walking up to the door and the porch light is already off, which it never is at that hour, and I am telling myself there is a normal reason for that.\n"
        + "And then the door is standing open about four inches, and I just stopped dead right there on the step because that door sticks and it does not drift open.\n"
    let pieces = run(text, chunk: 8).filter { !isBareDirection($0) }
    let stamped = pieces.filter { $0.hasPrefix("%%%") }.count
    check("T18: the carry still carries (a reply does not go flat after line one)",
          stamped >= 2, "only \(stamped) of \(pieces.count) pieces were steered")
}
testCarryStillWorksAtAll()

// ─────────────────────────────────────────────────────────────────────────────

print("")
print("  Speech pipeline — \(checks) checks")
if failures.isEmpty {
    print("  all green")
    print("")
    print("  NOT COVERED BY THIS SUITE, said plainly so nobody reads green as safe:")
    print("    - the VoiceService pump races (155's two-pumps-one-queue, 156's serial")
    print("      fetch stall) live in actor-scheduled audio code, not in this struct.")
    print("    - the two-floor rule (T13/T14) is checked on TEXT only. It proves the")
    print("      pieces are the right SIZE; it cannot prove the resulting margin beats")
    print("      whatever the provider's latency is doing tonight.")
    print("    - prefetch depth 2 is NOT covered here at all — it lives in the pump.")
    print("    - nothing here plays audio or listens to it. This proves the TEXT that")
    print("      reaches the synthesiser is whole, ordered and sensibly cut. It cannot")
    print("      prove what comes out of the speaker.")
    print("")
    exit(0)
} else {
    print("  \(failures.count) of \(checks) FAILED")
    print("")
    for f in failures { print("    - \(f)") }
    print("")
    exit(1)
}
