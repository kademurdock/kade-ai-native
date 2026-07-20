import Foundation

/// The Matchmaker — native port of the web `/matchmaker` page (Kade,
/// session 17/18: "match maker... so many things"). Server contract read
/// straight off `api/server/routes/kadeMatchmaker.js` before any Swift was
/// written (same discipline as every other port in this app):
///
///   GET /api/kade/matchmaker   JWT.
///     -> 200 { agents: [{ id, name, description, category, avatar, tags:
///        [String] }] } — the published-to-marketplace roster only, each
///        agent pre-tagged server-side from its own name/description/
///        category (see the route's KEYWORD_TAGS/NAME_BOOSTS). Nothing is
///        stored, nothing costs anything — this is a single read; all
///        scoring happens locally, exactly like the web page does in its
///        own inline `<script>`.
///     -> 401/500 { error }
///
/// Scoring is deliberately NOT done server-side, so `MatchmakerView` mirrors
/// the web page's own scoring function exactly rather than inventing a
/// different one that could rank differently for the same answers.
@MainActor
final class MatchmakerService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    private struct Roster: Decodable { let agents: [MatchmakerAgent] }

    /// Returns the roster, or an empty array on failure — check
    /// `loadError` after awaiting this to tell "empty roster" apart from
    /// "load failed."
    func loadRoster() async -> [MatchmakerAgent] {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/kade/matchmaker", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = "Couldn't load the character roster. Try again."
                return []
            }
            let roster = try decoder.decode(Roster.self, from: data)
            guard !roster.agents.isEmpty else {
                loadError = "The character roster came back empty. Try again in a moment."
                return []
            }
            return roster.agents
        } catch {
            loadError = "Couldn't load the character roster. Try again."
            return []
        }
    }
}

/// One matchmaker-eligible agent. `tags` drive scoring — mirrors the web
/// page's own `agent.tags` array field for field; every field is always
/// present in the server's response (defaults to `''`/`[]` server-side,
/// never omitted), so none of these need to be optional.
struct MatchmakerAgent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let category: String
    let avatar: String
    let tags: [String]
}
