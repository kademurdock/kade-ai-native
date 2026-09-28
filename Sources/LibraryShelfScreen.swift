import SwiftUI
import UIKit

/// ONE SHELF, ONE SCREEN (Part 296, Sep 27 2026). A folder of the library,
/// the way the Files app shows one: its name as the title, Back at the top
/// left, and VoiceOver starting on a line like "53 shelves, 26,817 items".
/// Swipe right for the shelves, then the items. A long shelf shows 60 items,
/// then "Show 60 more" (no page buttons).
///
/// Counts are only ever said when they are real. With the tree (one call for
/// every shelf) they are there at once; without it (an older server) the
/// heading says "Loading" until this shelf's own answer arrives, and the
/// count is said once when it does.
struct LibraryShelfScreen: View {
    let shelf: LibraryShelfRef
    private let service: ReadingRoomService
    @ObservedObject private var shelves = LibraryShelves.shared
    @StateObject private var actions: LibraryRowActions
    @Environment(\.dismiss) private var dismiss

    /// The tree id of My uploads (this seat's own uploads, every medium).
    static let mineID = "#mine"

    /// Without a tree: this level's shelves from /archive (nil until they arrive).
    @State private var folderRows: [LibraryShelfRef]?
    @State private var items: [RRItem] = []
    /// Items on this shelf (or, for a small shelf listed whole, under it), from the server.
    @State private var itemTotal: Int?
    @State private var itemsLoaded = false
    /// The server listed every item under this shelf (a small shelf).
    @State private var listedWhole = false
    @State private var pageNo = 0
    @State private var loadingMore = false
    @State private var failure: String?
    /// A late answer never lands on a newer load.
    @State private var token = 0
    /// Without a tree, a shelf that holds only one shelf is skipped: where it led, and both names.
    @State private var skippedTo: String?
    @State private var skippedTitle: String?
    @State private var started = false
    /// The last load was cut short (a push on top, another tab), so it runs
    /// again when this screen comes back (LibraryLoad).
    @State private var cutShort = false
    /// VoiceOver is on the heading already, so a count arriving later is said once.
    @State private var headingFocusDone = false
    /// My uploads: what is still on its way.
    @State private var pending: [RRItem] = []
    @State private var showFolderMove = false
    @State private var folderMoveTo = ""
    @AccessibilityFocusState private var headingFocused: Bool
    /// After "Show 60 more", VoiceOver moves to the first of the new items.
    @AccessibilityFocusState private var focusedItem: String?
    /// Part 292: Kade's painted shelves are silent (see KadeArt).
    @KadeArtShown private var artShown: Bool

    init(apiClient: KadeAPIClient, shelf: LibraryShelfRef) {
        let pair = LibraryNowPlaying.shared.ensure(client: apiClient)
        service = pair.service
        self.shelf = shelf
        _actions = StateObject(wrappedValue: LibraryRowActions(service: pair.service))
    }

    // MARK: what is shown

    private var isMineRoot: Bool { shelf.id == Self.mineID }

    /// This shelf in the tree, when there is one.
    private var node: RRTreeNode? {
        guard !shelf.isGroup, !isMineRoot else { return nil }
        if let found = shelves.node(shelf.id, scope: shelf.scope) { return found }
        return shelf.path.isEmpty ? nil : shelves.node(shelf.path, scope: shelf.scope)
    }

    /// "Local News, 1990s" for a shelf whose own name says too little (LibraryWords.placed).
    private var shownTitle: String { skippedTitle ?? shelf.screenTitle ?? shelf.title }

    /// The shelves on this shelf, in order (nil until known).
    private var shelfRows: [LibraryShelfRef]? {
        if shelf.isGroup { return shelf.members }
        if listedWhole { return [] }
        if isMineRoot, let tree = shelves.tree("mine") { return LibraryShelfRules.rows(tree.roots, scope: "mine") }
        if let node { return LibraryShelfRules.rows(node.children, scope: shelf.scope) }
        return folderRows
    }

