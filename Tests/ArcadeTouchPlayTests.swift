import Foundation

// Touch play (Oct 20 2026): the game pad's v2 recognizer (a port of the
// kit's core/touch.js v2, run against the kit's shared vectors: the Easy
// fight tier, VoiceOver-style menus, the scrub, flicks out of a block, duds
// with their reasons, her touch timing), the haptics for every gesture, the
// one speech queue, the pad's held state and words, the watchdog, How to
// play, Pad practice, the chimes and the touch trace. Compiled with the
// Arcade's other checks by run-arcade-tests.sh. With KIT_TOUCH_VECTORS set to
// the kit's core/test/touch_vectors.json, every vector in it runs too.

extension ArcadeModelsTests {
    // MARK: Helpers

    /// The Oct 18 tables (a build-341 pack carries only these, with no
    /// `fights`): the checks of the plain outputs run on them unchanged.
    static let v1JSON = """
    {"flickPx":20,"tapMs":250,"tapSlopPx":12,"doubleMs":300,"pulseMs":100,"holdMs":250,
     "repeatAfterMs":1000,"repeatEveryMs":250,"stickRadiusPx":60,
     "menu":{"flick1":{"up":{"pulse":{"sy":-1}},"down":{"pulse":{"sy":1}},"left":{"pulse":{"sx":-1}},"right":{"pulse":{"sx":1}},"repeat":true},
             "doubleTap1":{"pulse":{"buttons":["A"]}},"tap2":{"pulse":{"buttons":["B"]}},"doubleTap2":{"pulse":{"buttons":["START"]}},
             "flick3":{"up":{"pulse":{"buttons":["CU"]}},"down":{"pulse":{"buttons":["CD"]}},"left":{"pulse":{"buttons":["CL"]}},"right":{"pulse":{"buttons":["CR"]}}},
             "tap3":{"pulse":{"buttons":["START"]}},"hold1":{"info":"repeat","ms":1000}},
     "fight":{"anywhere":{"tap3":{"pulse":{"buttons":["START"]}}},
              "left":{"stick1":{"radiusPx":60},"tap1":{"pulse":{"buttons":["A"]}},
                      "flick2":{"up":{"info":"health"},"down":{"info":"where"},"left":{"info":"facing"},"right":{"info":"time"}},
                      "hold2":{"info":"repeat","ms":1000}},
              "right":{"flick1":{"left":{"pulse":{"buttons":["CL"]}},"up":{"pulse":{"buttons":["CU"]}},"down":{"pulse":{"buttons":["CD"]}},"right":{"pulse":{"buttons":["CR"]}}},
                       "tap1":{"pulse":{"buttons":["R"]}},"hold1":{"hold":{"buttons":["block"]}},
                       "tap2":{"pulse":{"buttons":["B"]}},"hold2":{"hold":{"buttons":["Z"]}}}}}
    """

    static let v1Table = ArcadeTouchTable(json: (try? JSONSerialization.jsonObject(with: Data(v1JSON.utf8))) as? [String: Any])

    /// The Oct 18 recognizer's outputs: the v1 table, no reports, no finger source.
    static func legacyPad() -> ArcadeTouchRecognizer {
        var pad = ArcadeTouchRecognizer(table: v1Table)
        pad.reports = false
        pad.fingerSource = false
        return pad
    }

    /// A table's plain outputs (the plain player's checks): no reports, no finger source.
    static func plainPad(_ table: ArcadeTouchTable) -> ArcadeTouchRecognizer {
        var pad = ArcadeTouchRecognizer(table: table)
        pad.reports = false
        pad.fingerSource = false
        return pad
    }

    static func near(_ a: Double, _ b: Double, _ give: Double = 0.001) -> Bool { abs(a - b) <= give }

    /// One gesture in the kit's vector shape (core/test/touchvec.js): fingers
    /// land at `at` (each `landGap` later, 40 pt apart from x), move along the
    /// path's [ms, dx, dy] waypoints and lift at `at + up`.
    static func step(at: Double = 0, fingers: Int = 1, x: Double = 200, landGap: Double = 0, path: [[Double]] = [],
                     up: Double) -> [String: Any] {
        ["at": at, "fingers": fingers, "x": x, "landGapMs": landGap, "path": path, "upAt": up]
    }

    /// A run: the outputs as the kit's runner writes them, with their times, and every raw output.
    struct TouchRun {
        var timed: [(out: String, t: Double)] = []
        var raw: [ArcadeTouchOutput] = []

        var words: [String] { timed.map { $0.out } }

        var shown: String { timed.map { $0.out + "@" + String(Int($0.t.rounded())) }.joined(separator: ", ") }

        var reports: [ArcadeGestureReport] {
            raw.compactMap { (output: ArcadeTouchOutput) -> ArcadeGestureReport? in
                if case .gesture(let report) = output { return report }
                return nil
            }
        }

        var lifts: [ArcadeLiftReport] {
            raw.compactMap { (output: ArcadeTouchOutput) -> ArcadeLiftReport? in
                if case .lifted(let lift) = output { return lift }
                return nil
            }
        }
    }

    /// The kit's touchvec.js expand(): each step's fingers land, move (a
    /// sample every stepMs, sent only when the position changed) and lift;
    /// every event in time order, ties in the order they were made.
    static func expand(_ steps: [[String: Any]]) -> [(t: Double, type: String, id: Int, x: Double, y: Double)] {
        var events: [(t: Double, type: String, id: Int, x: Double, y: Double, k: Int)] = []
        for (index, step) in steps.enumerated() {
            let n = Int(arcadeJSONNumber(step["fingers"]) ?? 1)
            let x = arcadeJSONNumber(step["x"]) ?? 200
            let y = arcadeJSONNumber(step["y"]) ?? 400
            let spread = arcadeJSONNumber(step["spread"]) ?? 40
            let at = arcadeJSONNumber(step["at"]) ?? 0
            let land = arcadeJSONNumber(step["landGapMs"]) ?? 0
            let liftGap = arcadeJSONNumber(step["liftGapMs"]) ?? 0
            let every = arcadeJSONNumber(step["stepMs"]) ?? 16
            let up = arcadeJSONNumber(step["upAt"]) ?? 0
            for i in 0..<n {
                events.append((t: at + Double(i) * land, type: "down", id: index * 10 + i, x: x + Double(i) * spread, y: y, k: events.count))
            }
            var points: [[Double]] = [[0, 0, 0]]
            for case let point as [Any] in (step["path"] as? [Any]) ?? [] {
                let numbers = point.compactMap { arcadeJSONNumber($0) }
                if numbers.count >= 3 { points.append(numbers) }
            }
            var lastX = 0.0
            var lastY = 0.0
            func sample(_ t: Double, _ dx: Double, _ dy: Double) {
                if dx == lastX && dy == lastY { return }
                lastX = dx
                lastY = dy
                for i in 0..<n {
                    events.append((t: at + t, type: "move", id: index * 10 + i, x: x + Double(i) * spread + dx, y: y + dy, k: events.count))
                }
            }
            for k in 1..<points.count {
                let a = points[k - 1]
                let b = points[k]
                var t = a[0] + every
                while t < b[0] {
                    let f = (t - a[0]) / (b[0] - a[0])
                    sample(t, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f)
                    t += every
                }
                sample(b[0], b[1], b[2])
            }
            for i in 0..<n {
                events.append((t: at + up + Double(i) * liftGap, type: "up", id: index * 10 + i, x: 0, y: 0, k: events.count))
            }
        }
        let sorted = events.sorted { ($0.t, $0.k) < ($1.t, $1.k) }
        return sorted.map { (t: $0.t, type: $0.type, id: $0.id, x: $0.x, y: $0.y) }
    }

    /// A pulse in a word, as the kit's actionOf writes it: its buttons, else its step.
    static func pulseWord(_ state: ArcadePadState) -> String {
        if !state.buttons.isEmpty { return state.buttons.joined(separator: "+") }
        if state.sx > 0 { return "right" }
        if state.sx < 0 { return "left" }
        if state.sy > 0 { return "down" }
        if state.sy < 0 { return "up" }
        return ""
    }

