import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// THE LIBRARY on the phone — the archive browser, collections, video with
/// AirPlay, the library's eyes (descriptions, "what just happened?", ask),
/// and the librarian's note (Part 181 continued, Sep 11 2026).
///
/// Her words: "The library browser and player … should be accessible easy to
/// use, but shouldn't be annoying or a pita for sighted people either. You
/// should be able to make playlists … Be nice if you could cast or airplay.
/// … a button that will kinda pause the movie and explain the past however
/// many minutes visually, so if you had questions you could ask … a cheap
/// flash model being a librarian."
///
/// Everything here talks to the same `/api/kade/reading-room` routes the web
/// page uses, through `ReadingRoomService`. Video plays in the system
/// `VideoPlayer` (its controls are VoiceOver-labelled by Apple, and the
/// AirPlay route picker beside it is the real one from AVKit, so casting to
/// an Apple TV is one tap and needs no SDK).

// MARK: - Wire shapes

struct RRFolder: Codable, Identifiable, Hashable { let name: String; let count: Int; let path: String; var id: String { path } }
struct RRArchivePage: Codable { let path: String; let folders: [RRFolder]; let items: [RRItem]; let total: Int; let page: Int; let limit: Int }
struct RRSearch: Codable { let items: [RRItem] }
struct RRCollectionRow: Codable, Identifiable, Hashable { let id: String; let title: String; let description: String?; let shared: Bool; let ownerName: String?; let count: Int }
struct RRCollectionItem: Codable, Identifiable, Hashable { let n: Int; let book: RRItem; let track: Int; let title: String; let mime: String?; let seconds: Double?; var id: Int { n } }
struct RRCollectionDetail: Codable { let id: String; let title: String; let shared: Bool; let ownerName: String?; let mine: Bool; let items: [RRCollectionItem]; let description: String? }
struct RRScene: Codable, Hashable { let t: Double; let text: String }
struct RRDescription: Codable, Hashable { let state: String?; let summary: String?; let scenes: [RRScene]?; let costUSD: Double?; let error: String? }
struct RRRecap: Codable, Hashable { let from: Double; let to: Double; let summary: String?; let scenes: [RRScene]? }
struct RRSource: Codable, Hashable { let title: String?; let url: String? }
struct RRLibrarian: Codable, Hashable { let note: String?; let confidence: String?; let identified: String?; let sources: [RRSource]?; let state: String?; let error: String? }

