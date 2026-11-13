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
/// Message content comes from GET /api/messages after completion. The stream
/// supplies only the completed reply identity for bounded recovery of verified
/// keeper receipts that arrive after FINAL. A missing identity is never guessed.
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
///
/// **Bug #6 (Sep 29 2026): Retry no longer posts the message twice.** Until
/// now every attempt minted a fresh `messageId`, so when the first POST had
/// reached the server and only the reply half failed, Retry made a second
/// copy of her message and a second reply. The fork already de-duplicates:
/// a plain send is claimed as a request receipt under its `messageId`
/// (`controllers/agents/request.js`), and a repeat POST with the same id and
/// the same input answers `status: "existing"` and starts nothing new. So
/// the caller now keeps the id of the failed attempt, asks
/// `checkReceipt(requestId:)` what happened to it, and resends under that
/// SAME id unless the server says the original failed or was stopped (then
/// a fresh id is a deliberate new attempt, the old behavior).
@MainActor
final class MessageSendingService: ObservableObject {
    enum SendError: Error {
        case server(Int)
        case streamError(String)
        case streamEndedWithoutFinal
    }

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()
    private var memoryReceiptTask: Task<Void, Never>?
    private var memoryReceiptLease = MemoryReceiptLease()
    private var liveMemoryCalls: Set<String> = []

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
    /// itself). `requestId` becomes the POST's `messageId`, which the server
    /// uses as the request receipt's id; `nil` mints a fresh one (Bug #6,
    /// Sep 29 2026 -- Retry passes the failed attempt's id back in).
    @discardableResult
    func send(
        text: String,
        conversationId: String?,
        parentMessageId: String?,
        agentId: String?,
        files: [[String: Any]]? = nil,
        inputSource: String? = nil,
        requestId: String? = nil,
        hearReplies: Bool = false,
        onText: ((String) -> Void)? = nil,
        onThink: ((String) -> Void)? = nil,
        onTool: ((String) -> Void)? = nil,
        onCompletedReply: ((String?) -> Void)? = nil
    ) async throws -> String {
        cancelMemoryReceiptRecovery()
        let memoryReceiptGeneration = memoryReceiptLease.generation
        liveMemoryCalls = []
        let turnRequestId = requestId ?? UUID().uuidString
        let start = try await startGeneration(
            text: text,
            conversationId: conversationId,
            parentMessageId: parentMessageId,
            agentId: agentId,
            files: files,
            inputSource: inputSource,
            requestId: turnRequestId,
            hearReplies: hearReplies
        )
        /* Build 212: the second half of the send-prologue bisect (see the
         * long note in ConversationDetailView.performSend). startGeneration
         * runs on the MainActor and does the POST that opens the stream; if
         * the freeze trail reaches "turn state reset" but never this crumb,
         * the wedge is in there and not in any SwiftUI commit at all. */
        KadeBreadcrumbs.drop("request dispatched")
        activeStreamId = start.streamId
        defer { activeStreamId = nil }
        var replyId = try await waitForFinal(streamId: start.streamId, onThink: onThink, onText: onText, onTool: onTool)
        if replyId == nil, !Task.isCancelled {
            // A short stream can already be gone (404). One bounded read of
            // this exact owner-scoped request preserves autoplay without
            // guessing the newest historical assistant message.
            replyId = await completedReplyId(requestId: turnRequestId, conversationId: start.conversationId)
        }
        if Task.isCancelled { throw URLError(.cancelled) }
        // Pick 4: the resume found no job and no saved reply turned up: not a
        // silent success. The ordinary error and Retry (same request id).
        if replyId == nil, lastResumeNotFound { throw SendError.streamEndedWithoutFinal }
        onCompletedReply?(replyId)
        if let replyId, memoryReceiptLease.accepts(memoryReceiptGeneration) {
            recoverMemoryReceipts(scope: .init(conversationId: start.conversationId, messageId: replyId),
                                  generation: memoryReceiptGeneration)
        }
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
        cancelMemoryReceiptRecovery()
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
        agentId: String?,
        files: [[String: Any]]? = nil,
        inputSource: String? = nil,
        requestId: String? = nil,
        hearReplies: Bool = false
    ) async throws -> StartResponse {
        var body: [String: Any] = [
            "text": text,
            "messageId": requestId ?? UUID().uuidString,
            "endpoint": "agents",
        ]
        if inputSource == "voice_transcript" { body["kadeInputSource"] = inputSource }
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
        // Session 26 (in-chat attachments): the exact array shape the web
        // composer sends (useChatFunctions.ts) -- the server attaches these
        // to the user message and hands them to the agent as context.
        if let files, !files.isEmpty {
            body["files"] = files
        }
        // July 23 2026 (kade_location): opt-in coordinate ride-along — same
        // shape the web client attaches. Nil (setting off / no fresh fix)
        // means the key is absent and the payload is byte-identical to
        // before this feature existed.
        if let userLocation = KadeLocationShare.shared.freshPayload() {
            body["userLocation"] = userLocation
        }
        // Aug 6 2026: whisper mode ride-along — absent unless the Settings
        // toggle is on, so the payload stays byte-identical when off (the
        // exact userLocation discipline above).
        if UserDefaults.standard.bool(forKey: "kade.speech.whisperMode") {
            body["kadeWhisper"] = true
        }
        // GW-6 (Nov 12 2026 audit): this phone speaks the reply as it streams
        // when Hear replies is on, so it says so. The fork forwards it to the
        // gateway as kade_live (KADE_SEND_LIVE=0 stops that); the gateway
        // acts on it only once KADE_SCREEN_LIVE is set. Absent otherwise, so
        // the body is byte-identical to before. Switch: kade.switch.kadeLive.
        if hearReplies, KadeAppSwitches.kadeLive {
            body["kadeLive"] = true
        }

        var req = client.request(path: "api/agents/chat/agents", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Bug #6 (Sep 29 2026): sorted keys. The server fingerprints a
        // receipt with `JSON.stringify(req.body.files)`, which keeps the
        // wire order of each file's keys, and a Swift Dictionary promises no
        // order -- so a retried attachment could fingerprint differently
        // under the same id and be refused with a 409.
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw SendError.server(http.statusCode) }
        return try decoder.decode(StartResponse.self, from: data)
    }

