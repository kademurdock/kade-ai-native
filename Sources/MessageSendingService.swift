import Foundation

/// Sends a user message into an existing conversation -- or starts a brand
/// new one, see below -- and waits for the agent's reply to finish. Phase 3;
/// new-conversation support added when Kade noticed there was no way to
/// start one from the native app (session 11).
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
/// NEW CONVERSATIONS: read directly from the fork's own controller
/// (`api/server/controllers/agents/request.js`): `const isNewConvo =
/// !reqConversationId || reqConversationId === 'new'; const conversationId
/// = isNewConvo ? crypto.randomUUID() : reqConversationId;` — so simply
/// OMITTING `conversationId` from the request body (not sending an empty
/// string, not sending a client-generated UUID) is what tells the server to
/// mint a brand-new one, which comes back in the response. `conversationId`
/// is therefore `String?` here: `nil` means "start a new one," and the
/// caller must read the RETURN VALUE (the resolved id -- the one that was
/// passed in, or the freshly minted one) to know what to use from here on.
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
/// propagates and the caller offers a retry. **Correction (session 13):**
/// this used to claim the caller's retry "safely re-reads whatever the
/// server already saved rather than resending" -- that was never actually
/// true of the shipped code (the caller's Retry called this same `send`
/// again with a fresh POST) and, worse, the caller had a real bug that
/// made Retry silently do nothing at all (see
/// `ConversationDetailView.retry()`/`FailedAttempt`, fixed this session).
/// The real, current behavior: Retry resends the identical text to the
/// identical parent as a genuinely new attempt, which can create a
/// duplicate turn in the rare case the original request actually reached
/// the server and only the confirm-the-reply half failed -- accepted
/// deliberately, since a visible duplicate is a far better failure mode
/// than a Retry button that does nothing.
@MainActor
final class MessageSendingService: ObservableObject {
    enum SendError: Error {
        case server(Int)
        case streamError(String)
        case streamEndedWithoutFinal
    }

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    /// The in-flight turn's `streamId` (== `conversationId`, confirmed in
    /// `docs/ENDPOINTS.md`), published so `ConversationDetailView` can offer
    /// a Stop button the moment there's something real to stop -- `nil`
    /// before `startGeneration` has returned and again once `send` finishes,
    /// however it finishes. Session 17: `POST /api/agents/chat/abort` sat in
    /// `docs/ENDPOINTS.md` "source-confirmed... not yet wired into the app"
    /// since Phase 3; this is that wiring.
    @Published private(set) var activeStreamId: String?

    init(client: KadeAPIClient) {
        self.client = client
    }

    /// Posts `text` as a new turn in `conversationId` and waits until the
    /// agent's reply is fully persisted server-side, then returns the
    /// RESOLVED conversation id -- pass `conversationId: nil` to start a
    /// brand-new conversation (see type doc); the id the server actually
    /// created comes back here, since the caller has no other way to learn
    /// it. Callers should re-fetch messages afterward to render the result
    /// (see type doc for why this method hands back no message content
    /// itself).
    @discardableResult
    func send(
        text: String,
        conversationId: String?,
        parentMessageId: String?,
        agentId: String?
    ) async throws -> String {
        let start = try await startGeneration(
            text: text,
            conversationId: conversationId,
            parentMessageId: parentMessageId,
            agentId: agentId
        )
        activeStreamId = start.streamId
        defer { activeStreamId = nil }
        try await waitForFinal(streamId: start.streamId)
        return start.conversationId
    }

    /// Stops the CURRENTLY in-flight turn server-side -- a no-op if nothing
    /// is running. This is the half a cancelled local `Task` alone can't
    /// do: cancelling `ConversationDetailView`'s `sendTask` stops the CLIENT
    /// from listening, but the agent keeps generating (and metering) on the
    /// server until something tells it to stop. Per `docs/ENDPOINTS.md`,
    /// `/abort` "persists whatever partial content it had" -- fail-soft on
    /// purpose (`try?`): if this one request doesn't land, the caller's
    /// separate `sendTask.cancel()` still stops the client side, and a
    /// short-lived job that finishes naturally a moment later is a far
    /// smaller problem than a Stop button that hangs on a flaky network
    /// call.
    func abortActive() async {
        guard let streamId = activeStreamId else { return }
        var req = client.request(path: "api/agents/chat/abort", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["streamId": streamId])
        _ = try? await client.send(req)
    }

    // MARK: - Phase A: kick off generation

    private struct StartResponse: Codable {
        let streamId: String
        let conversationId: String
    }

    private func startGeneration(
        text: String,
        conversationId: String?,
        parentMessageId: String?,
        agentId: String?
    ) async throws -> StartResponse {
        var body: [String: Any] = [
            "text": text,
            "messageId": UUID().uuidString,
            "endpoint": "agents",
        ]
        // Omit the key entirely for a brand-new conversation -- see the
        // type doc's "NEW CONVERSATIONS" section for why omission
        // (specifically, not an empty string or a client-made UUID) is
        // what the server actually checks for.
        if let conversationId {
            body["conversationId"] = conversationId
        }
        // A PRESENT parentMessageId passes through untouched. For the FIRST
        // message of a brand-new conversation (no conversationId, no
        // parent), the fork's NO_PARENT sentinel is sent EXPLICITLY --
        // exactly what the web composer does (useChatFunctions.ts:
        // `parentMessageId = Constants.NO_PARENT`). This used to say
        // omitting the key made "no behavior difference" -- WRONG, found
        // fixing a real live bug (July 22): the server's AUTOMATIC TITLE
        // GENERATION is gated on the RAW request body carrying exactly this
        // sentinel (`titleEligible`, api/server/controllers/agents/
        // request.js) -- a missing key destructures to null, silently fails
        // that check, and every conversation born in THIS app stayed
        // literally "New Chat" forever while web-born ones got real names.
        // The STORED chain was never wrong (the server normalizes the
        // persisted parent to the sentinel), which is why nothing else
        // misbehaved and the gap hid this long. An explicit JSON null would
        // fail the gate the same way -- the sentinel string is the one
        // spelling that works.
        if let parentMessageId {
            body["parentMessageId"] = parentMessageId
        } else if conversationId == nil {
            body["parentMessageId"] = KadeMessage.noParent
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
