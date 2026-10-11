import Foundation

/// The candidate's full sleeve and attached hand rotate as one rigid layer at
/// each shoulder. There is no independent wrist translation or hand rotation.
/// Left and right refer to the viewer's sides of the unchanged portrait.
struct CharacterDellaArmPose: Equatable {
    let viewerLeftDegrees: Double
    let viewerRightDegrees: Double

    static let maximumDegrees = 3.0
    static let still = CharacterDellaArmPose(viewerLeftDegrees: 0, viewerRightDegrees: 0)
}

/// Pure candidate choreography. A renderer may opt into it after the separate
/// sleeve/hand artwork and shoulder registration have been reviewed. It owns
/// no audio, mutable state, timer or publisher, and does not register any art.
enum CharacterDellaArmMotion {
    static let listeningPeriod = 20.0

    static func pose(time: Double, level: Double, active: Bool,
                     presentation: CharacterPresentation,
                     performanceElapsed: Double? = nil) -> CharacterDellaArmPose {
        guard active, time.isFinite, time >= 0, level.isFinite, level >= 0 else { return .still }
        switch presentation.activity {
        case .idle, .thinking:
            return .still
        case .listening:
            // A small, slow acknowledgement followed by a long rest. Output
            // audio cannot enlarge it; this is an attentive listening pose.
            let cycle = time.truncatingRemainder(dividingBy: listeningPeriod)
            let acknowledgement = CharacterFigureMotion.pulse(cycle,
                start: 14, rise: 0.75, hold: 0.4, fall: 1.25)
            return CharacterDellaArmPose(viewerLeftDegrees: -0.25 * acknowledgement,
                viewerRightDegrees: 0.75 * acknowledgement)
        case .speaking:
            let elapsed = performanceElapsed ?? presentation.elapsed
            guard elapsed.isFinite, elapsed >= 0 else { return .still }
            let energy = min(1, max(0, (level - 0.008) * 5))
            guard energy > 0 else { return .still }
            // Reuse the established turn's entrance/hold/settle and softer
            // follow-throughs at Della's slower pace. A later sentence cannot
            // replay the entrance when the shared performance clock is passed.
            let gesture = CharacterFigureMotion.gestureEnvelope(elapsed: elapsed,
                tempo: CharacterFigureMotion.profile(id: CharacterMotion.dellaID).tempo)
            guard gesture > 0 else { return .still }
            let recipe: (Double, Double)
            switch presentation.expression {
            case .surprised, .excited: recipe = (2.6, -3.0)
            case .amused, .playful: recipe = (1.8, -2.6)
            case .warm, .tender: recipe = (1.0, -2.0)
            case .concerned, .sad, .afraid: recipe = (-0.7, 1.3)
            case .curious, .thoughtful: recipe = (-0.4, 1.6)
            case .skeptical, .dry, .disgusted: recipe = (-0.8, 1.1)
            case .confident, .smug: recipe = (1.4, -1.7)
            case .angry, .frustrated: recipe = (0.8, -2.2)
            case .serious: recipe = (0.5, -1.3)
            case .tired: recipe = (-0.3, 0.6)
            case .neutral, .calm: recipe = (0.4, -1.0)
            }
            let amount = gesture * energy
            func bounded(_ degrees: Double) -> Double {
                min(CharacterDellaArmPose.maximumDegrees,
                    max(-CharacterDellaArmPose.maximumDegrees, degrees))
            }
            return CharacterDellaArmPose(viewerLeftDegrees: bounded(recipe.0 * amount),
                viewerRightDegrees: bounded(recipe.1 * amount))
        }
    }
}