    /// The kit's touchvec.js run(): before each event every job due at or
    /// before it runs, at its own time; then 1500 ms more. Outputs are written
    /// as the kit writes them: a pulse's word, '<hold> on' and '<hold> off',
    /// 'info:<key>', 'dud:<reason>'.
    static func run(_ mode: String, _ steps: [[String: Any]], tier: String = "easy", table: ArcadeTouchTable = .standard,
                    fit: ArcadeTouchFit? = nil) -> TouchRun {
        var pad = ArcadeTouchRecognizer(table: table.onTier(tier))
        pad.mode = mode
        pad.fit = fit
        var result = TouchRun()
        var holds: [String: String] = [:]
        var now = 0.0
        func record(_ outputs: [ArcadeTouchOutput], at t: Double) {
            for output in outputs {
                result.raw.append(output)
                switch output {
                case .pad(let source, let state):
                    if source == ArcadeTouchRecognizer.fingerSourceName { continue }
                    if source.hasPrefix("touch-p") {
                        if let state { result.timed.append((out: pulseWord(state), t: t)) }
                        continue
                    }
                    if let state {
                        let word = state.buttons.isEmpty ? "hold" : state.buttons.joined(separator: "+")
                        holds[source] = word
                        result.timed.append((out: word + " on", t: t))
                    } else if let word = holds.removeValue(forKey: source) {
                        result.timed.append((out: word + " off", t: t))
                    }
                case .info(let what):
                    result.timed.append((out: "info:" + what, t: t))
                case .dud(let dud):
                    result.timed.append((out: "dud:" + dud.reason.rawValue, t: t))
                default:
                    break
                }
            }
        }
        func until(_ end: Double) {
            while let due = pad.nextDue, due <= end {
                record(pad.advance(to: due), at: due)
            }
            now = end
        }
        for event in expand(steps) {
            until(event.t)
            switch event.type {
            case "down":
                record(pad.start(id: event.id, x: event.x, y: event.y, width: 400, height: 800, now: event.t), at: event.t)
            case "move":
                record(pad.move(id: event.id, x: event.x, y: event.y, now: event.t), at: event.t)
            default:
                record(pad.end(id: event.id, now: event.t), at: event.t)
            }
        }
        until(now + 1500)
        return result
    }

    /// The kit's matches(): the same outputs in the same order; '@ms' entries also match the time.
    static func matches(_ run: TouchRun, _ expect: [String]) -> Bool {
        guard run.timed.count == expect.count else { return false }
        for (index, entry) in expect.enumerated() {
            let parts = entry.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if run.timed[index].out != parts[0] { return false }
            if parts.count > 1, let at = Double(parts[1]), run.timed[index].t.rounded() != at { return false }
        }
        return true
    }

