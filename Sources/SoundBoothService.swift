import Foundation

// MARK: - Sound Booth (Part 120, Sep 3 2026)
//
// Her ask, Part 119.10: "I'm hoping the next session can be building a native
// playground on my platform where I can use AuK HQ." Then her interface, in
// her own words: "all the settings and import and all that, but you write the
// stuff in the textbox right? And there's some button that will either
// generate your text idea into a full scenema script based on its formatting,
// or it can write a new one based on a description... Maybe even an easy and
// advanced mode." Then, Part 120: "Might work seedaudio via api in the
// soundbooth as well. I'm most excited about native, it'll need to have
// working downloads and whatnot."
//
// The phone holds NO secrets. Every call here is an ordinary user JWT against
// the fork's /api/kade/sound-booth/*; the fork owns BRIDGE_SECRET and FAL_KEY
// and does the talking to the GPU and to fal. Contracts read straight off
// api/server/routes/kadeSoundBooth.js.

struct SoundBoothEstimate: Decodable, Equatable {
    let engine: String?
    let words: Int?
    let audioSeconds: Int?
    let renderSeconds: Int?
    let costUSD: Double?
    /// The estimate as a SENTENCE. Her standing rule is that the cost is said
    /// before the render runs, so the server writes the sentence and the app
    /// speaks it verbatim rather than assembling its own from the numbers.
    let spoken: String?
}

struct SoundBoothTake: Decodable, Identifiable, Equatable {
    let id: String
    let url: String
    let backupUrl: String?
    let masterUrl: String?
    /// Sep 27 2026, Sing it in my voice: the converted voice on its own (a
    /// signed storage link), the take a voice version was made from, and on
    /// a YuE2 take a word about its automatic voice version. The server sends
    /// them only on the takes of an account with a voice model.
    let vocalUrl: String?
    /// Sep 27 2026, vocal effects: on a voice version of a song sung with a
    /// vocal effect, the voice with that effect on its own (a signed storage
    /// link). `vocalUrl` stays the dry voice. Absent with no effect, with
    /// just a vocal (the take itself is then the voice with the effect), and
    /// from a server without vocal effects.
    let vocalFxUrl: String?
    let voiceOf: String?
    let voiceNote: String?
    let description: String?
    let seconds: Double?
    let costUSD: Double?
    let createdAt: String?
    /// Part 296: a YuE2 take's short note from the server (no chords were
    /// heard in the recording, or a section's words look short or long for
    /// its tune). The server speaks it when the batch finishes; the library
    /// shows it under the take. Empty or absent for most takes.
    let note: String?

    /// What VoiceOver reads for this take's row.
    func label(number: Int) -> String {
        var parts = ["Take \(number)"]
        if let s = seconds, s > 0 { parts.append("\(Int(s.rounded())) seconds") }
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: ", ")
    }
}

/// A loosely-typed JSON value, for the project's saved `options` — the
/// server stores whatever settings made the take, and their shapes differ
/// per engine and per key.
enum SoundBoothJSON: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), array([SoundBoothJSON]), null, other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([SoundBoothJSON].self) { self = .array(a); return }
        self = .other
    }

    /// The value as the settings dictionary stores it.
    var asFieldText: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "1" : ""
        default: return nil
        }
    }
}

struct SoundBoothProject: Decodable, Identifiable, Equatable {
    let id: String
    let options: [String: SoundBoothJSON]?
    let title: String
    let engine: String
    let mode: String
    let sourceText: String?
    let screenplay: String?
    let voiceSeed: Int?
    let script: String
    let readback: String?
    /// Sep 25 2026: the words a Lyria take sang. They used to be written into
    /// `readback`, which this screen reads out as "What you will hear"; the
    /// server now keeps them apart, so the library shows them apart too.
    let sungLyrics: String?
    let jobs: [String]?
    let state: String
    let lastError: String?
    let costUSD: Double?
    let updatedAt: String?
    let takes: [SoundBoothTake]?
    let hasRecoverableAudio: Bool?
    /// The server's own line for what made the row and why ("Sung in my voice
    /// — a song with music"). Read for Sing it in my voice rows only.
    let why: String?
    /// Oct 2 2026, AuK HQ speech rows: the script without its VOICE:, SEX:,
    /// SCENE: or SHOT: lines (only directions and words to perform), and the
    /// voice the saved script carries, for Describe a new voice. Both are
    /// empty for an edit, whose instruction lives in Edit instructions.
    /// Absent on older servers and on other engines.
    let performance: String?
    let voiceDescription: String?

    private enum CodingKeys: String, CodingKey {
        case id, options, title, engine, mode, sourceText, screenplay, voiceSeed, script, readback
        case sungLyrics, jobs, state, lastError, costUSD, updatedAt, takes, hasRecoverableAudio, why
        case performance
        case voiceDescription = "voice_description"
    }

