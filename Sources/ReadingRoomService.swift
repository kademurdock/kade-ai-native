import Foundation
import CryptoKit
import AVFoundation
import MediaPlayer
import UIKit

/// THE READING ROOM — the phone half (Part 181, Sep 11 2026).
///
/// Her ask, in her words: "a reading room ... bookshare books read by the
/// inworld voices, chunks at a time, rewind and forward, bookmarks ... skip
/// all that watermark material ... read like an NLS book: jacket, useful
/// information, and the story ... share a book from my phone and read it on
/// my phone ... people can donate audio books too, mp3 or whatever ... a
/// movie category ... cassettes ... retro radio."
///
/// Two things live here, and the split matters:
///   - `ReadingRoomService`  every call to the fork (`/api/kade/reading-room`)
///                           and the uploads, on the one main-actor client.
///   - `ReadingRoomPlayer`   the thing that makes sound. Text books are
///                           spoken a chunk at a time (the fork streams each
///                           chunk as WAV from the voice proxy); donated
///                           recordings play straight from Backblaze on an
///                           AVPlayer. Both feed the lock screen through
///                           MPNowPlayingInfoCenter so the headphone buttons
///                           and the lock-screen skip buttons do what they say.
///
/// THE AUDIO SESSION, the one deliberate difference from the speech lane: a
/// book is `.playback` WITHOUT `.mixWithOthers`, because a mixing session is
/// never the "now playing" app and the remote commands silently do nothing.
/// The room puts the app's usual `.mixWithOthers` session back on exit.
///
/// Nothing is cached on disk. A chunk is ~450 characters (about half a
/// minute), two are always fetched ahead, and the fork's session header gives
/// the proxy the previous chunk as context so the voice carries on instead of
/// restarting its intonation every sentence.

// MARK: - Wire shapes

struct RRProgress: Codable, Hashable {
    var s: Int
    var c: Int
    var pos: Double?
    var voice: String?
    var speed: Double?
    var finished: Bool?
    var where_: String?
    /// When this progress row last changed (the server's timestamp, ISO).
    /// Sep 23 2026 (B7): picks the Library's "Continue" item.
    var updatedAt: String?
    enum CodingKeys: String, CodingKey { case s, c, pos, voice, speed, finished, where_ = "where", updatedAt }
}

struct RRItem: Codable, Identifiable, Hashable {
    let id: String
    var kind: String            // "text" | "audio" | "video"
    var category: String        // book | audiobook | movie | cassette | radio | commercials | music | other
    var description: String?
    var tracks: Int?
    var seconds: Double?
    var state: String?
    var title: String
    var author: String?
    var publisher: String?
    var copyrightYear: String?
    var synopsis: String?
    var source: String?
    var ownerName: String?
    var owner: String?
    var shared: Bool
    var grownUpsOnly: Bool
    var sections: Int?
    var chunks: Int?
    var listen: String?
    var skippedCount: Int?
    var progress: RRProgress?
    var path: String?
    var described: Bool?

    /// Sep 12 2026, her word: "videos are showing up as books, doesn't seem
    /// like there's a way to play them or get AI descriptions". The archive
    /// push files a movie as kind "video"; this used to say only "audio" is a
    /// recording, so every video fell through to the book reader. Anything
    /// that is not text is a recording with tracks (audio or video).
    var isAudio: Bool { kind != "text" }
    var categoryName: String { RRCategory.name(category, isAudio: isAudio) }
    /// What VoiceOver says for the row.
    func spokenRow(where place: String) -> String {
        var bits: [String] = [title]
        if let a = author, !a.isEmpty { bits.append("by \(a)") }
        bits.append(categoryName)
        if let l = listen, !l.isEmpty { bits.append(l) }
        if let p = progress, let w = p.where_, !w.isEmpty { bits.append((isAudio ? "part " : "chapter ") + w) }
        if place != "mine", let d = ownerName, !d.isEmpty { bits.append("donated by \(d)") }
        if state == "pending" { bits.append("no recordings yet") }
        if place == "mine", shared { bits.append("in the library") }
        return bits.joined(separator: ", ")
    }
}

enum RRCategory {
    static let audio: [(String, String)] = [("audiobook", "Audiobook"), ("movie", "Movie"), ("cassette", "Cassette"), ("radio", "Radio"), ("commercials", "Commercials"), ("music", "Music"), ("other", "Other")]
    static func name(_ key: String, isAudio: Bool) -> String {
        if !isAudio { return "Book" }
        return audio.first(where: { $0.0 == key })?.1 ?? key.capitalized
    }
}

struct RRShelf: Codable {
    var mine: [RRItem]
    var borrowed: [RRItem]
    var library: [RRItem]
    var categories: [String]?
    var defaultVoice: String?
    var me: String?
    var librarian: Bool?
    var archiveOwned: Int?
    var libraryCount: Int?
    var libraryFiled: Int?
}

struct RRChapter: Codable, Identifiable, Hashable {
    let s: Int
    let title: String
    let chunks: Int?
    let chars: Int?
    let kind: String?
    var id: Int { s }
}
struct RRTrack: Codable, Identifiable, Hashable {
    let s: Int
    let title: String
    let seconds: Double?
    let bytes: Int?
    let mime: String?
    let url: String
    var description: RRDescription?
    var recaps: [RRRecap]?
    var clipBegin: Double?
    var clipEnd: Double?
    var id: Int { s }
}
struct RRSkipped: Codable, Identifiable, Hashable {
    let k: Int
    let title: String
    let reason: String
    let chunks: Int?
    var id: Int { k }
    var why: String {
        switch reason {
        case "bookshare-notice": return "Bookshare notice"
        case "copyright": return "copyright page"
        case "contents": return "contents list"
        case "publisher": return "publisher page"
        case "front-matter": return "front matter"
        case "back-matter": return "back matter"
        default: return reason
        }
    }
}
struct RRBookmark: Codable, Identifiable, Hashable {
    let id: String
    let s: Int
    let c: Int
    let pos: Double?
    let note: String?
    let snippet: String?
    let sectionTitle: String?
}

