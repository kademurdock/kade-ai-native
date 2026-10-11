import XCTest

/// Uses the same compiled unsigned runner as the existing host regressions.
/// These synthetic outputs never construct a player or connect to an account.
final class PuppetCompletionUITests: XCTestCase {
    private let people = ["harley", "kiana", "lilly", "della", "witherspoon", "lilly-private", "angel"]
    private let renderers = [
        "harley": "conversation-upper-body-harley-v1",
        "kiana": "conversation-upper-body-kiana-v1",
        "lilly": "conversation-upper-body-lilly-v1",
        "della": "della-articulated",
        "witherspoon": "conversation-upper-body-witherspoon-v1",
        "lilly-private": "conversation-upper-body-lilly-v1",
        "angel": "angel-vector"
    ]
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRoomySendingKeepsBodyAndComposer() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["KADE_A11Y_AUDIT": "1", "KADE_CHARACTER_AUDIT": "1",
            "KADE_DELLA_HOST_AUDIT": "1", "KADE_DELLA_HOST_CASE": "chat-roomy-light",
            "KADE_PUPPET_HOST_SENDING": "1"]
        app.launch()
        let stop = app.buttons["della-host.chat.send"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertEqual(stop.label, "Stop")
        XCTAssertTrue(stop.isEnabled && stop.isHittable)
        XCTAssertGreaterThanOrEqual(stop.frame.width, 44)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(stop.frame))
        let matches = app.descendants(matching: .any).matching(identifier: "della-host.chat.composer-field")
        XCTAssertEqual(matches.count, 1)
        let field = matches.element(boundBy: 0)
        XCTAssertTrue(field.elementType == .textField || field.elementType == .textView)
        XCTAssertEqual(field.label, "Message")
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(field.frame))
        XCTAssertFalse(field.frame.intersects(stop.frame))
        let observation = app.staticTexts["della-host.sending-geometry"]
        XCTAssertTrue(observation.waitForExistence(timeout: 10))
        let predicate = NSPredicate { object, _ in
            ((object as? XCUIElement)?.label ?? "pending").hasPrefix("{")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: observation)], timeout: 10), .completed)
        let data = try XCTUnwrap(observation.label.data(using: .utf8))
        let geometry = try JSONDecoder().decode([String: [Double]].self, from: data)
        XCTAssertEqual(Set(geometry.keys), Set(["stage", "transcript", "composer"]))
        func rectangle(_ name: String) throws -> CGRect {
            let values = try XCTUnwrap(geometry[name])
            XCTAssertEqual(values.count, 4)
            XCTAssertTrue(values.allSatisfy { $0.isFinite })
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        let stage = try rectangle("stage"), transcript = try rectangle("transcript"), composer = try rectangle("composer")
        XCTAssertEqual(stage.height, 208 * 620 / 414 + 40, accuracy: 1)
        XCTAssertGreaterThanOrEqual(transcript.height, 44)
        XCTAssertFalse(transcript.intersects(composer))
        XCTAssertTrue(composer.insetBy(dx: -1, dy: -1).contains(field.frame))
        XCTAssertTrue(composer.insetBy(dx: -1, dy: -1).contains(stop.frame))
        XCTAssertFalse(stage.intersects(composer))
        print("KADE_PUPPET_COMPLETION_UI_PHASE_PASS roomy-sending-light")
        app.terminate()
    }

    func testAllCastKeyposes() throws {
        let app = launch(events: false)
        let phases = people.flatMap { person in ["neutral", "gesturePeak", "settled"].map { person + "-" + $0 } }
        for (index, phase) in phases.enumerated() {
            try ready(app, phase: phase)
            let person = people[index / 3]
            XCTAssertEqual(text(app, "renderer"), renderers[person])
            XCTAssertGreaterThanOrEqual(number(app, "activeSamples"), 3)
            XCTAssertGreaterThanOrEqual(number(app, "distinctVectors"), 2)
            XCTAssertEqual(number(app, "fps"), index % 3 == 0 ? 8 : 24)
            XCTAssertEqual(number(app, "face"), index % 3 == 0 ? 0 : 1)
            if index % 3 == 1 { XCTAssertTrue((1...8).contains(number(app, "viseme"))) }
            else { XCTAssertEqual(number(app, "viseme"), 0) }
            print("KADE_PUPPET_COMPLETION_UI_PHASE_PASS " + phase)
            if index + 1 < phases.count { try next(app) }
        }
        app.terminate()
    }

    func testCompactAndMotionPolicies() throws {
        let app = launch(events: true)
        let policies = ["compact", "reduceMotion", "offscreen", "resume"]
        let phases = people.flatMap { person in policies.map { person + "-" + $0 } }
        for (index, phase) in phases.enumerated() {
            try ready(app, phase: phase)
            let person = people[index / 4]
            let policy = policies[index % 4]
            if policy == "compact" {
                XCTAssertEqual(text(app, "renderer"), person == "angel" ? "angel-vector" : "portrait")
                XCTAssertGreaterThanOrEqual(number(app, "activeSamples"), 3)
                XCTAssertEqual(number(app, "fps"), 24)
            } else if policy == "reduceMotion" || policy == "offscreen" {
                XCTAssertEqual(text(app, "renderer"), renderers[person])
                XCTAssertEqual(number(app, "fps"), 0)
                XCTAssertEqual(number(app, "viseme"), 0)
            } else {
                XCTAssertEqual(text(app, "renderer"), renderers[person])
                XCTAssertGreaterThanOrEqual(number(app, "activeSamples"), 3)
                XCTAssertGreaterThanOrEqual(number(app, "distinctVectors"), 2)
                XCTAssertEqual(number(app, "fps"), 24)
            }
            print("KADE_PUPPET_COMPLETION_UI_PHASE_PASS " + phase)
            if index + 1 < phases.count { try next(app) }
        }
        app.terminate()
    }

    private func launch(events: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["KADE_A11Y_AUDIT": "1", "KADE_CHARACTER_AUDIT": "1",
            "KADE_PUPPET_COMPLETION_AUDIT": "1", "KADE_PUPPET_COMPLETION_UI": "1",
            "KADE_PUPPET_COMPLETION_EVENTS": events ? "1" : "0",
            "KADE_PUPPET_COMPLETION_SOURCE": "native-ui-compiled-runner-bound"]
        app.launch()
        return app
    }
    private func ready(_ app: XCUIApplication, phase: String) throws {
        let current = app.staticTexts["puppet-completion.phase"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, phase)
        let ready = app.staticTexts["puppet-completion.status"]
        let predicate = NSPredicate(format: "label == %@", "ready")
        let observation = XCTNSPredicateExpectation(predicate: predicate, object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [observation], timeout: 10), .completed)
        XCTAssertEqual(ready.label, "ready")
        let window = app.frame
        XCTAssertGreaterThan(window.height, window.width)
    }
    private func text(_ app: XCUIApplication, _ key: String) -> String {
        app.staticTexts["puppet-completion." + key].label
    }
    private func number(_ app: XCUIApplication, _ key: String) -> Int { Int(text(app, key)) ?? -1 }
    private func next(_ app: XCUIApplication) throws {
        let button = app.buttons["puppet-completion.next"]
        XCTAssertTrue(button.exists && button.isEnabled && button.isHittable)
        button.tap()
    }
}
