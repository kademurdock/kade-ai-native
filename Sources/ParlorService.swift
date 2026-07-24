import Foundation
import AVFoundation

/// THE PARLOR, native half (July 24 2026 — Kade: "Can you make that native?
/// Like part of the native game parler? Before we push that next build").
/// Thin client over the fork's /api/kade/parlor routes — the SAME tables and
/// referee as chat, the phone line, and the web Parlor page. No LLM in the
/// mechanics; the engine's legal-move tokens render as SwiftUI buttons.
@MainActor
final class ParlorService: ObservableObject {
    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct GameOptions: Decodable {
        var opponents: [Int]?
        var rounds: [Int]?
        var difficulty: [String]?
        var category: [String]?
        var bet: [Int]?
        var clean: Bool?
        var seats: Int?
    }

    struct ParlorGame: Decodable, Identifiable, Hashable {
        var key: String
        var name: String
        var blurb: String
        var players: String
        var seatAware: Bool
        var usesChips: Bool
        var id: String { key }
        static func == (lhs: ParlorGame, rhs: ParlorGame) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
        var options: GameOptions?
    }

    struct Move: Decodable, Identifiable {
        var token: String
        var label: String
        var id: String { token }
    }

    struct Table: Decodable {
        var gameId: String
        var gameKey: String
        var name: String
        var status: String?
        var over: Bool
        var turnSeat: Int?
        var lines: [String]
        var legal: [Move]
        var legalHint: String?
        var names: [String]?
        var seatAgents: [String]?
        var historyCount: Int?
        var log: [String]?
        var sounds: [String]?
        // Phase 2 (party tables) — absent on solo tables.
        var party: Bool?
        var code: String?
        var seat: Int?
        var yourTurn: Bool?
        var turnName: String?
        var historyCursor: Int?
    }

    struct OpenTable: Decodable, Identifiable {
        var gameId: String
        var name: String
        var turns: Int
        var id: String { gameId }
    }

    struct TalkReply: Decodable {
        var name: String
        var line: String
    }

    private struct ServerError: Decodable { let error: String? }