    var engineLabel: String {
        switch engine {
        case "seed": return "Seed Audio"
        case "lyria": return "Lyria"
        case "yue2": return "YuE2"
        case "stable": return "Stable Audio"
        case "myvoice": return "Sing it in my voice"
        default: return "AuK HQ"
        }
    }
    /// What the row says made it. Sep 27 2026: a Sing it in my voice row says
    /// what went in (a song with music, or a vocal on its own), from the
    /// server; it used to fall through to "AuK HQ". Every other row keeps its
    /// engine's name.
    var rowLabel: String {
        let said = (why ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return engine == "myvoice" && !said.isEmpty ? said : engineLabel
    }
    var isWorking: Bool { state == "queued" || state == "running" }
    var stateWord: String {
        switch state {
        case "done": return "finished"
        case "queued": return "waiting its turn"
        case "running": return "rendering now"
        case "failed": return "did not finish"
        case "cancelled": return "stopped"
        default: return "a draft"
        }
    }
    /// The row, as one spoken sentence — the info block is one element and the
    /// buttons stay their own siblings (the Amber rule).
    var summary: String {
        var parts = [title, rowLabel, stateWord]
        if let t = takes, !t.isEmpty { parts.append("\(t.count) take\(t.count == 1 ? "" : "s")") }
        if let c = costUSD, c > 0 { parts.append("about \(max(1, Int((c * 100).rounded()))) cents") }
        if engine == "yue2" || engine == "myvoice" { parts.append("Execution cost only; startup and idle time are extra") }
        let r = (readback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty { parts.append(r) }
        return parts.joined(separator: ". ")
    }
}

struct SoundBoothScriptResult: Decodable {
    let engine: String
    let mode: String
    let script: String
    let screenplay: String?
    let readback: String?
    let estimate: SoundBoothEstimate?
    /// Non-nil when the text reads like a DESCRIPTION but was sent to be
    /// formatted — which would have performed the description out loud. A
    /// question, not a refusal; spoken before anything else.
    let mismatch: String?
    /// Non-nil when the script came back structurally wrong. Said out loud
    /// rather than shown, and Render stays available — she may want to fix it
    /// by hand in Advanced.
    let problem: String?
    /// Sep 25 2026: set when a song pasted whole (Lyrics Box, Tag Box,
    /// Negative Tag Box) was sorted into its boxes without the writer. Says
    /// where each part went and that the negative tags were left out.
    let note: String?
    /// True when the answer is a pasted song sorted into its boxes rather than
    /// a draft from the writer. `problem` then names what the paste is missing.
    let pasted: Bool?
    /// Set when a song pasted into the lyrics box was sorted while the writer
    /// drafted: `lyrics` belongs in the lyrics box, `script` is nil (the draft
    /// above is the direction).
    let pasteSorted: SoundBoothPasteSorted?
    /// Oct 2 2026, AuK HQ only: what goes in the script editor, directions in
    /// square brackets and the words to perform, never a VOICE:, SEX:, SCENE:
    /// or SHOT: line. Her report: "it writes things in the wrong places like
    /// voice descriptions." Absent on older servers; the booth then lifts the
    /// header lines out of `screenplay` itself (`SoundBoothText.splitHeaders`).
    let performance: String?
    /// Oct 2 2026, AuK HQ only: the voice the draft was written for, as its own
    /// field, for the Describe a new voice box. Absent on older servers; the
    /// booth then takes the voice from the screenplay's VOICE: line.
    let voiceDescription: String?

    private enum CodingKeys: String, CodingKey {
        case engine, mode, script, screenplay, readback, estimate, mismatch, problem, note, pasted, pasteSorted
        case performance
        case voiceDescription = "voice_description"
    }
}

/// Oct 2 2026: small text rules the booth shares, kept free of the main actor
/// so any model or view can use them.
enum SoundBoothText {
    /// Seed Audio takes at most this many seconds of each reference clip. A
    /// 32.6 second clip made every Seed render fail (Oct 1 2026).
    static let seedClipLimit: Double = 30

    /// The header words an AuK HQ screenplay may start with, and the setting
    /// each fills. The same list the server reads (kadeSoundBoothScreenplay.js
    /// HEADER_KEYS), so a line lifted out here would never have been spoken.
    private static let headerKeys: [String: String] = [
        "voice": "voice", "who": "voice", "speaker": "voice",
        "sex": "gender", "gender": "gender",
        "scene": "scene", "where": "scene", "place": "scene",
        "shot": "shot",
        "language": "language", "lang": "language",
    ]

    /// An AuK HQ screenplay without its header lines (VOICE:, SEX:, SCENE:,
    /// SHOT:, LANGUAGE:), and what those lines said, by setting ("voice",
    /// "gender", "scene", "shot", "language"). Read the way the server's
    /// parseScreenplay reads them: KEY: value lines at the very top, blank
    /// lines allowed between them, stopping at the first line that is not one.
    /// Text with no header lines comes back exactly as it was.
    static func splitHeaders(_ text: String) -> (body: String, headers: [String: String]) {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var headers: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            guard let colon = line.firstIndex(of: ":") else { break }
            let word = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard (3...10).contains(word.count),
                  word.allSatisfy({ $0.isASCII && $0.isLetter }),
                  let key = headerKeys[word.lowercased()],
                  !value.isEmpty else { break }
            headers[key] = value
            index += 1
        }
        guard !headers.isEmpty else { return (text, [:]) }
        let body = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, headers)
    }

