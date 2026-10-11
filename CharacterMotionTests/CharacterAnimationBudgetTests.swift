import Foundation

func runCharacterAnimationBudgetTests(_ check: (Bool, String) -> Void) {
    let activities: [CharacterActivity] = [.idle, .listening, .thinking, .speaking]
    let rates: [(CharacterThermalPressure, [Double])] = [
        (.nominal, [8, 12, 12, 24]),
        (.fair, [8, 8, 8, 18]),
        (.serious, [0, 0, 0, 0]),
        (.critical, [0, 0, 0, 0])
    ]
    for (thermal, expected) in rates {
        for (activity, rate) in zip(activities, expected) {
            let budget = CharacterAnimationBudget(active: true, activity: activity, thermal: thermal)
            check(budget.framesPerSecond == rate, "puppet rate follows activity and thermal pressure")
            check(budget.paused == (rate == 0), "serious and critical pressure stop the puppet clock")
            check(budget.minimumInterval.isFinite && budget.minimumInterval > 0,
                "even a paused puppet has a finite schedule interval")
            if rate > 0 {
                check(abs(budget.minimumInterval * rate - 1) < 0.000001,
                    "puppet interval matches its frame budget")
            }
            let paused = CharacterAnimationBudget(active: false, activity: activity, thermal: thermal)
            check(paused.framesPerSecond == 0 && paused.paused,
                "visibility, foreground, power and motion gates leave no ticking puppet clock")
        }
    }
    for activity in activities {
        let normal = CharacterAnimationBudget(active: true, activity: activity)
        let constrained = CharacterAnimationBudget(active: true, activity: activity, thermal: .fair)
        check(constrained.framesPerSecond <= normal.framesPerSecond,
            "fair thermal pressure never increases puppet sampling")
    }
    check(CharacterAnimationBudget(active: true, activity: .idle, thermal: .fair).framesPerSecond == 8,
        "fair idle sampling retains the short authored blink")
    let idle = CharacterAnimationBudget(active: true, activity: .idle)
    let listening = CharacterAnimationBudget(active: true, activity: .listening)
    let speaking = CharacterAnimationBudget(active: true, activity: .speaking)
    check(idle.framesPerSecond < listening.framesPerSecond && listening.framesPerSecond < speaking.framesPerSecond,
        "speech gets the fastest puppet clock while resting is cheaper")
    check(CharacterThermalPressure.allCases.count == rates.count,
        "every thermal state has an offline budget check")
}
