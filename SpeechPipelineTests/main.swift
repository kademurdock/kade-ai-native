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

print("")
print("  Speech pipeline — \(checks) checks")
if failures.isEmpty {
    print("  all green")
    print("")
    print("  NOT COVERED BY THIS SUITE, said plainly so nobody reads green as safe:")
    print("    - the VoiceService pump races (155's two-pumps-one-queue, 156's serial")
    print("      fetch stall) live in actor-scheduled audio code, not in this struct.")
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