extension ReadingRoomService {
    private struct Err: Decodable { let error: String? }
    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]? = nil, as type: T.Type, timeout: TimeInterval = 60) async throws -> T {
        let (data, http) = try await client.send(client.request(path: path, authorized: true, queryItems: items, timeout: timeout))
        guard http.statusCode == 200 else { throw RRError(message: (try? JSONDecoder().decode(Err.self, from: data))?.error ?? "The library answered \(http.statusCode).") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func postJSON<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type, method: String = "POST", timeout: TimeInterval = 120) async throws -> T {
        var req = client.request(path: path, method: method, authorized: true, timeout: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw RRError(message: (try? JSONDecoder().decode(Err.self, from: data))?.error ?? "The library answered \(http.statusCode).") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    struct OK: Decodable { let ok: Bool? }

    func archive(path: String, page: Int) async throws -> RRArchivePage {
        try await get("api/kade/reading-room/archive", [URLQueryItem(name: "path", value: path), URLQueryItem(name: "page", value: String(page))], as: RRArchivePage.self)
    }
    func search(_ q: String) async throws -> [RRItem] {
        try await get("api/kade/reading-room/search", [URLQueryItem(name: "q", value: q)], as: RRSearch.self).items
    }
    struct Colls: Decodable { let mine: [RRCollectionRow]; let shared: [RRCollectionRow] }
    func collections() async throws -> Colls { try await get("api/kade/reading-room/collections", as: Colls.self) }
    struct CollWrap: Decodable { let collection: RRCollectionRow }
    func newCollection(_ title: String) async throws -> RRCollectionRow { try await postJSON("api/kade/reading-room/collections", ["title": title], as: CollWrap.self).collection }
    func collection(_ id: String) async throws -> RRCollectionDetail { try await get("api/kade/reading-room/collections/\(id)", as: RRCollectionDetail.self) }
    func addToCollection(_ id: String, book: String, track: Int) async throws { _ = try await postJSON("api/kade/reading-room/collections/\(id)/items", ["book": book, "track": track], as: CollWrap.self) }
    func editCollection(_ id: String, shared: Bool? = nil, remove: Int? = nil) async throws {
        var b: [String: Any] = [:]
        if let shared { b["shared"] = shared }
        if let remove { b["remove"] = remove }
        _ = try await postJSON("api/kade/reading-room/collections/\(id)/edit", b, as: CollWrap.self)
    }
    func deleteCollection(_ id: String) async throws { _ = try await client.send(client.request(path: "api/kade/reading-room/collections/\(id)", method: "DELETE", authorized: true)) }

    struct Estimate: Decodable { let enabled: Bool?; let seconds: Double?; let usd: Double?; let hasSeconds: Bool?; let state: String? }
    func describeEstimate(book: String, t: Int) async throws -> Estimate { try await get("api/kade/reading-room/book/\(book)/describe/\(t)/estimate", as: Estimate.self) }
    struct DescState: Decodable { let state: String?; let progress: String?; let description: RRDescription? }
    func describeStart(book: String, t: Int, again: Bool) async throws -> DescState { try await postJSON("api/kade/reading-room/book/\(book)/describe/\(t)" + (again ? "?again=1" : ""), [:], as: DescState.self) }
    func describeStatus(book: String, t: Int) async throws -> DescState { try await get("api/kade/reading-room/book/\(book)/describe/\(t)", as: DescState.self) }
    struct RecapState: Decodable { let state: String?; let progress: String?; let recap: RRRecap?; let from: Double?; let to: Double? }
    func recapStart(book: String, t: Int, to: Double, minutes: Int) async throws -> RecapState { try await postJSON("api/kade/reading-room/book/\(book)/recap/\(t)", ["to": to, "minutes": minutes], as: RecapState.self) }
    func recapStatus(book: String, t: Int, from: Double, to: Double) async throws -> RecapState { try await get("api/kade/reading-room/book/\(book)/recap/\(t)", [URLQueryItem(name: "from", value: String(from)), URLQueryItem(name: "to", value: String(to))], as: RecapState.self) }
    struct Answer: Decodable { let answer: String? }
    func ask(book: String, t: Int, question: String, from: Double, to: Double) async throws -> String { try await postJSON("api/kade/reading-room/book/\(book)/ask/\(t)", ["question": question, "from": from, "to": to], as: Answer.self).answer ?? "" }
    struct LibWrap: Decodable { let librarian: RRLibrarian? }
    func librarianStart(book: String, again: Bool) async throws -> RRLibrarian? { try await postJSON("api/kade/reading-room/book/\(book)/librarian" + (again ? "?again=1" : ""), [:], as: LibWrap.self).librarian }
    func librarianStatus(book: String) async throws -> RRLibrarian? { try await get("api/kade/reading-room/book/\(book)/librarian", as: LibWrap.self).librarian }

    /// One line of speech from the platform's voice, as WAV bytes (the same
    /// `tts/manual` lane the app's read-aloud uses).
    func speech(_ text: String, voice: String?) async throws -> Data {
        var fields: [(String, String)] = [("input", text)]
        if let voice, !voice.isEmpty { fields.append(("voice", voice)) }
        let req = client.multipartRequest(path: "api/files/speech/tts/manual", authorized: true, fields: fields)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200, !data.isEmpty else { throw RRError(message: "The voice did not answer.") }
        return data
    }
}

// MARK: - AirPlay

struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.accessibilityLabel = "AirPlay"
        v.accessibilityHint = "Sends the picture and sound to an Apple TV or speaker."
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - The video pane with the library's eyes

struct VideoPane: View {
    @ObservedObject var player: ReadingRoomPlayer
    let service: ReadingRoomService
    let book: RRBook
    let announce: (String) -> Void
    @State private var desc: RRDescription?
    @State private var descStatus = ""
    @State private var recap: RRRecap?
    @State private var recapStatus = ""
    @State private var recapMinutes = 5
    @State private var question = ""
    @State private var answer = ""
    @State private var polling = false

    private var track: RRTrack? { book.tracks.indices.contains(player.s) ? book.tracks[player.s] : nil }
    private var isVideo: Bool { (track?.mime ?? "").hasPrefix("video/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isVideo, let av = player.avPlayer {
                VideoPlayer(player: av)
                    .frame(height: 220)
                    .cornerRadius(14)
                    .accessibilityLabel("The video")
                HStack {
                    AirPlayPicker().frame(width: 44, height: 44)
                    Text("AirPlay").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if isVideo {
                DisclosureGroup("Video description" + ((desc?.scenes?.count).map { " (\($0) scenes)" } ?? "")) {
                    Text("A described-video track written by the library's eyes: what is on screen, scene by scene. One run serves everyone.").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button(desc?.state == "done" ? "Describe it again" : (desc?.state == "working" ? "Working…" : "Describe this video")) { Task { await startDescribe() } }
                            .disabled(desc?.state == "working")
                        if desc?.state == "done" {
                            Button("Read it") { Task { await readDescription() } }
                        }
                    }
                    if desc?.state == "done" {
                        Toggle("Play with descriptions (pauses to describe each scene)", isOn: $player.describedMode)
                    }
                    if !descStatus.isEmpty { Text(descStatus).font(.footnote).foregroundStyle(.secondary) }
                    if let s = desc?.summary, !s.isEmpty { Text(s) }
                    ForEach(Array((desc?.scenes ?? []).enumerated()), id: \.offset) { i, sc in
                        Button {
                            player.seekFile(to: sc.t); player.play()
                        } label: {
                            Text("\(ReadingRoomPlayer.clock(sc.t)) — \(sc.text)").font(.subheadline).multilineTextAlignment(.leading)
                        }
                        .accessibilityHint("Plays from there.")
                    }
                }
                DisclosureGroup("What just happened?") {
                    Text("Pauses the video and describes the last few minutes visually, so you can ask about it.").font(.footnote).foregroundStyle(.secondary)
                    Picker("Last", selection: $recapMinutes) { Text("2 minutes").tag(2); Text("5 minutes").tag(5); Text("10 minutes").tag(10); Text("20 minutes").tag(20) }
                    Button("Tell me what just happened") { Task { await startRecap() } }
                    if !recapStatus.isEmpty { Text(recapStatus).font(.footnote).foregroundStyle(.secondary) }
                    if let r = recap {
                        if let s = r.summary { Text(s) }
                        ForEach(Array((r.scenes ?? []).enumerated()), id: \.offset) { _, sc in Text("\(ReadingRoomPlayer.clock(sc.t)) — \(sc.text)").font(.subheadline) }
                    }
                    HStack {
                        TextField("Ask about it", text: $question).textFieldStyle(.roundedBorder).onSubmit { Task { await askQuestion() } }
                        Button("Ask") { Task { await askQuestion() } }
                    }
                    if !answer.isEmpty { Text(answer) }
                }
            }
        }
        .onAppear { desc = track?.description; recap = track?.recaps?.last }
        .onChange(of: player.s) { _, _ in desc = track?.description; recap = track?.recaps?.last; player.scenes = desc?.scenes ?? [] }
        .onChange(of: desc) { _, d in player.scenes = d?.scenes ?? [] }
    }

    private func startDescribe() async {
        do {
            let est = try await service.describeEstimate(book: book.id, t: player.s)
            if est.enabled == false { announce("Video descriptions are switched off on this server."); return }
            let mins = Int(((est.seconds ?? 0) / 60).rounded())
            descStatus = "Describing" + (est.hasSeconds == true ? " about \(max(mins, 1)) minute\(mins == 1 ? "" : "s")" : "") + ", roughly \(String(format: "$%.3f", est.usd ?? 0)). A few minutes…"
            let r = try await service.describeStart(book: book.id, t: player.s, again: desc?.state == "done")
            if r.state == "done", let d = r.description { desc = d; announce("Already described.") ; return }
            desc = RRDescription(state: "working", summary: nil, scenes: nil, costUSD: nil, error: nil)
            announce("Describing. I will say when it is ready.")
            await pollDescribe()
        } catch { announce(error.localizedDescription) }
    }
    private func pollDescribe() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        for _ in 0 ..< 200 {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let st = try? await service.describeStatus(book: book.id, t: player.s) else { continue }
            if st.state == "working" { descStatus = "Describing… " + (st.progress ?? ""); continue }
            desc = st.description
            descStatus = st.state == "failed" ? "The last try failed: \(st.description?.error ?? "")" : ""
            announce(st.state == "done" ? "The description is ready: \(st.description?.scenes?.count ?? 0) scenes." : "The description failed.")
            return
        }
    }
    private func readDescription() async {
        guard let d = desc, d.state == "done" else { return }
        player.pause()
        await player.speak(d.summary ?? "")
        for sc in d.scenes ?? [] { if player.isPlaying { break }; await player.speak("At \(ReadingRoomPlayer.clock(sc.t)). \(sc.text)") }
    }
    private func startRecap() async {
        let to = player.filePosition
        if to < 20 { announce("Play a little first — there is nothing to recap yet."); return }
        player.pause()
        recapStatus = "Looking back over the last \(recapMinutes) minutes…"
        announce("Looking back over the last \(recapMinutes) minutes. This takes a minute or two.")
        do {
            let r = try await service.recapStart(book: book.id, t: player.s, to: to, minutes: recapMinutes)
            if r.state == "done", let rc = r.recap { recap = rc; recapStatus = ""; await player.speak(rc.summary ?? ""); return }
            let from = r.from ?? max(0, to - Double(recapMinutes * 60))
            for _ in 0 ..< 60 {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let st = try? await service.recapStatus(book: book.id, t: player.s, from: from, to: to) else { continue }
                if st.state == "done", let rc = st.recap {
                    recap = rc; recapStatus = ""
                    announce("Here is what happened.")
                    await player.speak((rc.summary ?? "") + " " + (rc.scenes ?? []).map { $0.text }.joined(separator: " "))
                    return
                }
                recapStatus = "Working… " + (st.progress ?? "")
            }
        } catch { recapStatus = error.localizedDescription; announce(error.localizedDescription) }
    }
    private func askQuestion() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        answer = "Thinking…"
        do {
            let a = try await service.ask(book: book.id, t: player.s, question: q, from: recap?.from ?? 0, to: recap?.to ?? player.filePosition)
            answer = a; announce(a); await player.speak(a)
        } catch { answer = error.localizedDescription; announce(error.localizedDescription) }
    }
}

