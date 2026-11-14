import Foundation

// MARK: - Tellavision "Follow along" (Nov 14 2026)
//
// Her phone listens to a film playing on her TV, finds its place with the
// syncprint fingerprint, and speaks the described video's lines in the gaps,
// in her own VoiceOver voice. The plan: TELLAVISION_SYNC_DESIGN_2026-11-13.md,
// Part 5.3 (the feature) and 5.1 (track.json, binding: the website builds it).
//
// This file is plain Foundation, so run-follow-along-tests.sh tests every rule
// here without a phone: the track, every sentence the phone says, the time
// words, the settings, the voice speed, the 16-second memory, how loud a clip
// is, the rules that turn what the matcher says into what she hears, the
// lines held for a pause, the little sounds, and the numbers-only test report.
//
// FollowAlongEngine.swift is the one doorway to syncprint.js (JavaScriptCore);
// FollowAlongAudio.swift is the microphone, the speech and the audio session;
// FollowAlongStore.swift keeps tracks on the phone; FollowAlongView.swift is
// the sheet.

// MARK: - The track (design 5.1)

/// One description line, with its window in film seconds.
struct FollowCue: Equatable {
    let id: String
    /// The window: the earliest start and the latest finish.
    let startSec: Double
    let endSec: Double
    /// When the thing happens, and the last sensible moment for it.
    let at: Double?
    let until: Double?
    let text: String
    let shortText: String?
    /// 1 to 3; 1 is the least important.
    let importance: Int
    /// The line reads text from the screen.
    let reading: Bool
    /// What the server expected: full, short or none.
    let fit: String?
}

/// track.json: the lines of one film (or one part of it) and what the
/// fingerprint is. Every field is read leniently, the describer's way: a
/// number sent as text still counts, a broken line is left out.
struct FollowTrack: Equatable {
    struct Span: Equatable {
        let startSec: Double
        let endSec: Double
    }

    struct Print: Equatable {
        let format: Int
        let bytes: Int
        let sha256: String
        /// Where second 0 of the fingerprint sits in the film, when the
        /// server says so (see printOffset).
        let startSec: Double?
    }

    struct Pace: Equatable {
        let secPerChar: Double?
        let rate: Double?
        let maxRate: Double?
    }

    struct Credit: Equatable {
        let start: String?
        let end: String?
    }

    static let formatName = "kade-follow-track"
    static let newestVersion = 1

    let format: String
    let version: Int
    let job: String
    let copyVersion: Int
    let title: String
    let language: String
    let filmSeconds: Double
    let covers: Span
    let print: Print
    let plannedAt: Pace?
    let credit: Credit?
    /// Sorted by start.
    let cues: [FollowCue]
    let quiet: [Span]
    let warning: String?

    enum Problem: Error, Equatable {
        case notATrack
        case newerVersion
        case noPrint

        /// What she hears.
        var words: String {
            switch self {
            case .notATrack: return "This follow-along track could not be read. Get it again from the video."
            case .newerVersion: return "This track needs a newer Kade-AI. Update the app, then try again."
            case .noPrint: return "This follow-along track has no fingerprint. Get it again from the video."
            }
        }
    }

    /// Reads track.json. Throws a Problem when it is not a track this app can use.
    static func read(_ data: Data) throws -> FollowTrack {
        let raw: RawTrack
        do {
            raw = try JSONDecoder().decode(RawTrack.self, from: data)
        } catch {
            throw Problem.notATrack
        }
        guard raw.format == formatName else { throw Problem.notATrack }
        let version = raw.version ?? 1
        guard version >= 1 else { throw Problem.notATrack }
        guard version <= newestVersion else { throw Problem.newerVersion }
        guard let print = raw.print, print.bytes > 0, isSHA256(print.sha256) else { throw Problem.noPrint }
        let cues = (raw.cues ?? []).compactMap { $0.value }.sorted {
            $0.startSec == $1.startSec ? $0.id < $1.id : $0.startSec < $1.startSec
        }
        let lastEnd = cues.map { $0.endSec }.max() ?? 0
        var film = raw.filmSeconds ?? 0
        if !(film > 0) { film = max(raw.covers?.endSec ?? 0, lastEnd) }
        guard film > 0 else { throw Problem.notATrack }
        let start = min(max(0, raw.covers?.startSec ?? 0), film)
        var end = raw.covers?.endSec ?? film
        if !(end > start) || end > film { end = film }
        let quiet = (raw.quiet ?? []).compactMap { pair -> Span? in
            guard pair.count == 2, pair[0].isFinite, pair[1].isFinite, pair[1] > pair[0] else { return nil }
            return Span(startSec: pair[0], endSec: pair[1])
        }
        let title = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = (raw.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return FollowTrack(
            format: formatName,
            version: version,
            job: raw.job ?? "",
            copyVersion: raw.copyVersion ?? 1,
            title: title.isEmpty ? "Your film" : title,
            language: language.isEmpty ? "en" : language,
            filmSeconds: film,
            covers: Span(startSec: start, endSec: end),
            print: Print(format: print.format ?? 1, bytes: print.bytes, sha256: print.sha256.lowercased(),
                         startSec: print.startSec),
            plannedAt: raw.plannedAt,
            credit: raw.credit,
            cues: cues,
            quiet: quiet,
            warning: raw.warning
        )
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }

    /// The track does not reach both ends of the film.
    var isPart: Bool {
        covers.startSec > 1 || covers.endSec < filmSeconds - 1
    }

    /// The track reaches the end of the film (so the closing credit belongs).
    var reachesFilmEnd: Bool {
        covers.endSec >= filmSeconds - 1
    }

    /// Where second 0 of the fingerprint sits in the film. A fingerprint of
    /// the whole film starts at 0. A part's fingerprint, made from that
    /// part's own sound, starts where the part does: a print that starts at
    /// 0 could not reach the part's end, so it must start at the part.
    func printOffset(printSeconds: Double) -> Double {
        if let start = print.startSec, start.isFinite, start >= 0 { return start }
        if covers.startSec > 1, printSeconds > 0, printSeconds + 1 < covers.endSec { return covers.startSec }
        return 0
    }

    /// Where the track ends, in fingerprint seconds.
    func endInPrint(printSeconds: Double) -> Double {
        let end = covers.endSec - printOffset(printSeconds: printSeconds)
        return printSeconds > 0 ? min(end, printSeconds) : end
    }
}

// The track as it arrives, before it is checked.
private struct RawTrack: Decodable {
    struct RawSpan: Decodable {
        let startSec: Double?
        let endSec: Double?
        enum CodingKeys: String, CodingKey { case startSec, endSec }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startSec = c.faNumber(.startSec)
            endSec = c.faNumber(.endSec)
        }
    }

