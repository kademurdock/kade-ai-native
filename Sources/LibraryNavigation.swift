import SwiftUI
import UIKit

/// THE LIBRARY, ONE SCREEN AT A TIME (Part 296, Sep 27 2026).
///
/// Kade, Sep 27: "I'd like it to work with voiceover kinda like how the
/// regular files app does ... The way they stack, the fact that there are
/// some weird folders, the fact that it takes a minute to load things so it
/// gives misleading item counts at the beginning, I like the layout of bard
/// nls ... Touching the top left doesn't bring you to the back button
/// usually ... I just feel like I'm getting lost in a stack of shelves and a
/// maze of folders."
///
/// Before this, the whole Library was ONE list on the tab's root: folders,
/// the player and collections all swapped in place, so the navigation bar
/// never had a Back button and the top-left corner was always Search. Now
/// every shelf, every list and the player is its own screen, pushed onto the
/// Library tab's stack through the one `HomeRoute.library` case, titled with
/// its name, with the system Back button at the top left.
///
/// Words: "shelf" now means only a folder in the library. "Your shelf", "The
/// archive", "All media", "Public library" and "Back to the shelf" are gone.

// MARK: - Routes

/// A place in the Library.
enum LibraryRoute: Hashable {
    /// A shelf: a folder of the library, a gathered row, or your uploads.
    case shelf(LibraryShelfRef)
    /// The player for one item.
    case item(LibraryItemRoute)
    case collection(RRCollectionRow)
    case page(LibraryPage)

    var id: String {
        switch self {
        case .shelf(let ref): return "shelf-\(ref.scope)-\(ref.id)-\(ref.path)"
        case .item(let item): return "item-\(item.id)-\(item.track ?? -1)-\(item.autoplay)-\(item.addRecordings)"
        case .collection(let row): return "collection-\(row.id)"
        case .page(let page): return "page-\(page.rawValue)"
        }
    }
}

/// The first screen's lists that are not shelves.
enum LibraryPage: String, Hashable {
    case search, recentlyAdded, recentlyOpened, collections, add
}

/// Which item the player screen shows, and what to do once it is open.
struct LibraryItemRoute: Hashable {
    let id: String
    /// Said as the screen's title until the item arrives.
    var title: String = ""
    /// Start at this part (a collection's track).
    var track: Int? = nil
    /// Press Play once it is open (Play all, in a collection).
    var autoplay = false
    /// Open the file picker for more recordings once it is open.
    var addRecordings = false
}

/// A shelf to show. `id` is the tree's key for it (the real path, or "#..."
/// for a gathered row); `path` is the real shelf /archive reads. `members`
/// carries a gathered row's shelves when there is no tree to look them up in.
struct LibraryShelfRef: Hashable {
    var id: String
    var title: String
    var path: String
    var scope: String = "public"
    /// Every item underneath, when known.
    var count: Int? = nil
    /// Small enough to list every item under it at once.
    var flat = false
    /// "audio" on a Springfield row that is local radio.
    var medium: String? = nil
    var members: [LibraryShelfRef] = []
    /// The screen's title when the name alone says too little: "1990s"
    /// opened from Local News is titled "Local News, 1990s", so touching the
    /// top of the screen says where she is. The row keeps the short name.
    var screenTitle: String? = nil

    var isGroup: Bool { !members.isEmpty }
    /// What VoiceOver says for the row: "Cars and Trucks, 956 items".
    var spoken: String {
        var bits = [title]
        if medium == "audio", !title.lowercased().contains("audio"), !title.lowercased().contains("radio") { bits.append("audio") }
        if let count { bits.append(LibraryWords.items(count)) }
        return bits.joined(separator: ", ")
    }
}

// MARK: - Words

