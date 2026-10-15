import Foundation

/// A play command is not evidence that the renderer has advanced. One bounded
/// recovery may restart the same queued audio; it never synthesizes a new clip.
struct StreamPlaybackStart {
    enum Action: Equatable { case wait, recover, started, failed, cancelled }
    private var deadline: TimeInterval
    private var recovered = false
    private let grace: TimeInterval

    init(now: TimeInterval, grace: TimeInterval = 0.5) {
        self.grace = grace
        deadline = now + grace
    }

    mutating func observe(now: TimeInterval, renderedSeconds: Double?, completedBuffers: Int, current: Bool) -> Action {
        guard current else { return .cancelled }
        if let seconds = renderedSeconds, seconds.isFinite, seconds > 0 { return .started }
        // A very short clip may finish between clock polls.
        if completedBuffers > 0 { return .started }
        guard now >= deadline else { return .wait }
        guard !recovered else { return .failed }
        recovered = true
        deadline = now + grace
        return .recover
    }
}

/// Bounded replay of the SAME HTTP response, so a local player failure does
/// not bill another synthesis. An incomplete/error/oversized response cannot
/// masquerade as a complete clip. Owned and synchronized by StreamingClipFetch.
struct StreamAudioReplay {
    private var bytes = Data()
    private var eligible = true
    private var succeeded = false
    private let limit: Int

    init(limit: Int = 8 * 1024 * 1024) { self.limit = limit }

    mutating func append(_ data: Data) {
        guard eligible else { return }
        guard data.count <= limit - bytes.count else {
            eligible = false
            bytes = Data()
            return
        }
        bytes.append(data)
    }

    mutating func finish(success: Bool) { succeeded = success && eligible }
    var completeAudio: Data? { succeeded && !bytes.isEmpty ? bytes : nil }
}
