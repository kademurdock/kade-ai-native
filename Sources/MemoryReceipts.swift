import Foundation

/// Verified keeper artifacts attached to one persisted assistant reply.
struct MemoryReceipt: Decodable {
    struct Change: Decodable {
        let key: String?
        let type: String?
    }
    let type: String?
    let toolCallId: String?
    let messageId: String?
    let conversationId: String?
    let memory: Change?
}

struct MemoryReceiptScope: Equatable {
    let conversationId: String
    let messageId: String
}

struct MemoryReceiptTracker {
    let scope: MemoryReceiptScope
    private(set) var seen: Set<String>

    init(scope: MemoryReceiptScope, seen: Set<String> = []) {
        self.scope = scope
        self.seen = seen
    }

    mutating func consume(_ receipts: [MemoryReceipt]) -> [MemoryReceipt] {
        receipts.filter { receipt in
            guard receipt.type == "memory",
                  receipt.conversationId == scope.conversationId,
                  receipt.messageId == scope.messageId,
                  let call = receipt.toolCallId, !call.isEmpty,
                  let key = receipt.memory?.key, !key.isEmpty,
                  let kind = receipt.memory?.type,
                  kind == "update" || kind == "delete" else { return false }
            return seen.insert(call).inserted
        }
    }
}

struct MemoryReceiptWindow {
    static let maxAttempts = 12
    static let intervalSeconds: UInt64 = 4
    let deadline: Date

    init(start: Date) { deadline = start.addingTimeInterval(48) }
    func permits(attempt: Int, now: Date, cancelled: Bool = false, scopeMatches: Bool = true) -> Bool {
        !cancelled && scopeMatches && attempt < Self.maxAttempts && now < deadline
    }
}

/// A send captures this lease before any network await. Leaving the chat or
/// starting another send invalidates both active and not-yet-started recovery.
struct MemoryReceiptLease {
    private(set) var generation = UUID()
    mutating func invalidate() { generation = UUID() }
    func accepts(_ captured: UUID) -> Bool { captured == generation }
}
