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
    /* Sep 23 2026 (A2): the ONE service and player live on LibraryNowPlaying
     * for the whole app, so a book keeps playing while you move around. Two
     * of these screens can be alive at once (the share sheet pushes a second
     * over the Library tab's own), so nothing here assumes it is the only
     * one. The player is deliberately not observed at this level: only the
     * player screen redraws on its clock (LibraryPlayerObserver), so the
     * shelf's long List is not rebuilt twice a second while a recording plays. */
    @ObservedObject private var service: ReadingRoomService
    private let player: ReadingRoomPlayer
    @ObservedObject private var nowPlaying: LibraryNowPlaying
    /// A file the share sheet handed over (book or recording).
    let incomingFile: URL?
    let incomingName: String?

    @State private var openBook: RRBook?
    @AppStorage("kade.library.followAlong") private var followAlong = false
    @State private var openCollectionRow: RRCollectionRow?
    @State private var incomingLink: String?
    @State private var showEdit = false
    @State private var showReport = false
    @State private var reportPath = ""
    @State private var reportNote = ""
    @State private var autoplayNext = false
    @State private var showCollectionPicker = false
    @State private var myCollections: [RRCollectionRow] = []
    @State private var opening = false
    @State private var status: String?
    @State private var openingLibrarian = false
    @State private var showLibrarian = false
    @State private var librarianAgentId: String?
    @State private var librarianDraft: String?
    @State private var category = ""
    @State private var keepUploadsPrivate = false
    @State private var showBookPicker = false
    @State private var showTrackPicker = false
    @State private var showDonateSheet = false
    @State private var donateFile: URL?
    @State private var donateName: String = ""
    @State private var uploadingItem: RRItem?
    @State private var uploadProgress: Double?
    @State private var grownUpsForBook = false
    /* Sep 23 2026 (B7): Listen / Browse / Add. Her pick is remembered; until
     * she picks, Listen when anything is on her shelf, otherwise Browse. A
     * shared link jumps to Add for this visit only. */
    @AppStorage("kade.library.section") private var savedSection = ""
    @State private var sectionOverride: String?
    /// The archive's place lives here, so switching parts does not lose it.
    @State private var archivePage: RRArchivePage?
    @State private var archivePath = ""
    @State private var archivePageNo = 0
    @State private var archiveScope = "public"
    @State private var archiveQuery = ""
    @State private var archiveResults: [RRItem] = []
    /// This screen's entry in LibraryNowPlaying's list of Library screens on display.
    @State private var screenID = UUID()
    @State private var isOnScreen = false
    /// `.task` runs again every time the screen reappears (a tab switch); the
    /// shared file must be handled once.
    @State private var routedIncoming = false
    @AccessibilityFocusState private var focus: Focus?
    private enum Focus: Hashable { case status, play, shelf }

    init(apiClient: KadeAPIClient, incomingFile: URL? = nil, incomingName: String? = nil) {
        let shared = LibraryNowPlaying.shared
        let pair = shared.ensure(client: apiClient)
        _service = ObservedObject(wrappedValue: pair.service)
        player = pair.player
        _nowPlaying = ObservedObject(wrappedValue: shared)
        self.incomingFile = incomingFile
        self.incomingName = incomingName
    }

    var body: some View {
        Group {
            if let book = openBook {
                LibraryPlayerObserver(player: player) { playerScreen(book) }
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
        // Sep 23 2026 (A2): collection playback (`onQueueNext`) is wired once on
        // LibraryNowPlaying, and leaving the Library no longer closes the
        // player. A video pauses there when its picture leaves the display.
        .onAppear {
            isOnScreen = true
            reportScreen()
            followPlayer()
            if nowPlaying.takeShowPlayerRequest() { showOpenPlayer() }
        }
        .onDisappear {
            isOnScreen = false
            nowPlaying.libraryScreenGone(screenID)
        }
        .onChange(of: openBook?.id) { _, _ in reportScreen() }
        .onChange(of: nowPlaying.current?.id) { _, _ in followPlayer() }
        .onChange(of: nowPlaying.showPlayerRequest) { _, _ in
            if isOnScreen, nowPlaying.takeShowPlayerRequest() { showOpenPlayer() }
        }
        // The player's announcements (chapter changes, bookmarks, errors) come
        // through LibraryNowPlaying, so only the Library screen on display
        // says them, and says them once.
        .onChange(of: nowPlaying.message) { _, line in
            if let line, isOnScreen { announce(line.text) }
        }
        .navigationTitle(openBook == nil ? (openCollectionRow?.title ?? "The Library") : (openBook?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.loadShelf()
            if let f = incomingFile, !routedIncoming {
                routedIncoming = true
                routeIncoming(f)
            }
        }
        .fileImporter(isPresented: $showBookPicker, allowedContentTypes: bookTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first { Task { await uploadBook(u) } }
        }
        .fileImporter(isPresented: $showTrackPicker, allowedContentTypes: [.audio, .movie, .mp3, .mpeg4Audio, .wav, .aiff], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await uploadTracks(urls) } }
        }
        .navigationDestination(isPresented: $showLibrarian) {
            if let agentId = librarianAgentId {
                ConversationDetailView(conversation: nil, initialAgentId: agentId, initialDraft: librarianDraft)
            }
        }
        .sheet(isPresented: $showEdit) {
            if let b = openBook {
                EditItemSheet(book: b) { fields in
                    Task {
                        do { let it = try await service.editItem(b.id, fields: fields); announce("Saved."); if var ob = openBook { ob = RRBook(id: ob.id, kind: ob.kind, category: it.category, title: it.title, author: it.author, description: it.description, ownerName: ob.ownerName, shared: it.shared, grownUpsOnly: it.grownUpsOnly, listen: ob.listen, jacket: ob.jacket, chapters: ob.chapters, tracks: ob.tracks, skipped: ob.skipped, bookmarks: ob.bookmarks, mine: ob.mine, defaultVoice: ob.defaultVoice, progress: ob.progress, librarian: ob.librarian, path: it.path, copyrightYear: it.copyrightYear); openBook = ob } } catch { announce(error.localizedDescription) }
                    }
                }
            }
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
            Section {
                Button { Task { await talkToLibrarian() } } label: {
                    Label(openingLibrarian ? "Opening the librarian…" : "Talk to the Librarian", systemImage: "books.vertical")
                }
                .disabled(openingLibrarian)
                .accessibilityHint("Opens Mrs. Witherspoon in the usual chat and voice screen.")
                Text("Tell Mrs. Witherspoon what you remember, or ask about something in the collection.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Image("LibraryAlcove").resizable().scaledToFill().frame(height: 130).clipped()
                .accessibilityHidden(true).listRowInsets(EdgeInsets())
            continueSection
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
            /* Her word (Sep 12 2026): "confusing that there are multiple donation button
             * options at the top and near the bottom, and why does it say the library is
             * empty?" One order now: the library itself first (search, the shelves,
             * loose donations), then your shelf, collections, and ONE "Add to the
             * library" section at the end that holds every way in.
             *
             * Sep 23 2026 (B7): that order was still one very long list. Now it is
             * three parts behind one segmented control — Listen (your shelf and
             * collections), Browse (search, the archive, loose donations) and Add
             * (every way in, and submissions) — with Continue, status and upload
             * progress above it in every part. Regrouped, nothing removed. */
            Section {
                Picker("Library section", selection: Binding(get: { section }, set: { savedSection = $0; sectionOverride = nil })) {
                    Text("Listen").tag("listen")
                    Text("Browse").tag("browse")
                    Text("Add").tag("add")
                }
                .pickerStyle(.segmented)
            }
            switch section {
            case "browse":
                ArchiveSection(service: service, open: { item in Task { await open(item) } }, me: service.shelf?.me ?? "", librarian: service.shelf?.librarian ?? false,
                               page: $archivePage, path: $archivePath, pageNo: $archivePageNo, scope: $archiveScope, query: $archiveQuery, results: $archiveResults)
                looseDonations
            case "add":
                addSection
                SubmissionsSection(service: service, announce: { announce($0) }, incomingLink: incomingLink, open: { id in Task { if let b = try? await service.openBook(id) { player.open(b); openBook = b } } })
            default:
                shelfFolders
                CollectionsSection(service: service, openCollection: { row in openCollectionRow = row })
            }
        }
        .refreshable { await service.loadShelf() }
        .overlay { if service.isLoading && service.shelf == nil { ProgressView("Loading the shelf…") } }
    }

    /// Which part of the shelf is showing: this visit's jump (a shared link
    /// goes to Add), else her remembered pick, else Listen when anything is on
    /// her shelf and Browse when nothing is. Listen while the shelf is still
    /// loading, so a full shelf never flips under VoiceOver.
    private var section: String {
        if let sectionOverride { return sectionOverride }
        if ["listen", "browse", "add"].contains(savedSection) { return savedSection }
        guard let shelf = service.shelf else { return "listen" }
        return shelf.mine.isEmpty && shelf.borrowed.isEmpty ? "browse" : "listen"
    }

    /// Sep 23 2026 (B7): "Continue" first. What is open in the player, else
    /// the most recently opened item with saved progress (each shelf item's
    /// progress row carries the server's `updatedAt`). Finished items don't
    /// count.
    @ViewBuilder
    private var continueSection: some View {
        if let now = nowPlaying.current {
            Section {
                continueRow(title: now.title, kind: now.kind, category: now.category, position: now.position) { showOpenPlayer() }
            }
        } else if let item = lastStarted {
            Section {
                continueRow(title: item.title, kind: item.kind, category: item.category, position: shelfPosition(item)) { Task { await open(item) } }
            }
        }
    }

    private var lastStarted: RRItem? {
        let shelf = (service.shelf?.mine ?? []) + (service.shelf?.borrowed ?? [])
        return shelf
            .filter { $0.progress?.finished != true && !($0.progress?.updatedAt ?? "").isEmpty }
            .max { ($0.progress?.updatedAt ?? "") < ($1.progress?.updatedAt ?? "") }
    }

    /// "Chapter 3 of 12" / "Part 2 of 5" from a shelf item's saved place.
    private func shelfPosition(_ item: RRItem) -> String {
        guard let w = item.progress?.where_, !w.isEmpty else { return "" }
        return (item.isAudio ? "Part " : "Chapter ") + w
    }

    private func continueRow(title: String, kind: String, category: String, position: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 12) {
                LibraryJacket(kind: kind, category: category, title: title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue").font(.subheadline.weight(.semibold))
                    Text(title).font(.headline)
                    if !position.isEmpty {
                        Text(position).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.circle.fill").font(.title2).accessibilityHidden(true)
            }
        }
        .accessibilityLabel(position.isEmpty ? "Continue: \(title)" : "Continue: \(title), \(position)")
        .accessibilityHint("Opens the player where you left off.")
    }

    /// Browse: shared items not filed on an archive shelf.
    private var looseDonations: some View {
        Section {
            let lib = service.shelf?.library ?? []
            let filed = service.shelf?.libraryFiled ?? 0
            let cats = Array(Set(lib.map { $0.isAudio ? $0.category : "book" })).sorted()
            if cats.count > 1 {
                Picker("Show", selection: $category) {
                    Text("Everything").tag("")
                    ForEach(cats, id: \.self) { Text(RRCategory.name($0, isAudio: $0 != "book")).tag($0) }
                }
            }
            let shown = lib.filter { category.isEmpty || ($0.isAudio ? $0.category : "book") == category }
            if shown.isEmpty {
                Text(!lib.isEmpty ? "Nothing on that shelf." : (filed > 0 ? "Everything shared so far, \(filed) items, is filed on the shelves above — Books, Video and the rest. Loose donations would be listed here." : "Nothing loose in the library yet. Choose Add, above, to donate something everyone can check out.")).foregroundStyle(.secondary)
            }
            ForEach(shown) { item in row(item, place: "library") }
        } header: { Text("Loose donations (not filed on a shelf)").accessibilityAddTraits(.isHeader) }
    }

    /// Add: every way into the library, in one place (her Sep 12 word).
    private var addSection: some View {
        Section {
            Text("Your uploads are yours to manage. Private items stay on your shelf until you submit them. The librarian’s uploads are shared by default.").font(.footnote).foregroundStyle(.secondary)
            if service.shelf?.librarian == true { Toggle("Keep my new uploads private", isOn: $keepUploadsPrivate) }
            Button { showBookPicker = true } label: {
                Label("Add a book or DAISY audiobook", systemImage: "book.closed")
            }
            .accessibilityHint("Pick A DAISY text or audio zip, an EPUB, a text file or a Word file from Files. It lands on your shelf; the Bookshare notice is skipped and the book opens with its jacket.")
            Toggle("Grown-ups only for the next book", isOn: $grownUpsForBook)
            Button { donateFile = nil; donateName = ""; showDonateSheet = true } label: {
                Label("Add audio or video", systemImage: "waveform")
            }
            .accessibilityHint("An audiobook, described-movie audio, a cassette side, old radio or commercials. Name it, then add one or more audio files; big files go straight to storage.")
        } header: { Text("Add to the library").accessibilityAddTraits(.isHeader) }
    }

    /// The personal shelf as folders — Books, Recordings, Video, Archive clips —
    /// with what you donated and what you opened side by side. Removing a
    /// checked-out item only touches your shelf.
    private func shelfFolder(_ b: RRItem) -> String { b.kind == "text" ? "Books" : (b.kind == "video" ? "Videos" : "Audio") }
    @ViewBuilder
    private var shelfFolders: some View {
        let mine = (service.shelf?.mine ?? []).map { ($0, "mine") }
        let borrowed = (service.shelf?.borrowed ?? []).map { ($0, "borrowed") }
        let all = mine + borrowed
        if all.isEmpty {
            Section { Text("Nothing on your shelf yet. Open anything under Browse, donate a book or a recording under Add, or share a file from another app to Kade-AI.").foregroundStyle(.secondary) } header: { Text("Your shelf").accessibilityAddTraits(.isHeader) }
        } else {
            ForEach(["Books", "Audio", "Videos"], id: \.self) { folder in
                let items = all.filter { shelfFolder($0.0) == folder }
                if !items.isEmpty {
                    Section {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, pair in
                            row(pair.0, place: pair.1)
                                .swipeActions(edge: .trailing) {
                                    if pair.1 == "borrowed" {
                                        Button("Remove from my shelf") { Task { try? await service.returnBook(bookId: pair.0.id); await service.loadShelf(); announce("Removed from your shelf. It stays in the library.") } }.tint(.orange)
                                    }
                                }
                        }
                    } header: { Text("Your shelf — \(folder) (\(items.count))").accessibilityAddTraits(.isHeader) }
                }
            }
        }
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
            HStack(alignment: .top, spacing: 12) {
                LibraryJacket(kind: item.kind, category: item.category, title: item.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline)
                    Text(rowDetail(item, place: place)).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            sectionOverride = "add"   // the submit form lives under Add (B7)
            announce("Paste is ready: submit \(incomingLink ?? "the link") for the library below.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        let audio = ["mp3", "m4a", "m4b", "aac", "wav", "ogg", "oga", "opus", "flac", "aiff", "aif", "mp4", "m4v", "mov", "webm"]
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
        let card = LibraryUploadCard(name: url.deletingPathExtension().lastPathComponent)
        do {
            let r = try await service.uploadBook(fileURL: url, grownUpsOnly: grownUpsForBook, keepPrivate: keepUploadsPrivate, onProgress: { p in card.progress(p) })
            card.finish(failed: false)
            let skipped = r.skipped?.count ?? 0
            announce("Added \(r.book.title)\(r.book.author.map { " by \($0)" } ?? ""). \(r.book.sections ?? 0) sections, about \(r.book.listen ?? "") of listening." + (skipped > 0 ? " \(skipped) front-matter parts skipped." : ""))
            await service.loadShelf()
            try? FileManager.default.removeItem(at: url)
        } catch {
            card.finish(failed: true)
            announce(error.localizedDescription)
        }
    }

    private func startRecording(title: String, author: String, year: String, category: String, description: String, grownUpsOnly: Bool) async {
        do {
            let item = try await service.newRecording(title: title, author: author, year: year, category: category, description: description, grownUpsOnly: grownUpsOnly, keepPrivate: keepUploadsPrivate)
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
        // One lock-screen card for the whole donation, not one per file.
        let card: LibraryUploadCard? = urls.isEmpty ? nil : LibraryUploadCard(name: item.title)
        var anyFailed = false
        for (i, u) in urls.enumerated() {
            announce("Uploading \(u.lastPathComponent) (\(i + 1) of \(urls.count))…")
            uploadProgress = 0
            do {
                item = try await service.uploadTrack(item: item, fileURL: u, title: urls.count == 1 && (item.tracks ?? 0) == 0 ? "" : u.deletingPathExtension().lastPathComponent) { p in
                    uploadProgress = p
                    card?.progress((Double(i) + p) / Double(urls.count))
                }
                uploadingItem = item
                announce("Part \(item.tracks ?? 0) added to \(item.title).")
                if u.path.contains("/SharedInbox/") { try? FileManager.default.removeItem(at: u) }
            } catch {
                anyFailed = true
                announce("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        card?.finish(failed: anyFailed)
        uploadProgress = nil
        await service.loadShelf()
        announce("\(item.title) has \(item.tracks ?? 0) recording\((item.tracks ?? 0) == 1 ? "" : "s"). Open it from your shelf to play it or put it in the library.")
    }

    // MARK: - Player

    private func talkToLibrarian(itemId: String? = nil) async {
        guard !openingLibrarian else { return }
        openingLibrarian = true
        defer { openingLibrarian = false }
        do {
            let guide = try await service.librarianGuide()
            guard guide.agentId.hasPrefix("agent_") else {
                announce("The librarian is unavailable right now. Please try again.")
                return
            }
            player.pause()
            librarianAgentId = guide.agentId
            librarianDraft = itemId.map { "Tell me about the Library item with catalog ID \($0)." }
            showLibrarian = true
        } catch {
            announce("Could not open the librarian. \(error.localizedDescription)")
        }
    }

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

                Button { Task { await talkToLibrarian(itemId: book.id) } } label: {
                    Label("Ask Mrs. Witherspoon about this item", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.bordered)
                .disabled(openingLibrarian)
                .accessibilityHint("Opens her chat with a question ready to send. Pauses library playback.")

                if book.isAudio {
                    VideoPane(player: player, service: service, book: book, announce: { announce($0) })
                }
                HStack {
                    Button { Task { await pickCollection() } } label: { Label("Add to a collection", systemImage: "text.badge.plus") }
                        .buttonStyle(.bordered)
                    Button { reportPath = book.path ?? ""; reportNote = ""; showReport = true } label: { Label("Suggest a different shelf", systemImage: "arrowshape.turn.up.right") }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Tells the librarian this is on the wrong shelf and where it belongs.")
                }
                .alert("Where does it belong?", isPresented: $showReport) {
                    TextField("Folder, like Books/Fiction — Romance", text: $reportPath)
                    TextField("Note (optional)", text: $reportNote)
                    Button("Send") { Task { do { let applied = try await service.reportShelf(book: book.id, path: reportPath, note: reportNote); announce(applied ? "Moved." : "Sent to the librarian. You will be told when it is moved.") } catch { announce(error.localizedDescription) } } }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Add \(book.title) to which collection?", isPresented: $showCollectionPicker, titleVisibility: .visible) {
                    ForEach(myCollections) { c in Button(c.title) { Task { await addTo(c, book: book) } } }
                    Button("Cancel", role: .cancel) {}
                }
                LibrarianPane(service: service, bookId: book.id, announce: { announce($0) }, speak: { text in await player.speak(text) }, note: book.librarian)
                if book.mine || (service.shelf?.librarian ?? false) {
                    Button { showEdit = true } label: { Label("Edit this item", systemImage: "pencil") }.buttonStyle(.bordered)
                }

                Text(player.nowText.isEmpty ? (book.isAudio ? player.partTitle : "Press Play.") : player.nowText)
                    .font(followAlong ? .title2 : .body)
                    .lineSpacing(followAlong ? 8 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(followAlong && player.isPlaying ? Color.yellow.opacity(0.22) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Now: " + (player.nowText.isEmpty ? player.partTitle : player.nowText))

                if book.isAudio {
                    Text("\(ReadingRoomPlayer.clock(player.filePosition)) of \(ReadingRoomPlayer.clock(player.fileDuration))")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }

                chapterPicker(book)
                if !book.isAudio {
                    Toggle("Highlight the spoken passage", isOn: $followAlong)
                        .accessibilityHint("Larger text and a highlighted passage while reading. Passage timing, not individual words. VoiceOver focus stays where you put it.")
                }

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
        .safeAreaInset(edge: .bottom) {
            transport.padding().background(.regularMaterial)
        }
    }

    private var speeds: [(Double, String)] { [(0.8, "Slower"), (0.9, "A little slower"), (1.0, "Normal"), (1.15, "A little faster"), (1.3, "Faster"), (1.5, "Fastest")] }

    @State private var scrubPosition: Double = 0
    @State private var scrubbing = false

    private var transport: some View {
        VStack(spacing: 10) {
            if player.isAudio, player.fileDuration > 0 {
                Slider(value: Binding(get: { scrubbing ? scrubPosition : player.filePosition }, set: { scrubPosition = $0 }),
                       in: 0...max(1, player.fileDuration), onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { player.seekFile(to: scrubPosition) }
                })
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(ReadingRoomPlayer.clock(player.filePosition)) of \(ReadingRoomPlayer.clock(player.fileDuration))")
                .accessibilityAdjustableAction { direction in
                    if direction == .increment { player.forward() }
                    else if direction == .decrement { player.back() }
                }
            }
            HStack(spacing: 10) {
                bigButton(player.isAudio ? "Previous part" : "Previous chapter", icon: "backward.end.fill", hint: "") { player.previousPart() }
                bigButton("Bookmark", icon: "bookmark.fill", hint: "Marks this spot so you can come back to it.") { Task { await addBookmark() } }
                bigButton(player.isAudio ? "Next part" : "Next chapter", icon: "forward.end.fill", hint: "") { player.nextPart() }
            }
            HStack(spacing: 12) {
                seekButton(backward: true)
                Button { player.togglePlay() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                        Text(player.isPlaying ? "Pause" : "Play").font(.footnote.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityFocused($focus, equals: .play)
                seekButton(backward: false)
            }
        }
    }

    private func seekButton(backward: Bool) -> some View {
        let direction = backward ? "back" : "forward"
        let sign: Double = backward ? -1 : 1
        return bigButton(backward ? "Back 10 seconds" : "Forward 10 seconds", icon: backward ? "gobackward.10" : "goforward.10", hint: "Hold for larger jumps, or use VoiceOver Actions.") {
            player.skip(seconds: sign * 10)
        }
        .contextMenu {
            ForEach([10, 20, 30, 60, 120], id: \.self) { seconds in
                Button("Skip \(direction) \(seconds) seconds") { player.skip(seconds: sign * Double(seconds)) }
            }
        }
        .accessibilityAction(named: "Skip \(direction) 20 seconds") { player.skip(seconds: sign * 20) }
        .accessibilityAction(named: "Skip \(direction) 30 seconds") { player.skip(seconds: sign * 30) }
        .accessibilityAction(named: "Skip \(direction) one minute") { player.skip(seconds: sign * 60) }
        .accessibilityAction(named: "Skip \(direction) two minutes") { player.skip(seconds: sign * 120) }
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

    @State private var showVoicePicker = false
    /// Sep 12 2026, her word: "the voice picker doesn't have a way for you to
    /// preview which voice you're picking to read your audiobook. If it's a
    /// DAISY it just shows a list of names." The plain wheel of names is gone;
    /// the button opens the same VoicePickerView every character uses, where
    /// flicking the wheel plays a preview of the voice you land on. Done
    /// hands the pick to the player, which restarts the current piece in it.
    private var voiceAndSpeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                let was = player.isPlaying
                if was { player.pause() }
                showVoicePicker = true
            } label: {
                HStack {
                    Text("Voice")
                    Spacer()
                    Text(player.voice.isEmpty ? "The library's voice" : player.voice)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice: \(player.voice.isEmpty ? "the library's voice" : player.voice)")
            .accessibilityHint("Opens the voice picker. Flick through the wheel to hear a preview of each voice, then press Done.")
            .sheet(isPresented: $showVoicePicker) {
                VoicePickerView(apiClient: service.client, selection: Binding(get: { player.voice }, set: { player.changeVoice($0) }), deliveryAgentId: ReadingRoomPlayer.deliveryPreference)
            }
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
        DisclosureGroup(book.mine || (service.shelf?.librarian ?? false) ? "Where it sits" : "Checked out") {
            if book.mine || (service.shelf?.librarian ?? false) {
                Button(book.shared ? "Take it out of the library" : ((service.shelf?.librarian ?? false) ? "Put it in the library for everyone" : "Submit this for the library")) { Task { await toggleShared() } }
                Button(book.grownUpsOnly ? "Grown-ups only is on — allow the kids" : "Grown-ups only is off — hide it from the kids") { Task { await toggleGrownUps() } }
                if book.isAudio {
                    Button("Add recordings") { uploadingItem = RRItem(id: book.id, kind: "audio", category: book.category, description: nil, tracks: book.tracks.count, seconds: nil, state: nil, title: book.title, author: book.author, publisher: nil, copyrightYear: nil, synopsis: nil, source: nil, ownerName: book.ownerName, owner: nil, shared: book.shared, grownUpsOnly: book.grownUpsOnly, sections: nil, chunks: nil, listen: book.listen, skippedCount: nil, progress: nil); showTrackPicker = true }
                }
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

    /// Tells LibraryNowPlaying this screen is on display, and whether it is
    /// showing the player (the Now Playing bar steps aside; a video pauses
    /// when its picture goes away).
    private func reportScreen() {
        guard isOnScreen else { return }
        nowPlaying.libraryScreen(screenID, showsPlayer: openBook != nil)
    }

    /// Keeps the player screen honest when the one player changes under it:
    /// closed from the Now Playing bar, the next item of a collection, or the
    /// other Library screen opening something else.
    private func followPlayer() {
        guard let shown = openBook else { return }
        guard let now = player.book else { openBook = nil; return }
        if now.id != shown.id { openBook = now }
    }

    /// The Now Playing bar (or a search result) asked for the player: show it
    /// for whatever is open, and put VoiceOver on Play.
    private func showOpenPlayer() {
        guard let book = player.book else { return }
        openCollectionRow = nil
        openBook = book
        announce(book.title + ". " + player.positionSpoken + (player.isPlaying ? "." : ". Press Play."))
        focus = .play
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
            openBook?.shared = r.book.shared
            announce(r.pending == true ? "Submitted for the library. The librarian will look at it and you will be told." : (r.book.shared ? "It is in the library now. Everyone will see it as donated by \(book.ownerName ?? "you")." : "Back on your private shelf."))
        } catch { announce(error.localizedDescription) }
    }
    private func toggleGrownUps() async {
        guard let book = openBook else { return }
        do {
            let r = try await service.setShared(bookId: book.id, grownUpsOnly: !book.grownUpsOnly)
            openBook?.grownUpsOnly = r.book.grownUpsOnly
            announce(r.book.grownUpsOnly ? "Hidden from the kids." : "The kids can see it.")
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

/// Sep 23 2026 (A2): redraws only the player screen when the shared player
/// changes (its clock ticks twice a second while a recording plays), so the
/// rest of the Library, the long shelf List, does not rebuild with it.
private struct LibraryPlayerObserver<Content: View>: View {
    @ObservedObject var player: ReadingRoomPlayer
    let content: () -> Content

    init(player: ReadingRoomPlayer, @ViewBuilder content: @escaping () -> Content) {
        _player = ObservedObject(wrappedValue: player)
        self.content = content
    }

    var body: some View { content() }
}

/// Sep 23 2026 (C3): the lock-screen card for one Library upload. Fail-soft
/// like KadeJobActivity itself (a nil id just means no card), and it passes
/// progress on in 5 percent steps so URLSession's callbacks never flood
/// ActivityKit.
@MainActor
private final class LibraryUploadCard {
    private let job: String?
    private var sent = -1.0

    init(name: String) {
        job = KadeJobActivity.start(kind: "upload", title: "Uploading: \(name)", status: "Uploading")
    }

    func progress(_ p: Double) {
        let value = min(max(p, 0), 1)
        guard value - sent >= 0.05 || (value >= 1 && sent < 1) else { return }
        sent = value
        KadeJobActivity.update(job, status: "Uploading", progress: value)
    }

    func finish(failed: Bool) {
        if failed {
            KadeJobActivity.finish(job, status: "Upload failed", failed: true)
        } else {
            KadeJobActivity.finish(job, status: "Added to the Library")
        }
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
    @State private var category = "other"
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
                    Picker("Type of recording", selection: $category) {
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
