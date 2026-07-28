import Foundation

/// One prompt group from GET /api/prompts/groups (July 28 2026, leftovers
/// item 5 — the native prompts/presets library). A "group" is what a
/// person thinks of as one saved prompt: it has the name, the category,
/// the one-line description, and a pointer (`productionId`) at whichever
/// saved version is live. The version text itself comes from
/// GET /api/prompts/:promptId. Wire fields verified against the fork's
/// promptGroup schema + formatPromptGroupsResponse this same day.
struct KadePromptGroup: Codable, Identifiable, Hashable {
    let _id: String
    let name: String
    var oneliner: String? = nil
    var category: String? = nil
    var authorName: String? = nil
    var productionId: String? = nil
    var command: String? = nil

    var id: String { _id }

    /// Row subtitle: the oneliner when the author wrote one, else the
    /// category, else nothing — never an empty gray line.
    var subtitle: String? {
        if let o = oneliner, !o.trimmingCharacters(in: .whitespaces).isEmpty { return o }
        if let c = category, !c.trimmingCharacters(in: .whitespaces).isEmpty { return c }
        return nil
    }
}

/// One saved prompt version (the text itself).
struct KadePrompt: Codable {
    let _id: String
    let prompt: String
    var type: String? = nil
}

@MainActor
final class PromptsService: ObservableObject {
    @Published private(set) var groups: [KadePromptGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published var errorMessage: String?

    private var after: String?
    private let client: KadeAPIClient

    init(client: KadeAPIClient) {
        self.client = client
    }

    private struct GroupsPage: Codable {
        let promptGroups: [KadePromptGroup]
        var has_more: Bool? = nil
        var after: String? = nil
    }

    /// First page (optionally filtered by name — the server does the
    /// matching). Cursor-paginated; `loadMore()` continues.
    func loadGroups(name: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var items = [URLQueryItem(name: "limit", value: "25")]
            if let name, !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
            let req = client.request(path: "api/prompts/groups", authorized: true, queryItems: items)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let page = try JSONDecoder().decode(GroupsPage.self, from: data)
            groups = page.promptGroups
            hasMore = page.has_more ?? false
            after = page.after
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the prompt library. Pull to try again."
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let cursor = after, !cursor.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let items = [
                URLQueryItem(name: "limit", value: "25"),
                URLQueryItem(name: "cursor", value: cursor),
            ]
            let req = client.request(path: "api/prompts/groups", authorized: true, queryItems: items)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let page = try JSONDecoder().decode(GroupsPage.self, from: data)
            groups.append(contentsOf: page.promptGroups)
            hasMore = page.has_more ?? false
            after = page.after
        } catch {
            // Silent on scroll-more; the first-page error path covers the
            // "network is down" story and a retry is one flick away.
        }
    }

    /// The live text for a group (its production version).
    func promptText(for group: KadePromptGroup) async -> String? {
        guard let pid = group.productionId else { return nil }
        do {
            let req = client.request(path: "api/prompts/\(pid)", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return nil }
            return (try? JSONDecoder().decode(KadePrompt.self, from: data))?.prompt
        } catch {
            return nil
        }
    }

    /// Saves a new prompt (group + its first version in one call — the
    /// same POST /api/prompts shape the web builder sends).
    func createPrompt(name: String, text: String, category: String?, oneliner: String?) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedText.isEmpty else { return false }
        struct CreateBody: Codable {
            struct P: Codable { let prompt: String; let type: String }
            struct G: Codable { let name: String; var category: String? = nil; var oneliner: String? = nil }
            let prompt: P
            let group: G
        }
        do {
            var req = client.request(path: "api/prompts", method: "POST", authorized: true)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = CreateBody(
                prompt: .init(prompt: trimmedText, type: "text"),
                group: .init(
                    name: trimmedName,
                    category: category?.isEmpty == false ? category : nil,
                    oneliner: oneliner?.isEmpty == false ? oneliner : nil
                )
            )
            req.httpBody = try JSONEncoder().encode(body)
            let (_, http) = try await client.send(req)
            guard http.statusCode == 200 else { return false }
            await loadGroups()
            return true
        } catch {
            return false
        }
    }

    /// Deletes a whole group (the server cascades its versions). Only
    /// offered on groups the signed-in person owns — the server enforces
    /// it regardless; the UI just doesn't dangle a button that would 403.
    func deleteGroup(_ group: KadePromptGroup) async -> Bool {
        do {
            let req = client.request(
                path: "api/prompts/groups/\(group._id)",
                method: "DELETE",
                authorized: true
            )
            let (_, http) = try await client.send(req)
            guard http.statusCode == 200 else { return false }
            groups.removeAll { $0._id == group._id }
            return true
        } catch {
            return false
        }
    }
}