    /// A server message, or nil when it says nothing. "[object Object]" is
    /// what an engine's list of problems becomes when it is printed as text
    /// (every failed Seed render on Oct 1 2026 said only that), so it is said
    /// in plain words instead, once, however many problems the list held
    /// ("[object Object],[object Object]"). The words start with a capital
    /// after a sentence ends ("Seed failed. The engine did not say why.").
    static func readable(_ message: String?) -> String? {
        let said = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return nil }
        guard said.contains("[object Object]") else { return said }
        let once = said.replacingOccurrences(
            of: #"\[object Object\](\s*,\s*\[object Object\])+"#,
            with: "[object Object]",
            options: .regularExpression
        )
        let plain = once
            .replacingOccurrences(
                of: #"([.!?]\s+)\[object Object\]"#,
                with: "$1The engine did not say why",
                options: .regularExpression
            )
            .replacingOccurrences(of: "[object Object]", with: "the engine did not say why")
        guard let first = plain.first else { return nil }
        let sentence = "\(first.uppercased())\(plain.dropFirst())"
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    /// A length as it is said: "33 seconds", or "32.6 seconds" when it is not whole.
    static func seconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 100_000 else { return "a long time" }
        let whole = value.rounded()
        if abs(value - whole) < 0.05 { return "\(Int(whole)) seconds" }
        return String(format: "%.1f seconds", value)
    }
}

/// Sep 25 2026: where the server put a song pasted whole from ChatGPT. The
/// phone sends a paste unsorted; these are the boxes the server sorted it
/// into, for the editor to match what was actually used.
struct SoundBoothPasteSorted: Decodable, Equatable {
    let script: String?
    let lyrics: String?
}

struct SoundBoothRenderResult: Decodable {
    let ok: Bool?
    let engine: String?
    let queued: Bool?
    let jobId: String?
    let projectId: String?
    let assetId: String?
    let url: String?
    let seconds: Int?
    let costUSD: Double?
    let estimate: SoundBoothEstimate?
    /// Sep 25 2026: what the server did with a pasted song, when it sorted one.
    let note: String?
    /// The server's own sentence about the finished render (Lyria: whether it
    /// wrote words for the song), with any paste note already in front.
    let spoken: String?
    /// Lyria: the words the take sang, when it sang any.
    let lyrics: String?
    /// The boxes a pasted song was sorted into before the engine saw it.
    let pasteSorted: SoundBoothPasteSorted?
}

struct SoundBoothStatus: Decodable {
    let jobId: String?
    let projectId: String?
    let state: String
    let error: String?
    let url: String?
    let durationS: Double?
    let costUSD: Double?
    let spoken: String?
    /// Sep 23 2026 (C3): how far along, when the server knows. A YuE2 or
    /// Stable Audio batch counts finished takes; an AuK HQ piece made in
    /// parts counts parts. Read only for the lock-screen card.
    let completed: Int?
    let total: Int?
    struct Parts: Decodable { let total: Int?; let done: Int?; let joined: Bool? }
    let multipart: Parts?
    var isFinished: Bool { state == "done" || state == "failed" || state == "cancelled" }
}

extension SoundBoothStatus {
    /// C3: the lock-screen card's words for a render still going. Stages only
    /// ("Waiting its turn", "Recording", "Mixing"); how far along rides in
    /// `cardProgress`, so the words stay the same from one poll to the next
    /// until the stage really changes.
    var cardStatus: String {
        if let parts = multipart, let count = parts.total, count > 1, (parts.done ?? 0) >= count {
            return "Mixing"
        }
        let started = multipart?.done ?? completed ?? 0
        return state == "queued" && started == 0 ? "Waiting its turn" : "Recording"
    }

    /// 0...1 when the server counts parts or takes; nil for a single piece.
    var cardProgress: Double? {
        if let parts = multipart, let count = parts.total, count > 1 {
            return min(1, Double(parts.done ?? 0) / Double(count))
        }
        if let count = total, count > 1 {
            return min(1, Double(completed ?? 0) / Double(count))
        }
        return nil
    }
}

