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
// file, and its captions file is empty, so most likely something switched
// that track back on (see DescribedVideoPlayer.swift, 3: which player and
// what switched it are not known yet). The rule itself lives here, pure, so
// DescribedCaptionsTests checks it with no phone.

/// What the player does with the MP4's own text tracks.
enum DescribedCaptionPlan: Equatable {
    /// VoiceOver on, not asked to read, film on the phone: every text track
    /// off and held off, and the app draws the captions (only when the film
    /// has dialogue) for anyone watching with her.
    case quiet(draws: Bool)
    /// VoiceOver on, asked to read, film on the phone: the Captions track and
    /// never another, held. A film with no dialogue has no Captions track, so
    /// nothing shows. The system is never asked to pick: on such a film its
    /// pick is "Audio descriptions (text)", which the narrator already says.
    case reads
    /// No VoiceOver, or AirPlay, and the film has dialogue: the Captions track.
    case captions
    /// No VoiceOver, or AirPlay, and no dialogue: nothing is shown.
    case off
    /// No VoiceOver, or AirPlay, and the captions file could not be read:
    /// left to the system.
    case automatic

    /// With VoiceOver on and the film on the phone, the player chooses, even
    /// before the captions file has been read (`hasDialogue` nil), so not one
    /// caption slips out while it downloads.
    static func choose(voiceOver: Bool, readAloud: Bool, external: Bool, hasDialogue: Bool?) -> DescribedCaptionPlan {
        if voiceOver && !external { return readAloud ? .reads : .quiet(draws: hasDialogue == true) }
        switch hasDialogue {
        case .some(true): return .captions
        case .some(false): return .off
        case .none: return .automatic
        }
    }

    /// True while VoiceOver could read over the film: the player's choice
    /// holds against AVPlayer, AVKit and her settings. Otherwise a pick in
    /// AVKit's subtitle menu stays the viewer's own.
    var held: Bool {
        switch self {
        case .quiet, .reads: return true
        case .captions, .off, .automatic: return false
        }
    }

    /// Whether AVPlayer may pick text tracks from her accessibility settings
    /// (Subtitles & Captioning's Closed Captions + SDH, a subtitle language).
    /// Never while held: that automatic pick is what turns a switched-off
    /// track back on.
    var systemMayPick: Bool { !held }

    /// The text track to show, as its place in the phone's list of them (nil:
    /// none). `captions` is captionsTrack's answer. `.automatic` leaves the
    /// choice to the system instead.
    func track(captions: Int?) -> Int? {
        switch self {
        case .reads, .captions: return captions
        case .quiet, .off, .automatic: return nil
        }
    }

    /// True when the plan is held and the track showing (its place in the
    /// list, nil for none) is not the one the player chose: something
    /// switched a track behind the player's back, so its choice goes back.
    func mustRestore(showing: Int?, captions: Int?) -> Bool {
        held && showing != track(captions: captions)
    }

    /// Which text track is "Captions", as its place in the phone's list, or
    /// nil when the copy has none or the phone cannot tell. `names` is what
    /// the phone says about each track, in order: its display name and any
    /// titles. media.ts titles them "Captions" and "Audio descriptions
    /// (text)", Captions first, and a copy has both only when the film has
    /// dialogue. So a name decides first (exactly "Captions"; any name that
    /// mentions descriptions rules a track out); failing that, the first
    /// track is Captions when there are two, or one and the film has dialogue.
    static func captionsTrack(names: [[String]], hasDialogue: Bool?) -> Int? {
        let describes = names.indices.filter { place in
            names[place].contains { $0.lowercased().contains("description") }
        }
        let named = names.indices.first { place in
            !describes.contains(place)
                && names[place].contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "captions" }
        }
        if let named { return named }
        guard let first = names.indices.first, !describes.contains(first),
              names.count >= 2 || hasDialogue == true else { return nil }
        return first
    }
}
