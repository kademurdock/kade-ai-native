import Foundation

/// One voice speed for every voice (Oct 16 2026, Kade: separate Fish and
/// Classic speed lists side by side were confusing). The chosen pace's value
/// rides the next synthesis request as `speed`; the proxy turns it into each
/// provider's own control. Audio players always use 1.0, including after a
/// preference changes mid-clip.
enum VoicePacePolicy {
    static let options: [(value: String, label: String, rate: Double?)] = [
        ("character", "Character's own speed", nil), ("unhurried", "Unhurried", 0.75),
        ("easygoing", "Easygoing", 0.9), ("natural", "Natural", 1),
        ("brisk", "Brisk", 1.2), ("quick", "Quick", 1.5),
    ]
    static func rate(base: Double?, preference: Double?) -> Double {
        let value = preference ?? base ?? 1
        return value.isFinite ? min(1.5, max(0.5, value)) : 1
    }
    /// The `speed` sent for a saved pace; "character" keeps the character's own rate.
    static func paceRate(_ pace: String, base: Double?) -> Double {
        rate(base: base, preference: options.first { $0.value == pace }?.rate)
    }
    /// The nearest named pace for an old numeric speed; normal or none keeps
    /// the character's own speed.
    static func legacyPace(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, abs(rate - 1) > 0.001 else { return "character" }
        return options.filter { $0.rate != nil }.min {
            abs(($0.rate ?? 1) - rate) < abs(($1.rate ?? 1) - rate)
        }?.value ?? "character"
    }
    /// One pace from the two older preferences: a chosen Fish pace wins,
    /// otherwise a non-normal Classic rate becomes its nearest pace.
    static func unifiedPace(fishPace: String?, classicRate: Double?) -> String {
        if let fishPace, fishPace != "character", options.contains(where: { $0.value == fishPace }) {
            return fishPace
        }
        return legacyPace(classicRate)
    }
    static func name(_ pace: String) -> String {
        options.first { $0.value == pace }?.label ?? "Character's own speed"
    }
    /// Short on-screen form: "Auto" for the character's own speed.
    static func chipLabel(_ pace: String) -> String {
        pace != "character" && options.contains(where: { $0.value == pace }) ? name(pace) : "Auto"
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
