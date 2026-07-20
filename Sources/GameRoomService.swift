import Foundation

/// The Game Room — native port of the web `/game-room` leaderboard (Kade,
/// session 17/18: "game room... family standings, records, and the latest
/// game results"). Server contract read straight off `api/server/routes/
/// kade.js`'s `GET /api/kade/game-leaderboard` before any Swift was
/// written.
///
/// Read-only and low-stakes by construction: this is a leaderboard over
/// games already played through ordinary chat. Actually PLAYING a game was
/// never a native gap in the first place — confirmed, not assumed, before
/// scoping this: the web client's own `GameTable.tsx` widget doc comment
/// states plainly "everything drawn here is ALREADY said in the agent's
/// message — this widget adds zero information... aria-hidden and
/// unfocusable," and this app's own `MessageTextSanitizer.stripGameSoundTags`
/// already strips the invisible `[table:id]` token those messages carry
/// (has since before this session — mirrors `gameSounds.ts` on purpose).
/// So "deal me in" to any companion, in an ordinary native chat, already
/// starts and plays a full game correctly; the ONLY thing genuinely
/// missing was this standings page, which is what this ships.
///
///   GET /api/kade/game-leaderboard   JWT.
///     -> 200 { finished, activeTables, players: [...], games: [...],
///        highlights: { biggestBlackjack, bestTrivia }, recent: [...] } —
///        exact field shapes: see `GameLeaderboard` below, named to match
///        the server's own JSON keys so no CodingKeys remapping is needed.
///     -> 401/500 { error }
@MainActor
final class GameRoomService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    func loadLeaderboard() async -> GameLeaderboard? {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/kade/game-leaderboard", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = "Couldn't load the Game Room. Try again."
                return nil
            }
            return try decoder.decode(GameLeaderboard.self, from: data)
        } catch {
            loadError = "Couldn't load the Game Room. Try again."
            return nil
        }
    }
}

/// Server never sends a per-row id (no userId reaches the client, by
/// design — see the route's own `firstName(d.user)`-only projection), and
/// two family members could plausibly share a first name, so rows here are
/// deliberately NOT `Identifiable` — every `ForEach` over these uses
/// `.enumerated()`/`id: \.offset` at the call site in `GameRoomView`
/// instead of a fragile "probably unique" string key.
struct GameLeaderboard: Decodable {
    let finished: Int
    let activeTables: Int
    let players: [PlayerRow]
    let games: [GameSummary]
    let highlights: Highlights
    let recent: [RecentResult]

    struct PlayerRow: Decodable {
        let by: String
        let wins: Int
        let losses: Int
        let draws: Int
        let played: Int
        let chips: Int
    }

    struct GameSummary: Decodable {
        let key: String
        let name: String
        let played: Int
        let rows: [GameRow]

        struct GameRow: Decodable {
            let by: String
            let w: Int
            let l: Int
            let d: Int
            let p: Int
        }
    }

    struct Highlights: Decodable {
        let biggestBlackjack: Blackjack?
        let bestTrivia: Trivia?

        struct Blackjack: Decodable {
            let by: String
            let chips: Int
            let when: String
        }
        struct Trivia: Decodable {
            let by: String
            let score: Int
            let total: Int
            let when: String
        }
    }

    struct RecentResult: Decodable {
        let by: String
        let game: String
        let outcome: String
        let detail: String
        let when: String
    }
}
