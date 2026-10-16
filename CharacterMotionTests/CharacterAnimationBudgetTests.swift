import Foundation

func runCharacterAnimationBudgetTests(_ check: (Bool, String) -> Void) {
    let activities: [CharacterActivity] = [.idle, .listening, .thinking, .speaking]
    // Oct 16 2026: a resting stage now breathes and drifts visibly, so idle
    // samples as smoothly as listening (12, or 8 at fair pressure).
    let rates: [(CharacterThermalPressure, [Double], Double)] = [
        (.nominal, [12, 12, 12, 24], 24),
        (.fair, [8, 8, 8, 18], 20),
        (.serious, [0, 0, 0, 0], 0),
        (.critical, [0, 0, 0, 0], 0)
    ]
    for (thermal, expected, blinkFloor) in rates {
        for (activity, rate) in zip(activities, expected) {
            let budget = CharacterAnimationBudget(active: true, activity: activity, thermal: thermal)
            check(budget.framesPerSecond == rate, "puppet rate follows activity and thermal pressure")
            check(budget.paused == (rate == 0), "serious and critical pressure stop the puppet clock")
            check(budget.minimumInterval.isFinite && budget.minimumInterval > 0,
                "even a paused puppet has a finite schedule interval")
            if rate > 0 {
                check(abs(budget.minimumInterval * rate - 1) < 0.000001,
                    "puppet interval matches its frame budget")
                check(budget.blinkFramesPerSecond == max(rate, blinkFloor) && budget.blinkFramesPerSecond >= 20,
                    "a blink is always sampled at 20 fps or faster")
                check(abs(budget.interval(blinking: true) * budget.blinkFramesPerSecond - 1) < 0.000001,
                    "the blink interval matches the blink rate")
            } else {
                check(budget.blinkFramesPerSecond == 0, "a stopped puppet clock never runs for a blink")
            }
            let paused = CharacterAnimationBudget(active: false, activity: activity, thermal: thermal)
            check(paused.framesPerSecond == 0 && paused.paused && paused.blinkFramesPerSecond == 0,
                "visibility, foreground, power and motion gates leave no ticking puppet clock")
        }
    }
    for activity in activities {
        let normal = CharacterAnimationBudget(active: true, activity: activity)
        let constrained = CharacterAnimationBudget(active: true, activity: activity, thermal: .fair)
        check(constrained.framesPerSecond <= normal.framesPerSecond
            && constrained.blinkFramesPerSecond <= normal.blinkFramesPerSecond,
            "fair thermal pressure never increases puppet sampling")
    }
    check(CharacterAnimationBudget(active: true, activity: .idle, thermal: .fair).framesPerSecond == 8,
        "fair idle sampling keeps its eight-frame floor")
    let idle = CharacterAnimationBudget(active: true, activity: .idle)
    let listening = CharacterAnimationBudget(active: true, activity: .listening)
    let speaking = CharacterAnimationBudget(active: true, activity: .speaking)
    check(idle.framesPerSecond == 12 && idle.framesPerSecond <= listening.framesPerSecond
        && listening.framesPerSecond < speaking.framesPerSecond,
        "speech gets the fastest puppet clock; the resting stage samples at 12 fps")
    // The schedule only speeds up for a blink the face clock has queued.
    let faces = CharacterFaceClock()
    check(abs(idle.interval(after: 100, faces: faces) - 1.0 / 12) < 0.000001,
        "with no blink queued the resting clock keeps its steady rate")
    _ = faces.sample(identity: CharacterMotion.harleyID + "|/images/a.png", time: 100,
        face: .neutral, glance: 0, active: true)
    var time = 100.0
    var fastest = 1.0
    while time < 110 {
        let gap = idle.interval(after: time, faces: faces)
        fastest = min(fastest, gap)
        time += gap
        _ = faces.sample(identity: CharacterMotion.harleyID + "|/images/a.png", time: time,
            face: .neutral, glance: 0, active: true)
    }
    check(abs(fastest - 1.0 / 24) < 0.000001, "the resting clock briefly reaches 24 fps around a blink")
    check(CharacterThermalPressure.allCases.count == rates.count,
        "every thermal state has an offline budget check")
}
