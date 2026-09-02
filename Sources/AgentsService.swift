import Foundation

/// One agent/character from GET /api/agents. Verified shape 2026-07-19 (see
/// docs/ENDPOINTS.md) — 221 agents on this account at verification time,
/// spanning many `category` values (companions, roleplay, personal, expert,
/// creative, ...). Only the fields this app actually displays are declared;
/// Codable ignores the rest (`_id`, `avatar`, `author`, `support_contact`,
/// `is_promoted`, `updatedAt`) automatically.
struct KadeAgent: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    /// Marketplace additions (July 28 2026) — all OPTIONAL so every existing
    /// consumer (picker, chat seeding, default-agent resolve) decodes exactly
    /// as before. `mongoId` (raw "_id") is what the permissions routes key
    /// publishing on; `author` gates the publish controls to your own
    /// creations; `avatar.filepath` is a site-relative image path.
    let mongoId: String?
    let author: String?
    let isPromoted: Bool?
    let avatar: KadeAgentAvatar?

    enum CodingKeys: String, CodingKey {
        case id, name, description, category, author, avatar
        case mongoId = "_id"
        case isPromoted = "is_promoted"
    }

    /// Lenient by hand: `id` and `name` stay strict (a row without them is
    /// genuinely unusable), everything else swallows odd/legacy shapes as
    /// nil — one weird avatar field on one agent must never fail the WHOLE
    /// roster decode (this list feeds the picker, chat seeding, and the
    /// Marketplace alike). Encode side stays compiler-synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
        category = try? c.decode(String.self, forKey: .category)
        mongoId = try? c.decode(String.self, forKey: .mongoId)
        author = try? c.decode(String.self, forKey: .author)
        isPromoted = try? c.decode(Bool.self, forKey: .isPromoted)
        avatar = try? c.decode(KadeAgentAvatar.self, forKey: .avatar)
    }
}

struct KadeAgentAvatar: Codable, Hashable {
    let filepath: String?
}

/// GET /api/agents response envelope. Verified shape 2026-07-19: the request
/// takes `cursor` as the query param name, but the response's own next-page
/// field is called `after` (not `nextCursor` like /api/convos) — easy to
/// mix up, so this is called out here rather than left implicit.
private struct AgentsPage: Codable {
    let data: [KadeAgent]
    let hasMore: Bool
    let after: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case after
    }
}

enum AgentsError: Error {
    case server(Int)
}

