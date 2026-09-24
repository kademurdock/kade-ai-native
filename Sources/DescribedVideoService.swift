import Foundation
import Combine

// MARK: - Make a described video (Sep 24 2026)
//
// The phone's door onto the website's describer (kademurdock.com/described-video):
// keep the actors, music and sound, and a narrator describes what happens on
// screen in the pauses. Every call is an ordinary user JWT against the fork's
// /api/kade/described-video/*; the fork owns the model, voice and storage keys.
//
// Owner-only trial today: the server answers 403 for everyone but admins. The
// app shows the feature (Create tile, search entry, Library button, Help) only
// after `GET config` has succeeded for this account (DescribedVideoAccess), so
// an account the server refuses never meets a screen that refuses it.

/// Where the screen opens: a Library video (book + track), the newest finished
/// video (a push or a lock-screen card), or plainly.
struct DescribedVideoStart: Hashable {
    var book: String? = nil
    var track: Int? = nil
    var openLatest = false
}

/// Whether this account may use the describer. Decided once per sign-in by
/// asking for the config; a 403 hides everything silently.
@MainActor
final class DescribedVideoAccess: ObservableObject {
    static let shared = DescribedVideoAccess()

    @Published private(set) var allowed = false
    private var decided = false
    private var checking = false

    /// Asks the server once. A network failure, a 401 or a 5xx leaves it
    /// undecided, so the next foreground asks again; 403 and 404 decide "no".
    func check(client: KadeAPIClient) async {
        guard !decided, !checking else { return }
        checking = true
        defer { checking = false }
        let req = client.request(path: "api/kade/described-video/config", authorized: true, timeout: 30)
        guard let (_, http) = try? await client.send(req) else { return }
        if http.statusCode == 200 {
            allowed = true
            decided = true
        } else if http.statusCode == 403 || http.statusCode == 404 {
            allowed = false
            decided = true
        }
    }

    /// The screen's own config load settles it too.
    func record(allowed: Bool) {
        self.allowed = allowed
        decided = true
    }

    /// Sign-out: the next account is asked afresh.
    func reset() {
        allowed = false
        decided = false
    }
}

// MARK: - Wire shapes (CONTRACT.md, HTTP API)

/// A section list the server may send as a count or as the section numbers.
struct DVSectionList: Decodable, Equatable {
    let sections: [Int]
    let count: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([Int].self) {
            sections = list
            count = list.count
        } else if let number = try? c.decode(Int.self) {
            sections = []
            count = max(0, number)
        } else if let number = try? c.decode(Double.self) {
            sections = []
            count = max(0, Int(number))
        } else {
            sections = []
            count = 0
        }
    }
}

/// "Saved to the Library": the server sends the Library item id, or true.
struct DVFlag: Decodable, Equatable {
    let isOn: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flag = try? c.decode(Bool.self) {
            isOn = flag
        } else if let text = try? c.decode(String.self) {
            isOn = !text.isEmpty
        } else {
            isOn = false
        }
    }
}

struct DVRange: Codable, Equatable {
    let start: Double
    let end: Double
}

struct DVSettings: Decodable, Equatable {
    let voice: String?
    let rate: Double?
    let maxRate: Double?
    let mode: String?
    let detail: String?
    let volume: String?
    let notes: String?
    let closeLook: Bool?
    let firstLook: Bool?
    let range: DVRange?
}

struct DVConfig: Decodable {
    struct Extras: Decodable { let closeLook: Double?; let firstLook: Double? }
    struct SetAside: Decodable { let factor: Double?; let extraUSD: Double? }
    struct VoiceCategory: Decodable { let name: String; let voices: [String] }

    let enabled: Bool?
    let maxBytes: Int?
    let chunkBytes: Int?
    let maxMinutes: Double?
    let maxSourceMinutes: Double?
    let limitUSD: Double?
    let dailyUSD: Double?
    let remainingUSD: Double?
    let perMinuteUSD: [String: Double]?
    let extrasPerMinuteUSD: Extras?
    let setAside: SetAside?
    let previewSeconds: Double?
    let library: Bool?
    let defaultLibraryPath: String?
    let defaultVoice: String?
    let voicesAvailable: Bool?
    let voices: [String]?
    let describe: [String: String]?
    let categories: [VoiceCategory]?
}