/// THE GUIDE (Part 121). Her ask: "I don't think people will know the
/// difference between seedaudio and scenema, much less how to use the
/// settings and prompt it." The explanation lives on the SERVER, once
/// (kadeSoundBooth.js GUIDE), written from the two engines' own docs, and
/// this screen renders it — a wording fix is a deploy, not a build. Every
/// setting the screen shows comes from here with its own hint, range and
/// default, so the phone can never show a knob the engine does not have.
struct SoundBoothGuide: Decodable {
    struct Starter: Decodable, Identifiable { let id: String; let title: String; let engine: String; let script: String }
    let starters: [Starter]?
    struct Rule: Decodable, Hashable { let pick: String; let when: String }
    struct Chooser: Decodable { let question: String; let answer: String; let rules: [Rule] }
    /// What the box is holding, and therefore which button exists. Part 121.1:
    /// one text box meant two different things depending on which button was
    /// pressed, and the box could not say which — so the choice moves above it.
    struct InputMode: Decodable, Identifiable, Hashable {
        let key: String
        let label: String
        let boxLabel: String
        let boxHint: String
        let button: String
        let buttonHint: String
        var id: String { key }
    }
    struct InputChoice: Decodable { let question: String; let modes: [InputMode] }
    struct Setting: Decodable, Identifiable, Hashable {
        let key: String
        let label: String
        let hint: String
        /// text · choice · toggle · number · clip
        let kind: String
        let options: [String]?
        let step: Double?
        let min: Double?
        /// For a number: the upper bound. For a clip row: how many clips.
        let max: Double?
        let defaultString: String?
        let defaultNumber: Double?
        let defaultBool: Bool?
        /// Part 293: the media link on the YuE2 cover field (YouTube and other
        /// media sites, or a direct audio or video file link). The server sends
        /// `link` only when this account can use it: it has the Family feature
        /// pack. Everyone else gets `lockedLink` (no path, no hint, `locked`
        /// says why), which the booth shows greyed out, never hidden. Neither
        /// is sent while the server's link switch is off.
        struct Link: Decodable, Hashable {
            let label: String
            let hint: String?
            let button: String
            let path: String?
            /// "media" since the Family feature pack; absent on older servers.
            let site: String?
            /// False only on a locked link.
            let available: Bool?
            /// Why a locked link cannot be used: "Part of the Family feature pack".
            let locked: String?
            let maxSeconds: Double?
        }
        let link: Link?
        let lockedLink: Link?
        /// Part 296, the booth's shared contract: true puts this setting in
        /// the one collapsed "More settings" group of its engine, after the
        /// settings most people use. Absent on older servers.
        let advanced: Bool?
        /// Part 295/296: why this setting cannot be used on this account
        /// (the Style choice outside the Family feature pack says "Part of
        /// the Family feature pack"). A locked setting is shown greyed out
        /// with this reason, never hidden, and its value is never sent.
        let locked: String?
        var id: String { key }
        var clipMax: Int { Int(max ?? 1) }
        /// The reason, when the setting is locked. An empty string counts as
        /// unlocked, as it does on the web page.
        var lockReason: String? {
            let reason = (locked ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? nil : reason
        }

        private enum CodingKeys: String, CodingKey { case key, label, hint, kind, options, min, max, step, link, lockedLink, advanced, locked, `default` }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = try c.decode(String.self, forKey: .label)
            hint = try c.decode(String.self, forKey: .hint)
            kind = try c.decode(String.self, forKey: .kind)
            options = try c.decodeIfPresent([String].self, forKey: .options)
            step = try? c.decodeIfPresent(Double.self, forKey: .step)
            min = try? c.decodeIfPresent(Double.self, forKey: .min)
            max = try? c.decodeIfPresent(Double.self, forKey: .max)
            link = try? c.decodeIfPresent(Link.self, forKey: .link)
            lockedLink = try? c.decodeIfPresent(Link.self, forKey: .lockedLink)
            // Part 296: read leniently, so an odd value never breaks the guide.
            advanced = try? c.decodeIfPresent(Bool.self, forKey: .advanced)
            locked = try? c.decodeIfPresent(String.self, forKey: .locked)
            // `default` is one of three shapes depending on the kind.
            defaultString = try? c.decodeIfPresent(String.self, forKey: .default)
            defaultNumber = try? c.decodeIfPresent(Double.self, forKey: .default)
            defaultBool = try? c.decodeIfPresent(Bool.self, forKey: .default)
        }
    }
    struct Recipe: Decodable {
        let label: String
        let task: String
        let text: String
    }
    /// Sep 27 2026, Sing it in my voice: the words an upload engine's screen
    /// says, from its guide entry (myVoice.ts `ui`), so a wording fix is a
    /// deploy, not a build. Every field is optional; the booth has its own
    /// words for any that are missing.
    struct UploadWords: Decodable, Hashable {
        /// The one button: "Sing it in my voice".
        let render: String?
        /// Said when the engine is chosen.
        let select: String?
        /// Said when a library take has just been attached to sing.
        let fromTake: String?
        /// Said when the button is pressed with nothing imported.
        let needClip: String?
        /// The library button on a take it can sing: "Sing this take in my voice".
        let useTake: String?
        /// The library button for the converted voice on its own.
        let vocal: String?
        /// The library button for the voice with its vocal effect.
        let vocalFx: String?
        /// In front of the imported recording's name: "Singing: ".
        let clip: String?
    }
    struct Engine: Decodable {
        let name: String
        let tagline: String
        let `where`: String
        let cost: String
        let bestFor: [String]
        let notFor: [String]
        let howToWrite: [String]
        let settings: [Setting]
        let recipes: [Recipe]?
        /// Sep 27 2026: "upload" for an engine with no script box, where the
        /// imported recording is the input (Sing it in my voice). Nil for
        /// every other engine. Only an account the server gives such an
        /// engine to ever sees one.
        let flow: String?
        let ui: UploadWords?
        /// The engines whose finished takes this one can sing again.
        let takesFrom: [String]?
        // Which settings sit in the one collapsed "More settings" group is
        // each Setting's own `advanced` (Part 296), shared with every engine.

        /// The card, as one spoken paragraph.
        var spoken: String {
            "\(name). \(tagline) \(`where`) \(cost) Best for: \(bestFor.joined(separator: "; ")). Not for: \(notFor.joined(separator: "; "))."
        }

        private enum CodingKeys: String, CodingKey {
            case name, tagline, `where`, cost, bestFor, notFor, howToWrite, settings, recipes, flow, ui, takesFrom
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            tagline = try c.decode(String.self, forKey: .tagline)
            self.`where` = try c.decode(String.self, forKey: .`where`)
            cost = try c.decode(String.self, forKey: .cost)
            bestFor = try c.decode([String].self, forKey: .bestFor)
            notFor = try c.decode([String].self, forKey: .notFor)
            howToWrite = try c.decode([String].self, forKey: .howToWrite)
            settings = try c.decode([Setting].self, forKey: .settings)
            recipes = try c.decodeIfPresent([Recipe].self, forKey: .recipes)
            // The Sep 27 fields are read leniently: an odd value never breaks the guide.
            flow = try? c.decodeIfPresent(String.self, forKey: .flow)
            ui = try? c.decodeIfPresent(UploadWords.self, forKey: .ui)
            takesFrom = try? c.decodeIfPresent([String].self, forKey: .takesFrom)
        }
    }
    let chooser: Chooser
    let input: InputChoice?
    let engines: [String: Engine]
}

