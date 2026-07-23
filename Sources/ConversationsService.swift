import Foundation

/// One row from GET /api/convos. Verified shape 2026-07-19 (see docs/ENDPOINTS.md).
/// Hashable because NavigationStack's value-based navigation
/// (NavigationLink(value:) + .navigationDestination(for:)) requires it.
struct KadeConversation: Codable, Identifiable, Hashable {
    let conversationId: String
    let title: String?
    let agentId: String?
    let createdAt: String
    let updatedAt: String

    var id: String { conversationId }

    enum CodingKeys: String, CodingKey {
        case conversationId, title, createdAt, updatedAt
        case agentId = "agent_id"
    }

    /// LibreChat itself keeps `title` populated (verified against 25 real
    /// conversations, 0 empty) but this is a network response, not a
    /// compile-time guarantee — fall back rather than show a blank row.
    var displayTitle: String {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "Untitled conversation" : t
    }
}

private struct ConversationsPage: Codable {
    let conversations: [KadeConversation]
    let nextCursor: String?
}

/// One message from GET /api/messages/:conversationId. Verified shape 2026-07-19.
struct KadeMessage: Codable, Identifiable {
    let messageId: String
    let conversationId: String
    let createdAt: String
    let isCreatedByUser: Bool
    let sender: String?
    let text: String?
    let content: [ContentBlock]?
    /// Server-counted tokens for this message (confirmed live 2026-07-22:
    /// every /api/messages doc carries it). Powers the native context
    /// meter -- summing these is exactly the web gauge's own client-side
    /// estimate path (useTokenUsage's isEstimate branch).
    var tokenCount: Int? = nil
    /// Which message this branches from. The all-zero UUID sentinel
    /// ("00000000-0000-0000-0000-000000000000") marks the first turn in a
    /// conversation (confirmed live 2026-07-19, see docs/ENDPOINTS.md).
    /// Added alongside the message-actions feature (Edit/Regenerate, see
    /// `ConversationDetailView`'s "Message actions" section): both work by
    /// resending a new sibling message that reuses an EARLIER message's
    /// own `parentMessageId` -- verified live as the safe way to do this
    /// (a naive attempt using the server's `isRegenerate`/
    /// `overrideParentMessageId`/`responseMessageId` fields corrupted the
    /// target message in a throwaway live test; see ENDPOINTS.md).
    let parentMessageId: String?
    /// The agent that produced this reply. Raw API field name is "model"
    /// (confirmed live 2026-07-19) -- NOT an LLM model name despite the
    /// field name, an `agent_id` like "agent_6llV0eMu4fmIaj8f2x1Sb". Nil on
    /// user messages. Lets a per-message "Read Aloud" action speak an OLDER
    /// reply in the SAME voice that agent actually used, rather than
    /// whichever agent is currently selected for the NEXT message.
    let agentId: String?

    enum CodingKeys: String, CodingKey {
        case messageId, conversationId, createdAt, isCreatedByUser, sender, text, content
        case parentMessageId
        case tokenCount
        case agentId = "model"
    }

    var id: String { messageId }

    /// The all-zero "no parent" sentinel (the fork's `Constants.NO_PARENT`)
    /// -- stored on every conversation's first message, and REQUIRED on the
    /// wire when SENDING that first message (see
    /// MessageSendingService.startGeneration for the live bug that proved
    /// omission is not equivalent to sending it).
    static let noParent = "00000000-0000-0000-0000-000000000000"

    /// Assistant replies often carry their real content in `content` (text /
    /// think / tool_call blocks) with `text` left empty; user messages use
    /// `text` directly. Prefer `content`'s text blocks, fall back to `text`,
    /// and for an assistant turn that was pure tool activity (no text block
    /// at all) say so explicitly rather than rendering a silent empty bubble
    /// — a blind VoiceOver user has no other way to tell "nothing" apart
    /// from "this loaded wrong."
    ///
    /// Keeps any inline "%%%..." TTS steering tag / Game Parlor token
    /// intact on purpose -- this is the string handed to
    /// `VoiceService.enqueueSpeak`, and those tags need to survive to reach
    /// inworld-tts-proxy. Anything a human reads or VoiceOver speaks instead
    /// must go through `readableText` below, never this property directly.
    var displayText: String {
        if let blocks = content, !blocks.isEmpty {
            let joined = blocks
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined(separator: "\n\n")
            if !joined.isEmpty { return joined }
        }
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return isCreatedByUser ? "" : "(No text in this reply — it looks like tool activity only.)"
    }

