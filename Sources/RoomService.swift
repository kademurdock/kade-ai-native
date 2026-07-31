import Foundation

/// The Debate & Roleplay Room — native port of the web `/debate-room` +
/// `/conversation-hall` pages (Kade, session 17/18: "Debait room too...").
/// Server contract read straight off `api/server/routes/kadeRoom.js` (475
/// lines, read end to end) before any Swift was written.
///
/// Plain request/response REST, no WebSocket — the web page itself strings
/// turns into rounds client-side by calling `POST .../next` repeatedly, not
/// through any live connection. That matters here: this is the same shape
/// of risk as Matchmaker/Game Room (ordinary `KadeAPIClient.send`, nothing
/// that needs a device to prove), NOT the shape of risk real-time calling
/// was (a raw duplex socket that genuinely couldn't be hand-verified).
///
///   GET  /api/kade/room/agents          -> { agents: [{id,name,
///                                        description(<=200 chars),avatar}] }
///                                        the castable roster: published
///                                        marketplace agents plus her own.
///   POST /api/kade/room                 body {topic, goals, agentIds:
///                                        [2-6 ids]} -> { room: RoomView }
///                                        (full, with an empty transcript)
///   GET  /api/kade/room                 -> { rooms: [RoomView] } (no
///                                        transcript field on these -- see
///                                        `lines` on `DebateRoom` instead)
///   GET  /api/kade/room/:id             -> { room: RoomView } (WITH
///                                        transcript, `lines` absent)
///   POST /api/kade/room/:id/say         body {text} -> { message: RoomLine }
///                                        -- success wraps the new line
///                                        under the key "message", NOT an
///                                        error string; only trust that on
///                                        a 200.
///   POST /api/kade/room/:id/next        body {} or {agentId} to force a
///                                        specific cast member -> 200
///                                        { message: RoomLine, nextIdx,
///                                        turnCount } | 402 (out of AI
///                                        budget, honest message) | 429
///                                        (300 turns/day cap) | 400 (room
///                                        full at 400 lines)
///   DELETE /api/kade/room/:id           -> { ok:true }
///   POST /api/kade/room/:id/share       body {share, title} -> {shared:
///                                        Bool}
///   GET  /api/kade/room/hall            -> { items: [HallItem] } -- 403
///                                        for child accounts, server-
///                                        enforced, nothing for the client
///                                        to gate itself.
///
/// Every error response on this route (not just some) uses the key
/// `message`, not `error` like Describe/Matchmaker -- confirmed by reading
/// every `res.status(...).json(...)` call in the file, not assumed from
/// one example.
@MainActor
final class RoomService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct RoomError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerMessage: Decodable { let message: String? }

    private func errorMessage(from data: Data, fallback: String) -> String {
        (try? decoder.decode(ServerMessage.self, from: data))?.message ?? fallback
    }

    // MARK: - Roster

    private struct AgentsResponse: Decodable { let agents: [RoomCastAgent] }

    func loadCastableAgents() async -> [RoomCastAgent] {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/kade/room/agents", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = errorMessage(from: data, fallback: "Couldn't load the character list.")
                return []
            }
            return try decoder.decode(AgentsResponse.self, from: data).agents
        } catch {
            loadError = "Couldn't load the character list. Try again."
            return []
        }
    }

    // MARK: - Rooms

    private struct RoomResponse: Decodable { let room: DebateRoom }
    private struct RoomsResponse: Decodable { let rooms: [DebateRoom] }

    func loadRooms() async -> [DebateRoom] {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/kade/room", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = errorMessage(from: data, fallback: "Couldn't load your rooms.")
                return []
            }
            return try decoder.decode(RoomsResponse.self, from: data).rooms
        } catch {
            loadError = "Couldn't load your rooms. Try again."
            return []
        }
    }

    func createRoom(topic: String, goals: String, agentIds: [String]) async throws -> DebateRoom {
        var req = client.request(path: "api/kade/room", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["topic": topic, "goals": goals, "agentIds": agentIds]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't create the room."))
        }
        return try decoder.decode(RoomResponse.self, from: data).room
    }

    func loadRoom(id: String) async throws -> DebateRoom {
        let req = client.request(path: "api/kade/room/\(id)", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't load that room."))
        }
        return try decoder.decode(RoomResponse.self, from: data).room
    }

    func deleteRoom(id: String) async throws {
        let req = client.request(path: "api/kade/room/\(id)", method: "DELETE", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't delete that room."))
        }
    }

    // MARK: - In-room actions

    private struct SayResponse: Decodable { let message: RoomLine }
    private struct NextTurnResponse: Decodable {
        let message: RoomLine
        let nextIdx: Int
        let turnCount: Int
    }

    func say(roomId: String, text: String) async throws -> RoomLine {
        var req = client.request(path: "api/kade/room/\(roomId)/say", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't post your message."))
        }
        return try decoder.decode(SayResponse.self, from: data).message
    }

    /// `forcedAgentId` nil means round-robin (the room's own `nextIdx`);
    /// pass a specific cast member's `agentId` to make them speak next
    /// regardless of whose turn it technically is -- mirrors the web
    /// page's own "interject between any two turns" design, not a native
    /// invention.
    private struct JobStart: Decodable { let jobId: String }

    /// Session 35 finale — ASYNC TURNS ("I want both"): start-and-poll,
    /// the architectural fix under every timeout band-aid. The start
    /// answers in a breath with a jobId; the server generates in the
    /// background with a FIVE-MINUTE model window (her philosophy:
    /// thinking gets room, waiting is fine); this polls every 2.5s until
    /// the turn lands. Old servers that answer the start with a plain 200
    /// still work — the sync decode is the graceful fallback, so this
    /// client never strands against an un-deployed fork.
    func nextTurn(roomId: String, forcedAgentId: String?, deepThink: Bool = false) async throws -> (line: RoomLine, nextIdx: Int, turnCount: Int) {
        var req = client.request(path: "api/kade/room/\(roomId)/next", method: "POST", authorized: true, timeout: 240)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["async": true]
        if let forcedAgentId { body["agentId"] = forcedAgentId }
        if deepThink { body["deepThink"] = true }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        if http.statusCode == 200 {
            // Pre-async server: the whole turn came back synchronously.
            let decoded = try decoder.decode(NextTurnResponse.self, from: data)
            return (decoded.message, decoded.nextIdx, decoded.turnCount)
        }
        guard http.statusCode == 202, let job = try? decoder.decode(JobStart.self, from: data) else {
            throw RoomError(message: errorMessage(from: data, fallback: "That turn failed — give it another try."))
        }
        // Poll. ~2.5s cadence, six-minute ceiling (the server's own window
        // is five; the extra minute absorbs queue-and-pacing time).
        let deadline = Date().addingTimeInterval(360)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled {
                throw RoomError(message: "Stopped.")
            }
            let statusReq = client.request(
                path: "api/kade/room/\(roomId)/next-status",
                authorized: true,
                queryItems: [URLQueryItem(name: "jobId", value: job.jobId)]
            )
            let (sData, sHttp) = try await client.send(statusReq)
            if sHttp.statusCode == 200 {
                struct Running: Decodable { let status: String }
                if let r = try? decoder.decode(Running.self, from: sData), r.status == "running" {
                    continue
                }
                let decoded = try decoder.decode(NextTurnResponse.self, from: sData)
                return (decoded.message, decoded.nextIdx, decoded.turnCount)
            }
            throw RoomError(message: errorMessage(from: sData, fallback: "That turn failed — give it another try."))
        }
        throw RoomError(message: "That turn is taking longer than six minutes — something's stuck. Try again.")
    }

    /// Session 35 part 3 (her ask: "add and remove agents"): edit the cast
    /// mid-room. Additions snapshot server-side exactly like create;
    /// removals keep the room at two or more; the server writes Narrator
    /// lines into the transcript so everyone -- humans and models -- knows
    /// who walked in or out. Returns the full updated room.
    func editCast(roomId: String, add: [String], remove: [String]) async throws -> DebateRoom {
        var req = client.request(path: "api/kade/room/\(roomId)/cast", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["add": add, "remove": remove])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't change the cast."))
        }
        return try decoder.decode(RoomResponse.self, from: data).room
    }

    /// Host opens/closes the party doors. Returns the updated room (with
    /// the minted code when opening).
    func setParty(roomId: String, enable: Bool) async throws -> DebateRoom {
        var req = client.request(path: "api/kade/room/\(roomId)/party", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["enable": enable])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't change party mode."))
        }
        return try decoder.decode(RoomResponse.self, from: data).room
    }

    /// Join someone's debate by its four-character code.
    func joinParty(code: String) async throws -> DebateRoom {
        var req = client.request(path: "api/kade/room/join-party", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't join that room."))
        }
        return try decoder.decode(RoomResponse.self, from: data).room
    }

    private struct ShareResponse: Decodable { let shared: Bool }

    func setShared(roomId: String, share: Bool, title: String) async throws -> Bool {
        var req = client.request(path: "api/kade/room/\(roomId)/share", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["share": share, "title": title])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw RoomError(message: errorMessage(from: data, fallback: "Couldn't share that room."))
        }
        return try decoder.decode(ShareResponse.self, from: data).shared
    }

    // MARK: - Conversation Hall

    private struct HallResponse: Decodable { let items: [HallItem] }

    /// Server returns 403 for a child account -- surfaced as an ordinary
    /// `loadError` string (the server's own message is already plain and
    /// non-alarming: "The Conversation Hall is for grown-up accounts."),
    /// not a special case the client needs its own copy for.
    func loadHall() async -> [HallItem] {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/kade/room/hall", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = errorMessage(from: data, fallback: "Couldn't load the Conversation Hall.")
                return []
            }
            return try decoder.decode(HallResponse.self, from: data).items
        } catch {
            loadError = "Couldn't load the Conversation Hall. Try again."
            return []
        }
    }
}