    // MARK: - Request receipts (Bug #6, Sep 29 2026)

    /// What the server knows about an earlier POST, read from its request
    /// receipt (`GET /api/agents/chat/tasks/:taskId` -- the same receipts
    /// the Agent work page lists, same status words as `AgentWorkItem`).
    enum ReceiptCheck {
        /// No receipt: the POST never reached the server.
        case notFound
        /// Starting, working, or the reply is saved.
        case arrived
        /// It reached the server but failed, was stopped, or was cut off.
        case failed
        /// No answer we can trust (offline, signed out, server trouble).
        case unknown
    }

    private struct ReceiptBody: Decodable { let status: String }

    private func completedReplyId(requestId: String, conversationId: String) async -> String? {
        let request = client.request(path: "api/agents/chat/tasks/\(requestId)", authorized: true, timeout: 8)
        guard let (data, http) = try? await client.send(request), !Task.isCancelled,
              http.statusCode == 200,
              let receipt = try? decoder.decode(ReplyTaskReceipt.self, from: data) else { return nil }
        return receipt.completedReplyId(requestId: requestId, conversationId: conversationId)
    }

    /// Never throws and never resends anything -- it only reads.
    func checkReceipt(requestId: String) async -> ReceiptCheck {
        let req = client.request(path: "api/agents/chat/tasks/\(requestId)", authorized: true)
        guard let (data, http) = try? await client.send(req) else { return .unknown }
        if http.statusCode == 404 { return .notFound }
        guard http.statusCode == 200,
              let receipt = try? decoder.decode(ReceiptBody.self, from: data) else { return .unknown }
        switch receipt.status {
        case "starting", "running", "completed": return .arrived
        case "failed", "stopped", "interrupted": return .failed
        default: return .unknown
        }
    }

    // MARK: - Phase B: subscribe until `final`