struct RRBook: Codable {
    let id: String
    let kind: String
    let category: String
    let title: String
    let author: String?
    let description: String?
    let ownerName: String?
    var shared: Bool
    var grownUpsOnly: Bool
    let listen: String?
    let jacket: String?
    let chapters: [RRChapter]
    let tracks: [RRTrack]
    let skipped: [RRSkipped]
    var bookmarks: [RRBookmark]
    let mine: Bool
    let defaultVoice: String?
    var progress: RRProgress?
    var librarian: RRLibrarian?
    var path: String?
    var copyrightYear: String?
    var isAudio: Bool { kind != "text" }   // audio or video: tracks, not chapters
    var partCount: Int { isAudio ? tracks.count : chapters.count }
    func partTitle(_ s: Int) -> String {
        if isAudio { return tracks.indices.contains(s) ? tracks[s].title : "" }
        return chapters.indices.contains(s) ? chapters[s].title : ""
    }
}

struct RRChunkText: Codable {
    let text: String
    let title: String?
}

struct RRError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Part 291 (Sep 25 2026): the library already holds exactly this file (the
/// same SHA-256) somewhere she can open it, so nothing was uploaded. Not a
/// failure: the words are said as they are, and the upload counts as done.
struct RRAlreadyInLibrary: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// The server's own sentence when it sent one; otherwise the plain one.
    init(serverMessage: String?, title: String?) {
        let said = (serverMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty {
            message = said
        } else {
            message = "Already in the library: \(name.isEmpty ? "this file" : name). It is exactly the same file, so it is kept once."
        }
    }
}

// MARK: - The service

@MainActor
final class ReadingRoomService: ObservableObject {
    let client: KadeAPIClient
    @Published var shelf: RRShelf?
    @Published var isLoading = false
    @Published var uploadStatus: String?

    init(client: KadeAPIClient) { self.client = client }

    struct LibrarianGuide: Decodable {
        let agentId: String
        let name: String
    }

    func librarianGuide() async throws -> LibrarianGuide {
        try await json(client.request(path: "api/kade/reading-room/guide", authorized: true), as: LibrarianGuide.self)
    }

    private struct ErrBody: Decodable { let error: String? }

    private func json<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let e = try? JSONDecoder().decode(ErrBody.self, from: data)
            throw RRError(message: e?.error ?? "The Reading Room answered \(http.statusCode).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval? = nil) -> URLRequest {
        var req = client.request(path: path, method: "POST", authorized: true, timeout: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    func loadShelf() async {
        isLoading = true
        defer { isLoading = false }
        do {
            shelf = try await json(client.request(path: "api/kade/reading-room/shelf", authorized: true), as: RRShelf.self)
        } catch {
            uploadStatus = error.localizedDescription
        }
    }

    func openBook(_ id: String) async throws -> RRBook {
        try await json(client.request(path: "api/kade/reading-room/book/\(id)", authorized: true, timeout: 45), as: RRBook.self)
    }

    func chunkText(bookId: String, s: Int, c: Int) async throws -> RRChunkText {
        try await json(client.request(path: "api/kade/reading-room/book/\(bookId)/text/\(s)/\(c)", authorized: true), as: RRChunkText.self)
    }

    /// The spoken chunk, whole. Streamed on the wire by the fork; read to the
    /// end here, because a ~30-second chunk decoded once and scheduled once is
    /// simpler and more robust than a second streaming pump (VoiceService's
    /// doc comment lists what the first one cost to get right).
    func chunkAudio(bookId: String, s: Int, c: Int, voice: String, speed: Double, skipped: Bool = false) async throws -> Data {
        var items = [URLQueryItem(name: "voice", value: voice), URLQueryItem(name: "speed", value: String(format: "%.2f", speed))]
        items.append(URLQueryItem(name: "delivery", value: VoiceService.delivery(forAgent: ReadingRoomPlayer.deliveryPreference) ?? "STABLE"))
        if skipped { items.append(URLQueryItem(name: "skipped", value: "1")) }
        let req = client.request(path: "api/kade/reading-room/book/\(bookId)/audio/\(s)/\(c)", authorized: true, queryItems: items, timeout: 90)
        let (data, http) = try await client.send(req)
        if http.statusCode == 204 { return Data() }
        guard http.statusCode == 200 else {
            let e = try? JSONDecoder().decode(ErrBody.self, from: data)
            throw RRError(message: e?.error ?? "The voice did not answer (\(http.statusCode)).")
        }
        return data
    }

    func saveProgress(bookId: String, s: Int, c: Int, pos: Double, voice: String, speed: Double, finished: Bool = false) async {
        var body: [String: Any] = ["s": s, "c": c, "pos": pos, "voice": voice, "speed": speed]
        if finished { body["finished"] = true }
        _ = try? await client.send(post("api/kade/reading-room/book/\(bookId)/progress", body))
    }

    func addBookmark(bookId: String, s: Int, c: Int, pos: Double) async throws -> RRBookmark {
        struct R: Decodable { let bookmark: RRBookmark }
        return try await json(post("api/kade/reading-room/book/\(bookId)/bookmarks", ["s": s, "c": c, "pos": pos]), as: R.self).bookmark
    }
    func removeBookmark(bookId: String, id: String) async throws {
        var req = client.request(path: "api/kade/reading-room/book/\(bookId)/bookmarks/\(id)", method: "DELETE", authorized: true)
        req.httpBody = nil
        _ = try await client.send(req)
    }
    struct ShareResult: Decodable { let book: RRItem; let pending: Bool? }
    func setShared(bookId: String, shared: Bool? = nil, grownUpsOnly: Bool? = nil) async throws -> ShareResult {
        var body: [String: Any] = [:]
        if let shared { body["shared"] = shared }
        if let grownUpsOnly { body["grownUpsOnly"] = grownUpsOnly }
        return try await json(post("api/kade/reading-room/book/\(bookId)/share", body), as: ShareResult.self)
    }
    func returnBook(bookId: String) async throws {
        _ = try await client.send(post("api/kade/reading-room/book/\(bookId)/return", [:]))
    }
    func withdraw(bookId: String) async throws {
        let req = client.request(path: "api/kade/reading-room/book/\(bookId)", method: "DELETE", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let e = try? JSONDecoder().decode(ErrBody.self, from: data)
            throw RRError(message: e?.error ?? "Could not withdraw it.")
        }
    }

    // MARK: uploads

    /// `duplicate`: the server already had this exact text where you can open it (Sep 25 2026), so nothing new was saved.
    /// `same == "file"` (Part 291): it was exactly the same file, found by its SHA-256 before any upload.
    struct UploadedBook: Decodable { let book: RRItem; let skipped: [RRSkippedSummary]?; let jacket: String?; let duplicate: Bool?; let same: String?; let message: String? }
    struct RRSkippedSummary: Decodable { let title: String?; let reason: String? }

    /// SHA-256 of a file on disk as lowercase hex, read 1 MB at a time off the
    /// main actor. Book imports and recording parts both send it (Part 291),
    /// so the server can say "exactly the same file" before anything uploads.
    private static func sha256Hex(of fileURL: URL) async throws -> String {
        let hashTask = Task.detached(priority: .utility) {
            let source = try FileHandle(forReadingFrom: fileURL)
            defer { try? source.close() }
            var hash = SHA256()
            while true {
                try Task.checkCancellation()
                let block = try source.read(upToCount: 1024 * 1024) ?? Data()
                if block.isEmpty { break }
                hash.update(data: block)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler(operation: { try await hashTask.value }, onCancel: { hashTask.cancel() })
    }

    /// Upload bytes to storage, then check a durable import job using short requests.
    /// `onProgress` (Sep 23 2026, C3) hears the storage upload's 0...1 for
    /// the lock-screen card; without it the upload runs exactly as before.
    func uploadBook(fileURL: URL, grownUpsOnly: Bool, keepPrivate: Bool = false, onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> UploadedBook {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let before = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let bytes = (before[.size] as? NSNumber)?.int64Value ?? 0
        let limit: Int64 = fileURL.pathExtension.lowercased() == "zip" ? 4 * 1024 * 1024 * 1024 : 256 * 1024 * 1024
        guard bytes > 0, bytes <= limit else { throw RRError(message: "Book ZIPs must be 4 GB or smaller; other book files must be 256 MB or smaller.") }
        let digest = try await Self.sha256Hex(of: fileURL)
        let requestID = "book-" + digest + (keepPrivate ? "-private" : "-shared") + (grownUpsOnly ? "-adult" : "-all")
        struct Job: Decodable { let id: String; let state: String; let uploadRequired: Bool?; let url: String?; let mime: String?; let result: UploadedBook?; let error: String? }
        // `sha256` (Part 291): when the library already holds exactly this file
        // where she can open it, the job comes back ready with a duplicate
        // result and uploadRequired false, so nothing is uploaded.
        var job = try await json(post("api/kade/reading-room/imports", ["requestId": requestID, "fileName": fileURL.lastPathComponent, "bytes": bytes, "private": keepPrivate, "grownUpsOnly": grownUpsOnly, "sha256": digest]), as: Job.self)
        if job.uploadRequired == true {
            guard let address = job.url, let url = URL(string: address) else { throw RRError(message: "Missing storage address.") }
            var put = URLRequest(url: url); put.httpMethod = "PUT"; put.timeoutInterval = 7200
            put.setValue(job.mime ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            let response: URLResponse
            if let onProgress {
                // The same progress delegate the recording uploads use.
                let session = URLSession(configuration: .default, delegate: UploadProgressDelegate(onProgress: onProgress), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                response = try await session.upload(for: put, fromFile: fileURL).1
            } else {
                response = try await URLSession.shared.upload(for: put, fromFile: fileURL).1
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RRError(message: "Storage did not confirm the upload. Retry the same file to recover it.") }
        }
        let after = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber), (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else { throw RRError(message: "The local book changed during upload. Select the finished file again.") }
        if job.state != "ready" { job = try await json(post("api/kade/reading-room/imports/\(job.id)/commit", [:]), as: Job.self) }
        let deadline = Date().addingTimeInterval(7200)
        while job.state != "ready" {
            try Task.checkCancellation()
            if job.state == "failed" { throw RRError(message: job.error ?? "Book import failed. Retry the same file.") }
            guard Date() < deadline else { throw RRError(message: "Your book is stored and its import is pending. Select the same file to check it again.") }
            try await Task.sleep(nanoseconds: 8_500_000_000)
            job = try await json(client.request(path: "api/kade/reading-room/imports/\(job.id)", authorized: true), as: Job.self)
        }
        guard let result = job.result else { throw RRError(message: "Import receipt missing. Select the same file to recover it.") }
        return result
    }

    /// Start a recording donation; returns the item to add parts to.
    func newRecording(title: String, author: String, year: String, category: String, description: String, grownUpsOnly: Bool, keepPrivate: Bool = false) async throws -> RRItem {
        struct R: Decodable { let item: RRItem }
        return try await json(post("api/kade/reading-room/media/new", ["title": title, "author": author, "year": year, "category": category, "description": description, "grownUpsOnly": grownUpsOnly, "private": keepPrivate]), as: R.self).item
    }

    /// One part, straight to Backblaze: ask the fork for a signed PUT, send
    /// the file from disk (never through memory), tell the fork it landed.
    func uploadTrack(item: RRItem, fileURL: URL, title: String, onProgress: @escaping @MainActor (Double) -> Void) async throws -> RRItem {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let seconds = (try? await AVURLAsset(url: fileURL).load(.duration).seconds) ?? 0
        guard bytes > 0, Int64(bytes) <= 20 * 1024 * 1024 * 1024 else { throw RRError(message: "Recordings must be 20 GB or smaller.") }
        struct Part: Decodable { let partNumber: Int; let url: String }
        struct Multipart: Decodable { let uploadId: String; let partBytes: Int; let parts: [Part] }
        /// Only the title is read, and an odd shape reads as no title rather
        /// than failing the whole answer.
        struct Existing: Decodable {
            let title: String?
            enum CodingKeys: String, CodingKey { case title }
            init(from decoder: Decoder) throws {
                let c = try? decoder.container(keyedBy: CodingKeys.self)
                title = try? c?.decode(String.self, forKey: .title)
            }
        }
        // Part 291: a duplicate answer has no key or mime, only
        // duplicate/same/message/existing, so those are optional here.
        struct Pre: Decodable {
            let key: String?
            let url: String?
            let mime: String?
            let multipart: Multipart?
            let duplicate: Bool?
            let same: String?
            let message: String?
            let existing: Existing?
        }
        struct R: Decodable { let item: RRItem }
        // Save the completion receipt before notifying the library, so a lost
        // response can be retried with the same storage key.
        let recoveryKey = "library-track-receipt-" + item.id + "-" + fileURL.lastPathComponent + "-" + String(bytes) + "-" + String((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        if let saved = UserDefaults.standard.data(forKey: recoveryKey), let body = try JSONSerialization.jsonObject(with: saved) as? [String: Any] {
            let result = try await json(post("api/kade/reading-room/media/\(item.id)/track/done", body), as: R.self).item
            UserDefaults.standard.removeObject(forKey: recoveryKey)
            return result
        }
        // Part 291: the file's SHA-256 goes with the presign, so a file the
        // library already holds (exactly the same bytes, somewhere she can
        // open) is answered before any upload, and nothing is sent.
        let digest = try await Self.sha256Hex(of: fileURL)
        let pre = try await json(post("api/kade/reading-room/media/\(item.id)/track/presign", ["fileName": fileURL.lastPathComponent, "mime": "", "bytes": bytes, "multipart": true, "sha256": digest]), as: Pre.self)
        if pre.duplicate == true {
            throw RRAlreadyInLibrary(serverMessage: pre.message, title: pre.existing?.title)
        }
        guard let key = pre.key, let mime = pre.mime else { throw RRError(message: "The library did not return an upload address.") }
        func send(_ file: URL, address: String, offset: Int, length: Int) async throws -> HTTPURLResponse {
            guard let url = URL(string: address) else { throw RRError(message: "Bad upload address.") }
            var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 7200
            request.setValue(mime, forHTTPHeaderField: "Content-Type")
            let delegate = UploadProgressDelegate { progress in onProgress((Double(offset) + progress * Double(length)) / Double(bytes)) }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (_, response) = try await session.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RRError(message: "Storage did not accept the file (\((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
            return http
        }
        var body: [String: Any] = ["key": key, "title": title, "bytes": bytes, "seconds": seconds.isFinite ? seconds : 0, "originalName": fileURL.lastPathComponent]
        if let multipart = pre.multipart {
            guard multipart.partBytes > 0, !multipart.parts.isEmpty else { throw RRError(message: "Invalid multipart upload plan.") }
            var receipts: [[String: Any]] = []
            let source = try FileHandle(forReadingFrom: fileURL)
            defer { try? source.close() }
            for part in multipart.parts {
                try Task.checkCancellation()
                let offset = (part.partNumber - 1) * multipart.partBytes
                let length = min(multipart.partBytes, bytes - offset)
                guard offset >= 0, length > 0 else { throw RRError(message: "Invalid upload part.") }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("library-part-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                FileManager.default.createFile(atPath: temporary.path, contents: nil)
                let output = try FileHandle(forWritingTo: temporary)
                do {
                    try source.seek(toOffset: UInt64(offset))
                    var remaining = length
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let block = try source.read(upToCount: min(1024 * 1024, remaining)) ?? Data()
                        guard !block.isEmpty else { throw RRError(message: "The local file changed during upload.") }
                        try output.write(contentsOf: block); remaining -= block.count
                    }
                    try output.close()
                } catch { try? output.close(); throw error }
                let response = try await send(temporary, address: part.url, offset: offset, length: length)
                guard let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else { throw RRError(message: "Storage omitted the part receipt.") }
                receipts.append(["partNumber": part.partNumber, "etag": etag])
            }
            body["multipart"] = ["uploadId": multipart.uploadId, "parts": receipts]
        } else {
            guard let address = pre.url else { throw RRError(message: "Missing upload address.") }
            _ = try await send(fileURL, address: address, offset: 0, length: bytes)
        }
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: body), forKey: recoveryKey)
        let result = try await json(post("api/kade/reading-room/media/\(item.id)/track/done", body), as: R.self).item
        UserDefaults.standard.removeObject(forKey: recoveryKey)
        return result
    }

    // MARK: voices

    struct VoiceGroup: Identifiable { let name: String; let voices: [String]; var id: String { name } }
    /// The proxy's own catalogue, the same one every voice picker uses.
    func loadVoices() async -> [VoiceGroup] {
        struct Cat: Decodable { let name: String; let voices: [String] }
        struct Resp: Decodable { let categories: [Cat]?; let hidden: [String]? }
        let base = "https://inworld-tts-proxy-production.up.railway.app/voices.json"
        guard let url = URL(string: base) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 KadeAI", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        let hidden = Set(r.hidden ?? [])
        return (r.categories ?? []).compactMap { c in
            let vs = c.voices.filter { !hidden.contains($0) }
            return vs.isEmpty ? nil : VoiceGroup(name: c.name, voices: vs)
        }
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: @MainActor (Double) -> Void
    init(onProgress: @escaping @MainActor (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in self.onProgress(p) }
    }
}

// MARK: - The player

@MainActor
final class ReadingRoomPlayer: ObservableObject {
    static let deliveryPreference = "library-reading"
    private let service: ReadingRoomService
    @Published private(set) var book: RRBook?
    @Published private(set) var s = 0
    @Published private(set) var c = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var nowText = ""
    @Published var voice = ""
    @Published var speed: Double = 1.0
    /// What to announce (a chapter change, an error). The view speaks it.
    @Published var announcement: String?
    @Published private(set) var filePosition: Double = 0
    @Published private(set) var fileDuration: Double = 0

    // text engine — STREAMED. The proxy speaks a chunk in ~half its play
    // time, so waiting for the whole WAV meant ~14 s before the first word
    // (measured on the fork smoke). The bytes are pulled through the same
    // StreamingClipFetch the speech lane uses and scheduled on the node in
    // ~0.4 s buffers as they land; the next chunk's fetch starts the moment
    // this one has fully arrived, with the queue capped at ~60 s ahead.
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var graphRate: Double = 0
    private var playToken = 0
    private var producer: Task<Void, Never>?
    private var activeFetch: StreamingClipFetch?
    private var queuedFrames: Int = 0
    private var textOffset: Double = 0
    private var seekTask: Task<Void, Never>?
    private var seekGeneration = 0
    private var audioCache: [String: Data] = [:]
    private var cacheOrder: [String] = []

    private func cacheKey(_ ss: Int, _ cc: Int) -> String {
        "\(book?.id ?? "")|\(ss)|\(cc)|\(voice)|\(speed)|\(VoiceService.delivery(forAgent: Self.deliveryPreference) ?? "STABLE")"
    }
    private func remember(_ data: Data, key: String) {
        guard !data.isEmpty else { return }
        audioCache[key] = data
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        while cacheOrder.count > 12 { audioCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
    private func previous(s: Int, c: Int) -> (s: Int, c: Int)? {
        if c > 0 { return (s, c - 1) }
        if s > 0 { return (s - 1, max(0, (book?.chapters[s - 1].chunks ?? 1) - 1)) }
        return nil
    }
    private func duration(_ data: Data) throws -> Double {
        guard let seconds = StreamingWavParser.pcmDuration(data) else {
            throw RRError(message: "That passage did not contain playable audio.")
        }
        return seconds
    }
    private func seekAudio(_ q: (s: Int, c: Int), bookId: String) async throws -> Data {
        let key = cacheKey(q.s, q.c)
        if let data = audioCache[key] { return data }
        let data = try await service.chunkAudio(bookId: bookId, s: q.s, c: q.c, voice: voice, speed: speed)
        try Task.checkCancellation()
        remember(data, key: key)
        return data
    }

    func skip(seconds: Double) {
        guard let book, seconds.isFinite else { return }
        if book.isAudio {
            seekFile(by: seconds)
            announcement = "\(seconds < 0 ? "Back" : "Forward") \(Int(abs(seconds))) seconds."
            return
        }
        let resume = isPlaying
        let original = (s: s, c: c, offset: textOffset)
        pause()
        seekTask?.cancel(); seekGeneration += 1
        let generation = seekGeneration
        seekTask = Task { [weak self] in
            guard let self else { return }
            var q = (s: original.s, c: original.c)
            var offset = original.offset + seconds
            do {
                while offset < 0 {
                    guard let prev = self.previous(s: q.s, c: q.c) else { offset = 0; break }
                    q = prev
                    let data = try await self.seekAudio(q, bookId: book.id)
                    offset += try self.duration(data)
                }
                while true {
                    let data = try await self.seekAudio(q, bookId: book.id)
                    let length = try self.duration(data)
                    if offset < length { break }
                    guard let next = self.next(s: q.s, c: q.c) else { offset = max(0, length - 0.05); break }
                    offset -= length; q = next
                }
                guard !Task.isCancelled, self.seekGeneration == generation, self.book?.id == book.id else { return }
                self.s = q.s; self.c = q.c; self.textOffset = max(0, offset)
                await self.refreshText()
                self.scheduleSave()
                self.announcement = "\(seconds < 0 ? "Back" : "Forward") \(Int(abs(seconds))) seconds."
                self.seekTask = nil
                if resume { self.play() }
            } catch {
                guard !Task.isCancelled, self.seekGeneration == generation else { return }
                self.announcement = error.localizedDescription
                self.seekTask = nil
                if resume { self.play() }
            }
        }
    }
    // file engine — `avPlayer` is read by the VideoPane's VideoPlayer
    private(set) var avPlayer: AVPlayer?
    /// The library's eyes on the phone: when on, the player pauses at each
    /// described scene, speaks it, and carries on (extended audio description).
    @Published var describedMode = false
    var scenes: [RRScene] = []
    private var spokenScenes: Set<Int> = []
    private var describing = false
    /// Collection playback: item ids still to play after this one.
    var queue: [String] = []
    var onQueueNext: ((String) -> Void)?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var remoteWired = false
    private var saveTask: Task<Void, Never>?

    init(service: ReadingRoomService) { self.service = service }

    var isAudio: Bool { book?.isAudio ?? false }
    var partCount: Int { book?.partCount ?? 0 }
    var partTitle: String { book?.partTitle(s) ?? "" }
    var positionSpoken: String {
        guard let book else { return "" }
        let what = book.isAudio ? "Part" : "Chapter"
        let t = book.partTitle(s)
        return "\(what) \(s + 1) of \(book.partCount)" + (t.isEmpty ? "" : ": \(t)")
    }

    // MARK: open / close

    func open(_ book: RRBook) {
        if self.book != nil { close() }
        self.book = book
        audioCache.removeAll(); cacheOrder.removeAll()
        let p = book.progress
        s = min(max(0, p?.s ?? 0), max(0, book.partCount - 1))
        c = book.isAudio ? 0 : max(0, p?.c ?? 0)
        voice = (p?.voice?.isEmpty == false ? p?.voice : nil) ?? book.defaultVoice ?? "Kiana (Comedian)"
        speed = p?.speed ?? 1.0
        textOffset = max(0, p?.pos ?? 0)
        prepareSession()
        wireRemote()
        if book.isAudio {
            loadTrack(s, at: p?.pos ?? 0, play: false)
        } else {
            Task { await refreshText() }
        }
        updateNowPlaying()
    }

    func close() {
        seekTask?.cancel(); seekTask = nil; seekGeneration += 1
        let wasPlaying = isPlaying
        pause()
        if !wasPlaying { saveNow() }
        saveTask?.cancel(); saveTask = nil
        unwireRemote()
        if let o = timeObserver { avPlayer?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil; endObserver = nil
        avPlayer = nil
        stopNode()
        if engine.isRunning { engine.stop() }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Back to the app's usual session shape (VoiceService.prepareOutputSession).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        book = nil
        audioCache.removeAll(); cacheOrder.removeAll()
        textOffset = 0
    }

    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    // MARK: transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let book, seekTask == nil else { return }
        prepareSession()
        // Sep 23 2026 (A2): takes the lock-screen buttons back after a call
        // (see yieldRemoteControls). A no-op while they are still wired.
        wireRemote()
        if book.isAudio {
            avPlayer?.playImmediately(atRate: Float(speed))
            isPlaying = true
            updateNowPlaying()
            return
        }
        guard !isPlaying else { return }
        isPlaying = true
        playToken += 1
        let token = playToken
        stopNode()
        updateNowPlaying()
        producer = Task { [weak self] in await self?.runProducer(token: token) }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        if isAudio {
            avPlayer?.pause()
        } else {
            playToken += 1
            stopNode()
        }
        saveNow()
        updateNowPlaying()
    }

    func back() { skip(seconds: -10) }
    func forward() { skip(seconds: 10) }

    func previousPart() {
        guard let book else { return }
        let atStart = book.isAudio ? filePosition < 5 : c == 0
        let target = atStart ? s - 1 : s
        if target < 0 { announcement = "This is the first \(book.isAudio ? "part" : "chapter")."; return }
        goToPart(target)
    }

    func nextPart() {
        guard let book else { return }
        if s + 1 >= book.partCount { announcement = "This is the last \(book.isAudio ? "part" : "chapter")."; return }
        goToPart(s + 1)
    }

    func goToPart(_ index: Int) {
        guard let book, book.partCount > 0 else { return }
        let i = min(max(0, index), book.partCount - 1)
        if book.isAudio { loadTrack(i, at: 0, play: isPlaying) } else { seek(s: i, c: 0) }
        announcement = positionSpoken
    }

    func goToBookmark(_ b: RRBookmark) {
        guard let book else { return }
        if book.isAudio { loadTrack(b.s, at: b.pos ?? 0, play: isPlaying) } else { seek(s: b.s, c: b.c, offset: b.pos ?? 0) }
        announcement = "Bookmark: " + positionSpoken
    }

    func restart() { goToPart(0); if !isAudio { seek(s: 0, c: 0) } }

    /// Current spot, for a bookmark.
    var here: (s: Int, c: Int, pos: Double) { (s, c, isAudio ? filePosition : textOffset) }

    func changeVoice(_ v: String) {
        seekTask?.cancel(); seekTask = nil; seekGeneration += 1
        voice = v
        let was = isPlaying
        if was { pause() }
        saveNow()
        if was { play() }
    }
    func changeSpeed(_ sp: Double) {
        seekTask?.cancel(); seekTask = nil; seekGeneration += 1
        speed = sp
        if isAudio { if isPlaying { avPlayer?.rate = Float(sp) } }
        else { let was = isPlaying; if was { pause(); play() } }
        saveNow()
    }

    // MARK: text engine

    private func next(s: Int, c: Int) -> (s: Int, c: Int)? {
        guard let book else { return nil }
        let count = book.chapters.indices.contains(s) ? (book.chapters[s].chunks ?? 0) : 0
        if c + 1 < count { return (s, c + 1) }
        if s + 1 < book.chapters.count { return (s + 1, 0) }
        return nil
    }

    private func seek(s ns: Int, c nc: Int, offset: Double = 0) {
        seekTask?.cancel(); seekTask = nil; seekGeneration += 1
        textOffset = max(0, offset)
        let was = isPlaying
        if was { playToken += 1; stopNode(); isPlaying = false }
        s = ns; c = nc
        Task { await refreshText() }
        scheduleSave()
        updateNowPlaying()
        if was { play() }
    }

    /// Stops everything scheduled and cancels the stream. Position is kept.
    private func stopNode() {
        producer?.cancel()
        producer = nil
        activeFetch?.cancel()
        activeFetch = nil
        if graphRate != 0 { node.stop() }
        if engine.isRunning { engine.pause() }
        queuedFrames = 0
    }

    private var queuedSeconds: Double { graphRate > 0 ? Double(queuedFrames) / graphRate : 0 }

    /// One chunk after another, each streamed and scheduled as it arrives.
    private func runProducer(token: Int) async {
        guard let book, !book.isAudio else { return }
        var cursor: (s: Int, c: Int)? = (s, c)
        while let q = cursor, token == playToken, isPlaying {
            while queuedSeconds > 60, token == playToken, isPlaying {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard token == playToken, isPlaying else { return }
            let n = next(s: q.s, c: q.c)
            do {
                let played = try await streamChunk(q, token: token, isLast: n == nil)
                guard token == playToken else { return }
                if !played, n == nil { bookFinished() ; return }
            } catch {
                guard token == playToken else { return }
                announcement = "\(error.localizedDescription) Press Play to try again."
                isPlaying = false
                stopNode()
                updateNowPlaying()
                return
            }
            cursor = n
        }
    }

    /// Streams one chunk into the node. Returns true when any audio was
    /// scheduled. The last buffer of the chunk carries the completion that
    /// moves the cursor to the next position (or ends the book).
    private func streamChunk(_ q: (s: Int, c: Int), token: Int, isLast: Bool) async throws -> Bool {
        guard let book else { return false }
        let bookId = book.id
        let voice = self.voice, speed = self.speed
        let delivery = VoiceService.delivery(forAgent: Self.deliveryPreference) ?? "STABLE"
        let key = cacheKey(q.s, q.c)
        let startOffset = q.s == s && q.c == c ? textOffset : 0
        if let cached = audioCache[key], let parsed = StreamingWavParser.parseHeader(cached) {
            var acc = PcmSampleAccumulator()
            let samples = mono(acc.append(cached.subdata(in: parsed.pcmStart..<cached.count)), channels: parsed.format.numChannels)
            let start = StreamingWavParser.framesToSkip(seconds: startOffset, rate: parsed.format.sampleRate, bufferStart: 0, count: samples.count)
            let step = max(1, Int(parsed.format.sampleRate * 0.4))
            for i in stride(from: start, to: samples.count, by: step) {
                let end = min(samples.count, i + step)
                schedule(samples: Array(samples[i..<end]), rate: parsed.format.sampleRate, final: end == samples.count, token: token, at: q, offset: Double(end) / parsed.format.sampleRate)
            }
            return start < samples.count
        }
        var whole = Data()
        var sampleOffset = 0
        let fetch = StreamingClipFetch(client: service.client) { [weak self] in
            guard let self else { return nil }
            let items = [URLQueryItem(name: "voice", value: voice), URLQueryItem(name: "speed", value: String(format: "%.2f", speed)), URLQueryItem(name: "delivery", value: delivery)]
            _ = self
            return self.service.client.request(path: "api/kade/reading-room/book/\(bookId)/audio/\(q.s)/\(q.c)", authorized: true, queryItems: items, timeout: 120)
        }
        activeFetch = fetch
        defer { if activeFetch === fetch { activeFetch = nil } }
        var header = Data()
        var format: StreamingWavFormat?
        var pcm = Data()
        var acc = PcmSampleAccumulator()
        var any = false
        var leftover: [Float] = []
        while let piece = await fetch.next() {
            guard token == playToken else { fetch.cancel(); return any }
            whole.append(piece)
            if format == nil {
                header.append(piece)
                guard let parsed = StreamingWavParser.parseHeader(header) else { continue }
                format = parsed.format
                if parsed.pcmStart < header.count { pcm = header.subdata(in: parsed.pcmStart ..< header.count) }
                header = Data()
            } else {
                pcm.append(piece)
            }
            guard let fmt = format else { continue }
            let threshold = Int(fmt.sampleRate) * fmt.numChannels * 2 * 2 / 5 // ~0.4 s
            if pcm.count >= threshold {
                leftover += mono(acc.append(pcm), channels: fmt.numChannels)
                pcm.removeAll(keepingCapacity: true)
                let end = sampleOffset + leftover.count
                let drop = StreamingWavParser.framesToSkip(seconds: startOffset, rate: fmt.sampleRate, bufferStart: sampleOffset, count: leftover.count)
                if schedule(samples: Array(leftover.dropFirst(drop)), rate: fmt.sampleRate, final: false, token: token, at: q, offset: Double(end) / fmt.sampleRate) { any = true }
                sampleOffset = end
                leftover.removeAll()
            }
        }
        guard token == playToken else { return any }
        if let s = fetch.lastStatus, s == 204 { return false }
        if let s = fetch.lastStatus, !(200 ..< 300).contains(s) { throw RRError(message: "The voice did not answer (HTTP \(s)).") }
        guard let fmt = format else {
            if fetch.deliveredBytes == 0 { throw RRError(message: fetch.failureNote == "empty stream" ? "The voice sent nothing for that part." : fetch.failureNote) }
            return false
        }
        if !pcm.isEmpty { leftover += mono(acc.append(pcm), channels: fmt.numChannels) }
        // the marker buffer: whatever is left, or 10 ms of silence
        if leftover.isEmpty { leftover = [Float](repeating: 0, count: Int(fmt.sampleRate / 100)) }
        remember(whole, key: key)
        let end = sampleOffset + leftover.count
        let drop = StreamingWavParser.framesToSkip(seconds: startOffset, rate: fmt.sampleRate, bufferStart: sampleOffset, count: leftover.count)
        if schedule(samples: Array(leftover.dropFirst(drop)), rate: fmt.sampleRate, final: true, token: token, at: q, offset: Double(end) / fmt.sampleRate) { any = true }
        return any
    }

    private func mono(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return samples }
        var out = [Float](); out.reserveCapacity(samples.count / channels)
        var i = 0
        while i + channels <= samples.count {
            var sum: Float = 0
            for ch in 0 ..< channels { sum += samples[i + ch] }
            out.append(sum / Float(channels))
            i += channels
        }
        return out
    }

    /// Schedules one buffer. The `final` buffer's completion advances the
    /// cursor from `at` to the next position.
    @discardableResult
    private func schedule(samples: [Float], rate: Double, final: Bool, token: Int, at q: (s: Int, c: Int), offset: Double) -> Bool {
        let step = max(1, Int(rate * 0.4))
        if samples.count > step {
            var scheduled = false
            for i in stride(from: 0, to: samples.count, by: step) {
                let end = min(samples.count, i + step)
                let endOffset = offset - Double(samples.count - end) / rate
                if schedule(samples: Array(samples[i..<end]), rate: rate, final: final && end == samples.count, token: token, at: q, offset: endOffset) { scheduled = true }
            }
            return scheduled
        }
        guard !samples.isEmpty, token == playToken,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }
        buildGraph(for: format)
        if !engine.isRunning { try? engine.start() }
        let n = samples.count
        queuedFrames += n
        node.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard token == self.playToken else { return }
                self.queuedFrames = max(0, self.queuedFrames - n)
                let changed = self.s != q.s || self.c != q.c
                self.s = q.s; self.c = q.c; self.textOffset = offset
                if changed { Task { await self.refreshText() } }
                if final { self.chunkFinished(q, token: token) }
            }
        }
        if !node.isPlaying { node.play() }
        return true
    }

    private func chunkFinished(_ pos: (s: Int, c: Int), token: Int) {
        guard token == playToken, isPlaying else { return }
        if let n = next(s: pos.s, c: pos.c) {
            let changed = n.s != s
            s = n.s; c = n.c; textOffset = 0
            Task { await refreshText() }
            scheduleSave()
            updateNowPlaying()
            if changed { announcement = positionSpoken }
        } else {
            bookFinished()
        }
    }

    private func bookFinished() {
        isPlaying = false
        stopNode()
        announcement = "The end. \(book?.title ?? "") is finished."
        if let book { Task { await service.saveProgress(bookId: book.id, s: s, c: c, pos: 0, voice: voice, speed: speed, finished: true) } }
        updateNowPlaying()
    }

    private func buildGraph(for format: AVAudioFormat) {
        if graphRate == format.sampleRate { return }
        if graphRate != 0 { engine.disconnectNodeOutput(node) } else { engine.attach(node) }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        graphRate = format.sampleRate
    }

    private func refreshText() async {
        guard let book, !book.isAudio else { return }
        let ss = s, cc = c
        if let t = try? await service.chunkText(bookId: book.id, s: ss, c: cc), self.book?.id == book.id, ss == s, cc == c {
            nowText = t.text
        }
    }

    // MARK: file engine

    private func loadTrack(_ index: Int, at seconds: Double, play: Bool) {
        guard let book, book.tracks.indices.contains(index), let url = URL(string: book.tracks[index].url) else { return }
        s = index; c = 0
        spokenScenes.removeAll()
        scenes = book.tracks[index].description?.scenes ?? []
        if let o = timeObserver { avPlayer?.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        let item = AVPlayerItem(url: url)
        let clipStart = book.tracks[index].clipBegin ?? 0
        if let end = book.tracks[index].clipEnd { item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 1000) }
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        avPlayer = player
        fileDuration = book.tracks[index].seconds ?? 0
        filePosition = seconds
        nowText = book.tracks[index].title
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.filePosition = t.seconds.isFinite ? max(0, t.seconds - clipStart) : 0
                if book.tracks[index].clipEnd == nil, let d = self.avPlayer?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.fileDuration = max(0, d - clipStart) }
                if Int(self.filePosition) % 10 == 0 { self.scheduleSave() }
                self.updateNowPlayingTime()
                self.checkDescribedScene()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let book = self.book else { return }
                if self.describing { return }
                if self.s + 1 < book.tracks.count {
                    self.loadTrack(self.s + 1, at: 0, play: true)
                    self.announcement = self.positionSpoken
                } else if !self.queue.isEmpty {
                    let next = self.queue.removeFirst()
                    self.announcement = "Next in the collection."
                    self.onQueueNext?(next)
                } else {
                    self.isPlaying = false
                    self.announcement = "The end. \(book.title) is finished."
                    Task { await self.service.saveProgress(bookId: book.id, s: self.s, c: 0, pos: 0, voice: self.voice, speed: self.speed, finished: true) }
                    self.updateNowPlaying()
                }
            }
        }
        if seconds + clipStart > 0 { player.seek(to: CMTime(seconds: seconds + clipStart, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) }
        if play { self.play() }
        scheduleSave()
        updateNowPlaying()
    }

    func seekFile(to seconds: Double) {
        guard let p = avPlayer else { return }
        let start = book?.tracks[s].clipBegin ?? 0
        p.seek(to: CMTime(seconds: max(0, seconds) + start, preferredTimescale: 1000))
        filePosition = max(0, seconds)
        spokenScenes = Set(scenes.indices.filter { scenes[$0].t < seconds - 1 })
        scheduleSave()
    }

    /// Speak one line through the platform voice; waits until it has been said.
    func speak(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let data = try? await service.speech(t, voice: voice) { await SkippedClipPlayer.shared.play(data) }
    }

    private func checkDescribedScene() {
        guard describedMode, !describing, isAudio, isPlaying, !scenes.isEmpty else { return }
        let t = filePosition
        for (i, sc) in scenes.enumerated() where !spokenScenes.contains(i) && t >= sc.t && t < sc.t + 1.5 {
            spokenScenes.insert(i)
            describing = true
            avPlayer?.pause()
            Task { @MainActor in
                await self.speak(sc.text)
                self.describing = false
                if self.isPlaying { self.avPlayer?.play() }
            }
            break
        }
    }

    private func seekFile(by delta: Double) {
        guard let p = avPlayer else { return }
        let target = max(0, min(fileDuration > 0 ? fileDuration - 0.5 : .greatestFiniteMagnitude, filePosition + delta))
        p.seek(to: CMTime(seconds: target + (book?.tracks[s].clipBegin ?? 0), preferredTimescale: 1000))
        filePosition = target
        scheduleSave()
    }

    // MARK: progress

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveNowAsync()
        }
    }
    private func saveNow() {
        guard let book else { return }
        let position = here, voice = self.voice, speed = self.speed
        Task { await service.saveProgress(bookId: book.id, s: position.s, c: position.c, pos: position.pos, voice: voice, speed: speed) }
    }
    private func saveNowAsync() async {
        guard let book else { return }
        await service.saveProgress(bookId: book.id, s: s, c: c, pos: isAudio ? filePosition : textOffset, voice: voice, speed: speed)
    }

    // MARK: lock screen

    private func wireRemote() {
        guard !remoteWired else { return }
        remoteWired = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.back() }; return .success }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.forward() }; return .success }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previousPart() }; return .success }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.nextPart() }; return .success }
        center.stopCommand.isEnabled = false
    }
    /// Sep 23 2026 (A2): the book now outlives its screen, so a call can start
    /// while it is open. The call screen wires play/pause to its own barge-in
    /// and, on hang-up, removes EVERY target from those commands. The book
    /// lets go of the buttons for the call (LibraryNowPlaying calls this) and
    /// `play()` takes them back.
    func yieldRemoteControls() {
        unwireRemote()
    }

    private func unwireRemote() {
        guard remoteWired else { return }
        remoteWired = false
        let center = MPRemoteCommandCenter.shared()
        for cmd in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipBackwardCommand, center.skipForwardCommand, center.previousTrackCommand, center.nextTrackCommand] {
            cmd.removeTarget(nil)
        }
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }
    private func updateNowPlaying() {
        guard let book else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyArtist: (book.author?.isEmpty == false ? book.author! : (book.ownerName.map { "Donated by \($0)" } ?? "Kade-AI")),
            MPMediaItemPropertyAlbumTitle: partTitle.isEmpty ? "The Reading Room" : partTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
        ]
        if isAudio {
            info[MPMediaItemPropertyPlaybackDuration] = fileDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = filePosition
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        // Part 292: a painted picture, added after the words. The artwork
        // fetches its picture only when the system asks, so nothing here waits.
        if let artwork = lockScreenArtwork(for: book) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Part 292: the lock screen's picture for the open item: the glowing old
    /// radio for radio, the item's painted jacket for the rest, none for
    /// kinds nobody painted or with "Painted pictures" off. One artwork per
    /// picture, kept, so play and pause do not hand the lock screen a new one.
    private static var lockScreenArt: [String: MPMediaItemArtwork] = [:]
    private func lockScreenArtwork(for book: RRBook) -> MPMediaItemArtwork? {
        let showPictures = (UserDefaults.standard.object(forKey: KadeArt.showKey) as? Bool) ?? true
        guard showPictures, let name = KadeArt.lockScreenPicture(kind: book.kind, category: book.category) else { return nil }
        if let kept = Self.lockScreenArt[name] { return kept }
        let made = KadeArt.lockScreenArtwork(named: name)
        Self.lockScreenArt[name] = made
        return made
    }
    private func updateNowPlayingTime() {
        guard isAudio, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = filePosition
        info[MPMediaItemPropertyPlaybackDuration] = fileDuration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    static func clock(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