    struct RawPrint: Decodable {
        let format: Int?
        let bytes: Int
        let sha256: String
        let startSec: Double?
        enum CodingKeys: String, CodingKey { case format, bytes, sha256, startSec }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = c.faInt(.format)
            bytes = c.faInt(.bytes) ?? 0
            sha256 = (c.faString(.sha256) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            startSec = c.faNumber(.startSec)
        }
    }

    struct Maybe: Decodable {
        let value: FollowCue?
        init(from decoder: Decoder) throws {
            value = try? FollowCue(from: decoder)
        }
    }

    let format: String?
    let version: Int?
    let job: String?
    let copyVersion: Int?
    let title: String?
    let language: String?
    let filmSeconds: Double?
    let covers: RawSpan?
    let print: RawPrint?
    let plannedAt: FollowTrack.Pace?
    let credit: FollowTrack.Credit?
    let cues: [Maybe]?
    let quiet: [[Double]]?
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case format, version, job, copyVersion, title, language, filmSeconds, covers, print
        case plannedAt, credit, cues, quiet, warning
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.faString(.format)
        version = c.faInt(.version)
        job = c.faString(.job)
        copyVersion = c.faInt(.copyVersion)
        title = c.faString(.title)
        language = c.faString(.language)
        filmSeconds = c.faNumber(.filmSeconds)
        covers = try? c.decodeIfPresent(RawSpan.self, forKey: .covers)
        print = try? c.decodeIfPresent(RawPrint.self, forKey: .print)
        plannedAt = try? c.decodeIfPresent(FollowTrack.Pace.self, forKey: .plannedAt)
        credit = try? c.decodeIfPresent(FollowTrack.Credit.self, forKey: .credit)
        cues = try? c.decodeIfPresent([Maybe].self, forKey: .cues)
        quiet = try? c.decodeIfPresent([[Double]].self, forKey: .quiet)
        warning = c.faString(.warning)
    }
}

extension FollowTrack.Pace: Decodable {
    enum CodingKeys: String, CodingKey { case secPerChar, rate, maxRate }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        secPerChar = c.faNumber(.secPerChar)
        rate = c.faNumber(.rate)
        maxRate = c.faNumber(.maxRate)
    }
}

extension FollowTrack.Credit: Decodable {
    enum CodingKeys: String, CodingKey { case start, end }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let first = (c.faString(.start) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let last = (c.faString(.end) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        start = first.isEmpty ? nil : first
        end = last.isEmpty ? nil : last
    }
}

extension FollowCue: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, startSec, endSec, at, until, text, shortText, importance, reading, fit
    }

    /// A line without an id, a window or words cannot be used: it throws,
    /// and the track leaves it out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let words = (c.faString(.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = c.faString(.id), !key.isEmpty,
              let start = c.faNumber(.startSec), let end = c.faNumber(.endSec),
              start >= 0, end >= start, !words.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "A line needs an id, a window and words."))
        }
        id = key
        startSec = start
        endSec = end
        at = c.faNumber(.at)
        until = c.faNumber(.until)
        text = words
        let short = (c.faString(.shortText) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        shortText = short.isEmpty ? nil : short
        importance = min(3, max(1, c.faInt(.importance) ?? 2))
        reading = c.faBool(.reading) ?? false
        fit = c.faString(.fit)
    }
}

