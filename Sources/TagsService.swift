import Foundation

/// One saved bookmark tag from GET /api/tags. Verified live 2026-07-28:
/// the fork's conversationTag schema carries tag/description/count/position
/// (count is maintained server-side as conversations gain/lose the tag).
/// Everything but `tag` is optional on the wire — decode leniently so a
/// server-side schema tweak can never brick the Bookmarks screen.
struct KadeTag: Codable, Identifiable, Hashable {
    let tag: String
    var description: String? = nil
    var count: Int? = nil
    var position: Int? = nil

    var id: String { tag }

    /// What VoiceOver speaks for the row: name plus a real count when the
    /// server sent one ("Recipes, 3 conversations"), just the name when not.
    var spokenSummary: String {
        guard let count, count > 0 else { return tag }
        return "\(tag), \(count) conversation\(count == 1 ? "" : "s")"
    }
}

/// Bookmarks/tags — the native half of LibreChat's conversation tags
/// (July 28 2026, leftovers item 3). Same API the web uses, nothing custom:
/// GET/POST /api/tags, PUT/DELETE /api/tags/:tag, and
/// PUT /api/tags/convo/:conversationId with the conversation's FULL new tag
/// list. Tag names ride in the URL path for rename/delete, so they are
/// percent-encoded with a strict character set — "Road trip!" must not
/// 404 for want of an escaped space.
@MainActor
final class TagsService: ObservableObject {
    @Published private(set) var tags: [KadeTag] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let client: KadeAPIClient

    init(client: KadeAPIClient) {
        self.client = client
    }

    /// Path-segment encoding for tag names. `.urlPathAllowed` keeps "/"
    /// unescaped (it is a path DELIMITER set, not a segment set), and a
    /// tag named "a/b" would silently become two segments — so this
    /// starts from `.alphanumerics` and adds only unreserved marks.
    private static let segmentAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    private static func encodeSegment(_ tag: String) -> String {
        tag.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? tag
    }

    func loadTags() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/tags", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                // 404 = the user simply has no tags yet (the route 404s on
                // a null result) — an empty shelf, not an error.
                if http.statusCode == 404 { tags = []; return }
                throw URLError(.badServerResponse)
            }
            var decoded = try JSONDecoder().decode([KadeTag].self, from: data)
            decoded.sort { ($0.position ?? 0, $0.tag.lowercased()) < ($1.position ?? 0, $1.tag.lowercased()) }
            tags = decoded
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load your bookmarks. Pull to try again."
        }
    }

    /// Creates a tag shelf entry (no conversation attached yet). Returns
    /// true on success so callers can announce it.
    func createTag(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            var req = client.request(path: "api/tags", method: "POST", authorized: true)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["tag": trimmed])
            let (_, http) = try await client.send(req)
            guard http.statusCode == 200 else { return false }
            await loadTags()
            return true
        } catch {
            return false
        }
    }

    func renameTag(_ oldName: String, to newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return false }
        do {
            var req = client.request(
                path: "api/tags/\(Self.encodeSegment(oldName))",
                method: "PUT",
                authorized: true
            )
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["tag": trimmed])
            let (_, http) = try await client.send(req)
            guard http.statusCode == 200 else { return false }
            await loadTags()
            return true
        } catch {
            return false
        }
    }

    func deleteTag(_ name: String) async -> Bool {
        do {
            let req = client.request(
                path: "api/tags/\(Self.encodeSegment(name))",
                method: "DELETE",
                authorized: true
            )
            let (_, http) = try await client.send(req)
            guard http.statusCode == 200 else { return false }
            await loadTags()
            return true
        } catch {
            return false
        }
    }

    /// The tags currently on one conversation — read from the full convo
    /// record (GET /api/convos/:id carries `tags`; the list rows don't).
    func tagsForConversation(id: String) async -> [String] {
        do {
            let req = client.request(path: "api/convos/\(id)", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return [] }
            struct ConvoTags: Codable { var tags: [String]? }
            return (try? JSONDecoder().decode(ConvoTags.self, from: data))?.tags ?? []
        } catch {
            return []
        }
    }

    /// Replaces a conversation's tag list wholesale (that is the API's
    /// shape — PUT the full new list, additions and removals both).
    func setTags(_ newTags: [String], onConversation id: String) async -> Bool {
        do {
            var req = client.request(
                path: "api/tags/convo/\(id)",
                method: "PUT",
                authorized: true
            )
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["tags": newTags])
            let (_, http) = try await client.send(req)
            guard http.statusCode == 200 else { return false }
            await loadTags()   // counts changed
            return true
        } catch {
            return false
        }
    }

    /// Conversations carrying one tag — the server filters
    /// (GET /api/convos?tags=<name>), no client-side page crawling.
    func conversations(withTag tag: String, cursor: String?) async throws
        -> (conversations: [KadeConversation], nextCursor: String?)
    {
        var items = [URLQueryItem(name: "tags", value: tag)]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let req = client.request(path: "api/convos", authorized: true, queryItems: items)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Page: Codable {
            let conversations: [KadeConversation]
            let nextCursor: String?
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        return (page.conversations, page.nextCursor)
    }
}