    /// IOS-20 (Nov 12 2026 audit): one SSE event, decoded ONCE, off the main
    /// actor (it used to be decoded up to five times per line, on main).
    /// Every field is optional and each top-level key is decoded on its own,
    /// so one odd field (a final carrying `error: true`, the `created` frame
    /// whose `message` is an object) can never make the whole frame
    /// unreadable. Fail-soft, exactly as before: an unparseable frame is just
    /// skipped.
    private struct StreamFrame: Decodable {
        struct Part: Decodable { let type: String?; let think: String?; let text: String? }
        struct Delta: Decodable { let content: [Part]? }
        struct ToolCall: Decodable {
            struct Fn: Decodable { let name: String? }
            let name: String?
            let function: Fn?
            var toolName: String? { name ?? function?.name }
        }
        struct StepDetails: Decodable { let type: String?; let tool_calls: [ToolCall]? }
        struct Reply: Decodable { let messageId: String?; let conversationId: String? }
        struct Payload: Decodable {
            let delta: Delta?
            let stepDetails: StepDetails?
            let type: String?
            let toolCallId: String?
            let messageId: String?
            let conversationId: String?
            let memory: MemoryReceipt.Change?

            private enum CodingKeys: String, CodingKey {
                case delta, stepDetails, type, toolCallId, messageId, conversationId, memory
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                delta = try? c.decodeIfPresent(Delta.self, forKey: .delta)
                stepDetails = try? c.decodeIfPresent(StepDetails.self, forKey: .stepDetails)
                type = try? c.decodeIfPresent(String.self, forKey: .type)
                toolCallId = try? c.decodeIfPresent(String.self, forKey: .toolCallId)
                messageId = try? c.decodeIfPresent(String.self, forKey: .messageId)
                conversationId = try? c.decodeIfPresent(String.self, forKey: .conversationId)
                memory = try? c.decodeIfPresent(MemoryReceipt.Change.self, forKey: .memory)
            }
        }

        /// Phase 3 A1 (Nov 12 2026): the server's spoken names for this step's
        /// tool calls, `toolLabels[i]` for `tool_calls[i]`; "" means say nothing.
        struct Extras: Decodable {
            let toolLabels: [String]?
            private enum CodingKeys: String, CodingKey { case toolLabels }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                toolLabels = try? c.decodeIfPresent([String].self, forKey: .toolLabels)
            }
        }

        let event: String?
        let final: Bool?
        let responseMessage: Reply?
        let data: Payload?
        let kade: Extras?
        /// Only meaningful on an SSE `event: error` line.
        let errorText: String?
        /// Only on a `kade_gap` event (pick 4): why the server could not
        /// resume exactly ("other-job", "out-of-range", "no-log").
        let gapReason: String?

        private enum CodingKeys: String, CodingKey {
            case event, final, responseMessage, data, kade, error, message, reason
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = try? c.decodeIfPresent(String.self, forKey: .event)
            final = try? c.decodeIfPresent(Bool.self, forKey: .final)
            responseMessage = try? c.decodeIfPresent(Reply.self, forKey: .responseMessage)
            data = try? c.decodeIfPresent(Payload.self, forKey: .data)
            kade = try? c.decodeIfPresent(Extras.self, forKey: .kade)
            let err = try? c.decodeIfPresent(String.self, forKey: .error)
            let msg = try? c.decodeIfPresent(String.self, forKey: .message)
            errorText = err ?? msg
            gapReason = try? c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    /// Pick 4 (Nov 12 2026): the last event id the worker has read, shared
    /// between the detached line reader and the resume loop. Every element
    /// the worker yields is consumed before a drop is thrown, so an id here
    /// never runs ahead of what the chat view was handed.
    private final class StreamCursor: @unchecked Sendable {
        private let lock = NSLock()
        private var _id: String?
        private var _progressed = false
        /// Set on the main actor after a kade_gap: later words are not spoken.
        var gap = false
        var id: String? { lock.lock(); defer { lock.unlock() }; return _id }
        func record(_ id: String) { lock.lock(); _id = id; _progressed = true; lock.unlock() }
        /// True once since the last call if a new id arrived.
        func takeProgress() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let was = _progressed
            _progressed = false
            return was
        }
    }

    /// Pick 4: true when the last reply's stream had a hole the server could
    /// not fill; the chat view then speaks the rest from the saved reply.
    private(set) var lastStreamHadGap = false