/// Lenient reading for this file (the describer's own helpers live in
/// DescribedVideoService.swift, which the tests do not compile).
private extension KeyedDecodingContainer {
    func faNumber(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number.isFinite ? number : nil }
        if let text = try? decodeIfPresent(String.self, forKey: key),
           let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite {
            return number
        }
        return nil
    }

    func faInt(_ key: Key) -> Int? {
        guard let number = faNumber(key), abs(number) < 1e15 else { return nil }
        return Int(number.rounded())
    }

    func faString(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? decodeIfPresent(Double.self, forKey: key), number.isFinite {
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        }
        return nil
    }

    func faBool(_ key: Key) -> Bool? {
        if let flag = try? decodeIfPresent(Bool.self, forKey: key) { return flag }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Every sentence the phone says (design 5.3, "The exact words")

/// The phone says these with its own speech engine, so they work with the
/// screen locked; they are not VoiceOver announcements. Plain words, short
/// sentences. The design's numbers are in the comments.
enum FollowWords {
    /// 1. She pressed Start listening.
    static let listening = "Listening for your film."
    /// 2. 20 seconds with no match.
    static let stillListening = "Still listening. Turn the TV up, or move the phone closer."
    /// 3. 60 seconds with no match.
    static let cantFind = "I can't find this film yet. Check that it is playing, and that it is the same film."
    /// 6. The room went quiet where the film should be loud.
    static let paused = "The film seems to be paused. I will carry on when it plays."
    /// 7. There is sound, but not this film.
    static let lost = "I lost the film. I am listening for it."
    /// 10. Her pause and her resume.
    static let descriptionsPaused = "Descriptions paused."
    static let descriptionsOn = "Descriptions on."
    /// 11.
    static let earbudsGone = "Earbuds disconnected. Descriptions paused."
    /// 12. After the closing credit.
    static let ended = "The film has ended. Follow along is off."
    /// The end of a track that covers only part of the film (5.3 failure cases).
    static let trackEnds = "This track ends here. Follow along is off."
    /// 13. She pressed Stop.
    static let stopped = "Follow along is off. The microphone is off."
    /// 14.
    static let noFilm = "I have not heard the film for 10 minutes. Follow along is off."
    /// 16. A notification after a call, and the screen's words.
    static let callNotification = "Follow along stopped for a call. Open Kade-AI to carry on."
    static let stoppedByCall = "Stopped by a call."
    /// 17. On the screen.
    static let micDenied = "Kade-AI is not allowed to use the microphone. Open Settings, then Kade-AI, and turn Microphone on."
    /// Failure cases (design 5.3).
    static let couldNotStart = "Follow along could not start on this phone."
    static let micBusy = "The microphone is busy. Try again after your call."
    static let notPhoneMic = "Follow along needs your phone's own microphone, and another microphone is in use. Unplug it, then press Start listening."
    static let stoppedForProblem = "Follow along stopped. Press Start listening to carry on."
    static let damagedOnPhone = "The track on this phone is damaged. Delete it, then get it again from the video."
    static let damagedDownload = "The follow-along track did not download whole. Try again."
    static let making = "The follow-along track is being made. Try again in a minute or two."
    static let notReady = "A follow-along track is not ready for this video."
    static let gone = "The original video is no longer on the server, so a follow-along track cannot be made. Describe it again to get one."
    /// The screen before anything is said, and while it gets ready.
    static let ready = "Press Start listening, then start the film on your TV."
    static let preparing = "Getting the track ready."
    /// The button on the described video screen, and its hint.
    static let button = "Follow along with my TV"
    static let buttonHint = "Your phone listens for the film on another screen and speaks the descriptions in step."
    /// Shown above the Start button. Pressing Start after it is her consent.
    static let privacy = "Your phone listens only to find your place in the film. The sound is checked on this phone. It is never saved and never sent anywhere. The microphone stays on until you press Stop or the film ends."

    /// 4. "Found your place: 12 minutes in." In the first minute: "the beginning."
    static func found(_ filmSec: Double) -> String {
        "Found your place: \(place(filmSec))."
    }

    /// 8.
    static func backInStep(_ filmSec: Double) -> String {
        "Back in step: \(place(filmSec))."
    }

    /// 9. "You skipped ahead to 1 hour 5 minutes." or "You went back to 31 minutes."
    static func skipped(to filmSec: Double, ahead: Bool) -> String {
        ahead ? "You skipped ahead to \(clock(filmSec))." : "You went back to \(clock(filmSec))."
    }

    /// 15. Where am I.
    static func whereAmI(_ filmSec: Double?) -> String {
        guard let filmSec else { return "Not in step. Listening." }
        return upperFirst(place(filmSec)) + ", in step."
    }

    /// 5. Said once after locking on, when the track covers only part of the film.
    static func covers(startSec: Double, endSec: Double, filmSeconds: Double) -> String? {
        let fromStart = startSec <= 1
        let toEnd = endSec >= filmSeconds - 1
        if fromStart && toEnd { return nil }
        if fromStart { return "This track covers the first \(length(endSec))." }
        if toEnd { return "This track covers from \(clock(startSec)) to the end." }
        return "This track covers from \(clock(startSec)) to \(clock(endSec))."
    }

    /// 6, with the lines held because they did not fit (her choice: a soft
    /// chime, then they are read while the film is paused).
    static func paused(held lines: [String]) -> String {
        guard !lines.isEmpty else { return paused }
        let intro = lines.count == 1 ? "Here is the line I held." : "Here are the \(lines.count) lines I held."
        let body = lines.map { sentence($0) }.joined(separator: " ")
        return "The film seems to be paused. \(intro) \(body) I will carry on when it plays."
    }

    // MARK: Time words

    /// "12 minutes in", "1 hour in", "1 hour 5 minutes in"; "the beginning"
    /// in the first minute. Whole minutes, rounded down.
    static func place(_ seconds: Double) -> String {
        let words = clock(seconds)
        return words == beginning ? words : words + " in"
    }

    /// "31 minutes", "1 hour", "1 hour 5 minutes"; "the beginning" in the
    /// first minute. Whole minutes, rounded down.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return beginning }
        return hoursAndMinutes(Int(seconds / 60))
    }

    /// A length, "1 hour 30 minutes", to the nearest minute (at least 1 minute).
    static func length(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "1 minute" }
        return hoursAndMinutes(max(1, Int((seconds / 60).rounded())))
    }

    static let beginning = "the beginning"

    private static func hoursAndMinutes(_ totalMinutes: Int) -> String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let hourWords = hours == 1 ? "1 hour" : "\(hours) hours"
        let minuteWords = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        if hours == 0 { return minuteWords }
        if minutes == 0 { return hourWords }
        return "\(hourWords) \(minuteWords)"
    }

    static func upperFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// A line as a sentence: it ends with a stop, a question or an exclamation.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?\u{2026}\"'\u{201D}".contains(last) ? trimmed : trimmed + "."
    }
}

