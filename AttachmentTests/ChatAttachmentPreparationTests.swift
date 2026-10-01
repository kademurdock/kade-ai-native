import Combine
import XCTest
@testable import KadeAI

/// Synthetic bytes and injected uploads only: these tests do not read Photos,
/// request camera access, upload files, or start paid model generation.
@MainActor
final class ChatAttachmentPreparationTests: XCTestCase {
    private func file(_ name: String = "test.txt") -> ChatAttachment.PreparedFile {
        ChatAttachment.PreparedFile(data: Data("test".utf8), mimeType: "text/plain", fileName: name, width: nil, height: nil)
    }

    private func attachment(_ id: String) -> ChatAttachment {
        ChatAttachment(id: id, filepath: "https://example.invalid/\(id)", type: "text/plain", width: nil, height: nil, displayName: "test.txt")
    }

    func testCancelIgnoresOldUploadAndKeepsNextOperationBusy() async {
        let oldStarted = expectation(description: "old upload started")
        let nextStarted = expectation(description: "next upload started")
        let nextReady = expectation(description: "next attachment ready")
        var continuations: [CheckedContinuation<ChatAttachment, Error>] = []
        var readyIds: [String] = []
        let model = ChatAttachmentPreparation(uploader: { _, _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                if continuations.count == 1 { oldStarted.fulfill() }
                else { nextStarted.fulfill() }
            }
        })
        let client = KadeAPIClient()
        model.start(.prepared(file()), client: client, conversationId: "chat", agentId: "agent") {
            readyIds.append($0.id)
        }
        XCTAssertTrue(model.isBusy, "Send must be blocked before the worker starts")
        await fulfillment(of: [oldStarted], timeout: 1)
        model.cancel()
        XCTAssertFalse(model.isBusy)
        model.start(.prepared(file("next.txt")), client: client, conversationId: "chat", agentId: "agent") {
            readyIds.append($0.id)
            nextReady.fulfill()
        }
        await fulfillment(of: [nextStarted], timeout: 1)
        continuations[0].resume(returning: attachment("old"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.isBusy, "A late old upload must not clear the new spinner")
        XCTAssertTrue(readyIds.isEmpty, "A late old upload must not attach its file")
        continuations[1].resume(returning: attachment("next"))
        await fulfillment(of: [nextReady], timeout: 1)
        XCTAssertEqual(readyIds, ["next"])
        XCTAssertFalse(model.isBusy)
    }

    func testTimeoutClearsBusyAndLeavesExplicitRetry() async {
        let started = expectation(description: "upload started")
        let timedOut = expectation(description: "timeout shown")
        var continuation: CheckedContinuation<ChatAttachment, Error>?
        var ready = false
        let model = ChatAttachmentPreparation(uploadTimeoutNanoseconds: 20_000_000, uploader: { _, _, _, _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        let subscription = model.$errorMessage.compactMap { $0 }.sink { _ in timedOut.fulfill() }
        model.start(.prepared(file()), client: KadeAPIClient(), conversationId: nil, agentId: "agent") { _ in ready = true }
        await fulfillment(of: [started, timedOut], timeout: 1)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
        XCTAssertNotNil(model.errorMessage)
        continuation?.resume(returning: attachment("late"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(ready)
        XCTAssertNotNil(model.errorMessage)
        subscription.cancel()
        model.cancel()
    }

    func testManualRetryPreservesPreparedBytesAndOriginalContext() async {
        let failed = expectation(description: "failure shown")
        let ready = expectation(description: "retry ready")
        var attempts = 0
        let original = file("original.txt")
        let model = ChatAttachmentPreparation(uploader: { _, prepared, conversationId, agentId in
            attempts += 1
            XCTAssertEqual(prepared.data, original.data)
            XCTAssertEqual(prepared.fileName, "original.txt")
            XCTAssertEqual(conversationId, "original-chat")
            XCTAssertEqual(agentId, "original-agent")
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return self.attachment("retried")
        })
        let subscription = model.$errorMessage.compactMap { $0 }.sink { _ in failed.fulfill() }
        model.start(.prepared(original), client: KadeAPIClient(), conversationId: "original-chat", agentId: "original-agent") { _ in ready.fulfill() }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(attempts, 1, "A failure must not automatically upload again")
        model.retry()
        await fulfillment(of: [ready], timeout: 1)
        XCTAssertEqual(attempts, 2)
        subscription.cancel()
    }

    func testSharedSizeGuardRejectsEmptyAndOversizedBytes() {
        XCTAssertThrowsError(try ChatAttachment.prepare(data: Data(), mimeType: "text/plain", fileName: "empty.txt")) {
            guard case ChatAttachment.UploadError.emptyFile = $0 else { return XCTFail("Expected empty-file guard") }
        }
        XCTAssertThrowsError(try ChatAttachment.prepare(data: Data(count: Int(ChatAttachment.maxUploadBytes) + 1), mimeType: "text/plain", fileName: "large.txt")) {
            guard case ChatAttachment.UploadError.tooLarge = $0 else { return XCTFail("Expected size guard") }
        }
        XCTAssertThrowsError(try ChatAttachment.prepare(data: Data([1, 2, 3]), mimeType: "image/jpeg", fileName: "bad.jpg")) {
            guard case ChatAttachment.UploadError.unreadableImage = $0 else { return XCTFail("Expected invalid-image guard") }
        }
    }
}
