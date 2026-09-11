import Foundation
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
    enum CodingKeys: String, CodingKey { case s, c, pos, voice, speed, finished, where_ = "where" }
}

struct RRItem: Codable, Identifiable, Hashable {
    let id: String
    var kind: String            // "text" | "audio"
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

    var isAudio: Bool { kind == "audio" }
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
    var isAudio: Bool { kind == "audio" }
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

// MARK: - The service

@MainActor
final class ReadingRoomService: ObservableObject {
    let client: KadeAPIClient
    @Published var shelf: RRShelf?
    @Published var isLoading = false
    @Published var uploadStatus: String?

    init(client: KadeAPIClient) { self.client = client }

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
    func setShared(bookId: String, shared: Bool? = nil, grownUpsOnly: Bool? = nil) async throws -> RRItem {
        struct R: Decodable { let book: RRItem }
        var body: [String: Any] = [:]
        if let shared { body["shared"] = shared }
        if let grownUpsOnly { body["grownUpsOnly"] = grownUpsOnly }
        return try await json(post("api/kade/reading-room/book/\(bookId)/share", body), as: R.self).book
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

    struct UploadedBook: Decodable { let book: RRItem; let skipped: [RRSkippedSummary]?; let jacket: String? }
    struct RRSkippedSummary: Decodable { let title: String?; let reason: String? }

    /// A book file (DAISY zip, EPUB, txt, docx, html) through the fork, which
    /// parses it. Read as Data: text-only DAISY zips are a few megabytes.
    func uploadBook(fileURL: URL, grownUpsOnly: Bool) async throws -> UploadedBook {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 80 * 1024 * 1024 else { throw RRError(message: "That file is over 80 MB. Bookshare's text-only DAISY zip is the one to share — it is usually under 5 MB.") }
        var req = client.multipartRequest(
            path: "api/kade/reading-room/upload",
            authorized: true,
            fields: [("grownUpsOnly", grownUpsOnly ? "1" : "0")],
            fileField: "book",
            fileData: data,
            fileName: fileURL.lastPathComponent,
            fileMimeType: fileURL.pathExtension.lowercased() == "epub" ? "application/epub+zip" : (fileURL.pathExtension.lowercased() == "zip" ? "application/zip" : "application/octet-stream")
        )
        req.timeoutInterval = 180
        return try await json(req, as: UploadedBook.self)
    }

    /// Start a recording donation; returns the item to add parts to.
    func newRecording(title: String, author: String, year: String, category: String, description: String, grownUpsOnly: Bool) async throws -> RRItem {
        struct R: Decodable { let item: RRItem }
        return try await json(post("api/kade/reading-room/media/new", ["title": title, "author": author, "year": year, "category": category, "description": description, "grownUpsOnly": grownUpsOnly]), as: R.self).item
    }

    /// One part, straight to Backblaze: ask the fork for a signed PUT, send
    /// the file from disk (never through memory), tell the fork it landed.
    func uploadTrack(item: RRItem, fileURL: URL, title: String, onProgress: @escaping @MainActor (Double) -> Void) async throws -> RRItem {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let seconds = (try? await AVURLAsset(url: fileURL).load(.duration).seconds) ?? 0
        struct Pre: Decodable { let key: String; let url: String; let mime: String }
        let pre = try await json(post("api/kade/reading-room/media/\(item.id)/track/presign", ["fileName": fileURL.lastPathComponent, "mime": "", "bytes": bytes]), as: Pre.self)
        guard let putURL = URL(string: pre.url) else { throw RRError(message: "Bad upload address.") }
        var put = URLRequest(url: putURL)
        put.httpMethod = "PUT"
        put.setValue(pre.mime, forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 3600
        // The bucket is not kademurdock.com: no pacing gate, no browser UA
        // needed, and a plain shared session can stream a file from disk.
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, resp) = try await session.upload(for: put, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw RRError(message: "Storage did not accept the file (\((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        struct R: Decodable { let item: RRItem }
        return try await json(post("api/kade/reading-room/media/\(item.id)/track/done", ["key": pre.key, "title": title, "bytes": bytes, "seconds": seconds.isFinite ? seconds : 0, "originalName": fileURL.lastPathComponent]), as: R.self).item
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

    // text engine
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var graphRate: Double = 0
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var inflight: Set<String> = []
    private var scheduled: [(s: Int, c: Int)] = []
    private var playToken = 0
    // file engine
    private var avPlayer: AVPlayer?
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
        self.book = book
        let p = book.progress
        s = min(max(0, p?.s ?? 0), max(0, book.partCount - 1))
        c = book.isAudio ? 0 : max(0, p?.c ?? 0)
        voice = (p?.voice?.isEmpty == false ? p?.voice : nil) ?? book.defaultVoice ?? "Kiana (Comedian)"
        speed = p?.speed ?? 1.0
        prepareSession()
        wireRemote()
        if book.isAudio {
            loadTrack(s, at: p?.pos ?? 0, play: false)
        } else {
            Task { await refreshText() }
            prefetch()
        }
        updateNowPlaying()
    }

    func close() {
        pause()
        saveNow()
        unwireRemote()
        if let o = timeObserver { avPlayer?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil; endObserver = nil
        avPlayer = nil
        if engine.isRunning { engine.stop() }
        cache.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Back to the app's usual session shape (VoiceService.prepareOutputSession).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        book = nil
    }

    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    // MARK: transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let book else { return }
        prepareSession()
        if book.isAudio {
            avPlayer?.rate = Float(speed)
            avPlayer?.play()
            isPlaying = true
            updateNowPlaying()
            return
        }
        isPlaying = true
        playToken += 1
        let token = playToken
        if graphRate != 0 { node.stop() }
        scheduled.removeAll()
        updateNowPlaying()
        Task { await pump(token: token) }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        if isAudio {
            avPlayer?.pause()
        } else {
            playToken += 1
            if graphRate != 0 { node.stop() }
            scheduled.removeAll()
        }
        saveNow()
        updateNowPlaying()
    }

    func back() {
        guard let book else { return }
        if book.isAudio {
            seekFile(by: -15)
            announcement = "Back 15 seconds."
            return
        }
        if c > 0 { seek(s: s, c: c - 1) }
        else if s > 0 { seek(s: s - 1, c: max(0, (book.chapters[s - 1].chunks ?? 1) - 1)) }
        else { announcement = "This is the beginning." }
    }

    func forward() {
        guard let book else { return }
        if book.isAudio {
            seekFile(by: 15)
            announcement = "Forward 15 seconds."
            return
        }
        if let n = next(s: s, c: c) { seek(s: n.s, c: n.c) } else { announcement = "This is the end." }
    }

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
        if book.isAudio { loadTrack(b.s, at: b.pos ?? 0, play: isPlaying) } else { seek(s: b.s, c: b.c) }
        announcement = "Bookmark: " + positionSpoken
    }

    func restart() { goToPart(0); if !isAudio { seek(s: 0, c: 0) } }

    /// Current spot, for a bookmark.
    var here: (s: Int, c: Int, pos: Double) { (s, c, isAudio ? filePosition : 0) }

    func changeVoice(_ v: String) {
        voice = v
        cache.removeAll()
        let was = isPlaying
        if was { pause() }
        saveNow()
        if was { play() }
    }
    func changeSpeed(_ sp: Double) {
        speed = sp
        if isAudio { if isPlaying { avPlayer?.rate = Float(sp) } }
        else { cache.removeAll(); let was = isPlaying; if was { pause(); play() } }
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

    private func seek(s ns: Int, c nc: Int) {
        let was = isPlaying
        if was { playToken += 1; if graphRate != 0 { node.stop() }; scheduled.removeAll(); isPlaying = false }
        s = ns; c = nc
        Task { await refreshText() }
        scheduleSave()
        updateNowPlaying()
        if was { play() } else { prefetch() }
    }

    private func key(_ s: Int, _ c: Int) -> String { "\(s)/\(c)" }

    private func fetchBuffer(s: Int, c: Int) async throws -> AVAudioPCMBuffer? {
        guard let book else { return nil }
        let k = key(s, c)
        if let b = cache[k] { return b }
        if inflight.contains(k) {
            // wait for the other fetch
            for _ in 0 ..< 600 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let b = cache[k] { return b }
                if !inflight.contains(k) { break }
            }
        }
        inflight.insert(k)
        defer { inflight.remove(k) }
        let data = try await service.chunkAudio(bookId: book.id, s: s, c: c, voice: voice, speed: speed)
        guard !data.isEmpty, let buf = Self.decodeWav(data) else { return nil }
        cache[k] = buf
        if cache.count > 10 {
            let keep = Set(scheduled.map { key($0.s, $0.c) } + [k, key(s, c)])
            if let victim = cache.keys.first(where: { !keep.contains($0) }) { cache.removeValue(forKey: victim) }
        }
        return buf
    }

    private func prefetch() {
        guard book != nil, !isAudio else { return }
        var p: (s: Int, c: Int)? = (s, c)
        var n = 0
        while let q = p, n < 2 {
            let k = key(q.s, q.c)
            if cache[k] == nil, !inflight.contains(k) {
                let qs = q.s, qc = q.c
                Task { _ = try? await fetchBuffer(s: qs, c: qc) }
            }
            p = next(s: q.s, c: q.c)
            n += 1
        }
    }

    /// Keep the node fed: the chunk at the cursor, then the next, while
    /// fetching one more ahead. Completion callbacks advance the cursor.
    private func pump(token: Int) async {
        guard let book, !book.isAudio else { return }
        var cursor: (s: Int, c: Int)? = (s, c)
        var first = true
        while let q = cursor, token == playToken, isPlaying {
            let buf: AVAudioPCMBuffer?
            do { buf = try await fetchBuffer(s: q.s, c: q.c) } catch {
                announcement = "\(error.localizedDescription) Press Play to try again."
                isPlaying = false
                updateNowPlaying()
                return
            }
            guard token == playToken, isPlaying else { return }
            guard let buf else { cursor = next(s: q.s, c: q.c); continue } // unspeakable chunk: skip
            buildGraph(for: buf.format)
            if !engine.isRunning { try? engine.start() }
            let pos = q
            node.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.chunkFinished(pos, token: token) }
            }
            scheduled.append(pos)
            if first { node.play(); first = false }
            // fetch one further ahead while this one and the next are queued
            if let ahead = next(s: q.s, c: q.c), let ahead2 = next(s: ahead.s, c: ahead.c) {
                let a = ahead2
                Task { _ = try? await fetchBuffer(s: a.s, c: a.c) }
            }
            // wait until fewer than two are queued before scheduling more
            while scheduled.count >= 2, token == playToken, isPlaying {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            cursor = next(s: q.s, c: q.c)
            if cursor == nil {
                // nothing more to schedule; the last completion ends the book
                return
            }
        }
    }

    private func chunkFinished(_ pos: (s: Int, c: Int), token: Int) {
        guard token == playToken, isPlaying else { return }
        scheduled.removeAll(where: { $0.s == pos.s && $0.c == pos.c })
        if let n = next(s: pos.s, c: pos.c) {
            let changed = n.s != s
            s = n.s; c = n.c
            Task { await refreshText() }
            scheduleSave()
            updateNowPlaying()
            if changed { announcement = positionSpoken }
        } else {
            isPlaying = false
            announcement = "The end. \(book?.title ?? "") is finished."
            if let book { Task { await service.saveProgress(bookId: book.id, s: s, c: c, pos: 0, voice: voice, speed: speed, finished: true) } }
            updateNowPlaying()
        }
    }

    private func buildGraph(for format: AVAudioFormat) {
        if graphRate == format.sampleRate { return }
        if graphRate != 0 { engine.disconnectNodeOutput(node) } else { engine.attach(node) }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        graphRate = format.sampleRate
    }

    /// WAV bytes → one float PCM buffer. 16-bit mono is what the proxy sends;
    /// stereo and 8-bit are folded rather than refused.
    nonisolated static func decodeWav(_ data: Data) -> AVAudioPCMBuffer? {
        guard let (fmt, pcmStart) = StreamingWavParser.parseHeader(data), pcmStart < data.count else { return nil }
        let pcm = data.subdata(in: pcmStart ..< data.count)
        let channels = max(1, fmt.numChannels)
        let bytesPer = max(1, fmt.bitsPerSample / 8)
        let frames = pcm.count / (bytesPer * channels)
        guard frames > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        guard let out = buf.floatChannelData?[0] else { return nil }
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for f in 0 ..< frames {
                var sum: Float = 0
                for ch in 0 ..< channels {
                    let i = (f * channels + ch) * bytesPer
                    let v: Float
                    if bytesPer == 2 {
                        let lo = UInt16(p[i]), hi = UInt16(p[i + 1])
                        v = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
                    } else if bytesPer == 1 {
                        v = (Float(p[i]) - 128) / 128
                    } else {
                        let b0 = UInt32(p[i + bytesPer - 3]), b1 = UInt32(p[i + bytesPer - 2]), b2 = UInt32(p[i + bytesPer - 1])
                        var x = Int32(bitPattern: (b0 << 8) | (b1 << 16) | (b2 << 24))
                        x >>= 8
                        v = Float(x) / 8388608
                    }
                    sum += v
                }
                out[f] = sum / Float(channels)
            }
        }
        return buf
    }