// MARK: - Her settings (design 5.3, Settings)

struct FollowAlongSettings: Codable, Equatable {
    enum Voice: String, Codable, CaseIterable {
        /// AVSpeechSynthesizer, her VoiceOver voice and speed when VoiceOver is on.
        case phone
        /// The recorded narrator: greyed out until a track carries clips.
        case narrator
    }

    enum Amount: String, Codable, CaseIterable {
        case everything
        case important
    }

    var voice: Voice = .phone
    /// nil: the same as VoiceOver (or the phone's usual speed without it).
    /// Otherwise 0.75 to 2.
    var speed: Double? = nil
    var amount: Amount = .everything
    /// The two little sounds (found, lost). nil: follows the app's Sound effects setting.
    var sounds: Bool? = nil
    /// The soft chime that means "pause your TV and I will tell you more".
    var heldChime: Bool = true
    /// Seconds; above 0 starts each line earlier, below 0 later. -1 to 1 in tenths.
    var nudge: Double = 0

    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static let key = "kade.followAlong.settings"

    enum CodingKeys: String, CodingKey { case voice, speed, amount, sounds, heldChime, nudge }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voice = (try? c.decodeIfPresent(Voice.self, forKey: .voice)) ?? .phone
        if let value = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? nil {
            speed = Self.clampSpeed(value)
        }
        amount = (try? c.decodeIfPresent(Amount.self, forKey: .amount)) ?? .everything
        sounds = (try? c.decodeIfPresent(Bool.self, forKey: .sounds)) ?? nil
        heldChime = ((try? c.decodeIfPresent(Bool.self, forKey: .heldChime)) ?? nil) ?? true
        nudge = Self.clampNudge(((try? c.decodeIfPresent(Double.self, forKey: .nudge)) ?? nil) ?? 0)
    }

    static func load(_ defaults: UserDefaults = .standard) -> FollowAlongSettings {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(FollowAlongSettings.self, from: data) else {
            return FollowAlongSettings()
        }
        return saved
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// The little sounds are on: her choice here, else the app's Sound effects.
    func soundsOn(soundEffects: Bool) -> Bool {
        sounds ?? soundEffects
    }

    static func clampSpeed(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return speeds.min(by: { abs($0 - value) < abs($1 - value) })
    }

    static func clampNudge(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(1, max(-1, value)) * 10).rounded() / 10
    }

    /// "On time", "0.3 seconds earlier", "1 second later".
    static func nudgeWords(_ value: Double) -> String {
        let tenths = Int((clampNudge(value) * 10).rounded())
        if tenths == 0 { return "On time" }
        let size = abs(tenths)
        let amount = size == 10 ? "1 second" : "0.\(size) seconds"
        return tenths > 0 ? "\(amount) earlier" : "\(amount) later"
    }

    /// "Same as VoiceOver" (or "Usual speed" without VoiceOver), or "1.5 times".
    static func speedWords(_ value: Double?, voiceOver: Bool) -> String {
        guard let value else { return voiceOver ? "Same as VoiceOver" : "Usual speed" }
        return number(value) + " times"
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// The AVSpeechUtterance rate for a speed she chose: the usual rate at
    /// 1, more or less in steps of a quarter, never past the engine's limits.
    static func speechRate(for speed: Double, usual: Float, slowest: Float, fastest: Float) -> Float {
        let rate = usual + Float(speed - 1) * 0.25
        return min(fastest, max(slowest, rate))
    }
}

// MARK: - How fast her phone's voice speaks (design 5.3)

/// The phone times each line it speaks, keeps the middle value of the last
/// ten, and hands the planner seconds per letter. The status sentences at
/// the start give a first reading. A line that ran past its window makes the
/// number go up.
struct FollowPace: Equatable {
    /// syncprint's own guess, before anything is measured.
    static let fallback = 0.065
    static let keep = 10
    private(set) var samples: [Double] = []
    /// More than 1 after lines ran past their windows.
    private(set) var stretch = 1.0

