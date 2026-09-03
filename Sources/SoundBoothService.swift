import Foundation

// MARK: - Sound Booth (Part 120, Sep 3 2026)
//
// Her ask, Part 119.10: "I'm hoping the next session can be building a native
// playground on my platform where I can use Scenema." Then her interface, in
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
    let description: String?
    let seconds: Int?
    let costUSD: Double?
    let createdAt: String?

    /// What VoiceOver reads for this take's row.
    func label(number: Int) -> String {
        var parts = ["Take \(number)"]
        if let s = seconds, s > 0 { parts.append("\(s) seconds") }
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: ", ")
    }
}

/// A loosely-typed JSON value, for the project's saved `options` — the
/// server stores whatever settings made the take, and their shapes differ
/// per engine and per key.
enum SoundBoothJSON: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), null, other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
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
    let script: String
    let readback: String?
    let jobs: [String]?
    let state: String
    let lastError: String?
    let costUSD: Double?
    let updatedAt: String?
    let takes: [SoundBoothTake]?

    var engineLabel: String { engine == "seed" ? "Seed Audio" : "Scenema" }
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
        let r = (readback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty { parts.append(r) }
        return parts.joined(separator: ". ")
    }
}

struct SoundBoothScriptResult: Decodable {
    let engine: String
    let mode: String
    let script: String
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
    var isFinished: Bool { state == "done" || state == "failed" || state == "cancelled" }
}

/// THE GUIDE (Part 121). Her ask: "I don't think people will know the
/// difference between seedaudio and scenema, much less how to use the
/// settings and prompt it." The explanation lives on the SERVER, once
/// (kadeSoundBooth.js GUIDE), written from the two engines' own docs, and
/// this screen renders it — a wording fix is a deploy, not a build. Every
/// setting the screen shows comes from here with its own hint, range and
/// default, so the phone can never show a knob the engine does not have.
struct SoundBoothGuide: Decodable {
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
        let min: Double?
        /// For a number: the upper bound. For a clip row: how many clips.
        let max: Double?
        let defaultString: String?
        let defaultNumber: Double?
        let defaultBool: Bool?
        var id: String { key }
        var clipMax: Int { Int(max ?? 1) }

        private enum CodingKeys: String, CodingKey { case key, label, hint, kind, options, min, max, `default` }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = try c.decode(String.self, forKey: .label)
            hint = try c.decode(String.self, forKey: .hint)
            kind = try c.decode(String.self, forKey: .kind)
            options = try c.decodeIfPresent([String].self, forKey: .options)
            min = try? c.decodeIfPresent(Double.self, forKey: .min)
            max = try? c.decodeIfPresent(Double.self, forKey: .max)
            // `default` is one of three shapes depending on the kind.
            defaultString = try? c.decodeIfPresent(String.self, forKey: .default)
            defaultNumber = try? c.decodeIfPresent(Double.self, forKey: .default)
            defaultBool = try? c.decodeIfPresent(Bool.self, forKey: .default)
        }
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
    struct Engine: Decodable { let configured: Bool; let queued: Bool?; let usdPerMin: Double? }
    struct Mood: Decodable, Identifiable, Hashable { let key: String; let label: String; var id: String { key } }
    struct Limits: Decodable { let scenemaChars: Int?; let seedChars: Int?; let scriptsPerDay: Int? }
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
        clipURLs: [String] = []
    ) async throws -> SoundBoothScriptResult {
        var body: [String: Any] = ["engine": engine, "mode": mode, "text": text, "gender": gender]
        if let v = voiceDescription, !v.isEmpty { body["voice_description"] = v }
        if let m = mood, !m.isEmpty { body["mood"] = m }
        if let s = scene, !s.isEmpty { body["scene"] = s }
        if let s = shot, !s.isEmpty { body["shot"] = s }
        if !clipURLs.isEmpty {
            if engine == "seed" { body["audio_urls"] = clipURLs } else { body["reference_voice_url"] = clipURLs[0] }
        }
        // The script desk calls a model; 90 s server-side is normal, and the
        // 60-second URLSession default is exactly the trap build 169 fell in.
        return try await post("api/kade/sound-booth/script", body: body, timeout: 120, fallback: "The script desk had trouble. Try again.")
    }

    func render(body: [String: Any]) async throws -> SoundBoothRenderResult {
        // Seed Audio is SYNCHRONOUS and can legitimately take three minutes
        // for a two-minute scene; Scenema returns as soon as it is queued.
        try await post("api/kade/sound-booth/render", body: body, timeout: 240, fallback: "That render could not start.")
    }

    func status(jobId: String) async throws -> SoundBoothStatus {
        try await get("api/kade/sound-booth/status/\(jobId)", fallback: "Couldn't read that render.")
    }

    func cancel(jobId: String) async throws {
        struct Ok: Decodable { let ok: Bool? }
        let _: Ok = try await post("api/kade/sound-booth/cancel/\(jobId)", body: [:], timeout: 30, fallback: "Couldn't stop that render.")
    }

    func projects() async throws -> [SoundBoothProject] {
        struct Wrap: Decodable { let projects: [SoundBoothProject] }
        let w: Wrap = try await get("api/kade/sound-booth/projects", fallback: "Couldn't load your Sound Booth.")
        return w.projects
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

    func importReference(data: Data, fileName: String, mimeType: String) async throws -> ImportedReference {
        var req = client.multipartRequest(
            path: "api/kade/sound-booth/reference",
            authorized: true,
            fields: [],
            fileField: "clip",
            fileData: data,
            fileName: fileName,
            fileMimeType: mimeType
        )
        req.timeoutInterval = 180
        let (respData, http) = try await client.send(req)
        struct Resp: Decodable { let url: String?; let name: String?; let spoken: String?; let error: String? }
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

    /// WORKING DOWNLOADS, her words. The bytes come through the SAME authorized
    /// gallery lane My Creations uses (`/api/kade/asset-download/:id`), land in
    /// a temp file named from the server's own Content-Disposition, and feed
    /// the share sheet — which on iOS is how audio actually gets saved to
    /// Files, sent in a message, or dropped into another app. A plain link
    /// would not do it: the asset URLs are signed and short-lived, and the
    /// share sheet needs a real file on disk to offer "Save to Files".
    func download(take: SoundBoothTake, title: String) async throws -> URL {
        let req = client.request(path: "api/kade/asset-download/\(take.id)", method: "GET", authorized: true, timeout: 120)
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
