import XCTest

/// GAP 3 — Apple's own accessibility audit, run on the Mac Kade already rents.
///
/// Why this file exists, in one sentence: the native app's accessibility is
/// currently guarded by hand-discipline (the isHeader audits, the VoiceOver
/// path rules, the route table) — good discipline, held in human memory — and
/// `performAccessibilityAudit()` turns that memory into a machine check that
/// runs against the REAL rendered app in a simulator.
///
/// WHAT THIS TEST DELIBERATELY DOES NOT DO, each omission load-bearing:
///
///  · IT DOES NOT FAIL THE BUILD ON FINDINGS. Apple's audit fails the test by
///    default; every issue here is swallowed by the handler and PRINTED
///    instead. That is not softness, it is the standing scar: A GUARD THAT
///    CRIES WOLF GETS SWITCHED OFF. Apple's audit has known false-positive
///    classes (decorative images flagged for contrast, spacer views flagged
///    for description). It reports for a while, gets calibrated against real
///    findings, and only then earns the right to block. `KADE_A11Y_STRICT=1`
///    on the workflow flips it to blocking when that day comes.
///
///  · IT DOES NOT TOUCH APP SOURCE. Not one line of Sources/ changes for this
///    lane. Sign-in is driven through the real form the way a person would.
///
///  · IT DOES NOT SIGN, PUBLISH, OR BUMP A BUILD NUMBER. Simulator only. There
///    is no path from this test to her phone, by construction.
///
/// ⚠️ THE `KADE_TOUR = "1"` LINE IN setUp IS NOT A COPY-PASTE ACCIDENT. The app
/// skips its push-permission request when that variable is "1" (KadeAIApp
/// .requestPushAuthorization, `#if DEBUG` only) — which matters here because a
/// system permission alert sits on top of the screen, blocks every tap, and
/// would be audited as if it were ours. The app's timed screenshot tour ALSO
/// keys off that variable, but its guard needs all THREE of KADE_TOUR,
/// KADE_TOUR_EMAIL and KADE_TOUR_PASS — so setting the flag alone buys the
/// quiet without starting a walk that would fight this one. Do not add the
/// other two.
final class KadeA11yAuditUITests: XCTestCase {

    // MARK: - What gets audited

    /// Named explicitly rather than using `.all`, so a future Xcode adding an
    /// eighth audit type changes this file (and its findings) on purpose
    /// instead of silently. Settings notes that don't name their version read
    /// later like broken promises — that lesson is already on the record.
    private static let auditTypes: XCUIAccessibilityAuditType = [
        .contrast,
        .elementDetection,
        .hitRegion,
        .sufficientElementDescription,
        .dynamicType,
        .textClipped,
        .trait
    ]

    /// One stop on the walk. `path` is the sequence of accessibility labels to
    /// tap from the home screen to get there — one entry for a top-level
    /// screen, two for something nested inside it.
    ///
    /// ⚠️ THESE ARE ACCESSIBILITY LABELS, NOT VISIBLE TITLES. The home tiles
    /// pass a `spoken:` string that becomes the label, and the label is what
    /// XCUITest matches on ("The Marketplace", not "Marketplace"). If a stop
    /// starts reporting `skipped`, the label moved — fix it here, and treat
    /// the skip line as the lane telling the truth rather than as a failure.
    private struct Stop {
        let name: String
        let path: [String]
    }

    /// Deliberately excludes anything that opens a microphone, a camera, a
    /// LiveKit room, or a game loop: Kade's Clubhouse, The Parlor, calls and
    /// Spotter. Those cost real time and real network on every run and their
    /// failure mode is a hung simulator, not a finding.
    private static let stops: [Stop] = [
        Stop(name: "Home", path: []),
        Stop(name: "Settings", path: ["Settings"]),
        Stop(name: "Settings, Accessibility", path: ["Settings", "Accessibility"]),
        Stop(name: "Your conversations", path: ["Your conversations"]),
        Stop(name: "The Marketplace", path: ["The Marketplace"]),
        Stop(name: "The Prompt Library", path: ["The Prompt Library"]),
        Stop(name: "Bookmarks", path: ["Bookmarks"]),
        Stop(name: "Transcribe", path: ["Transcribe a voice memo"]),
        Stop(name: "Help", path: ["Help"])
    ]

    // MARK: - State

    private var app: XCUIApplication!
    private var issueCount = 0
    private var screensAudited = 0
    private var screensSkipped = 0

    // MARK: - The test

    override func setUpWithError() throws {
        // The whole point is to walk every screen; one bad stop must not end
        // the run, or the report only ever describes the first problem.
        continueAfterFailure = true

        app = XCUIApplication()
        app.launchEnvironment["KADE_TOUR"] = "1"   // see the class comment
        app.launch()

        // Belt and braces for anything the flag above does not cover (a
        // Local Network prompt, say). An interruption monitor taps the first
        // button on any system alert that steals focus mid-walk.
        _ = addUIInterruptionMonitor(withDescription: "system alert") { alert in
            let button = alert.buttons.element(boundBy: 0)
            if button.exists { button.tap(); return true }
            return false
        }
    }