    /// A line of `characters` letters took `seconds` from its first sound to its last.
    mutating func measured(characters: Int, seconds: Double) {
        guard characters >= 8, seconds.isFinite, seconds > 0.2, seconds < 60 else { return }
        let value = seconds / Double(characters)
        guard value > 0.01, value < 0.3 else { return }
        samples.append(value)
        if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }
    }

    /// A description ran past the end of its window.
    mutating func overran() {
        stretch = min(1.5, stretch * 1.1)
    }

    /// A description ended in its window: the allowance settles back.
    mutating func inTime() {
        stretch = max(1, stretch * 0.98)
    }

    var median: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Seconds per letter for the planner.
    var secPerChar: Double {
        (median ?? Self.fallback) * stretch
    }
}

// MARK: - The last 16 seconds of sound (design 5.3, the listening schedule)

/// The microphone stays open the whole time; the phone keeps only the last
/// 16 seconds, 8 kHz mono, and drops the rest. Each piece arrives with the
/// clock time it ended at; that clock is the master clock. Nothing here is
/// ever written to a file or sent anywhere.
struct FollowRing {
    static let rate = 8000.0
    let capacity: Int
    private var store: [Int16]
    /// Where the next sample goes.
    private var head = 0
    private(set) var count = 0
    /// The clock time just after the newest sample; nil when empty.
    private(set) var endTime: Double?

    init(seconds: Double = 16) {
        capacity = max(1, Int(seconds * Self.rate))
        store = [Int16](repeating: 0, count: capacity)
    }

    var seconds: Double { Double(count) / Self.rate }

    /// Adds sound that ended at `end`. When the clock jumps (the microphone
    /// stopped and started again, or a piece went missing) the memory starts
    /// afresh, so no clip ever joins two stretches of sound.
    mutating func append(_ samples: [Int16], endingAt end: Double) {
        guard !samples.isEmpty, end.isFinite else { return }
        if let last = endTime {
            let expected = last + Double(samples.count) / Self.rate
            if abs(end - expected) > 0.25 { clear() }
        }
        var source = samples[...]
        if source.count > capacity { source = source.suffix(capacity) }
        for sample in source {
            store[head] = sample
            head = (head + 1) % capacity
        }
        count = min(capacity, count + source.count)
        endTime = end
    }

    /// The last `seconds` of sound, oldest first, with the clock time of its
    /// first sample. nil when the memory holds less than that.
    func last(_ seconds: Double) -> (samples: [Int16], start: Double)? {
        guard let endTime, seconds > 0 else { return nil }
        let wanted = Int((seconds * Self.rate).rounded())
        guard wanted > 0, wanted <= count else { return nil }
        var out = [Int16](repeating: 0, count: wanted)
        var index = (head - wanted + capacity) % capacity
        for position in 0..<wanted {
            out[position] = store[index]
            index = (index + 1) % capacity
        }
        return (out, endTime - Double(wanted) / Self.rate)
    }

    mutating func clear() {
        head = 0
        count = 0
        endTime = nil
    }
}

// MARK: - How loud a clip is

enum FollowLoudness {
    /// The level in decibels against full scale (root mean square). Digital
    /// silence gives -120.
    static func db(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 1e-6 else { return -120 }
        return max(-120, 20 * log10(rms))
    }
}

/// How loud the film sounds in her room: the middle of the last eight clips
/// that matched while in step.
struct FollowHeard: Equatable {
    private(set) var values: [Double] = []

    mutating func add(_ db: Double) {
        guard db.isFinite, db > -100 else { return }
        values.append(db)
        if values.count > 8 { values.removeFirst(values.count - 8) }
    }

    var level: Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Catches a pause quickly. The phone measures each half second of sound as
/// it arrives (cheap, no matcher). When the room has been quiet for 3
/// seconds, well under the film's heard level, it asks the matcher to check
/// now instead of waiting for its next turn; again every 4 seconds while it
/// stays quiet, at most 4 times.
struct FollowLevelWatch: Equatable {
    static let firstAfter = 6
    static let thenEvery = 8
    static let most = 4
    static let drop = FollowJudge.quietDrop
    private(set) var quietBlocks = 0
    private(set) var fired = 0

    /// One half second at `db`. True: check now.
    mutating func block(db: Double, heard: Double?) -> Bool {
        guard let heard, db < heard - Self.drop else {
            quietBlocks = 0
            fired = 0
            return false
        }
        quietBlocks += 1
        guard fired < Self.most else { return false }
        let due = Self.firstAfter + fired * Self.thenEvery
        if quietBlocks >= due {
            fired += 1
            return true
        }
        return false
    }
}

// MARK: - What the matcher said, in Swift words

/// One check: a clip of the microphone's sound compared with the fingerprint.
struct FollowCheck: Equatable {
    var found = false
    /// Fingerprint seconds where the clip began.
    var filmSec: Double?
    /// syncprint's reason: ok, silence, no match, ambiguous, too short, error.
    var reason = "error"
    /// The fingerprint says the film itself is quiet there (only when a place was expected).
    var expectQuiet: Bool?
    var confidence = 0.0
    var clipSec = 0.0
    var clipDb = -120.0
    var startMono = 0.0
    var millis = 0.0
}

/// syncprint's tracker state.
struct FollowTrackerState: Equatable {
    enum Status: String {
        case searching, locked, holding, lost
    }