enum LibraryWords {
    static let notFiled = "Not filed yet"
    /// Remembered between launches: whether this seat's tree had a
    /// Springfield screen, so its row is there from the first moment.
    static let hasLocalKey = "kade.library.hasLocal"

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n == 1 ? one : many)"
    }
    static func items(_ n: Int) -> String { count(n, "item", "items") }
    static func shelves(_ n: Int) -> String { count(n, "shelf", "shelves") }

    /// "45 seconds", "12 minutes", "1 hour 5 minutes".
    static func length(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "" }
        if total < 60 { return count(total, "second", "seconds") }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return count(minutes, "minute", "minutes") }
        let hours = minutes / 60
        let rest = minutes % 60
        return count(hours, "hour", "hours") + (rest > 0 ? " " + count(rest, "minute", "minutes") : "")
    }

    /// How long an item is: its recordings' time, or a book's listening time.
    static func length(of item: RRItem) -> String {
        if item.isAudio, let s = item.seconds, s > 0 { return length(seconds: s) }
        return item.listen ?? ""
    }

    /// How a shelf's name is read (display only; the real name stays in the
    /// path): an archive.org slug reads as words, a lowercase first letter
    /// is capitalised.
    static func tidy(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Untitled shelf" }
        if !name.contains(" "), name.filter({ $0 == "-" }).count >= 2, name == name.lowercased() {
            name = name.replacingOccurrences(of: "-", with: " ")
        }
        if let first = name.first, first.isLowercase {
            name = first.uppercased() + String(name.dropFirst())
        }
        return name
    }

    /// The librarian's holding shelves (Needs Filing, Archive Intake,
    /// anything ending "(Review)").
    static func isHolding(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return n == "needs filing" || n == "archive intake" || n.hasSuffix("(review)")
    }

    /// 0 ordinary; then Undated, Multiple decades, "Other ...", and Not filed yet last.
    private static func tailRank(_ name: String) -> Int {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n == notFiled.lowercased() { return 4 }
        if n == "undated" || n.hasPrefix("undated,") { return 1 }
        if n == "multiple decades" || n.hasPrefix("multiple decades,") { return 2 }
        if n == "other" || n.hasPrefix("other ") { return 3 }
        return 0
    }

    /// The one order a shelf list uses: capitals ignored, numbers in number
    /// order (so decades run oldest first), the tail names last.
    static func inOrder(_ a: String, _ b: String) -> Bool {
        let ra = tailRank(a), rb = tailRank(b)
        if ra != rb { return ra < rb }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Words for the repeat check: case, punctuation and leading zeros ignored.
    private static func words(_ s: String) -> Set<String> {
        let parts = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(parts.map { part -> String in
            let text = String(part)
            guard text.allSatisfy({ $0.isNumber }) else { return text }
            let trimmed = text.drop(while: { $0 == "0" })
            return trimmed.isEmpty ? "0" : String(trimmed)
        })
    }

    /// "Ozarks, Radio Airchecks" for a shelf that holds only one shelf,
    /// leaving out a name that only repeats the one before it.
    static func chain(_ parent: String, _ child: String) -> String {
        let kid = words(child)
        if !kid.isEmpty && kid.isSubset(of: words(parent)) { return parent }
        return parent + ", " + child
    }

    /// A shelf name that means little without the shelf it sits on: a
    /// decade or a year, Undated, Multiple decades, a season, and (Part 296)
    /// a letter shelf, so the described films' "A" screen is titled
    /// "Described audio movies, A".
    static func needsPlace(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n == "undated" || n == "multiple decades" { return true }
        if n == "0-9" || n == "numbers" { return true }
        if n.count == 1, let c = n.first, c.isLetter { return true }
        if n.range(of: #"^\d{4}s?$"#, options: .regularExpression) != nil { return true }
        return n.range(of: #"^season \d+"#, options: .regularExpression) != nil
    }

    /// A row as pushed from the shelf titled `parent`: a name that says too
    /// little on its own gets the parent's name in its screen title.
    static func placed(_ ref: LibraryShelfRef, under parent: String) -> LibraryShelfRef {
        guard ref.screenTitle == nil, !parent.isEmpty, needsPlace(ref.title) else { return ref }
        var copy = ref
        copy.screenTitle = parent + ", " + ref.title
        return copy
    }

    /// Whether a row ends "donated by": never for your own items, never for
    /// the library owner's (almost every item in the archive is hers).
    static func showsDonor(_ item: RRItem, me: String) -> Bool {
        guard let d = item.ownerName, !d.isEmpty else { return false }
        if !me.isEmpty, item.owner == me { return false }
        return item.fromLibraryOwner != true
    }

    /// What VoiceOver says for an item row: title, type, length, where it
    /// sits on a small shelf listed whole, "described".
    static func spokenRow(_ item: RRItem, me: String, place: String) -> String {
        var bits: [String] = [item.title]
        if let a = item.author, !a.isEmpty { bits.append("by \(a)") }
        bits.append(item.typeWord)
        let len = length(of: item)
        if !len.isEmpty { bits.append(len) }
        if let sub = item.sub, !sub.isEmpty { bits.append(sub) }
        if item.described == true { bits.append("described") }
        if let p = item.progress, p.finished != true, let w = p.where_, !w.isEmpty { bits.append((item.isAudio ? "part " : "chapter ") + w) }
        if showsDonor(item, me: me), let d = item.ownerName { bits.append("donated by \(d)") }
        if item.state == "pending" { bits.append("no recordings yet") }
        if place == "mine", !item.shared, item.state != "pending" { bits.append("private") }
        return bits.joined(separator: ", ")
    }

    /// The same, for the row's second line on screen.
    static func detailLine(_ item: RRItem, me: String, place: String) -> String {
        var bits: [String] = []
        if let a = item.author, !a.isEmpty { bits.append("by \(a)") }
        bits.append(item.typeWord)
        let len = length(of: item)
        if !len.isEmpty { bits.append(len) }
        if let sub = item.sub, !sub.isEmpty { bits.append(sub) }
        if item.described == true { bits.append("described") }
        if let p = item.progress, p.finished != true, let w = p.where_, !w.isEmpty { bits.append((item.isAudio ? "part " : "chapter ") + w) }
        if showsDonor(item, me: me), let d = item.ownerName { bits.append("donated by \(d)") }
        if item.state == "pending" { bits.append("no recordings yet") }
        if place == "mine", !item.shared, item.state != "pending" { bits.append("private") }
        return bits.joined(separator: " · ")
    }
}

// MARK: - A load cut short

/// SwiftUI cancels a screen's `.task` when the screen leaves the display: a
/// push on top of it (a shelf opened before this one's items arrived) or a
/// switch to another tab. A load cut short that way is never an error to show
/// her ("cancelled", with a Try again row pushed in under the heading); the
/// screen loads again when it comes back.
enum LibraryLoad {
    static func cancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return Task.isCancelled
    }
}

// MARK: - Shelf rows from the tree, or from /archive

enum LibraryShelfRules {
    /// Rows for a tree node's children, in the server's order (the server
    /// already applied every display rule). Empty shelves never show.
    static func rows(_ nodes: [RRTreeNode], scope: String) -> [LibraryShelfRef] {
        nodes.filter { $0.count > 0 }.map { ref(for: $0, scope: scope) }
    }

    static func ref(for node: RRTreeNode, scope: String) -> LibraryShelfRef {
        LibraryShelfRef(id: node.id, title: node.name, path: node.path, scope: scope, count: node.count,
                        flat: node.flat, medium: node.medium, members: [])
    }

    /// Rows for an older server's /archive folders, tidied on the phone:
    /// empty shelves hidden, names tidied, capitals ignored in the order,
    /// decades oldest first, and the librarian's holding shelves gathered
    /// into one "Not filed yet" row at the end. Display only.
    static func rows(fromFolders folders: [RRFolder], parent: String, scope: String, gather: Bool = true) -> [LibraryShelfRef] {
        var shelves: [LibraryShelfRef] = []
        var holding: [LibraryShelfRef] = []
        for folder in folders where folder.count > 0 {
            let ref = LibraryShelfRef(id: folder.path, title: LibraryWords.tidy(folder.name), path: folder.path, scope: scope,
                                      count: folder.count, flat: folder.count <= 20)
            if gather && LibraryWords.isHolding(folder.name) { holding.append(ref) } else { shelves.append(ref) }
        }
        shelves.sort { LibraryWords.inOrder($0.title, $1.title) }
        if !holding.isEmpty {
            holding.sort { LibraryWords.inOrder($0.title, $1.title) }
            let total = holding.reduce(0) { $0 + ($1.count ?? 0) }
            shelves.append(LibraryShelfRef(id: "#not-filed/" + parent, title: LibraryWords.notFiled, path: "", scope: scope,
                                           count: total, flat: false, members: holding))
        }
        return shelves
    }
}

// MARK: - What a row can do besides open

/// Everything an item row offers in the Actions rotor and on a long press
/// (her Sep 25 word), shared by every Library list. One per screen; the
/// screen hosts its dialogs with `.libraryRowActions(_:)`.
@MainActor
final class LibraryRowActions: ObservableObject {
    let service: ReadingRoomService
    @Published var showLibrarian = false
    @Published private(set) var librarianAgentId: String?
    @Published private(set) var librarianDraft: String?
    @Published private(set) var openingLibrarian = false
    @Published var collecting: RRItem?
    @Published var showCollections = false
    @Published private(set) var collections: [RRCollectionRow] = []
    @Published var moving: RRItem?
    @Published var moveTo = ""
    @Published var deleting: RRItem?
    /// Bumped after a move or a delete, so the screen reloads what it shows.
    @Published private(set) var changes = 0

    init(service: ReadingRoomService) { self.service = service }

    var me: String { service.shelf?.me ?? "" }
    var librarian: Bool { service.shelf?.librarian ?? false }
    func canManage(_ item: RRItem) -> Bool { librarian || (!me.isEmpty && item.owner == me) }
    func isMine(_ item: RRItem) -> Bool { !me.isEmpty && item.owner == me }

    /// Opens Mrs. Witherspoon in the usual chat, on top of this screen.
    func talkToLibrarian(about itemId: String? = nil) async {
        guard !openingLibrarian else { return }
        openingLibrarian = true
        defer { openingLibrarian = false }
        do {
            let guide = try await service.librarianGuide()
            guard guide.agentId.hasPrefix("agent_") else {
                say("The librarian is unavailable right now. Please try again.")
                return
            }
            LibraryNowPlaying.shared.player?.pause()
            librarianAgentId = guide.agentId
            librarianDraft = itemId.map { "Tell me about the Library item with catalog ID \($0)." }
            showLibrarian = true
        } catch {
            say("Could not open the librarian. \(error.localizedDescription)")
        }
    }

    /// "Add to a collection" without opening the item.
    func collect(_ item: RRItem) async {
        do {
            let c = try await service.collections()
            var mine = c.mine
            if mine.isEmpty {
                let made = try await service.newCollection("My collection")
                mine = [made]
            }
            collections = mine
            collecting = item
            showCollections = true
        } catch { say(error.localizedDescription) }
    }

    func add(_ item: RRItem, to c: RRCollectionRow) async {
        collecting = nil
        do {
            try await service.addToCollection(c.id, book: item.id, track: 0)
            say("Added \(item.title) to \(c.title).")
        } catch { say(error.localizedDescription) }
    }

    /// Moves one item to another folder (the librarian's or the owner's tool, asked for by her press).
    func move() async {
        guard let item = moving else { return }
        moving = nil
        let to = moveTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return }
        do {
            let n = try await service.batch(ids: [item.id], action: "move", to: to)
            say(n > 0 ? "Moved \(item.title) to \(to)." : "Nothing was moved.")
            changes += 1
        } catch { say(error.localizedDescription) }
    }

    func delete(_ item: RRItem) async {
        do {
            _ = try await service.batch(ids: [item.id], action: "delete")
            say("Deleted \(item.title).")
            changes += 1
        } catch { say(error.localizedDescription) }
    }

    private func say(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// Hosts a screen's row-action dialogs, each on a view of its own (never two
/// presentations on one view, the build-121 rule), and the librarian's chat.
private struct LibraryRowActionsHost: ViewModifier {
    @ObservedObject var actions: LibraryRowActions

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $actions.showLibrarian) {
                if let agentId = actions.librarianAgentId {
                    ConversationDetailView(conversation: nil, initialAgentId: agentId, initialDraft: actions.librarianDraft)
                }
            }
            .background {
                Color.clear
                    .confirmationDialog("Add \(actions.collecting?.title ?? "it") to which collection?", isPresented: $actions.showCollections, titleVisibility: .visible) {
                        ForEach(actions.collections) { c in
                            Button(c.title) { if let item = actions.collecting { Task { await actions.add(item, to: c) } } }
                        }
                        Button("Cancel", role: .cancel) { actions.collecting = nil }
                    }
            }
            .background {
                Color.clear
                    .alert("Move \(actions.moving?.title ?? "it") to", isPresented: Binding(get: { actions.moving != nil }, set: { if !$0 { actions.moving = nil } })) {
                        TextField("Folder, like Video/Commercials", text: $actions.moveTo)
                        Button("Move") { Task { await actions.move() } }
                        Button("Cancel", role: .cancel) { actions.moving = nil }
                    }
            }
            .background {
                Color.clear
                    // Delete is one flick away in the rotor, so it asks first.
                    .confirmationDialog("Delete \(actions.deleting?.title ?? "this") from the library?", isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }), titleVisibility: .visible) {
                        Button("Delete it", role: .destructive) {
                            if let d = actions.deleting { actions.deleting = nil; Task { await actions.delete(d) } }
                        }
                        Button("Cancel", role: .cancel) { actions.deleting = nil }
                    } message: { Text("It is removed for everyone, and this cannot be undone.") }
            }
    }
}

