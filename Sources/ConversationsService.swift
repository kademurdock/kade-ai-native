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

    var id: String { messageId }

    /// Assistant replies often carry their real content in `content` (text /
    /// think / tool_call blocks) with `text` left empty; user messages use
    /// `text` directly. Prefer `content`'s text blocks, fall back to `text`,
    /// and for an assistant turn that was pure tool activity (no text block
    /// at all) say so explicitly rather than rendering a silent empty bubble
    /// — a blind VoiceOver user has no other way to tell "nothing" apart
    /// from "this loaded wrong."
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

    private func fetchPage(cursor: String?) async throws -> ConversationsPage {
        var items: [URLQueryItem] = []
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let req = client.request(path: "api/convos", authorized: true, queryItems: items)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw ConversationsError.server(http.statusCode) }
        return try decoder.decode(ConversationsPage.self, from: data)
    }
}