    var status: Status = .searching
    /// Fingerprint seconds now (while locked or holding).
    var filmSec: Double?
    var sinceLastFixSec: Double?
    var justJumped = false
    var lastJumpSec = 0.0
    var lastBackJumpMono: Double?
    var lastBackJumpFilmSec: Double?
    var misses = 0
    var doubt = false
}

/// When to listen next, and for how long.
struct FollowListen: Equatable {
    var wait: Double
    var clip: Double
}

struct FollowPlanOptions: Equatable {
    var secPerChar: Double
    /// How long the speech engine takes to make its first sound.
    var leadSec = 0.15
    /// The planner's half second of grace.
    var toleranceSec = 0.5
    var importantOnly = false
}

/// syncprint's planCues answer.
struct FollowPlan: Equatable {
    enum Action: String { case speak, wait }
    var action: Action
    var id = ""
    var text = ""
    var short = false
    var estSec = 0.0
    var waitSec = 1.0
    var reason = ""

    static func waiting(_ seconds: Double, _ reason: String) -> FollowPlan {
        FollowPlan(action: .wait, waitSec: seconds, reason: reason)
    }
}

// MARK: - The rules that turn what the matcher says into what she hears

enum FollowEvent: Equatable {
    case stillListening
    case cantFind
    /// The first lock (fingerprint seconds).
    case found(Double)
    case backInStep(Double)
    case skipped(Double, ahead: Bool)
    case paused
    case lost
    /// The track's end; `part` when the track covers only part of the film.
    case ended(part: Bool)
    case noFilm
}

/// The little sounds that go with some sentences, when Sounds is on.
enum FollowSoundKind: Hashable {
    /// Two rising notes: locked on, or back in step.
    case rising
    /// Two falling notes: lost the film, or the film paused.
    case falling
    /// The soft chime: a line did not fit; pause the TV to hear it.
    case held
}

/// Reads the matcher's checks and the tracker's state, and decides what is
/// said (design 5.3, the exact words and "Paused or lost").
struct FollowJudge: Equatable {
    enum Phase: Equatable { case searching, inStep, paused, lost, ended }

    static let stillListeningAfter = 20.0
    static let cantFindAfter = 60.0
    static let giveUpAfter = 600.0
    /// A jump this big while in step is said aloud; a smaller one is the
    /// clock being corrected.
    static let skipWordsAfter = 8.0
    /// Decibels under the film's heard level that count as "the room went quiet".
    static let quietDrop = 15.0
    /// Quiet checks in a row, where the film should be loud, that mean paused.
    static let quietChecks = 2

    /// Where the track ends, in fingerprint seconds.
    let endSec: Double
    /// The track covers only part of the film.
    let part: Bool
    private(set) var phase: Phase = .searching
    private(set) var everFound = false
    private(set) var startedAt: Double
    private(set) var lastHeardAt: Double
    private(set) var quietRun = 0
    private(set) var heard = FollowHeard()
    private var saidStill = false
    private var saidCantFind = false

    init(now: Double, endSec: Double, part: Bool) {
        self.endSec = endSec
        self.part = part
        startedAt = now
        lastHeardAt = now
    }

    /// A check was made; `state` is the tracker's state right after it.
    mutating func checked(_ check: FollowCheck, state: FollowTrackerState, now: Double) -> [FollowEvent] {
        guard phase != .ended else { return [] }
        if check.found {
            lastHeardAt = now
            quietRun = 0
            if state.status == .locked { heard.add(check.clipDb) }
        } else if seemsQuiet(check) {
            quietRun += 1
        } else {
            quietRun = 0
        }
        return follow(state)
    }

    /// Time passes (every few tenths of a second).
    mutating func tick(state: FollowTrackerState, now: Double) -> [FollowEvent] {
        guard phase != .ended else { return [] }
        var events = follow(state)
        if !everFound {
            if !saidStill, now - startedAt >= Self.stillListeningAfter {
                saidStill = true
                events.append(.stillListening)
            }
            if !saidCantFind, now - startedAt >= Self.cantFindAfter {
                saidCantFind = true
                events.append(.cantFind)
            }
        }
        if now - lastHeardAt >= Self.giveUpAfter {
            phase = .ended
            events.append(.noFilm)
            return events
        }
        if phase == .inStep, state.status == .locked, let film = state.filmSec, film >= endSec - 0.5 {
            phase = .ended
            events.append(.ended(part: part))
        }
        return events
    }

    /// A check that missed, in a room gone quiet where the film should be
    /// loud. syncprint (1.1.0 on) says "silence" itself, from how loud the
    /// film sounds in this room; the phone's own measure is a second opinion.
    func seemsQuiet(_ check: FollowCheck) -> Bool {
        guard !check.found, check.expectQuiet == false else { return false }
        if check.reason == "silence" { return true }
        guard let level = heard.level else { return false }
        return check.clipDb < level - Self.quietDrop
    }

    private mutating func follow(_ state: FollowTrackerState) -> [FollowEvent] {
        var events: [FollowEvent] = []
        if state.status == .locked, let film = state.filmSec {
            switch phase {
            case .searching:
                phase = .inStep
                everFound = true
                events.append(.found(film))
            case .paused, .lost:
                // A pause or an ad break moved the clock; that is not a skip.
                phase = .inStep
                events.append(.backInStep(film))
            case .inStep:
                if state.justJumped, abs(state.lastJumpSec) >= Self.skipWordsAfter {
                    events.append(.skipped(film, ahead: state.lastJumpSec > 0))
                }
            case .ended:
                break
            }
        }
        if phase == .inStep {
            if quietRun >= Self.quietChecks {
                phase = .paused
                events.append(.paused)
            } else if state.status == .lost {
                phase = .lost
                events.append(.lost)
            }
        }
        return events
    }

