import Foundation

/// Sends a user message into an existing conversation and waits for the
/// agent's reply to finish. Phase 3.
///
/// The fork's generation contract is two-phase, not a single POST-that-
/// streams — confirmed both against the live fork source
/// (`api/server/routes/agents/{index,chat}.js`, `controllers/agents/request.js`)
/// and by sending one real test message through this account 2026-07-19
/// (see `docs/ENDPOINTS.md`):
///
///   A) POST /api/agents/chat/agents -> { streamId, conversationId, status }
///      (streamId == conversationId, always)
///   B) GET  /api/agents/chat/stream/:streamId -> Server-Sent Events,
///      ending in a `{"final": true, ...}` frame.
///
/// Two things the live test surfaced that reading the web client's source
/// alone did not make obvious:
///
/// 1. The `messageId` this service mints and sends is NOT what ends up
///    persisted — the server saves the user turn under its own,
///    server-assigned id instead. There's no point reconciling that by
///    hand, so this service doesn't try: on completion, the caller simply
///    re-fetches the message list via `ConversationsService` (Phase 2,
///    already verified) — that always reflects exactly what the server
///    persisted, real ids included.
/// 2. A short reply can finish and have its generation job cleaned up
///    server-side before this service ever opens the GET stream — that
///    surfaces as an HTTP 404 ("Stream not found"). That is NOT a failure;
///    it's the server saying the turn already completed. This service
///    treats a 404 here exactly like a normal `final` frame.
///
/// Given both of those, this service deliberately never decodes
/// `responseMessage` out of the SSE payload — it only watches the stream
/// for a completion signal (`final: true`) or an explicit `error` event,
/// then returns. Less clever, more correct: the actual message content
/// always comes from the same already-proven GET /api/messages path.
///
/// v1 scope also skips the web client's resumable/reconnect/sync machinery
/// on purpose (built for a much more continuous, token-by-token UI than
/// this app wants). If the connection drops mid-stream, the error just
/// propagates and the caller offers a retry — safe, because retrying only
/// re-reads whatever the server already saved rather than resending
/// anything destructive.
@MainActor
final class MessageSendingService: ObservableObject {
    enum SendError: Error {
        case server(Int)
        case streamError(String)
        case streamEndedWithoutFinal
    }

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    /// Posts `text` as a new turn in `conversationId` and waits until the
    /// agent's reply is fully persisted server-side. Returns once done;
    /// callers should re-fetch messages afterward to render the result
    /// (see type doc for why this method hands back no message content
    /// itself).
    func send(
        text: String,
        conversationId: String,
        parentMessageId: String?,
        agentId: String?
    ) async throws {
        let start = try await startGeneration(
            text: text,
            conversationId: conversationId,
            parentMessageId: parentMessageId,
            agentId: agentId
        )
        try await waitForFinal(streamId: start.streamId)
    }

    // MARK: - Phase A: kick off generation

    private struct StartResponse: Codable {
        let streamId: String
        let conversationId: String
    }

    private func startGeneration(
        text: String,
        conversationId: String,
        parentMessageId: String?,
        agentId: String?
    ) async throws -> StartResponse {
        var body: [String: Any] = [
            "text": text,
            "messageId": UUID().uuidString,
            "conversationId": conversationId,
            "endpoint": "agents",
        ]
        // Omit the key entirely rather than send an explicit JSON null: the
        // server destructures `parentMessageId = null` from the body, and
        // that default only fires on a genuinely MISSING key anyway — a
        // present-but-null value would resolve to the same `null` either
        // way, so leaving the key out sidesteps needing an NSNull sentinel
        // (and the awkward String/NSNull-in-an-Any-dictionary typing that
        // comes with one) for no behavior difference.
        if let parentMessageId {
            body["parentMessageId"] = parentMessageId
        }
        if let agentId {
            body["agent_id"] = agentId
        }

        var req = client.request(path: "api/agents/chat/agents", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw SendError.server(http.statusCode) }
        return try decoder.decode(StartResponse.self, from: data)
    }

    // MARK: - Phase B: subscribe until `final`

    private struct FinalFlag: Codable { let final: Bool? }
    private struct ErrorFrame: Codable { let error: String?; let message: String? }

    private func waitForFinal(streamId: String) async throws {
        var req = client.request(path: "api/agents/chat/stream/\(streamId)", authorized: true)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Generous on purpose: the generation job lives server-side,
        // independent of this HTTP connection, so there's no correctness
        // cost to waiting a while for a slow, tool-heavy agent turn — only
        // a UX cost, and a timeout here still leaves a safe "retry"
        // (re-reads whatever the server already saved).
        req.timeoutInterval = 300

        let (bytes, http) = try await client.streamBytes(req)
        if http.statusCode == 404 {
            return  // job already finished server-side — see type doc, point 2
        }
        guard http.statusCode == 200 else { throw SendError.server(http.statusCode) }

        var currentEvent = "message"
        for try await rawLine in bytes.lines {
            if rawLine.hasPrefix("event:") {
                currentEvent = String(rawLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if rawLine.hasPrefix("data:") {
                let jsonText = String(rawLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                let jsonData = Data(jsonText.utf8)

                if currentEvent == "error" {
                    let parsed = try? decoder.decode(ErrorFrame.self, from: jsonData)
                    let message = parsed?.error ?? parsed?.message ?? "The assistant hit an error."
                    throw SendError.streamError(message)
                }

                if let flag = try? decoder.decode(FinalFlag.self, from: jsonData), flag.final == true {
                    return
                }

                currentEvent = "message"
            }
        }
        throw SendError.streamEndedWithoutFinal
    }
}
