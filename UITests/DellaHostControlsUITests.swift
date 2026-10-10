import XCTest

/// Checks the real call/chat control tree in silent, paused simulator fixtures.
/// Nothing is tapped: send, recording, notifications and call actions stay idle.
/// Run only this class with the KadeAIA11yAudit scheme; the other UI audit walks
/// authenticated screens and has a different coverage contract.
final class DellaHostControlsUITests: XCTestCase {
    private struct Control {
        let element: XCUIElement
        let name: String
        let frame: CGRect
    }

    private struct FailedCheck: Error {
        let message: String
    }

    private var phase = ""
    private var checks = 0

    func testChatRoomyLight() throws {
        try checkChat("chat-roomy-light", attachment: false, invitation: false, keyboard: false)
    }

    func testChatPackedDark() throws {
        try checkChat("chat-packed-dark", attachment: true, invitation: true, keyboard: false)
    }

    func testChatKeyboardDark() throws {
        try checkChat("chat-keyboard-dark", attachment: true, invitation: true, keyboard: true)
    }

    func testChatAccessibilityDark() throws {
        try checkChat("chat-a11y-dark", attachment: true, invitation: true, keyboard: false)
    }

    func testCallRoomyLight() throws {
        try checkCall("call-roomy-light", secondaryControlsVisible: true)
    }

    func testCallCaptionsDark() throws {
        try checkCall("call-captions-dark", secondaryControlsVisible: false)
    }

    func testCallCaptionsScrolledDark() throws {
        try checkCall("call-captions-scrolled-dark", secondaryControlsVisible: true)
    }

    func testCallCameraLight() throws {
        try checkCall("call-camera-light", secondaryControlsVisible: false)
    }

    func testCallCameraScrolledDark() throws {
        try checkCall("call-camera-scrolled-dark", secondaryControlsVisible: true)
    }

    func testCallAccessibilityDark() throws {
        try checkCall("call-a11y-dark", secondaryControlsVisible: false)
    }

    func testCallAccessibilityScrolledDark() throws {
        try checkCall("call-a11y-scrolled-dark", secondaryControlsVisible: true)
    }