struct SoundBoothSuggestion: Decodable {
    let engine: String
    let sure: Bool
    let reason: String
}

struct SoundBoothHealth: Decodable {
    /* Lyria is priced per SONG, not per minute, so its card carries a
     * different number and the phone has to read whichever one is there. */
    struct Engine: Decodable { let configured: Bool; let queued: Bool?; let usdPerMin: Double?; let usdPerSong: Double?; let model: String? }
    struct Mood: Decodable, Identifiable, Hashable { let key: String; let label: String; var id: String { key } }
    struct Limits: Decodable { let scenemaChars: Int?; let seedChars: Int?; let lyriaChars: Int?; let scriptsPerDay: Int? }
    let engines: [String: Engine]
    let scriptDesk: Bool
    let moods: [Mood]
    let limits: Limits?
    let guide: SoundBoothGuide?
    /// Part 293: this person's Family feature pack map. Absent on older servers.
    let features: KadeFamilyFeatures?
}

/// THE FAMILY FEATURE PACK (Part 293, Sep 25 2026). One map per person, the
/// same one GET /api/kade/features answers, also carried as `features` on the
/// Sound Booth's /health, the describer's /config and the Clubhouse's /config.
/// True means usable now. False means the control is shown greyed out with
/// `note` as its reason, never hidden. Every field is read leniently, and a
/// map that cannot be read at all counts as absent (an older server, which
/// gates nothing), so it can never break the answer it rides in.
struct KadeFamilyFeatures: Decodable, Equatable {
    /// The Sound Booth's media link for a cover.
    let mediaLinks: Bool?
    /// The video describer's link import.
    let describerLinks: Bool?
    /// The Clubhouse jukebox's song links.
    let jukeboxLinks: Bool?
    /// Kade's shared Library shelves.
    let familyLibrary: Bool?

    /// The reason beside every greyed-out pack control (family/pack.ts FAMILY_PACK_NOTE).
    static let note = "Part of the Family feature pack"

    private enum CodingKeys: String, CodingKey { case mediaLinks, describerLinks, jukeboxLinks, familyLibrary }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool? {
            guard let c else { return nil }
            return try? c.decodeIfPresent(Bool.self, forKey: key)
        }
        mediaLinks = flag(.mediaLinks)
        describerLinks = flag(.describerLinks)
        jukeboxLinks = flag(.jukeboxLinks)
        familyLibrary = flag(.familyLibrary)
    }
}

@MainActor
final class SoundBoothService: ObservableObject {
    struct BoothError: LocalizedError {
        let message: String
        /// Oct 2 2026: the project a failed render was saved under, when the
        /// server named it, so trying again adds to that row instead of
        /// starting another failed one beside it.
        var projectId: String? = nil
        var errorDescription: String? { message }
    }

    private let client: KadeAPIClient
    init(apiClient: KadeAPIClient) { client = apiClient }

