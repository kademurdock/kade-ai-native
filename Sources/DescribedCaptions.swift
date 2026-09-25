import Foundation

// MARK: - Captions the app draws itself (Sep 25 2026, Part 291)
//
// Pure Foundation on purpose, so DescribedCaptionsTests builds with the
// open-source Swift toolchain (run-caption-tests.sh), no Mac needed.
//
// The described copy's captions.vtt is written by the server
// (packages/api/src/description/transcript.ts, captionTrack + webVtt):
//   WEBVTT
//
//   1
//   00:00:00.000 --> 00:00:02.670
//   Speaker 1: It's April
//   1, the day of the fool.
//
// Times are in the DESCRIBED copy's own time, the same times as the MP4's
// text track, so they line up with the player's clock even when the picture
// was frozen for a long description. Captions never overlap: the server ends
// each one before the next begins.

/// One caption line.
struct DescribedCaptionCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum DescribedCaptions {
    /// Every readable cue, in time order. Hours are optional, CRLF is fine,
    /// the two lines of a cue become one line, and &amp; &lt; &gt; are
    /// unescaped (the same rules as the website's parseVtt and vttText).
    /// A block without a readable time, or with no words, is skipped.
    static func parse(_ text: String) -> [DescribedCaptionCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [DescribedCaptionCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let sides = lines[timing].components(separatedBy: "-->")
            guard sides.count == 2 else { continue }
            // "00:00:02.670 align:start" -> "00:00:02.670"
            let endStamp = sides[1]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .first ?? ""
            guard let start = seconds(sides[0]), let end = seconds(endStamp), end > start else { continue }
            let words = lines[(timing + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard !words.isEmpty else { continue }
            cues.append(DescribedCaptionCue(start: start, end: end, text: words))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// The caption on screen at `time`: shown from its start up to (not
    /// including) its end; "" between captions.
    static func caption(at time: Double, in cues: [DescribedCaptionCue]) -> String {
        guard time.isFinite else { return "" }
        var shown = ""
        for cue in cues {
            if cue.start > time { break }
            if time < cue.end { shown = cue.text }
        }
        return shown
    }

    /// "00:01:02.500" or "01:02.500" -> 62.5; nil for anything else.
    static func seconds(_ stamp: String) -> Double? {
        let fields = stamp.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