    private func launch(_ requestedPhase: String) throws -> XCUIApplication {
        phase = requestedPhase
        checks = 0
        let app = XCUIApplication()
        app.launchEnvironment = [
            "KADE_CHARACTER_AUDIT": "1",
            "KADE_A11Y_AUDIT": "1",
            "KADE_DELLA_HOST_AUDIT": "1",
            "KADE_DELLA_HOST_CASE": requestedPhase,
            // Reject inherited selectors for the separate art/lab fixtures.
            "KADE_PUPPET_LAB": "0",
            "KADE_DELLA_ARTICULATED_AUDIT": "0",
            "KADE_CHAT_LAYOUT_AUDIT": "0",
            "KADE_CALL_LAYOUT_AUDIT": "0",
            "KADE_TOUR": "0"
        ]
        app.launch()
        try require(app.wait(for: .runningForeground, timeout: 20), "app became foreground")
        let firstID = requestedPhase.hasPrefix("chat-")
            ? "della-host.chat.composer-field" : "della-host.call.hang-up"
        try require(app.descendants(matching: .any).matching(identifier: firstID)
            .firstMatch.waitForExistence(timeout: 20), "actual host exposed " + firstID)
        if requestedPhase.contains("scrolled") {
            let target = app.buttons.matching(identifier: "della-host.call.deep-think").firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.isHittable == true
            }, object: target)
            try require(XCTWaiter.wait(for: [ready], timeout: 15) == .completed,
                        "fixture completed its scroll before control checks")
        }
        return app
    }

    private func checkChat(_ requestedPhase: String, attachment: Bool,
                           invitation: Bool, keyboard: Bool) throws {
        let app = try launch(requestedPhase)
        defer { app.terminate() }
        if keyboard {
            try require(app.keyboards.firstMatch.waitForExistence(timeout: 10), "software keyboard is present")
        } else {
            try require(app.keyboards.count == 0, "software keyboard is absent")
        }

        let fieldMatches = app.descendants(matching: .any)
            .matching(identifier: "della-host.chat.composer-field")
        try require(fieldMatches.count == 1, "one native composer field")
        let field = fieldMatches.element(boundBy: 0)
        try require(field.elementType == .textField || field.elementType == .textView,
                    "composer retains its native text control")
        try require(field.label == "Message", "composer label is Message")
        try require(field.isEnabled && field.isHittable, "composer is enabled and reachable")
        let fieldFrame = try visibleFrame(field, in: app, name: "composer")

        let send = try button(app, identifier: "della-host.chat.send", label: "Send message")
        let attach = try button(app, identifier: "della-host.chat.attach",
                                label: attachment ? "Attachment added" : "Attach a photo or file",
                                enabled: !attachment, reachable: !attachment)
        let mic = try button(app, label: "Record a voice message")
        let thinking = try button(app, label: "Thinking")
        let agent = try button(app, label: "Talking to Della")
        let voice = try button(app, label: "Voice")
        let hearReplies = try button(app, label: "Hear replies")
        let speed = try button(app, label: "Voice speed")
        try require(nonemptyValue(thinking.element), "Thinking exposes its separate state value")
        try require(nonemptyValue(hearReplies.element), "Hear replies exposes its separate state value")
        try require(nonemptyValue(speed.element), "Voice speed exposes its separate rate value")
        try disjoint([send, attach, mic, thinking, agent, voice, hearReplies, speed])
        for control in [send, attach, mic, thinking] {
            try require(!overlaps(fieldFrame, control.frame), "composer does not cover " + control.name)
        }

        if attachment {
            // The fixture uses the real pending-attachment row. Do not remove it.
            _ = try button(app, label: "Remove attachment", minimumTarget: false)
            try require(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Attached: ")).count == 1,
                        "attachment status remains a separate readable element")
        }
        if invitation {
            let turnOn = try button(app, label: "Turn on notifications")
            let notNow = try button(app, label: "Not now")
            try disjoint([turnOn, notNow, send, mic])
        }
        passed()
    }

    private func checkCall(_ requestedPhase: String, secondaryControlsVisible: Bool) throws {
        let app = try launch(requestedPhase)
        defer { app.terminate() }
        let mute = try button(app, identifier: "della-host.call.mute", label: "Mute microphone")
        let hangUp = try button(app, identifier: "della-host.call.hang-up", label: "Hang Up")
        try require(nonemptyValue(mute.element), "Mute exposes its microphone state")
        try disjoint([mute, hangUp])

        // All secondary controls must retain independent native buttons, even
        // when long captions place them below the initial scroll viewport.
        let camera = try button(app, identifier: "della-host.call.camera", label: "Camera",
                                reachable: secondaryControlsVisible)
        let spotter = try button(app, identifier: "della-host.call.spotter", label: "Spotter",
                                 reachable: secondaryControlsVisible)
        let deepThink = try button(app, identifier: "della-host.call.deep-think", label: "Deep think",
                                   reachable: secondaryControlsVisible)
        for control in [camera, spotter, deepThink] {
            try require(nonemptyValue(control.element), control.name + " exposes its separate state value")
        }
        if secondaryControlsVisible {
            try disjoint([mute, hangUp, camera, spotter, deepThink])
        }
        try require(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "You said: ")).count == 1,
                    "user caption is a separate accessibility element")
        try require(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Della said: ")).count == 1,
                    "Della caption is a separate accessibility element")
        passed()
    }

    private func button(_ app: XCUIApplication, identifier: String? = nil, label: String,
                        enabled: Bool = true, reachable: Bool = true,
                        minimumTarget: Bool = true) throws -> Control {
        let matches = identifier.map { app.buttons.matching(identifier: $0) }
            ?? app.buttons.matching(NSPredicate(format: "label == %@", label))
        try require(matches.count == 1, "one separate native button for " + label)
        let element = matches.element(boundBy: 0)
        try require(element.label == label, "expected button label for " + label)
        try require(element.isEnabled == enabled, "expected enabled state for " + label)
        if reachable { try require(element.isHittable, label + " is reachable") }
        let frame = element.frame
        try require(valid(frame), label + " has a finite, nonempty frame")
        if minimumTarget {
            try require(frame.width >= 44 && frame.height >= 44,
                        label + " has a 44pt target (actual " + dimensions(frame) + ")")
        }
        if reachable { _ = try visibleFrame(element, in: app, name: label) }
        return Control(element: element, name: label, frame: frame)
    }

    private func visibleFrame(_ element: XCUIElement, in app: XCUIApplication, name: String) throws -> CGRect {
        let frame = element.frame
        let window = app.frame
        try require(valid(frame) && valid(window), name + " has usable screen geometry")
        try require(window.insetBy(dx: -0.5, dy: -0.5).contains(frame), name + " fits entirely on screen")
        return frame
    }

    private func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    private func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        let intersection = first.intersection(second)
        return !intersection.isNull && intersection.width > 0.5 && intersection.height > 0.5
    }

    private func disjoint(_ controls: [Control]) throws {
        for first in controls.indices {
            for second in controls.indices where second > first {
                try require(!overlaps(controls[first].frame, controls[second].frame),
                            controls[first].name + " does not overlap " + controls[second].name)
            }
        }
    }

    private func nonemptyValue(_ element: XCUIElement) -> Bool {
        guard let value = element.value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func dimensions(_ frame: CGRect) -> String {
        String(format: "%.2f x %.2f", Double(frame.width), Double(frame.height))
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        checks += 1
        guard condition() else {
            print("KADE_DELLA_HOST_CONTROLS_FAILED " + phase + " " + message)
            XCTFail(phase + ": " + message, file: file, line: line)
            throw FailedCheck(message: message)
        }
    }

    private func passed() {
        print("KADE_DELLA_HOST_CONTROLS_PASSED \(checks) \(phase)")
    }
}
