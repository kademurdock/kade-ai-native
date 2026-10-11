import Foundation

func runCharacterDellaArmMotionChecks(_ check: (Bool, String) -> Void) {
    func speech(_ clipElapsed: Double, _ expression: CharacterExpression = .warm) -> CharacterPresentation {
        CharacterPresentation(activity: .speaking, expression: expression, elapsed: clipElapsed)
    }
    func sample(_ elapsed: Double, expression: CharacterExpression = .warm, level: Double = 1,
                active: Bool = true, clipElapsed: Double = 0.1) -> CharacterDellaArmPose {
        CharacterDellaArmMotion.pose(time: 40, level: level, active: active,
            presentation: speech(clipElapsed, expression), performanceElapsed: elapsed)
    }
    func finiteAndBounded(_ value: CharacterDellaArmPose) -> Bool {
        [value.viewerLeftDegrees, value.viewerRightDegrees].allSatisfy {
            $0.isFinite && abs($0) <= CharacterDellaArmPose.maximumDegrees
        }
    }
    let entrance = sample(0)
    let held = sample(0.7)
    let lateSentence = sample(30, clipElapsed: 0.1)
    check(entrance == .still && held != .still && lateSentence == .still,
        "Della sleeves enter, hold, settle and stay rested during a later sentence")
    check(sample(0.7, clipElapsed: 0.7) == sample(0.7, clipElapsed: 0.02),
        "The shared Della turn clock prevents a new sentence from replaying an arm gesture")
    check(CharacterDellaArmMotion.pose(time: 40, level: 1, active: true,
        presentation: speech(0.7)) == held,
        "A standalone Della candidate can use its clip elapsed without another clock")
    let open = sample(0.7, expression: .excited)
    let inward = sample(0.7, expression: .concerned)
    check(open.viewerLeftDegrees > 0 && open.viewerRightDegrees < 0
        && inward.viewerLeftDegrees < 0 && inward.viewerRightDegrees > 0,
        "Della's open and protective delivery gestures have distinct shoulder directions")
    check(sample(0.7, level: 0) == .still && sample(0.7, level: 0.008) == .still,
        "Silence and the existing output noise floor park both Della hands immediately")
    check(sample(0.7, active: false) == .still,
        "An inactive Della candidate parks both shoulder layers immediately")
    check(abs(sample(0.7, level: 0.1).viewerRightDegrees) < abs(held.viewerRightDegrees),
        "Rendered output energy changes the bounded Della arm accent")

    for activity in [CharacterActivity.idle, .thinking] {
        check(CharacterDellaArmMotion.pose(time: 15, level: 1, active: true,
            presentation: CharacterPresentation(activity: activity, elapsed: 0.7)) == .still,
            "Idle, interrupted or thinking Della does not gesture to another audio source")
    }
    let listening = CharacterPresentation(activity: .listening)
    check(CharacterDellaArmMotion.pose(time: 15, level: 0, active: true, presentation: listening)
        == CharacterDellaArmMotion.pose(time: 15, level: 1, active: true, presentation: listening),
        "Listening acknowledgement is independent of output audio")
    let acknowledgement = CharacterDellaArmMotion.pose(time: 15, level: 0, active: true, presentation: listening)
    check(acknowledgement != .still && abs(acknowledgement.viewerLeftDegrees) <= 0.25
        && abs(acknowledgement.viewerRightDegrees) <= 0.75,
        "Della's listening acknowledgement stays much smaller than speech gestures")
    check(acknowledgement == CharacterDellaArmMotion.pose(time: 35, level: 0,
        active: true, presentation: listening), "Della listening motion is deterministic and slow")
    var activeListeningSamples = 0
    for tick in 0..<400 {
        let pose = CharacterDellaArmMotion.pose(time: Double(tick) / 10, level: 0,
            active: true, presentation: listening)
        if pose != .still { activeListeningSamples += 1 }
        check(finiteAndBounded(pose), "Della's listening sleeve poses remain finite and bounded")
    }
    check(activeListeningSamples > 0 && activeListeningSamples < 80,
        "Della rests her hands for more than eighty percent of a listening cycle")

    for invalid in [Double.nan, .infinity, -.infinity, -1] {
        check(CharacterDellaArmMotion.pose(time: invalid, level: 1, active: true,
            presentation: speech(0.7)) == .still, "Invalid Della sampling clocks park both arms")
        check(CharacterDellaArmMotion.pose(time: 40, level: invalid, active: true,
            presentation: speech(0.7)) == .still, "Invalid Della output energy parks both arms")
        check(sample(invalid) == .still, "Invalid shared Della turn timing cannot move the hands")
    }
    for expression in CharacterExpression.allCases {
        for elapsed in [0, 0.2, 0.7, 1.2, 2.2, 4.3, 5.3, 9.3, 11, 30, Double.greatestFiniteMagnitude] {
            for level in [0.0, 0.009, 0.05, 0.2, 1, Double.greatestFiniteMagnitude] {
                check(finiteAndBounded(sample(elapsed, expression: expression, level: level)),
                    "Every Della delivery and output level stays within the three-degree shoulder limit")
            }
            check(sample(elapsed, expression: expression, active: false) == .still,
                "Every Della delivery preserves exact still arms when motion is disabled")
        }
        check(sample(11, expression: expression) == .still,
            "Della's finite speaking gesture ends completely instead of becoming an endless arm loop")
    }
    let tempo = CharacterFigureMotion.profile(id: CharacterMotion.dellaID).tempo
    for boundary in [0.32, 0.74, 1.56, 2.8, 3.26, 3.6, 4.54, 6.1, 6.5, 6.78, 7.72] {
        let before = sample(boundary / tempo - 0.000001, expression: .excited)
        let after = sample(boundary / tempo + 0.000001, expression: .excited)
        check(abs(before.viewerLeftDegrees - after.viewerLeftDegrees) < 0.0001
            && abs(before.viewerRightDegrees - after.viewerRightDegrees) < 0.0001,
            "Della sleeve entrance, hold, rest and follow-through meet without a pose discontinuity")
    }
}
