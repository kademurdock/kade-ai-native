import SwiftUI
import UIKit

/// THE LIBRARY'S FIRST SCREEN (Part 296, Sep 27 2026). BARD's Bookshelf
/// shape: a short, fixed list that never reorders, each row opening its own
/// screen with Back at the top left. In this order, always: Continue,
/// Springfield and the Ozarks, Video, Audio, Books, Search the Library,
/// Recently added, Recently opened, My uploads, Collections, Talk to the
/// Librarian, Add and requests. The reading-room picture is the last row.
///
/// Rows keep their places; only their words change. A count says "loading"
/// until it is real (the tree, kept on disk from last time, usually has it at
/// once). The Listen, Browse and Add switch and the lists stacked under it
/// are gone, and so is the status line: news is spoken, never inserted
/// above what she is touching.
struct LibraryHomeView: View {
    @ObservedObject private var service: ReadingRoomService
    @ObservedObject private var nowPlaying: LibraryNowPlaying
    @ObservedObject private var shelves = LibraryShelves.shared
    @ObservedObject private var requests = LibraryRequestsModel.shared
    @ObservedObject private var uploads = LibraryUploadState.shared
    /// Sep 29 2026: the Family history row's state (FamilyHistoryAccess).
    @ObservedObject private var family = FamilyHistoryAccess.shared
    @StateObject private var actions: LibraryRowActions
    @AppStorage(LibraryWords.hasLocalKey) private var rememberedLocal = false
    @State private var collectionCount: Int?
    @State private var lastLoad: Date?
    private let apiClient: KadeAPIClient

    init(apiClient: KadeAPIClient) {
        let shared = LibraryNowPlaying.shared
        let pair = shared.ensure(client: apiClient)
        self.apiClient = apiClient
        _service = ObservedObject(wrappedValue: pair.service)
        _nowPlaying = ObservedObject(wrappedValue: shared)
        _actions = StateObject(wrappedValue: LibraryRowActions(service: pair.service))
    }

    var body: some View {
        List {
            Section {
                Group {
                    continueRow
                    localRow
                    mediaRow("Video", root: "Videos", icon: "film")
                    mediaRow("Audio", root: "Audio", icon: "waveform")
                    mediaRow("Books", root: "Books", icon: "book.closed")
                }
                Group {
                    pageRow("Search the Library", icon: "magnifyingglass", page: .search,
                            hint: "Find a title, a channel, a brand or a year anywhere in the Library.")
                    pageRow("Recently added", icon: "sparkles", page: .recentlyAdded,
                            hint: "The newest things in the Library, newest first.")
                    countRow("Recently opened", icon: "clock.arrow.circlepath", detail: openedDetail, route: .page(.recentlyOpened),
                             hint: "What you opened lately, newest first.")
                    countRow("My uploads", icon: "square.and.arrow.up", detail: mineDetail,
                             route: .shelf(LibraryShelfRef(id: LibraryShelfScreen.mineID, title: "My uploads", path: "", scope: "mine")),
                             hint: "Everything you added, on its shelves.")
                    countRow("Collections", icon: "text.badge.plus", detail: collectionsDetail, route: .page(.collections),
                             hint: "Your playlists, and the ones shared with you.")
                    familyRow
                    familyAskRow
                }
                Group {
                    librarianRow
                    addRow
                }
            }
            // The reading alcove: silent, and at the bottom, where touch never looks for a control.
            Section {
                Image("LibraryAlcove").resizable().scaledToFill().frame(height: 130).clipped()
                    .accessibilityHidden(true)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .libraryRowActions(actions)
        .refreshable { await reload(force: true) }
        .task { await reload(force: false) }
    }

    // MARK: rows

    /// "Continue": what is open in the player, else the last thing started.
    @ViewBuilder
    private var continueRow: some View {
        if let now = nowPlaying.current {
            continueLink(title: now.title, kind: now.kind, category: now.category, position: now.position,
                         route: LibraryItemRoute(id: now.id, title: now.title))
        } else if let item = lastStarted {
            continueLink(title: item.title, kind: item.kind, category: item.category, position: shelfPosition(item),
                         route: LibraryItemRoute(id: item.id, title: item.title))
        } else {
            // Dimmed until there is something to pick up (never "nothing" while it loads).
            // Laid out like the real row (a jacket-sized space, "Continue" over
            // a headline), so the rows under it stay put when it fills in.
            Button {} label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle").font(.title2).frame(width: 40, height: 56).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue").font(.subheadline.weight(.semibold))
                        Text(service.shelf == nil ? "Loading" : "Nothing started yet").font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(true)
            .accessibilityLabel(service.shelf == nil ? "Continue, loading" : "Continue, nothing started yet")
            .accessibilityHint(service.shelf == nil ? "" : "Anything you start in the Library can be picked up here.")
        }
    }

    private func continueLink(title: String, kind: String, category: String, position: String, route: LibraryItemRoute) -> some View {
        NavigationLink(value: HomeRoute.library(.item(route))) {
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
            }
        }
        .accessibilityLabel(position.isEmpty ? "Continue: \(title)" : "Continue: \(title), \(position)")
        .accessibilityHint("Opens the player where you left off.")
    }