    private func refreshText() async {
        guard let book, !book.isAudio else { return }
        let ss = s, cc = c
        if let t = try? await service.chunkText(bookId: book.id, s: ss, c: cc), ss == s, cc == c {
            nowText = t.text
        }
    }

    // MARK: file engine

    private func loadTrack(_ index: Int, at seconds: Double, play: Bool) {
        guard let book, book.tracks.indices.contains(index), let url = URL(string: book.tracks[index].url) else { return }
        s = index; c = 0
        if let o = timeObserver { avPlayer?.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        avPlayer = player
        fileDuration = book.tracks[index].seconds ?? 0
        filePosition = seconds
        nowText = book.tracks[index].title
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.filePosition = t.seconds.isFinite ? t.seconds : 0
                if let d = self.avPlayer?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.fileDuration = d }
                if Int(self.filePosition) % 10 == 0 { self.scheduleSave() }
                self.updateNowPlayingTime()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let book = self.book else { return }
                if self.s + 1 < book.tracks.count {
                    self.loadTrack(self.s + 1, at: 0, play: true)
                    self.announcement = self.positionSpoken
                } else {
                    self.isPlaying = false
                    self.announcement = "The end. \(book.title) is finished."
                    Task { await self.service.saveProgress(bookId: book.id, s: self.s, c: 0, pos: 0, voice: self.voice, speed: self.speed, finished: true) }
                    self.updateNowPlaying()
                }
            }
        }
        if seconds > 0 { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000)) }
        if play { self.play() }
        scheduleSave()
        updateNowPlaying()
    }

    private func seekFile(by delta: Double) {
        guard let p = avPlayer else { return }
        let target = max(0, min(fileDuration > 0 ? fileDuration - 0.5 : .greatestFiniteMagnitude, filePosition + delta))
        p.seek(to: CMTime(seconds: target, preferredTimescale: 1000))
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
    private func saveNow() { Task { await saveNowAsync() } }
    private func saveNowAsync() async {
        guard let book else { return }
        await service.saveProgress(bookId: book.id, s: s, c: c, pos: isAudio ? filePosition : 0, voice: voice, speed: speed)
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
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.back() }; return .success }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.forward() }; return .success }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previousPart() }; return .success }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.nextPart() }; return .success }
        center.stopCommand.isEnabled = false
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