    /// The frames `waitForFinal` acts on. Everything else on the wire
    /// (on_run_step_delta, created, step-completed...) is dropped in the
    /// worker so it never costs a main-actor hop. A future event type must
    /// be added here or it is dropped.
    nonisolated private static let handledStreamEvents: Set<String> = [
        "on_reasoning_delta", "on_message_delta", "on_run_step", "attachment",
    ]

    /// Bytes -> lines -> decoded frames, entirely off the main actor.
    /// `sseEvent` is the SSE `event:` line ("message" unless the server named one).
    nonisolated private static func frames(from bytes: URLSession.AsyncBytes, cursor: StreamCursor? = nil)
        -> AsyncThrowingStream<(sseEvent: String, frame: StreamFrame?), Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                var currentEvent = "message"
                var pendingId: String?
                do {
                    for try await rawLine in bytes.lines {
                        if rawLine.hasPrefix("id:") {
                            // Pick 4: the latest valid id; anything else is ignored.
                            if cursor != nil, let id = StreamResume.cursor(fromIdLine: rawLine) { pendingId = id }
                        } else if rawLine.hasPrefix("event:") {
                            currentEvent = String(rawLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if rawLine.hasPrefix("data:") {
                            let jsonText = String(rawLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            let frame = try? decoder.decode(StreamFrame.self, from: Data(jsonText.utf8))
                            let sseEvent = currentEvent
                            currentEvent = "message"
                            if let id = pendingId {
                                cursor?.record(id)
                                pendingId = nil
                            }
                            if sseEvent == "error" || sseEvent == "kade_gap" {
                                // Always delivered, even unparseable: the caller must throw.
                                continuation.yield((sseEvent, frame))
                            } else if let frame,
                                      frame.final == true || handledStreamEvents.contains(frame.event ?? "") {
                                continuation.yield((sseEvent, frame))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    /// Session 35 encore (her ask: "see the deepthink bubble as it's
    /// generating... see the thoughts populate as they stream"): the
    /// subscribe stream has ALWAYS carried on_reasoning_delta frames
    /// (proven live July 31 — think-typed content parts on the wire);
    /// this used to read past every one of them waiting for `final`.
    /// `onThink` now hands each think chunk to the caller the moment it
    /// arrives. Fail-soft: an unparseable frame is just skipped, exactly
    /// as before.
    /// Aug 7 2026 (her ask: "I don't even know if you can tell when memories
    /// are made on native") — the stream has ALWAYS carried memory-artifact
    /// frames ({event:"attachment", data:{memory:{key,type}}}, emitted by the
    /// platform's memory writer after its post-turn pass); native read past
    /// them. Now each one lands as a NotificationCenter post the chat view
    /// turns into a spoken + felt cue. Fail-soft: unparseable = skipped.
    static let memoryArtifactNotification = Notification.Name("kadeMemoryArtifact")

    /* PART 91.4 — WHY THE PHONE GOES QUIET WHEN AN AGENT USES A TOOL.
     *
     * This stream handled exactly three events: on_reasoning_delta,
     * on_message_delta and attachment. The server ALSO sends on_run_step every
     * time the agent picks up a tool, and nothing here ever read it — so a turn
     * that thinks for a second and then spends two minutes running tools
     * looked, sounded and felt like a dead app. Kiana rarely exposed it: she
     * answers fast and usually reaches for at most one tool. Forge has
     * sixty-seven and chains them freely, which turns the gap from a blip into
     * minutes of silence on Kade's phone.
     *
     * Silence and death are indistinguishable by ear. That rule is written all
     * over this platform, and this was the last place still breaking it.
     * (Its frame is StreamFrame's `data.stepDetails` since IOS-20.) */

    /// Tool names are plumbing (`startHarnessRun_action_a2FkZS1oYX`,
    /// `kade_read_page`). This turns one into something worth hearing.
    /// An unknown name still beats silence, so the fallback tidies rather than
    /// hides: drop the action suffix, split the snake case, say it plainly.
    /* Sep 5 2026 (Part 132.2), her word: "Kiana is using tool name" is wordy.
     * Short labels now — "web search", "weather", "memory" — and the caller
     * announces the label alone, no "<agent> is …" wrapper. */
    static func spokenToolName(_ raw: String) -> String {
        let known: [String: String] = [
            "web_search": "web search",
            "file_search": "your files",
            "kade_read_page": "reading a page",
            "kade_research": "deep research",
            "kade_memory_search": "memory",
            "kade_living_memory": "memory",
            "kade_weather": "weather",
            "kade_news": "news",
            "kade_wikipedia": "wikipedia",
            "kade_notify": "reminder",
            "kade_feedback": "feedback",
            "kade_code": "code",
            "kade_errand": "errand",
            "kade_phone_call": "phone",
            "kade_call_me": "call",
            "kade_location": "location",
            "kade_help": "help pages",
            "kade_joke": "jokes",
            "kade_games": "game parlor",
            "kade_lyrics": "lyrics",
            "kade_media": "media",
            "kade_transcribe": "transcript",
            "kade_make_file": "file",
            "kade_message": "message",
            "kade_funding_balance": "cost and paid back",
            "flux": "picture",
            "fal_studio": "studio",
        ]
        var base = raw
        if let r = base.range(of: "_action_") { base = String(base[base.startIndex..<r.lowerBound]) }
        if let hit = known[base] { return hit }
        var out = ""
        for ch in base {
            if ch == "_" {
                out.append(" ")
            } else if ch.isUppercase && !out.isEmpty && out.last != " " {
                out.append(" ")
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Pick 4 (Nov 12 2026): a stream that drops mid-reply is picked back up
    /// from the last event id the phone holds, up to eight tries at 0.5, 1,
    /// 2, then 4 s (counting again after any try that made progress). A
    /// server that sends no ids is never retried: today's error and Retry.
    private func waitForFinal(streamId: String, onThink: ((String) -> Void)? = nil, onText: ((String) -> Void)? = nil, onTool: ((String) -> Void)? = nil) async throws -> String? {
        lastStreamHadGap = false
        lastResumeNotFound = false
        guard KadeAppSwitches.streamResume else {
            return try await readStream(streamId: streamId, cursor: nil, resuming: false,
                                        onThink: onThink, onText: onText, onTool: onTool)
        }
        let cursor = StreamCursor()
        var attempt = 0
        var dropped = false
        /// When the drops began with no progress since: a total budget of
        /// 300 s, the same as one stream's own idle timeout.
        var stalledSince: Date?
        var waitingForSignal = false
        while true {
            do {
                return try await readStream(streamId: streamId, cursor: cursor, resuming: dropped,
                                            onThink: onThink, onText: onText, onTool: onTool)
            } catch {
                // Stop: always the calm "Stopped." path, never Retry.
                if Task.isCancelled { throw URLError(.cancelled) }
                // An error frame from the server, or a refused request, is never retried.
                if let known = error as? SendError {
                    guard case .streamEndedWithoutFinal = known else { throw known }
                } else if let urlError = error as? URLError {
                    // Only a real connection loss is resumed. The 300 s idle
                    // timeout is the server's hung-turn cap (its heartbeat
                    // stops after 240 s): retrying it would undo that cap.
                    guard Self.resumableNetworkCodes.contains(urlError.code) else { throw error }
                } else {
                    throw error
                }
                // No id ever seen = the server keeps no log: today's behaviour.
                guard cursor.id != nil else { throw error }
                if cursor.takeProgress() {
                    attempt = 0
                    stalledSince = nil
                }
                let firstDrop = stalledSince ?? Date()
                stalledSince = firstDrop
                guard Date().timeIntervalSince(firstDrop) < 300 else { throw error }
                // Sweep, Nov 13 2026: with no route at all every try fails at
                // once, so those are not counted (eight of them took 24 s);
                // they wait 4 s at a time inside the 300 s budget above.
                let counted = StreamResume.countsAsAttempt(error)
                if counted {
                    attempt += 1
                    guard attempt <= StreamResume.maxAttempts else { throw error }
                    KadeBreadcrumbs.drop("stream dropped; picking it up (try \(attempt))")
                } else if !waitingForSignal {
                    KadeBreadcrumbs.drop("stream dropped with no signal; waiting for it to come back")
                }
                waitingForSignal = !counted
                dropped = true
                do {
                    try await Task.sleep(nanoseconds: counted ? StreamResume.delayNanos(attempt: attempt)
                                                              : StreamResume.noRouteWaitNanos)
                } catch {
                    throw URLError(.cancelled)   // Stop during the wait: "Stopped."
                }
            }
        }
    }

    /// Pick 4: the connection losses worth picking up again. Everything else
    /// (a timeout, a refused certificate, a bad URL) ends the turn as before.
    private static let resumableNetworkCodes: Set<URLError.Code> = [
        .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff,
        .callIsActive, .resourceUnavailable,
    ]

    /// Pick 4: a resume answered 404 (the job is gone, for example after a
    /// server redeploy). If no saved reply turns up either, send() throws so
    /// she gets the ordinary error and Retry with the same request id.
    private(set) var lastResumeNotFound = false

    private func readStream(streamId: String, cursor: StreamCursor?, resuming: Bool,
                            onThink: ((String) -> Void)?, onText: ((String) -> Void)?,
                            onTool: ((String) -> Void)?) async throws -> String? {
        // Pick 4: ask for ids (kadeSeq=1) and send the cursor when resuming.
        var req = client.request(path: "api/agents/chat/stream/\(streamId)", authorized: true,
                                 queryItems: cursor != nil ? [URLQueryItem(name: "kadeSeq", value: "1")] : nil)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if resuming, let id = cursor?.id { req.setValue(id, forHTTPHeaderField: "Last-Event-ID") }
        // Generous on purpose: the generation job lives server-side,
        // independent of this HTTP connection, so there's no correctness
        // cost to waiting a while for a slow, tool-heavy agent turn — only
        // a UX cost, and a timeout here still leaves a safe "retry"
        // (re-reads whatever the server already saved).
        req.timeoutInterval = 300

        let (bytes, http) = try await client.streamBytes(req)
        if http.statusCode == 404 {
            // Pick 4: after a drop, a 404 means the reply finished while we
            // were away: reload the saved messages and speak the rest.
            if resuming {
                lastStreamHadGap = true
                lastResumeNotFound = true
            }
            return nil  // no guessed historical reply id
        }
        guard http.statusCode == 200 else { throw SendError.server(http.statusCode) }

        /* IOS-20 (Nov 12 2026 audit): line splitting and JSON decoding happen
         * in a detached worker (one decode per event, was up to five on the
         * main actor). Only frames this loop acts on arrive here. */
        for try await (sseEvent, frame) in Self.frames(from: bytes, cursor: cursor) {
            if sseEvent == "error" {
                throw SendError.streamError(frame?.errorText ?? "The assistant hit an error.")
            }
            if sseEvent == "kade_gap" {
                // Pick 4: the server could not resume exactly. Words after
                // this are not spoken out of place; the chat view speaks the
                // rest from the saved reply at the end.
                cursor?.gap = true
                lastStreamHadGap = true
                KadeBreadcrumbs.drop("stream resume not exact (\(frame?.gapReason ?? "unknown"))")
                // The turn was replaced: reload the saved messages.
                if frame?.gapReason == "other-job" { return nil }
                continue
            }
            guard let frame else { continue }

            if frame.final == true {
                guard frame.responseMessage?.conversationId == streamId else { return nil }
                return frame.responseMessage?.messageId
            }

            switch frame.event {
            case "on_reasoning_delta":
                guard let onThink else { break }
                for part in frame.data?.delta?.content ?? [] where part.type == "think" {
                    if let think = part.think, !think.isEmpty { onThink(think) }
                }
            case "on_message_delta":
                // Aug 7 2026 (her "even with deep think off it takes forever...
                // still seems like she's thinking"): the reply TEXT was always
                // streaming on this wire too (on_message_delta frames). onText
                // hands each text chunk up the moment it arrives; the chat view
                // grows a live reply from it.
                guard let onText, cursor?.gap != true else { break }
                for part in frame.data?.delta?.content ?? [] where part.type == "text" {
                    if let text = part.text, !text.isEmpty { onText(text) }
                }
            case "on_run_step":
                /* The tool announcement: one line per tool the agent picks
                 * up, so a long chain reads as progress instead of a hang. */
                guard let onTool else { break }
                // Phase 3 A1: the server's label for each call, by the call's
                // own index, wins; spokenToolName is only the fallback for an
                // older server (keep it, but stop adding names to it).
                let labels = KadeAppSwitches.toolLabels ? frame.kade?.toolLabels : nil
                for (index, call) in (frame.data?.stepDetails?.tool_calls ?? []).enumerated() {
                    if let labels, index < labels.count {
                        let label = labels[index].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !label.isEmpty { onTool(label) }
                        continue
                    }
                    if let n = call.toolName, !n.isEmpty { onTool(Self.spokenToolName(n)) }
                }
            case "attachment":
                if let d = frame.data, d.conversationId == streamId, let messageId = d.messageId {
                    let receipt = MemoryReceipt(type: d.type, toolCallId: d.toolCallId, messageId: d.messageId,
                                                conversationId: d.conversationId, memory: d.memory)
                    var tracker = MemoryReceiptTracker(
                        scope: .init(conversationId: streamId, messageId: messageId), seen: liveMemoryCalls
                    )
                    for verified in tracker.consume([receipt]) { announceMemoryReceipt(verified) }
                    liveMemoryCalls = tracker.seen
                }
            default:
                break
            }
        }
        // A cancelled consumer makes AsyncThrowingStream end quietly (nil, no
        // throw). Rethrow as the cancel the chat view's calm "Stopped." path
        // catches, never as streamEndedWithoutFinal (that one shows Retry).
        if Task.isCancelled { throw URLError(.cancelled) }
        throw SendError.streamEndedWithoutFinal
    }
    private struct ReceiptMessages: Decodable {
        struct Reply: Decodable {
            let messageId: String
            let conversationId: String
            let isCreatedByUser: Bool
            let attachments: [MemoryReceipt]?
        }
        let messages: [Reply]
    }

    func cancelMemoryReceiptRecovery() {
        memoryReceiptLease.invalidate()
        memoryReceiptTask?.cancel()
        memoryReceiptTask = nil
    }

    private func announceMemoryReceipt(_ receipt: MemoryReceipt) {
        guard let kind = receipt.memory?.type else { return }
        NotificationCenter.default.post(name: Self.memoryArtifactNotification, object: nil,
            userInfo: ["type": kind, "key": receipt.memory?.key ?? "",
                       "conversationId": receipt.conversationId ?? "", "messageId": receipt.messageId ?? ""])
    }

    /// The reply finishes immediately. Only its existing saved metadata is read
    /// briefly afterward; no generation, audio, push, or historical replay.
    private func recoverMemoryReceipts(scope: MemoryReceiptScope, generation: UUID) {
        guard memoryReceiptLease.accepts(generation) else { return }
        let window = MemoryReceiptWindow(start: Date())
        var tracker = MemoryReceiptTracker(scope: scope, seen: liveMemoryCalls)
        memoryReceiptTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<MemoryReceiptWindow.maxAttempts {
                do {
                    try await Task.sleep(nanoseconds: MemoryReceiptWindow.intervalSeconds * 1_000_000_000)
                    guard window.permits(attempt: attempt, now: Date(), cancelled: Task.isCancelled,
                                         scopeMatches: self.memoryReceiptLease.accepts(generation)) else { return }
                    var request = self.client.request(path: "api/messages", authorized: true,
                        queryItems: [URLQueryItem(name: "conversationId", value: scope.conversationId),
                                     URLQueryItem(name: "messageId", value: scope.messageId)])
                    request.timeoutInterval = min(6, max(1, window.deadline.timeIntervalSinceNow))
                    let (data, http) = try await self.client.send(request)
                    guard window.permits(attempt: attempt, now: Date(), cancelled: Task.isCancelled,
                                         scopeMatches: self.memoryReceiptLease.accepts(generation)),
                          http.statusCode == 200 else { return }
                    let snapshot = try self.decoder.decode(ReceiptMessages.self, from: data)
                    guard snapshot.messages.count == 1, let reply = snapshot.messages.first,
                          !reply.isCreatedByUser, reply.messageId == scope.messageId,
                          reply.conversationId == scope.conversationId else { return }
                    let fresh = tracker.consume(reply.attachments ?? [])
                    for receipt in fresh { self.announceMemoryReceipt(receipt) }
                    if !fresh.isEmpty { return }
                } catch { return } // bounded, fail-soft; never retry a rejected read
            }
        }
    }
}
