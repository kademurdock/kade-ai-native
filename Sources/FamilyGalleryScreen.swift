import SwiftUI
import UIKit

// MARK: - Family history: photos and records (Sep 29 2026)
//
// DESIGN 1.8. One GET /gallery page at a time, in the server's words:
// - It opens on Photos (portraits and family photos). The filter: Photos,
//   Portraits, Records, Graves, Newspapers and documents, Stories and
//   clippings, Everything (with the server's counts). The sort: nearest
//   relatives first, or oldest first.
// - Three across, eager (never a lazy grid), 48 to a page. "Next 48" and
//   "Previous 48" replace the page, say "Showing 49 to 96 of 250", then move
//   VoiceOver to the first new picture. Each picture decodes at its cell's
//   size.
// - A cell shows a kind mark and a year for sight. Under VoiceOver it is ONE
//   element: the short label, "5 of 250", the date, place and description as
//   more content, and Open full screen and Open {person} in the Actions
//   rotor. Voice Control answers to "Photo 5".
// - Play slideshow plays this page. Closing the viewer hands VoiceOver back
//   to the picture it opened from.

struct FamilyGalleryScreen: View {
    let apiClient: KadeAPIClient
    let route: FamilyGalleryRoute

    @State private var kind: String
    /// "near" (nearest relatives first) or "year" (oldest first).
    @State private var sort = "near"
    @State private var from = 0
    @State private var page: FHGallery?
    @State private var failure: String?
    @State private var viewer: FamilyViewerRequest?
    @State private var returnKey: String?
    @State private var sayPage = false
    @AccessibilityFocusState private var focusKey: String?

    private let pageSize = 48

    init(apiClient: KadeAPIClient, route: FamilyGalleryRoute) {
        self.apiClient = apiClient
        self.route = route
        _kind = State(initialValue: route.kind)
        _page = State(initialValue: FamilyHistoryService.shared.cachedGallery(route, sort: nil, from: 0))
    }

    private var asked: FamilyGalleryRoute {
        FamilyGalleryRoute(kind: kind, person: route.person, since: route.since)
    }

    private var sortParam: String? { sort == "year" ? "year" : nil }

    private var loadKey: String { "\(kind)|\(sort)|\(from)" }

