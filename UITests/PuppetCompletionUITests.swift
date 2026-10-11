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

    @MainActor
    func testRoomySendingKeepsBodyAndComposer() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["KADE_A11Y_AUDIT": "1", "KADE_CHARACTER_AUDIT": "1",
            "KADE_DELLA_HOST_AUDIT": "1", "KADE_DELLA_HOST_CASE": "chat-roomy-light",
            "KADE_PUPPET_HOST_SENDING": "1"]
        app.launch()
        let native = try sendingSnapshot(app)
        let stop = try native.exact("della-host.chat.send", type: .button)
        XCTAssertEqual(stop.label, "Stop")
        XCTAssertTrue(stop.isEnabled)
        XCTAssertTrue(app.buttons["della-host.chat.send"].isHittable)
        XCTAssertGreaterThanOrEqual(stop.frame.width, 44)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
        XCTAssertTrue(native.window.insetBy(dx: -1, dy: -1).contains(stop.frame))
        let field = try native.exact("della-host.chat.composer-field")
        XCTAssertTrue(field.elementType == .textField || field.elementType == .textView)
        XCTAssertEqual(field.label, "Message")
        XCTAssertTrue(native.window.insetBy(dx: -1, dy: -1).contains(field.frame))
        XCTAssertFalse(field.frame.intersects(stop.frame))
        let observation = try native.exact("della-host.sending-geometry", type: .staticText)
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

    @MainActor
    func testAllCastKeyposes() throws {
        let app = launch(events: false)
        let phases = people.flatMap { person in ["neutral", "gesturePeak", "settled"].map { person + "-" + $0 } }
        for (index, phase) in phases.enumerated() {
            let observed = try ready(app, phase: phase)
            let person = people[index / 3]
            XCTAssertEqual(observed.text("renderer"), renderers[person])
            XCTAssertGreaterThanOrEqual(observed.number("activeSamples"), 3)
            XCTAssertGreaterThanOrEqual(observed.number("distinctVectors"), 2)
            XCTAssertEqual(observed.number("fps"), index % 3 == 0 ? 8 : 24)
            XCTAssertEqual(observed.number("face"), index % 3 == 0 ? 0 : 1)
            if index % 3 == 1 { XCTAssertTrue((1...8).contains(observed.number("viseme"))) }
            else { XCTAssertEqual(observed.number("viseme"), 0) }
            print("KADE_PUPPET_COMPLETION_UI_PHASE_PASS " + phase)
            if index + 1 < phases.count { try next(app, observed: observed) }
        }
        app.terminate()
    }

    @MainActor
    func testCompactAndMotionPolicies() throws {
        let app = launch(events: true)
        let policies = ["compact", "reduceMotion", "offscreen", "resume"]
        let phases = people.flatMap { person in policies.map { person + "-" + $0 } }
        for (index, phase) in phases.enumerated() {
            let observed = try ready(app, phase: phase)
            let person = people[index / 4]
            let policy = policies[index % 4]
            if policy == "compact" {
                XCTAssertEqual(observed.text("renderer"), person == "angel" ? "angel-vector" : "portrait")
                XCTAssertGreaterThanOrEqual(observed.number("activeSamples"), 3)
                XCTAssertEqual(observed.number("fps"), 24)
            } else if policy == "reduceMotion" || policy == "offscreen" {
                XCTAssertEqual(observed.text("renderer"), renderers[person])
                XCTAssertEqual(observed.number("fps"), 0)
                XCTAssertEqual(observed.number("viseme"), 0)
            } else {
                XCTAssertEqual(observed.text("renderer"), renderers[person])
                XCTAssertGreaterThanOrEqual(observed.number("activeSamples"), 3)
                XCTAssertGreaterThanOrEqual(observed.number("distinctVectors"), 2)
                XCTAssertEqual(observed.number("fps"), 24)
            }
            print("KADE_PUPPET_COMPLETION_UI_PHASE_PASS " + phase)
            if index + 1 < phases.count { try next(app, observed: observed) }
        }
        app.terminate()
    }

    @MainActor
    private func launch(events: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["KADE_A11Y_AUDIT": "1", "KADE_CHARACTER_AUDIT": "1",
            "KADE_PUPPET_COMPLETION_AUDIT": "1", "KADE_PUPPET_COMPLETION_UI": "1",
            "KADE_PUPPET_COMPLETION_EVENTS": events ? "1" : "0",
            "KADE_PUPPET_COMPLETION_SOURCE": "native-ui-compiled-runner-bound"]
        app.launch()
        return app
    }
    private struct NativeElement {
        let label: String
        let frame: CGRect
        let isEnabled: Bool
        let elementType: XCUIElement.ElementType

        @MainActor
        init(_ element: any XCUIElementSnapshot) {
            label = element.label; frame = element.frame
            isEnabled = element.isEnabled; elementType = element.elementType
        }
    }
    private struct NativeTree {
        let window: CGRect
        let elements: [String: [NativeElement]]

        func exact(_ identifier: String, type: XCUIElement.ElementType? = nil) throws -> NativeElement {
            let matches = elements[identifier] ?? []
            XCTAssertEqual(matches.count, 1, "Unique native element: " + identifier)
            let element = try XCTUnwrap(matches.first)
            if let type { XCTAssertEqual(element.elementType, type, identifier) }
            return element
        }
    }
    private struct PhaseObservation {
        let labels: [String: String]
        let next: NativeElement?
        func text(_ key: String) -> String { labels[key] ?? "" }
        func number(_ key: String) -> Int { Int(text(key)) ?? -1 }
    }
    private enum SnapshotFailure: Error { case treeLimit, notReady }

    @MainActor
    private func nativeTree(_ app: XCUIApplication) throws -> NativeTree {
        let snapshot = try app.snapshot()
        var pending: [(element: any XCUIElementSnapshot, depth: Int)] = [(snapshot, 0)]
        var elements: [String: [NativeElement]] = [:]
        var visited = 0
        while let entry = pending.popLast() {
            visited += 1
            guard visited <= 4096 && entry.depth <= 64 else { throw SnapshotFailure.treeLimit }
            let identifier = entry.element.identifier
            if identifier.hasPrefix("puppet-completion.")
                || ["della-host.chat.send", "della-host.chat.composer-field", "della-host.sending-geometry"].contains(identifier) {
                elements[identifier, default: []].append(NativeElement(entry.element))
            }
            for child in entry.element.children.reversed() { pending.append((child, entry.depth + 1)) }
        }
        return NativeTree(window: snapshot.frame, elements: elements)
    }

    @MainActor
    private func waitForSnapshot(_ app: XCUIApplication, accepts: (NativeTree) -> Bool) throws -> NativeTree {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lastIssue = "No matching native phase and ready state"
        repeat {
            do {
                let tree = try nativeTree(app)
                if accepts(tree) { return tree }
            } catch { lastIssue = String(describing: type(of: error)) }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.1, remaining))) }
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("Native readiness exceeded 10 seconds: " + lastIssue)
        throw SnapshotFailure.notReady
    }

    @MainActor
    private func ready(_ app: XCUIApplication, phase: String) throws -> PhaseObservation {
        let tree = try waitForSnapshot(app) { tree in
            let current = tree.elements["puppet-completion.phase"] ?? []
            let status = tree.elements["puppet-completion.status"] ?? []
            return current.count == 1 && status.count == 1 && current[0].elementType == .staticText
                && status[0].elementType == .staticText && current[0].label == phase && status[0].label == "ready"
        }
        var labels: [String: String] = [:]
        for key in ["phase", "status", "renderer", "activeSamples", "distinctVectors", "fps", "face", "viseme"] {
            labels[key] = try tree.exact("puppet-completion." + key, type: .staticText).label
        }
        XCTAssertEqual(labels["phase"], phase)
        XCTAssertEqual(labels["status"], "ready")
        XCTAssertGreaterThan(tree.window.height, tree.window.width)
        let next: NativeElement?
        if (tree.elements["puppet-completion.next"] ?? []).isEmpty { next = nil }
        else { next = try tree.exact("puppet-completion.next", type: .button) }
        return PhaseObservation(labels: labels, next: next)
    }

    @MainActor
    private func sendingSnapshot(_ app: XCUIApplication) throws -> NativeTree {
        try waitForSnapshot(app) { tree in
            let geometry = tree.elements["della-host.sending-geometry"] ?? []
            return geometry.count == 1 && geometry[0].elementType == .staticText && geometry[0].label.hasPrefix("{")
        }
    }

    @MainActor
    private func next(_ app: XCUIApplication, observed: PhaseObservation) throws {
        let native = try XCTUnwrap(observed.next)
        XCTAssertTrue(native.isEnabled)
        let button = app.buttons["puppet-completion.next"]
        XCTAssertTrue(button.isHittable)
        button.tap()
    }
}