struct DVCopy: Decodable, Identifiable {
    let version: Int?
    let preview: Bool?
    let settings: DVSettings?
    let outputSeconds: Double?
    let count: Int?
    let skipped: Int?
    let failedSections: Int?
    let savedToLibrary: DVFlag?
    let finishedAt: String?
    let range: DVRange?

    var id: Int { version ?? 1 }
    var number: Int { version ?? 1 }
    var isSaved: Bool { savedToLibrary?.isOn ?? false }
}

struct DVJob: Decodable, Identifiable {
    let id: String
    let name: String?
    let bytes: Int?
    let state: String
    let source: String?
    let seconds: Double?
    let stage: String?
    let progress: Double?
    let etaSeconds: Double?
    let error: String?
    let settings: DVSettings?
    let costUSD: Double?
    let runCostUSD: Double?
    let setAsideUSD: Double?
    let estimatedUSD: Double?
    let outputSeconds: Double?
    let descriptions: Int?
    let skipped: Int?
    let failedSections: Int?
    let sections: Int?
    let done: Int?
    let resumable: Bool?
    let abandonable: Bool?
    let finishable: Bool?
    let retryableSections: DVSectionList?
    let copies: [DVCopy]?
    let version: Int?
    let kind: String?
    let savedToLibrary: DVFlag?
    let createdAt: String?
    let finishedAt: String?
    let expiresAt: String?
    let cancelRequested: Bool?
    let cancelStuck: Bool?
    let uploadedBytes: Int?
    let queuePosition: Double?
    let sourcePrivate: Bool?
    let sourceGrownUps: Bool?
    let sourceOwner: String?
    let range: DVRange?
    let preview: Bool?

    var title: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Untitled video" : n
    }

    /// Checking, importing or describing: the server is busy with it.
    var isWorking: Bool { ["checking", "importing", "reserving", "queued", "running"].contains(state) }
    /// Worth asking about again soon.
    var needsWatching: Bool { isWorking || state == "deleting" }

    /// The finished copies, oldest first. An older server that kept one copy
    /// on the job itself still gets a version to play.
    var finishedCopies: [DVCopy] {
        if let copies, !copies.isEmpty { return copies }
        guard state == "done" else { return [] }
        return [DVCopy(
            version: version ?? 1,
            preview: preview,
            settings: settings,
            outputSeconds: outputSeconds,
            count: descriptions,
            skipped: skipped,
            failedSections: failedSections,
            savedToLibrary: savedToLibrary,
            finishedAt: finishedAt,
            range: range
        )]
    }

    /// How many parts could not be described and can be tried again.
    var retryableCount: Int { retryableSections?.count ?? 0 }

    /// The list's words for its state (the website's own).
    var stateWord: String {
        switch state {
        case "uploading": return "upload not finished"
        case "checking": return "checking the video"
        case "importing": return "importing"
        case "ready": return "ready to describe"
        case "reserving", "queued":
            return stage == "Continuing after a server restart" ? "continuing after a server restart" : "waiting for its turn"
        case "running": return "describing, \(Int((progress ?? 0).rounded())) percent"
        case "done": return preview == true ? "preview finished" : "finished"
        case "failed": return "stopped"
        case "cancelled": return "cancelled"
        case "deleting": return "being deleted"
        default: return state
        }
    }
}

struct DVJobList: Decodable {
    let jobs: [DVJob]
    let remainingUSD: Double?