/// One character available to cast into a room -- the room-specific
/// roster from `GET /api/kade/room/agents` (published marketplace agents
/// plus her own), deliberately a DIFFERENT type from `KadeAgent`
/// (`/api/agents`, the full chat-switcher list) since the two endpoints
/// return different field sets for different purposes.
struct RoomCastAgent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let avatar: String
}

/// One agent actually seated in a room -- a snapshot taken at creation
/// time (name/avatar/voice), not a live reference back to `RoomCastAgent`.
struct RoomCastMember: Decodable, Hashable {
    let agentId: String
    let name: String
    let avatar: String
    let voiceId: String
    let rate: Double?
}

/// One transcript line. No natural unique id from the server (matches
/// `GameLeaderboard`'s same reasoning) -- deliberately NOT `Identifiable`;
/// every `ForEach` over a room's transcript uses `.enumerated()`/
/// `id: \.offset` at the call site instead.
struct RoomLine: Decodable, Hashable {
    let speaker: String
    let name: String
    let text: String
    let ts: String
}

/// A room. `transcript` is present when fetched singly (`GET .../:id`, or
/// right after `POST` creating one); `lines` is present instead in the
/// no-transcript list view (`GET /api/kade/room`) -- the server sends
/// exactly one of the two depending on context, never both, so both are
/// optional here rather than modeling two separate types for one shape.
/// One party guest, as the server lists them (names only — ids stay
/// server-side). Session 35 finale.
struct RoomGuest: Decodable, Hashable {
    let name: String
}

struct DebateRoom: Decodable, Identifiable, Hashable {
    let id: String
    let topic: String
    let goals: String
    let agents: [RoomCastMember]
    let shared: Bool
    let sharedTitle: String
    let nextIdx: Int
    let turnCount: Int
    let createdAt: String
    let updatedAt: String
    let transcript: [RoomLine]?
    let lines: Int?
    /// Party (session 35 finale): whose room is this (host controls), the
    /// open-doors code ('' = closed), and who's joined. Optional with
    /// defaults so pre-party servers and the ShareRoomSheet's rebuild both
    /// stay compiling and correct.
    var mine: Bool? = nil
    var partyCode: String? = nil
    var guests: [RoomGuest]? = nil

    var castNames: String {
        agents.map(\.name).joined(separator: ", ")
    }
}

/// One shared room as it appears in the Conversation Hall. Its transcript
/// is a read-only, capped-at-200-lines preview snapshot (`{name,text}`
/// only, no `speaker`/`ts` — the server strips those for this view), not
/// a live room you can add turns to.
struct HallItem: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let topic: String
    let cast: [String]
    let by: String
    let sharedAt: String?
    let transcript: [HallLine]

    struct HallLine: Decodable, Hashable {
        let name: String
        let text: String
    }
}
