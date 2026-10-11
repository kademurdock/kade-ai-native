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

    private struct ChatCore {
        let fieldFrame: CGRect
        let controls: [Control]
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
        try checkChat("chat-keyboard-dark", attachment: true, invitation: true,
                      keyboard: true, invitationVisible: false)
    }

    func testChatKeyboardScrolledDark() throws {
        try checkChat("chat-keyboard-scrolled-dark", attachment: true, invitation: true, keyboard: true)
    }

    func testChatAccessibilityDark() throws {
        try checkChat("chat-a11y-dark", attachment: true, invitation: true,
                      keyboard: false, invitationVisible: false)
    }

    func testChatAccessibilityScrolledDark() throws {
        try checkChat("chat-a11y-scrolled-dark", attachment: true, invitation: true, keyboard: false)
    }

    func testChatAccessibilityKeyboardDark() throws {
        try checkChat("chat-a11y-keyboard-dark", attachment: true, invitation: true,
                      keyboard: true, invitationVisible: false, optionalControlsVisible: false)
    }

    func testChatAccessibilityKeyboardCardScrolledDark() throws {
        try checkChat("chat-a11y-keyboard-card-scrolled-dark", attachment: true, invitation: true,
                      keyboard: true, optionalControlsVisible: false)
    }

    func testChatAccessibilityKeyboardControlsScrolledDark() throws {
        try checkChat("chat-a11y-keyboard-controls-scrolled-dark", attachment: true, invitation: true,
                      keyboard: true, invitationVisible: false)
    }

    func testChatAccessibilitySmallLight() throws {
        try checkChat("chat-a11y-small-light", attachment: true, invitation: true,
                      keyboard: false, invitationVisible: false, optionalControlsVisible: false)
    }

    func testChatAccessibilityCardScrolledSmallLight() throws {
        try checkChat("chat-a11y-card-scrolled-small-light", attachment: true, invitation: true,
                      keyboard: false, optionalControlsVisible: false)
    }

    func testChatAccessibilityControlsScrolledSmallLight() throws {
        try checkChat("chat-a11y-controls-scrolled-small-light", attachment: true, invitation: true,
                      keyboard: false, invitationVisible: false)
    }

    func testChatAccessibilityKeyboardSmallLight() throws {
        try checkChat("chat-a11y-keyboard-small-light", attachment: true, invitation: true,
                      keyboard: true, invitationVisible: false, optionalControlsVisible: false)
    }

    func testChatAccessibilityKeyboardCardScrolledSmallLight() throws {
        try checkChat("chat-a11y-keyboard-card-scrolled-small-light", attachment: true, invitation: true,
                      keyboard: true, optionalControlsVisible: false, dismissKeyboardByDragging: true)
    }

    func testChatAccessibilityKeyboardControlsScrolledSmallLight() throws {
        try checkChat("chat-a11y-keyboard-controls-scrolled-small-light", attachment: true, invitation: true,
                      keyboard: true, invitationVisible: false, dismissKeyboardByDragging: true)
    }

    func testChatAccessibilityEmptyKeyboardSmallLight() throws {
        try checkChat("chat-a11y-empty-keyboard-small-light", attachment: true, invitation: true,
                      keyboard: true, invitationVisible: false, optionalControlsVisible: false)
    }

    func testChatAccessibilityEmptyControlsScrolledSmallLight() throws {
        try checkChat("chat-a11y-empty-controls-scrolled-small-light", attachment: true, invitation: true,
                      keyboard: false, invitationVisible: false)
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

    private func launch(_ requestedPhase: String, uiDrag: Bool = false) throws -> XCUIApplication {
        phase = requestedPhase
        checks = 0
        let app = XCUIApplication()
        app.launchEnvironment = [
            "KADE_CHARACTER_AUDIT": "1",
            "KADE_A11Y_AUDIT": "1",
            "KADE_DELLA_HOST_AUDIT": "1",
            "KADE_DELLA_HOST_CASE": requestedPhase,
            "KADE_DELLA_HOST_UI_DRAG": uiDrag ? "1" : "0",
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
        if requestedPhase.contains("scrolled") && !uiDrag {
            let targetID: String
            if requestedPhase.hasPrefix("call-") { targetID = "della-host.call.deep-think" }
            else if requestedPhase.contains("controls-scrolled") { targetID = "della-host.chat.speed" }
            else { targetID = "della-host.chat.invite-not-now" }
            let target = app.buttons.matching(identifier: targetID).firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.isHittable == true
            }, object: target)
            try require(XCTWaiter.wait(for: [ready], timeout: 15) == .completed,
                        "fixture completed its scroll before control checks")
        }
        return app
    }

    private func checkChat(_ requestedPhase: String, attachment: Bool,
                           invitation: Bool, keyboard: Bool, invitationVisible: Bool = true,
                           optionalControlsVisible: Bool = true,
                           dismissKeyboardByDragging: Bool = false) throws {
        let app = try launch(requestedPhase, uiDrag: dismissKeyboardByDragging)
        defer { app.terminate() }
        let expected = requestedPhase.contains("-small-")
            ? CGSize(width: 375, height: 667) : CGSize(width: 440, height: 956)
        try require(abs(app.frame.width - expected.width) <= 1
                    && abs(app.frame.height - expected.height) <= 1,
                    "test uses the requested real phone window")
        var core = try checkChatCore(app, attachment: attachment, keyboard: keyboard)
        if dismissKeyboardByDragging {
            // The fixture deliberately leaves the real keyboard and scroll
            // position alone. Only this native viewport drag may dismiss it.
            try dragTranscript(app)
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                (object as? XCUIApplication)?.keyboards.count == 0
            }, object: app)
            try require(XCTWaiter.wait(for: [hidden], timeout: 10) == .completed,
                        "real transcript drag dismisses the software keyboard")
            try scrollTranscriptToTarget(app)
            core = try checkChatCore(app, attachment: attachment, keyboard: false)
        }

        let agent = try button(app, identifier: "della-host.chat.agent", label: "Talking to Della",
                               reachable: optionalControlsVisible)
        let voice = try button(app, identifier: "della-host.chat.voice", label: "Voice",
                               reachable: optionalControlsVisible)
        let hearReplies = try hearRepliesToggle(app, reachable: optionalControlsVisible)
        let speed = try button(app, identifier: "della-host.chat.speed", label: "Voice speed",
                               reachable: optionalControlsVisible)
        let optionalControls = [agent, voice, hearReplies, speed]
        try require(nonemptyValue(speed.element), "Voice speed exposes its separate rate value")
        if optionalControlsVisible {
            try disjoint(optionalControls + core.controls)
            for control in optionalControls {
                try require(!overlaps(core.fieldFrame, control.frame),
                            "composer does not cover " + control.name + " [editor=" + rectangle(core.fieldFrame)
                                + " control=" + rectangle(control.frame) + "]")
            }
            if requestedPhase.contains("controls-scrolled") {
                try controlsInsideTranscript(optionalControls, in: app)
            }
            if keyboard && !dismissKeyboardByDragging {
                let keyboardFrame = app.keyboards.firstMatch.frame
                for control in optionalControls {
                    try require(control.frame.maxY <= keyboardFrame.minY + 0.5,
                                control.name + " stays above the keyboard [control=" + rectangle(control.frame)
                                    + " keyboard=" + rectangle(keyboardFrame) + "]")
                }
            }
        }
        if invitation {
            let turnOn = try button(app, identifier: "della-host.chat.invite-turn-on",
                                    label: "Turn on notifications", reachable: invitationVisible)
            let notNow = try button(app, identifier: "della-host.chat.invite-not-now",
                                    label: "Not now", reachable: invitationVisible)
            if invitationVisible {
                let visibleControls = core.controls + (optionalControlsVisible ? optionalControls : [])
                try disjoint([turnOn, notNow] + visibleControls)
                try require(!overlaps(core.fieldFrame, turnOn.frame)
                            && !overlaps(core.fieldFrame, notNow.frame),
                            "invitation does not cover the composer")
                if requestedPhase.contains("scrolled") {
                    try controlsInsideTranscript([turnOn, notNow], in: app)
                }
                if keyboard && !dismissKeyboardByDragging {
                    let top = app.keyboards.firstMatch.frame.minY
                    try require(turnOn.frame.maxY <= top + 0.5 && notNow.frame.maxY <= top + 0.5,
                                "visible invitation buttons stay above the keyboard")
                }
            }
        }
        passed()
    }

    private func checkChatCore(_ app: XCUIApplication, attachment: Bool, keyboard: Bool) throws -> ChatCore {
        if keyboard {
            try require(app.keyboards.firstMatch.waitForExistence(timeout: 10), "software keyboard is present")
        } else {
            try require(app.keyboards.count == 0, "software keyboard is absent")
        }
        let fieldMatches = app.descendants(matching: .any)
            .matching(identifier: "della-host.chat.composer-field")
        try require(fieldMatches.count == 1, "one native composer field [" + matchContext(fieldMatches) + "]")
        let field = fieldMatches.element(boundBy: 0)
        try require(field.elementType == .textField || field.elementType == .textView,
                    "composer retains its native text control [type=" + nativeType(field) + "]")
        try require(field.label == "Message", "composer label is Message")
        try require(field.isEnabled && field.isHittable, "composer is enabled and reachable")
        let fieldFrame = try visibleFrame(field, in: app, name: "composer")
        if phase.contains("-a11y-") {
            try require(fieldFrame.width >= app.frame.width - 64,
                        "accessibility composer uses the full-width editor row [editor=" + rectangle(fieldFrame)
                            + " window=" + rectangle(app.frame) + "]")
        }
        let send = try button(app, identifier: "della-host.chat.send", label: "Send message")
        let attach = try button(app, identifier: "della-host.chat.attach",
                                label: attachment ? "Attachment added" : "Attach a photo or file",
                                enabled: !attachment, reachable: !attachment)
        _ = try visibleFrame(attach.element, in: app, name: "Attach")
        let mic = try button(app, identifier: "della-host.chat.mic", label: "Record a voice message")
        let thinking = try button(app, identifier: "della-host.chat.thinking", label: "Thinking")
        try require(nonemptyValue(thinking.element), "Thinking exposes its separate state value")
        var controls = [send, attach, mic, thinking]
        for control in controls {
            try require(!overlaps(fieldFrame, control.frame), "composer does not cover " + control.name
                        + " [editor=" + rectangle(fieldFrame) + " control=" + rectangle(control.frame) + "]")
        }
        var attachmentStatusFrame: CGRect?
        if attachment {
            controls.append(try button(app, label: "Remove attachment"))
            let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Attached: "))
            try require(status.count == 1,
                        "attachment status remains a separate readable element")
            attachmentStatusFrame = try visibleFrame(status.element(boundBy: 0), in: app,
                                                     name: "attachment status")
        }
        try disjoint(controls)
        if keyboard {
            let keyboardFrame = app.keyboards.firstMatch.frame
            try require(valid(keyboardFrame), "software keyboard has a nonempty native frame")
            try require(fieldFrame.maxY <= keyboardFrame.minY + 0.5,
                        "composer stays above the keyboard [editor=" + rectangle(fieldFrame)
                            + " keyboard=" + rectangle(keyboardFrame) + "]")
            for control in controls {
                try require(control.frame.maxY <= keyboardFrame.minY + 0.5,
                            control.name + " stays above the keyboard [control=" + rectangle(control.frame)
                                + " keyboard=" + rectangle(keyboardFrame) + "]")
            }
            if let attachmentStatusFrame {
                try require(attachmentStatusFrame.maxY <= keyboardFrame.minY + 0.5,
                            "attachment status stays above the keyboard [status=" + rectangle(attachmentStatusFrame)
                                + " keyboard=" + rectangle(keyboardFrame) + "]")
            }
        }
        let composerFrames = [fieldFrame] + controls.map(\.frame)
            + (attachmentStatusFrame.map { [$0] } ?? [])
        let region = try transcriptInteractionRegion(app, composerFrames: composerFrames)
        try require(region.height >= 44, "real transcript retains at least 44pt of interaction room [region="
                    + rectangle(region) + "]")
        if keyboard {
            // This checks the derived gesture bounds. The independent complete
            // editor/control/status bounds above already checked keyboard avoidance.
            let keyboardFrame = app.keyboards.firstMatch.frame
            try require(region.maxY <= keyboardFrame.minY + 0.5,
                        "transcript interaction region stays above the keyboard [region=" + rectangle(region)
                            + " keyboard=" + rectangle(keyboardFrame) + "]")
        }
        return ChatCore(fieldFrame: fieldFrame, controls: controls)
    }

    private func transcriptInteractionRegion(_ app: XCUIApplication,
                                             composerFrames: [CGRect]? = nil) throws -> CGRect {
        let matches = app.scrollViews.matching(identifier: "della-host.chat.transcript-scroll")
        try require(matches.count == 1, "one real native transcript ScrollView [" + matchContext(matches) + "]")
        let container = try visibleFrame(matches.element(boundBy: 0), in: app, name: "transcript ScrollView")
        let navigationBars = app.navigationBars
        try require(navigationBars.count == 1, "one real native chat navigation bar")
        let navigation = try visibleFrame(navigationBars.element(boundBy: 0), in: app, name: "chat navigation bar")

        let pinnedFrames: [CGRect]
        if let composerFrames {
            pinnedFrames = composerFrames
        } else {
            let identifiers = ["della-host.chat.composer-field", "della-host.chat.send",
                               "della-host.chat.attach", "della-host.chat.mic", "della-host.chat.thinking"]
            var frames = try identifiers.map { identifier in
                let elements = app.descendants(matching: .any).matching(identifier: identifier)
                try require(elements.count == 1, "one native composer boundary for " + identifier)
                return try visibleFrame(elements.element(boundBy: 0), in: app, name: identifier)
            }
            let remove = app.buttons.matching(NSPredicate(format: "label == %@", "Remove attachment"))
            let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Attached: "))
            try require(remove.count <= 1 && status.count <= 1, "attachment boundaries remain separate native elements")
            if remove.count == 1 {
                frames.append(try visibleFrame(remove.element(boundBy: 0), in: app, name: "Remove attachment"))
            }
            if status.count == 1 {
                frames.append(try visibleFrame(status.element(boundBy: 0), in: app, name: "attachment status"))
            }
            pinnedFrames = frames
        }
        try require(!pinnedFrames.isEmpty && pinnedFrames.allSatisfy(valid),
                    "native composer boundaries have usable screen geometry")
        let composerTop = pinnedFrames.map(\.minY).min()!
        var bottom = min(container.maxY, composerTop)
        if app.keyboards.count > 0 {
            try require(app.keyboards.count == 1, "one real software keyboard bounds the drag")
            bottom = min(bottom, try visibleFrame(app.keyboards.firstMatch, in: app, name: "software keyboard").minY)
        }
        let top = max(container.minY, navigation.maxY)
        // CGRect accessors standardize a negative stored height. Reject a
        // reversed or short directed interval before constructing a rectangle.
        try require(top.isFinite && bottom.isFinite && bottom - top >= 56,
                    "native transcript has a directed 56pt interaction gap [top="
                        + String(format: "%.6f", Double(top)) + " bottom="
                        + String(format: "%.6f", Double(bottom)) + " container=" + rectangle(container)
                        + " navigation=" + rectangle(navigation) + "]")
        let region = CGRect(x: container.minX, y: top, width: container.width, height: bottom - top)
        // SwiftUI safeAreaInset / UIKit adjustedContentInset can leave the AX
        // ScrollView frame equal to the entire window. This native interaction
        // region excludes observed chrome, composer leaves and keyboard. It is
        // not a measurement of content insets: the separate capture gate checks
        // the true transcript viewport, including AX-hidden portrait and padding.
        try require(valid(region) && region.height >= 56,
                    "native transcript retains at least 56pt for an interior drag [region=" + rectangle(region)
                        + " container=" + rectangle(container) + " navigation=" + rectangle(navigation)
                        + " composerTop=" + String(format: "%.6f", Double(composerTop)) + "]")
        return region
    }

    private func controlsInsideTranscript(_ controls: [Control], in app: XCUIApplication) throws {
        let region = try transcriptInteractionRegion(app).insetBy(dx: -0.5, dy: -0.5)
        for control in controls {
            try require(region.contains(control.frame), control.name + " fits inside the native transcript interaction region [control="
                        + rectangle(control.frame) + " region=" + rectangle(region) + "]")
        }
    }

    private func dragTranscript(_ app: XCUIApplication) throws {
        let region = try transcriptInteractionRegion(app)
        try require(region.height >= 44, "transcript interaction region has enough room for a native drag")
        // Use actual screen points inside the region. Normalizing the raw AX
        // container would start at y=533.6, inside the SE keyboard at y=451.
        let window = app.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: region.midX - window.minX,
                                              dy: region.minY + region.height * 0.8 - window.minY))
        let finish = origin.withOffset(CGVector(dx: region.midX - window.minX,
                                               dy: region.minY + region.height * 0.2 - window.minY))
        start.press(forDuration: 0.05, thenDragTo: finish)
    }

    private func scrollTranscriptToTarget(_ app: XCUIApplication) throws {
        let identifiers = phase.contains("controls-scrolled")
            ? ["della-host.chat.agent", "della-host.chat.voice", "della-host.chat.hear-replies", "della-host.chat.speed"]
            : ["della-host.chat.invite-turn-on", "della-host.chat.invite-not-now"]
        let targets = try identifiers.map { identifier in
            if identifier == "della-host.chat.hear-replies" { return try hearRepliesElement(app) }
            return app.buttons.matching(identifier: identifier).firstMatch
        }
        for _ in 0..<8 {
            let region = try transcriptInteractionRegion(app).insetBy(dx: -0.5, dy: -0.5)
            if targets.allSatisfy({ $0.exists && $0.isHittable && valid($0.frame) && region.contains($0.frame) }) {
                return
            }
            try dragTranscript(app)
        }
        let region = try transcriptInteractionRegion(app).insetBy(dx: -0.5, dy: -0.5)
        try require(targets.allSatisfy { $0.exists && $0.isHittable && valid($0.frame) && region.contains($0.frame) },
                    "bounded real transcript drags make every requested target reachable")
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
        let stopTalking = try button(app, identifier: "della-host.call.stop-talking", label: "Stop talking",
                                     reachable: requestedPhase.contains("scrolled"))
        for control in [camera, spotter, deepThink] {
            try require(nonemptyValue(control.element), control.name + " exposes its separate state value")
        }
        if secondaryControlsVisible {
            let visible = [mute, hangUp, camera, spotter, deepThink]
                + (requestedPhase.contains("scrolled") ? [stopTalking] : [])
            try disjoint(visible)
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
        try require(matches.count == 1, "one separate native button for " + label + " [" + matchContext(matches) + "]")
        let element = matches.element(boundBy: 0)
        return try checkedControl(element, in: app, label: label, enabled: enabled,
                                  reachable: reachable, minimumTarget: minimumTarget)
    }

    private func hearRepliesElement(_ app: XCUIApplication) throws -> XCUIElement {
        // .isToggle can expose this one product control as a native switch.
        // Every other control keeps its strict app.buttons query.
        let matches = app.descendants(matching: .any).matching(identifier: "della-host.chat.hear-replies")
        try require(matches.count == 1, "one separate native Hear replies toggle [" + matchContext(matches) + "]")
        let element = matches.element(boundBy: 0)
        try require(element.elementType == .switch || element.elementType == .button,
                    "Hear replies retains its native interactive toggle type [type=" + nativeType(element) + "]")
        let value = element.value as? String
        try require(value == "Off" || (element.elementType == .switch && value == "0"),
                    "Hear replies exposes the exact Off state [type=" + nativeType(element)
                        + " value=" + String((value ?? "nil").prefix(40)) + "]")
        return element
    }

    private func hearRepliesToggle(_ app: XCUIApplication, reachable: Bool) throws -> Control {
        try checkedControl(hearRepliesElement(app), in: app, label: "Hear replies", enabled: true,
                           reachable: reachable, minimumTarget: true)
    }

    private func checkedControl(_ element: XCUIElement, in app: XCUIApplication, label: String,
                                enabled: Bool, reachable: Bool, minimumTarget: Bool) throws -> Control {
        try require(element.label == label, "expected button label for " + label)
        try require(element.isEnabled == enabled, "expected enabled state for " + label)
        if reachable { try require(element.isHittable, label + " is reachable") }
        let frame = element.frame
        try require(valid(frame), label + " has a finite, nonempty frame")
        if minimumTarget {
            try require(frame.width >= 44 && frame.height >= 44,
                        label + " has a 44pt target [type=" + nativeType(element) + " rect=" + rectangle(frame) + "]")
        }
        if reachable { _ = try visibleFrame(element, in: app, name: label) }
        return Control(element: element, name: label, frame: frame)
    }

    private func visibleFrame(_ element: XCUIElement, in app: XCUIApplication, name: String) throws -> CGRect {
        let frame = element.frame
        let window = app.frame
        try require(valid(frame) && valid(window), name + " has usable screen geometry [type=" + nativeType(element)
                    + " rect=" + rectangle(frame) + " window=" + rectangle(window) + "]")
        try require(window.insetBy(dx: -0.5, dy: -0.5).contains(frame), name + " fits entirely on screen [rect="
                    + rectangle(frame) + " window=" + rectangle(window) + "]")
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
                            controls[first].name + " does not overlap " + controls[second].name
                                + " [first=" + rectangle(controls[first].frame) + " second=" + rectangle(controls[second].frame) + "]")
            }
        }
    }

    private func nonemptyValue(_ element: XCUIElement) -> Bool {
        guard let value = element.value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rectangle(_ frame: CGRect) -> String {
        let description = String(format: "(%.6f,%.6f,%.6f,%.6f;maxY=%.6f)", Double(frame.minX), Double(frame.minY),
                                 Double(frame.width), Double(frame.height), Double(frame.maxY))
        return String(description.prefix(120))
    }

    private func nativeType(_ element: XCUIElement) -> String {
        String(String(describing: element.elementType).prefix(40))
    }

    private func matchContext(_ matches: XCUIElementQuery) -> String {
        let count = matches.count
        let types = (0..<min(count, 3)).map { nativeType(matches.element(boundBy: $0)) }.joined(separator: ",")
        return "count=\(count) types=[\(types)]"
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        checks += 1
        guard condition() else {
            let message = message()
            print("KADE_DELLA_HOST_CONTROLS_FAILED " + phase + " " + message)
            XCTFail(phase + ": " + message, file: file, line: line)
            throw FailedCheck(message: message)
        }
    }

    private func passed() {
        print("KADE_DELLA_HOST_CONTROLS_PASSED \(checks) \(phase)")
    }
}
