import Foundation

@main
struct MemoryReceiptTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("Memory receipt check failed: \(name)") }
            checks += 1
        }
        let scope = MemoryReceiptScope(conversationId: "conversation", messageId: "reply")
        func receipt(_ call: String, kind: String = "update", conversation: String = "conversation", message: String = "reply", key: String = "snack") throws -> MemoryReceipt {
            let object: [String: Any] = ["type": "memory", "toolCallId": call, "conversationId": conversation,
                "messageId": message, "memory": ["key": key, "type": kind]]
            return try JSONDecoder().decode(MemoryReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var tracker = MemoryReceiptTracker(scope: scope, seen: ["already-heard-live"])
        check(try tracker.consume([receipt("late-card")]).count == 1, "verified new card")
        check(try tracker.consume([receipt("late-card")]).isEmpty, "same receipt never reannounces")
        check(try tracker.consume([receipt("already-heard-live")]).isEmpty, "live SSE receipt not replayed")
        check(try tracker.consume([receipt("wrong-chat", conversation: "other")]).isEmpty, "wrong chat")
        check(try tracker.consume([receipt("historical", message: "old-reply")]).isEmpty, "historical reply")
        check(try tracker.consume([receipt("failure", kind: "error")]).isEmpty, "error is never a saved cue")
        check(try tracker.consume([receipt("", key: "snack")]).isEmpty, "missing tool call identity")
        check(try tracker.consume([receipt("missing-key", key: "")]).isEmpty, "empty key")
        check(try tracker.consume([receipt("forgotten", kind: "delete")]).count == 1, "verified deletion")
        let ordinary = try JSONDecoder().decode(MemoryReceipt.self, from: Data("{\"type\":\"image\",\"file_id\":\"photo\"}".utf8))
        check(tracker.consume([ordinary]).isEmpty, "ordinary attachment")
        let start = Date(timeIntervalSince1970: 100)
        let window = MemoryReceiptWindow(start: start)
        check(window.permits(attempt: 0, now: start), "initial window")
        check(window.permits(attempt: 11, now: start.addingTimeInterval(47)), "last bounded attempt")
        check(!window.permits(attempt: 12, now: start), "attempt cap")
        check(!window.permits(attempt: 0, now: start.addingTimeInterval(48)), "deadline cap")
        check(!window.permits(attempt: 0, now: start, cancelled: true), "in-flight cancellation")
        check(!window.permits(attempt: 0, now: start, scopeMatches: false), "stale response scope")
        var lease = MemoryReceiptLease()
        let firstSend = lease.generation
        check(lease.accepts(firstSend), "captured send permits recovery")
        lease.invalidate() // Leaving while the send still awaits FINAL.
        check(!lease.accepts(firstSend), "leave before final cannot start recovery")
        let nextSend = lease.generation
        lease.invalidate() // A newer send replaces that scope before its read returns.
        check(!lease.accepts(nextSend) && !lease.accepts(firstSend), "new send invalidates prior scopes")
        print("Memory receipt tests passed: \(checks)")
    }
}