    /// `displayText` with every display-only tag stripped (TTS steering,
    /// Game Parlor cues, the Deep Think marker) -- what the chat bubble
    /// shows, what its accessibility label speaks, and what the per-message
    /// Copy action puts on the pasteboard. See `MessageTextSanitizer`'s own
    /// doc comment for the full reasoning and why `displayText` itself
    /// stays raw. Ported July 19 2026 after Kade reported VoiceOver reading
    /// raw "%%%" tags aloud in the native chat view -- this property didn't
    /// exist before, `displayText` was shown/spoken directly.
    var readableText: String {
        MessageTextSanitizer.forDisplay(displayText)
    }

    /// True when this reply carries a context-compaction "summary" content
    /// block: the server condensed everything OLDER than this point into a
    /// running story-so-far summary for the model's payload only. Nothing in
    /// the stored transcript is deleted; the block itself is invisible to
    /// `displayText` (it filters for type == "text"). The web app renders a
    /// collapsible "Summary" element here; MessageRow surfaces a one-line,
    /// screen-reader-brief note instead. (July 22 2026, decision #2 of
    /// CONVERSATION_COMPACTING_PLAN: a subtle note, once per compaction.)
    var hasCompactionSummary: Bool {
        content?.contains(where: { $0.type == "summary" }) ?? false
    }

    /// Who VoiceOver announces this message as coming from.
    var speakerLabel: String {
        if isCreatedByUser { return "You" }
        let s = sender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "Assistant" : s
    }
}

/// One block of an assistant message's `content` array. Real payloads
/// include at least "text", "think", and "tool_call" types; think/tool_call
/// blocks carry their payload under a DIFFERENT key ("think", "tool_call"),
/// not "text" — so `text` is genuinely absent (not wrong-typed) on those,
/// and decodes to nil safely. The lenient `init(from:)` below additionally
/// makes sure one odd/future block shape can never fail the whole message
/// (and therefore the whole conversation) out of loading.
struct ContentBlock: Codable {
    let type: String
    let text: String?

    enum CodingKeys: String, CodingKey { case type, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        self.text = try? c.decode(String.self, forKey: .text)
    }
}

/// One row from `GET /api/kade/calls`. Only the fields the post-call
/// handoff actually needs are decoded; the route returns more (preview,
/// duration, turn count) and this is deliberately lenient about the rest so
/// a future server-side addition can never fail the decode.
struct KadeCallSummary: Decodable {
    let id: String
    let agentName: String?
    let startedAt: String
    /// The chat conversation this call was minted into, or nil while that
    /// mint is still in flight. Exposed on the fork as of session 14.
    let mergedConversationId: String?
}

struct KadeCallsPage: Decodable {
    let calls: [KadeCallSummary]
}

enum ConversationsError: Error {
    case server(Int)
}

/// Fetches conversations and message history from kademurdock.com. Read-only
/// for Phase 2 — sending messages and streaming replies are Phase 3.
@MainActor
final class ConversationsService: ObservableObject {
    @Published private(set) var conversations: [KadeConversation] = []
    @Published private(set) var isLoadingList = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var listError: String?
    /// Result of the last delete/rename/archive, in plain language, for the
    /// list screen to announce. Session 14 (Kade: "maybe a rotor of actions
    /// in the conversations list where you can delete stuff"). Deliberately
    /// NOT folded into `listError`: that one means "the list itself failed
    /// to load" and drives a whole different UI state.
    @Published var actionMessage: String?

    private var nextCursor: String?
    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    var hasMore: Bool { nextCursor != nil }

    /// Called on sign-out so the next sign-in never flashes a stale list.
    func reset() {
        conversations = []
        nextCursor = nil
        listError = nil
        actionMessage = nil
    }

    func loadFirstPage() async {
        guard !isLoadingList else { return }
        isLoadingList = true
        listError = nil
        defer { isLoadingList = false }
        do {
            let page = try await fetchPage(cursor: nil)
            conversations = page.conversations
            nextCursor = page.nextCursor
        } catch {
            listError = "Couldn't load your conversations. Pull to refresh to try again."
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoadingList else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetchPage(cursor: nextCursor)
            conversations.append(contentsOf: page.conversations)
            nextCursor = page.nextCursor
        } catch {
            // Silent on purpose: the list the user already has stays intact
            // and usable; "Load more" is still there to try again.
        }
    }