    private var lastStarted: RRItem? {
        let all = (service.shelf?.mine ?? []) + (service.shelf?.borrowed ?? [])
        return all
            .filter { $0.progress?.finished != true && !($0.progress?.updatedAt ?? "").isEmpty }
            .max { ($0.progress?.updatedAt ?? "") < ($1.progress?.updatedAt ?? "") }
    }

    /// "Chapter 3 of 12" / "Part 2 of 5" from a shelf item's saved place.
    private func shelfPosition(_ item: RRItem) -> String {
        guard let w = item.progress?.where_, !w.isEmpty else { return "" }
        return (item.isAudio ? "Part " : "Chapter ") + w
    }

    /// Springfield and the Ozarks is always the second row, so nothing is
    /// slipped in above Video once things load. It opens in the family
    /// library. Anywhere else (an outside seat, the App Review seat) it stays
    /// where it is, greyed out with the Family feature pack's reason: her
    /// Sep 25 rule for pack features is greyed, never hidden. Until that is
    /// known it is dimmed and says loading; the family's answer is
    /// remembered between launches, so for them it is live from the start.
    private enum LocalRow { case open, loading, locked }

    private var localState: LocalRow {
        let family = service.shelf?.familyLibrary
        if let tree = shelves.publicTree { return tree.local != nil || family == true ? .open : .locked }
        if family == true { return .open }
        // The shelf has answered: false for an outside seat, null for the App Review seat.
        if service.shelf != nil { return .locked }
        return rememberedLocal ? .open : .loading
    }

    @ViewBuilder
    private var localRow: some View {
        switch localState {
        case .open: openLocalRow
        case .loading: dimmedLocalRow(locked: false)
        case .locked: dimmedLocalRow(locked: true)
        }
    }

    private func dimmedLocalRow(locked: Bool) -> some View {
        let detail = locked ? KadeFamilyFeatures.note : "loading"
        return Button {} label: {
            rowLabel("Springfield and the Ozarks", icon: "mappin.and.ellipse", detail: detail)
        }
        .disabled(true)
        .accessibilityLabel("Springfield and the Ozarks, \(detail)")
        .accessibilityHint(locked ? "Local TV, radio and commercials from Springfield and the Ozarks." : "")
    }

    private var openLocalRow: some View {
        let local = shelves.publicTree?.local
        let ref = LibraryShelfRef(id: local?.id ?? "#local", title: "Springfield and the Ozarks",
                                  path: local?.path.isEmpty == false ? (local?.path ?? "") : "Videos/Ozarks (Springfield Area)",
                                  scope: "public", count: local?.count)
        let detail: String
        if let n = local?.count {
            detail = LibraryWords.items(n)
        } else if shelves.publicTree != nil {
            detail = "no items yet"
        } else if shelves.treeUnsupported {
            detail = "local TV, radio and commercials"
        } else {
            detail = countDetail(nil)
        }
        return linkRow("Springfield and the Ozarks", icon: "mappin.and.ellipse", detail: detail, route: .shelf(ref),
                       hint: "Local TV, radio and commercials from Springfield and the Ozarks, on one screen.")
    }

    /// Video, Audio, Books with their honest counts.
    private func mediaRow(_ title: String, root: String, icon: String) -> some View {
        let count = rootCount(root)
        let ref = LibraryShelfRef(id: shelves.publicTree?.root(root)?.id ?? root, title: title, path: root, scope: "public", count: count)
        return linkRow(title, icon: icon, detail: countDetail(count), route: .shelf(ref),
                       hint: "Opens the \(title) shelves.")
    }

    private func rootCount(_ root: String) -> Int? {
        if let tree = shelves.publicTree { return tree.root(root)?.count ?? 0 }
        if let folders = shelves.rootFolders {
            let wanted = root.lowercased()
            return folders.first { $0.path.lowercased() == wanted || $0.name.lowercased() == wanted }?.count ?? 0
        }
        return nil
    }

    private func countDetail(_ count: Int?) -> String {
        if let count { return count == 0 ? "no items yet" : LibraryWords.items(count) }
        return shelves.failed ? "could not load; pull down to try again" : "loading"
    }

    private var openedDetail: String {
        guard let items = LibraryOpenedScreen.opened(service.shelf) else { return "loading" }
        return items.isEmpty ? "nothing yet" : LibraryWords.items(items.count)
    }

    private var mineDetail: String {
        guard let shelf = service.shelf else { return "loading" }
        let pending = shelf.mine.filter { $0.state == "pending" }.count
        return pending > 0 ? "\(pending) still uploading" : "books and recordings you added"
    }

    /// "Collections, 3" (it read "Collections, 3 collections").
    private var collectionsDetail: String {
        guard let n = collectionCount else { return "loading" }
        return n == 0 ? "none yet" : n.formatted()
    }