    /// The words, and the little sound, for an event. Times are fingerprint
    /// seconds; `offset` turns them into film seconds. `held` are the lines
    /// read when the film pauses. `firstCredit` is the opening credit, said
    /// once after the first lock.
    static func words(for event: FollowEvent, track: FollowTrack, offset: Double, held: [String] = [],
                      firstCredit: Bool = true) -> (text: String, sound: FollowSoundKind?) {
        switch event {
        case .stillListening:
            return (FollowWords.stillListening, nil)
        case .cantFind:
            return (FollowWords.cantFind, nil)
        case .found(let film):
            var parts = [FollowWords.found(film + offset)]
            if firstCredit, let credit = track.credit?.start { parts.append(FollowWords.sentence(credit)) }
            if let covers = FollowWords.covers(startSec: track.covers.startSec, endSec: track.covers.endSec,
                                               filmSeconds: track.filmSeconds) {
                parts.append(covers)
            }
            return (parts.joined(separator: " "), .rising)
        case .backInStep(let film):
            return (FollowWords.backInStep(film + offset), .rising)
        case .skipped(let film, let ahead):
            return (FollowWords.skipped(to: film + offset, ahead: ahead), nil)
        case .paused:
            return (FollowWords.paused(held: held), .falling)
        case .lost:
            return (FollowWords.lost, .falling)
        case .ended(let part):
            if part { return (FollowWords.trackEnds, nil) }
            if let credit = track.credit?.end { return (FollowWords.sentence(credit) + " " + FollowWords.ended, nil) }
            return (FollowWords.ended, nil)
        case .noFilm:
            return (FollowWords.noFilm, nil)
        }
    }
}

// MARK: - Lines that do not fit (her choice, Nov 14 2026)

/// A line whose window closes before it could be said is held, a soft chime
/// sounds, and the held lines are read when the film pauses. Only lines
/// whose window she was in step for are held, never ones from before she
/// found her place or skipped.
struct FollowHolder: Equatable {
    static let keep = 8
    static let chimeGap = 15.0
    static let toleranceSec = 0.5

    /// The cues sorted by the end of their window, in fingerprint seconds.
    private let byEnd: [FollowCue]
    private var cursor = 0
    private(set) var held: [FollowCue] = []
    private var lastChime = -1_000_000.0

    init(cues: [FollowCue], offset: Double) {
        byEnd = cues.map { cue in
            FollowCue(id: cue.id, startSec: cue.startSec - offset, endSec: cue.endSec - offset, at: cue.at,
                      until: cue.until, text: cue.text, shortText: cue.shortText, importance: cue.importance,
                      reading: cue.reading, fit: cue.fit)
        }.sorted { $0.endSec == $1.endSec ? $0.startSec < $1.startSec : $0.endSec < $1.endSec }
    }

    /// She is in step from `filmSec` on (found, back in step, skipped):
    /// lines from before are not hers to hold, and lines held from another
    /// part of the film mean nothing now.
    mutating func moved(to filmSec: Double) {
        held.removeAll()
        var low = 0
        var high = byEnd.count
        while low < high {
            let middle = (low + high) / 2
            if byEnd[middle].endSec + Self.toleranceSec < filmSec {
                low = middle + 1
            } else {
                high = middle
            }
        }
        cursor = low
    }

    /// The film is at `filmSec` (in step, descriptions on). Every line whose
    /// window has closed unspoken is held, once. Returns the newly held lines.
    mutating func sweep(filmSec: Double, spoken: Set<String>, importantOnly: Bool) -> [FollowCue] {
        var fresh: [FollowCue] = []
        while cursor < byEnd.count, byEnd[cursor].endSec + Self.toleranceSec < filmSec {
            let cue = byEnd[cursor]
            cursor += 1
            if spoken.contains(cue.id) { continue }
            if importantOnly && cue.importance < 2 { continue }
            held.append(cue)
            fresh.append(cue)
        }
        if held.count > Self.keep { held.removeFirst(held.count - Self.keep) }
        return fresh
    }

    /// Lines passing while descriptions are paused are let go, not held.
    mutating func pass(filmSec: Double) {
        while cursor < byEnd.count, byEnd[cursor].endSec + Self.toleranceSec < filmSec {
            cursor += 1
        }
    }

    /// Whether the chime may sound now (never two within 15 seconds).
    mutating func mayChime(now: Double) -> Bool {
        guard now - lastChime >= Self.chimeGap else { return false }
        lastChime = now
        return true
    }

    /// The held lines, oldest first, in the film's order; the list empties.
    mutating func takeAll() -> [FollowCue] {
        let lines = held.sorted { $0.startSec < $1.startSec }
        held.removeAll()
        return lines
    }
}

// MARK: - The little sounds, made in code (like WaitingChime)

enum FollowSounds {
    static let sampleRate = 22_050

