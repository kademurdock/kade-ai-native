import SwiftUI
import UIKit

/// One load owner on LibraryHomeView's List; these Sections only render.
struct LibraryBrowseSections: View {
    @ObservedObject var catalog: LibraryBrowseController
    @ObservedObject var actions: LibraryRowActions
    @FocusState private var searchEditing: Bool
    @AccessibilityFocusState private var firstNewItem: String?

    var body: some View {
        Group {
            Section {
                HStack {
                    TextField("Title, topic, channel or year", text: $catalog.searchText)
                        .submitLabel(.search).autocorrectionDisabled()
                        .focused($searchEditing)
                        .accessibilityLabel("Search the Library")
                        .onSubmit { search() }
                    Button("Search") { search() }
                }
                Picker("Type", selection: $catalog.query.type) {
                    Text("All types").tag("")
                    ForEach(typeFacets) { facet in Text("\(facet.typeTitle) (\(facet.count.formatted()))").tag(facet.id) }
                }
                Picker("Decade", selection: $catalog.query.decade) {
                    Text("All decades").tag("")
                    ForEach(decadeFacets) { facet in Text("\(facet.id) (\(facet.count.formatted()))").tag(facet.id) }
                }
                Picker("Format", selection: $catalog.query.kind) {
                    Text("All formats").tag("")
                    Text("Read").tag("text")
                    Text("Audio").tag("audio")
                    Text("Video").tag("video")
                }
                Picker("Order", selection: $catalog.query.sort) {
                    Text("Recently added").tag("recent")
                    Text("Title").tag("title")
                }
                if catalog.query != LibraryBrowseQuery() || !catalog.searchText.isEmpty {
                    Button("Clear filters") { catalog.clearFilters(); searchEditing = false }
                }
            } header: { Text("Browse the Library").accessibilityAddTraits(.isHeader) }

            Section {
                Text(countWords).font(.headline).accessibilityAddTraits(.isHeader)
                if let failure = catalog.failure {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Try again") {
                        catalog.tryAgain()
                    }
                }
                if !catalog.loading, catalog.paging.total == 0, catalog.failure == nil {
                    Text("Nothing matches these filters. Try another type, decade or search.").foregroundStyle(.secondary)
                }
                ForEach(catalog.paging.items) { item in
                    LibraryItemRow(item: item, actions: actions)
                        .accessibilityFocused($firstNewItem, equals: item.id)
                }
                if catalog.paging.next != nil {
                    Button(catalog.loadingMore ? "Loading more…" : "Load more") {
                        guard !catalog.loadingMore else { return }
                        catalog.startMore()
                    }
                    .accessibilityHint("Adds the next items to this list and moves to the first new item.")
                }
            }
            .onChange(of: catalog.firstNewID) { _, id in firstNewItem = id }
        }
    }

    private var typeFacets: [LibraryBrowseFacet] { facets(catalog.paging.types, selected: catalog.query.type) }
    private var decadeFacets: [LibraryBrowseFacet] { facets(catalog.paging.decades, selected: catalog.query.decade) }
    private func facets(_ rows: [LibraryBrowseFacet], selected: String) -> [LibraryBrowseFacet] {
        let valid = rows.filter { !$0.id.isEmpty }
        return selected.isEmpty || valid.contains(where: { $0.id == selected })
            ? valid : valid + [LibraryBrowseFacet(_id: selected, count: 0)]
    }
    private var countWords: String {
        if catalog.loading { return "Loading the Library…" }
        guard let total = catalog.paging.total else { return catalog.failure == nil ? "Loading the Library…" : "Could not load the Library." }
        return LibraryWords.items(total) + (catalog.paging.items.isEmpty ? "" : ", \(catalog.paging.items.count.formatted()) shown")
    }

    private func search() {
        catalog.search()
        searchEditing = false
    }

}

struct LibraryBrowseLoadID: Hashable {
    let query: LibraryBrowseQuery
    let refresh: UUID
    let changes: Int
    let retry: Int
}

