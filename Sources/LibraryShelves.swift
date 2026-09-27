import Foundation
import SwiftUI

/// THE LIBRARY'S SHELVES, ALL AT ONCE (Part 296, Sep 27 2026).
///
/// Kade: "the fact that it takes a minute to load things so it gives
/// misleading item counts at the beginning ... I just feel like I'm getting
/// lost in a stack of shelves and a maze of folders."
///
/// The fork's `GET /api/kade/reading-room/tree` answers, in one call, every
/// shelf this seat can see with its honest item count (kadeReadingRoomTree.js
/// on the fork applies the display rules: empty shelves hidden, a shelf that
/// holds only one shelf skipped, small shelves listed whole, holding shelves
/// gathered into "Not filed yet", Springfield and the Ozarks on one screen).
/// The phone keeps the public tree here, and a copy on disk, so the first
/// screen has its counts the moment it opens next time.
///
/// An older server has no tree (404). Then each shelf asks `/archive` for its
/// own level as before, and `LibraryShelfRules` tidies what comes back on the
/// phone. Nothing in the library is ever moved or renamed by any of this.

// MARK: - Wire shapes

/// One shelf in the tree. Every field is optional on the wire, so a server
/// that sends a little less still decodes.
struct RRTreeNode: Decodable, Sendable {
    /// Unique key: the real path, or "#..." for a gathered row.
    let id: String
    let name: String
    /// The real (deepest) shelf to pass to /archive; empty on a gathered row.
    let path: String
    /// Every item underneath.
    let count: Int
    /// Items sitting on `path` itself, when the server says.
    let direct: Int?
    /// List everything under it at once (/archive?deep=1).
    let flat: Bool
    /// A gathered row ("Not filed yet", "Springfield and the Ozarks").
    let isVirtual: Bool
    /// "video" or "audio" on the Springfield rows.
    let medium: String?
    let children: [RRTreeNode]

    private enum Keys: String, CodingKey { case id, name, path, count, direct, flat, children, medium
        case isVirtual = "virtual"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let path = (try? c.decode(String.self, forKey: .path)) ?? ""
        let name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.path = path
        self.name = name.isEmpty ? (path.split(separator: "/").last.map(String.init) ?? "Untitled shelf") : name
        let key = (try? c.decode(String.self, forKey: .id)) ?? ""
        id = key.isEmpty ? (path.isEmpty ? "#" + name : path) : key
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
        direct = try? c.decode(Int.self, forKey: .direct)
        flat = (try? c.decode(Bool.self, forKey: .flat)) ?? false
        isVirtual = ((try? c.decode(Bool.self, forKey: .isVirtual)) ?? false) || path.isEmpty
        medium = try? c.decode(String.self, forKey: .medium)
        children = (try? c.decode([RRTreeNode].self, forKey: .children)) ?? []
    }

    /// Items on the shelf itself: the server's number, else what the
    /// children leave over.
    var directCount: Int {
        if let direct { return max(0, direct) }
        if isVirtual { return 0 }
        return max(0, count - children.reduce(0) { $0 + $1.count })
    }
}

struct RRTreePending: Decodable, Sendable {
    let uploading: Int?
    let stalled: Int?
}

/// The whole tree for one scope ("public" or "mine").
struct RRTree: Decodable, Sendable {
    let roots: [RRTreeNode]
    /// Springfield and the Ozarks, gathered; nil outside the family library.
    let local: RRTreeNode?
    let total: Int?
    let pending: RRTreePending?

    private enum Keys: String, CodingKey { case roots, children, tree, local, total, pending }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let r = try? c.decode([RRTreeNode].self, forKey: .roots) {
            roots = r
        } else if let r = try? c.decode([RRTreeNode].self, forKey: .children) {
            roots = r
        } else if let r = try? c.decode([RRTreeNode].self, forKey: .tree) {
            roots = r
        } else if let t = try? c.decode(RRTreeNode.self, forKey: .tree) {
            roots = t.children
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "No shelves in the tree."))
        }
        local = try? c.decode(RRTreeNode.self, forKey: .local)
        total = try? c.decode(Int.self, forKey: .total)
        pending = try? c.decode(RRTreePending.self, forKey: .pending)
    }

    /// One of the three first-screen shelves (Videos, Audio, Books).
    func root(_ name: String) -> RRTreeNode? {
        let wanted = name.lowercased()
        let singular = wanted.hasSuffix("s") ? String(wanted.dropLast()) : wanted
        return roots.first { node in
            let p = node.path.lowercased()
            let n = node.name.lowercased()
            return p == wanted || n == wanted || p == singular || n == singular
        }
    }
}

// MARK: - The calls

extension ReadingRoomService {
    /// The tree's raw bytes (kept on disk as they came), or nil when this
    /// server has no tree route.
    func libraryTreeData(scope: String) async throws -> Data? {
        let req = client.request(path: "api/kade/reading-room/tree", authorized: true, queryItems: [URLQueryItem(name: "scope", value: scope)], timeout: 60)
        let (data, http) = try await client.send(req)
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw RRError(message: "The library answered \(http.statusCode).") }
        return data
    }

    /// The newest items in the library, or nil when this server has no
    /// such list yet.
    func recentItems() async throws -> [RRItem]? {
        struct Recent: Decodable { let items: [RRItem] }
        let req = client.request(path: "api/kade/reading-room/recent", authorized: true, timeout: 60)
        let (data, http) = try await client.send(req)
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw RRError(message: "The library answered \(http.statusCode).") }
        // A 200 that is not the list is the live server's web page for an
        // address it does not know yet: no such list, not an error to read out.
        return (try? JSONDecoder().decode(Recent.self, from: data))?.items
    }
}

