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

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()
    private var hasLoadedOnce = false

    init(client: KadeAPIClient) {
        self.client = client
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
        hasLoadedOnce = false
        loadError = nil
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
            agents = page.data.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            hasLoadedOnce = true
        } catch {
            loadError = "Couldn't load the agent list. Try again."
        }
    }
}