    private enum CodingKeys: String, CodingKey { case jobs, remainingUSD }
    /// One unreadable row must not hide every other video.
    private struct Maybe: Decodable {
        let job: DVJob?
        init(from decoder: Decoder) throws { job = try? DVJob(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try c.decodeIfPresent([Maybe].self, forKey: .jobs) ?? []
        jobs = rows.compactMap { $0.job }
        remainingUSD = try? c.decodeIfPresent(Double.self, forKey: .remainingUSD)
    }
}

struct DVEstimate: Decodable, Equatable {
    struct Breakdown: Decodable, Equatable {
        let vision: Double?
        let speech: Double?
        let dialogue: Double?
        let closeLook: Double?
        let firstLook: Double?
    }
    let estimateUSD: Double?
    let setAsideUSD: Double?
    let remainingUSD: Double?
    let dailyUSD: Double?
    let limitUSD: Double?
    let allowed: Bool?
    let reason: String?
    let seconds: Double?
    let breakdown: Breakdown?

    var isAllowed: Bool { allowed ?? true }
}

struct DVFiles: Decodable {
    let video: String?
    let videoDownload: String?
    let audio: String?
    let audioDownload: String?
    let transcript: String?
    let transcriptDownload: String?
    let captions: String?
    let captionsDownload: String?
    let descriptions: String?
    let descriptionsDownload: String?
    let script: String?
    let scriptDownload: String?
}

struct DVLibrarySaved: Decodable {
    let savedToLibrary: DVFlag?
    let path: String?
}

// MARK: - The service

@MainActor
final class DescribedVideoService: ObservableObject {
    struct DescribedVideoError: LocalizedError {
        let message: String
        var status: Int = 0
        var errorDescription: String? { message }
    }

    private static let base = "api/kade/described-video/"
    private let client: KadeAPIClient
    /// YouTube import ids by link, so pressing Import twice on one link
    /// recovers the first import instead of starting a second.
    private var importIds: [String: String] = [:]

    init(client: KadeAPIClient) {
        self.client = client
    }

    static func newRequestId() -> String {
        UUID().uuidString
    }

    // MARK: Plumbing

    private func decodeError(_ data: Data, status: Int, fallback: String) -> DescribedVideoError {
        struct E: Decodable { let error: String? }
        let text = (try? JSONDecoder().decode(E.self, from: data))?.error ?? ""
        return DescribedVideoError(message: text.isEmpty ? fallback : text, status: status)
    }

