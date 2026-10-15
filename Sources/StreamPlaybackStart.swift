import Foundation

/// These values select generation instructions or Inworld's supported API rate.
/// Audio players always use 1.0, including after a preference changes mid-clip.
enum VoicePacePolicy {
    static let fishOptions: [(value: String, label: String, rate: Double?)] = [
        ("character", "Character setting", nil), ("unhurried", "Unhurried", 0.75),
        ("easygoing", "Easygoing", 0.9), ("natural", "Natural", 1),
        ("brisk", "Brisk", 1.2), ("quick", "Quick", 1.5),
    ]
    static func rate(base: Double?, preference: Double?) -> Double {
        let value = preference ?? base ?? 1
        return value.isFinite ? min(1.5, max(0.5, value)) : 1
    }
    static func fishRate(_ pace: String, base: Double?) -> Double {
        rate(base: base, preference: fishOptions.first { $0.value == pace }?.rate)
    }
    static func isFish(voice: String?, providers: [String: String]) -> Bool {
        guard let voice else { return true }
        if let provider = providers[voice] { return provider == "fish" }
        return !voice.hasSuffix("(Classic)")
    }
    static func legacyFishPace(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, abs(rate - 1) > 0.001 else { return "character" }
        return fishOptions.filter { $0.rate != nil }.min {
            abs(($0.rate ?? 1) - rate) < abs(($1.rate ?? 1) - rate)
        }?.value ?? "character"
    }
    static func fishName(_ pace: String) -> String {
        fishOptions.first { $0.value == pace }?.label ?? "Character setting"
    }
}

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
