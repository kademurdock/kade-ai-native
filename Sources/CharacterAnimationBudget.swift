import Foundation

/// Device pressure only affects decorative sampling, never playback or calls.
/// Kept independent of ProcessInfo so every budget can be checked offline.
enum CharacterThermalPressure: CaseIterable {
    case nominal, fair, serious, critical

    var permitsAnimation: Bool { self == .nominal || self == .fair }
}

/// A visible puppet spends most of its time listening or resting. Reserve the
/// faster clock for speech and leave no ticking clock when motion is paused.
struct CharacterAnimationBudget {
    let active: Bool
    let activity: CharacterActivity
    var thermal: CharacterThermalPressure = .nominal

    var framesPerSecond: Double {
        guard active, thermal.permitsAnimation else { return 0 }
        switch (activity, thermal) {
        case (.speaking, .nominal): return 24
        case (.speaking, .fair): return 18
        // Oct 16 2026: resting breath and drift now move visibly, so the
        // resting stage samples them as smoothly as listening does.
        case (.idle, .nominal), (.listening, .nominal), (.thinking, .nominal): return 12
        case (.idle, .fair), (.listening, .fair), (.thinking, .fair): return 8
        default: return 0
        }
    }

    /// For the short window around a blink (CharacterFaceClock) the clock
    /// runs at least this fast, so the eyelid's closing, hold and opening each
    /// get frames. Never while the clock itself is stopped.
    var blinkFramesPerSecond: Double {
        let rate = framesPerSecond
        guard rate > 0 else { return 0 }
        return max(rate, thermal == .nominal ? 24 : 20)
    }

    var paused: Bool { framesPerSecond == 0 }

    /// TimelineView still needs a finite interval while its clock is paused.
    var minimumInterval: TimeInterval { interval(blinking: false) }

    func interval(blinking: Bool) -> TimeInterval {
        let rate = blinking ? blinkFramesPerSecond : framesPerSecond
        return rate > 0 ? 1 / rate : 1
    }

    // The puppet model tests compile this file for CharacterThermalPressure only,
    // without the face clock (CharacterMotion.swift).
    #if !PUPPET_MODEL_TESTS
    /// The gap to the frame after one drawn at `time`. Looks one steady frame
    /// ahead, so the faster frames begin before the eyelid starts to close.
    func interval(after time: Double, faces: CharacterFaceClock) -> TimeInterval {
        let steady = interval(blinking: false)
        return interval(blinking: faces.wantsBlinkFrames(at: time)
            || faces.wantsBlinkFrames(at: time + steady))
    }
    #endif
}

#if canImport(SwiftUI) && !CHARACTER_MODEL_TESTS && !PUPPET_MODEL_TESTS
import SwiftUI

/// The portrait's frame dates: the activity budget's steady rate, raised to
/// the blink rate for the brief window around each blink the face clock has
/// queued. A paused budget yields one frame and then stops the clock.
struct CharacterAnimationSchedule: TimelineSchedule {
    let budget: CharacterAnimationBudget
    let paused: Bool
    let faces: CharacterFaceClock

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, schedule: self)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let schedule: CharacterAnimationSchedule

        mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            upcoming = schedule.paused || schedule.budget.paused ? nil
                : current.addingTimeInterval(schedule.budget.interval(after: current.timeIntervalSinceReferenceDate,
                    faces: schedule.faces))
            return current
        }
    }
}
#endif