/// Fetches the list of agents/characters this account can talk to (GET
/// /api/agents), for the Phase 4 agent-switcher. Loaded once and cached for
/// the app session — re-fetching every time the picker sheet opens would
/// burn the shared pacing budget (see `KadeAPIClient`) for a list that
/// changes rarely mid-session.
@MainActor
final class AgentsService: ObservableObject {
    @Published private(set) var agents: [KadeAgent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    /// Aug 6 2026 (her ask: "pin the person's default agent at the top"):
    /// this user's most-talked-to companion ids, most first, from
    /// GET /api/kade/agent-default (conversation counts, server truth).
    /// Empty until loaded or on any failure — pickers just stay alphabetical.
    @Published private(set) var defaultAgentIds: [String] = []
    /// Build 261 (her ask, Sep 2 2026: "faving them or whatever"): the
    /// person's own starred characters, from LibreChat's
    /// `GET/POST /api/settings/favorites` — the same store the web's
    /// Favorites shelf reads, so a star on the phone shows on the web.
    @Published private(set) var favoriteIds: [String] = []

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()
    private var hasLoadedOnce = false

    private var changeObserver: NSObjectProtocol?

    init(client: KadeAPIClient) {
        self.client = client
        /* Part 116 (Sep 1 2026, build 260) — the cache learns about writes.
         * "Loaded once and cached for the app session" was fine until the
         * builder could CREATE characters: Amber A built Della on native and
         * her own picker did not show it until a force-quit. Any builder
         * write (create / save / delete / duplicate / share) posts
         * `AgentBuilderService.agentsChanged`; this drops the cache and
         * refetches, so the picker is right the next time it opens. */
        changeObserver = NotificationCenter.default.addObserver(
            forName: AgentBuilderService.agentsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    /// Drop the cached list and fetch again. Keeps the old rows on screen
    /// until the new ones land, so a picker that happens to be open never
    /// blinks empty.
    func refresh() async {
        hasLoadedOnce = false
        loadError = nil
        await loadIfNeeded()
    }

    /// Looked up by callers that only have an agentId (e.g. a conversation's
    /// stored `agent_id`, or the currently-selected agent in
    /// `ConversationDetailView`) and want a human-readable name to show.
    /// Returns nil if the list hasn't loaded yet or the id isn't in it —
    /// callers fall back to a generic label rather than blocking on this.
    func name(for agentId: String?) -> String? {
        guard let agentId else { return nil }
        return agents.first(where: { $0.id == agentId })?.name
    }

    /// Called on sign-out so the next sign-in never shows a stale/wrong-account list.
    func reset() {
        agents = []
        defaultAgentIds = []
        favoriteIds = []
        hasLoadedOnce = false
        loadError = nil
    }

    private struct FavoriteRow: Decodable { let agentId: String? }

    /// Fail-soft: a failed load leaves no stars, never an error surface.
    private func loadFavorites() async {
        do {
            let req = client.request(path: "api/settings/favorites", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return }
            let rows = try decoder.decode([FavoriteRow].self, from: data)
            favoriteIds = rows.compactMap { $0.agentId }
        } catch {
            // quiet by design
        }
    }

    func isFavorite(_ agentId: String) -> Bool { favoriteIds.contains(agentId) }

    /// Star or unstar. Sends the WHOLE list (that is the route's contract);
    /// updates locally first so the row flips at once, rolls back on failure.
    @discardableResult
    func toggleFavorite(_ agentId: String) async -> Bool {
        let before = favoriteIds
        var next = before
        if let i = next.firstIndex(of: agentId) { next.remove(at: i) } else { next.insert(agentId, at: 0) }
        favoriteIds = next
        var req = client.request(path: "api/settings/favorites", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["favorites": next.map { ["agentId": $0] }])
        if let (_, http) = try? await client.send(req), http.statusCode == 200 {
            return true
        }
        favoriteIds = before
        return false
    }

    private struct AgentDefaultResponse: Decodable {
        struct Row: Decodable { let agentId: String; let count: Int? }
        let top: [Row]
    }

    /// Fail-soft fetch of the most-talked-to list. Piggybacks on
    /// loadIfNeeded's lifecycle; a failure leaves the pin absent, never an
    /// error surface — the picker's alphabetical order is the fallback.
    private func loadDefaultAgents() async {
        do {
            let req = client.request(path: "api/kade/agent-default", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return }
            let parsed = try decoder.decode(AgentDefaultResponse.self, from: data)
            defaultAgentIds = parsed.top.map { $0.agentId }
        } catch {
            // quiet by design
        }
    }

    /// Loads once per sign-in; safe to call from every screen that needs the
    /// list (`ConversationDetailView.task` and `AgentPickerView.task` both
    /// call this) without triggering duplicate fetches — the `hasLoadedOnce`/
    /// `isLoading` guards make repeat calls a no-op.
    func loadIfNeeded() async {
        guard !hasLoadedOnce, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            // limit=1000 is the server's own hard cap (see docs/ENDPOINTS.md's
            // getListAgentsByAccess note) — one request covers this account's
            // real count (221 at verification time) with plenty of headroom.
            // Known simplification: if the account ever exceeds 1000 agents,
            // this silently shows only the first page rather than paginating
            // further — a flat picker sheet of 1000+ rows would need its own
            // redesign (grouping/search-only) before that limit matters.
            let req = client.request(
                path: "api/agents",
                authorized: true,
                queryItems: [URLQueryItem(name: "limit", value: "1000")]
            )
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { throw AgentsError.server(http.statusCode) }
            let page = try decoder.decode(AgentsPage.self, from: data)
            // July 27 2026: one agent appearing twice in the merged ACL list
            // would crash AgentPickerView's Dictionary(uniqueKeysWithValues:)
            // and poison every ForEach keyed by id -- de-dupe at the source,
            // first occurrence wins.
            var seenIds = Set<String>()
            agents = page.data.filter { seenIds.insert($0.id).inserted }.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            await loadDefaultAgents()
            await loadFavorites()
            hasLoadedOnce = true
        } catch {
            loadError = "Couldn't load the agent list. Try again."
        }
    }
}
