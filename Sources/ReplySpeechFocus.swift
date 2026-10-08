import Foundation

struct ReplySpeechIdentity {
    let messageId: String
    let conversationId: String
    let isCreatedByUser: Bool
}

/// The owner-scoped request receipt can identify a reply when its short
/// stream has already ended. It never selects a message from history.
struct ReplyTaskReceipt: Decodable {
    let taskId: String
    let conversationId: String
    let status: String
    let responseMessageId: String?
    let canOpenConversation: Bool

    func completedReplyId(requestId: String, conversationId: String) -> String? {
        guard taskId == requestId, self.conversationId == conversationId,
              status == "completed", canOpenConversation,
              let responseMessageId, !responseMessageId.isEmpty else { return nil }
        return responseMessageId
    }
}

/// A reply's speech delivery may begin before its final text arrives.
/// Keep that history through completion so draining the queue cannot be
/// mistaken for a voice that never started.
struct ReplySpeechFocus {
    private(set) var playbackStarted = false
    private(set) var awaitingFirstClip = false

    static func acceptsReply(finalReplyId: String?, conversationId: String, message: ReplySpeechIdentity) -> Bool {
        guard let finalReplyId, !finalReplyId.isEmpty else { return false }
        return message.messageId == finalReplyId && message.conversationId == conversationId && !message.isCreatedByUser
    }

    mutating func reset() {
        playbackStarted = false
        awaitingFirstClip = false
    }

    mutating func playbackDidStart() {
        playbackStarted = true
        awaitingFirstClip = false
    }

    /// Successful completion never supplies a focus instruction. It only
    /// records whether a first character clip is still expected.
    mutating func completed(readAloudEnabled: Bool, hasAssistantReply: Bool) {
        let expectsSpeech = readAloudEnabled && hasAssistantReply
        awaitingFirstClip = expectsSpeech && !playbackStarted
    }

    /// An old isSpeaking-false edge cannot end a newer scheduled queue's
    /// wait. This only cleans up waiting; actual voice errors own their cue.
    mutating func queueDidDrain(hasPendingSpeech: Bool) -> Bool {
        guard !hasPendingSpeech else { return false }
        let endedWait = awaitingFirstClip
        awaitingFirstClip = false
        return endedWait
    }

    mutating func clearWait() {
        awaitingFirstClip = false
    }
}