    /// Sep 29 2026: Family history, after Collections, always in this place.
    /// The family's account opens it ("Ada's brother", the server's words);
    /// every other account, the App Review seat included, sees it greyed with
    /// the server's reason (her rule: greyed, never hidden). "Checking" until
    /// the first answer; the last one is remembered per account, so for the
    /// family it is live at launch.
    @ViewBuilder
    private var familyRow: some View {
        let words: FamilyRowWords = family.words
        if words.enabled {
            linkRow("Family history", icon: "person.3", detail: words.detail, route: .family(.home), hint: words.hint)
                .accessibilityInputLabels(["Family history"])
        } else {
            Button {} label: {
                rowLabel("Family history", icon: "person.3", detail: words.detail)
            }
            .disabled(true)
            .accessibilityLabel("Family history, \(words.detail)")
            .accessibilityHint(words.hint)
            .accessibilityInputLabels(["Family history"])
        }
    }

    /// Under the greyed row, for an account not linked to the tree yet: one
    /// tap asks the tree's owner (POST /ask). Afterwards it stays, dimmed,
    /// "Asked on {date}". Review and test seats never get it.
    @ViewBuilder
    private var familyAskRow: some View {
        switch family.words.ask {
        case .hidden:
            EmptyView()
        case .ask:
            Button { Task { await askToJoinFamily() } } label: {
                rowLabel(family.asking ? "Asking…" : "Ask to be added", icon: "hand.raised", detail: nil)
            }
            .disabled(family.asking)
            .accessibilityHint("Asks the tree's owner to match your account to your place in the family tree.")
        case .asked(let when):
            Button {} label: {
                rowLabel("Ask to be added", icon: "hand.raised", detail: when)
            }
            .disabled(true)
            .accessibilityLabel("Ask to be added, \(when)")
        }
    }

    private func askToJoinFamily() async {
        let said = await family.ask()
        if !said.isEmpty { KadeAnnounce.high(said) }
    }

    private var librarianRow: some View {
        Button { Task { await actions.talkToLibrarian() } } label: {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical").foregroundStyle(.brown).frame(width: 40).accessibilityHidden(true)
                Text(actions.openingLibrarian ? "Opening the librarian…" : "Talk to the Librarian")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(actions.openingLibrarian)
        .accessibilityHint("Opens Mrs. Witherspoon in the usual chat and voice screen. Tell her what you remember, or ask about something in the collection.")
    }

    /// Add and requests: says an upload in progress, or request news.
    private var addRow: some View {
        var spoken: [String] = []
        var shown = "books, recordings, links and requests"
        if let p = uploads.progress, let t = uploads.title {
            shown = "uploading \(t), \(LibraryWords.percent(p)) percent"
            spoken.append(shown)
        } else if requests.unread > 0 {
            shown = requests.unread == 1 ? "1 request has news" : "\(requests.unread) requests have news"
            spoken.append(shown)
        }
        return NavigationLink(value: HomeRoute.library(.page(.add))) {
            rowLabel("Add and requests", icon: "plus.circle", detail: shown)
        }
        .accessibilityLabel((["Add and requests"] + spoken).joined(separator: ", "))
        .accessibilityHint("Donate a book or a recording, submit a link, or ask the library for something.")
    }

    private func pageRow(_ title: String, icon: String, page: LibraryPage, hint: String) -> some View {
        NavigationLink(value: HomeRoute.library(.page(page))) {
            rowLabel(title, icon: icon, detail: nil)
        }
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    private func countRow(_ title: String, icon: String, detail: String, route: LibraryRoute, hint: String) -> some View {
        linkRow(title, icon: icon, detail: detail, route: route, hint: hint)
    }

    private func linkRow(_ title: String, icon: String, detail: String, route: LibraryRoute, hint: String) -> some View {
        NavigationLink(value: HomeRoute.library(route)) {
            rowLabel(title, icon: icon, detail: detail)
        }
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint(hint)
    }

    private func rowLabel(_ title: String, icon: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.brown).frame(width: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: loading

    /// The shelf, the tree, request news and the collections count. Coming
    /// Back to this screen asks again only after half a minute (a pull
    /// always asks), so a walk through the shelves never floods the server.
    private func reload(force: Bool) async {
        if !force, let last = lastLoad, Date().timeIntervalSince(last) < 30 { return }
        let service = self.service
        let shelves = self.shelves
        async let shelf: Void = service.loadShelf()
        async let tree: Void = shelves.refresh(service, force: force)
        await shelf
        await tree
        // Sep 29 2026: may this account open Family history? (Its own
        // half-minute rule; a pull asks outright.)
        await family.check(client: apiClient, force: force)
        await requests.reload(service)
        if let c = try? await service.collections() { collectionCount = c.mine.count + c.shared.count }
        // Opening a row (or another tab) before this finished cancels it
        // (LibraryLoad); then the next return asks again instead of leaving
        // "loading" on a row for half a minute.
        if !Task.isCancelled { lastLoad = Date() }
    }
}
