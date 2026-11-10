import Foundation

// The Library player's words and small rules (Sources/LibraryPlayerWords.swift).
// Plain Foundation, run by run-library-player-tests.sh. Every check prints what
// it got, and the run ends non-zero if any failed.

var checks = 0
var failures: [String] = []
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    checks += 1
    if got != want { failures.append("\(name): got \(got), wanted \(want)") }
}

typealias W = LibraryPlayerWords

// The clock a sighted person reads.
check("clock: zero", W.clock(0), "0:00")
check("clock: under a minute", W.clock(40), "0:40")
check("clock: minutes", W.clock(125), "2:05")
check("clock: an hour", W.clock(3725), "1:02:05")
check("clock: half seconds round down, so it never shows the end early", W.clock(59.9), "0:59")
check("clock: a negative time is zero", W.clock(-3), "0:00")
check("clock: not a number is zero", W.clock(.nan), "0:00")
check("clock: infinity is zero", W.clock(.infinity), "0:00")

// The same time for the ear: no colons.
check("spoken: zero", W.spokenClock(0), "0 seconds")
check("spoken: one second", W.spokenClock(1), "1 second")
check("spoken: under a minute", W.spokenClock(40), "40 seconds")
check("spoken: exactly a minute", W.spokenClock(60), "1 minute")
check("spoken: minutes and seconds", W.spokenClock(125), "2 minutes 5 seconds")
check("spoken: exactly an hour", W.spokenClock(3600), "1 hour")
check("spoken: past an hour the seconds are left out", W.spokenClock(3725), "1 hour 2 minutes")
check("spoken: two hours", W.spokenClock(7260), "2 hours 1 minute")
check("spoken: not a number", W.spokenClock(.nan), "0 seconds")
check("spoken: never holds a colon", W.spokenClock(4000).contains(":"), false)

check("slider value", W.spokenPosition(40, of: 125), "40 seconds of 2 minutes 5 seconds")
check("slider value: a position past the end reads as the end", W.spokenPosition(200, of: 125), "2 minutes 5 seconds of 2 minutes 5 seconds")
check("slider value: no length yet says only the place", W.spokenPosition(40, of: 0), "40 seconds")

// One swipe on the slider.
check("step: a commercial", W.seekStep(duration: 30), 10)
check("step: exactly ten minutes", W.seekStep(duration: 600), 10)
check("step: a half-hour show", W.seekStep(duration: 1800), 30)
check("step: exactly an hour", W.seekStep(duration: 3600), 30)
check("step: a film", W.seekStep(duration: 7200), 60)
check("step: no length yet", W.seekStep(duration: 0), 10)
check("step: not a number", W.seekStep(duration: .nan), 10)
check("hint names the real step, short", W.seekHint(duration: 30), "Swipe up or down to move 10 seconds at a time.")
check("hint names the real step, film", W.seekHint(duration: 7200), "Swipe up or down to move 1 minute at a time.")

// The status line.
check("resting: a one-part recording", W.restingStatus(isAudio: true, position: 40, duration: 125, part: 0, partCount: 1),
      "0:40 of 2:05 \u{00B7} 1:25 left")
check("resting: a recording with parts", W.restingStatus(isAudio: true, position: 40, duration: 125, part: 1, partCount: 5),
      "0:40 of 2:05 \u{00B7} 1:25 left \u{00B7} Part 2 of 5")
check("resting: a recording whose length is not known yet", W.restingStatus(isAudio: true, position: 0, duration: 0, part: 0, partCount: 1), "")
check("resting: parts but no length yet", W.restingStatus(isAudio: true, position: 0, duration: 0, part: 2, partCount: 4), "Part 3 of 4")
check("resting: a book", W.restingStatus(isAudio: false, position: 0, duration: 0, part: 2, partCount: 12), "Chapter 3 of 12")
check("resting: a book with no chapters yet", W.restingStatus(isAudio: false, position: 0, duration: 0, part: 0, partCount: 0), "")
check("resting: a place past the end never shows a negative time left",
      W.restingStatus(isAudio: true, position: 200, duration: 125, part: 0, partCount: 1), "2:05 of 2:05 \u{00B7} 0:00 left")
check("resting, spoken", W.spokenRestingStatus(isAudio: true, position: 40, duration: 125, part: 1, partCount: 5),
      "40 seconds of 2 minutes 5 seconds, 1 minute 25 seconds left, Part 2 of 5")
check("resting, spoken: a book", W.spokenRestingStatus(isAudio: false, position: 0, duration: 0, part: 0, partCount: 3), "Chapter 1 of 3")
check("part words never count past the total", W.partWords(isAudio: true, part: 7, partCount: 3), "Part 8 of 8")