    /// One vector from the kit's file shape: {id, mode, tier, steps, expect}.
    static func runVector(_ vector: [String: Any], table: ArcadeTouchTable = .standard) -> TouchRun {
        let steps = ((vector["steps"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        return run((vector["mode"] as? String) ?? "menu", steps, tier: (vector["tier"] as? String) ?? "easy", table: table)
    }

    /// The kit's shared vectors (core/test/touch_vectors.json, Oct 20 2026):
    /// the first-timer set (FT) and the menus (M), exactly as the kit has them.
    static let sharedVectorsJSON = """
    [
    {"id":"FT1","what":"still 150 ms","set":"first-timer","mode":"fight","tier":"easy","steps":[{"upAt":150}],"expect":["CL@150"]},
    {"id":"FT2","what":"still 420 ms, drift 10 pt","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[420,0,10]],"upAt":420}],"expect":["CL@420"]},
    {"id":"FT3","what":"still 480 ms, drift 26 pt","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[480,26,0]],"upAt":480}],"expect":["CL@480"]},
    {"id":"FT4","what":"VoiceOver-style double-tap: two 120 ms taps, 250 ms apart","set":"first-timer","mode":"fight","tier":"easy","steps":[{"upAt":120},{"at":370,"upAt":120}],"expect":["CL@120","CL@490"]},
    {"id":"FT5","what":"rest 300 ms, then 45 pt up over 200 ms","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[300,0,0],[500,0,-45]],"upAt":520}],"expect":["CU"]},
    {"id":"FT6","what":"rest 700 ms","set":"first-timer","mode":"fight","tier":"easy","steps":[{"upAt":700}],"expect":["block on@500","block off@700"]},
    {"id":"FT7","what":"rest 700 ms, then 50 pt right","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[700,0,0],[850,50,0]],"upAt":870}],"expect":["block on@500","block off","CR"]},
    {"id":"FT8","what":"slow flick, 35 pt right over 600 ms","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[600,35,0]],"upAt":620}],"expect":["CR"]},
    {"id":"FT9","what":"15 pt slide, lifted at 200 ms","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[200,15,0]],"upAt":200}],"expect":["CL@200"]},
    {"id":"FT10","what":"two fingers landing 90 ms apart, lifted at 200 ms","set":"first-timer","mode":"fight","tier":"easy","steps":[{"fingers":2,"landGapMs":90,"upAt":200}],"expect":["info:quiet@600"]},
    {"id":"FT11","what":"two-finger double-tap, 350 ms gap","set":"first-timer","mode":"fight","tier":"easy","steps":[{"fingers":2,"upAt":100},{"at":450,"fingers":2,"upAt":100}],"expect":["START"]},
    {"id":"FT12","what":"two fingers, 40 pt down","set":"first-timer","mode":"fight","tier":"easy","steps":[{"fingers":2,"path":[[150,0,40]],"upAt":170}],"expect":["info:status"]},
    {"id":"FT13","what":"two fingers still 1.1 s","set":"first-timer","mode":"fight","tier":"easy","steps":[{"fingers":2,"upAt":1100}],"expect":["info:help@1000"]},
    {"id":"FT14","what":"three-finger tap","set":"first-timer","mode":"fight","tier":"easy","steps":[{"fingers":3,"upAt":120}],"expect":["START"]},
    {"id":"FT15","what":"two-finger flick up","set":"first-timer","mode":"fight","tier":"easy","steps":[{"fingers":2,"path":[[150,0,-40]],"upAt":170}],"expect":["info:where"]},
    {"id":"FT16","what":"a very slow flick: 30 pt left over 1200 ms (never a block)","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[1200,-30,0]],"upAt":1220}],"expect":["CL"]},
    {"id":"FT17","what":"rest, then slide 30 pt out (under 40): the block stays","set":"first-timer","mode":"fight","tier":"easy","steps":[{"path":[[700,0,0],[800,0,-30]],"upAt":900}],"expect":["block on@500","block off@900"]},
    {"id":"M1","what":"flick right 30 pt: one step (DDOWN on a list screen is the input bridge, not the recognizer)","set":"menus","mode":"menu","steps":[{"path":[[60,30,0]],"upAt":80}],"expect":["right"]},
    {"id":"M2","what":"two taps with a 380 ms gap: choose","set":"menus","mode":"menu","steps":[{"upAt":100},{"at":480,"upAt":100}],"expect":["A"]},
    {"id":"M3","what":"a single 420 ms still tap: hear it, 400 ms after the lift","set":"menus","mode":"menu","steps":[{"upAt":420}],"expect":["info:here@820"]},
    {"id":"M4","what":"two-finger scrub, 3 reversals of 30 pt in 900 ms: back, and no line step","set":"menus","mode":"menu","steps":[{"fingers":2,"path":[[225,30,0],[450,0,0],[675,30,0],[900,0,0]],"upAt":920}],"expect":["B"]},
    {"id":"M5","what":"two-finger tap: quiet","set":"menus","mode":"menu","steps":[{"fingers":2,"upAt":100}],"expect":["info:quiet@500"]},
    {"id":"M6","what":"two-finger double-tap: start","set":"menus","mode":"menu","steps":[{"fingers":2,"upAt":100},{"at":300,"fingers":2,"upAt":100}],"expect":["START"]},
    {"id":"M7","what":"travel of 25 pt: a dud (short flick)","set":"menus","mode":"menu","steps":[{"path":[[80,25,0]],"upAt":100}],"expect":["dud:shortFlick"]},
    {"id":"M8","what":"one finger held still 1.1 s: repeat","set":"menus","mode":"menu","steps":[{"upAt":1100}],"expect":["info:repeat@1000"]},
    {"id":"M9","what":"two fingers held still 1.1 s: help","set":"menus","mode":"menu","steps":[{"fingers":2,"upAt":1100}],"expect":["info:help@1000"]},
    {"id":"M10","what":"two-finger flick down: next line","set":"menus","mode":"menu","steps":[{"fingers":2,"path":[[100,0,40]],"upAt":120}],"expect":["info:nextLine"]},
    {"id":"M11","what":"two-finger flick up: line before","set":"menus","mode":"menu","steps":[{"fingers":2,"path":[[100,0,-40]],"upAt":120}],"expect":["info:prevLine"]},
    {"id":"M12","what":"three-finger tap: start","set":"menus","mode":"menu","steps":[{"fingers":3,"upAt":100}],"expect":["START"]},
    {"id":"M13","what":"three-finger flick left: C left","set":"menus","mode":"menu","steps":[{"fingers":3,"path":[[80,-40,0]],"upAt":100}],"expect":["CL"]},
    {"id":"M14","what":"a still 600 ms touch: a dud (slow tap)","set":"menus","mode":"menu","steps":[{"upAt":600}],"expect":["dud:slowTap"]},
    {"id":"M15","what":"a second tap 500 ms late: two taps and a lateDouble dud","set":"menus","mode":"menu","steps":[{"upAt":100},{"at":600,"upAt":100}],"expect":["info:here@500","dud:lateDouble","info:here@1100"]},
    {"id":"M16","what":"two fingers landing 300 ms apart: a dud (apart)","set":"menus","mode":"menu","steps":[{"fingers":2,"landGapMs":300,"upAt":400}],"expect":["dud:apart"]},
    {"id":"M17","what":"a slow 26 pt drift over 800 ms: a dud (drift)","set":"menus","mode":"menu","steps":[{"path":[[800,26,0]],"upAt":800}],"expect":["dud:drift"]},
    {"id":"M18","what":"flick down then keep the finger down: steps again after 1 s, then every 300 ms","set":"menus","mode":"menu","steps":[{"path":[[60,0,30]],"upAt":1500}],"expect":["down","down","down"]},
    {"id":"M19","what":"pause screen: two-finger double-tap is start (the menu table)","set":"menus","mode":"pause","steps":[{"fingers":2,"upAt":100},{"at":300,"fingers":2,"upAt":100}],"expect":["START"]},
    {"id":"M20","what":"a demo: two-finger double-tap is start (the menu table)","set":"menus","mode":"demo","steps":[{"fingers":2,"upAt":100},{"at":300,"fingers":2,"upAt":100}],"expect":["START"]},
    {"id":"M21","what":"a demo: one tap is hear it, never an attack","set":"menus","mode":"demo","steps":[{"upAt":120}],"expect":["info:here@520"]}
    ]
    """

    /// A seeded generator for the randomised sets.
    struct Seeded {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
    }

    static func hundredth(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: The checks

    static func touchPlay() throws {
        touchTablesV2()
        touchVectors()
        touchReports()
        touchTiming()
        touchFeel()
        touchSpeechQueue()
        touchPadHeld()
        touchWords()
        touchPractice()
        touchBridgeAndReport()
    }

    static func touchTablesV2() {
        let table = ArcadeTouchTable.standard
        check(table.flickPx == 28 && table.tapMs == 450 && table.tapSlopPx == 24 && table.doubleMs == 400 && table.holdMs == 500
              && table.repeatEveryMs == 300 && table.base.flickBreaksPx == 40 && table.base.stillPx == 3 && table.base.stillMs == 150,
              "the relaxed numbers, and a rest waits until the fingers stop")
        check(ArcadeTouchNumbers() == table.base, "a table that leaves numbers out takes the kit's v2 defaults")
        check(table.base.scrubReversals == 2 && table.base.scrubLegPx == 20 && table.base.scrubWithinMs == 1200, "the scrub's numbers")
        check(table.hasTiers && table.tier == "easy" && Set(table.fights.keys) == ["easy", "full"], "Easy and Full fight controls, Easy first")
        let fight = table.numbers(mode: "fight")
        check(fight.tapMs == 500 && fight.holdMs == 500 && fight.tapSlopPx == 28 && fight.flickPx == 28 && fight.doubleMs == 400,
              "Easy's own timing: a tap is anything lifted before the 500 ms rest, the slop is the flick")
        check(table.numbers(mode: "menu").tapMs == 450 && table.numbers(mode: "demo").tapSlopPx == 24, "menus keep the top-level numbers")
        check(table.gestures(mode: "demo", zone: nil) == table.menu && table.gestures(mode: "pause", zone: nil) == table.menu,
              "a demo and the pause screen use the menu table")
        check(table.menu.scrubs[2] == .pulse(ArcadePadState(buttons: ["B"])) && table.menu.says["scrub2"] == "back"
              && table.menu.taps[1] == .info("here") && table.menu.says["tap1"] == "hear it"
              && table.menu.taps[2] == .info("quiet") && table.menu.flicks[1]?.says[.right] == "next",
              "the VoiceOver-style menu table, with its words")
        check(table.zones.map { $0.name } == ["pad"] && table.zone(x: 10, y: 790, width: 400, height: 800) == ArcadeZone("pad"),
              "Easy is one zone, the whole pad")
        let pad = table.gestures(mode: "fight", zone: ArcadeZone("pad"))
        check(pad.taps[1] == .pulse(ArcadePadState(buttons: ["CL"])) && pad.flickBreaks == [1] && pad.says["hold1"] == "block"
              && pad.holdTimes[1] == 500 && pad.flicks[1]?.says[.up] == "strong punch" && pad.taps[3] == .pulse(ArcadePadState(buttons: ["START"])),
              "the Easy pad: tap and four flicks attack, a rest blocks and breaks into a flick")
        let full = table.onTier("full")
        check(full.zones.isEmpty && full.zone(x: 50, y: 400, width: 400, height: 800) == .left
              && full.gestures(mode: "fight", zone: .left).flicks[2]?.actions[.down] == .info("status")
              && full.gestures(mode: "fight", zone: .right).flickBreaks.contains(1)
              && full.gestures(mode: "fight", zone: .left).holds[2] == .info("help")
              && full.anywhere.holds[3] == .info("help") && full.anywhere.holdTimes[3] == 800,
              "Full: the two halves, status and where on the left, a flick out of the right-hand block, help on two or three fingers")
        check(table.fight == table.fights["full"], "`fight` is an exact copy of Full, for build 341")
        var older = v1Table
        older.tier = "easy"
        check(older.active == older.fight && !older.hasTiers && older.numbers(mode: "fight") == older.base,
              "a pack with no tiers falls back to `fight`, on its own numbers")
        let block: [String: Any] = ["buttons": ["block"]]
        let start: [String: Any] = ["buttons": ["START"]]
        let blockHold: [String: Any] = ["hold": block, "flickBreaks": true, "say": "block"]
        let pauseTap: [String: Any] = ["pulse": start, "say": "pause"]
        let plainTap: [String: Any] = ["pulse": start]
        let repeatHold: [String: Any] = ["info": "repeat"]
        let anywhereJSON: [String: Any] = ["hold1": blockHold, "tap3": pauseTap]
        let zoneJSON: [String: Any] = ["hold1": repeatHold, "tap3": plainTap]
        let overlaid = ArcadeGestureSet(json: anywhereJSON).overlaid(by: ArcadeGestureSet(json: zoneJSON))
        check(overlaid.flickBreaks.isEmpty && overlaid.says["hold1"] == nil && overlaid.says["tap3"] == nil,
              "a zone's own gesture brings its own flickBreaks and words, or none")
    }

    static func touchVectors() {
        // The kit's own first-timer and menu vectors, exactly as its recognizer gives them.
        let shared = ((try? JSONSerialization.jsonObject(with: Data(sharedVectorsJSON.utf8))) as? [Any]) ?? []
        check(shared.count == 38, "the shared first-timer and menu vectors are read (\(shared.count))")
        for case let vector as [String: Any] in shared {
            let got = runVector(vector)
            let expect = (vector["expect"] as? [String]) ?? []
            check(matches(got, expect), "shared vector " + ((vector["id"] as? String) ?? "?") + ": " + got.shown
                  + " (wanted " + expect.joined(separator: ", ") + ")")
        }
        // The kit's whole file, when it is given: every vector, on its own table, which is the app's standard one.
        if let path = ProcessInfo.processInfo.environment["KIT_TOUCH_VECTORS"], !path.isEmpty {
            let parsed = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let file = (parsed as? [String: Any]) ?? [:]
            let table = ArcadeTouchTable(json: file["table"] as? [String: Any])
            check(table == ArcadeTouchTable.standard, "the kit's table is the app's standard table")
            let list = (file["vectors"] as? [Any]) ?? []
            check(!list.isEmpty, "the kit's touch vectors are read")
            var failed: [String] = []
            for case let vector as [String: Any] in list {
                let got = runVector(vector, table: table)
                if !matches(got, (vector["expect"] as? [String]) ?? []) { failed.append(((vector["id"] as? String) ?? "?") + ": " + got.shown) }
            }
            check(failed.isEmpty, "every kit vector: \(list.count - failed.count) of \(list.count); first failures: "
                  + failed.prefix(5).joined(separator: "; "))
        }

        // Randomised Easy sets in the kit's shapes (seeded).
        var random = Seeded(state: 20_261_020)
        var taps = 0
        for _ in 0..<1000 {
            let ms = random.range(80, 480).rounded()
            let distance = random.range(0, 27)
            let angle = random.range(0, 2 * Double.pi)
            let got = run("fight", [step(path: [[ms, hundredth(distance * cos(angle)), hundredth(distance * sin(angle))]], up: ms)])
            if got.words == ["CL"] { taps += 1 }
        }
        check(taps == 1000, "1,000 still touches of 80-480 ms with up to 27 pt of drift: all weak punches (\(taps))")
        let ways: [(base: Double, attack: String)] = [(Double.pi, "CL"), (-Double.pi / 2, "CU"), (Double.pi / 2, "CD"), (0, "CR")]
        var flicks = 0
        for _ in 0..<1000 {
            let way = ways[Int(random.next() * 4) % 4]
            let ms = random.range(80, 1200).rounded()
            let distance = random.range(28.5, 120)
            let angle = way.base + random.range(-Double.pi / 6, Double.pi / 6)
            let got = run("fight", [step(path: [[ms, hundredth(distance * cos(angle)), hundredth(distance * sin(angle))]], up: ms + 20)])
            if got.words == [way.attack] { flicks += 1 }
        }
        check(flicks == 1000, "1,000 flicks of 28.5-120 pt over 80-1200 ms, up to 30 degrees off: the right attack, never a block (\(flicks))")
        var rests = 0
        for _ in 0..<200 {
            let ms = random.range(520, 1500).rounded()
            if matches(run("fight", [step(up: ms)]), ["block on@500", "block off@" + String(Int(ms))]) { rests += 1 }
        }
        check(rests == 200, "200 rests of 520-1500 ms: a block at 500 ms, let go at the lift (\(rests))")
    }

    static func touchReports() {
        // The finger source: on as the first finger lands, off after the last one's own outputs.
        let tap = run("fight", [step(up: 150)])
        let fingerOn = ArcadeTouchOutput.pad(source: ArcadeTouchRecognizer.fingerSourceName, state: ArcadePadState())
        let fingerOff = ArcadeTouchOutput.pad(source: ArcadeTouchRecognizer.fingerSourceName, state: nil)
        if let on = tap.raw.firstIndex(of: fingerOn), let off = tap.raw.firstIndex(of: fingerOff),
           let attack = tap.raw.firstIndex(of: .pad(source: "touch-p1", state: ArcadePadState(buttons: ["CL"]))) {
            check(on == 0 && attack < off, "'touch-finger' is held from the first finger down to after the last one's outputs")
        } else {
            check(false, "the finger source and the attack are sent")
        }
        // The rest: its report at 500 ms with its words; the lift reported as a release.
        let rest = run("fight", [step(up: 700)])
        check(rest.reports.map { $0.key } == ["hold1", "release"] && rest.reports[0].ms == 500 && rest.reports[0].say == "block",
              "the rest blocks at 500 ms and the lift lets it go")
        let broke = run("fight", [step(path: [[700, 0, 0], [850, 50, 0]], up: 870)])
        check(broke.reports.map { $0.key } == ["hold1", "release", "flick1"] && broke.reports[2].fromHold
              && broke.reports[2].direction == .right && broke.reports[2].say == "strong kick",
              "a flick out of a block: the block lets go, then the strong kick")
        let scrub = run("menu", [step(fingers: 2, path: [[225, 30, 0], [450, 0, 0], [675, 30, 0], [900, 0, 0]], up: 920)])
        check(scrub.words == ["B"] && scrub.reports.map { $0.key } == ["scrub2"], "a two-finger scrub is Back, and never a two-finger flick")
        let held = run("menu", [step(path: [[60, 0, 30]], up: 1500)])
        check(held.words == ["down", "down", "down"] && held.reports.map { $0.repeatStep } == [false, true, true],
              "a held flick repeats after a second, then every 300 ms, each step reported")
        check(run("menu", [step(fingers: 2, path: [[100, -40, 0]], up: 150)]).words == ["dud:noAction"],
              "two fingers flicked left in a menu: nothing there")
        check(run("fight", [step(fingers: 3, path: [[100, 40, 0]], up: 150)]).words == ["dud:noAction"],
              "three fingers moving in Easy: nothing there")
        var older = ArcadeTouchRecognizer(table: v1Table)
        _ = older.start(id: 1, x: 50, y: 50, width: 400, now: 0)
        _ = older.end(id: 1, now: 50)
        let lone = older.advance(to: 1000).compactMap { (output: ArcadeTouchOutput) -> ArcadeDudReason? in
            if case .dud(let dud) = output { return dud.reason }
            return nil
        }
        check(lone == [.noAction], "a lone tap where only a double-tap works: nothing there")
        let lift = run("menu", [step(path: [[100, 10, 0]], up: 300)]).lifts
        check(lift.count == 1 && lift[0].ms == 300 && lift[0].far == 10 && !lift[0].fired && lift[0].fingers == 1,
              "the lift's measurements: 300 ms, 10 pt, nothing fired")
        check(ArcadeFeel.dud == [ArcadeBuzz(style: .warning)], "every dud gets the warning buzz")
    }

    static func touchTiming() {
        let menu = ArcadeTouchTable.standard.numbers(mode: "menu")
        let easy = ArcadeTouchTable.standard.numbers(mode: "fight")
        let quickMenu = menu.fitted(.quick)
        check(quickMenu.tapMs == 250 && quickMenu.doubleMs == 300 && quickMenu.tapSlopPx == 12 && quickMenu.flickPx == 20 && quickMenu.holdMs == 250,
              "Quick: the old quarter-second values")
        let quickEasy = easy.fitted(.quick)
        check(quickEasy.tapMs == 250 && quickEasy.holdMs == 250 && quickEasy.tapSlopPx == 20 && quickEasy.flickPx == 20,
              "Quick keeps Easy's shape: no dead gap")
        check(menu.fitted(nil) == menu, "Relaxed is the table's own")
        check(run("fight", [step(up: 300)], fit: .quick).words == ["block on", "block off"], "with Quick, a 300 ms rest blocks")
        check(run("menu", [step(up: 1100)], fit: .quick).words == ["info:repeat"], "an info hold keeps its own second")
        let slow = ArcadeTouchFit(tapMs: 600, doubleMs: 500, slopPx: 26, flickPx: 32, restMs: 700)
        check(run("fight", [step(up: 600)], fit: slow).words == ["CL"]
              && run("fight", [step(up: 800)], fit: slow).words == ["block on", "block off"],
              "fitted to a slow tapper: 600 ms is a tap, the rest is 700 ms")

        let fit = ArcadeTouchFit.fitted(taps: [300, 320, 340, 360, 380, 400, 420, 440, 460, 480],
                                        gaps: [250, 270, 290, 310, 330],
                                        drifts: [2, 4, 6, 8, 10, 12, 14, 16, 18, 20],
                                        flicks: [40, 50, 60, 70, 80])
        check(near(fit.tapMs, 598) && near(fit.restMs, 598) && near(fit.doubleMs, 429) && near(fit.slopPx, 27) && near(fit.flickPx, 31),
              "the fit: p90 taps x 1.3, rest at least 450, p90 gaps x 1.3, p90 drift x 1.5, flick at least slop + 4")
        let bounded = ArcadeTouchFit.fitted(taps: [900, 900, 900, 900, 900], gaps: [100, 100, 100, 100, 100],
                                            drifts: [1, 1, 1, 1, 1], flicks: [200, 200, 200, 200, 200])
        check(bounded.tapMs == 650 && bounded.restMs == 900 && bounded.doubleMs == 350 && bounded.slopPx == 16 && bounded.flickPx == 40,
              "every number within its bounds")
        check(ArcadeTouchFit.fitted(taps: [300], gaps: [], drifts: [3], flicks: []) == .relaxed, "too few samples keep Relaxed")
        check(ArcadeTouchFit.percentile([5, 1, 3], 50) == 3 && ArcadeTouchFit.percentile([], 90) == nil
              && ArcadeTouchFit.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 10) == 1, "nearest-rank percentiles")

        var store = ArcadeTouchTimingStore()
        check(store.choice == .relaxed && store.overlay == nil, "Relaxed by default")
        store.choice = .fitted
        check(store.overlay == nil, "Fitted to me before any practice is Relaxed")
        store.fitted = slow
        check(store.overlay == slow && (store.kitValue["choice"] as? String) == "fitted" && (store.kitValue["restMs"] as? Double) == 700,
              "Fitted to me, and the kit is told the numbers")
        check(ArcadeTouchTimingStore.decode(store.encoded()) == store, "kept and read back")
        check(ArcadeTouchTimingStore.decode(Data("nonsense".utf8)) == ArcadeTouchTimingStore() && ArcadeTouchTimingStore.decode(nil).choice == .relaxed,
              "anything unreadable is Relaxed")
        store.choice = .quick
        check(store.overlay == .quick && ArcadeTouchTiming.allCases.map { $0.label } == ["Fitted to me", "Relaxed", "Quick"], "Quick, and the labels")
    }

    static func touchFeel() {
        func feels(_ mode: String, _ steps: [[String: Any]], tier: String = "easy") -> [[ArcadeBuzz]] {
            run(mode, steps, tier: tier).reports.map { ArcadeFeel.of($0) }
        }
        let tick = [ArcadeBuzz(style: .selection)]
        let light = [ArcadeBuzz(style: .light)]
        let medium = [ArcadeBuzz(style: .medium)]
        let heavy = [ArcadeBuzz(style: .heavy)]
        let rigid = [ArcadeBuzz(style: .rigid)]
        let soft = [ArcadeBuzz(style: .soft)]
        let twoLight = [ArcadeBuzz(style: .light), ArcadeBuzz(style: .light, afterMs: 60)]
        let scrub = step(fingers: 2, path: [[225, 30, 0], [450, 0, 0], [675, 30, 0], [900, 0, 0]], up: 920)
        check(feels("menu", [step(path: [[60, 30, 0]], up: 80)]) == [tick], "a menu step: a selection tick")
        check(feels("menu", [step(up: 100)]) == [tick], "hear it: a tick")
        check(feels("menu", [step(up: 100), step(at: 480, up: 100)]) == [medium], "choose: medium")
        check(feels("menu", [scrub]) == [twoLight], "back: two light 60 ms apart")
        check(feels("menu", [step(fingers: 2, up: 100)]) == [soft], "quiet: soft")
        check(feels("menu", [step(fingers: 2, up: 100), step(at: 300, fingers: 2, up: 100)]) == [rigid], "Start: rigid")
        check(feels("menu", [step(fingers: 2, up: 1100)]) == [soft], "help: soft")
        check(feels("fight", [step(up: 150)]) == [light], "the Easy tap attack: light")
        check(feels("fight", [step(path: [[100, -40, 0]], up: 150)]) == [medium], "a weak punch flick: medium")
        check(feels("fight", [step(path: [[100, 0, -40]], up: 150)]) == [heavy], "a strong punch flick: heavy")
        check(feels("fight", [step(up: 700)]) == [rigid, soft], "block on: rigid; off: soft")
        check(feels("fight", [step(path: [[700, 0, 0], [850, 50, 0]], up: 870)]) == [rigid, soft, heavy], "a strong kick out of a block: heavy")
        check(feels("fight", [step(fingers: 2, path: [[150, 0, 40]], up: 170)]) == [tick], "status: a tick")
        check(feels("fight", [step(fingers: 3, up: 120)]) == [rigid], "pause: rigid")
        check(feels("fight", [step(x: 300, up: 100)], tier: "full") == [medium] && feels("fight", [step(x: 50, up: 100)], tier: "full") == [medium],
              "Full: jump and change target, medium")
        check(ArcadeFeel.cue("telegraph") == [ArcadeBuzz(style: .rigid), ArcadeBuzz(style: .rigid, afterMs: 70)]
              && ArcadeFeel.cue("hurt") == heavy && ArcadeFeel.cue("landed") == twoLight
              && ArcadeFeel.cue("blocked") == [ArcadeBuzz(style: .rigid, intensity: 0.6)]
              && ArcadeFeel.cue("reach") == [ArcadeBuzz(style: .soft, intensity: 0.4)]
              && ArcadeFeel.cue("ko") == [ArcadeBuzz(style: .success)] && ArcadeFeel.cue("other").isEmpty,
              "the kit's game cues: the wind-up's double buzz, hurt, landed, blocked, in reach, KO")
        check(ArcadeFeel.taken == [ArcadeBuzz(style: .success)] && ArcadeFeel.back == twoLight && ArcadeFeel.start == rigid,
              "the pad taken, the escape scrub and the magic tap")
    }

    static func touchSpeechQueue() {
        check(ArcadeSpeechQueue.timeoutMs("Pad on.") == 1600 && ArcadeSpeechQueue.timeoutMs(String(repeating: "word ", count: 30)) == 8000,
              "0.8 s + 0.4 s a word, at most 8 s")
        var queue = ArcadeSpeechQueue()
        let first = ArcadeSpeechItem(id: "1", text: "Pad on.", cls: "answer")
        let second = ArcadeSpeechItem(id: "2", text: "Legal notice.", cls: "screen")
        let own = ArcadeSpeechItem(id: nil, text: "Low Power Mode is on.", cls: "screen")
        check(queue.add(first, now: 0) == [.post(first)] && queue.deadline == 1600, "the first line is said at once")
        check(queue.add(second, now: 10).isEmpty && queue.add(own, now: 20).isEmpty && queue.waiting.count == 2,
              "one at a time: the rest wait")
        check(queue.finished(text: "Something else.", ok: true, now: 100).isEmpty && queue.current == first,
              "another announcement's end changes nothing")
        var retried = first
        retried.tries = 1
        check(queue.finished(text: "Pad on.", ok: false, now: 200) == [.post(retried)], "VoiceOver did not say it: once more")
        check(queue.finished(text: "Pad on.", ok: false, now: 300) == [.ack(id: "1", ok: false), .post(second)],
              "not said twice: acknowledged as not spoken, and the next one starts")
        check(queue.expire(now: 1899).isEmpty, "not given up before its time")
        check(queue.expire(now: 1900) == [.ack(id: "2", ok: false), .post(own)], "a missing end times out, and the queue moves on")
        check(queue.finished(text: nil, ok: true, now: 2000).isEmpty && queue.isIdle, "the app's own line needs no answer")
        _ = queue.add(first, now: 3000)
        _ = queue.add(second, now: 3010)
        check(queue.quiet() == [.silence] && queue.isIdle && queue.quiet().isEmpty,
              "quiet stops everything, VoiceOver's line too, and clears the rest")
        check(queue.add(own, now: 3100) == [.post(own)], "and the next line is said at once")
        var cut = ArcadeSpeechQueue()
        _ = cut.add(ArcadeSpeechItem(id: "7", text: "Your foe attacks.", cls: "alert"), now: 0)
        _ = cut.add(ArcadeSpeechItem(id: "8", text: "Round two.", cls: "flow"), now: 5)
        let hers = ArcadeSpeechItem(id: nil, text: "Playing.", cls: "answer", interrupts: true)
        check(cut.add(hers, now: 10) == [.ack(id: "7", ok: false), .ack(id: "8", ok: false), .stop, .post(hers)],
              "her own action cuts the line being said and drops what waits")

        // The same words again at once (Pad practice's say-backs): the cut one's end is its own.
        var same = ArcadeSpeechQueue()
        let tapBack = ArcadeSpeechItem(id: nil, text: "Tap: hear it.", cls: "answer", interrupts: true)
        _ = same.add(tapBack, now: 0)
        check(same.add(tapBack, now: 100) == [.stop, .post(tapBack)] && same.cutTexts == ["Tap: hear it."],
              "a say-back cut by the same say-back")
        check(same.finished(text: "Tap: hear it.", ok: false, now: 150).isEmpty && same.current == tapBack && same.cutTexts.isEmpty,
              "VoiceOver's end for the cut one (not spoken) is not the new one's: no retry, no stutter")
        check(same.finished(text: "Tap: hear it.", ok: true, now: 900).isEmpty && same.isIdle, "the new one ends on its own end")

        // The kit's answers (urgent, with an id) cut the line being said here; an older kit keeps its flush.
        check(ArcadeSpeechQueue.kitInterrupts(flush: false, urgent: true, id: "k3")
              && !ArcadeSpeechQueue.kitInterrupts(flush: false, urgent: false, id: "k4")
              && !ArcadeSpeechQueue.kitInterrupts(flush: false, urgent: true, id: nil)
              && ArcadeSpeechQueue.kitInterrupts(flush: true, urgent: false, id: nil),
              "her answers cut, as the kit has already cut its own line")

        // The kit cut its line for her answer (a clip, say): its lines here go, the app's own stays.
        var kit = ArcadeSpeechQueue()
        let menuLine = ArcadeSpeechItem(id: "k4", text: "Main menu.", cls: "screen")
        let mine = ArcadeSpeechItem(id: nil, text: "Low Power Mode is on.", cls: "flow")
        _ = kit.add(menuLine, now: 0)
        _ = kit.add(ArcadeSpeechItem(id: "k5", text: "Quest.", cls: "screen"), now: 1)
        _ = kit.add(mine, now: 2)
        check(kit.cutKit(now: 10) == [.silence, .post(mine)] && kit.current == mine && kit.waiting.isEmpty
              && kit.cutTexts == ["Main menu."], "the kit's cut: its line being said stops, its waiting lines go")
        check(kit.cutKit(now: 20).isEmpty && kit.current == mine, "the app's own line is not the kit's to cut")

        // A restarted page numbers its lines from the start again: the old page's items go, unanswered.
        var reload = ArcadeSpeechQueue()
        let restart = ArcadeSpeechItem(id: nil, text: "The game restarted while you were away.", cls: "screen")
        _ = reload.add(ArcadeSpeechItem(id: "k9", text: "Round two.", cls: "flow"), now: 0)
        _ = reload.add(restart, now: 1)
        _ = reload.add(ArcadeSpeechItem(id: "k10", text: "Fight.", cls: "flow"), now: 2)
        check(reload.dropKit(now: 10) == [.post(restart)] && reload.current == restart && reload.waiting.isEmpty,
              "a new page: the old page's items go with no answer, the app's own line is said")
    }

    static func touchPadHeld() {
        check(ArcadePadWords.label == "Game pad" && ArcadePadWords.hint == "Double-tap to play.", "the pad's label and short hint")
        check(ArcadePadWords.value(mode: "menu") == "Menu" && ArcadePadWords.value(mode: "fight") == "Fight"
              && ArcadePadWords.value(mode: "pause") == "Paused" && ArcadePadWords.value(mode: "demo") == "Demo"
              && ArcadePadWords.value(mode: "other") == "Menu", "the pad's value from the kit's mode")
        var hold = ArcadePadHold()
        check(hold.focus(now: 0) == [.focusedNotHeld] && hold.focused && !hold.held,
              "focus waits for the hold, and the kit's voice may go once VoiceOver has read the pad")
        check(hold.touch(now: 10, voiceOver: false).isEmpty && !hold.held, "with VoiceOver off there is nothing to take")
        check(hold.touch(now: 20, voiceOver: true) == [.risingChime, .takenBuzz, .holdSpeech(false), .say("Pad on.", cls: "answer")] && hold.held,
              "the first touch takes the pad: rising chime, buzz, the kit's voice back, Pad on.")
        check(hold.touch(now: 30, voiceOver: true).isEmpty && hold.focus(now: 35).isEmpty, "touches while held change nothing")
        hold.setMode("fight")
        check(hold.lostFocus(now: 40, mode: "fight", pauseOnLeave: true) == [.fallingChime, .holdSpeech(true), .pauseGame]
              && !hold.held && hold.autoPaused, "VoiceOver back mid-fight: falling chime, the kit's voice held, the fight paused")
        hold.setMode("pause")
        check(hold.autoPaused && hold.touch(now: 50, voiceOver: true) == [.risingChime, .takenBuzz, .holdSpeech(false),
                                                                          .say("Paused. Two-finger double-tap to fight.", cls: "screen")],
              "taken again on the pause screen: Pad on. only once a session, and the paused line")
        check(hold.lostFocus(now: 60, mode: "menu", pauseOnLeave: true) == [.fallingChime, .holdSpeech(true)], "in a menu nothing pauses")
        check(hold.lostFocus(now: 70, mode: "fight", pauseOnLeave: true) == [.holdSpeech(true)], "focus leaving a pad not held only holds the voice")
        var off = ArcadePadHold()
        _ = off.touch(now: 0, voiceOver: true)
        check(off.lostFocus(now: 10, mode: "fight", pauseOnLeave: false) == [.fallingChime, .holdSpeech(true)], "Pause when I leave the pad off")
        var paused = ArcadePadHold()
        _ = paused.touch(now: 0, voiceOver: true)
        _ = paused.lostFocus(now: 10, mode: "fight", pauseOnLeave: true)
        paused.forgetPause()
        check(!paused.touch(now: 20, voiceOver: true).contains(.say(ArcadeTouchLines.pausedReturn, cls: "screen")),
              "a fight left some other way says nothing on return")
        var resumed = ArcadePadHold()
        _ = resumed.touch(now: 0, voiceOver: true)
        resumed.setMode("fight")
        _ = resumed.lostFocus(now: 10, mode: "fight", pauseOnLeave: true)
        resumed.setMode("pause")
        resumed.setMode("fight")   // resumed from the strip's Pause, or the magic tap on the pad not held
        check(!resumed.autoPaused && !resumed.touch(now: 20, voiceOver: true).contains(.say(ArcadeTouchLines.pausedReturn, cls: "screen")),
              "a fight resumed some other way: no paused line in a live fight")
        var neverPaused = ArcadePadHold()
        _ = neverPaused.touch(now: 0, voiceOver: true)
        neverPaused.setMode("fight")
        _ = neverPaused.lostFocus(now: 10, mode: "fight", pauseOnLeave: true)
        check(!neverPaused.touch(now: 20, voiceOver: true).contains(.say(ArcadeTouchLines.pausedReturn, cls: "screen")) && !neverPaused.autoPaused,
              "the pause never came (the game still fighting): no paused line")
        var spot = ArcadePadHold()
        check(!spot.offPad(voiceOver: true), "before VoiceOver has been on the pad, nothing says it is off it")
        _ = spot.focus(now: 0)
        check(!spot.offPad(voiceOver: true), "on the pad")
        _ = spot.lostFocus(now: 10, mode: "menu", pauseOnLeave: true)
        check(spot.offPad(voiceOver: true) && !spot.offPad(voiceOver: false), "off the pad (for the strip): the kit's voice stays held")
        check(ArcadePadHold.isVoiceOverTap(sinceActivateMs: 40, fingers: 1, offset: 0.5)
              && !ArcadePadHold.isVoiceOverTap(sinceActivateMs: 200, fingers: 1, offset: 0)
              && !ArcadePadHold.isVoiceOverTap(sinceActivateMs: 40, fingers: 1, offset: 30)
              && !ArcadePadHold.isVoiceOverTap(sinceActivateMs: 40, fingers: 2, offset: 0)
              && !ArcadePadHold.isVoiceOverTap(sinceActivateMs: nil, fingers: 1, offset: 0),
              "VoiceOver's own tap after its activate: one finger at the pad's middle within 150 ms, and nothing else")
        var activated = ArcadePadHold()
        check(activated.activate(now: 0) == [.risingChime, .takenBuzz, .holdSpeech(false), .say("Pad on.", cls: "answer")]
              && activated.activates == 1, "VoiceOver's activate takes the pad")
        _ = activated.lostFocus(now: 100, mode: "menu", pauseOnLeave: true)
        check(activated.activate(now: 5000).contains(.say(ArcadeTouchLines.directTouchOff, cls: "answer")),
              "two activates in 10 s with no touch between: direct touch looks off")
        _ = activated.lostFocus(now: 5100, mode: "menu", pauseOnLeave: true)
        check(!activated.activate(now: 6000).contains(.say(ArcadeTouchLines.directTouchOff, cls: "answer")), "said once")
        var touched = ArcadePadHold()
        _ = touched.activate(now: 0)
        _ = touched.touch(now: 100, voiceOver: true)
        _ = touched.lostFocus(now: 200, mode: "menu", pauseOnLeave: true)
        check(!touched.activate(now: 3000).contains(.say(ArcadeTouchLines.directTouchOff, cls: "answer")), "a touch between: direct touch works")

        check(ArcadeWatchdog.shouldWarn(mode: "fight", lastTouch: nil, now: 9000, warnedThisFight: false)
              && ArcadeWatchdog.shouldWarn(mode: "fight", lastTouch: 1000, now: 6000, warnedThisFight: false)
              && !ArcadeWatchdog.shouldWarn(mode: "fight", lastTouch: 1001, now: 6000, warnedThisFight: false)
              && !ArcadeWatchdog.shouldWarn(mode: "fight", lastTouch: nil, now: 9000, warnedThisFight: true)
              && !ArcadeWatchdog.shouldWarn(mode: "demo", lastTouch: nil, now: 9000, warnedThisFight: false),
              "the watchdog: no pad touch in 5 s of a live fight, once per fight, never in a demo")
    }

    static func touchWords() {
        let split = ArcadeGestureWords.split("doubleTap2")
        check(split.kind == "doubleTap" && split.fingers == 2 && ArcadeGestureWords.split("hold1").kind == "hold"
              && ArcadeGestureWords.split("release").kind == "release", "keys and fingers")
        func sayBacks(_ mode: String, _ steps: [[String: Any]], tier: String = "easy") -> [String] {
            run(mode, steps, tier: tier).reports.map { ArcadeGestureWords.sayBack($0) }
        }
        check(sayBacks("fight", [step(up: 150)]) == ["Tap: weak punch."], "Tap: weak punch.")
        check(sayBacks("fight", [step(path: [[100, 0, -40]], up: 150)]) == ["Flick up: strong punch."], "Flick up: strong punch.")
        check(sayBacks("fight", [step(path: [[700, 0, 0], [850, 50, 0]], up: 870)])
              == ["Rest: block.", "Lift: block off.", "From a block, flick right: strong kick."], "Rest, Lift, and a flick out of it")
        check(sayBacks("menu", [step(up: 100), step(at: 480, up: 100)]) == ["Double-tap: choose."], "Double-tap: choose.")
        check(sayBacks("menu", [step(fingers: 2, path: [[225, 30, 0], [450, 0, 0], [675, 30, 0], [900, 0, 0]], up: 920)])
              == ["Two-finger scrub: back."], "Two-finger scrub: back.")
        check(sayBacks("menu", [step(up: 1100)]) == ["Hold: repeat."], "a menu hold is a hold, not a rest")
        check(ArcadeGestureWords.action(.pulse(ArcadePadState(buttons: ["CR"])), say: nil) == "C right"
              && ArcadeGestureWords.action(.info("status"), say: nil) == "how you're doing"
              && ArcadeGestureWords.action(.pulse(ArcadePadState(sx: -1)), say: nil) == "left", "words for a table with no 'say'")

        let sections = ArcadeHowToPlay.sections(table: .standard, plainHelp: nil)
        check(sections.map { $0.title } == ["Menus", "Fights, Easy controls"], "How to play: menus, then the Easy fight")
        check(sections[0].rows.contains("Two-finger scrub: back.") && sections[0].rows.contains("Tap: hear it.")
              && sections[0].rows.contains("Flick right: next.") && sections[0].rows.contains("Two-finger double-tap: start."),
              "the menu rows from the table's words")
        check(sections[1].rows.contains("Tap: weak punch.") && sections[1].rows.contains("Rest: block.")
              && sections[1].rows.contains("From a block, flick to hit back.") && sections[1].rows.contains("Two-finger flick down: how you're doing."),
              "the Easy rows")
        let full = ArcadeHowToPlay.sections(table: ArcadeTouchTable.standard.onTier("full"), plainHelp: nil)
        check(full.map { $0.title } == ["Menus", "Fights, Full controls, left half", "Fights, Full controls, right half", "Fights, Full controls, anywhere"]
              && full[1].rows.contains("Slide a finger: walk.") && full[2].rows.contains("Tap: jump.")
              && full[3].rows.contains("Three-finger hold: help."), "Full: the halves and anywhere")
        let plain = ArcadeHowToPlay.sections(table: ArcadeTouchTable(), plainHelp: "The left half is the control pad.")
        check(plain.first?.title == "The game's own help" && plain.first?.rows == ["The left half is the control pad."], "the plain player's own help leads")
        check(ArcadeHowToPlay.zoneWords("a") == "the A area" && ArcadeHowToPlay.zoneWords("pad") == "the whole pad", "zone names")
    }

    static func touchPractice() {
        let lessons = ArcadePadPractice.makeLessons(table: .standard, voiceOver: true)
        check(lessons.map { $0.title } == ["the pad", "menus", "fighting"] && lessons.map { $0.steps.count } == [3, 7, 10],
              "three lessons: the pad, menus (7 gestures), fighting (10)")
        check(lessons[1].steps.map { $0.line } == ArcadePadPractice.menuLines.map { $0.line }, "the plan's menu lines")
        check(lessons[2].steps.map { $0.line }.prefix(3) == ["Tap anywhere: an attack.", "Flick up: strong punch.", "Flick right: strong kick."]
              && lessons[2].steps[5].line == "Rest a finger still: block. Lift to stop."
              && lessons[2].steps[6].want == ArcadePracticeStep.Want.gesture(key: "flick1", direction: nil, fromHold: true),
              "the fight lines from the table's words")
        check(ArcadePadPractice.makeLessons(table: .standard, voiceOver: false).first?.intro == "Lesson 1, menus.",
              "with VoiceOver off there is no pad lesson")
        check(ArcadePadPractice.makeLessons(table: v1Table, voiceOver: false)[0].steps.first?.line == "Flick right for the next item.",
              "an older table keeps the lines its gestures share")
        check(ArcadePadPractice.makeLessons(table: v1Table, voiceOver: false)[0].steps.contains { $0.line == "Two-finger tap: B." },
              "and says its own words where they differ")

        var practice = ArcadePadPractice(lessons: lessons, endLine: ArcadePadPractice.practiceModeLine)
        func feed(_ mode: String, _ steps: [[String: Any]]) -> [String] {
            var lines: [String] = []
            for output in run(mode, steps).raw { lines += practice.handle(output) }
            return lines
        }
        check(practice.startLines() == [ArcadePadPractice.opening, "Lesson 1, the pad.", lessons[0].steps[0].line], "the opening")
        check(feed("menu", [step(up: 100)]).isEmpty, "a touch in Lesson 1 is not said back: only the pad moves its steps")
        check(practice.padHeld() == ["Good.", lessons[0].steps[1].line], "the pad taken")
        check(feed("menu", [step(up: 100)]).isEmpty, "the touch that took the pad is not an attempt (its say-back would cut the step)")
        check(practice.padHeld().isEmpty, "taking it again is not the step")
        check(practice.padReleased() == ["Good.", lessons[0].steps[2].line], "VoiceOver back")
        check(lessons[0].steps[2].line.hasPrefix("Touch the pad below the buttons, then double-tap"),
              "VoiceOver is on a strip button then: she touches the pad before the double-tap")
        check(practice.padHeld() == ["Good.", "Lesson done.", "Lesson 2, menus.", "Flick right for the next item."] && practice.mode == "menu",
              "Lesson 1 done")
        check(feed("menu", [step(up: 100)]).isEmpty, "the touch once after taking the pad does not cut Lesson 2's first line")
        let right = [step(path: [[60, 30, 0]], up: 80)]
        check(feed("menu", right) == ["Flick right: next."], "every attempt is said back")
        check(feed("menu", right) == ["Flick right: next.", "Good.", "Flick left for the one before."], "two clean in a row pass")
        check(feed("menu", right) == ["Flick right: next.", "That flick went right. Flick left for previous."], "the wrong way, corrected")
        check(feed("menu", [step(path: [[80, 25, 0]], up: 100)]) == ["Your finger moved, but not far enough for a flick. Flick farther."],
              "a dud gets its reason")
        check(practice.taps.isEmpty, "no taps measured while flicks were wanted")
        check(practice.nextLesson() == ["Next: fighting.", lessons[2].intro, "Tap anywhere: an attack."] && practice.mode == "fight",
              "Next lesson skips")
        check(feed("fight", [step(up: 700)]) == ["Rest: block.", "That was a rest, so it blocked. Lift sooner for an attack.", "Lift: block off."],
              "a rest when a tap was wanted")
        check(feed("fight", [step(fingers: 2, up: 100)]) == ["Two-finger tap: quiet.", "That was two fingers. Use one."],
              "two fingers when one was wanted")
        _ = feed("fight", [step(up: 150)])
        check(practice.taps.count == 1 && practice.drifts.count == 1, "her one-finger taps are measured while a tap is wanted")
        check(!practice.keepsFit && practice.nextLesson() == [ArcadePadPractice.doneLine, ArcadePadPractice.practiceModeLine]
              && practice.finished && practice.current == nil && practice.repeatLines() == [ArcadePadPractice.doneLine],
              "too few taps to fit: plain Done, never 'tuned', then the pointer to the game's own practice")

        // A slow double-tap: said back and corrected once (not by its late second tap too), and the
        // gap measured as the recognizer judges it, from the first lift to the second landing.
        let choose = ArcadePracticeStep(line: "Double-tap to choose.", want: .gesture(key: "doubleTap1", direction: nil, fromHold: false),
                                        mode: "menu", say: "choose")
        var twice = ArcadePadPractice(lessons: [ArcadePracticeLesson(title: "menus", intro: "Menus.", steps: [choose])])
        func feedTwice(_ steps: [[String: Any]]) -> [String] {
            var lines: [String] = []
            for output in run("menu", steps).raw { lines += twice.handle(output) }
            return lines
        }
        check(feedTwice([step(up: 100), step(at: 600, up: 100)]) == ["Tap: hear it.", "The second tap came late. Tap twice, a little quicker."],
              "a slow double-tap: one say-back and one correction")
        check(twice.gaps == [500], "the gap from the first lift (100 ms) to the second landing (600 ms)")
        check(feedTwice([step(up: 100), step(at: 350, up: 100)]) == ["Double-tap: choose."] && twice.gaps == [500, 250],
              "a double-tap in time, and its 250 ms gap")
        _ = feedTwice([step(up: 120)])
        check(twice.taps.count == 5 && twice.keepsFit && twice.nextLesson() == [ArcadePadPractice.finishedLine],
              "enough taps measured: the end says the pad is tuned to her touch")

        let kickStep: [String: Any] = ["key": "flick1", "dir": "right", "mode": "fight", "line": "Flick right.", "say": "kick"]
        let kicks: [String: Any] = ["title": "kicks", "intro": "Kicks.", "steps": [kickStep]]
        let custom: [String: Any] = ["lessons": [kicks], "end": "Done."]
        let made = ArcadePadPractice.makeLessons(json: custom, voiceOver: true)
        check(made?.lessons.map { $0.title } == ["the pad", "kicks"] && made?.end == "Done."
              && made?.lessons.last?.steps.first?.want == ArcadePracticeStep.Want.gesture(key: "flick1", direction: .right, fromHold: false),
              "the pack's own practice table, after the app's pad lesson")
        let noLessons: [String: Any] = ["lessons": [Any]()]
        check(ArcadePadPractice.makeLessons(json: nil, voiceOver: true) == nil
              && ArcadePadPractice.makeLessons(json: noLessons, voiceOver: true) == nil, "none, or nothing usable: the app's own lessons")

        let rising = ArcadeChime.wav(rising: true)
        let falling = ArcadeChime.wav(rising: false)
        check(rising.count == 44 + 2646 * 2 && String(decoding: rising.prefix(4), as: UTF8.self) == "RIFF"
              && String(decoding: rising[8..<12], as: UTF8.self) == "WAVE" && rising != falling && rising.dropFirst(44).contains { $0 != 0 },
              "the chimes: 120 ms of 16-bit mono at 22,050 Hz, rising and falling")
    }

    static func touchBridgeAndReport() {
        check(ArcadeJS.say("Pad on.", cls: "answer").contains(#"k.say("Pad on.", { cls: "answer" }); return true;"#)
              && ArcadeJS.say("x", cls: "screen").contains("if (!k || !k.say) { return false; }"), "the app's line into the kit's queue")
        check(ArcadeJS.spoken(id: "12", ok: true) == "window.revivalKit&&window.revivalKit.spoken&&window.revivalKit.spoken(12,true);void 0"
              && ArcadeJS.spoken(id: "n-3", ok: false).contains(#"spoken("n-3",false)"#) && ArcadeJS.idLiteral("007") == #""007""#,
              "an item's id goes back as it came")
        check(ArcadeJS.holdSpeech(true).contains("holdSpeech(true)") && ArcadeJS.speechGo.contains("speechGo()")
              && ArcadeJS.hasSpeechQueue.contains("window.revivalKit.spoken"), "hold, go and the queue check")
        check(ArcadeJS.holdSpeech(true).contains("else { window.__arcadeHold = true; }")
              && ArcadeJS.holdSpeech(false).contains("k.holdSpeech(false)"),
              "a hold sent before the kit is there is kept for it")
        let script = ArcadeJS.hostScript(base: "b", emulatorData: "d", settings: [:])
        check(script.contains("speechGate: true,") && script.contains("id: (o && o.id != null) ? String(o.id) : null")
              && script.contains("cls: (o && o.cls) ? String(o.cls) : null") && script.contains("detail.route === 'native'"),
              "the host script gates the kit's voice and carries each native line's id and class")
        check(script.contains("window.__arcadeHold = null; }") && script.contains("held();")
              && ArcadeJS.hostScript(base: "b", emulatorData: "d", settings: [:], holdSpeech: true).contains("window.__arcadeHold = true; }"),
              "the kit's voice held from its first event while the offer or Pad practice is up")
        check(script.contains("if (name === 'say' && detail && detail.cls === 'answer') { post({ t: 'event', name: 'cut', detail: null }); }"),
              "every answer the kit queues is a cut of the line being said, sent as 'cut'")
        check(ArcadeKitSettings.calls("alerts") == "alerts", "the kit's 'alerts' calls")
        check(ArcadeSpeakerWarnings.buzzAndWords.calls == "alerts" && ArcadeSpeakerWarnings.buzzOnly.calls == "off"
              && ArcadeSpeakerWarnings.everyCall.calls == "all" && ArcadeSpeakerWarnings.off.calls == "off"
              && ArcadeSpeakerWarnings.buzzOnly.buzz && !ArcadeSpeakerWarnings.off.buzz, "Warnings on the phone speaker")

        let none = ArcadeTouchChoices(settings: nil)
        check(none == ArcadeTouchChoices() && none.fightControls == "easy" && none.walkIn && none.skipDemo == nil && none.lessDamage == nil
              && none.lessDamageShown && none.skipDemoShown(touch: true) && !none.skipDemoShown(touch: false),
              "the touch defaults: Easy, walk in, less damage in Easy, and the demo skipped for touch input only")
        let chosen = ArcadeTouchChoices(settings: ["fightControls": "full", "walkIn": false, "lessDamage": false, "skipDemo": false])
        check(chosen.fightControls == "full" && !chosen.walkIn && chosen.skipDemo == false && !chosen.skipDemoShown(touch: true)
              && !chosen.lessDamageShown, "her own choices")
        check(ArcadeTouchChoices(settings: ["fightControls": "hard"]).fightControls == "easy", "an unknown tier is Easy")
        check(ArcadeTouchChoices(settings: ["fightControls": "full"]).lessDamageShown == false, "less damage is on by default only in Easy")
        var kept: [String: Any] = ["fightControls": "full", "walkIn": false]
        ArcadeTouchChoices.fillDefaults(&kept, pauseOnLeave: false, touch: true)
        check((kept["fightControls"] as? String) == "full" && (kept["walkIn"] as? Bool) == false && (kept["skipDemo"] as? Bool) == true
              && (kept["pauseOnLeave"] as? Bool) == false, "defaults fill only what she has not chosen")
        var keys: [String: Any] = [:]
        ArcadeTouchChoices.fillDefaults(&keys, pauseOnLeave: true, touch: false)
        check((keys["fightControls"] as? String) == "easy" && (keys["walkIn"] as? Bool) == true && keys["skipDemo"] == nil
              && keys["pauseOnLeave"] == nil, "a keyboard or controller player keeps the demo fight: no touch-only defaults")

        var telemetry = ArcadeTelemetry()
        telemetry.openedAt = Date(timeIntervalSince1970: 0)
        telemetry.touch.note(pad: true, seconds: 3.5, how: "first touch")
        telemetry.touch.watchdogFires = 1
        telemetry.touch.activates = 2
        for output in run("fight", [step(up: 150)]).raw + run("menu", [step(path: [[80, 25, 0]], up: 100)]).raw {
            switch output {
            case .gesture(let report): telemetry.touch.note(gesture: report, seconds: 4, held: true, tier: "easy")
            case .dud(let dud): telemetry.touch.note(dud: dud, seconds: 5, held: true, tier: "easy")
            default: break
            }
        }
        let spoken: [String: Any] = ["t": 1200, "text": "Pad on.", "cls": "answer", "route": "native", "start": true]
        let mode: [String: Any] = ["t": 1300, "k": "mode", "mode": "fight", "screen": "fight"]
        telemetry.note(event: "telemetry", detail: ["fps": 60, "trace": [spoken]])
        telemetry.note(event: "telemetry", detail: ["fps": 59, "trace": [mode]])
        telemetry.note(error: "a page error")
        let report = telemetry.report(now: Date(timeIntervalSince1970: 60))
        check(report.contains("Pad: taken 1, let go 0. VoiceOver's activate on the pad: 2. Pad isn't held lines: 1.")
              && report.contains("Pad times: on 3.50 s (first touch).") && report.contains("Gestures: tap1 1."),
              "the pad's summary")
        check(report.contains("Gesture trace (the last 2):") && report.contains("tap1: weak punch")
              && report.contains("Kit trace, speech and events (the last 2):")
              && report.contains("cls=answer route=native start=true t=1200 text=Pad on.") && report.contains("k=mode mode=fight screen=fight t=1300"),
              "the gesture trace, and the kit's trace gathered tick by tick")
        if let summary = report.range(of: "Pad: taken"), let errors = report.range(of: "Last errors:"), let trace = report.range(of: "Gesture trace") {
            check(summary.lowerBound < errors.lowerBound && errors.lowerBound < trace.lowerBound,
                  "the summary leads and the traces go last, so a report cut to size keeps the summary")
        } else {
            check(false, "the report has the summary, the errors and the traces")
        }
    }
}