extension View {
    func libraryRowActions(_ actions: LibraryRowActions) -> some View {
        modifier(LibraryRowActionsHost(actions: actions))
    }
}

// MARK: - One item row, the same in every list

struct LibraryItemRow: View {
    let item: RRItem
    /// "archive" (a shelf or a list) or "mine" (My uploads).
    var place: String = "archive"
    let actions: LibraryRowActions
    /// "Remove from this list" (Recently opened).
    var remove: (() -> Void)? = nil
    @Environment(\.kadeNavigation) private var nav
    @ObservedObject private var describedVideo = DescribedVideoAccess.shared

    var body: some View {
        Button {
            nav.pushLibrary(.item(LibraryItemRoute(id: item.id, title: item.title)))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                LibraryJacket(kind: item.kind, category: item.category, title: item.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline)
                    Text(LibraryWords.detailLine(item, me: actions.me, place: place)).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel(LibraryWords.spokenRow(item, me: actions.me, place: place))
        .accessibilityHint(item.state == "pending" ? "Opens it; add recordings from its page." : "Opens the player.")
        .contextMenu { rowActions }
        .accessibilityActions { rowActions }
    }

    @ViewBuilder
    private var rowActions: some View {
        Button("Ask the librarian about this") { Task { await actions.talkToLibrarian(about: item.id) } }
        if item.kind == "video" && describedVideo.allowed {
            Button("Make a described copy") { nav.open(.describedVideo(DescribedVideoStart(book: item.id, track: 0))) }
        }
        Button("Add to a collection") { Task { await actions.collect(item) } }
        if place == "mine", item.isAudio, actions.isMine(item) {
            Button("Add recordings") { nav.pushLibrary(.item(LibraryItemRoute(id: item.id, title: item.title, addRecordings: true))) }
        }
        if actions.canManage(item) {
            Button("Move to another folder") { actions.moveTo = item.path ?? ""; actions.moving = item }
            Button("Delete from the library", role: .destructive) { actions.deleting = item }
        }
        if let remove {
            Button("Remove from this list") { remove() }
        }
    }
}

/// A shelf row: "Cars and Trucks, 956 items". A real screen push, so Back
/// at the top left returns here.
struct LibraryShelfRow: View {
    let shelf: LibraryShelfRef

