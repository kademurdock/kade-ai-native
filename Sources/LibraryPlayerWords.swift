import Foundation

/// Nov 10 2026: the Library player's words and small rules, in one plain file
/// with no SwiftUI or audio in it, so `run-library-player-tests.sh` can check
/// them on any machine with a Swift compiler.
///
/// What it settles:
///   - how a time is SPOKEN ("2 minutes 5 seconds", never "2 colon 05");
///   - how far one VoiceOver swipe on the position slider moves (a two-hour
///     film is 720 swipes at ten seconds each, so the step grows with length);
///   - the one status line the player shows for sight and reads for VoiceOver;
///   - when the part controls mean anything (a thirty-second commercial has
///     one part, so Previous part, Next part and the Part menu could only ever
///     answer "this is the last part");
///   - the quick type buttons over the catalog.
enum LibraryPlayerWords {

    // MARK: time, for the eye

    /// "0:40", "12:05", "1:02:05". The same shape as the player's own clock.
    static func clock(_ seconds: Double) -> String {
        let t = whole(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        let mm = m < 10 ? "0\(m)" : "\(m)"
        let ss = s < 10 ? "0\(s)" : "\(s)"
        return h > 0 ? "\(h):\(mm):\(ss)" : "\(m):\(ss)"
    }

    // MARK: time, for the ear

    /// "40 seconds", "2 minutes 5 seconds", "1 hour 2 minutes". Past an hour
    /// the seconds are left out: nobody steers a film by the second.
    static func spokenClock(_ seconds: Double) -> String {
        let t = whole(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        var bits: [String] = []
        if h > 0 { bits.append(h == 1 ? "1 hour" : "\(h) hours") }
        if m > 0 { bits.append(m == 1 ? "1 minute" : "\(m) minutes") }
        if h == 0 && (s > 0 || bits.isEmpty) { bits.append(s == 1 ? "1 second" : "\(s) seconds") }
        return bits.joined(separator: " ")
    }

    /// The slider's spoken value: "40 seconds of 2 minutes 5 seconds".
    static func spokenPosition(_ position: Double, of duration: Double) -> String {
        guard whole(duration) > 0 else { return spokenClock(position) }
        return spokenClock(min(position, duration)) + " of " + spokenClock(duration)
    }

    // MARK: one swipe on the slider

    /// Ten seconds up to ten minutes, thirty up to an hour, a minute past it.
    static func seekStep(duration: Double) -> Double {
        let t = whole(duration)
        if t > 3600 { return 60 }
        if t > 600 { return 30 }
        return 10
    }

    /// The slider's hint, naming the step it will really take.
    static func seekHint(duration: Double) -> String {
        "Swipe up or down to move " + spokenClock(seekStep(duration: duration)) + " at a time."
    }

    // MARK: the status line

    /// What the line shows when nothing is being said: where a recording is
    /// and how much is left, or which chapter a book is on.
    static func restingStatus(isAudio: Bool, position: Double, duration: Double, part: Int, partCount: Int) -> String {
        if isAudio {
            guard whole(duration) > 0 else { return partCount > 1 ? partWords(isAudio: true, part: part, partCount: partCount) : "" }
            let at = min(max(0, position), duration)
            var line = clock(at) + " of " + clock(duration) + " \u{00B7} " + clock(duration - at) + " left"
            if partCount > 1 { line += " \u{00B7} " + partWords(isAudio: true, part: part, partCount: partCount) }
            return line
        }
        return partCount > 0 ? partWords(isAudio: false, part: part, partCount: partCount) : ""
    }

    /// The same, as VoiceOver reads it when she touches the line.
    static func spokenRestingStatus(isAudio: Bool, position: Double, duration: Double, part: Int, partCount: Int) -> String {
        if isAudio {
            guard whole(duration) > 0 else { return partCount > 1 ? partWords(isAudio: true, part: part, partCount: partCount) : "" }
            let at = min(max(0, position), duration)
            var line = spokenPosition(at, of: duration) + ", " + spokenClock(duration - at) + " left"
            if partCount > 1 { line += ", " + partWords(isAudio: true, part: part, partCount: partCount) }
            return line
        }
        return partCount > 0 ? partWords(isAudio: false, part: part, partCount: partCount) : ""
    }

    /// "Part 2 of 5", "Chapter 3 of 12". `part` is zero-based.
    static func partWords(isAudio: Bool, part: Int, partCount: Int) -> String {
        let n = max(0, part) + 1
        return "\(isAudio ? "Part" : "Chapter") \(n) of \(max(partCount, n))"
    }

    /// What the line shows: a fresh message first, then why the book paused
    /// itself, then the resting line.
    static func status(message: String, pausedFor: String?, resting: String) -> String {
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { return said }
        if let why = pausedFor?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty { return "Paused for \(why)" }
        return resting
    }

    /// How long a message stays on the line: longer for longer words, never
    /// under six seconds or over fifteen.
    static func statusSeconds(for message: String) -> Double {
        let words = message.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        return min(15, max(6, 3 + Double(words) * 0.45))
    }

    // MARK: parts

    /// Previous part, Next part and the Part menu only when there is more
    /// than one part to move between.
    static func showsPartControls(partCount: Int) -> Bool { partCount > 1 }

    /// The Play button's word. "Resume" after the book paused itself for a
    /// call or a voice message, the same word the Now Playing bar uses.
    static func playWord(playing: Bool, pausedFor: String?) -> String {
        if playing { return "Pause" }
        return (pausedFor ?? "").isEmpty ? "Play" : "Resume"
    }

    // MARK: quick types over the catalog

    /// A quick type button: the catalog's own type id and its word.
    struct QuickType: Equatable, Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    /// Always the same buttons in the same order, so the row never moves
    /// when the catalog loads. Each id is one the catalog's Type menu sends.
    static let quickTypes: [QuickType] = [
        QuickType(id: "movie", title: "Movies", symbol: "film"),
        QuickType(id: "tv", title: "Television", symbol: "tv"),
        QuickType(id: "commercials", title: "Commercials", symbol: "megaphone"),
        QuickType(id: "radio", title: "Radio", symbol: "radio"),
        QuickType(id: "music", title: "Music", symbol: "music.note"),
        QuickType(id: "audiobook", title: "Audiobooks", symbol: "headphones"),
        QuickType(id: "book", title: "Books", symbol: "book.closed"),
        QuickType(id: "newspaper", title: "Newspapers", symbol: "newspaper"),
    ]

    /// Pressing the chosen type again clears it; pressing another picks it.
    static func toggledType(current: String, pressed: String) -> String {
        current == pressed ? "" : pressed
    }

    // MARK: private

    /// A whole, safe number of seconds. A length from the server or the
    /// player is never trusted to be a number that fits (LibraryWords.length).
    private static func whole(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(Swift.min(seconds, 1_000_000_000).rounded(.down))
    }
}