// MARK: - The store

@MainActor
final class LibraryShelves: ObservableObject {
    static let shared = LibraryShelves()

    /// The public tree (every shelf the family library shows this seat).
    @Published private(set) var publicTree: RRTree?
    /// This seat's own uploads, asked for when My uploads opens.
    @Published private(set) var mineTree: RRTree?
    /// The server has no tree route: each shelf asks /archive instead.
    @Published private(set) var treeUnsupported = false
    /// Without a tree: the first level of /archive, for the three counts on
    /// the first screen.
    @Published private(set) var rootFolders: [RRFolder]?
    /// The last load failed and nothing was ever shown (said in place of a count).
    @Published private(set) var failed = false

    private var publicIndex: [String: RRTreeNode] = [:]
    private var mineIndex: [String: RRTreeNode] = [:]
    private var loadedAt: [String: Date] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var triedDisk = false

    func tree(_ scope: String) -> RRTree? { scope == "mine" ? mineTree : publicTree }

    /// A shelf by its tree id ("Videos/Commercials", "#local", "#not-filed/Videos").
    func node(_ id: String, scope: String) -> RRTreeNode? {
        guard !id.isEmpty else { return nil }
        return scope == "mine" ? mineIndex[id] : publicIndex[id]
    }

    /// True once there is nothing more to wait for before a shelf can show
    /// its level: the tree is here, or the server has none.
    func settled(_ scope: String) -> Bool { tree(scope) != nil || treeUnsupported }

    /// Loads (or refreshes) one scope's tree. Waits for a load already on its
    /// way instead of starting a second one; skips a fresh tree unless forced.
    func refresh(_ service: ReadingRoomService, scope: String = "public", force: Bool = false) async {
        if scope == "public" && publicTree == nil && !triedDisk {
            triedDisk = true
            await readDisk()
        }
        if let task = running[scope] {
            await task.value
            return
        }
        if !force, let at = loadedAt[scope], Date().timeIntervalSince(at) < 120 { return }
        let task = Task { @MainActor in await self.fetch(service, scope: scope) }
        running[scope] = task
        await task.value
        running[scope] = nil
    }

    /// Forgets everything (sign-out), on disk too, so the next person to
    /// sign in never hears this one's shelves.
    func reset() {
        for task in running.values { task.cancel() }
        running = [:]
        publicTree = nil
        mineTree = nil
        publicIndex = [:]
        mineIndex = [:]
        loadedAt = [:]
        rootFolders = nil
        treeUnsupported = false
        failed = false
        triedDisk = true
        UserDefaults.standard.removeObject(forKey: LibraryWords.hasLocalKey)
        if let url = Self.diskURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: private

    private func fetch(_ service: ReadingRoomService, scope: String) async {
        do {
            // No tree route (404), or a 200 that is not a tree: the live
            // server today answers an unknown address with its web page, so
            // both mean "ask /archive", and the first screen's three counts
            // come from its first level (never "loading" for ever).
            let data = try await service.libraryTreeData(scope: scope)
            let decoded: RRTree?
            if let data { decoded = await Self.decode(data) } else { decoded = nil }
            guard let data, let tree = decoded else {
                noTree()
                if scope == "public" {
                    let page = try await service.archive(path: "", page: 0)
                    rootFolders = page.folders
                }
                loadedAt[scope] = Date()
                failed = false
                return
            }
            treeUnsupported = false
            failed = false
            apply(tree, scope: scope)
            loadedAt[scope] = Date()
            if scope == "public" { Self.writeDisk(data) }
        } catch {
            if tree(scope) == nil && rootFolders == nil { failed = true }
        }
    }

    private func noTree() {
        treeUnsupported = true
        publicTree = nil
        mineTree = nil
        publicIndex = [:]
        mineIndex = [:]
    }

    private func apply(_ tree: RRTree, scope: String) {
        var index: [String: RRTreeNode] = [:]
        func add(_ node: RRTreeNode) {
            index[node.id] = node
            for kid in node.children { add(kid) }
        }
        // Springfield's rows first: one of them ("All local video") can share
        // its real path with the shelf under Video, and the shelf itself wins.
        if let local = tree.local { add(local) }
        for root in tree.roots { add(root) }
        if scope == "mine" {
            mineIndex = index
            mineTree = tree
        } else {
            publicIndex = index
            publicTree = tree
            UserDefaults.standard.set(tree.local != nil, forKey: LibraryWords.hasLocalKey)
        }
    }

    private func readDisk() async {
        guard let url = Self.diskURL, let data = try? Data(contentsOf: url) else { return }
        guard let tree = await Self.decode(data), publicTree == nil else { return }
        apply(tree, scope: "public")
    }

    private static func decode(_ data: Data) async -> RRTree? {
        await Task.detached(priority: .userInitiated) {
            try? JSONDecoder().decode(RRTree.self, from: data)
        }.value
    }

    private static var diskURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("library-shelves.json")
    }

    private static func writeDisk(_ data: Data) {
        guard let url = diskURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Upload progress for the whole Library (Part 296): the Add screen shows
/// it, and the first screen's Add row says it, wherever the upload started.
@MainActor
final class LibraryUploadState: ObservableObject {
    static let shared = LibraryUploadState()
    @Published var title: String?
    @Published var progress: Double?

    func reset() {
        title = nil
        progress = nil
    }
}