    func fetchMessages(conversationId: String) async throws -> [KadeMessage] {
        let req = client.request(path: "api/messages/\(conversationId)", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ConversationsError.server(http.statusCode) }
        // Messages arrive in chronological / parent-chain order already
        // (verified against a real 8-message thread) — no client-side sort
        // or tree reconstruction for this first pass. Known simplification:
        // if a conversation has been branched/regenerated, this renders the
        // straight chronological line rather than the exact active branch.
        return try decoder.decode([KadeMessage].self, from: data)
    }

    // MARK: - Row actions (session 14)

    /// DELETE /api/convos with `{"arg":{"conversationId":...}}`.
    /// Contract read straight off the fork's own `api/server/routes/convos.js`
    /// rather than guessed: the route reads `req.body.arg`, refuses outright
    /// if no identifying parameter is present (its own guard against
    /// wiping every conversation at once), and answers **201**, not 200, on
    /// success -- so the status check here accepts both rather than the 200
    /// that would have been the natural assumption.
    @discardableResult
    func deleteConversation(id: String, title: String) async -> Bool {
        var req = client.request(path: "api/convos", method: "DELETE", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["arg": ["conversationId": id]]
        )
        do {
            let (_, http) = try await client.send(req)
            guard (200...201).contains(http.statusCode) else {
                actionMessage = "Couldn't delete \(title). Try again."
                return false
            }
            conversations.removeAll { $0.conversationId == id }
            actionMessage = "Deleted \(title)."
            return true
        } catch {
            actionMessage = "Couldn't delete \(title). Try again."
            return false
        }
    }

