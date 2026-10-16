import XCTest

/// Checks the real call/chat control tree in silent, paused simulator fixtures.
/// Nothing is tapped: send, recording, notifications and call actions stay idle.
/// Run only this class with the KadeAIA11yAudit scheme; the other UI audit walks
/// authenticated screens and has a different coverage contract.
final class DellaHostControlsUITests: XCTestCase {
    private struct Control {
        let element: XCUIElement
        let observation: any XCUIElementSnapshot
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

    private struct TranscriptDragState {
        var used = 0
        var keyboardDismissalDrags = 0
        var lastContext = "no gesture issued"
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
            // Ask isHittable only once the target's activation point (its frame
            // center) is inside the window. Asking mid-scroll, while that point is
            // off screen, makes XCTest record "Failed to determine hittability ...
            // Activation point invalid" as a test failure even though the scroll
            // then completes. The required end state (hittable target) is unchanged.
            let window = app.frame
            let deadline = Date().addingTimeInterval(30)
            var settled = false
            while !settled && Date() < deadline {
                if target.exists {
                    let frame = target.frame
                    settled = valid(frame) && window.contains(CGPoint(x: frame.midX, y: frame.midY))
                        && target.isHittable
                }
                if !settled { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            }
            try require(settled, "fixture completed its scroll before control checks")
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
        let window = app.frame
        try require(abs(window.width - expected.width) <= 1
                    && abs(window.height - expected.height) <= 1,
                    "test uses the requested real phone window")
        var core = try checkChatCore(app, attachment: attachment, keyboard: keyboard)
        if dismissKeyboardByDragging {
            // The fixture deliberately leaves the real keyboard and scroll
            // position alone. Only real native transcript gestures may dismiss it.
            var drags = TranscriptDragState()
            try dismissKeyboardWithTranscriptDrags(app, state: &drags)
            drags.keyboardDismissalDrags = drags.used
            core = try checkChatCore(app, attachment: attachment, keyboard: false)
            try scrollTranscriptToTarget(app, state: &drags)
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
        try require(nonemptyValue(speed.observation), "Voice speed exposes its separate rate value")
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
        let fieldObservation = try field.snapshot()
        try require(fieldObservation.elementType == .textField || fieldObservation.elementType == .textView,
                    "composer retains its native text control [type=" + nativeType(fieldObservation) + "]")
        try require(fieldObservation.label == "Message", "composer label is Message")
        try require(fieldObservation.isEnabled && field.isHittable, "composer is enabled and reachable")
        let window = app.frame
        let fieldFrame = try visibleFrame(fieldObservation, window: window, name: "composer")
        if phase.contains("-a11y-") {
            try require(fieldFrame.width >= window.width - 64,
                        "accessibility composer uses the full-width editor row [editor=" + rectangle(fieldFrame)
                            + " window=" + rectangle(window) + "]")
        }
        let send = try button(app, identifier: "della-host.chat.send", label: "Send message")
        let attach = try button(app, identifier: "della-host.chat.attach",
                                label: attachment ? "Attachment added" : "Attach a photo or file",
                                enabled: !attachment, reachable: !attachment)
        _ = try visibleFrame(attach.observation, window: window, name: "Attach")
        let mic = try button(app, identifier: "della-host.chat.mic", label: "Record a voice message")
        let thinking = try button(app, identifier: "della-host.chat.thinking", label: "Thinking")
        try require(nonemptyValue(thinking.observation), "Thinking exposes its separate state value")
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
            let removeCount = remove.count
            let statusCount = status.count
            try require(removeCount <= 1 && statusCount <= 1, "attachment boundaries remain separate native elements")
            if removeCount == 1 {
                frames.append(try visibleFrame(remove.element(boundBy: 0), in: app, name: "Remove attachment"))
            }
            if statusCount == 1 {
                frames.append(try visibleFrame(status.element(boundBy: 0), in: app, name: "attachment status"))
            }
            pinnedFrames = frames
        }
        try require(!pinnedFrames.isEmpty && pinnedFrames.allSatisfy(valid),
                    "native composer boundaries have usable screen geometry")
        let composerTop = pinnedFrames.map(\.minY).min()!
        var bottom = min(container.maxY, composerTop)
        let keyboardCount = app.keyboards.count
        if keyboardCount > 0 {
            try require(keyboardCount == 1, "one real software keyboard bounds the drag")
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

    private func dragTranscript(_ app: XCUIApplication, region: CGRect,
                                keyboardWaitSeconds: TimeInterval,
                                state: inout TranscriptDragState,
                                verticalDisplacement: CGFloat? = nil) throws {
        try require(state.used < 8, "native transcript gestures share one eight-drag budget")
        try require(region.height >= 44, "transcript interaction region has enough room for a native drag")
        // Use actual screen points inside the region. Normalizing the raw AX
        // container would start at y=533.6, inside the SE keyboard at y=451.
        // Start near the lower interior edge of the observed gap. This remains
        // an interaction bound; the separate capture gate measures the viewport.
        let window = app.frame
        let interior = min(24, region.height * 0.2)
        var startPoint = CGPoint(x: region.midX, y: region.maxY - interior)
        var finishPoint = CGPoint(x: region.midX, y: region.minY + interior)
        if let verticalDisplacement {
            startPoint.y = verticalDisplacement > 0 ? region.minY + interior : region.maxY - interior
            finishPoint.y = startPoint.y + verticalDisplacement
        }
        let keyboardBefore = app.keyboards.count
        try require(state.used > 0 || keyboardBefore == 1,
                    "keyboard is present before the first real transcript gesture")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: startPoint.x - window.minX,
                                              dy: startPoint.y - window.minY))
        let finish = origin.withOffset(CGVector(dx: finishPoint.x - window.minX,
                                               dy: finishPoint.y - window.minY))
        state.used += 1
        if verticalDisplacement != nil {
            // Target search uses a controlled release instead of the default
            // drag velocity; the keyboard dismissal gesture remains unchanged.
            start.press(forDuration: 0.05, thenDragTo: finish,
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        } else {
            start.press(forDuration: 0.05, thenDragTo: finish)
        }
        if keyboardWaitSeconds > 0 {
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                (object as? XCUIApplication)?.keyboards.count == 0
            }, object: app)
            _ = XCTWaiter.wait(for: [hidden], timeout: keyboardWaitSeconds)
        }
        let keyboardAfter = app.keyboards.count
        let geometry = String(format: "r=(%.6f,%.6f,%.6f,%.6f) s=(%.6f,%.6f) e=(%.6f,%.6f)",
                              Double(region.minX), Double(region.minY), Double(region.width), Double(region.height),
                              Double(startPoint.x), Double(startPoint.y), Double(finishPoint.x), Double(finishPoint.y))
        let context = "n=\(state.used)/8 " + geometry + " k=\(keyboardBefore)>\(keyboardAfter)"
        state.lastContext = String(context.prefix(180))
    }

