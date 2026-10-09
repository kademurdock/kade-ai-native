import Foundation

/// Selection of authored facial pixels only. Audio timing, ownership and the
/// continuous head/body gestures remain with their existing presentation data.
enum CharacterFacialPolicy {
    static let blinkThreshold = 0.35

    static func blinkInnerRadius(agentID: String?) -> Double {
        // Lilly's outer right eye reaches into the old feathered band. Keep
        // the same ellipse, but cover her complete eye with authored pixels.
        CharacterMotion.rigID(agentID) == CharacterMotion.lillyID ? 0.9 : 0.6
    }

    static func face(for presentation: CharacterPresentation, agentID: String?) -> CharacterFace {
        // Harley's curious panel has wide, startled eyes. A neutral listener
        // keeps his resting face while the existing listening gesture nods.
        // Authored directions and a one-shot laugh always take precedence.
        if agentID == CharacterMotion.harleyID, !presentation.laughing,
           presentation.activity == .listening, presentation.expression == .neutral {
            return .neutral
        }
        return presentation.face
    }

    static func shouldBlink(amount: Double, face: CharacterFace, agentID: String?) -> Bool {
        guard amount.isFinite, (0...1).contains(amount), amount >= blinkThreshold else { return false }
        // Harley's delighted nuance also has authored closed/squinted eyes.
        // The other delighted panels have visible open eyes.
        if face == .delighted, agentID == CharacterMotion.harleyID { return false }
        // These exact laugh panels already close the eyes. Della and
        // Witherspoon's laugh panels have open eyes and retain their blink.
        if face == .laugh {
            switch CharacterMotion.rigID(agentID) {
            case CharacterMotion.harleyID, CharacterMotion.kianaID, CharacterMotion.lillyID:
                return false
            default:
                break
            }
        }
        return true
    }
}
