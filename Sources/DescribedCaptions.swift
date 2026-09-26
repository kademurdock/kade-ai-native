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

// MARK: - Which captions the system shows (Sep 26 2026, Part 295)
//
// Her words after a Road Runner short with no dialogue at all: "the onscreen
// captioning is read out by voiceover still and talks over the film". That
// copy's only text track is "Audio descriptions (text)", switched off in the
// file, so something on the phone switched it back on (see
// DescribedVideoPlayer.swift, 2). The rule itself lives here, pure, so
// DescribedCaptionsTests checks it with no phone.

/// What the player does with the MP4's own text tracks.
enum DescribedCaptionPlan: Equatable {
    /// VoiceOver on, not asked to read, film on the phone: every text track
    /// off and kept off, and the app draws the captions (only when the film
    /// has dialogue) for anyone watching with her.
    case quiet(draws: Bool)
    /// The Captions track: media.ts puts it FIRST whenever there is dialogue.
    case captions
    /// No dialogue: the only text track would be "Audio descriptions
    /// (text)", which the narrator already says, so nothing is shown.
    case off
    /// The captions file could not be read: left to the system.
    case automatic

    /// Quiet wins whenever VoiceOver could read over the film, even before
    /// the captions file has been read (`hasDialogue` nil), so not one
    /// caption slips out while it downloads.
    static func choose(voiceOver: Bool, readAloud: Bool, external: Bool, hasDialogue: Bool?) -> DescribedCaptionPlan {
        if voiceOver && !readAloud && !external { return .quiet(draws: hasDialogue == true) }
        switch hasDialogue {
        case .some(true): return .captions
        case .some(false): return .off
        case .none: return .automatic
        }
    }

    /// Whether AVPlayer may pick text tracks from her accessibility settings
    /// (Subtitles & Captioning's Closed Captions + SDH, a subtitle language).
    /// Never while quiet: that automatic pick is what turns a switched-off
    /// track back on.
    var systemMayPick: Bool {
        if case .quiet = self { return false }
        return true
    }

    /// True when a text track has been switched on behind the player's back
    /// (AVKit, AVPlayer, her settings) and must go off again.
    func mustSwitchOff(trackShowing: Bool) -> Bool {
        if case .quiet = self { return trackShowing }
        return false
    }
}