    private func dismissKeyboardWithTranscriptDrags(_ app: XCUIApplication,
                                                    state: inout TranscriptDragState) throws {
        try require(app.keyboards.count == 1, "software keyboard precedes the real dismissal gestures")
        var allocatedWait: TimeInterval = 0
        while app.keyboards.count > 0 && state.used < 8 {
            let region = try transcriptInteractionRegion(app)
            let wait = min(2, max(0, 10 - allocatedWait))
            allocatedWait += wait
            try dragTranscript(app, region: region, keyboardWaitSeconds: wait, state: &state)
        }
        try require(state.used > 0, "at least one real transcript gesture was issued")
        try require(app.keyboards.count == 0,
                    "real transcript drags dismiss the software keyboard [" + state.lastContext + "]")
    }

    private func scrollTranscriptToTarget(_ app: XCUIApplication,
                                          state: inout TranscriptDragState) throws {
        let identifiers = phase.contains("controls-scrolled")
            ? ["della-host.chat.agent", "della-host.chat.voice", "della-host.chat.hear-replies", "della-host.chat.speed"]
            : ["della-host.chat.invite-turn-on", "della-host.chat.invite-not-now"]
        let targets = try identifiers.map { identifier in
            if identifier == "della-host.chat.hear-replies" { return try hearRepliesElement(app) }
            return app.buttons.matching(identifier: identifier).firstMatch
        }
        while state.used < 8 {
            let region = try transcriptInteractionRegion(app)
            let targetBounds = region.insetBy(dx: -0.5, dy: -0.5)
            try require(app.keyboards.count == 0,
                        "software keyboard stays absent during target search [" + state.lastContext + "]")
            let observations = targets.map { target in
                let exists = target.exists
                return (exists: exists, frame: exists ? target.frame : CGRect.null)
            }
            if zip(targets, observations).allSatisfy({ pair in
                // Same four requirements; hittability is asked last, only for an
                // on-screen frame, so an off-screen target cannot record an XCTest issue.
                pair.1.exists && valid(pair.1.frame) && targetBounds.contains(pair.1.frame) && pair.0.isHittable
            }) {
                return
            }
            guard let displacement = transcriptTargetDisplacement(observations.map { $0.frame }, in: region) else {
                break
            }
            try dragTranscript(app, region: region, keyboardWaitSeconds: 0, state: &state,
                               verticalDisplacement: displacement)
        }
        let region = try transcriptInteractionRegion(app).insetBy(dx: -0.5, dy: -0.5)
        try require(app.keyboards.count == 0,
                    "software keyboard stays absent after target search [" + state.lastContext + "]")
        let reachable = targets.allSatisfy { target in
            guard target.exists else { return false }
            let frame = target.frame
            return valid(frame) && region.contains(frame) && target.isHittable
        }
        if !reachable {
            // These are fresh observations after the failed predicate. They
            // explain its native boundaries without changing any gesture or
            // accepting a target from a later diagnostic observation.
            printTargetFailure("drags=\(state.used)/8 dismissal=\(state.keyboardDismissalDrags)"
                + " search=\(state.used - state.keyboardDismissalDrags) keyboard=\(app.keyboards.count)"
                + " region=" + rectangle(region))
            for (identifier, target) in zip(identifiers, targets) {
                let exists = target.exists
                if exists {
                    let hittable = target.isHittable
                    let frame = target.frame
                    printTargetFailure("id=" + identifier + " exists=\(exists) hittable=\(hittable)"
                        + " valid=\(valid(frame)) inside=\(region.contains(frame)) frame=" + rectangle(frame))
                } else {
                    printTargetFailure("id=" + identifier
                        + " exists=false hittable=unqueried valid=unqueried inside=unqueried frame=unavailable")
                }
            }
        }
        try require(reachable,
                    "bounded real drags make every target reachable [" + state.lastContext + "]")
    }