check("status note: a message wins", W.statusNote(message: "Bookmark placed.", pausedFor: "a call"), "Bookmark placed.")
check("status note: then why it paused itself", W.statusNote(message: "", pausedFor: "a call"), "Paused for a call")
check("status note: nothing to say is nothing", W.statusNote(message: "  ", pausedFor: nil), "")
check("status note: a blank reason is no reason", W.statusNote(message: "", pausedFor: " "), "")
// Nov 10 review: a skip, a part change or a bookmark jump must never take the
// clock off the screen. The clock keeps the first line whatever is said.
let restingClock = W.restingStatus(isAudio: true, position: 40, duration: 125, part: 0, partCount: 1)
let saidLines = ["Forward 10 seconds.", "Back 10 seconds.", "Part 2 of 5: The storm", "Bookmark placed.", "The voice did not answer (HTTP 502). Press Play to try again, or pick another voice first.", ""]
let pausedReasons: [String?] = [nil, "a call", "a voice message"]
for said in saidLines {
    for why in pausedReasons {
        let tag = "(" + said + ", " + (why ?? "playing") + ")"
        let lines = W.statusLines(message: said, pausedFor: why, resting: restingClock)
        check("status lines: always two " + tag, lines.count, 2)
        check("status lines: the clock keeps the first line " + tag, lines.first ?? "", restingClock)
        check("status lines: the clock is shown " + tag, lines.joined(separator: " ").contains("0:40 of 2:05"), true)
    }
}
check("status lines: the message sits under the clock", W.statusLines(message: "Forward 10 seconds.", pausedFor: nil, resting: restingClock), [restingClock, "Forward 10 seconds."])
check("status lines: the paused reason sits under the clock", W.statusLines(message: "", pausedFor: "a call", resting: restingClock), [restingClock, "Paused for a call"])
check("status lines: at rest the second line is empty", W.statusLines(message: "", pausedFor: nil, resting: restingClock), [restingClock, ""])
check("status lines: with no clock yet the note takes the first line", W.statusLines(message: "Bookmark placed.", pausedFor: nil, resting: ""), ["Bookmark placed.", ""])
check("status lines: nothing at all is two empty lines", W.statusLines(message: "", pausedFor: nil, resting: " "), ["", ""])
let restingSpoken = W.spokenRestingStatus(isAudio: true, position: 40, duration: 125, part: 0, partCount: 1)
check("spoken status: the place first, then the note", W.spokenStatus(message: "Forward 10 seconds.", pausedFor: nil, spokenResting: restingSpoken), restingSpoken + ". Forward 10 seconds.")
check("spoken status: at rest only the place", W.spokenStatus(message: "", pausedFor: nil, spokenResting: restingSpoken), restingSpoken)
check("spoken status: no place yet, only the note", W.spokenStatus(message: "Bookmark placed.", pausedFor: nil, spokenResting: ""), "Bookmark placed.")
check("spoken status: never holds a colon clock", W.spokenStatus(message: "", pausedFor: "a call", spokenResting: restingSpoken).contains("0:40"), false)

// Nov 10 review: a chosen caption or sound track is found again on a freshly
// loaded copy of the video, and nothing is chosen for her when none matches.
let english = W.TrackKey(language: "en", name: "English", special: false)
let englishSDH = W.TrackKey(language: "en", name: "English SDH", special: true)
let spanish = W.TrackKey(language: "es", name: "Spanish", special: false)
let describedTrack = W.TrackKey(language: "en", name: "English, described", special: true)
let noMatch: Int? = nil
check("rematch: the same track is found", W.rematch(english, in: [spanish, english, englishSDH]), 1)
check("rematch: the kind matters", W.rematch(englishSDH, in: [english, englishSDH]), 1)
check("rematch: a renamed track with the same language and kind is found when it is the only one", W.rematch(W.TrackKey(language: "en", name: "English (CC)", special: false), in: [spanish, english, englishSDH]), 1)
check("rematch: two candidates is no match", W.rematch(W.TrackKey(language: "en", name: "Commentary", special: false), in: [english, W.TrackKey(language: "en", name: "English 2", special: false)]), noMatch)
check("rematch: another language is no match", W.rematch(spanish, in: [english, englishSDH]), noMatch)
check("rematch: a described track is not swapped for a plain one", W.rematch(describedTrack, in: [english]), noMatch)
check("rematch: no tracks is no match", W.rematch(english, in: []), noMatch)
check("rematch: a track with no language only matches exactly", W.rematch(W.TrackKey(language: "", name: "Track 2", special: false), in: [W.TrackKey(language: "", name: "Track 1", special: false)]), noMatch)
check("status time: a short line stays six seconds", W.statusSeconds(for: "Saved."), 6)
check("status time: a long line stays longer", W.statusSeconds(for: "The voice did not answer (HTTP 502). Press Play to try again, or pick another voice first.") > 9, true)
check("status time: never past fifteen seconds", W.statusSeconds(for: String(repeating: "word ", count: 200)), 15)

// Part controls and the Play word.
check("no part controls for nothing", W.showsPartControls(partCount: 0), false)
check("no part controls for one part", W.showsPartControls(partCount: 1), false)
check("part controls from two parts", W.showsPartControls(partCount: 2), true)
check("Play word: playing", W.playWord(playing: true, pausedFor: nil), "Pause")
check("Play word: playing wins over an old reason", W.playWord(playing: true, pausedFor: "a call"), "Pause")
check("Play word: stopped", W.playWord(playing: false, pausedFor: nil), "Play")
check("Play word: paused for a call", W.playWord(playing: false, pausedFor: "a call"), "Resume")
check("Play word: an empty reason is no reason", W.playWord(playing: false, pausedFor: ""), "Play")

// The quick type buttons.
check("quick types are each named once", Set(W.quickTypes.map { $0.id }).count, W.quickTypes.count)
check("quick types have no blank word", W.quickTypes.contains { $0.title.isEmpty || $0.id.isEmpty || $0.symbol.isEmpty }, false)
check("quick types lead with movies and television", Array(W.quickTypes.prefix(2).map { $0.id }), ["movie", "tv"])
for quick in W.quickTypes {
    // The button and the Type menu must say the same word for the same id.
    check("quick type \(quick.id) matches the Type menu's word", LibraryBrowseFacet(_id: quick.id, count: 0).typeTitle, quick.title)
}
check("pressing a type picks it", W.toggledType(current: "", pressed: "movie"), "movie")
check("pressing another type replaces it", W.toggledType(current: "tv", pressed: "movie"), "movie")
check("pressing the chosen type clears it", W.toggledType(current: "movie", pressed: "movie"), "")

if failures.isEmpty {
    print("Library player: \(checks) checks passed")
} else {
    print("Library player: \(failures.count) of \(checks) FAILED")
    for f in failures { print("  - \(f)") }
    exit(1)
}