    private func decodeError(_ data: Data, fallback: String) -> BoothError {
        struct E: Decodable { let error: String?; let projectId: String? }
        let decoded = try? JSONDecoder().decode(E.self, from: data)
        let msg = SoundBoothText.readable(decoded?.error)
        let project = (decoded?.projectId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return BoothError(message: msg ?? fallback, projectId: project.isEmpty ? nil : project)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], timeout: TimeInterval, fallback: String) async throws -> T {
        var req = client.request(path: path, method: "POST", authorized: true, timeout: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw decodeError(data, fallback: fallback) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, fallback: String) async throws -> T {
        let req = client.request(path: path, method: "GET", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw decodeError(data, fallback: fallback) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func health() async throws -> SoundBoothHealth {
        try await get("api/kade/sound-booth/health", fallback: "Couldn't open the Sound Booth.")
    }

    /// Free, instant, explainable: the server reads her text and says which
    /// engine, with a reason she can hear. Not a model call.
    func suggest(text: String) async throws -> SoundBoothSuggestion {
        try await post("api/kade/sound-booth/suggest", body: ["text": text], timeout: 30, fallback: "Couldn't suggest right now.")
    }

    /// Surprise me, for songs. The server picks a way of looking, the lyric
    /// writer brainstorms and throws ideas away, and one pitch comes back:
    /// about ten seconds and a fraction of a cent. Any failure throws and
    /// the view falls back to its own free list.
    /// Part 293: `band` is the YuE2 Style she chose (Kids, Soul…). A Kids style
    /// makes the server pitch only clean ideas, whoever is asking.
    func songIdea(band: String? = nil) async throws -> String {
        struct Idea: Decodable { let idea: String }
        var body: [String: Any] = [:]
        if let band, !band.isEmpty { body["band"] = band }
        let made: Idea = try await post("api/kade/sound-booth/idea", body: body, timeout: 90, fallback: "The writer could not be reached.")
        return made.idea
    }

    /// mode "format" keeps her words verbatim and only adds structure;
    /// "write" drafts a whole piece from a description. Oct 2 2026: `gender`
    /// is nil when nothing chose one (AuK HQ has no sex setting, and its voice
    /// description says it), so no default sex is sent to the writer.
    func makeScript(
        engine: String,
        mode: String,
        text: String,
        voiceDescription: String?,
        gender: String?,
        mood: String?,
        scene: String?,
        shot: String?,
        clipURLs: [String] = [],
        lyrics: String? = nil,
        band: String? = nil
    ) async throws -> SoundBoothScriptResult {
        var body: [String: Any] = ["engine": engine, "mode": mode, "text": text]
        if let gender, !gender.isEmpty, engine != "lyria", engine != "yue2" { body["gender"] = gender }
        if let lyrics, !lyrics.isEmpty { body["lyrics"] = lyrics }
        // Part 293: the YuE2 Style, so the desk writes a Kids song clean.
        if engine == "yue2", let band, !band.isEmpty { body["band"] = band }
        if let v = voiceDescription, !v.isEmpty { body["voice_description"] = v }
        if let m = mood, !m.isEmpty { body["mood"] = m }
        if let s = scene, !s.isEmpty { body["scene"] = s }
        if let s = shot, !s.isEmpty { body["shot"] = s }
        if !clipURLs.isEmpty {
            /* Lyria clones nothing and has no reference clip, so a clip left
             * over from another engine must never ride along with a song. */
            if engine == "lyria" { /* no clips */ }
            else if engine == "seed" { body["audio_urls"] = clipURLs } else { body["reference_voice_url"] = clipURLs[0] }
        }
        // The script desk calls a model; 90 s server-side is normal, and the
        // 60-second URLSession default is exactly the trap build 169 fell in.
        // Part 212: the lyric desk reasons before it writes. Kimi K3 at medium
        // effort measured 73-111 s and at high up to 178 s, so 120 s forced the
        // server down to low effort. 300 s matches a deep-thinking draft; the
        // server gives up first and says so in plain words.
        // Part 218: a sung draft goes to the deep lane. The server takes it as a
        // job and answers at once, the writer thinks for minutes, and this asks
        // after it every eight seconds. No request is ever held open.
        if (engine == "lyria" || engine == "yue2") && mode == "write" {
            return try await deepScript(body: body)
        }
        return try await post("api/kade/sound-booth/script", body: body, timeout: 300, fallback: "The script desk had trouble. Try again.")
    }

    private struct ScriptJobStart: Decodable { let job: String? }
    private struct ScriptJobState: Decodable {
        let state: String?
        let error: String?
        let result: SoundBoothScriptResult?
    }

    private func deepScript(body: [String: Any]) async throws -> SoundBoothScriptResult {
        let fallback = "The script desk had trouble. Try again."
        var deep = body
        deep["background"] = true
        var req = client.request(path: "api/kade/sound-booth/script", method: "POST", authorized: true, timeout: 60)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: deep)
        let (data, http) = try await client.send(req)
        if http.statusCode == 200 {
            return try JSONDecoder().decode(SoundBoothScriptResult.self, from: data)
        }
        // 202 is a new job; 409 is her own draft already being written, so
        // wait on that one instead of failing.
        let started = try? JSONDecoder().decode(ScriptJobStart.self, from: data)
        guard http.statusCode == 202 || http.statusCode == 409, let id = started?.job, !id.isEmpty else {
            throw decodeError(data, fallback: fallback)
        }
        var misses = 0
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 8_000_000_000)
            let poll = client.request(path: "api/kade/sound-booth/script/job/\(id)", method: "GET", authorized: true)
            guard let answer = try? await client.send(poll) else {
                misses += 1
                if misses > 6 { throw BoothError(message: "Connection lost while waiting for the draft. Your idea is kept. Try again.") }
                continue
            }
            misses = 0
            guard answer.1.statusCode == 200 else { throw decodeError(answer.0, fallback: fallback) }
            let job = try JSONDecoder().decode(ScriptJobState.self, from: answer.0)
            if job.state == "done", let result = job.result { return result }
            if job.state == "failed" { throw BoothError(message: SoundBoothText.readable(job.error) ?? fallback) }
        }
        throw BoothError(message: "The writer is taking far too long. Your idea is kept. Try again.")
    }

    struct LyricsDraft: Decodable { let transcript: String; let warning: String }
    /// Part 293: 240 seconds (was 210), so a long cover recording's words are
    /// not cut off by the phone while the server is still listening.
    func transcribeLyrics(url: String) async throws -> LyricsDraft {
        try await post("api/kade/sound-booth/reference/lyrics", body: ["url": url], timeout: 240, fallback: "Could not hear the words. Your lyrics are kept.")
    }

    func render(body: [String: Any]) async throws -> SoundBoothRenderResult {
        // Seed Audio is SYNCHRONOUS and can legitimately take three minutes
        // for a two-minute scene; AuK HQ returns as soon as it is queued.
        try await post("api/kade/sound-booth/render", body: body, timeout: 240, fallback: "That render could not start.")
    }

    /// Sep 27 2026: what a render would cost, asked without starting it
    /// (`estimateOnly`), for Sing it in my voice, whose price follows the
    /// recording's length. The same estimate the render answers with, the
    /// web page's quoteUpload. Nothing is made or spent.
    func quote(body: [String: Any]) async throws -> SoundBoothRenderResult {
        var asked = body
        asked["estimateOnly"] = true
        return try await post("api/kade/sound-booth/render", body: asked, timeout: 60, fallback: "Couldn't price that recording.")
    }

