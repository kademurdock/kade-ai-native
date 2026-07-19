import Foundation

/// Parses the ISO-8601-with-fractional-seconds timestamps LibreChat sends
/// (e.g. "2026-07-18T21:56:38.762Z", verified live 2026-07-19) into
/// VoiceOver-friendly strings.
enum KadeDateFormatting {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from iso: String) -> Date? {
        isoWithFractional.date(from: iso) ?? isoPlain.date(from: iso)
    }

    /// "2 hours ago" — for conversation list rows. VoiceOver reads this naturally.
    static func relative(from iso: String) -> String? {
        guard let d = date(from: iso) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// A short clock time — for individual message timestamps.
    static func time(from iso: String) -> String? {
        guard let d = date(from: iso) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// The current moment in the same shape as `date(from:)` expects back —
    /// used to stamp an optimistic local message (Phase 3) before the
    /// server's own timestamp comes back from a refetch.
    static func isoNow() -> String {
        isoWithFractional.string(from: Date())
    }
}