    var body: some View {
        NavigationLink(value: HomeRoute.library(.shelf(shelf))) {
            HStack(spacing: 12) {
                Image(systemName: shelf.isGroup || shelf.id.hasPrefix("#") ? "tray.full" : "folder")
                    .foregroundStyle(.brown)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(shelf.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let n = shelf.count {
                    Text(n.formatted()).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityLabel(shelf.spoken)
    }
}

// MARK: - Where each route goes

/// Builds a Library route's screen (ContentView's `destination` hands every
/// `.library` route here).
struct LibraryDestination: View {
    let route: LibraryRoute
    let apiClient: KadeAPIClient

    var body: some View {
        switch route {
        case .shelf(let ref):
            LibraryShelfScreen(apiClient: apiClient, shelf: ref)
        case .item(let item):
            // Another item can take the top player's place (ContentView's
            // pushLibrary); the id makes that a fresh screen that opens it,
            // never the old screen's state still showing the old item.
            ReadingRoomView(apiClient: apiClient, item: item).id(item)
        case .collection(let row):
            LibraryCollectionScreen(apiClient: apiClient, row: row)
        case .page(let page):
            switch page {
            case .search: LibrarySearchScreen(apiClient: apiClient)
            case .recentlyAdded: LibraryRecentScreen(apiClient: apiClient)
            case .recentlyOpened: LibraryOpenedScreen(apiClient: apiClient)
            case .collections: LibraryCollectionsScreen(apiClient: apiClient)
            case .add: ReadingRoomView(apiClient: apiClient)
            }
        }
    }
}
