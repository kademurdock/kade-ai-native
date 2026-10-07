import Foundation

/// A reply's speech delivery may begin before its final text arrives.
/// Keep that history through completion so draining the queue cannot be
/// mistaken for a voice that never started.
struct ReplySpeechFocus {
    private(set) var playbackStarted = false
    private(set) var awaitingFirstClip = false

    mutating func reset() {
        playbackStarted = false
        awaitingFirstClip = false
    }

    mutating func playbackDidStart() {
        playbackStarted = true
        awaitingFirstClip = false
    }

    /// Whether VoiceOver should deliver the completed text immediately.
    mutating func completed(readAloudEnabled: Bool, hasAssistantReply: Bool) -> Bool {
        let expectsSpeech = readAloudEnabled && hasAssistantReply
        awaitingFirstClip = expectsSpeech && !playbackStarted
        return !expectsSpeech
    }

    /// Fall back only when this reply expected speech and none ever played.
    mutating func speechQueueDidFinish() -> Bool {
        let needsFallback = awaitingFirstClip && !playbackStarted
        awaitingFirstClip = false
        return needsFallback
    }

    mutating func clearWait() {
        awaitingFirstClip = false
    }
}