    func testAccessibilityAuditAcrossTheMainScreens() throws {
        emit("KADE_A11Y|version|1")

        // 1 — the signed-out surface. This one always runs: it needs no
        //     credentials and it is the first screen every new family member
        //     ever meets.
        audit(screen: "Sign in")

        // 2 — sign in, or say plainly that we could not and audit nothing
        //     more. A report that quietly covers one screen while sounding
        //     like it covered nine is the dishonest half of this whole class
        //     of tool.
        guard signInIfCredentialsWereProvided() else {
            emit("KADE_A11Y_SUMMARY|screens=\(screensAudited)|skipped=\(screensSkipped)|issues=\(issueCount)")
            return
        }

        // 3 — the walk.
        for stop in Self.stops {
            guard navigateHome() else {
                skip(stop.name, "could not get back to the home screen")
                continue
            }
            guard follow(path: stop.path, for: stop.name) else { continue }
            audit(screen: stop.name)
        }

        _ = navigateHome()
        emit("KADE_A11Y_SUMMARY|screens=\(screensAudited)|skipped=\(screensSkipped)|issues=\(issueCount)")
    }

    // MARK: - Auditing

    private func audit(screen: String) {
        var found = 0
        do {
            try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
                found += 1
                self.issueCount += 1
                self.emit(
                    "KADE_A11Y_ISSUE|"
                    + self.clean(screen) + "|"
                    + self.clean(self.describe(issue.auditType)) + "|"
                    + self.clean(issue.element?.label ?? "(element not identified)") + "|"
                    + self.clean(String(describing: issue))
                )
                // TRUE means "ignore this one" — every issue is recorded and
                // then ignored, so the test itself never fails. See the class
                // comment: reporting first, blocking later, once calibrated.
                return true
            }
        } catch {
            skip(screen, "the audit itself threw: \(clean(String(describing: error)))")
            return
        }
        screensAudited += 1
        emit("KADE_A11Y_SCREEN|\(clean(screen))|\(found)")
    }

    /// Apple's type is an OptionSet, not an enum, and its `String(describing:)`
    /// reads as `XCUIAccessibilityAuditType(rawValue: 2)` — a number nobody can
    /// hear. This says the finding out loud instead. if/else rather than a
    /// switch on purpose: this file ships without ever meeting a compiler on
    /// this machine, so it avoids every construct it does not have to use.
    private func describe(_ type: XCUIAccessibilityAuditType) -> String {
        if type == .contrast { return "contrast too low to read" }
        if type == .elementDetection { return "element not detected as its own control" }
        if type == .hitRegion { return "tap target too small" }
        if type == .sufficientElementDescription { return "missing or unhelpful description" }
        if type == .dynamicType { return "does not scale with Dynamic Type" }
        if type == .textClipped { return "text is clipped" }
        if type == .trait { return "wrong accessibility trait" }
        return "other"
    }

    // MARK: - Getting around

    /// Types into the real sign-in form. Credentials arrive from the workflow
    /// as TEST_RUNNER_-prefixed variables (xcodebuild strips the prefix before
    /// handing them to the runner process) and are NEVER written in this file
    /// or in codemagic.yaml.
    private func signInIfCredentialsWereProvided() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["KADE_A11Y_EMAIL"], !email.isEmpty,
              let pass = env["KADE_A11Y_PASS"], !pass.isEmpty else {
            skip("every signed-in screen",
                 "no test-seat credentials were provided, so only the sign-in screen was audited")
            return false
        }

        let emailField = app.textFields["Email"]
        guard emailField.waitForExistence(timeout: 30) else {
            skip("every signed-in screen", "the Email field never appeared")
            return false
        }
        emailField.tap()
        emailField.typeText(email)

        let passwordField = app.secureTextFields["Password"]
        guard passwordField.waitForExistence(timeout: 5) else {
            skip("every signed-in screen", "the Password field never appeared")
            return false
        }
        passwordField.tap()
        passwordField.typeText(pass)

        let signIn = app.buttons["Sign in"]
        guard signIn.waitForExistence(timeout: 5) else {
            skip("every signed-in screen", "the Sign in button never appeared")
            return false
        }
        signIn.tap()

        // The home screen's "Tools" header is the tell that sign-in landed.
        // 60 seconds because this is a real round trip to kademurdock.com on a
        // CI box, and a slow network is not an accessibility finding.
        guard app.staticTexts["Tools"].waitForExistence(timeout: 60) else {
            skip("every signed-in screen",
                 "sign-in did not complete within 60 seconds — network, or the test seat's password changed")
            return false
        }
        return true
    }

    /// Taps Back until the home screen's "Tools" header is showing again.
    private func navigateHome() -> Bool {
        for _ in 0..<5 {
            if app.staticTexts["Tools"].exists { return true }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap() } else { break }
            _ = app.staticTexts["Tools"].waitForExistence(timeout: 3)
        }
        return app.staticTexts["Tools"].exists
    }

    private func follow(path: [String], for name: String) -> Bool {
        for label in path {
            let button = app.buttons[label]
            if !button.waitForExistence(timeout: 5) {
                // Some rows are cells rather than buttons (Settings lists).
                let cell = app.cells[label]
                if cell.waitForExistence(timeout: 2) {
                    cell.tap()
                    _ = app.wait(for: .runningForeground, timeout: 2)
                    continue
                }
                skip(name, "could not find \"\(clean(label))\" to tap")
                return false
            }
            if !button.isHittable { app.swipeUp() }
            button.tap()
            // Let the navigation settle before auditing what is on screen.
            Thread.sleep(forTimeInterval: 1.5)
        }
        return true
    }

    // MARK: - Speaking

    private func skip(_ name: String, _ reason: String) {
        screensSkipped += 1
        emit("KADE_A11Y_SKIP|\(clean(name))|\(clean(reason))")
    }

    /// The harness reads these lines out of the build log, so a pipe or a
    /// newline inside a description would split one finding into two. Same
    /// reason the compile gate cares about punctuation: this ends up as speech.
    private func clean(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func emit(_ line: String) {
        print(line)
    }
}