    enum ParlorError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            if case .server(let m) = self { return m }
            return "The Parlor hiccuped."
        }
    }

    private func explain(_ data: Data, fallback: String) -> String {
        (try? decoder.decode(ServerError.self, from: data))?.error ?? fallback
    }

    func games() async throws -> [ParlorGame] {
        struct Wrapper: Decodable { let games: [ParlorGame] }
        let req = client.request(path: "api/kade/parlor/games", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ParlorError.server(explain(data, fallback: "Couldn't load the menu.")) }
        return try decoder.decode(Wrapper.self, from: data).games
    }

    func openTables() async -> [OpenTable] {
        struct Wrapper: Decodable { let active: [OpenTable]? }
        let req = client.request(path: "api/kade/my-tables", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200 else { return [] }
        return (try? decoder.decode(Wrapper.self, from: data))?.active ?? []
    }

    struct NewTableRequest {
        var game: String
        var opponents: Int?
        var agentSeats: [String] = []
        var rounds: Int?
        var difficulty: String?
        var category: String?
        var bet: Int?
        var clean: Bool?
        /// Phase 2: open seats friends can claim with the join code (0 = solo).
        var partyOpenSeats: Int = 0
    }

    func newTable(_ r: NewTableRequest) async throws -> Table {
        var body: [String: Any] = ["game": r.game]
        if r.partyOpenSeats > 0 { body["party_open_seats"] = r.partyOpenSeats }
        if !r.agentSeats.isEmpty { body["agent_seats"] = r.agentSeats }
        else if let o = r.opponents { body["opponents"] = o }
        if let v = r.rounds { body["rounds"] = v }
        if let v = r.difficulty, !v.isEmpty { body["difficulty"] = v }
        if let v = r.category, !v.isEmpty { body["category"] = v }
        if let v = r.bet { body["bet"] = v }
        if let v = r.clean { body["clean"] = v }
        return try await post(path: "api/kade/parlor/new", body: body, fallback: "Couldn't deal that table.")
    }

    /// Phase 2: take a seat at a friend's table by its 4-character code.
    func join(code: String) async throws -> Table {
        try await post(path: "api/kade/parlor/join", body: ["code": code], fallback: "No open table with that code.")
    }

    /// Phase 2: poll the shared table — YOUR view + everything said since `since`.
    func partyState(gameId: String, since: Int) async throws -> Table {
        let req = client.request(
            path: "api/kade/parlor/party-state/\(gameId)",
            authorized: true,
            queryItems: [URLQueryItem(name: "since", value: String(since))]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ParlorError.server(explain(data, fallback: "Couldn't read the table.")) }
        return try decoder.decode(Table.self, from: data)
    }

    /// Phase 2: play YOUR seat's move on a shared table.
    func partyMove(gameId: String, token: String) async throws -> Table {
        try await post(path: "api/kade/parlor/party-move/\(gameId)", body: ["move": token], fallback: "That move didn't go through.")
    }

    func state(gameId: String) async throws -> Table {
        let req = client.request(path: "api/kade/parlor/state/\(gameId)", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ParlorError.server(explain(data, fallback: "Couldn't read that table.")) }
        return try decoder.decode(Table.self, from: data)
    }

    func move(gameId: String, token: String) async throws -> Table {
        try await post(path: "api/kade/parlor/move/\(gameId)", body: ["move": token], fallback: "That move didn't go through.")
    }

    func talk(gameId: String, text: String, to: String?) async throws -> TalkReply {
        var body: [String: Any] = ["text": text]
        if let to, !to.isEmpty { body["to"] = to }
        var req = client.request(path: "api/kade/parlor/talk/\(gameId)", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ParlorError.server(explain(data, fallback: "No reply from the table.")) }
        return try decoder.decode(TalkReply.self, from: data)
    }

    func quit(gameId: String) async {
        var req = client.request(path: "api/kade/parlor/quit/\(gameId)", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        _ = try? await client.send(req)
    }

    func transcript(gameId: String) async -> String? {
        let req = client.request(path: "api/kade/parlor/log/\(gameId)", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func post(path: String, body: [String: Any], fallback: String) async throws -> Table {
        var req = client.request(path: path, method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ParlorError.server(explain(data, fallback: fallback)) }
        return try decoder.decode(Table.self, from: data)
    }
}

/// The house voice: a tiny dedicated narrator queue so the Parlor can speak
/// through ONE chosen voice (Kade's or Miss A's clones by default) without
/// touching VoiceService's per-agent read-aloud queue. Fail-soft: a clip
/// that won't fetch or play is simply skipped.
@MainActor
final class ParlorNarrator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Mode: String, CaseIterable, Identifiable {
        case events
        case everything
        case off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .events: return "Game events"
            case .everything: return "Everything (events + chatter)"
            case .off: return "Nothing — VoiceOver has it"
            }
        }
    }

    private let client: KadeAPIClient
    var voice: String = "Voice 466"
    var mode: Mode = .events

    private var queue: [String] = []
    private var player: AVAudioPlayer?
    private var pumping = false

    init(client: KadeAPIClient) {
        self.client = client
    }

    /// Queue narration for a batch of log lines, honoring the mode:
    /// character chatter ("<name> says: ...") only speaks in .everything.
    func narrate(_ lines: [String]) {
        guard mode != .off else { return }
        for line in lines {
            let isChatter = line.contains(" says: ")
            if isChatter && mode != .everything { continue }
            queue.append(line.replacingOccurrences(of: " says: ", with: " says, "))
        }
        if !pumping { Task { await pump() } }
    }

    func say(_ text: String) {
        guard mode != .off, !text.isEmpty else { return }
        queue.append(text)
        if !pumping { Task { await pump() } }
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        pumping = false
    }

    private var finishContinuation: CheckedContinuation<Void, Never>?

    private func pump() async {
        pumping = true
        while !queue.isEmpty {
            let text = queue.removeFirst()
            let fields: [(String, String)] = [("input", text), ("voice", voice)]
            let req = client.multipartRequest(path: "api/files/speech/tts/manual", authorized: true, fields: fields)
            guard let (data, http) = try? await client.send(req), http.statusCode == 200, !data.isEmpty else { continue }
            guard let p = try? AVAudioPlayer(data: data) else { continue }
            player = p
            p.delegate = self
            p.play()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                finishContinuation = c
            }
        }
        pumping = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finishContinuation?.resume()
            self.finishContinuation = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.finishContinuation?.resume()
            self.finishContinuation = nil
        }
    }
}

/// Table sound effects: the same clips the web pages play, fetched once from
/// the site and cached for the session. Fail-soft and fire-and-forget.
@MainActor
final class ParlorSounds {
    static let shared = ParlorSounds()
    private var cache: [String: Data] = [:]
    private var players: [AVAudioPlayer] = []

    func play(_ cues: [String], client: KadeAPIClient) {
        for (i, cue) in cues.prefix(6).enumerated() {
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(i) * 350_000_000)
                await self.playOne(cue, client: client)
            }
        }
    }

    private func playOne(_ cue: String, client: KadeAPIClient) async {
        var data = cache[cue]
        if data == nil {
            let req = client.request(path: "assets/sounds/\(cue).mp3")
            guard let (d, http) = try? await client.send(req), http.statusCode == 200, !d.isEmpty else { return }
            cache[cue] = d
            data = d
        }
        guard let data, let p = try? AVAudioPlayer(data: data) else { return }
        p.volume = 0.7
        p.play()
        players.append(p)
        if players.count > 8 { players.removeFirst(players.count - 8) }
    }
}
