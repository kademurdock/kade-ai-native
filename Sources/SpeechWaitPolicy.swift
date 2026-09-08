import Foundation

enum SpeechWaitPolicy {
    enum Phase { case waiting, reply, thinking, tool, finished }

    static func shouldResume(phase: Phase, turnLive: Bool, clipPlaying: Bool, paused: Bool, speechQueued: Bool) -> Bool {
        guard turnLive, !clipPlaying, !paused, !speechQueued else { return false }
        return phase == .waiting || phase == .thinking || phase == .tool
    }
}