    private func makeRequest(_ path: String, method: String, body: [String: Any]?, query: [URLQueryItem]?, timeout: TimeInterval) throws -> URLRequest {
        var req = client.request(path: Self.base + path, method: method, authorized: true, queryItems: query, timeout: timeout)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// A long upload can outlive the access token. One quiet refresh through
    /// the httpOnly cookie (the same call AuthService makes at launch), then
    /// the request is built again with the new token.
    private func refreshToken() async -> Bool {
        struct Refreshed: Decodable { let token: String }
        let req = client.request(path: "api/auth/refresh", method: "POST")
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let fresh = try? JSONDecoder().decode(Refreshed.self, from: data),
              !fresh.token.isEmpty else { return false }
        Keychain.set(fresh.token, for: .accessToken)
        return true
    }

    private func exchange(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        query: [URLQueryItem]? = nil,
        timeout: TimeInterval = 60,
        fallback: String
    ) async throws -> Data {
        let first = try makeRequest(path, method: method, body: body, query: query, timeout: timeout)
        var (data, http) = try await client.send(first)
        if http.statusCode == 401, await refreshToken() {
            let again = try makeRequest(path, method: method, body: body, query: query, timeout: timeout)
            (data, http) = try await client.send(again)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw decodeError(data, status: http.statusCode, fallback: fallback)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DescribedVideoError(message: "The describer sent an answer this app could not read. Try again, or use the website.")
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil, fallback: String) async throws -> T {
        let data = try await exchange(path, query: query, fallback: fallback)
        return try decode(data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any] = [:], timeout: TimeInterval = 60, fallback: String) async throws -> T {
        let data = try await exchange(path, method: "POST", body: body, timeout: timeout, fallback: fallback)
        return try decode(data)
    }

    // MARK: Reading

    func config() async throws -> DVConfig {
        try await get("config", fallback: "Couldn't open the video describer.")
    }

    func libraryFolders() async throws -> [String] {
        struct Folders: Decodable { let folders: [String]? }
        let answer: Folders = try await get("library-folders", fallback: "Couldn't read your Library folders.")
        return answer.folders ?? []
    }

    func jobs() async throws -> DVJobList {
        try await get("jobs", fallback: "Couldn't load your videos.")
    }

    func job(_ id: String) async throws -> DVJob {
        try await get("jobs/\(id)", fallback: "Couldn't read that video.")
    }

    func files(jobId: String, version: Int) async throws -> DVFiles {
        try await get("jobs/\(jobId)/files", query: [URLQueryItem(name: "version", value: String(version))], fallback: "Couldn't get the playback links. Try again.")
    }

    /// transcript, captions, descriptions or script, as plain text.
    func text(jobId: String, kind: String, version: Int) async throws -> String {
        let data = try await exchange(
            "jobs/\(jobId)/text/\(kind)",
            query: [URLQueryItem(name: "version", value: String(version))],
            timeout: 60,
            fallback: "That text is not available for this copy."
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Choosing a video

    struct UploadStart: Decodable {
        let job: DVJob
        let chunkBytes: Int?
    }

    /// Upload one file in the server's chunk size, straight from disk (one
    /// chunk in memory at a time), then ask the server to check it.
    ///
    /// `recoveryKey` names the file (name, size, date). The request id saved
    /// under it makes the server hand back the SAME job when the same file is
    /// picked again, with `uploadedBytes` saying where to carry on.
    func upload(
        fileURL: URL,
        name: String,
        recoveryKey: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> DVJob {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else { throw DescribedVideoError(message: "That video could not be read. Try choosing it again.") }
        let defaults = UserDefaults.standard
        let key = "kade.describedVideo.upload." + recoveryKey
        var requestId = defaults.string(forKey: key) ?? Self.newRequestId()
        defaults.set(requestId, forKey: key)
        let cleanName = String(name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(240))

        var started: UploadStart = try await post(
            "uploads",
            body: ["requestId": requestId, "name": cleanName, "bytes": size],
            fallback: "The upload could not start. Try again."
        )
        if ["failed", "cancelled", "done"].contains(started.job.state) {
            requestId = Self.newRequestId()
            defaults.set(requestId, forKey: key)
            started = try await post(
                "uploads",
                body: ["requestId": requestId, "name": cleanName, "bytes": size],
                fallback: "The upload could not start. Try again."
            )
        }
        var job = started.job
        if job.state == "uploading" {
            let chunk = max(1024 * 1024, started.chunkBytes ?? 8 * 1024 * 1024)
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var offset = ((job.uploadedBytes ?? 0) / chunk) * chunk
            onProgress(Double(offset) / Double(size))
            while offset < size {
                try Task.checkCancellation()
                let length = min(chunk, size - offset)
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: length) ?? Data()
                guard data.count == length else {
                    throw DescribedVideoError(message: "The video changed while it was uploading. Choose it again to start over.")
                }
                job = try await sendChunk(jobId: job.id, part: offset / chunk + 1, data: data, done: offset, total: size, onProgress: onProgress)
                offset += length
            }
        }
        onProgress(1)
        job = try await post("jobs/\(job.id)/prepare", fallback: "The upload is incomplete. Choose the same video again to carry on.")
        defaults.removeObject(forKey: key)
        return job
    }

    /// One chunk, three tries with a short wait between them. Only a dropped
    /// connection, a timeout or a busy server is tried again; a refusal (the
    /// wrong file, an upload that is no longer open) stops at once.
    private func sendChunk(
        jobId: String,
        part: Int,
        data: Data,
        done: Int,
        total: Int,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> DVJob {
        let length = data.count
        var lastError = DescribedVideoError(message: "The upload connection keeps dropping. Choose the same video again to carry on from where it stopped.")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
            }
            var req = client.request(path: Self.base + "jobs/\(jobId)/chunks", method: "POST", authorized: true, timeout: 180)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(part), forHTTPHeaderField: "X-Part-Number")
            let delegate = UploadProgressDelegate { fraction in
                onProgress((Double(done) + fraction * Double(length)) / Double(total))
            }
            let session = client.makeAuxiliarySession(delegate: delegate, timeout: 180)
            await client.awaitPacingGate()
            let answer: (Data, URLResponse)
            do {
                answer = try await session.upload(for: req, from: data)
                session.finishTasksAndInvalidate()
            } catch {
                session.invalidateAndCancel()
                if Task.isCancelled { throw CancellationError() }
                continue
            }
            let body = answer.0
            guard let http = answer.1 as? HTTPURLResponse else { continue }
            if http.statusCode == 401 {
                if await refreshToken() { continue }
                throw DescribedVideoError(message: "Please sign in again, then choose the same video to carry on.", status: 401)
            }
            if (200..<300).contains(http.statusCode) {
                return try decode(body)
            }
            let refusal = decodeError(body, status: http.statusCode, fallback: "The upload did not complete. Choose the same video again to carry on.")
            if [408, 429, 500, 502, 503, 504].contains(http.statusCode) {
                lastError = refusal
                continue
            }
            throw refusal
        }
        throw lastError
    }

    func importYouTube(url: String) async throws -> DVJob {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var requestId = importIds[link] ?? Self.newRequestId()
        importIds[link] = requestId
        var job: DVJob = try await post("imports", body: ["url": link, "requestId": requestId], fallback: "That YouTube video could not be imported.")
        if ["failed", "cancelled", "done"].contains(job.state) {
            requestId = Self.newRequestId()
            importIds[link] = requestId
            job = try await post("imports", body: ["url": link, "requestId": requestId], fallback: "That YouTube video could not be imported.")
        }
        return job
    }

    func importLibrary(book: String, track: Int) async throws -> DVJob {
        try await post(
            "library-imports",
            body: ["book": book, "track": track, "requestId": Self.newRequestId()],
            fallback: "That Library video could not be checked."
        )
    }

    // MARK: Spending

    /// action: start, preview, resume, finish or redo. The price is the
    /// server's, never a formula on the phone.
    func estimate(jobId: String, action: String, settings: [String: Any]?, sections: [Int]? = nil) async throws -> DVEstimate {
        var body: [String: Any] = ["action": action]
        if let settings { body["settings"] = settings }
        if let sections, !sections.isEmpty { body["sections"] = sections }
        return try await post("jobs/\(jobId)/estimate", body: body, fallback: "Couldn't work out the price. Try again.")
    }

    func start(jobId: String, settings: [String: Any], preview: Bool) async throws -> DVJob {
        var body = settings
        if preview { body["preview"] = true }
        return try await post("jobs/\(jobId)/start", body: body, fallback: "That could not start. Nothing was spent.")
    }

    /// Continue a preview to the whole part.
    func finish(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/finish", fallback: "That could not start. Nothing was spent.")
    }

    /// Carry on from where it stopped. The voice fields may change.
    func resume(jobId: String, voiceFields: [String: Any]) async throws -> DVJob {
        try await post("jobs/\(jobId)/resume", body: voiceFields, fallback: "That could not carry on. Try again.")
    }

    /// Back to the last finished version after a stopped remake.
    func abandon(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/abandon", fallback: "Couldn't go back to the earlier version.")
    }

    /// Describe again only the parts that could not be described.
    func redo(jobId: String, expectedVersion: Int) async throws -> DVJob {
        try await post("jobs/\(jobId)/redo", body: ["expectedVersion": expectedVersion], fallback: "Couldn't try those parts again.")
    }

    func cancel(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/cancel", fallback: "Couldn't cancel. Try again.")
    }

    func rename(jobId: String, name: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/rename", body: ["name": name], fallback: "Couldn't rename it.")
    }

    func delete(jobId: String) async throws {
        _ = try await exchange("jobs/\(jobId)", method: "DELETE", fallback: "Couldn't delete it. Try again.")
    }

    func saveToLibrary(jobId: String, version: Int, path: String, share: Bool) async throws -> DVLibrarySaved {
        try await post(
            "jobs/\(jobId)/library",
            body: ["version": version, "path": path, "share": share],
            timeout: 180,
            fallback: "Couldn't save it to your Library. Try again."
        )
    }

    /// A few seconds of the narrator, as WAV bytes. Counted in the allowance.
    func sample(voice: String, rate: Double, text: String? = nil) async throws -> Data {
        var body: [String: Any] = ["voice": voice, "rate": rate]
        if let text, !text.isEmpty { body["text"] = String(text.prefix(200)) }
        let data = try await exchange("sample", method: "POST", body: body, timeout: 90, fallback: "The sample could not be made. Try again.")
        guard !data.isEmpty else { throw DescribedVideoError(message: "The sample came back empty. Try again.") }
        return data
    }

    // MARK: Saving files

    /// A finished file (a signed storage link) saved to a temp file named for
    /// the video, for the share sheet. Streams to disk, so a long film never
    /// sits in memory.
    func download(from link: String, fileName: String) async throws -> URL {
        guard let url = URL(string: link) else { throw DescribedVideoError(message: "That download link is not valid. Try again.") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let session = client.makeAuxiliarySession(delegate: DescribedVideoSessionDelegate(), timeout: 120)
        defer { session.finishTasksAndInvalidate() }
        await client.awaitPacingGate()
        let (temporary, response) = try await session.download(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw DescribedVideoError(message: "The file could not be fetched. Refresh the links and try again.")
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    /// Text already in hand, as a file for the share sheet.
    func textFile(_ text: String, fileName: String) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: target)
        try Data(text.utf8).write(to: target, options: .atomic)
        return target
    }

    /// A name a person would recognise in Files: the video's own name.
    static func fileName(_ title: String, label: String, ext: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty ? "Described video" : String(cleaned.prefix(60))
        return "\(stem) (\(label)).\(ext)"
    }

    // MARK: Lock-screen cards
    //
    // A job outlives the screen: she can leave while it describes, the server
    // keeps going, and the screen picks it back up next time. The card ids live
    // on the TYPE, filed under the job, so a later visit moves the same card on
    // instead of starting a second beside it (the Sound Booth's rule).

    private struct Card { let id: String; var status: String; var progress: Double? }
    private static var cards: [String: Card] = [:]

    /// Starts the job's card, or moves it on when the words change or known
    /// progress moves a tenth or more.
    func showCard(jobId: String, title: String, status: String, progress: Double?) {
        if var card = Self.cards[jobId] {
            let moved = progress.map { abs($0 - (card.progress ?? 0)) >= 0.1 } ?? false
            guard status != card.status || moved else { return }
            card.status = status
            card.progress = progress
            Self.cards[jobId] = card
            KadeJobActivity.update(card.id, status: status, progress: progress)
            return
        }
        guard let id = KadeJobActivity.start(kind: "described-video", title: title, status: status, progress: progress) else { return }
        Self.cards[jobId] = Card(id: id, status: status, progress: progress)
    }

    func endCard(jobId: String, status: String, failed: Bool = false) {
        guard let card = Self.cards.removeValue(forKey: jobId) else { return }
        KadeJobActivity.finish(card.id, status: status, failed: failed)
    }

    /// A job that ended while the screen was closed still has its card up;
    /// the list says how it ended.
    func settleCards(with jobs: [DVJob]) {
        for key in Array(Self.cards.keys) {
            guard let job = jobs.first(where: { $0.id == key }) else { continue }
            if job.isWorking { continue }
            switch job.state {
            case "done": endCard(jobId: key, status: "Ready to watch")
            case "ready": endCard(jobId: key, status: "Checked and ready")
            case "cancelled": endCard(jobId: key, status: "Stopped", failed: true)
            case "uploading": endCard(jobId: key, status: "Upload paused", failed: true)
            default: endCard(jobId: key, status: "Didn't finish", failed: true)
            }
        }
    }
}

/// The download session needs a delegate object; it has nothing to say.
final class DescribedVideoSessionDelegate: NSObject, URLSessionDelegate {}
