import Foundation

/// PART 90 — the one place that knows an accessibility audit is driving the app.
///
/// Why this exists at all: `performAccessibilityAudit` runs inside XCUITest, and
/// XCUITest waits for the app to report itself IDLE before every single query.
/// An app that is never idle cannot be audited — every snapshot request waits
/// sixty seconds and then fails. Two live runs died exactly that way before this
/// file existed.
///
/// The rule for anything gated on this: it may only ever turn OFF work that a
/// simulator cannot use anyway (haptics nobody feels, earcons nobody hears). It
/// must NEVER change layout, labels, traits, text, or contrast — the audit has
/// to be looking at the same screen a real person meets, or it is auditing a
/// stunt double and its findings are worthless.
///
/// `#if DEBUG` throughout: a Release build does not contain this branch, so
/// there is no path from a CI flag to anything on Kade's phone.
enum KadeUITestMode {
    static var isAuditing: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KADE_A11Y_AUDIT"] == "1"
        #else
        return false
        #endif
    }
}