    static func samples(_ kind: FollowSoundKind) -> [Int16] {
        switch kind {
        case .rising: return notes([659.25, 987.77], seconds: 0.11, peak: 0.12)
        case .falling: return notes([987.77, 659.25], seconds: 0.11, peak: 0.12)
        case .held: return bell([523.25, 783.99], seconds: 0.7, peak: 0.07)
        }
    }

    static func seconds(_ kind: FollowSoundKind) -> Double {
        Double(samples(kind).count) / Double(sampleRate)
    }

    /// Notes one after another, each swelling in over 15 ms and fading over 60 ms.
    static func notes(_ frequencies: [Double], seconds: Double, peak: Double) -> [Int16] {
        let perNote = Int((seconds * Double(sampleRate)).rounded())
        let attack = 0.015 * Double(sampleRate)
        let release = 0.06 * Double(sampleRate)
        var out: [Int16] = []
        out.reserveCapacity(perNote * frequencies.count)
        for frequency in frequencies {
            for index in 0..<perNote {
                let position = Double(index)
                let left = Double(perNote - 1 - index)
                var gain = 1.0
                if position < attack { gain = min(gain, 0.5 - 0.5 * cos(Double.pi * position / attack)) }
                if left < release { gain = min(gain, 0.5 - 0.5 * cos(Double.pi * left / release)) }
                let wave = sin(2 * Double.pi * frequency * position / Double(sampleRate))
                out.append(Int16((wave * gain * peak * 32_767).rounded()))
            }
        }
        return out
    }

    /// Notes together, struck softly and left to ring away: a bell.
    static func bell(_ frequencies: [Double], seconds: Double, peak: Double) -> [Int16] {
        let total = Int((seconds * Double(sampleRate)).rounded())
        let attack = 0.01 * Double(sampleRate)
        var out: [Int16] = []
        out.reserveCapacity(total)
        let share = peak / Double(max(1, frequencies.count))
        for index in 0..<total {
            let position = Double(index)
            var gain = exp(-4.5 * position / Double(total))
            if position < attack { gain *= 0.5 - 0.5 * cos(Double.pi * position / attack) }
            let left = Double(total - 1 - index)
            if left < 0.02 * Double(sampleRate) { gain *= left / (0.02 * Double(sampleRate)) }
            var wave = 0.0
            for frequency in frequencies { wave += sin(2 * Double.pi * frequency * position / Double(sampleRate)) }
            out.append(Int16((wave * gain * share * 32_767).rounded()))
        }
        return out
    }
}

// MARK: - The test report (design 5.5, step 10)

/// Numbers only: never film sound, never words from the film or the track.
struct FollowReport: Equatable {
    var minutesListened = 0.0
    var secondsToLock: Double?
    var checks = 0
    var failedChecks = 0
    var matchMillis: [Double] = []
    var skips = 0
    var losses = 0
    var pauses = 0
    var backInStep = 0
    var linesSpoken = 0
    var shortLines = 0
    var linesHeld = 0
    var heldLinesRead = 0
    var secondsPerLetter: Double?
    var outputDelayMillis = 0.0
    var nudgeSeconds = 0.0
    var batteryStart: Double?
    var batteryNow: Double?
    var loadMillis: Double?
    var printSeconds = 0.0
    var cues = 0

    mutating func checked(_ check: FollowCheck) {
        checks += 1
        if !check.found { failedChecks += 1 }
        if check.millis > 0 {
            matchMillis.append(check.millis)
            if matchMillis.count > 60 { matchMillis.removeFirst(matchMillis.count - 60) }
        }
    }

    mutating func note(_ event: FollowEvent) {
        switch event {
        case .skipped: skips += 1
        case .lost: losses += 1
        case .paused: pauses += 1
        case .backInStep: backInStep += 1
        default: break
        }
    }

    private static func middle(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// One "label: number" per line; a number not known yet is left out.
    func text() -> String {
        var lines = ["follow along report: 1"]
        func number(_ label: String, _ value: Double?, places: Int = 1) {
            guard let value, value.isFinite else { return }
            lines.append("\(label): \(String(format: "%.\(places)f", value))")
        }
        func count(_ label: String, _ value: Int) {
            lines.append("\(label): \(value)")
        }
        number("minutes listened", minutesListened)
        number("seconds to lock on", secondsToLock)
        count("checks", checks)
        count("failed checks", failedChecks)
        number("match milliseconds, middle", Self.middle(matchMillis), places: 0)
        number("match milliseconds, most", matchMillis.max(), places: 0)
        count("skips", skips)
        count("lost", losses)
        count("pauses", pauses)
        count("back in step", backInStep)
        count("lines spoken", linesSpoken)
        count("short lines", shortLines)
        count("lines held", linesHeld)
        count("held lines read", heldLinesRead)
        number("voice seconds per letter", secondsPerLetter, places: 3)
        number("output delay milliseconds", outputDelayMillis, places: 0)
        number("timing nudge seconds", nudgeSeconds)
        number("battery percent at start", batteryStart.map { $0 * 100 }, places: 0)
        number("battery percent now", batteryNow.map { $0 * 100 }, places: 0)
        number("load milliseconds", loadMillis, places: 0)
        number("fingerprint minutes", printSeconds / 60)
        count("lines in track", cues)
        return lines.joined(separator: "\n")
    }
}
