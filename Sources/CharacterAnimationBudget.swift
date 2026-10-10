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
        case (.listening, .nominal), (.thinking, .nominal): return 12
        case (.listening, .fair), (.thinking, .fair): return 8
        case (.idle, .nominal): return 8
        // Keep the ordinary blink visible at fair pressure: a lower resting
        // rate can skip its brief closed-eye hold altogether.
        case (.idle, .fair): return 8
        default: return 0
        }
    }

    var paused: Bool { framesPerSecond == 0 }

    /// TimelineView still needs a finite interval while its clock is paused.
    var minimumInterval: TimeInterval {
        let rate = framesPerSecond
        return rate > 0 ? 1 / rate : 1
    }
}
