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

    /// Sep 23 2026: the ios-redesign-tour workflow runs on the same Codemagic
    /// simulator. That Mac has no audio hardware, so each CoreAudio call on
    /// the earcon and haptic warm-up waited thirty seconds on the main thread;
    /// the first screen never drew inside the tour's minute, and it
    /// photographed only the launch screen. DEBUG-only, like the audit.
    static var isTouring: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KADE_TOUR"] == "1"
        #else
        return false
        #endif
    }

    /// Either CI run: skip the audio and haptic warm-up.
    static var skipsAudioWarmup: Bool { isAuditing || isTouring }
}
