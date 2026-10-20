import Foundation

// Touch play (Oct 20 2026): the game pad's v2 recognizer (the Easy fight
// tier, VoiceOver-style menus, the scrub, flicks out of a block, duds with
// their reasons, her touch timing), the haptics for every gesture, the one
// speech queue, the pad's held state and words, the watchdog, How to play,
// Pad practice, the chimes and the touch trace. Compiled with the Arcade's
// other checks by run-arcade-tests.sh.

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

    /// The Oct 18 recognizer's outputs: the v1 table, no reports.
    static func legacyPad() -> ArcadeTouchRecognizer {
        var pad = ArcadeTouchRecognizer(table: v1Table)
        pad.reports = false
        return pad
    }

    /// A table's plain outputs (the plain player's checks), no reports.
    static func plainPad(_ table: ArcadeTouchTable) -> ArcadeTouchRecognizer {
        var pad = ArcadeTouchRecognizer(table: table)
        pad.reports = false
        return pad
    }

    static func near(_ a: Double, _ b: Double, _ give: Double = 0.001) -> Bool { abs(a - b) <= give }

    /// What a run did, in words: a pulse by its buttons ("CL") or its step
    /// ("right"), a held hold on and off ("block on", "block off"), an info key ("info here").
    static func acts(_ outputs: [ArcadeTouchOutput]) -> [String] {
        var words: [String] = []
        var held: [String: String] = [:]
        for output in outputs {
            switch output {
            case .pad(let source, let state):
                if source.hasPrefix("touch-p"), Int(source.dropFirst(7)) != nil {
                    guard let state else { continue }
                    words.append(state.buttons.isEmpty ? ArcadeGestureWords.stateWords(state) : state.buttons.joined(separator: "+"))
                } else if source.hasPrefix("touch-hold") {
                    if let state {
                        let name = state.buttons.joined(separator: "+")
                        held[source] = name
                        words.append(name + " on")
                    } else {
                        words.append((held[source] ?? "hold") + " off")
                    }
                }
            case .info(let what):
                words.append("info " + what)
            default:
                break
            }
        }
        return words
    }

    static func gestureReports(_ outputs: [ArcadeTouchOutput]) -> [ArcadeGestureReport] {
        outputs.compactMap { (output: ArcadeTouchOutput) -> ArcadeGestureReport? in
            if case .gesture(let report) = output { return report }
            return nil
        }
    }

    static func dudReasons(_ outputs: [ArcadeTouchOutput]) -> [ArcadeDudReason] {
        outputs.compactMap { (output: ArcadeTouchOutput) -> ArcadeDudReason? in
            if case .dud(let dud) = output { return dud.reason }
            return nil
        }
    }

    // MARK: Shared touch vectors

    /// One finger: down at (x, y) at t0, a straight slide of (dx, dy) from
    /// `from` over `over` ms, sampled every 16 ms, up at `up`.
    static func finger(_ id: Int = 1, x: Double = 200, y: Double = 400, t0: Double = 0, dx: Double = 0, dy: Double = 0,
                       from: Double? = nil, over: Double = 0, up: Double) -> [[Any]] {
        let start = from ?? t0
        func at(_ time: Double) -> (Double, Double) {
            guard dx != 0 || dy != 0 else { return (x, y) }
            let p = over <= 0 ? (time >= start ? 1.0 : 0.0) : min(1, max(0, (time - start) / over))
            return (x + dx * p, y + dy * p)
        }
        var events: [[Any]] = [[t0, "down", id, x, y]]
        var t = t0 + 16
        while t < up {
            let point = at(t)
            events.append([t, "move", id, point.0, point.1])
            t += 16
        }
        let last = at(up)
        events.append([up, "up", id, last.0, last.1])
        return events
    }

    /// One finger along a path of (t, dx, dy) points, sampled every 16 ms, up at the last point.
    static func path(_ id: Int, x: Double, y: Double, _ points: [(Double, Double, Double)]) -> [[Any]] {
        guard let first = points.first, let last = points.last else { return [] }
        func at(_ time: Double) -> (Double, Double) {
            for index in 1..<points.count where time <= points[index].0 {
                let a = points[index - 1]
                let b = points[index]
                let p = b.0 > a.0 ? (time - a.0) / (b.0 - a.0) : 1
                return (x + a.1 + (b.1 - a.1) * p, y + a.2 + (b.2 - a.2) * p)
            }
            return (x + last.1, y + last.2)
        }
        var events: [[Any]] = [[first.0, "down", id, x + first.1, y + first.2]]
        var t = first.0 + 16
        while t < last.0 {
            let point = at(t)
            events.append([t, "move", id, point.0, point.1])
            t += 16
        }
        events.append([last.0, "up", id, x + last.1, y + last.2])
        return events
    }

    /// A shared vector in the shape assumed for the kit's core/test/touch_vectors.json:
    /// {mode, tier, width, height, events: [[t, "down"|"move"|"up", id, x, y]], until, expect}.
    static func vector(_ mode: String, _ events: [[Any]], until: Double, tier: String = "easy", expect: [String] = []) -> [String: Any] {
        let sorted = events.sorted { (arcadeJSONNumber($0[0]) ?? 0) < (arcadeJSONNumber($1[0]) ?? 0) }
        return ["mode": mode, "tier": tier, "width": 400, "height": 800, "events": sorted, "until": until, "expect": expect]
    }

    /// Runs a vector: before each event the clock advances to just short of
    /// it (a touch at the same moment as a timer goes first), and to `until` at the end.
    static func runVector(_ vector: [String: Any], table: ArcadeTouchTable = .standard, fit: ArcadeTouchFit? = nil) -> [ArcadeTouchOutput] {
        var pad = ArcadeTouchRecognizer(table: table.onTier((vector["tier"] as? String) ?? "easy"))
        pad.mode = (vector["mode"] as? String) ?? "menu"
        pad.fit = fit
        let width = arcadeJSONNumber(vector["width"]) ?? 400
        let height = arcadeJSONNumber(vector["height"]) ?? 800
        var out: [ArcadeTouchOutput] = []
        for case let event as [Any] in (vector["events"] as? [Any]) ?? [] {
            guard event.count >= 5, let t = arcadeJSONNumber(event[0]), let kind = event[1] as? String,
                  let number = arcadeJSONNumber(event[2]), let x = arcadeJSONNumber(event[3]), let y = arcadeJSONNumber(event[4]) else { continue }
            let id = Int(number)
            out += pad.advance(to: t - 0.001)
            switch kind {
            case "down":
                out += pad.start(id: id, x: x, y: y, width: width, height: height, now: t)
            case "move":
                out += pad.move(id: id, x: x, y: y, now: t)
            case "up":
                out += pad.move(id: id, x: x, y: y, now: t)
                out += pad.end(id: id, now: t)
            default:
                break
            }
        }
        out += pad.advance(to: arcadeJSONNumber(vector["until"]) ?? 5000)
        return out
    }

    /// The first-timer set (the plan's FT1-FT14), Easy fight controls on the standard table.
    static func firstTimerVectors() -> [(name: String, vector: [String: Any])] {
        var set: [(name: String, vector: [String: Any])] = []
        func add(_ name: String, _ events: [[Any]], until: Double, _ expect: [String]) {
            set.append((name, vector("fight", events, until: until, expect: expect)))
        }
        add("FT1 still 150 ms", finger(up: 150), until: 2000, ["CL"])
        add("FT2 still 420 ms, drift 10", finger(dx: 10, over: 420, up: 420), until: 2000, ["CL"])
        add("FT3 still 480 ms, drift 26", finger(dx: 18.4, dy: 18.4, over: 480, up: 480), until: 2000, ["CL"])
        add("FT4 a VoiceOver-style double-tap", finger(1, up: 120) + finger(2, t0: 370, up: 490), until: 2000, ["CL", "CL"])
        add("FT5 rest 300 ms, then 45 up", finger(dy: -45, from: 300, over: 200, up: 520), until: 2000, ["CU"])
        add("FT6 rest 700 ms", finger(up: 700), until: 2000, ["block on", "block off"])
        add("FT7 rest 700 ms, then 50 right", finger(dx: 50, from: 700, over: 100, up: 820), until: 2000, ["block on", "block off", "CR"])
        add("FT8 a slow flick, 35 right over 600 ms", finger(dx: 35, over: 600, up: 600), until: 2000, ["CR"])
        add("FT9 a 15 pt slide lifted at 200 ms", finger(dx: 15, over: 200, up: 200), until: 2000, ["CL"])
        add("FT10 two fingers 90 ms apart", finger(1, up: 200) + finger(2, x: 260, t0: 90, up: 200), until: 2000, ["info quiet"])
        add("FT11 two-finger double-tap", finger(1, up: 100) + finger(2, x: 260, up: 100)
                + finger(3, t0: 300, up: 450) + finger(4, x: 260, t0: 300, up: 450), until: 2000, ["START"])
        add("FT12 two fingers 40 down", finger(1, dy: 40, over: 150, up: 200) + finger(2, x: 260, dy: 40, over: 150, up: 200),
            until: 2000, ["info status"])
        add("FT13 two fingers still 1.1 s", finger(1, up: 1100) + finger(2, x: 260, up: 1100), until: 3000, ["info help"])
        add("FT14 three-finger tap", finger(1, up: 100) + finger(2, x: 260, t0: 5, up: 100) + finger(3, x: 320, t0: 10, up: 100),
            until: 2000, ["START"])
        return set
    }

    /// A seeded generator for the randomised sets.
    struct Seeded {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
    }

    // MARK: The checks

    static func touchPlay() throws {
        touchTablesV2()
        touchVectors()
        touchMenusV2()
        touchDuds()
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
              && table.repeatEveryMs == 300 && table.base.flickBreaksPx == 40, "the relaxed numbers")
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
              && full.gestures(mode: "fight", zone: .left).holds[2] == .info("help"),
              "Full: the two halves, status and where on the left, a flick out of the right-hand block, help on the two-finger hold")
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
        // The first-timer set: every attack gesture attacks or blocks, none does nothing.
        for (name, vector) in firstTimerVectors() {
            let got = acts(runVector(vector))
            check(got == (vector["expect"] as? [String] ?? []), name + ": " + got.joined(separator: ", "))
        }
        // The same vectors survive JSON (the kit's file is read the same way).
        if let data = try? JSONSerialization.data(withJSONObject: ["vectors": firstTimerVectors().map { $0.vector }]),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = parsed["vectors"] as? [Any] {
            var same = 0
            for case let vector as [String: Any] in list where acts(runVector(vector)) == (vector["expect"] as? [String] ?? []) { same += 1 }
            check(same == 14, "all 14 first-timer vectors pass after JSON")
        } else {
            check(false, "the vectors are JSON")
        }
        // The kit's own vectors, when its file is given (KIT_TOUCH_VECTORS=path/to/core/test/touch_vectors.json).
        if let path = ProcessInfo.processInfo.environment["KIT_TOUCH_VECTORS"], !path.isEmpty {
            let parsed = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let list = ((parsed as? [String: Any])?["vectors"] as? [Any]) ?? []
            check(!list.isEmpty, "the kit's touch vectors are read")
            for case let vector as [String: Any] in list {
                let got = acts(runVector(vector))
                check(got == (vector["expect"] as? [String] ?? []), "kit vector " + ((vector["name"] as? String) ?? "?") + ": " + got.joined(separator: ", "))
            }
        }
        // FT6 in detail: the block comes on at the rest (500 ms), with its report, and goes at the lift.
        let rest = runVector(vector("fight", finger(up: 700), until: 2000))
        let held = gestureReports(rest)
        check(held.map { $0.key } == ["hold1", "release1"] && held[0].ms >= 500 && held[0].ms < 520 && held[0].say == "block",
              "the rest blocks at 500 ms and the lift lets it go")
        // FT10 in detail: the two-finger tap waits for a second one (400 ms), then is quiet.
        check(acts(runVector(vector("fight", finger(1, up: 200) + finger(2, x: 260, t0: 90, up: 200), until: 599))).isEmpty
              && acts(runVector(vector("fight", finger(1, up: 200) + finger(2, x: 260, t0: 90, up: 200), until: 600))) == ["info quiet"],
              "quiet 400 ms after the lift, not before")
        // FT7 in detail: the flick out of the block is reported as one.
        let out = gestureReports(runVector(vector("fight", finger(dx: 50, from: 700, over: 100, up: 820), until: 2000)))
        check(out.map { $0.key } == ["hold1", "release1", "flick1"] && out[2].fromHold && out[2].direction == .right
              && out[2].say == "strong kick", "a flick out of a block: the block lets go, then the strong kick")

        // Randomised Easy sets (seeded).
        var random = Seeded(state: 20_261_020)
        var taps = 0
        for index in 0..<1000 {
            let duration = random.range(80, 480)
            let drift = random.range(0, 27)
            let angle = random.range(0, 2 * Double.pi)
            let got = acts(runVector(vector("fight", finger(index, dx: drift * cos(angle), dy: drift * sin(angle), over: duration, up: duration),
                                            until: duration + 1000)))
            if got == ["CL"] { taps += 1 }
        }
        check(taps == 1000, "1,000 still touches of 80-480 ms with up to 27 pt of drift: all weak punches (\(taps))")
        var flicks = 0
        let attacks: [ArcadeDirection: String] = [.left: "CL", .up: "CU", .down: "CD", .right: "CR"]
        for index in 0..<1000 {
            let travel = random.range(28, 120)
            // The flick reaches 28 pt before the 500 ms rest (the plan's "before the rest fires").
            let duration = random.range(80, min(1200, 470 * travel / 28))
            let direction = ArcadeDirection.allCases[Int(random.next() * 4) % 4]
            let side = random.range(-0.3, 0.3) * travel
            var dx = side
            var dy = side
            switch direction {
            case .left: dx = -travel
            case .right: dx = travel
            case .up: dy = -travel
            case .down: dy = travel
            }
            if acts(runVector(vector("fight", finger(index, dx: dx, dy: dy, over: duration, up: duration), until: duration + 1000)))
                == [attacks[direction] ?? ""] { flicks += 1 }
        }
        check(flicks == 1000, "1,000 flicks of 28-120 pt that travel 28 pt before the rest: the right attack every time (\(flicks))")
        var rests = 0
        for index in 0..<200 {
            let duration = random.range(520, 1500)
            if acts(runVector(vector("fight", finger(index, up: duration), until: duration + 1000))) == ["block on", "block off"] { rests += 1 }
        }
        check(rests == 200, "200 rests of 520-1500 ms: a block, let go at the lift (\(rests))")
        // A slide that is still within 28 pt when the rest fires blocks (by design: a flick fires "before the rest").
        check(acts(runVector(vector("fight", finger(dx: 30, over: 1200, up: 1200), until: 3000))) == ["block on", "block off"],
              "28 pt reached only after the rest: a block, not a kick")
    }

    static func touchMenusV2() {
        check(acts(runVector(vector("menu", finger(dx: 30, over: 100, up: 150), until: 2000))) == ["right"], "flick right 30 pt: one step")
        check(acts(runVector(vector("menu", finger(1, up: 100) + finger(2, t0: 300, up: 480), until: 2000))) == ["A"],
              "two taps 380 ms apart: choose")
        let here = vector("menu", finger(up: 420), until: 819)
        check(acts(runVector(here)).isEmpty && acts(runVector(vector("menu", finger(up: 420), until: 820))) == ["info here"],
              "a 420 ms still tap: hear it, 400 ms after the lift")
        let scrubPoints: [(Double, Double, Double)] = [(0, 0, 0), (150, 30, 0), (300, 0, 0), (450, 30, 0), (600, 0, 0), (750, 30, 0), (900, 0, 0)]
        let scrub = runVector(vector("menu", path(1, x: 150, y: 400, scrubPoints) + path(2, x: 210, y: 400, scrubPoints), until: 2500))
        check(acts(scrub) == ["B"] && gestureReports(scrub).map { $0.key } == ["scrub2"], "a two-finger scrub is Back, and never a two-finger flick")
        check(acts(runVector(vector("menu", finger(1, up: 100) + finger(2, x: 260, up: 100), until: 2000))) == ["info quiet"],
              "a two-finger tap is quiet")
        check(acts(runVector(vector("menu", finger(1, up: 100) + finger(2, x: 260, up: 100)
                                       + finger(3, t0: 250, up: 350) + finger(4, x: 260, t0: 250, up: 350), until: 2000))) == ["START"],
              "a two-finger double-tap is Start")
        check(acts(runVector(vector("menu", finger(1, dy: 40, over: 120, up: 150) + finger(2, x: 260, dy: 40, over: 120, up: 150),
                                    until: 2000))) == ["info nextLine"], "two fingers flicked down: the screen's next line")
        check(acts(runVector(vector("menu", finger(up: 1100), until: 2500))) == ["info repeat"], "one finger still a second: repeat")
        // A finger kept down after a flick steps again after a second, then every 300 ms.
        let repeated = runVector(vector("menu", finger(dx: 30, over: 60, up: 1700), until: 2500))
        check(acts(repeated) == ["right", "right", "right", "right"]
              && gestureReports(repeated).map { $0.repeatStep } == [false, true, true, true], "a held flick repeats, each step reported")
        check(acts(runVector(vector("menu", finger(1, up: 100) + finger(2, x: 260, up: 100) + finger(3, x: 320, up: 100), until: 2000)))
              == ["START"], "three fingers: Start (untaught)")
    }

    static func touchDuds() {
        let short = runVector(vector("menu", finger(dx: 25, over: 100, up: 200), until: 2000))
        check(acts(short).isEmpty && dudReasons(short) == [.shortFlick], "25 pt is between the slop and a flick: a short flick")
        check(ArcadeFeel.dud == [ArcadeBuzz(style: .warning)], "every dud gets the warning buzz")
        check(dudReasons(runVector(vector("menu", finger(up: 700), until: 2000))) == [.slowTap], "still 700 ms in a menu: too slow for a tap")
        let apart = runVector(vector("menu", finger(1, up: 900) + finger(2, x: 260, t0: 300, up: 900), until: 2000))
        check(acts(apart).isEmpty && dudReasons(apart) == [.apart], "two fingers landing 300 ms apart that did nothing: apart")
        let drift = runVector(vector("fight", finger(1, dx: 40, over: 100, up: 150) + finger(2, x: 260, dx: 40, over: 100, up: 150)
                                         + finger(3, x: 320, dx: 40, over: 100, up: 150), until: 2000))
        check(dudReasons(drift) == [.drift], "three fingers moving in Easy (no three-finger flick): drift")
        let late = runVector(vector("menu", finger(1, up: 100) + finger(2, t0: 550, up: 700), until: 2000))
        check(acts(late) == ["info here", "info here"] && dudReasons(late) == [.lateDouble], "a second tap 600 ms after the first: late")
        let sideways = runVector(vector("menu", finger(1, dx: -40, over: 100, up: 150) + finger(2, x: 260, dx: -40, over: 100, up: 150),
                                        until: 2000))
        check(acts(sideways).isEmpty && dudReasons(sideways) == [.noAction], "two fingers flicked left in a menu: nothing there")
        var older = ArcadeTouchRecognizer(table: v1Table)
        _ = older.start(id: 1, x: 50, y: 50, width: 400, now: 0)
        _ = older.end(id: 1, now: 50)
        check(dudReasons(older.advance(to: 1000)) == [.noAction], "a lone tap where only a double-tap works: nothing there")
        // Every lift is measured.
        let lifts = runVector(vector("menu", finger(dx: 10, over: 100, up: 300), until: 2000)).compactMap { (output: ArcadeTouchOutput) -> ArcadeLiftReport? in
            if case .lifted(let lift) = output { return lift }
            return nil
        }
        check(lifts.count == 1 && lifts[0].ms == 300 && lifts[0].far == 10 && !lifts[0].fired && lifts[0].fingers == 1,
              "the lift's measurements: 300 ms, 10 pt, nothing fired")
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
        check(acts(runVector(vector("fight", finger(up: 300), until: 2000), fit: .quick)) == ["block on", "block off"],
              "with Quick, a 300 ms rest blocks")
        check(acts(runVector(vector("menu", finger(up: 1100), until: 2500), fit: .quick)) == ["info repeat"],
              "an info hold keeps its own second")
        let slow = ArcadeTouchFit(tapMs: 600, doubleMs: 500, slopPx: 26, flickPx: 32, restMs: 700)
        check(acts(runVector(vector("fight", finger(up: 600), until: 2000), fit: slow)) == ["CL"]
              && acts(runVector(vector("fight", finger(up: 800), until: 2000), fit: slow)) == ["block on", "block off"],
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
        func feels(_ mode: String, _ events: [[Any]], until: Double = 2500, tier: String = "easy") -> [[ArcadeBuzz]] {
            gestureReports(runVector(vector(mode, events, until: until, tier: tier))).map { ArcadeFeel.of($0) }
        }
        let tick = [ArcadeBuzz(style: .selection)]
        let light = [ArcadeBuzz(style: .light)]
        let medium = [ArcadeBuzz(style: .medium)]
        let heavy = [ArcadeBuzz(style: .heavy)]
        let rigid = [ArcadeBuzz(style: .rigid)]
        let soft = [ArcadeBuzz(style: .soft)]
        let twoLight = [ArcadeBuzz(style: .light), ArcadeBuzz(style: .light, afterMs: 60)]
        check(feels("menu", finger(dx: 30, over: 100, up: 150)) == [tick], "a menu step: a selection tick")
        check(feels("menu", finger(up: 100)) == [tick], "hear it: a tick")
        check(feels("menu", finger(1, up: 100) + finger(2, t0: 300, up: 480)) == [medium], "choose: medium")
        let scrubPoints: [(Double, Double, Double)] = [(0, 0, 0), (150, 30, 0), (300, 0, 0), (450, 30, 0), (600, 0, 0)]
        check(feels("menu", path(1, x: 150, y: 400, scrubPoints) + path(2, x: 210, y: 400, scrubPoints)) == [twoLight],
              "back: two light 60 ms apart")
        check(feels("menu", finger(1, up: 100) + finger(2, x: 260, up: 100)) == [soft], "quiet: soft")
        check(feels("menu", finger(1, up: 100) + finger(2, x: 260, up: 100) + finger(3, t0: 250, up: 350)
                        + finger(4, x: 260, t0: 250, up: 350)) == [rigid], "Start: rigid")
        check(feels("menu", finger(1, up: 1100) + finger(2, x: 260, up: 1100)) == [soft], "help: soft")
        check(feels("fight", finger(up: 150)) == [light], "the Easy tap attack: light")
        check(feels("fight", finger(dx: -40, over: 100, up: 150)) == [medium], "a weak punch flick: medium")
        check(feels("fight", finger(dy: -40, over: 100, up: 150)) == [heavy], "a strong punch flick: heavy")
        check(feels("fight", finger(up: 700)) == [rigid, soft], "block on: rigid; off: soft")
        check(feels("fight", finger(dx: 50, from: 700, over: 100, up: 820)) == [rigid, soft, heavy], "a strong kick out of a block: heavy")
        check(feels("fight", finger(1, dy: 40, over: 150, up: 200) + finger(2, x: 260, dy: 40, over: 150, up: 200)) == [tick],
              "status: a tick")
        check(feels("fight", finger(1, up: 100) + finger(2, x: 260, up: 100) + finger(3, x: 320, up: 100)) == [rigid], "pause: rigid")
        check(feels("fight", finger(x: 300, up: 100), tier: "full") == [medium] && feels("fight", finger(x: 50, up: 100), tier: "full") == [medium],
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
        check(queue.quiet() == [.stop] && queue.isIdle && queue.quiet().isEmpty, "quiet stops and clears everything")
        check(queue.add(own, now: 3100) == [.post(own)], "and the next line is said at once")
        var cut = ArcadeSpeechQueue()
        _ = cut.add(ArcadeSpeechItem(id: "7", text: "Your foe attacks.", cls: "alert"), now: 0)
        _ = cut.add(ArcadeSpeechItem(id: "8", text: "Round two.", cls: "flow"), now: 5)
        let hers = ArcadeSpeechItem(id: nil, text: "Playing.", cls: "answer", interrupts: true)
        check(cut.add(hers, now: 10) == [.ack(id: "7", ok: false), .ack(id: "8", ok: false), .stop, .post(hers)],
              "her own action cuts the line being said and drops what waits")
    }

    static func touchPadHeld() {
        check(ArcadePadWords.label == "Game pad" && ArcadePadWords.hint == "Double-tap to play.", "the pad's label and short hint")
        check(ArcadePadWords.value(mode: "menu") == "Menu" && ArcadePadWords.value(mode: "fight") == "Fight"
              && ArcadePadWords.value(mode: "pause") == "Paused" && ArcadePadWords.value(mode: "demo") == "Demo"
              && ArcadePadWords.value(mode: "other") == "Menu", "the pad's value from the kit's mode")
        var hold = ArcadePadHold()
        check(hold.focus(now: 0).isEmpty && hold.focused && !hold.held, "focus waits for the hold")
        check(hold.touch(now: 10, voiceOver: false).isEmpty && !hold.held, "with VoiceOver off there is nothing to take")
        check(hold.touch(now: 20, voiceOver: true) == [.risingChime, .takenBuzz, .holdSpeech(false), .say("Pad on.", cls: "answer")] && hold.held,
              "the first touch takes the pad: rising chime, buzz, the kit's voice back, Pad on.")
        check(hold.touch(now: 30, voiceOver: true).isEmpty, "touches while held change nothing")
        check(hold.lostFocus(now: 40, mode: "fight", pauseOnLeave: true) == [.fallingChime, .holdSpeech(true), .pauseGame]
              && !hold.held && hold.autoPaused, "VoiceOver back mid-fight: falling chime, the kit's voice held, the fight paused")
        check(hold.touch(now: 50, voiceOver: true) == [.risingChime, .takenBuzz, .holdSpeech(false),
                                                       .say("Paused. Two-finger double-tap to fight.", cls: "screen")],
              "taken again: Pad on. only once a session, and the paused line")
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
        check(split.kind == "doubleTap" && split.fingers == 2 && ArcadeGestureWords.split("hold1").kind == "hold", "keys and fingers")
        func sayBacks(_ mode: String, _ events: [[Any]], tier: String = "easy") -> [String] {
            gestureReports(runVector(vector(mode, events, until: 2500, tier: tier))).map { ArcadeGestureWords.sayBack($0) }
        }
        check(sayBacks("fight", finger(up: 150)) == ["Tap: weak punch."], "Tap: weak punch.")
        check(sayBacks("fight", finger(dy: -40, over: 100, up: 150)) == ["Flick up: strong punch."], "Flick up: strong punch.")
        check(sayBacks("fight", finger(dx: 50, from: 700, over: 100, up: 820))
              == ["Rest: block.", "Lift: block off.", "From a block, flick right: strong kick."], "Rest, Lift, and a flick out of it")
        check(sayBacks("menu", finger(1, up: 100) + finger(2, t0: 300, up: 480)) == ["Double-tap: choose."], "Double-tap: choose.")
        let scrubPoints: [(Double, Double, Double)] = [(0, 0, 0), (150, 30, 0), (300, 0, 0), (450, 30, 0), (600, 0, 0)]
        check(sayBacks("menu", path(1, x: 150, y: 400, scrubPoints) + path(2, x: 210, y: 400, scrubPoints)) == ["Two-finger scrub: back."],
              "Two-finger scrub: back.")
        check(sayBacks("menu", finger(up: 1100)) == ["Hold: repeat."], "a menu hold is a hold, not a rest")
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
              && full[1].rows.contains("Slide a finger: move.") && full[2].rows.contains("Tap: jump."), "Full: the halves")
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

        var practice = ArcadePadPractice(lessons: lessons, endLine: "In the game, Practice on the main menu is a safe first fight.")
        check(practice.startLines() == [ArcadePadPractice.opening, "Lesson 1, the pad.", lessons[0].steps[0].line], "the opening")
        check(practice.padHeld() == ["Good.", lessons[0].steps[1].line], "the pad taken")
        check(practice.padHeld().isEmpty, "taking it again is not the step")
        check(practice.padReleased() == ["Good.", lessons[0].steps[2].line], "VoiceOver back")
        check(practice.padHeld() == ["Good.", "Lesson done.", "Lesson 2, menus.", "Flick right for the next item."] && practice.mode == "menu",
              "Lesson 1 done")
        func feed(_ events: [[Any]], _ mode: String) -> [String] {
            var lines: [String] = []
            for output in runVector(vector(mode, events, until: 2500)) { lines += practice.handle(output) }
            return lines
        }
        let right = finger(dx: 30, over: 100, up: 150)
        check(feed(right, "menu") == ["Flick right: next."], "every attempt is said back")
        check(feed(right, "menu") == ["Flick right: next.", "Good.", "Flick left for the one before."], "two clean in a row pass")
        check(feed(right, "menu") == ["Flick right: next.", "That flick went right. Flick left for previous."], "the wrong way, corrected")
        check(feed(finger(dx: 25, over: 100, up: 200), "menu") == ["Your finger moved, but not far enough for a flick. Flick farther."],
              "a dud gets its reason")
        check(practice.taps.isEmpty, "no taps measured while flicks were wanted")
        check(practice.nextLesson() == ["Next: fighting.", lessons[2].intro, "Tap anywhere: an attack."] && practice.mode == "fight",
              "Next lesson skips")
        check(feed(finger(up: 700), "fight") == ["Rest: block.", "That was a rest, so it blocked. Lift sooner for an attack.", "Lift: block off."],
              "a rest when a tap was wanted")
        check(feed(finger(1, up: 100) + finger(2, x: 260, up: 100), "fight") == ["Two-finger tap: quiet.", "That was two fingers. Use one."],
              "two fingers when one was wanted")
        _ = feed(finger(up: 150), "fight")
        check(practice.taps.count == 1 && practice.drifts.count == 1, "her one-finger taps are measured while a tap is wanted")
        check(practice.nextLesson() == [ArcadePadPractice.finishedLine, "In the game, Practice on the main menu is a safe first fight."]
              && practice.finished && practice.current == nil, "the end points her to the game's own practice")

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
        let script = ArcadeJS.hostScript(base: "b", emulatorData: "d", settings: [:])
        check(script.contains("speechGate: true,") && script.contains("id: (o && o.id != null) ? String(o.id) : null")
              && script.contains("cls: (o && o.cls) ? String(o.cls) : null") && script.contains("detail.route === 'native'"),
              "the host script gates the kit's voice and carries each native line's id and class")
        check(ArcadeKitSettings.calls("alerts") == "alerts", "the kit's 'alerts' calls")
        check(ArcadeSpeakerWarnings.buzzAndWords.calls == "alerts" && ArcadeSpeakerWarnings.buzzOnly.calls == "off"
              && ArcadeSpeakerWarnings.everyCall.calls == "all" && ArcadeSpeakerWarnings.off.calls == "off"
              && ArcadeSpeakerWarnings.buzzOnly.buzz && !ArcadeSpeakerWarnings.off.buzz, "Warnings on the phone speaker")

        let none = ArcadeTouchChoices(settings: nil)
        check(none == ArcadeTouchChoices() && none.fightControls == "easy" && none.walkIn && none.skipDemo && none.lessDamage == nil
              && none.lessDamageShown, "the touch defaults: Easy, walk in, skip the demo, less damage in Easy")
        let chosen = ArcadeTouchChoices(settings: ["fightControls": "full", "walkIn": false, "lessDamage": false, "skipDemo": false])
        check(chosen.fightControls == "full" && !chosen.walkIn && !chosen.skipDemo && !chosen.lessDamageShown, "her own choices")
        check(ArcadeTouchChoices(settings: ["fightControls": "hard"]).fightControls == "easy", "an unknown tier is Easy")
        check(ArcadeTouchChoices(settings: ["fightControls": "full"]).lessDamageShown == false, "less damage is on by default only in Easy")
        var kept: [String: Any] = ["fightControls": "full", "walkIn": false]
        ArcadeTouchChoices.fillDefaults(&kept, pauseOnLeave: false)
        check((kept["fightControls"] as? String) == "full" && (kept["walkIn"] as? Bool) == false && (kept["skipDemo"] as? Bool) == true
              && (kept["pauseOnLeave"] as? Bool) == false, "defaults fill only what she has not chosen")

        var telemetry = ArcadeTelemetry()
        telemetry.openedAt = Date(timeIntervalSince1970: 0)
        telemetry.touch.note(pad: true, seconds: 3.5, how: "first touch")
        telemetry.touch.watchdogFires = 1
        telemetry.touch.activates = 2
        for output in runVector(vector("fight", finger(up: 150), until: 2500)) + runVector(vector("menu", finger(dx: 25, over: 100, up: 200), until: 2500)) {
            switch output {
            case .gesture(let report): telemetry.touch.note(gesture: report, seconds: 4, held: true, tier: "easy")
            case .dud(let dud): telemetry.touch.note(dud: dud, seconds: 5, held: true, tier: "easy")
            default: break
            }
        }
        let spoken: [String: Any] = ["text": "Pad on.", "cls": "answer", "route": "native", "cutBy": "none"]
        let tick: [String: Any] = ["fps": 60, "speech": [spoken]]
        telemetry.note(event: "telemetry", detail: tick)
        telemetry.note(error: "a page error")
        let report = telemetry.report(now: Date(timeIntervalSince1970: 60))
        check(report.contains("Pad: taken 1, let go 0. VoiceOver's activate on the pad: 2. Pad isn't held lines: 1.")
              && report.contains("Pad times: on 3.50 s (first touch).") && report.contains("Gestures: tap1 1."),
              "the pad's summary")
        check(report.contains("Gesture trace (the last 2):") && report.contains("tap1: weak punch") && report.contains("Kit speech trace (the last 1):")
              && report.contains("cls=answer cutBy=none route=native text=Pad on."), "the gesture and speech traces")
        if let summary = report.range(of: "Pad: taken"), let errors = report.range(of: "Last errors:"), let trace = report.range(of: "Gesture trace") {
            check(summary.lowerBound < errors.lowerBound && errors.lowerBound < trace.lowerBound,
                  "the summary leads and the traces go last, so a report cut to size keeps the summary")
        } else {
            check(false, "the report has the summary, the errors and the traces")
        }
    }
}
