import Foundation

func runCharacterBodyPerformanceChecks(_ check: (Bool, String) -> Void) {
    let clock = CharacterBodyPerformanceClock()
    let id = CharacterMotion.harleyID
    func speech(_ elapsed: Double, _ expression: CharacterExpression = .warm) -> CharacterPresentation {
        CharacterPresentation(activity: .speaking, expression: expression, elapsed: elapsed)
    }
    func sample(_ time: Double, _ state: CharacterPresentation, identity: String? = nil,
                active: Bool = true) -> Double {
        clock.elapsed(identity: identity ?? id, time: time, active: active, presentation: state)
    }
    func close(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.000001 }
    check(sample(10, speech(0)) == 0, "A fresh body performance starts at the actual speech boundary")
    check(close(sample(10.8, speech(0.8)), 0.8), "Body performance advances with the shared clock")
    check(close(sample(11.1, .idle), 1.1), "A short queued-sentence gap retains the body performance")
    check(close(sample(11.4, speech(0.1)), 1.4), "The next sentence does not replay the entrance gesture")
    check(close(sample(11.5, speech(0.2, .skeptical)), 1.5), "A changed delivery direction does not restart the turn")
    check(close(sample(11.6, speech(0.05), identity: CharacterMotion.dellaID), 0.05),
        "A different speaker cannot inherit the previous body's turn")
    check(sample(11.7, CharacterPresentation(activity: .listening)) == 0,
        "Listening immediately interrupts the body turn")
    check(close(sample(11.8, speech(0.03)), 0.03), "Speech after an interruption starts its own turn")
    check(sample(12, CharacterPresentation(activity: .thinking)) == 0,
        "Thinking clears the previous speaking turn")
    check(close(sample(13, speech(0.2)), 0.2), "A new speaking turn can catch up to its current clip")
    check(sample(14.3, .idle) == 0, "A long silent gap ends the body turn")
    check(close(sample(14.5, speech(0.1)), 0.1), "A later reply starts a fresh body turn")
    check(sample(14.6, speech(0.2), active: false) == 0, "Motion policy stop clears the body clock")
    check(close(sample(14.7, speech(0.04)), 0.04), "Reactivation catches up without retaining a paused turn")
    check(close(sample(8, speech(0.06)), 0.06), "A backwards shared clock resets body timing")
    for invalid in [Double.nan, .infinity, -.infinity, -1] {
        check(sample(invalid, speech(0.2)) == 0, "Invalid shared body clocks reset safely")
        check(sample(20, speech(invalid)) == 0, "Invalid first-clip elapsed never starts an old gesture")
        clock.reset()
    }

    let identities = [CharacterMotion.harleyID, CharacterMotion.dellaID, CharacterMotion.kianaID,
        CharacterMotion.lillyID, CharacterMotion.witherspoonID, CharacterMotion.angelID]
    func values(_ pose: CharacterFigurePose) -> [Double] {
        [pose.headAngle, pose.headNod, pose.torsoAngle, pose.torsoLift, pose.farArmAngle, pose.nearArmAngle]
    }
    let limits = [7.0, 0.018, 3, 0.008, 14, 16]
    let personalities = Set(identities.map {
        values(CharacterFigureMotion.pose(id: $0, time: 12, level: 0.2, active: true,
            presentation: speech(0.5, .playful), performanceElapsed: 0.5)).map { String($0) }.joined(separator: ",")
    })
    check(personalities.count == identities.count, "The six drawn rigs have individual body timing and energy")
    check(CharacterFigureMotion.pose(id: CharacterMotion.lillyID, time: 12, level: 0.2,
        active: true, presentation: speech(0.5)) == CharacterFigureMotion.pose(id: CharacterMotion.skyleeLillyID,
        time: 12, level: 0.2, active: true, presentation: speech(0.5)),
        "Both Lilly identities share the exact drawn body's personality")

    for identity in identities {
        let signatures = Set(CharacterExpression.allCases.map {
            values(CharacterFigureMotion.pose(id: identity, time: 12, level: 0.2, active: true,
                presentation: speech(0.5, $0), performanceElapsed: 0.5)).map { String($0) }.joined(separator: ",")
        })
        check(signatures.count == CharacterExpression.allCases.count,
            "Every authored delivery direction has a distinct body posture")
        for expression in CharacterExpression.allCases {
            for elapsed in [0, 0.3, 0.8, 1.6, 3.3, 6.8, 30, Double.greatestFiniteMagnitude] {
                let state = speech(elapsed, expression)
                let quiet = CharacterFigureMotion.pose(id: identity, time: 12, level: 0,
                    active: true, presentation: state, performanceElapsed: elapsed)
                check(quiet.farArmAngle == 0 && quiet.nearArmAngle == 0,
                    "Silent speech never swings either arm")
                let moving = CharacterFigureMotion.pose(id: identity, time: .greatestFiniteMagnitude,
                    level: 1, active: true, presentation: state, performanceElapsed: elapsed)
                check(zip(values(moving), limits).allSatisfy { $0.0.isFinite && abs($0.0) <= $0.1 },
                    "Individual body choreography remains inside all original art limits")
                check(CharacterFigureMotion.pose(id: identity, time: 12, level: 1,
                    active: false, presentation: state) == .still, "A disabled body stays exactly still")
            }
        }
        let settled = CharacterFigureMotion.pose(id: identity, time: 12, level: 1, active: true,
            presentation: speech(0.3, .excited), performanceElapsed: 30)
        check(settled.farArmAngle == 0 && settled.nearArmAngle == 0,
            "A long turn rests its arms even when a later sentence clip starts")
        let tempo = CharacterFigureMotion.profile(id: identity).tempo
        for boundary in [0.32, 0.74, 1.56, 2.8, 3.26, 3.6, 4.54, 6.1, 6.5, 6.78, 7.72] {
            let before = CharacterFigureMotion.gestureEnvelope(elapsed: boundary / tempo - 0.000001, tempo: tempo)
            let after = CharacterFigureMotion.gestureEnvelope(elapsed: boundary / tempo + 0.000001, tempo: tempo)
            check(abs(before - after) < 0.00001, "Body gesture entrance, hold and settle join continuously")
        }
    }

    for expression in CharacterExpression.allCases {
        for elapsed in [0, 0.3, 0.8, 1.6, 3.3, 6.8, 30, Double.greatestFiniteMagnitude] {
            let state = speech(elapsed, expression)
            let arms = AngelVectorMotion.arms(time: 12, level: 1, active: true,
                presentation: state, performanceElapsed: elapsed)
            check([arms.degrees, arms.offsetX, arms.offsetY].allSatisfy(\.isFinite)
                && abs(arms.degrees) <= AngelVectorArmPose.maximumDegrees
                && abs(arms.offsetX) <= AngelVectorArmPose.maximumOffsetX
                && abs(arms.offsetY) <= AngelVectorArmPose.maximumOffsetY,
                "Angel's clasped arm unit remains bounded without separating either wrist")
            check(AngelVectorMotion.arms(time: 12, level: 0, active: true,
                presentation: state) == .still, "Angel's arms rest during quiet speech")
            check(AngelVectorMotion.arms(time: 12, level: 1, active: false,
                presentation: state) == .still, "Angel's inactive arms preserve exact original art")
        }
    }
    for invalid in [Double.nan, .infinity, -.infinity, -1] {
        check(AngelVectorMotion.arms(time: invalid, level: 1, active: true,
            presentation: speech(0.5)) == .still, "Invalid clocks cannot corrupt Angel's arms")
        check(AngelVectorMotion.arms(time: 12, level: invalid, active: true,
            presentation: speech(0.5)) == .still, "Invalid or negative energy parks Angel's arms")
        check(AngelVectorMotion.arms(time: 12, level: 1, active: true,
            presentation: speech(0.5), performanceElapsed: invalid) == .still,
            "Invalid turn timing parks Angel's entire clasped unit")
    }
    for activity in [CharacterActivity.idle, .listening, .thinking] {
        check(AngelVectorMotion.arms(time: 12, level: 1, active: true,
            presentation: CharacterPresentation(activity: activity, elapsed: 0.5)) == .still,
            "Other audio cannot animate Angel's hands while she listens or thinks")
    }
    check(AngelVectorMotion.arms(time: 12, level: 1, active: true,
        presentation: speech(0.5), performanceElapsed: 30) == .still,
        "Angel's later sentences cannot replay the first arm gesture")
}

