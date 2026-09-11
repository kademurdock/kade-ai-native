import SwiftUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation

/// THE READING ROOM — the screens (Part 181, Sep 11 2026). See
/// ReadingRoomService.swift for what the room is and why it is shaped so.
///
/// Two screens on one NavigationStack push: the SHELF (yours, checked out,
/// the library by category, and the two donate flows) and the PLAYER. A book
/// shared into the app from the iPhone share sheet arrives as `incomingFile`
/// and goes straight into the donate flow — that is the whole "share a book
/// from my phone and read it on my phone" path.
///
/// VoiceOver shape (her rules): rows are Buttons with one spoken label; the
/// player's transport is six big buttons in reading order; ONE announcement
/// channel (the player's `announcement`) says chapter changes, bookmarks and
/// errors and never the text being read; nothing auto-plays.
struct ReadingRoomView: View {
    @StateObject private var service: ReadingRoomService
    @StateObject private var player: ReadingRoomPlayer
    /// A file the share sheet handed over (book or recording).
    let incomingFile: URL?
    let incomingName: String?

    @State private var openBook: RRBook?
    @State private var openCollectionRow: RRCollectionRow?
    @State private var incomingLink: String?
    @State private var autoplayNext = false
    @State private var showCollectionPicker = false
    @State private var myCollections: [RRCollectionRow] = []
    @State private var opening = false
    @State private var status: String?
    @State private var category = ""
    @State private var showBookPicker = false
    @State private var showTrackPicker = false
    @State private var showDonateSheet = false
    @State private var donateFile: URL?
    @State private var donateName: String = ""
    @State private var uploadingItem: RRItem?
    @State private var uploadProgress: Double?
    @State private var grownUpsForBook = false
    @AccessibilityFocusState private var focus: Focus?
    private enum Focus: Hashable { case status, play, shelf }

    init(apiClient: KadeAPIClient, incomingFile: URL? = nil, incomingName: String? = nil) {
        let svc = ReadingRoomService(client: apiClient)
        _service = StateObject(wrappedValue: svc)
        _player = StateObject(wrappedValue: ReadingRoomPlayer(service: svc))
        self.incomingFile = incomingFile
        self.incomingName = incomingName
    }