    private var title: String {
        FamilyAccessRules.nonEmpty(page?.title) ?? FamilyGalleryKinds.title(kind)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FamilyHeading(text: title, level: .h1, focusOnArrival: true)
                    controls
                    content(width: geo.size.width)
                }
                .padding()
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { await load() }
        .refreshable { await load() }
        .background {
            Color.clear.fullScreenCover(item: $viewer, onDismiss: { returnFocus() }) { request in
                FamilyPhotoViewer(request: request)
            }
        }
    }

    // MARK: Filter, sort, play

    private var kinds: [FHKindCount] {
        if let known = page?.kinds, !known.isEmpty { return known }
        return FamilyGalleryKinds.fallback
    }

    private var kindBinding: Binding<String> {
        Binding(get: { kind }, set: { (picked: String) in
            guard picked != kind else { return }
            kind = picked
            from = 0
            sayPage = true
        })
    }

    private var sortBinding: Binding<String> {
        Binding(get: { sort }, set: { (picked: String) in
            guard picked != sort else { return }
            sort = picked
            from = 0
            sayPage = true
        })
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Menu {
                    Picker("Show", selection: kindBinding) {
                        ForEach(kinds) { choice in
                            Text(FamilyGalleryKinds.menuWords(choice)).tag(choice.key)
                        }
                    }
                } label: {
                    Label(FamilyGalleryKinds.title(kind, in: kinds), systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Show, " + FamilyGalleryKinds.title(kind, in: kinds))
                Menu {
                    Picker("Order", selection: sortBinding) {
                        Text("Nearest relatives first").tag("near")
                        Text("Oldest first").tag("year")
                    }
                } label: {
                    Label(sort == "year" ? "Oldest first" : "Nearest first", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel(sort == "year" ? "Order, oldest first" : "Order, nearest relatives first")
            }
            .font(.subheadline)
            if let items = page?.items, !items.isEmpty {
                Button {
                    viewer = FamilyViewerRequest(items: items, start: 0, slideshow: true)
                } label: {
                    Label("Play slideshow", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Shows these pictures one at a time. It starts when you press Play.")
            }
        }
    }

    // MARK: The grid

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let page {
            if page.items.isEmpty {
                Text("There are no pictures here yet.")
                    .foregroundStyle(.secondary)
            } else {
                grid(page, width: width)
                pageButtons(page)
            }
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load() }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    private func grid(_ page: FHGallery, width: CGFloat) -> some View {
        let usable: CGFloat = min(width, 680) - 32
        let side: CGFloat = max(72, ((usable - 16) / 3).rounded(.down))
        let cells: [FamilyGalleryItem] = FamilyGalleryItem.list(page)
        let rows: Int = (cells.count + 2) / 3
        let total: Int = page.total ?? cells.count
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(FamilyGalleryItem.row(cells, row)) { cell in
                        FamilyGalleryCell(cell: cell, total: total, side: side, focus: $focusKey) {
                            openViewer(page.items, at: cell.position, key: cell.focusKey)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pageButtons(_ page: FHGallery) -> some View {
        if page.prev != nil || page.next != nil {
            FamilyPageButtons(size: pageSize,
                              hasPrevious: page.prev != nil,
                              hasNext: page.next != nil,
                              previous: { turn(to: page.prev) },
                              next: { turn(to: page.next) })
        }
    }

    private func turn(to start: Int?) {
        guard let start else { return }
        sayPage = true
        from = max(0, start)
    }

    // MARK: The viewer

    private func openViewer(_ items: [FHImage], at index: Int, key: String) {
        returnKey = key
        viewer = FamilyViewerRequest(items: items, start: index)
    }

    private func returnFocus() {
        guard let key = returnKey else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            focusKey = key
        }
    }

    // MARK: Loading

    @MainActor
    private func load() async {
        let wanted: FamilyGalleryRoute = asked
        if let cached = FamilyHistoryService.shared.cachedGallery(wanted, sort: sortParam, from: from) {
            show(cached)
            return
        }
        do {
            let fresh = try await FamilyHistoryService.shared.gallery(wanted, sort: sortParam, from: from)
            show(fresh)
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if page == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }

    /// A new page: say which pictures show, then move to the first of them.
    private func show(_ fresh: FHGallery) {
        page = fresh
        failure = nil
        guard sayPage else { return }
        sayPage = false
        let shownFrom: Int = fresh.from ?? 0
        let count: Int = fresh.count ?? fresh.items.count
        let words: String = FamilyAccessRules.nonEmpty(fresh.pageSpoken)
            ?? FamilyPaging.spoken(shownFrom..<(shownFrom + count), total: fresh.total ?? count)
        FamilyAnnounce.say(words)
        guard let first = FamilyGalleryItem.list(fresh).first else { return }
        let key: String = first.focusKey
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            focusKey = key
        }
    }
}

// MARK: - One cell

/// A picture in the grid, with its number in the whole gallery.
struct FamilyGalleryItem: Identifiable {
    /// Its place on this page (from 0).
    let position: Int
    /// Its number in the whole gallery (from 1).
    let number: Int
    let image: FHImage

    var id: Int { position }
    var focusKey: String { "gallery-\(number)-\(image.id)" }

    static func list(_ page: FHGallery) -> [FamilyGalleryItem] {
        let start: Int = page.from ?? 0
        return page.items.enumerated().map { (pair: (offset: Int, element: FHImage)) -> FamilyGalleryItem in
            FamilyGalleryItem(position: pair.offset, number: pair.element.index ?? (start + pair.offset + 1), image: pair.element)
        }
    }

    /// The three cells of grid row `row`.
    static func row(_ cells: [FamilyGalleryItem], _ row: Int) -> [FamilyGalleryItem] {
        let start: Int = row * 3
        let end: Int = min(cells.count, start + 3)
        return start < end ? Array(cells[start..<end]) : []
    }
}

struct FamilyGalleryCell: View {
    let cell: FamilyGalleryItem
    let total: Int
    let side: CGFloat
    var focus: AccessibilityFocusState<String?>.Binding
    let onOpen: () -> Void

    @Environment(\.kadeNavigation) private var nav

    private var image: FHImage { cell.image }

    private var label: String {
        FamilyAccessRules.nonEmpty(image.short) ?? FamilyAccessRules.nonEmpty(image.caption) ?? image.label
    }

    private var voiceName: String { "Photo \(cell.number)" }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                FamilyPhoto(image: image, size: .t, drawn: side)
                badge
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue("\(cell.number) of \(total)")
        .accessibilityHint("Opens it full screen.")
        .accessibilityInputLabels([voiceName])
        .accessibilityCustomContent(AccessibilityCustomContentKey("Date"), textOrNil(image.date))
        .accessibilityCustomContent(AccessibilityCustomContentKey("Place"), textOrNil(image.place))
        .accessibilityCustomContent(AccessibilityCustomContentKey("Description"), textOrNil(image.description))
        .accessibilityActions { actions }
        .accessibilityFocused(focus, equals: cell.focusKey)
    }

    private func textOrNil(_ words: String?) -> Text? {
        guard let said = FamilyAccessRules.nonEmpty(words) else { return nil }
        return Text(said)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open full screen") { onOpen() }
        ForEach(image.people) { person in
            Button(FamilyHeroCard.openName(person)) {
                nav.pushLibrary(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))
            }
        }
    }

    /// The kind mark and the year, for sight.
    private var badge: some View {
        HStack(spacing: 3) {
            Image(systemName: FamilyGalleryKinds.glyph(image))
            if let year = image.year {
                Text(String(year))
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.65)))
        .padding(4)
        .accessibilityHidden(true)
    }
}

// MARK: - Kinds

enum FamilyGalleryKinds {
    /// Before the first page arrives (the server's own list replaces it).
    static let fallback: [FHKindCount] = [
        FHKindCount(key: "photos", title: "Photos", count: nil),
        FHKindCount(key: "portraits", title: "Portraits", count: nil),
        FHKindCount(key: "records", title: "Records", count: nil),
        FHKindCount(key: "graves", title: "Graves", count: nil),
        FHKindCount(key: "documents", title: "Newspapers and documents", count: nil),
        FHKindCount(key: "stories", title: "Stories and clippings", count: nil),
        FHKindCount(key: "all", title: "Everything", count: nil),
    ]

    static func title(_ key: String, in list: [FHKindCount] = FamilyGalleryKinds.fallback) -> String {
        if let found = list.first(where: { $0.key == key }), let words = FamilyAccessRules.nonEmpty(found.title) { return words }
        if let known = fallback.first(where: { $0.key == key })?.title { return known }
        return "Photos"
    }

    /// "Photos (250)".
    static func menuWords(_ kind: FHKindCount) -> String {
        let words: String = FamilyAccessRules.nonEmpty(kind.title) ?? kind.key
        guard let count = kind.count else { return words }
        return words + " (\(count))"
    }

    static func glyph(_ image: FHImage) -> String {
        if image.isRestoredCopy { return "wand.and.stars" }
        switch image.categoryKind {
        case .portrait: return "person.crop.square"
        case .photo, .other: return "photo"
        case .record: return "doc.text"
        case .grave: return "leaf"
        case .document: return "newspaper"
        case .story: return "text.book.closed"
        case .restored: return "wand.and.stars"
        }
    }
}