@MainActor
final class LibraryBrowseController: ObservableObject {
    private let service: ReadingRoomService
    @Published var query = LibraryBrowseQuery()
    @Published var searchText = ""
    @Published private(set) var paging = LibraryBrowsePaging<RRItem>()
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var failure: String?
    @Published private(set) var retry = 0
    @Published private(set) var firstNewID: String?
    private var moreTask: Task<Void, Never>?
    private var moreLease = LibraryBrowseMoreLease()
    private var loaded: LibraryBrowseLoadID?
    private var inFlight: LibraryBrowseLoadID?
    private var currentLoad: LibraryBrowseLoadID?
    private var failedMore = false

    init(service: ReadingRoomService) { self.service = service }
    func loadID(refresh: UUID, changes: Int) -> LibraryBrowseLoadID {
        LibraryBrowseLoadID(query: query, refresh: refresh, changes: changes, retry: retry)
    }
    func search() {
        query.q = String(searchText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        retry += 1
    }
    func clearFilters() {
        searchText = ""
        query = LibraryBrowseQuery()
        retry += 1
    }
    func tryAgain() {
        if failedMore { startMore() }
        else { retry += 1 }
    }
    func startMore() {
        guard !loading, !loadingMore, paging.query == query, paging.next != nil,
              let lease = moreLease.reserve() else { return }
        // Reserve before the Task gets a turn, so a rapid second activation
        // cannot overwrite the real request's cancellation handle.
        loadingMore = true
        moreTask = Task { await loadMore(lease: lease) }
    }
    func cancelMore() {
        moreLease.cancel()
        moreTask?.cancel()
        moreTask = nil
        loadingMore = false
    }
    /// Invalidate an initial request before a quick leave-and-return can
    /// encounter its in-flight guard. The List cancels its task itself.
    func suspend() {
        cancelMore()
        currentLoad = nil
        inFlight = nil
        loading = false
        loadingMore = false
    }

    func reload(id: LibraryBrowseLoadID) async {
        guard (loaded != id || paging.total == nil), inFlight != id else { return }
        currentLoad = id
        inFlight = id
        cancelMore()
        let announce = loaded != nil
        let captured = id.query
        let generation = paging.reset(for: captured)
        firstNewID = nil
        loading = true
        loadingMore = false
        failure = nil
        failedMore = false
        defer {
            if generation == paging.generation { loading = false; inFlight = nil }
        }
        do {
            let page = try await service.browse(captured)
            guard !Task.isCancelled, currentLoad == id, query == captured, generation == paging.generation else { return }
            guard paging.accept(page, query: captured, generation: generation) else {
                throw RRError(message: "The library returned an incomplete list. Try again.")
            }
            loaded = id
            if announce { say(LibraryWords.items(page.total) + " match.") }
        } catch {
            guard !LibraryLoad.cancelled(error), currentLoad == id, query == captured, generation == paging.generation else { return }
            failure = error.localizedDescription
            failedMore = false
        }
    }

    private func loadMore(lease: UUID) async {
        defer {
            if moreLease.accepts(lease) { moreLease.finish(lease); loadingMore = false; moreTask = nil }
        }
        guard moreLease.accepts(lease), !loading, paging.query == query, let cursor = paging.next else { return }
        let captured = query
        let generation = paging.generation
        let oldIDs = Set(paging.items.map(\.id))
        failure = nil
        do {
            let page = try await service.browse(captured, after: cursor)
            guard !Task.isCancelled, moreLease.accepts(lease), captured == query, generation == paging.generation else { return }
            guard paging.accept(page, query: captured, generation: generation, after: cursor) else {
                throw RRError(message: "The next items could not be added. Try again.")
            }
            firstNewID = paging.items.first(where: { !oldIDs.contains($0.id) })?.id
            say("\(paging.items.count.formatted()) of \(LibraryWords.items(page.total)) shown.")
        } catch {
            guard !LibraryLoad.cancelled(error), moreLease.accepts(lease), captured == query, generation == paging.generation else { return }
            failure = error.localizedDescription
            failedMore = true
        }
    }

    private func say(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: text, attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low]))
    }
}
