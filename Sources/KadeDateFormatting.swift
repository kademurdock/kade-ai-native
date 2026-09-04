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

    /// Part 126 (Sep 4 2026), her ask: "it would be nice if the messages were
    /// more time-stamped on native the way they are on web." The web stamps
    /// every bubble with the date and the time; native carried the clock time
    /// only, so a message from last Tuesday read as "4:32 PM" with no day.
    /// This is the day AND the time, in words a screen reader says well:
    /// "Today 4:32 PM", "Yesterday 9:10 AM", "Tuesday 9:10 AM" inside a week,
    /// "Aug 21, 9:10 AM" beyond it, and the year only when it differs.
    static func stamp(from iso: String, now: Date = Date()) -> String? {
        guard let d = date(from: iso) else { return nil }
        let cal = Calendar.current
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        let t = tf.string(from: d)
        if cal.isDateInToday(d) { return "Today \(t)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(t)" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 99
        if days >= 0 && days < 7 {
            let wf = DateFormatter(); wf.setLocalizedDateFormatFromTemplate("EEEE")
            return "\(wf.string(from: d)) \(t)"
        }
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate(cal.component(.year, from: d) == cal.component(.year, from: now) ? "MMM d" : "MMM d, yyyy")
        return "\(df.string(from: d)), \(t)"
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
