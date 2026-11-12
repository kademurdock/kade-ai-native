import Foundation

/// Phase 4 pick 4 (Nov 12 2026): rules for picking a dropped reply stream back
/// up. Pure Foundation, tested by run-voice-sync-tests.sh.
///
/// The fork gives every event it sends a number (`id: <epoch>-<seq>`, only for
/// a request that carries kadeSeq=1) and keeps a bounded log per job. A phone
/// that drops reconnects with the last number it holds (Last-Event-ID) and gets
/// exactly what came after. What the server cannot serve exactly it says with
/// a `kade_gap` event. Server switch: KADE_STREAM_LOG=0 (no ids, so the phone
/// never tries). Phone switch: UserDefaults kade.switch.streamResume.
enum StreamResume {
    static let maxAttempts = 8

    /// 0.5 s, 1 s, 2 s, then 4 s.
    static func delayNanos(attempt: Int) -> UInt64 {
        let seconds = min(4.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        return UInt64(seconds * 1_000_000_000)
    }

    /// "id: 9f3a1c2e-128" -> "9f3a1c2e-128". Anything else is nil.
    static func cursor(fromIdLine line: String) -> String? {
        guard line.hasPrefix("id:") else { return nil }
        let value = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8,
              parts[0].allSatisfy({ $0.isHexDigit }),
              !parts[1].isEmpty, parts[1].count <= 9,
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return value
    }

    /// What is left to speak when the stream could not be resumed exactly.
    /// nil means the place cannot be found safely: speak nothing and say so.
    static func tail(saved: String, delivered: String) -> String? {
        if delivered.isEmpty { return saved }
        if saved.hasPrefix(delivered) { return String(saved.dropFirst(delivered.count)) }
        let anchor = String(delivered.suffix(48))
        guard anchor.count >= 16,
              let first = saved.range(of: anchor),
              let last = saved.range(of: anchor, options: .backwards),
              first == last else { return nil }
        return String(saved[first.upperBound...])
    }
}