    /// Every item underneath (nil until known).
    private var totalCount: Int? {
        if let node { return node.count }
        if isMineRoot, let tree = shelves.tree("mine") { return tree.roots.reduce(0) { $0 + $1.count } }
        if shelf.isGroup { return shelf.members.reduce(0) { $0 + ($1.count ?? 0) } }
        if let rows = folderRows, let direct = itemTotal {
            return listedWhole ? direct : rows.reduce(0) { $0 + ($1.count ?? 0) } + direct
        }
        return shelf.count
    }

    /// Items sitting on this shelf itself (every item, for a shelf listed whole).
    private var directCount: Int? {
        if shelf.isGroup { return 0 }
        if let node { return node.flat ? node.count : node.directCount }
        if isMineRoot && shelves.tree("mine") != nil { return 0 }
        return itemTotal
    }

    /// Where the items are read from.
    private var itemsPath: String { skippedTo ?? node?.path ?? shelf.path }

    private var heading: String {
        guard let rows = shelfRows, let total = totalCount else {
            return failure == nil ? "Loading \(shownTitle)…" : "Could not open \(shownTitle)."
        }
        if rows.isEmpty && total == 0 && isMineRoot && pending.isEmpty {
            return "You have not added anything yet. Add and requests, on the Library's first screen, is where to add a book or a recording."
        }
        if rows.isEmpty { return total == 0 ? "Nothing on this shelf yet." : LibraryWords.items(total) }
        return LibraryWords.shelves(rows.count) + ", " + LibraryWords.items(total)
    }

    /// "Still uploading, 26", and how many of those stopped more than a day
    /// ago (the tree says), so a stalled push is not taken for one on its way.
    private var pendingHeading: String {
        var words = "Still uploading, \(pending.count)"
        if let stalled = shelves.tree("mine")?.pending?.stalled, stalled > 0 {
            words += stalled == pending.count ? ", all stopped more than a day ago" : ", \(stalled) stopped more than a day ago"
        }
        return words
    }

    /// Part 292's painted shelf for this one (Books, Radio, Springfield's
    /// local news…), found by the words in its path; none for a gathered row.
    private var shelfPicture: String? {
        guard artShown else { return nil }
        let path = itemsPath.isEmpty ? shelf.path : itemsPath
        return path.isEmpty ? nil : KadeArt.shelfPicture(forArchivePath: path)
    }

    /// The librarian (or the owner, in their own uploads) can move or rename a real shelf.
    private var canMoveFolder: Bool {
        guard !shelf.isGroup, !isMineRoot, !itemsPath.isEmpty, node?.isVirtual != true else { return false }
        return actions.librarian || shelf.scope == "mine" || items.contains(where: { actions.canManage($0) })
    }

    // MARK: body