    var body: some View {
        Group {
            if let book = openBook {
                playerScreen(book)
            } else if let row = openCollectionRow {
                CollectionScreen(service: service, row: row, play: { item, rest in
                    player.queue = rest.map { $0.book.id }
                    autoplayNext = true
                    Task { await open(item.book, track: item.track) }
                }, back: { openCollectionRow = nil })
            } else {
                shelfScreen
            }
        }
        .onAppear {
            player.onQueueNext = { id in
                Task { @MainActor in
                    autoplayNext = true
                    if let b = try? await service.openBook(id) { player.open(b); openBook = b; player.play() }
                }
            }
        }
        .navigationTitle(openBook == nil ? (openCollectionRow?.title ?? "The Library") : (openBook?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.loadShelf()
            if let f = incomingFile { routeIncoming(f) }
        }
        .onDisappear { player.close() }
        .onChange(of: player.announcement) { _, msg in
            if let msg { announce(msg); player.announcement = nil }
        }
        .fileImporter(isPresented: $showBookPicker, allowedContentTypes: bookTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first { Task { await uploadBook(u) } }
        }
        .fileImporter(isPresented: $showTrackPicker, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await uploadTracks(urls) } }
        }
        .sheet(isPresented: $showDonateSheet) {
            DonateRecordingSheet(fileName: donateName) { title, author, year, cat, desc, grownUps in
                Task { await startRecording(title: title, author: author, year: year, category: cat, description: desc, grownUpsOnly: grownUps) }
            }
        }
    }

    private var bookTypes: [UTType] {
        var t: [UTType] = [.zip, .plainText, .html, .xml]
        if let epub = UTType(filenameExtension: "epub") { t.append(epub) }
        if let docx = UTType(filenameExtension: "docx") { t.append(docx) }
        return t
    }

    // MARK: - Shelf

    private var shelfScreen: some View {
        List {
            if let status {
                Section {
                    Text(status).foregroundStyle(.secondary).accessibilityFocused($focus, equals: .status)
                }
            }
            if let p = uploadProgress, let item = uploadingItem {
                Section("Uploading to \(item.title)") {
                    ProgressView(value: p).accessibilityLabel("Uploading, \(Int(p * 100)) percent")
                }
            }
            Section {
                Button { showBookPicker = true } label: {
                    Label("Donate a book", systemImage: "book.closed")
                }
                .accessibilityHint("Pick Bookshare's DAISY zip, an EPUB, a text file or a Word file from Files. It lands on your shelf; the Bookshare notice is skipped and the book opens with its jacket.")
                Toggle("Grown-ups only for the next book", isOn: $grownUpsForBook)
                Button { donateFile = nil; donateName = ""; showDonateSheet = true } label: {
                    Label("Donate a recording", systemImage: "waveform")
                }
                .accessibilityHint("An audiobook, described-movie audio, a cassette side, old radio or commercials. Name it, then add one or more audio files; big files go straight to storage.")
            } header: { Text("Donate") }

            ArchiveSection(service: service, open: { item in Task { await open(item) } })
            CollectionsSection(service: service, openCollection: { row in openCollectionRow = row })
            SubmissionsSection(service: service, announce: { announce($0) }, incomingLink: incomingLink, open: { id in Task { if let b = try? await service.openBook(id) { player.open(b); openBook = b } } })

            shelfSection("Your shelf", items: service.shelf?.mine ?? [], place: "mine", empty: "Nothing on your shelf yet. Donate a book or a recording above, or share a file from another app to Kade-AI.")
            shelfSection("Checked out", items: service.shelf?.borrowed ?? [], place: "borrowed", empty: "Nothing checked out yet.")

            Section {
                let lib = service.shelf?.library ?? []
                let cats = Array(Set(lib.map { $0.isAudio ? $0.category : "book" })).sorted()
                if cats.count > 1 {
                    Picker("Show", selection: $category) {
                        Text("Everything").tag("")
                        ForEach(cats, id: \.self) { Text(RRCategory.name($0, isAudio: $0 != "book")).tag($0) }
                    }
                }
                let shown = lib.filter { category.isEmpty || ($0.isAudio ? $0.category : "book") == category }
                if shown.isEmpty {
                    Text(lib.isEmpty ? "The library is empty. Put something from your shelf in it and everyone can check it out." : "Nothing on that shelf.").foregroundStyle(.secondary)
                }
                ForEach(shown) { item in row(item, place: "library") }
            } header: { Text("The library") }
        }
        .refreshable { await service.loadShelf() }
        .overlay { if service.isLoading && service.shelf == nil { ProgressView("Loading the shelf…") } }
    }

    @ViewBuilder
    private func shelfSection(_ title: String, items: [RRItem], place: String, empty: String) -> some View {
        Section {
            if items.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(items) { item in row(item, place: place) }
        } header: { Text(title) }
    }

    private func row(_ item: RRItem, place: String) -> some View {
        Button {
            Task { await open(item) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(rowDetail(item, place: place)).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(item.spokenRow(where: place))
        .accessibilityHint(place == "library" ? "Checks it out and opens it." : (item.state == "pending" ? "Opens it; add recordings from its page." : "Opens it where you left off."))
        .contextMenu {
            if place == "mine", item.isAudio {
                Button("Add recordings") { uploadingItem = item; showTrackPicker = true }
            }
        }
        .accessibilityAction(named: place == "mine" && item.isAudio ? "Add recordings" : "Open") {
            if place == "mine", item.isAudio { uploadingItem = item; showTrackPicker = true } else { Task { await open(item) } }
        }
    }

    private func rowDetail(_ item: RRItem, place: String) -> String {
        var bits: [String] = []
        if let a = item.author, !a.isEmpty { bits.append("by \(a)") }
        bits.append(item.categoryName)
        if let l = item.listen, !l.isEmpty { bits.append(l) }
        if let p = item.progress, let w = p.where_, !w.isEmpty { bits.append((item.isAudio ? "part " : "chapter ") + w) }
        if place != "mine", let d = item.ownerName, !d.isEmpty { bits.append("donated by \(d)") }
        if item.state == "pending" { bits.append("no recordings yet") }
        if place == "mine", item.shared { bits.append("in the library") }
        return bits.joined(separator: " · ")
    }

    private func open(_ item: RRItem, track: Int? = nil) async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do {
            var book = try await service.openBook(item.id)
            if let track { book.progress = RRProgress(s: track, c: 0, pos: 0, voice: book.progress?.voice, speed: book.progress?.speed, finished: false, where_: nil) }
            player.open(book)
            openBook = book
            openCollectionRow = nil
            if autoplayNext { autoplayNext = false; player.play() }
            let resume = (book.progress?.s ?? 0) > 0 || (book.progress?.c ?? 0) > 0 || (book.progress?.pos ?? 0) > 5
            announce((resume ? "Resuming " : "Opened ") + book.title + ". " + player.positionSpoken + ". Press Play.")
            focus = .play
        } catch {
            announce(error.localizedDescription)
        }
    }

    // MARK: - Donations

    private func routeIncoming(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if url.lastPathComponent == "link.txt", let text = try? String(contentsOf: url, encoding: .utf8) {
            incomingLink = text.trimmingCharacters(in: .whitespacesAndNewlines)
            announce("Paste is ready: submit \(incomingLink ?? "the link") for the library below.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        let audio = ["mp3", "m4a", "m4b", "aac", "wav", "ogg", "oga", "opus", "flac", "aiff", "aif", "mp4"]
        if audio.contains(ext) {
            donateFile = url
            donateName = incomingName ?? url.lastPathComponent
            showDonateSheet = true
        } else {
            Task { await uploadBook(url) }
        }
    }

    private func uploadBook(_ url: URL) async {
        announce("Reading \(url.lastPathComponent)… a few seconds.")
        do {
            let r = try await service.uploadBook(fileURL: url, grownUpsOnly: grownUpsForBook)
            let skipped = r.skipped?.count ?? 0
            announce("Added \(r.book.title)\(r.book.author.map { " by \($0)" } ?? ""). \(r.book.sections ?? 0) sections, about \(r.book.listen ?? "") of listening." + (skipped > 0 ? " \(skipped) front-matter parts skipped." : ""))
            await service.loadShelf()
            try? FileManager.default.removeItem(at: url)
        } catch {
            announce(error.localizedDescription)
        }
    }

    private func startRecording(title: String, author: String, year: String, category: String, description: String, grownUpsOnly: Bool) async {
        do {
            let item = try await service.newRecording(title: title, author: author, year: year, category: category, description: description, grownUpsOnly: grownUpsOnly)
            uploadingItem = item
            await service.loadShelf()
            if let f = donateFile {
                await uploadTracks([f])
            } else {
                announce("Started \(item.title). Now pick the audio files.")
                showTrackPicker = true
            }
        } catch {
            announce(error.localizedDescription)
        }
    }

    private func uploadTracks(_ urls: [URL]) async {
        guard var item = uploadingItem else { return }
        for (i, u) in urls.enumerated() {
            announce("Uploading \(u.lastPathComponent) (\(i + 1) of \(urls.count))…")
            uploadProgress = 0
            do {
                item = try await service.uploadTrack(item: item, fileURL: u, title: urls.count == 1 && (item.tracks ?? 0) == 0 ? "" : u.deletingPathExtension().lastPathComponent) { p in
                    uploadProgress = p
                }
                uploadingItem = item
                announce("Part \(item.tracks ?? 0) added to \(item.title).")
                if u.path.contains("/SharedInbox/") { try? FileManager.default.removeItem(at: u) }
            } catch {
                announce("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        uploadProgress = nil
        await service.loadShelf()
        announce("\(item.title) has \(item.tracks ?? 0) recording\((item.tracks ?? 0) == 1 ? "" : "s"). Open it from your shelf to play it or put it in the library.")
    }

    // MARK: - Player

    private func playerScreen(_ book: RRBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button { closeBook() } label: { Label("Back to the shelf", systemImage: "chevron.left") }
                    .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.title2.bold())
                    Text(bookMeta(book)).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                transport
                    .padding(.top, 4)

                if book.isAudio {
                    VideoPane(player: player, service: service, book: book, announce: { announce($0) })
                }
                HStack {
                    Button { Task { await pickCollection() } } label: { Label("Add to a collection", systemImage: "text.badge.plus") }
                        .buttonStyle(.bordered)
                }
                .confirmationDialog("Add \(book.title) to which collection?", isPresented: $showCollectionPicker, titleVisibility: .visible) {
                    ForEach(myCollections) { c in Button(c.title) { Task { await addTo(c, book: book) } } }
                    Button("Cancel", role: .cancel) {}
                }
                LibrarianPane(service: service, bookId: book.id, announce: { announce($0) }, speak: { text in await player.speak(text) }, note: book.librarian)

                Text(player.nowText.isEmpty ? (book.isAudio ? player.partTitle : "Press Play.") : player.nowText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Now: " + (player.nowText.isEmpty ? player.partTitle : player.nowText))

                if book.isAudio {
                    Text("\(ReadingRoomPlayer.clock(player.filePosition)) of \(ReadingRoomPlayer.clock(player.fileDuration))")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }

                chapterPicker(book)

                if !book.isAudio { voiceAndSpeed }
                else {
                    Picker("Speed", selection: Binding(get: { player.speed }, set: { player.changeSpeed($0) })) {
                        ForEach(speeds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }

                bookmarksBlock(book)
                if !book.isAudio, !book.skipped.isEmpty { skippedBlock(book) }
                ownerBlock(book)
            }
            .padding()
        }
    }

    private var speeds: [(Double, String)] { [(0.8, "Slower"), (0.9, "A little slower"), (1.0, "Normal"), (1.15, "A little faster"), (1.3, "Faster"), (1.5, "Fastest")] }

    private var transport: some View {
        VStack(spacing: 10) {
            Button { player.togglePlay() } label: {
                Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityFocused($focus, equals: .play)
            .accessibilityHint(player.isAudio ? "" : "Reads from where you are. Each piece is spoken fresh by the voice you picked.")
            HStack(spacing: 10) {
                bigButton("Back", icon: "gobackward.15", hint: player.isAudio ? "Back fifteen seconds." : "Back one piece, about half a minute.") { player.back() }
                bigButton("Forward", icon: "goforward.15", hint: player.isAudio ? "Forward fifteen seconds." : "Forward one piece.") { player.forward() }
                bigButton("Bookmark", icon: "bookmark.fill", hint: "Marks this spot so you can come back to it.") { Task { await addBookmark() } }
            }
            HStack(spacing: 10) {
                bigButton(player.isAudio ? "Previous part" : "Previous chapter", icon: "backward.end.fill", hint: "") { player.previousPart() }
                bigButton(player.isAudio ? "Next part" : "Next chapter", icon: "forward.end.fill", hint: "") { player.nextPart() }
            }
        }
    }

    private func bigButton(_ title: String, icon: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.footnote.bold()).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    private func chapterPicker(_ book: RRBook) -> some View {
        let count = book.partCount
        return Picker(book.isAudio ? "Part" : "Chapter", selection: Binding(get: { player.s }, set: { player.goToPart($0) })) {
            ForEach(0 ..< max(count, 1), id: \.self) { i in
                Text("\(i + 1). \(book.partTitle(i))").tag(i)
            }
        }
        .accessibilityHint("Jumps to that \(book.isAudio ? "part" : "chapter").")
    }

    @State private var voiceGroups: [ReadingRoomService.VoiceGroup] = []
    private var voiceAndSpeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Voice", selection: Binding(get: { player.voice }, set: { player.changeVoice($0) })) {
                if !voiceGroups.contains(where: { $0.voices.contains(player.voice) }) { Text(player.voice).tag(player.voice) }
                ForEach(voiceGroups) { g in
                    Section(g.name) { ForEach(g.voices, id: \.self) { Text($0).tag($0) } }
                }
            }
            .task { if voiceGroups.isEmpty { voiceGroups = await service.loadVoices() } }
            Picker("Speed", selection: Binding(get: { player.speed }, set: { player.changeSpeed($0) })) {
                ForEach(speeds, id: \.0) { Text($0.1).tag($0.0) }
            }
        }
    }

    private func bookmarksBlock(_ book: RRBook) -> some View {
        DisclosureGroup("Bookmarks (\(book.bookmarks.count))") {
            if book.bookmarks.isEmpty { Text("None yet. Press Bookmark while listening.").foregroundStyle(.secondary) }
            ForEach(book.bookmarks) { b in
                let label = (book.isAudio ? "Part " : "Chapter ") + "\(b.s + 1)" + ((b.sectionTitle?.isEmpty == false) ? ", \(b.sectionTitle!)" : "") + (book.isAudio ? ", " + ReadingRoomPlayer.clock(b.pos ?? 0) : "") + ((b.snippet?.isEmpty == false) ? " — “\(b.snippet!)”" : "")
                HStack {
                    Button(label) { player.goToBookmark(b) }.accessibilityHint("Goes there.")
                    Spacer()
                    Button("Remove") { Task { await removeBookmark(b) } }.foregroundStyle(.red).accessibilityLabel("Remove bookmark, \(label)")
                }
            }
        }
    }

    private func skippedBlock(_ book: RRBook) -> some View {
        DisclosureGroup("Skipped parts (\(book.skipped.count))") {
            Text("Front matter the room skips on its own: the Bookshare notice, the copyright page, the contents list, publisher sign-up pages. Play any of them here.").font(.footnote).foregroundStyle(.secondary)
            ForEach(book.skipped) { sk in
                Button("\(sk.title) (\(sk.why))") { Task { await playSkipped(sk, of: book) } }
                    .accessibilityHint("Reads it aloud.")
            }
        }
    }

    private func ownerBlock(_ book: RRBook) -> some View {
        DisclosureGroup(book.mine ? "This is your donation" : "Checked out") {
            if book.mine {
                Button(book.shared ? "Take it out of the library" : "Put it in the library for everyone") { Task { await toggleShared() } }
                Button(book.grownUpsOnly ? "Grown-ups only is on — allow the kids" : "Grown-ups only is off — hide it from the kids") { Task { await toggleGrownUps() } }
                if book.isAudio {
                    Button("Add recordings") { uploadingItem = RRItem(id: book.id, kind: "audio", category: book.category, description: nil, tracks: book.tracks.count, seconds: nil, state: nil, title: book.title, author: book.author, publisher: nil, copyrightYear: nil, synopsis: nil, source: nil, ownerName: book.ownerName, owner: nil, shared: book.shared, grownUpsOnly: book.grownUpsOnly, sections: nil, chunks: nil, listen: book.listen, skippedCount: nil, progress: nil); showTrackPicker = true }
                }
                Button("Submit this for the library") { Task { await submitItem(book) } }
                    .accessibilityHint("Asks the librarian to add it to the family library.")
                Button("Withdraw it from the Library", role: .destructive) { Task { await withdraw() } }
                    .accessibilityHint("Removes it for everyone. Cannot be undone.")
            } else {
                Button("Return it to the library") { Task { await returnIt() } }
                    .accessibilityHint("Takes it off your shelf and forgets your place.")
            }
        }
    }

    private func bookMeta(_ book: RRBook) -> String {
        var bits: [String] = []
        if let a = book.author, !a.isEmpty { bits.append("by \(a)") }
        bits.append(RRCategory.name(book.category, isAudio: book.isAudio))
        if let l = book.listen, !l.isEmpty { bits.append(l) }
        if !book.mine, let d = book.ownerName, !d.isEmpty { bits.append("donated by \(d)") }
        return bits.joined(separator: " · ")
    }

    // MARK: - actions

    private func pickCollection() async {
        do {
            let c = try await service.collections()
            myCollections = c.mine
            if myCollections.isEmpty {
                let made = try await service.newCollection("My collection")
                myCollections = [made]
            }
            showCollectionPicker = true
        } catch { announce(error.localizedDescription) }
    }
    private func addTo(_ c: RRCollectionRow, book: RRBook) async {
        do { try await service.addToCollection(c.id, book: book.id, track: player.s); announce("Added to \(c.title).") } catch { announce(error.localizedDescription) }
    }

    private func submitItem(_ book: RRBook) async {
        do { _ = try await service.submit(url: nil, book: book.id, title: book.title, note: ""); announce("Submitted for the library. You will be told when it is approved.") } catch { announce(error.localizedDescription) }
    }

    private func closeBook() {
        player.close()
        openBook = nil
        Task { await service.loadShelf() }
        announce("Back on the shelf.")
    }

    private func addBookmark() async {
        guard let book = openBook else { return }
        let h = player.here
        do {
            let b = try await service.addBookmark(bookId: book.id, s: h.s, c: h.c, pos: h.pos)
            openBook?.bookmarks.insert(b, at: 0)
            announce("Bookmark placed. " + player.positionSpoken + (book.isAudio ? ", " + ReadingRoomPlayer.clock(h.pos) : ""))
        } catch { announce(error.localizedDescription) }
    }
    private func removeBookmark(_ b: RRBookmark) async {
        guard let book = openBook else { return }
        do {
            try await service.removeBookmark(bookId: book.id, id: b.id)
            openBook?.bookmarks.removeAll { $0.id == b.id }
            announce("Bookmark removed.")
        } catch { announce(error.localizedDescription) }
    }
    private func toggleShared() async {
        guard let book = openBook else { return }
        do {
            let r = try await service.setShared(bookId: book.id, shared: !book.shared)
            openBook?.shared = r.shared
            announce(r.shared ? "It is in the library now. Everyone will see it as donated by \(book.ownerName ?? "you")." : "Back on your private shelf.")
        } catch { announce(error.localizedDescription) }
    }
    private func toggleGrownUps() async {
        guard let book = openBook else { return }
        do {
            let r = try await service.setShared(bookId: book.id, grownUpsOnly: !book.grownUpsOnly)
            openBook?.grownUpsOnly = r.grownUpsOnly
            announce(r.grownUpsOnly ? "Hidden from the kids." : "The kids can see it.")
        } catch { announce(error.localizedDescription) }
    }
    private func withdraw() async {
        guard let book = openBook else { return }
        do {
            player.close()
            try await service.withdraw(bookId: book.id)
            openBook = nil
            await service.loadShelf()
            announce("\(book.title) is withdrawn.")
        } catch { announce(error.localizedDescription) }
    }
    private func returnIt() async {
        guard let book = openBook else { return }
        do {
            player.close()
            try await service.returnBook(bookId: book.id)
            openBook = nil
            await service.loadShelf()
            announce("Returned. Your place in it is forgotten.")
        } catch { announce(error.localizedDescription) }
    }
    private func playSkipped(_ sk: RRSkipped, of book: RRBook) async {
        player.pause()
        announce("Reading the skipped part: \(sk.title)")
        let count = sk.chunks ?? 0
        for i in 0 ..< count {
            guard let data = try? await service.chunkAudio(bookId: book.id, s: sk.k, c: i, voice: player.voice, speed: player.speed, skipped: true), !data.isEmpty else { continue }
            await SkippedClipPlayer.shared.play(data)
        }
    }

    private func announce(_ message: String) {
        status = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// Plays one WAV clip to its end — for the skipped front matter, which is
/// read on demand and never scheduled into the book's own stream.
@MainActor
final class SkippedClipPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = SkippedClipPlayer()
    private var player: AVAudioPlayer?
    private var done: CheckedContinuation<Void, Never>?
    func play(_ data: Data) async {
        player?.stop()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        player = p
        p.delegate = self
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            done = cont
            if !p.play() { done = nil; cont.resume() }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let c = self.done
            self.done = nil
            c?.resume()
        }
    }
}

/// The donate-a-recording form: what it is and which shelf it goes on.
struct DonateRecordingSheet: View {
    let fileName: String
    let onStart: (String, String, String, String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var year = ""
    @State private var category = "audiobook"
    @State private var desc = ""
    @State private var grownUps = false

    var body: some View {
        NavigationStack {
            Form {
                if !fileName.isEmpty { Section { Text("Shared file: \(fileName)").foregroundStyle(.secondary) } }
                Section("What is it") {
                    TextField("Title", text: $title)
                    TextField("Who made it (optional)", text: $author)
                    TextField("Year (optional)", text: $year).keyboardType(.numberPad)
                    Picker("Shelf", selection: $category) {
                        ForEach(RRCategory.audio, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    TextField("About it (optional)", text: $desc, axis: .vertical).lineLimit(2 ... 5)
                    Toggle("Grown-ups only", isOn: $grownUps)
                }
                Section {
                    Button("Start — then pick the audio files") {
                        onStart(title.trimmingCharacters(in: .whitespaces), author, year, category, desc, grownUps)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Donate a recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if title.isEmpty, !fileName.isEmpty { title = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ") } }
        }
    }
}