    /// Native target geometry chooses the direction after each real gesture.
    /// A target already above the region must move down; continuing upward can
    /// pass the controls and spend the remaining budget moving away from them.
    private func transcriptTargetDisplacement(_ frames: [CGRect], in region: CGRect) -> CGFloat? {
        guard !frames.isEmpty, frames.allSatisfy(valid), valid(region) else { return nil }
        let group = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let bounds = region.insetBy(dx: -0.5, dy: -0.5)
        guard valid(group), group.width <= bounds.width, group.height <= bounds.height,
              group.minX >= bounds.minX, group.maxX <= bounds.maxX else { return nil }
        let interior = min(24, region.height * 0.2)
        let limit = (region.height - 2 * interior) * 0.5
        let delta = bounds.midY - group.midY
        let displacement = min(limit, max(-limit, delta))
        // Missing/impossible geometry or no usable movement falls through to
        // the original target diagnostics and strict final reachability check.
        guard displacement.isFinite, abs(displacement) >= 1 else { return nil }
        return displacement
    }

    private func printTargetFailure(_ detail: String) {
        let line = "KADE_DELLA_HOST_CONTROLS_FAILED " + phase + " target-diagnostic " + detail
        print(String(line.prefix(300)))
    }

    private func checkCall(_ requestedPhase: String, secondaryControlsVisible: Bool) throws {
        let app = try launch(requestedPhase)
        defer { app.terminate() }
        let mute = try button(app, identifier: "della-host.call.mute", label: "Mute microphone")
        let hangUp = try button(app, identifier: "della-host.call.hang-up", label: "Hang Up")
        try require(nonemptyValue(mute.observation), "Mute exposes its microphone state")
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
            try require(nonemptyValue(control.observation), control.name + " exposes its separate state value")
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
        let observation = try element.snapshot()
        try require(observation.elementType == .switch || observation.elementType == .button,
                    "Hear replies retains its native interactive toggle type [type=" + nativeType(observation) + "]")
        let value = observation.value as? String
        try require(value == "Off" || (observation.elementType == .switch && value == "0"),
                    "Hear replies exposes the exact Off state [type=" + nativeType(observation)
                        + " value=" + String((value ?? "nil").prefix(40)) + "]")
        return element
    }

    private func hearRepliesToggle(_ app: XCUIApplication, reachable: Bool) throws -> Control {
        try checkedControl(hearRepliesElement(app), in: app, label: "Hear replies", enabled: true,
                           reachable: reachable, minimumTarget: true)
    }

    private func checkedControl(_ element: XCUIElement, in app: XCUIApplication, label: String,
                                enabled: Bool, reachable: Bool, minimumTarget: Bool) throws -> Control {
        // One native AX observation supplies attributes for this control check.
        // Hittability is still queried live; it is not an AX snapshot attribute.
        // No observation survives a gesture: callers re-enter these checks after
        // each keyboard/scroll transition, retaining the original assertions.
        let observation = try element.snapshot()
        try require(observation.label == label, "expected button label for " + label)
        try require(observation.isEnabled == enabled, "expected enabled state for " + label)
        if reachable { try require(element.isHittable, label + " is reachable") }
        let frame = observation.frame
        try require(valid(frame), label + " has a finite, nonempty frame")
        if minimumTarget {
            try require(frame.width >= 44 && frame.height >= 44,
                        label + " has a 44pt target [type=" + nativeType(observation) + " rect=" + rectangle(frame) + "]")
        }
        if reachable { _ = try visibleFrame(observation, window: app.frame, name: label) }
        return Control(element: element, observation: observation, name: label, frame: frame)
    }

    private func visibleFrame(_ element: XCUIElement, in app: XCUIApplication, name: String) throws -> CGRect {
        try visibleFrame(element, window: app.frame, name: name)
    }

    private func visibleFrame(_ observation: any XCUIElementAttributes, window: CGRect, name: String) throws -> CGRect {
        let frame = observation.frame
        try require(valid(frame) && valid(window), name + " has usable screen geometry [type=" + nativeType(observation)
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

    private func nonemptyValue(_ element: any XCUIElementAttributes) -> Bool {
        guard let value = element.value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rectangle(_ frame: CGRect) -> String {
        let description = String(format: "(%.6f,%.6f,%.6f,%.6f;maxY=%.6f)", Double(frame.minX), Double(frame.minY),
                                 Double(frame.width), Double(frame.height), Double(frame.maxY))
        return String(description.prefix(120))
    }

    private func nativeType(_ element: any XCUIElementAttributes) -> String {
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