    var body: some View {
        List {
            Section {
                Text(heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load(again: true) } }
                }
            }
            if let rows = shelfRows, !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.id) { ref in LibraryShelfRow(shelf: LibraryWords.placed(ref, under: shownTitle)) }
                }
            }
            itemsSection
            if isMineRoot && !pending.isEmpty {
                Section {
                    ForEach(pending) { item in LibraryItemRow(item: item, place: "mine", actions: actions) }
                } header: { Text(pendingHeading).accessibilityAddTraits(.isHeader) }
            }
            if canMoveFolder {
                Section {
                    Button("Move or rename this shelf") { folderMoveTo = itemsPath; showFolderMove = true }
                        .accessibilityHint("The librarian's tool. Everything on it moves too.")
                }
            }
            if let picture = shelfPicture {
                // Silent, and at the bottom (Part 296): it used to be a band at
                // the top that came and went per folder and moved the list.
                Section {
                    KadePaintedHeader(imageName: picture, symbol: "books.vertical", tint: .brown, height: 110)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle(shownTitle)
        .navigationBarTitleDisplayMode(.inline)
        .libraryRowActions(actions)
        .task { await start() }
        .refreshable { await load(again: true) }
        // After a move or a delete the row's own line ("Moved ...", "Deleted
        // ...") is the one thing said; the reload stays quiet.
        .onChange(of: actions.changes) { _, _ in Task { await load(again: true, speak: false) } }
        .background {
            Color.clear
                .alert("Move or rename this shelf", isPresented: $showFolderMove) {
                    TextField("New name or place", text: $folderMoveTo)
                    Button("Move") { Task { await moveFolder() } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Everything on \(shownTitle) moves with it.") }
        }
    }

    @ViewBuilder
    private var itemsSection: some View {
        if let rows = shelfRows, ((directCount ?? 0) > 0 || !items.isEmpty) {
            Section {
                if !itemsLoaded {
                    Text("Loading the items…").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    LibraryItemRow(item: item, place: shelf.scope == "mine" ? "mine" : "archive", actions: actions)
                        .accessibilityFocused($focusedItem, equals: item.id)
                }
                if itemsLoaded, let total = itemTotal, items.count < total {
                    Button(loadingMore ? "Loading more…" : "Show \(min(60, total - items.count)) more") { Task { await showMore() } }
                        .disabled(loadingMore)
                        .accessibilityHint("Showing \(items.count.formatted()) of \(total.formatted()). The next ones are added below.")
                }
            } header: {
                if !rows.isEmpty, let direct = directCount {
                    Text("Items on this shelf, \(direct.formatted())").accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    // MARK: loading

    private func start() async {
        guard !started else {
            // Back on display after a load was cut short: load again, quietly
            // (VoiceOver goes back to the row she opened, not the heading).
            if cutShort { await load(again: false, speak: false) }
            return
        }
        started = true
        focusHeadingSoon()
        if service.shelf == nil { await service.loadShelf() }
        if isMineRoot { pending = (service.shelf?.mine ?? []).filter { $0.state == "pending" } }
        await load(again: false)
    }

    /// BARD's rule: a new list starts VoiceOver on its heading, not at the
    /// top of the screen. Once, from the task, after the push has settled.
    private func focusHeadingSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            headingFocused = true
            headingFocusDone = true
        }
    }

    private func load(again: Bool, speak: Bool = true) async {
        token += 1
        let mine = token
        let wasWaiting = shelfRows == nil || totalCount == nil
        failure = nil
        cutShort = false
        if again || !shelves.settled(shelf.scope) {
            await shelves.refresh(service, scope: shelf.scope, force: again)
        }
        if again && isMineRoot {
            await service.loadShelf()
            pending = (service.shelf?.mine ?? []).filter { $0.state == "pending" }
        }
        guard mine == token else { return }
        if shelf.isGroup {
            itemsLoaded = true
        } else if node != nil || (isMineRoot && shelves.tree("mine") != nil) {
            await loadItems(token: mine)
        } else {
            await loadLevel(token: mine)
        }
        guard mine == token, !cutShort else { return }
        if speak && (wasWaiting || again) && headingFocusDone && shelfRows != nil {
            say(heading)
        }
    }

    /// With the tree: only the items (the shelves and counts are known).
    private func loadItems(token mine: Int) async {
        guard let node else {
            items = []; itemTotal = 0; itemsLoaded = true
            return
        }
        let whole = node.flat
        guard whole || node.directCount > 0 else {
            items = []; itemTotal = 0; itemsLoaded = true
            return
        }
        do {
            let page = try await service.archive(path: node.path, page: 0, scope: shelf.scope, deep: whole)
            guard mine == token else { return }
            items = page.items
            itemTotal = page.total
            pageNo = page.page
            listedWhole = whole && page.folders.isEmpty
            itemsLoaded = true
        } catch {
            guard mine == token else { return }
            if LibraryLoad.cancelled(error) { cutShort = true; return }
            failure = error.localizedDescription
            itemsLoaded = true
        }
    }

    /// Without the tree: this level from /archive, skipping any shelf that
    /// holds only one other shelf (the heading and title then say both names).
    private func loadLevel(token mine: Int) async {
        guard !shelf.path.isEmpty || isMineRoot else {
            folderRows = []; itemTotal = 0; itemsLoaded = true
            return
        }
        var path = shelf.path
        var title = shelf.screenTitle ?? shelf.title
        do {
            var page = try await service.archive(path: path, page: 0, scope: shelf.scope, deep: shelf.flat)
            var hops = 0
            while !isMineRoot, hops < 6, page.items.isEmpty, page.total == 0, page.folders.count == 1,
                  let only = page.folders.first, !LibraryWords.isHolding(only.name) {
                hops += 1
                path = only.path
                title = LibraryWords.chain(title, LibraryWords.tidy(only.name))
                page = try await service.archive(path: path, page: 0, scope: shelf.scope, deep: only.count <= 20)
            }
            guard mine == token else { return }
            if hops > 0 {
                skippedTo = path
                skippedTitle = title
            }
            folderRows = LibraryShelfRules.rows(fromFolders: page.folders, parent: path, scope: shelf.scope)
            items = page.items
            itemTotal = page.total
            pageNo = page.page
            listedWhole = page.deep == true
            itemsLoaded = true
        } catch {
            guard mine == token else { return }
            if LibraryLoad.cancelled(error) { cutShort = true; return }
            failure = error.localizedDescription
        }
    }

    private func showMore() async {
        guard !loadingMore, let total = itemTotal, items.count < total else { return }
        loadingMore = true
        defer { loadingMore = false }
        let mine = token
        do {
            let page = try await service.archive(path: itemsPath, page: pageNo + 1, scope: shelf.scope, deep: listedWhole)
            guard mine == token else { return }
            let known = Set(items.map { $0.id })
            let fresh = page.items.filter { !known.contains($0.id) }
            items.append(contentsOf: fresh)
            pageNo = page.page
            if let first = fresh.first {
                // The new items go in where the button was, so VoiceOver moves
                // to the first of them and reads it; swiping right goes on
                // through the rest to the button. Left on the button, she had
                // to swipe back past sixty rows to hear them.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard mine == token else { return }
                    focusedItem = first.id
                }
            } else {
                say("That is everything on this shelf.")
            }
        } catch {
            say(error.localizedDescription)
        }
    }

    private func moveFolder() async {
        let to = folderMoveTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to != itemsPath else { return }
        do {
            let r = try await service.moveFolder(from: itemsPath, to: to)
            say("Moved \(r.moved ?? 0) items to \(r.to ?? to).")
            await shelves.refresh(service, scope: shelf.scope, force: true)
            dismiss()
        } catch {
            say(error.localizedDescription)
        }
    }

    private func say(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

// MARK: - Search the Library

/// Search the Library on its own screen. VoiceOver starts on the search box
/// (the keyboard waits for her double-tap); a result opens the player, and
/// Back comes back to the results.
struct LibrarySearchScreen: View {
    private let service: ReadingRoomService
    @StateObject private var actions: LibraryRowActions
    @State private var query = ""
    @State private var results: [RRItem] = []
    /// The words of the last finished search.
    @State private var searched: String?
    @State private var searching = false
    @State private var more = false
    @State private var page = 0
    @State private var started = false
    @AccessibilityFocusState private var fieldFocused: Bool
    @KadeArtShown private var artShown: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(apiClient: KadeAPIClient) {
        let pair = LibraryNowPlaying.shared.ensure(client: apiClient)
        service = pair.service
        _actions = StateObject(wrappedValue: LibraryRowActions(service: pair.service))
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("A title, a channel, a brand, a year…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                        .accessibilityLabel("Search the Library")
                        .accessibilityFocused($fieldFocused)
                    Button("Search") { Task { await search() } }
                        .disabled(trimmed.isEmpty || searching)
                }
            }
            if searching || searched != nil {
                Section {
                    if searching {
                        Text("Searching…").foregroundStyle(.secondary)
                    } else if results.isEmpty, let s = searched {
                        Text("Nothing in the Library matches \(s).").foregroundStyle(.secondary)
                    }
                    ForEach(results) { item in LibraryItemRow(item: item, actions: actions) }
                    if more && !searching {
                        Button("Show more results") { Task { await search(next: true) } }
                    }
                } header: {
                    if !searching, let s = searched, !results.isEmpty {
                        Text("\(LibraryWords.count(results.count, "result", "results")) for \(s)").accessibilityAddTraits(.isHeader)
                    }
                }
            }
            if searched != nil && results.isEmpty && !searching && artShown && !typeSize.isAccessibilitySize {
                // Part 292's empty card-catalog drawer: silent, at the bottom.
                KadeArtSpot(imageName: "ArtEmptySearch", fallbackSymbol: "tray", width: 110, height: 110)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Search the Library")
        .navigationBarTitleDisplayMode(.inline)
        .libraryRowActions(actions)
        .task {
            guard !started else { return }
            started = true
            if service.shelf == nil { await service.loadShelf() }
            try? await Task.sleep(nanoseconds: 550_000_000)
            fieldFocused = true
        }
    }

    private func search(next: Bool = false) async {
        let q = next ? (searched ?? trimmed) : trimmed
        guard !q.isEmpty, !searching else { return }
        searching = true
        defer { searching = false }
        let wanted = next ? page + 1 : 0
        do {
            let r = try await service.searchPage(q, page: wanted)
            if next {
                let known = Set(results.map { $0.id })
                results.append(contentsOf: r.items.filter { !known.contains($0.id) })
            } else {
                results = r.items
            }
            page = wanted
            more = r.more ?? false
            searched = q
            say(next ? "\(r.items.count) more. \(results.count) results for \(q)." : "\(LibraryWords.count(results.count, "result", "results")) for \(q).")
        } catch {
            say(error.localizedDescription)
        }
    }

    private func say(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

// MARK: - Recently added

/// The newest items in the library, newest first (BARD's "Recently Added").
struct LibraryRecentScreen: View {
    private let service: ReadingRoomService
    @StateObject private var actions: LibraryRowActions
    @State private var items: [RRItem]?
    @State private var unsupported = false
    @State private var failure: String?
    @State private var started = false
    /// The first load was cut short (LibraryLoad); it runs again on return.
    @State private var cutShort = false
    @AccessibilityFocusState private var headingFocused: Bool

    init(apiClient: KadeAPIClient) {
        let pair = LibraryNowPlaying.shared.ensure(client: apiClient)
        service = pair.service
        _actions = StateObject(wrappedValue: LibraryRowActions(service: pair.service))
    }

    private var heading: String {
        if unsupported { return "This list comes with the next library update." }
        if let failure { return failure }
        guard let items else { return "Loading the newest items…" }
        return items.isEmpty ? "Nothing has been added yet." : "The \(LibraryWords.items(items.count)) added most recently, newest first"
    }

    var body: some View {
        List {
            Section {
                Text(heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                if failure != nil {
                    Button("Try again") { Task { await load() } }
                }
            }
            if let items, !items.isEmpty {
                Section {
                    ForEach(items) { item in LibraryItemRow(item: item, actions: actions) }
                }
            }
        }
        .navigationTitle("Recently added")
        .navigationBarTitleDisplayMode(.inline)
        .libraryRowActions(actions)
        .refreshable { await load() }
        .onChange(of: actions.changes) { _, _ in Task { await load() } }
        .task {
            guard !started else {
                if cutShort { await load() }
                return
            }
            started = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                headingFocused = true
            }
            if service.shelf == nil { await service.loadShelf() }
            await load()
        }
    }

    private func load() async {
        failure = nil
        cutShort = false
        do {
            if let found = try await service.recentItems() {
                items = found
                unsupported = false
            } else {
                unsupported = true
            }
        } catch {
            if LibraryLoad.cancelled(error) { cutShort = true; return }
            if items == nil { failure = error.localizedDescription }
        }
    }
}

// MARK: - Recently opened

/// What you opened lately, newest first (it used to fill "Your shelf" with
/// every clip ever previewed). "Remove from this list" forgets your place in it.
struct LibraryOpenedScreen: View {
    @ObservedObject private var service: ReadingRoomService
    @StateObject private var actions: LibraryRowActions
    @State private var started = false
    @AccessibilityFocusState private var headingFocused: Bool
    @KadeArtShown private var artShown: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(apiClient: KadeAPIClient) {
        let pair = LibraryNowPlaying.shared.ensure(client: apiClient)
        _service = ObservedObject(wrappedValue: pair.service)
        _actions = StateObject(wrappedValue: LibraryRowActions(service: pair.service))
    }

    /// The fifty most recently opened (your own items too), newest first.
    static func opened(_ shelf: RRShelf?) -> [RRItem]? {
        guard let shelf else { return nil }
        let all = shelf.borrowed + shelf.mine.filter { !($0.progress?.updatedAt ?? "").isEmpty }
        let sorted = all.sorted { ($0.progress?.updatedAt ?? "") > ($1.progress?.updatedAt ?? "") }
        var seen = Set<String>()
        return Array(sorted.filter { seen.insert($0.id).inserted }.prefix(50))
    }

    private var items: [RRItem]? { Self.opened(service.shelf) }

    private var heading: String {
        guard let items else { return "Loading what you opened…" }
        return items.isEmpty ? "Nothing opened yet. Anything you open in the Library shows up here." : LibraryWords.items(items.count) + ", newest first"
    }

    var body: some View {
        List {
            Section {
                Text(heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
            }
            if let items, !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        let borrowed = !actions.isMine(item)
                        LibraryItemRow(item: item, actions: actions, remove: borrowed ? removal(item) : nil)
                            .swipeActions(edge: .trailing) {
                                if borrowed {
                                    Button("Remove from this list") { Task { await remove(item) } }.tint(.orange)
                                }
                            }
                    }
                }
            }
            if let items, items.isEmpty, artShown, !typeSize.isAccessibilitySize {
                // Part 292's empty wall shelf: silent, at the bottom, only once the list has really loaded.
                KadeArtSpot(imageName: "ArtEmptyShelf", fallbackSymbol: "books.vertical", width: 120, height: 120)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Recently opened")
        .navigationBarTitleDisplayMode(.inline)
        .libraryRowActions(actions)
        .refreshable { await service.loadShelf() }
        .onChange(of: actions.changes) { _, _ in Task { await service.loadShelf() } }
        .task {
            guard !started else { return }
            started = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                headingFocused = true
            }
            await service.loadShelf()
        }
    }

    /// "Remove from this list", for the row's Actions rotor.
    private func removal(_ item: RRItem) -> () -> Void {
        return { Task { await remove(item) } }
    }

    private func remove(_ item: RRItem) async {
        do {
            try await service.returnBook(bookId: item.id)
            await service.loadShelf()
            UIAccessibility.post(notification: .announcement, argument: "Removed \(item.title) from this list, and your place in it is forgotten. It stays in the library.")
        } catch {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }
}

// MARK: - Collections

/// Your playlists and the ones shared with you, on their own screen.
struct LibraryCollectionsScreen: View {
    private let service: ReadingRoomService
    @Environment(\.kadeNavigation) private var nav

    init(apiClient: KadeAPIClient) {
        service = LibraryNowPlaying.shared.ensure(client: apiClient).service
    }

    var body: some View {
        List {
            CollectionsSection(service: service, openCollection: { row in nav.pushLibrary(.collection(row)) })
        }
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One collection, pushed: Back at the top left returns to Collections.
struct LibraryCollectionScreen: View {
    private let service: ReadingRoomService
    private let player: ReadingRoomPlayer
    let row: RRCollectionRow
    @StateObject private var actions: LibraryRowActions
    @Environment(\.kadeNavigation) private var nav
    @Environment(\.dismiss) private var dismiss

    init(apiClient: KadeAPIClient, row: RRCollectionRow) {
        let pair = LibraryNowPlaying.shared.ensure(client: apiClient)
        service = pair.service
        player = pair.player
        self.row = row
        _actions = StateObject(wrappedValue: LibraryRowActions(service: pair.service))
    }

    var body: some View {
        CollectionScreen(service: service, row: row, play: { item, rest in
            // The rest of the collection plays on from LibraryNowPlaying, wherever she goes.
            player.queue = rest.map { $0.book.id }
            nav.pushLibrary(.item(LibraryItemRoute(id: item.book.id, title: item.book.title, track: item.track, autoplay: true)))
        }, back: { dismiss() }, askLibrarian: { item in Task { await actions.talkToLibrarian(about: item.id) } })
        .libraryRowActions(actions)
    }
}
