import Foundation

struct Fixture: Decodable, Identifiable { let id: String; let title: String }
var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
}
func page(_ ids: [String], next: String? = nil, total: Int = 80) -> LibraryBrowsePage<Fixture> {
    LibraryBrowsePage(items: ids.map { Fixture(id: $0, title: "Invented \($0)") }, total: total,
                      types: [LibraryBrowseFacet(_id: "newspaper", count: 80)],
                      decades: [LibraryBrowseFacet(_id: "1930s", count: 80)],
                      next: next, familyLibrary: true)
}

let json = Data(#"{"items":[{"id":"synthetic-item","title":"Invented newspaper"}],"total":1,"types":[{"_id":"newspaper","count":1}],"decades":[{"_id":"1930s","count":1}],"next":null,"familyLibrary":true}"#.utf8)
let decoded = try JSONDecoder().decode(LibraryBrowsePage<Fixture>.self, from: json)
check(decoded.items.first?.id == "synthetic-item" && decoded.total == 1, "existing item IDs and total decode without reminting")
check(decoded.types.first?.id == "newspaper" && decoded.types.first?.typeTitle == "Newspapers", "source-aware document types retain their returned IDs")
check(decoded.decades.first?.id == "1930s" && decoded.next == nil, "decade IDs and end-of-list cursor decode")
check(decoded.familyLibrary == true, "family scope metadata is only read from the server")
check(LibraryBrowseFacet(_id: "yearbook", count: 1).typeTitle == "Yearbooks", "yearbooks have their own source type")
check(LibraryBrowseFacet(_id: "newsletter", count: 1).typeTitle == "Newsletters", "newsletters have their own source type")

var query = LibraryBrowseQuery()
query.q = " Disney+ & Ozarks? "
query.kind = "text"; query.type = "newspaper"; query.decade = "1930s"; query.sort = "title"
query.path = "Audio/Ozarks (Springfield Area)"
let cursor = "opaque+cursor/with%characters=="
let values = Dictionary(uniqueKeysWithValues: query.queryItems(after: cursor).map { ($0.name, $0.value ?? "") })
check(values["q"] == "Disney+ & Ozarks?", "search trims outer whitespace without changing reserved characters")
check(values["kind"] == "text" && values["type"] == "newspaper" && values["decade"] == "1930s", "all three filters are sent under the exact API names")
check(values["sort"] == "title" && values["scope"] == "public", "sort and authorized catalog scope are explicit")
check(values["after"] == cursor && values["path"] == query.path, "cursor and path are passed verbatim as query items")
check(!query.queryItems().contains(where: { $0.name == "after" || $0.name == "page" }), "a fresh list has neither an old cursor nor an offset")
var components = URLComponents(string: "https://example.invalid/api/kade/reading-room/browse")!
components.queryItems = query.queryItems(after: cursor)
let escaped = LibraryBrowseQuery.preservingPluses(in: components.url!)
let encoded = URLComponents(url: escaped, resolvingAgainstBaseURL: false)!
check(encoded.percentEncodedQuery?.contains("%2B") == true && encoded.queryItems?.first(where: { $0.name == "after" })?.value == cursor,
      "literal plus signs survive HTTP query parsing, including inside an opaque cursor")
var bounded = LibraryBrowseQuery(); bounded.q = String(repeating: "x", count: 150)
check(bounded.queryItems().first?.value?.count == 120, "search follows the server's bounded text input")

var state = LibraryBrowsePaging<Fixture>()
let firstGeneration = state.reset(for: query)
check(state.accept(page(["one", "two", "two"], next: cursor), query: query, generation: firstGeneration), "first authorized page is accepted")
check(state.items.map(\.id) == ["one", "two"] && state.next == cursor, "duplicates cannot become duplicate VoiceOver stops")
check(state.types.first?.id == "newspaper" && state.decades.first?.id == "1930s", "first-page facets stay with that query")
check(!state.accept(page(["wrong"]), query: query, generation: firstGeneration, after: "foreign-cursor"), "a different page cursor cannot append")
check(state.accept(page(["two", "three"], next: "next-cursor"), query: query, generation: firstGeneration, after: cursor), "the exact next cursor appends")
check(state.items.map(\.id) == ["one", "two", "three"], "overlapping pages deduplicate while preserving catalog order")
check(!state.accept(page(["old"]), query: query, generation: firstGeneration, after: cursor), "a replayed earlier page cannot append twice")
check(state.accept(page(["four"], next: "next-cursor"), query: query, generation: firstGeneration, after: "next-cursor") && state.next == nil,
      "a server repeating its cursor cannot cause an endless More loop")

var audio = query; audio.kind = "audio"
let audioGeneration = state.reset(for: audio)
check(state.items.isEmpty && state.types.isEmpty && state.decades.isEmpty && state.next == nil, "changing format clears previous results, facets and cursor")
check(!state.accept(page(["old-text"]), query: query, generation: firstGeneration), "late text response cannot populate an audio filter")
check(!state.accept(page(["wrong-sort"]), query: query, generation: audioGeneration), "generation alone cannot bypass exact-query matching")
let returnedGeneration = state.reset(for: query)
check(!state.accept(page(["very-old"]), query: query, generation: firstGeneration), "returning to the same filters does not revive an old request")
check(state.accept(page([], next: "bad-empty-cursor", total: 0), query: query, generation: returnedGeneration) && state.next == nil,
      "a legitimate empty result has no pagination loop")
let invalidGeneration = state.reset(for: query)
check(!state.accept(page((1...61).map { String($0) }), query: query, generation: invalidGeneration), "oversized responses cannot silently violate the 60-item page")
check(!state.accept(page(["one"], total: -1), query: query, generation: invalidGeneration), "negative server totals are rejected")
var mine = query; mine.scope = "mine"
check(!state.accept(page(["private-old"]), query: mine, generation: invalidGeneration), "an upload-scope response cannot enter the Library scope")
check(mine.queryItems().first(where: { $0.name == "scope" })?.value == "mine", "own-upload scope remains available without changing server ACLs")
// Cached results survive leaving, but an unfinished More request does not.
var lease = LibraryBrowseMoreLease()
let oldMore = lease.reserve()!
check(lease.reserve() == nil, "rapid repeated More cannot replace the active request handle")
lease.cancel()
let newMore = lease.reserve()!
check(!lease.accepts(oldMore) && lease.accepts(newMore), "quick leave and return gives More a fresh identity even with the same cached list")
lease.finish(oldMore)
check(lease.accepts(newMore) && lease.reserve() == nil, "a canceled old defer cannot release a newer More request")
lease.finish(newMore)
check(lease.reserve() != nil, "only the current More completion re-enables pagination")
print("Library browse: \(checks) checks passed")
