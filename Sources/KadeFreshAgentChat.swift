import Foundation

/// A tap asks for an empty composer with this exact agent. The nonce belongs to
/// this navigation request, never to a saved/server conversation or message.
struct KadeFreshAgentChatRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let agentID: String

    init?(agentID: String, requestID: UUID = UUID()) {
        guard Self.isGeneratedAgentID(agentID) else { return nil }
        self.id = requestID
        self.agentID = agentID
    }

    static func isGeneratedAgentID(_ value: String) -> Bool {
        // Server-created LibreChat agents use the agent_ prefix and nanoid21.
        let bytes = Array(value.utf8)
        guard bytes.count == 27, value.hasPrefix("agent_") else { return false }
        return bytes.dropFirst(6).allSatisfy {
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

enum KadeTalkLinkTarget: Equatable {
    case main
    case agent(KadeFreshAgentChatRequest)
    case invalid
}

enum KadeFreshAgentChatParser {
    static let routeName = "agent-chat"

    /// Custom APNs fields are parsed only after a notification response (tap),
    /// never on receipt/background delivery. Arrays, numbers and empty values
    /// cannot turn into an invented or default agent.
    static func push(routeName: String, agentValue: Any?) -> KadeFreshAgentChatRequest? {
        guard let agentID = targetID(routeName: routeName, agentValue: agentValue) else { return nil }
        return KadeFreshAgentChatRequest(agentID: agentID)
    }

    static func targetID(routeName: String, agentValue: Any?) -> String? {
        guard routeName == Self.routeName, let agentID = agentValue as? String,
              KadeFreshAgentChatRequest.isGeneratedAgentID(agentID) else { return nil }
        return agentID
    }

    /// Distinguishes a plain Talk link from an explicitly malformed agent
    /// target. Duplicate query parameters are refused even if their values match.
    static func talkLink(_ url: URL) -> KadeTalkLinkTarget {
        guard url.scheme?.lowercased() == "kadeai", url.host?.lowercased() == "talk",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty || url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .invalid }
        let targets = (components.queryItems ?? []).filter { $0.name == "agent" }
        guard !targets.isEmpty else { return .main }
        guard targets.count == 1, let value = targets[0].value,
              let request = KadeFreshAgentChatRequest(agentID: value) else { return .invalid }
        return .agent(request)
    }
}

/// The latest explicit tap wins. Signed-out/session-restoration attempts leave
/// the request parked; a ready consumer removes it before opening the view.
/// Contains no draft, transcript, account data or server-creation operation.
struct KadeFreshAgentChatInbox {
    private(set) var pending: KadeFreshAgentChatRequest?

    mutating func park(_ request: KadeFreshAgentChatRequest) { pending = request }
    mutating func cancel() { pending = nil }
    mutating func consume(authReady: Bool) -> KadeFreshAgentChatRequest? {
        guard authReady else { return nil }
        let request = pending
        pending = nil
        return request
    }
}
