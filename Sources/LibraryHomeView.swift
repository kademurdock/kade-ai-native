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
    @StateObject private var actions: LibraryRowActions
    @AppStorage(LibraryWords.hasLocalKey) private var rememberedLocal = false
    @State private var collectionCount: Int?
    @State private var lastLoad: Date?

    init(apiClient: KadeAPIClient) {
        let shared = LibraryNowPlaying.shared
        let pair = shared.ensure(client: apiClient)
        _service = ObservedObject(wrappedValue: pair.service)
        _nowPlaying = ObservedObject(wrappedValue: shared)
        _actions = StateObject(wrappedValue: LibraryRowActions(service: pair.service))
    }

    var body: some View {
        List {
            Section {
                Group {
                    continueRow
                    if showsLocal { localRow }
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
            Button {} label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle").font(.title2).frame(width: 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue").font(.headline)
                        Text(service.shelf == nil ? "loading" : "nothing started yet").font(.subheadline)
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

    /// Springfield and the Ozarks: only in the family library (the App
    /// Review seat and other outside seats hear nothing of it). Its place is
    /// remembered between launches, so the row is there from the start.
    private var showsLocal: Bool {
        if let tree = shelves.publicTree { return tree.local != nil }
        if shelves.treeUnsupported { return service.shelf?.familyLibrary == true }
        return rememberedLocal
    }

    private var localRow: some View {
        let local = shelves.publicTree?.local
        let ref = LibraryShelfRef(id: local?.id ?? "#local", title: "Springfield and the Ozarks",
                                  path: local?.path.isEmpty == false ? (local?.path ?? "") : "Videos/Ozarks (Springfield Area)",
                                  scope: "public", count: local?.count)
        let detail: String
        if let n = local?.count {
            detail = LibraryWords.items(n)
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

    private var collectionsDetail: String {
        guard let n = collectionCount else { return "loading" }
        return n == 0 ? "none yet" : LibraryWords.count(n, "collection", "collections")
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
            shown = "uploading \(t), \(Int(p * 100)) percent"
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
        lastLoad = Date()
        let service = self.service
        let shelves = self.shelves
        async let shelf: Void = service.loadShelf()
        async let tree: Void = shelves.refresh(service, force: force)
        await shelf
        await tree
        await requests.reload(service)
        if let c = try? await service.collections() { collectionCount = c.mine.count + c.shared.count }
    }
}