// MARK: - The librarian's note

struct LibrarianPane: View {
    let service: ReadingRoomService
    let bookId: String
    let announce: (String) -> Void
    let speak: (String) async -> Void
    @State var note: RRLibrarian?
    @State private var status = ""

    var body: some View {
        DisclosureGroup("The librarian's note" + ((note?.identified).flatMap { $0.isEmpty ? nil : ": \($0)" } ?? "")) {
            Text("A short note the library's librarian digs up on the web about what this is, who made it and when. Honest about guesses.").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button(note?.state == "done" ? "Look it up again" : (note?.state == "working" ? "Looking…" : "Ask the librarian to look this up")) { Task { await lookUp() } }.disabled(note?.state == "working")
                if note?.state == "done", let n = note?.note { Button("Read the note") { Task { await speak(n) } } }
            }
            if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            if note?.state == "done" {
                if let c = note?.confidence { Text("Confidence: \(c).").font(.footnote).foregroundStyle(.secondary) }
                Text(note?.note ?? "")
                ForEach(Array((note?.sources ?? []).enumerated()), id: \.offset) { _, s in
                    if let u = s.url, let url = URL(string: u) { Link(s.title ?? u, destination: url).font(.footnote) }
                }
            }
        }
        .onAppear { if note?.state == "working" { Task { await poll() } } }
    }
    private func lookUp() async {
        do {
            let r = try await service.librarianStart(book: bookId, again: note?.state == "done")
            note = r
            if r?.state != "done" { announce("The librarian is looking it up."); await poll() } else { announce("The librarian has a note.") }
        } catch { announce(error.localizedDescription) }
    }
    private func poll() async {
        for _ in 0 ..< 30 {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let r = try? await service.librarianStatus(book: bookId) else { continue }
            note = r
            if r?.state == "done" { announce("The librarian has a note."); return }
            if r?.state == "failed" { status = "The last try failed: \(r?.error ?? "")"; return }
        }
    }
}