func runAngelClaspGeometryChecks(_ art: CharacterAngelVectorArt,
                                _ check: (Bool, String) -> Void) {
    let shapes = art.shapes.filter { AngelVectorArmPose.shapeIDs.contains($0.id) }
    check(Set(shapes.map(\.id)) == AngelVectorArmPose.shapeIDs && shapes.allSatisfy { $0.group == "body" },
        "The arm unit contains exactly Angel's two original sleeves, hands and finger marks")
    func transform(_ point: [Double], degrees: Double, x: Double, y: Double) -> [Double] {
        let pivot = AngelVectorArmPose.pivot
        let angle = degrees * .pi / 180
        let dx = point[0] - pivot[0], dy = point[1] - pivot[1]
        return [pivot[0] + dx * cos(angle) - dy * sin(angle) + x * art.canvas,
            pivot[1] + dx * sin(angle) + dy * cos(angle) + y * art.canvas]
    }
    var contained = true
    for degrees in [-AngelVectorArmPose.maximumDegrees, 0, AngelVectorArmPose.maximumDegrees] {
        for x in [-AngelVectorArmPose.maximumOffsetX, 0, AngelVectorArmPose.maximumOffsetX] {
            for y in [-AngelVectorArmPose.maximumOffsetY, 0, AngelVectorArmPose.maximumOffsetY] {
                for shape in shapes {
                    let margin = (shape.strokeWidth ?? 0) / 2
                    for command in shape.path {
                        for index in stride(from: 0, to: command.v.count, by: 2) {
                            let point = transform([command.v[index], command.v[index + 1]], degrees: degrees, x: x, y: y)
                            contained = contained && point.allSatisfy { $0.isFinite && (margin...art.canvas - margin).contains($0) }
                        }
                    }
                }
            }
        }
    }
    check(contained, "Angel's original arm control-point hulls and strokes remain inside the master at extrema")
    // The common rigid transform preserves the original cuff/hand overlap and
    // the clasp: no shoulder rotation or wrist offset can pull these apart.
    let cuff = [472.0, 764.0], hand = [437.0, 763.0]
    let movedCuff = transform(cuff, degrees: 1.5, x: 0.004, y: -0.008)
    let movedHand = transform(hand, degrees: 1.5, x: 0.004, y: -0.008)
    let originalDistance = hypot(cuff[0] - hand[0], cuff[1] - hand[1])
    let movedDistance = hypot(movedCuff[0] - movedHand[0], movedCuff[1] - movedHand[1])
    check(abs(originalDistance - movedDistance) < 0.000001,
        "Angel's sleeve and hand retain their original wrist relationship during a clasp gesture")
}
