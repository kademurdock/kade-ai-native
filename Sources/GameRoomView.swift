import SwiftUI

/// The Game Room — see `GameRoomService` for the server contract and why
/// this leaderboard, specifically, was the missing piece (actually PLAYING
/// a game already works in any ordinary chat — see that file's doc
/// comment). Read-only: family standings, a couple of highlights, a
/// per-game breakdown, and a short recent-results feed — the same
/// sections the web page shows under "The Game Room," not a pixel-for-
/// pixel port of its table markup.
///
/// VoiceOver notes: every section is a real heading; every row is ONE
/// combined element (`.ignore` + an explicit constructed label) rather
/// than `.combine`, matching this app's standing rule after `.combine`
/// caused real narration bugs twice (see `HelpView`'s doc comment). Rows
/// have no natural unique id from the server (see `GameLeaderboard`'s doc
/// comment), so every `ForEach` here keys off `.enumerated()`/`\.offset`.
struct GameRoomView: View {
    @StateObject private var service: GameRoomService

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: GameRoomService(client: apiClient))
    }

    @State private var board: GameLeaderboard?
    @State private var hasLoaded = false

    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var a11yFocus: Focus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let error = service.loadError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityFocused($a11yFocus, equals: .status)
                } else if service.isLoading || !hasLoaded {
                    ProgressView("Loading the Game Room…")
                        .accessibilityLabel("Loading the Game Room")
                } else if let board {
                    summarySection(board)
                    if board.highlights.biggestBlackjack != nil || board.highlights.bestTrivia != nil {
                        highlightsSection(board.highlights)
                    }
                    if !board.players.isEmpty {
                        standingsSection(board.players)
                    }
                    if !board.games.isEmpty {
                        byGameSection(board.games)
                    }
                    if !board.recent.isEmpty {
                        recentSection(board.recent)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Game Room")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            board = await service.loadLeaderboard()
            hasLoaded = true
            if service.loadError != nil { a11yFocus = .status }
        }
    }

    private func summarySection(_ board: GameLeaderboard) -> some View {
        let intro = "Family bragging rights, straight from the Game Parlor's referee."
        let line = summaryLine(board)
        return VStack(alignment: .leading, spacing: 4) {
            Text(intro)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(line)
                .font(.subheadline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(intro) \(line)")
    }

    private func summaryLine(_ board: GameLeaderboard) -> String {
        if board.finished == 0 {
            return "No finished games yet — the board is wide open. Tell Deuce or Kiana \"deal me in\" and claim the first win."
        }
        let gameWord = board.finished == 1 ? "game" : "games"
        var line = "\(board.finished) finished \(gameWord) on the books"
        if let champ = board.players.first {
            let winWord = champ.wins == 1 ? "win" : "wins"
            let gamesWord = champ.played == 1 ? "game" : "games"
            line += " — \(champ.by) leads the family with \(champ.wins) \(winWord) across \(champ.played) \(gamesWord)."
        } else {
            line += "."
        }
        return line
    }

    private func highlightsSection(_ highlights: GameLeaderboard.Highlights) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Highlights")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if let bj = highlights.biggestBlackjack {
                let text = "Biggest Blackjack win: \(bj.by), \(bj.chips) chips."
                Text(text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            }
            if let trivia = highlights.bestTrivia {
                let text = "Best Trivia score: \(trivia.by), \(trivia.score) of \(trivia.total)."
                Text(text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            }
        }
    }

    private func standingsSection(_ players: [GameLeaderboard.PlayerRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Family standings")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(players.enumerated()), id: \.offset) { index, row in
                let text = "\(index + 1). \(row.by) — \(row.wins) won, \(row.losses) lost, \(row.draws) drawn, \(row.played) played."
                Text(text)
                    .font(.body)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            }
        }
    }

    private func byGameSection(_ games: [GameLeaderboard.GameSummary]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Game by game")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(games.enumerated()), id: \.offset) { _, game in
                let playWord = game.played == 1 ? "game" : "games"
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(game.name) — \(game.played) \(playWord) played")
                        .font(.headline)
                    ForEach(Array(game.rows.enumerated()), id: \.offset) { rowIndex, row in
                        let text = "\(rowIndex + 1). \(row.by) — \(row.w) won, \(row.l) lost, \(row.d) drawn."
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(text)
                    }
                }
            }
        }
    }

    private func recentSection(_ recent: [GameLeaderboard.RecentResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent results")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                let whenText = KadeDateFormatting.relative(from: item.when)
                let detailPart = item.detail.isEmpty ? "" : " — \(item.detail)"
                let base = "\(item.by) \(item.outcome) \(item.game)\(detailPart)"
                let text = base + (whenText.map { ", \($0)" } ?? "")
                Text(text)
                    .font(.body)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            }
        }
    }
}