// MARK: - Archive browser, search, collections (shelf sections)

struct ArchiveSection: View {
    let service: ReadingRoomService
    let open: (RRItem) -> Void
    @State private var page: RRArchivePage?
    @State private var path = ""
    @State private var pageNo = 0
    @State private var status = ""
    @State private var query = ""
    @State private var results: [RRItem] = []

    var body: some View {
        Section {
            HStack {
                TextField("A title, a channel, a brand, a year…", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await doSearch() } }
                Button("Search") { Task { await doSearch() } }
            }
            ForEach(results) { item in itemRow(item) }
        } header: { Text("Find something") }

        Section {
            Text("The family's television, commercials, tapes and radio, browsed the way the collection is filed.").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button("Archive") { Task { await load("", 0) } }.font(.subheadline)
                ForEach(Array(path.split(separator: "/").enumerated()), id: \.offset) { i, seg in
                    Text("›").accessibilityHidden(true)
                    Button(String(seg)) { Task { await load(path.split(separator: "/").prefix(i + 1).joined(separator: "/"), 0) } }.font(.subheadline)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Where you are: " + (path.isEmpty ? "the archive" : path.replacingOccurrences(of: "/", with: ", ")))
            if let p = page {
                if p.folders.isEmpty && p.items.isEmpty {
                    Text(path.isEmpty ? "Nothing has been pushed to the archive yet. On the PC, run \"9 - PUSH TO LIBRARY\" in the collection folder." : "This folder is empty.").foregroundStyle(.secondary)
                }
                ForEach(p.folders) { f in
                    Button { Task { await load(f.path, 0) } } label: {
                        HStack { Image(systemName: "folder").foregroundStyle(.brown).accessibilityHidden(true); Text(f.name); Spacer(); Text("\(f.count)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .accessibilityLabel("Folder \(f.name), \(f.count) item\(f.count == 1 ? "" : "s")")
                    .accessibilityHint("Opens the folder.")
                }
                ForEach(p.items) { item in itemRow(item) }
                if p.total > p.limit {
                    HStack {
                        Button("Previous page") { Task { await load(path, max(0, pageNo - 1)) } }.disabled(pageNo == 0)
                        Spacer()
                        Text("Page \(pageNo + 1) of \(Int(ceil(Double(p.total) / Double(p.limit))))").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Next page") { Task { await load(path, pageNo + 1) } }.disabled((pageNo + 1) * p.limit >= p.total)
                    }
                }
            } else { Text(status.isEmpty ? "Loading…" : status).foregroundStyle(.secondary) }
        } header: { Text("The archive") }
        .task { if page == nil { await load("", 0) } }
    }

    private func itemRow(_ item: RRItem) -> some View {
        Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(detail(item)).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(item.spokenRow(where: "archive") + (item.described == true ? ", described" : ""))
        .accessibilityHint("Opens it.")
    }
    private func detail(_ item: RRItem) -> String {
        var bits: [String] = [item.categoryName]
        if let a = item.author, !a.isEmpty { bits.append(a) }
        if let y = item.copyrightYear, !y.isEmpty { bits.append(y) }
        if let l = item.listen, !l.isEmpty { bits.append(l) }
        if item.described == true { bits.append("described") }
        return bits.joined(separator: " · ")
    }
    private func load(_ p: String, _ n: Int) async {
        do { let pg = try await service.archive(path: p, page: n); page = pg; path = pg.path; pageNo = pg.page
            UIAccessibility.post(notification: .announcement, argument: (pg.path.isEmpty ? "The archive" : pg.path.components(separatedBy: "/").last ?? pg.path) + ": \(pg.folders.count) folder\(pg.folders.count == 1 ? "" : "s"), \(pg.total) clip\(pg.total == 1 ? "" : "s").")
        } catch { status = error.localizedDescription }
    }
    private func doSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        do { results = try await service.search(q); UIAccessibility.post(notification: .announcement, argument: "\(results.count) result\(results.count == 1 ? "" : "s") for \(q).") } catch { status = error.localizedDescription }
    }
}

struct CollectionsSection: View {
    let service: ReadingRoomService
    let openCollection: (RRCollectionRow) -> Void
    @State private var mine: [RRCollectionRow] = []
    @State private var shared: [RRCollectionRow] = []
    @State private var newTitle = ""
    @State private var status = ""

    var body: some View {
        Section {
            Text("Playlists you put together from anything in the library — yours until you share them.").font(.footnote).foregroundStyle(.secondary)
            if mine.isEmpty && shared.isEmpty { Text("No collections yet. Name one below, then use \"Add to a collection\" on anything you play.").foregroundStyle(.secondary) }
            ForEach(mine) { c in row(c, mine: true) }
            ForEach(shared) { c in row(c, mine: false) }
            HStack {
                TextField("New collection name", text: $newTitle).textFieldStyle(.roundedBorder)
                Button("Make it") { Task { await make() } }.disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Collections") }
        .task { await reload() }
    }
    private func row(_ c: RRCollectionRow, mine: Bool) -> some View {
        Button { openCollection(c) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.headline)
                Text("\(c.count) item\(c.count == 1 ? "" : "s")" + (mine ? (c.shared ? " · shared" : " · private") : " · by \(c.ownerName ?? "someone")")).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHint("Opens the collection.")
    }
    func reload() async {
        do { let c = try await service.collections(); mine = c.mine; shared = c.shared } catch { status = error.localizedDescription }
    }
    private func make() async {
        do { _ = try await service.newCollection(newTitle.trimmingCharacters(in: .whitespaces)); UIAccessibility.post(notification: .announcement, argument: "Made \(newTitle)."); newTitle = ""; await reload() } catch { status = error.localizedDescription }
    }
}

struct CollectionScreen: View {
    let service: ReadingRoomService
    let row: RRCollectionRow
    let play: (RRCollectionItem, [RRCollectionItem]) -> Void
    let back: () -> Void
    @State private var detail: RRCollectionDetail?
    @State private var status = ""

    var body: some View {
        List {
            Section {
                Button { back() } label: { Label("Back to the shelf", systemImage: "chevron.left") }
            }
            if let d = detail {
                Section {
                    Text("\(d.items.count) item\(d.items.count == 1 ? "" : "s")" + (d.mine ? (d.shared ? " · shared with the family" : " · private") : " · by \(d.ownerName ?? "someone")")).foregroundStyle(.secondary)
                    if let desc = d.description, !desc.isEmpty { Text(desc) }
                    Button("Play all, in order") { if let first = d.items.first { play(first, Array(d.items.dropFirst())) } }.disabled(d.items.isEmpty)
                    if d.mine {
                        Button(d.shared ? "Make it private" : "Share it with the family") { Task { try? await service.editCollection(row.id, shared: !d.shared); await load() } }
                        Button("Delete this collection", role: .destructive) { Task { try? await service.deleteCollection(row.id); back() } }
                    }
                }
                Section("Items") {
                    ForEach(Array(d.items.enumerated()), id: \.offset) { i, it in
                        HStack {
                            Button { play(it, Array(d.items.dropFirst(i + 1))) } label: {
                                VStack(alignment: .leading) {
                                    Text("\(i + 1). \(it.title)").font(.headline)
                                    Text([it.book.author, RRCategory.name(it.book.kind == "text" ? "book" : it.book.category, isAudio: it.book.kind != "text"), it.seconds.map { ReadingRoomPlayer.clock($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityHint("Plays it, then the rest of the collection.")
                            if d.mine {
                                Spacer()
                                Button("Remove") { Task { try? await service.editCollection(row.id, remove: it.n); await load() } }.foregroundStyle(.red).accessibilityLabel("Remove \(it.title)")
                            }
                        }
                    }
                }
            } else { Text(status.isEmpty ? "Loading…" : status).foregroundStyle(.secondary) }
        }
        .navigationTitle(row.title)
        .task { await load() }
    }
    private func load() async { do { detail = try await service.collection(row.id) } catch { status = error.localizedDescription } }
}