    /// POST /api/convos/update with `{"arg":{"conversationId":...,"title":...}}`.
    /// Server trims and caps the title at 1024 characters; this trims first
    /// so an all-whitespace rename is refused locally instead of quietly
    /// becoming an empty title on the server.
    @discardableResult
    func renameConversation(id: String, title newTitle: String) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            actionMessage = "A name can't be empty."
            return false
        }
        var req = client.request(path: "api/convos/update", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["arg": ["conversationId": id, "title": trimmed]]
        )
        do {
            let (_, http) = try await client.send(req)
            guard (200...201).contains(http.statusCode) else {
                actionMessage = "Couldn't rename that conversation. Try again."
                return false
            }
            applyLocalTitle(trimmed, to: id)
            actionMessage = "Renamed to \(trimmed)."
            return true
        } catch {
            actionMessage = "Couldn't rename that conversation. Try again."
            return false
        }
    }

    /// POST /api/convos/archive with `{"arg":{"conversationId":...,"isArchived":true}}`.
    /// The list route defaults to `isArchived=false`, so an archived
    /// conversation simply stops appearing here -- it is NOT deleted, and
    /// it's still reachable on the web app. Worth saying out loud in the
    /// confirmation copy, since "archive" and "delete" are easy to confuse
    /// when you're navigating by ear.
    @discardableResult
    func archiveConversation(id: String, title: String) async -> Bool {
        var req = client.request(path: "api/convos/archive", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["arg": ["conversationId": id, "isArchived": true]]
        )
        do {
            let (_, http) = try await client.send(req)
            guard (200...201).contains(http.statusCode) else {
                actionMessage = "Couldn't archive \(title). Try again."
                return false
            }
            conversations.removeAll { $0.conversationId == id }
            actionMessage = "Archived \(title)."
            return true
        } catch {
            actionMessage = "Couldn't archive \(title). Try again."
            return false
        }
    }

    /// One page of ARCHIVED conversations -- same route and page shape as
    /// the main list, filtered server-side (`GET /api/convos?isArchived=
    /// true`; the fork reads the param through `isEnabled`, so the literal
    /// string "true" is correct). Deliberately NOT cached on a @Published
    /// here: archived is a visit-when-needed surface, and a second stored
    /// list would need syncing through every archive/unarchive/delete --
    /// `ArchivedConversationsView` fetches fresh each visit instead.
    func fetchArchivedPage(cursor: String?) async throws
        -> (conversations: [KadeConversation], nextCursor: String?) {
        var items: [URLQueryItem] = [URLQueryItem(name: "isArchived", value: "true")]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let req = client.request(path: "api/convos", authorized: true, queryItems: items)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ConversationsError.server(http.statusCode) }
        let page = try decoder.decode(ConversationsPage.self, from: data)
        return (page.conversations, page.nextCursor)
    }

    /// The exact inverse of `archiveConversation` (same route, `isArchived:
    /// false`), split into its own method so the spoken confirmation reads
    /// as a restore. Refreshes the main list on success so the restored
    /// conversation is already back in place -- the list's focus steering
    /// is covered-screen-guarded (session 24), so this background refresh
    /// can never yank VoiceOver focus out from under the archived screen.
    @discardableResult
    func unarchiveConversation(id: String, title: String) async -> Bool {
        var req = client.request(path: "api/convos/archive", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["arg": ["conversationId": id, "isArchived": false]]
        )
        do {
            let (_, http) = try await client.send(req)
            guard (200...201).contains(http.statusCode) else {
                actionMessage = "Couldn't restore \(title). Try again."
                return false
            }
            actionMessage = "Restored \(title). It's back in your conversations."
            await loadFirstPage()
            return true
        } catch {
            actionMessage = "Couldn't restore \(title). Try again."
            return false
        }
    }

    /// `KadeConversation` is a `let`-only value type (correct -- it models a
    /// server response), so a rename replaces the element rather than
    /// mutating it in place.
    private func applyLocalTitle(_ title: String, to id: String) {
        guard let index = conversations.firstIndex(where: { $0.conversationId == id }) else { return }
        let old = conversations[index]
        conversations[index] = KadeConversation(
            conversationId: old.conversationId,
            title: title,
            agentId: old.agentId,
            createdAt: old.createdAt,
            updatedAt: old.updatedAt
        )
    }

    /// DELETE /api/messages/:conversationId/:messageId -- answers **204**
    /// (no content), read straight off the fork's `api/server/routes/
    /// messages.js`, not assumed. Session 14, part of the widened message
    /// actions Kade asked for.
    ///
    /// Known and deliberate limitation, worth stating rather than hiding:
    /// this deletes ONE message, and because this client renders the flat
    /// chronological line rather than reconstructing the branch tree (the
    /// standing simplification documented on `fetchMessages`), deleting a
    /// message in the MIDDLE of a thread leaves its reply behind, orphaned
    /// and answering a question that is no longer there. The UI therefore
    /// only offers Delete on the last message or two -- see
    /// `ConversationDetailView.canDelete(_:)`.
    @discardableResult
    func deleteMessage(conversationId: String, messageId: String) async -> Bool {
        let req = client.request(
            path: "api/messages/\(conversationId)/\(messageId)",
            method: "DELETE",
            authorized: true
        )
        do {
            let (_, http) = try await client.send(req)
            guard (200...204).contains(http.statusCode) else {
                actionMessage = "Couldn't delete that message. Try again."
                return false
            }
            actionMessage = "Message deleted."
            return true
        } catch {
            actionMessage = "Couldn't delete that message. Try again."
            return false
        }
    }

    /// Fetches one conversation by id. Used by the post-call handoff to turn
    /// the transcript's `mergedConversationId` into a real
    /// `KadeConversation` it can navigate to.
    func fetchConversation(id: String) async -> KadeConversation? {
        let req = client.request(path: "api/convos/\(id)", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200 else { return nil }
        return try? decoder.decode(KadeConversation.self, from: data)
    }

    /// Share-link trio, contracts read off the fork's share.js (session 26,
    /// leftovers item 9). GET link/:id answers success:false for
    /// never-shared; POST :id mints; DELETE :shareId revokes with cleanup.
    func existingShare(conversationId: String) async -> String? {
        struct R: Decodable { let success: Bool?; let shareId: String? }
        let req = client.request(path: "api/share/link/\(conversationId)", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let r = try? decoder.decode(R.self, from: data), r.success == true else { return nil }
        return r.shareId
    }

    func createShare(conversationId: String) async -> String? {
        struct R: Decodable { let shareId: String? }
        var req = client.request(path: "api/share/\(conversationId)", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [:])
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let r = try? decoder.decode(R.self, from: data) else { return nil }
        return r.shareId
    }

    func revokeShare(shareId: String) async -> Bool {
        let req = client.request(path: "api/share/\(shareId)", method: "DELETE", authorized: true)
        guard let (_, http) = try? await client.send(req), http.statusCode == 200 else { return false }
        return true
    }

    /// The title the server generated for a BRAND-NEW conversation's first
    /// exchange. GET /api/convos/gen_title/:id -- the route long-polls its
    /// own title cache (backoff, ~15s max) and 404s if generation never
    /// happened, so nil here simply means "no name yet." Reading it also
    /// consumes the cache entry -- harmless: the title itself is persisted
    /// onto the conversation independently; the cache is only the
    /// "it's ready" notification channel the web client uses too.
    func fetchGeneratedTitle(conversationId: String) async -> String? {
        struct GenTitle: Codable { let title: String? }
        let req = client.request(path: "api/convos/gen_title/\(conversationId)", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200 else { return nil }
        return (try? decoder.decode(GenTitle.self, from: data))?.title
    }

    /// Polls the calls history for the conversation the just-finished call
    /// was minted into. Kade, session 14: "It doesn't drop you into your
    /// current voice conversation via text after the call."
    ///
    /// The whole flow, so the next person doesn't have to re-derive it: on
    /// hangup the bridge posts the transcript to `/api/kade/calls/ingest`,
    /// which asynchronously and fail-soft mints it into a normal chat
    /// conversation and stamps `mergedConversationId` back onto the
    /// transcript. That id is exposed on `GET /api/kade/calls` as of this
    /// session (it existed server-side all along but was never returned).
    /// Because the mint is in flight when the socket closes, the first read
    /// legitimately returns null -- so this POLLS rather than treating one
    /// null as "there isn't one," and gives up quietly rather than making
    /// the user wait forever on a server-side step that is allowed to fail.
    ///
    /// `startedAfter` guards against opening a STALE call's conversation if
    /// this one's transcript never lands (an empty call logs no transcript
    /// at all -- `logCallTranscript` returns early with zero turns).
    func awaitCallConversation(startedAfter: Date, attempts: Int = 8) async -> KadeConversation? {
        for attempt in 0..<attempts {
            // Back off gently: the mint usually lands within a couple of
            // seconds, and `KadeAPIClient`'s own pacing gate already spaces
            // these out, so this is deliberately unhurried.
            try? await Task.sleep(nanoseconds: UInt64((attempt == 0 ? 1.5 : 2.5) * 1_000_000_000))
            if Task.isCancelled { return nil }
            let req = client.request(
                path: "api/kade/calls",
                authorized: true,
                queryItems: [URLQueryItem(name: "limit", value: "3")]
            )
            guard let (data, http) = try? await client.send(req), http.statusCode == 200 else { continue }
            guard let page = try? decoder.decode(KadeCallsPage.self, from: data) else { continue }
            let fresh = page.calls.first {
                guard let merged = $0.mergedConversationId, !merged.isEmpty else { return false }
                guard let started = KadeDateFormatting.date(from: $0.startedAt) else { return false }
                // 90s of slack: `startedAt` is stamped when the CALL began,
                // which is a few seconds before this Date (also a call start),
                // never more. FIX (session 21): this was `-90 * 60` -- 90
                // MINUTES, not 90 seconds -- so an EMPTY call that minted no
                // conversation of its own (a Spotter call nobody answered)
                // would match an unrelated call from up to an hour and a half
                // earlier that DID have a `mergedConversationId`, and drop the
                // caller into THAT old conversation (the "it put me back in my
                // last Kiana chat" bug). At a real 90s window an empty call
                // resolves to nil and the call screen just dismisses home,
                // which is the correct "nothing to show" behavior.
                return started > startedAfter.addingTimeInterval(-90)
            }
            if let merged = fresh?.mergedConversationId,
               let convo = await fetchConversation(id: merged) {
                // The list this app is holding predates the new conversation,
                // so refresh it too -- otherwise going "back" from the
                // transcript lands on a list that doesn't contain it.
                await loadFirstPage()
                return convo
            }
        }
        return nil
    }

    private func fetchPage(cursor: String?) async throws -> ConversationsPage {
        var items: [URLQueryItem] = []
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let req = client.request(path: "api/convos", authorized: true, queryItems: items)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ConversationsError.server(http.statusCode) }
        return try decoder.decode(ConversationsPage.self, from: data)
    }
}
