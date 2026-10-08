import Foundation

struct LibraryBrowseQuery: Hashable {
    var q = ""
    var scope = "public"
    var kind = ""
    var type = ""
    var decade = ""
    var sort = "recent"
    var path = ""

    func queryItems(after: String? = nil) -> [URLQueryItem] {
        var values = [
            URLQueryItem(name: "q", value: String(q.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "kind", value: kind),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "decade", value: decade),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "path", value: path)
        ]
        if let after { values.append(URLQueryItem(name: "after", value: after)) }
        return values
    }

    /// Query parsers read a literal + as a space. Preserve titles such as
    /// Disney+ and leave an opaque cursor's bytes unchanged.
    static func preservingPluses(in url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = parts.percentEncodedQuery, query.contains("+") else { return url }
        parts.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        return parts.url ?? url
    }
}

struct LibraryBrowseFacet: Decodable, Identifiable, Hashable {
    let _id: String
    let count: Int
    var id: String { _id }

    var typeTitle: String {
        let names = ["book": "Books", "newspaper": "Newspapers", "newsletter": "Newsletters",
                     "yearbook": "Yearbooks", "audiobook": "Audiobooks", "commercials": "Commercials",
                     "radio": "Radio", "music": "Music", "movie": "Movies", "tv": "Television",
                     "cassette": "Cassettes", "vhs": "Home video", "psa": "Public service announcements",
                     "other": "Other"]
        return names[_id] ?? _id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct LibraryBrowsePage<Item: Decodable>: Decodable {
    let items: [Item]
    let total: Int
    let types: [LibraryBrowseFacet]
    let decades: [LibraryBrowseFacet]
    let next: String?
    let familyLibrary: Bool?
}

/// More owns one request independently of the cached list's generation.
/// Leaving may preserve that list, while invalidating the unfinished page.
struct LibraryBrowseMoreLease {
    private var active: UUID?
    mutating func reserve() -> UUID? {
        guard active == nil else { return nil }
        let lease = UUID()
        active = lease
        return lease
    }
    func accepts(_ lease: UUID) -> Bool { active == lease }
    mutating func finish(_ lease: UUID) { if accepts(lease) { active = nil } }
    mutating func cancel() { active = nil }
}

/// A cursor belongs to one exact query and one load. Returning to the same
/// filters does not make a response from an older load current again.
struct LibraryBrowsePaging<Item: Decodable & Identifiable> {
    private(set) var query = LibraryBrowseQuery()
    private(set) var generation = UUID()
    private(set) var items: [Item] = []
    private(set) var total: Int?
    private(set) var types: [LibraryBrowseFacet] = []
    private(set) var decades: [LibraryBrowseFacet] = []
    private(set) var next: String?

    mutating func reset(for query: LibraryBrowseQuery) -> UUID {
        self.query = query
        generation = UUID()
        items = []
        total = nil
        types = []
        decades = []
        next = nil
        return generation
    }

    @discardableResult
    mutating func accept(_ page: LibraryBrowsePage<Item>, query: LibraryBrowseQuery,
                         generation: UUID, after: String? = nil) -> Bool {
        guard self.query == query, self.generation == generation, page.total >= 0,
              page.items.count <= 60, after == nil || (after == next && next != nil) else { return false }
        var known = Set<Item.ID>()
        if after != nil { known = Set(items.map(\.id)) }
        let fresh = page.items.filter { known.insert($0.id).inserted }
        if after == nil {
            items = fresh
            types = page.types
            decades = page.decades
        } else {
            items.append(contentsOf: fresh)
        }
        total = page.total
        // A repeated cursor or empty page cannot create an endless More loop.
        next = page.items.isEmpty || page.next == after ? nil : page.next
        return true
    }
}
