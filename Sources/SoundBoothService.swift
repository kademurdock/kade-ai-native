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
    let description: String?
    let seconds: Double?
    let costUSD: Double?
    let createdAt: String?

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
    let jobs: [String]?
    let state: String
    let lastError: String?
    let costUSD: Double?
    let updatedAt: String?
    let takes: [SoundBoothTake]?
    let hasRecoverableAudio: Bool?

    var engineLabel: String {
        switch engine {
        case "seed": return "Seed Audio"
        case "lyria": return "Lyria"
        case "yue2": return "YuE2"
        case "stable": return "Stable Audio"
        default: return "AuK HQ"
        }
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
        var parts = [title, engineLabel, stateWord]
        if let t = takes, !t.isEmpty { parts.append("\(t.count) take\(t.count == 1 ? "" : "s")") }
        if let c = costUSD, c > 0 { parts.append("about \(max(1, Int((c * 100).rounded()))) cents") }
        if engine == "yue2" { parts.append("Execution cost only; startup and idle time are extra") }
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
        /// Part 293: on the YuE2 cover field only when this account may paste a
        /// YouTube link (the server leaves it off for App Review).
        struct Link: Decodable, Hashable { let label: String; let hint: String; let button: String; let path: String? }
        let link: Link?
        var id: String { key }
        var clipMax: Int { Int(max ?? 1) }

        private enum CodingKeys: String, CodingKey { case key, label, hint, kind, options, min, max, step, link, `default` }
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
        /// The card, as one spoken paragraph.
        var spoken: String {
            "\(name). \(tagline) \(`where`) \(cost) Best for: \(bestFor.joined(separator: "; ")). Not for: \(notFor.joined(separator: "; "))."
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
}

@MainActor
final class SoundBoothService: ObservableObject {
    struct BoothError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let client: KadeAPIClient
    init(apiClient: KadeAPIClient) { client = apiClient }

    private func decodeError(_ data: Data, fallback: String) -> BoothError {
        struct E: Decodable { let error: String? }
        let msg = (try? JSONDecoder().decode(E.self, from: data))?.error
        return BoothError(message: msg?.isEmpty == false ? msg! : fallback)
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
    /// "write" drafts a whole piece from a description.
    func makeScript(
        engine: String,
        mode: String,
        text: String,
        voiceDescription: String?,
        gender: String,
        mood: String?,
        scene: String?,
        shot: String?,
        clipURLs: [String] = [],
        lyrics: String? = nil,
        band: String? = nil
    ) async throws -> SoundBoothScriptResult {
        var body: [String: Any] = ["engine": engine, "mode": mode, "text": text, "gender": gender]
        if engine == "lyria" || engine == "yue2" { body.removeValue(forKey: "gender") }
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
            if job.state == "failed" { throw BoothError(message: job.error ?? fallback) }
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
        let first = (message ?? "").split(separator: ".").first
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
    struct ImportedReference { let url: String; let name: String; let spoken: String }


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
        struct Resp: Decodable { let url: String?; let name: String?; let spoken: String?; let error: String?; let ext: String? }
        let r = try? JSONDecoder().decode(Resp.self, from: respData)
        guard http.statusCode == 200, let remote = r?.url, !remote.isEmpty else {
            throw BoothError(message: r?.error ?? "That clip could not be imported.")
        }
        return ImportedReference(
            url: remote,
            name: r?.name ?? fileName,
            spoken: r?.spoken ?? "Clip imported. It will be used as the voice to clone."
        )
    }

    /// A YOUTUBE LINK FOR A YUE2 COVER (Part 293), her ask: "The soundbooth
    /// needs a youtube paste link in the yue2 workflow so people can cover
    /// songs from youtube videos." The server checks the video's length before
    /// downloading, brings in only its sound, and answers exactly as a file
    /// import does plus the video's title and length. It gives up by itself in
    /// under two minutes, so 150 seconds here never cuts off a real answer.
    func importReferenceLink(link: String, engine: String) async throws -> ImportedReference {
        struct Source: Decodable { let title: String?; let seconds: Double? }
        struct Resp: Decodable { let url: String?; let name: String?; let spoken: String?; let seconds: Double?; let source: Source? }
        let r: Resp = try await post(
            "api/kade/sound-booth/reference/link",
            body: ["engine": engine, "url": link],
            timeout: 150,
            fallback: "The song could not be brought in from YouTube."
        )
        guard let remote = r.url, !remote.isEmpty else {
            throw BoothError(message: "The song could not be brought in from YouTube.")
        }
        let title = r.source?.title ?? r.name ?? "YouTube song"
        let seconds = r.seconds ?? r.source?.seconds
        return ImportedReference(
            url: remote,
            name: seconds.map { "\(title) (\(Self.clock($0)))" } ?? title,
            spoken: r.spoken ?? "Song imported from YouTube."
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