    func status(jobId: String) async throws -> SoundBoothStatus {
        try await get("api/kade/sound-booth/status/\(jobId)", fallback: "Couldn't read that render.")
    }

    struct CancelResult: Decodable { let ok: Bool?; let state: String?; let spoken: String? }
    func cancel(jobId: String) async throws -> CancelResult {
        try await post("api/kade/sound-booth/cancel/\(jobId)", body: [:], timeout: 30, fallback: "Couldn't stop that render.")
    }

    // MARK: - Lock-screen cards for renders (Sep 23 2026 redesign, C3)
    //
    // A queued render (AuK HQ, YuE2, Stable Audio) outlives the screen: she can
    // leave while it records, the server keeps going, and the booth picks the
    // job back up the next time it opens. This service lives only as long as
    // the screen, so the card ids live on the TYPE, filed under the render's
    // project, where the next visit finds them instead of starting a second
    // card beside the first. Lyria and Seed Audio record inside one request,
    // so their card starts and ends within that request and is never filed.

    private struct RenderCard { let id: String; var status: String; var progress: Double? }
    private static var renderCards: [String: RenderCard] = [:]

    /// A new card. Nil when none could be shown, which is not an error.
    func startRenderCard(kind: String, title: String, status: String) -> String? {
        KadeJobActivity.start(kind: kind, title: title, status: status)
    }

    /// Files a card that is showing `status` under the render's project (or
    /// its job, when the server named no project).
    func fileRenderCard(_ id: String?, under key: String, showing status: String) {
        guard let id else { return }
        if let earlier = Self.renderCards[key], earlier.id != id {
            KadeJobActivity.finish(earlier.id, status: "Ended", failed: true)
        }
        Self.renderCards[key] = RenderCard(id: id, status: status, progress: nil)
    }

    /// Moves a filed card on, but only when the stage changes or known
    /// progress has moved a tenth or more since the card last changed.
    func updateRenderCard(under key: String, status: String, progress: Double?) {
        guard var card = Self.renderCards[key] else { return }
        let last = card.progress ?? 0
        let moved = progress.map { abs($0 - last) >= 0.1 } ?? false
        guard status != card.status || moved else { return }
        card.status = status
        card.progress = progress
        Self.renderCards[key] = card
        KadeJobActivity.update(card.id, status: status, progress: progress)
    }

    func finishRenderCard(under key: String, status: String, failed: Bool = false) {
        guard let card = Self.renderCards.removeValue(forKey: key) else { return }
        KadeJobActivity.finish(card.id, status: status, failed: failed)
    }

    /// The card of a request no project holds yet (Lyria, Seed Audio).
    func finishRenderCard(id: String?, status: String, failed: Bool = false) {
        KadeJobActivity.finish(id, status: status, failed: failed)
    }

    /// A render that ended while the booth was closed left its card up. The
    /// project list says how it ended, so the card can say so too. A project
    /// still working keeps its card; the resumed poll moves it on.
    func settleRenderCards(with projects: [SoundBoothProject]) {
        for (key, card) in Self.renderCards {
            guard let project = projects.first(where: { $0.id == key || ($0.jobs ?? []).contains(key) }),
                  !project.isWorking else { continue }
            Self.renderCards[key] = nil
            switch project.state {
            case "done": KadeJobActivity.finish(card.id, status: "Ready to play")
            case "cancelled": KadeJobActivity.finish(card.id, status: "Stopped", failed: true)
            default: KadeJobActivity.finish(card.id, status: Self.cardReason(project.lastError), failed: true)
            }
        }
    }

    /// A short plain reason for a card that ends without audio: the server's
    /// own first sentence when it is short, otherwise just "Didn't finish".
    static func cardReason(_ message: String?) -> String {
        let first = (SoundBoothText.readable(message) ?? "").split(separator: ".").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !first.isEmpty, first.count <= 60 else { return "Didn't finish" }
        return "Didn't finish. \(first.prefix(1).uppercased())\(first.dropFirst())."
    }

    func projects() async throws -> [SoundBoothProject] {
        struct Wrap: Decodable { let projects: [SoundBoothProject] }
        let w: Wrap = try await get("api/kade/sound-booth/projects", fallback: "Couldn't load your Sound Booth.")
        return w.projects
    }

    func rename(projectId: String, title: String) async throws {
        var req = client.request(path: "api/kade/sound-booth/projects/\(projectId)", method: "PATCH", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw decodeError(data, fallback: "Couldn't save that title.") }
    }

    func delete(projectId: String) async throws {
        let req = client.request(path: "api/kade/sound-booth/projects/\(projectId)", method: "DELETE", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw decodeError(data, fallback: "Couldn't remove that.") }
    }

    /// IMPORT A CLIP TO CLONE, her ask. The bytes ride the same multipart
    /// helper the speech lane uses, and the fork puts them in the storage
    /// every gallery file already uses and hands back a signed URL. Kept in
    /// the service rather than the view so every call to the API client goes
    /// through one main-actor-isolated owner — the same reason this whole
    /// file exists.
    /// `seconds`: the recording's length when the server measured it (Sep 27
    /// 2026, so Sing it in my voice can show "3:12" beside the name).
    struct ImportedReference { let url: String; let name: String; let spoken: String; var seconds: Double? = nil }


    func importReference(data: Data, fileName: String, mimeType: String, engine: String) async throws -> ImportedReference {
        var req = client.multipartRequest(
            path: "api/kade/sound-booth/reference",
            authorized: true,
            // The server judges the format against the ENGINE — AuK HQ takes
            // WAV/MP3/M4A, Seed also takes OGG — so it has to know which.
            fields: [("engine", engine)],
            fileField: "clip",
            fileData: data,
            fileName: fileName,
            fileMimeType: mimeType
        )
        req.timeoutInterval = 180
        let (respData, http) = try await client.send(req)
        struct Resp: Decodable { let url: String?; let name: String?; let spoken: String?; let error: String?; let ext: String?; let seconds: Double? }
        let r = try? JSONDecoder().decode(Resp.self, from: respData)
        guard http.statusCode == 200, let remote = r?.url, !remote.isEmpty else {
            throw BoothError(message: r?.error ?? "That clip could not be imported.")
        }
        return ImportedReference(
            url: remote,
            name: r?.name ?? fileName,
            spoken: r?.spoken ?? "Clip imported. It will be used as the voice to clone.",
            seconds: r?.seconds
        )
    }

    /// A MEDIA LINK FOR A YUE2 COVER (Part 293), her ask: "The soundbooth
    /// needs a youtube paste link in the yue2 workflow so people can cover
    /// songs from youtube videos." Since the Family feature pack it takes
    /// YouTube, other big media sites and direct audio or video file links.
    /// The server checks the length before downloading, brings in only the
    /// sound, and answers exactly as a file import does plus the source's
    /// site, title and length. An account without the pack gets 403 with the
    /// server's own sentence, which is said as it is. The server gives up by
    /// itself in under two minutes, so 150 seconds never cuts off an answer.
    func importReferenceLink(link: String, engine: String) async throws -> ImportedReference {
        struct Source: Decodable { let site: String?; let title: String?; let seconds: Double? }
        struct Resp: Decodable { let url: String?; let name: String?; let spoken: String?; let seconds: Double?; let source: Source? }
        let r: Resp = try await post(
            "api/kade/sound-booth/reference/link",
            body: ["engine": engine, "url": link],
            timeout: 150,
            fallback: "The song could not be brought in from that link."
        )
        guard let remote = r.url, !remote.isEmpty else {
            throw BoothError(message: "The song could not be brought in from that link.")
        }
        let title = r.source?.title ?? r.name ?? "Song from a link"
        let seconds = r.seconds ?? r.source?.seconds
        return ImportedReference(
            url: remote,
            name: seconds.map { "\(title) (\(Self.clock($0)))" } ?? title,
            spoken: r.spoken ?? "Song imported from the link."
        )
    }

    /// "3:12" for a length in seconds.
    static func clock(_ seconds: Double) -> String {
        let total = Swift.max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// WORKING DOWNLOADS, her words. The bytes come through the SAME authorized
    /// gallery lane My Creations uses (`/api/kade/asset-download/:id`), land in
    /// a temp file named from the server's own Content-Disposition, and feed
    /// the share sheet — which on iOS is how audio actually gets saved to
    /// Files, sent in a message, or dropped into another app. A plain link
    /// would not do it: the asset URLs are signed and short-lived, and the
    /// share sheet needs a real file on disk to offer "Save to Files".
    func download(take: SoundBoothTake, title: String, master: Bool = false) async throws -> URL {
        let req = client.request(path: "api/kade/asset-download/\(take.id)", method: "GET", authorized: true, queryItems: master ? [URLQueryItem(name: "master", value: "1")] : nil, timeout: 120)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200, !data.isEmpty else {
            throw BoothError(message: "Couldn't fetch that recording. Try again.")
        }
        var name = safeFileName(title)
        var ext = "mp3"
        if let disp = http.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disp.range(of: "filename=\"") {
            let tail = disp[range.upperBound...]
            if let end = tail.firstIndex(of: "\""), end > tail.startIndex {
                let real = String(tail[..<end])
                let parts = real.split(separator: ".")
                if parts.count >= 2, let last = parts.last { ext = String(last) }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name.isEmpty ? "kade-ai-audio" : name)
            .appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Sep 27 2026, Sing it in my voice: the converted voice on its own, from
    /// the take's signed storage link (the web page's "Download my voice on
    /// its own"). The gallery download lane has no way to ask for it, and a
    /// signed link carries its own permission, so this request carries no
    /// sign-in: storage refuses a request that brings a second one. Lands in
    /// a temp file for the share sheet, like `download`.
    func downloadVocal(from link: String, title: String) async throws -> URL {
        guard let url = URL(string: link, relativeTo: client.baseURL)?.absoluteURL, url.scheme == "https" else {
            throw BoothError(message: "Couldn't fetch the voice on its own. Try again.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200, !data.isEmpty else {
            throw BoothError(message: "Couldn't fetch the voice on its own. Open the Sound Booth again and retry.")
        }
        let found = url.pathExtension.lowercased()
        let ext = ["mp3", "wav", "m4a", "flac", "ogg"].contains(found) ? found : "mp3"
        let name = safeFileName(title)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(name.isEmpty ? "kade-ai-voice" : name)
            .appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: file)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// A file name a person would recognise in Files, built from the project's
    /// own title rather than an id — "Bedtime fox story.mp3", not "6a3c….mp3".
    private func safeFileName(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(60))
    }
}

