import Foundation

/// Facial geometry in Angel's own neutral head coordinates. Values scale the
/// master geometry; they never select another character's image or move a
/// mouth independently of its head. Eyebrow offsets are fractions of the
/// authored eye height, slopes and smile curvature are signed -1...1.
struct AngelVectorFacialPose {
    let leftEye: Double
    let rightEye: Double
    let leftBrow: Double
    let rightBrow: Double
    let leftBrowSlope: Double
    let rightBrowSlope: Double
    let gazeX: Double
    let gazeY: Double
    let smile: Double
    let cheekLift: Double
    let restingMouth: Double
}

/// The authored mouth box supplies width and height. Aperture is a geometric
/// opening, not image opacity; zero draws a single closed curved lip line.
struct AngelVectorMouthPose {
    let width: Double
    let aperture: Double
    let roundness: Double
    let smile: Double
    let upperTeeth: Double
    let lowerTeeth: Double
    let tongue: Double

    static let closed = AngelVectorMouthPose(width: 1, aperture: 0,
        roundness: 0.25, smile: 0.25, upperTeeth: 0, lowerTeeth: 0, tongue: 0)
}

struct AngelVectorOrnamentPose {
    let leftWingDegrees: Double
    let rightWingDegrees: Double
    /// Fractions of the common square master canvas.
    let haloOffsetY: Double
    let haloDegrees: Double
    /// Slow luminance changes at stable jewel positions, never a flash.
    let sparkle: Double

    static let still = AngelVectorOrnamentPose(leftWingDegrees: 0,
        rightWingDegrees: 0, haloOffsetY: 0, haloDegrees: 0, sparkle: 0.36)
}

enum AngelVectorMotion {
    /// All seventeen existing semantic faces have Angel's own parameter pose.
    /// The selected pose can change immediately while its eyelid aperture stays
    /// continuous. No whole-face opacity dissolve creates duplicate contours.
    static func facial(_ face: CharacterFace, blink: Double,
                       active: Bool) -> AngelVectorFacialPose {
        let selected = active ? face : .neutral
        let blinkAmount = active && blink.isFinite ? min(1, max(0, blink)) : 0
        let closedFraction = 1 - blinkAmount
        let recipe: (Double, Double, Double, Double, Double, Double,
                     Double, Double, Double, Double, Double)
        // Eyes, brow heights, brow slopes, gaze, smile, cheeks, resting opening.
        switch selected {
        case .neutral:    recipe = (1, 1, 0, 0, 0, 0, 0, 0, 0.25, 0.10, 0)
        case .smile:      recipe = (0.82, 0.82, 0.10, 0.10, 0, 0, 0, 0, 0.82, 0.72, 0)
        case .laugh:      recipe = (0.10, 0.10, 0.18, 0.18, 0, 0, 0, 0, 1, 1, 0.78)
        case .surprised:  recipe = (1.10, 1.10, 0.80, 0.80, 0, 0, 0, 0, 0.02, 0.08, 0.58)
        case .skeptical:  recipe = (0.86, 0.60, 0.62, -0.08, 0.24, 0.05, 0.16, 0, -0.10, 0.06, 0)
        case .angry:      recipe = (0.76, 0.76, -0.24, -0.24, -0.66, 0.66, 0, 0, -0.62, 0.12, 0)
        case .sad:        recipe = (0.74, 0.74, 0.20, 0.20, 0.66, -0.66, 0, 0.15, -0.76, 0.02, 0)
        case .worried:    recipe = (0.94, 0.94, 0.42, 0.42, 0.53, -0.53, 0, 0, -0.42, 0.06, 0.04)
        case .closed:     recipe = (0, 0, 0, 0, 0, 0, 0, 0, 0.44, 0.18, 0)
        case .curious:    recipe = (1, 0.94, 0.36, 0.10, 0.13, 0.04, 0.10, -0.08, 0.36, 0.20, 0)
        case .thoughtful: recipe = (0.92, 0.92, 0.12, 0.12, 0.05, -0.05, -0.18, -0.22, 0.10, 0.10, 0)
        case .playful:    recipe = (0.66, 0.95, 0.16, 0.40, 0, 0.10, 0.12, 0, 0.92, 0.62, 0)
        case .confident:  recipe = (0.96, 0.96, 0.24, 0.24, 0.04, -0.04, 0, -0.03, 0.65, 0.44, 0)
        case .tender:     recipe = (0.83, 0.83, 0.18, 0.18, 0.14, -0.14, 0, 0.04, 0.56, 0.36, 0)
        case .tired:      recipe = (0.48, 0.48, -0.06, -0.06, 0.04, -0.04, 0, 0.18, 0.02, 0.03, 0)
        case .serious:    recipe = (0.90, 0.90, -0.02, -0.02, 0.12, -0.12, 0, 0, -0.06, 0.04, 0)
        case .delighted:  recipe = (0.69, 0.69, 0.48, 0.48, 0, 0, 0, -0.06, 1, 0.92, 0.24)
        }
        return AngelVectorFacialPose(leftEye: recipe.0 * closedFraction,
            rightEye: recipe.1 * closedFraction, leftBrow: recipe.2,
            rightBrow: recipe.3, leftBrowSlope: recipe.4,
            rightBrowSlope: recipe.5, gazeX: recipe.6, gazeY: recipe.7,
            smile: recipe.8, cheekLift: recipe.9, restingMouth: recipe.10)
    }

    /// Same semantic visemes as CharacterMotion. Noise/pause/old owner already
    /// produce role zero at the caller. `active` additionally enforces still art.
    static func mouth(role: Int, strength: Double, face: CharacterFace,
                      active: Bool) -> AngelVectorMouthPose {
        let expression = facial(face, blink: 0, active: active)
        guard active else {
            return AngelVectorMouthPose(width: 1, aperture: 0,
                roundness: 0.25, smile: expression.smile,
                upperTeeth: 0, lowerTeeth: 0, tongue: 0)
        }
        // Authored laughter remains readable without a second speech mouth.
        if face == .laugh {
            return AngelVectorMouthPose(width: 1.10, aperture: 0.78,
                roundness: 0.38, smile: 1, upperTeeth: 0.16,
                lowerTeeth: 0, tongue: 0.20)
        }
        guard strength.isFinite, strength > 0.06, (1...8).contains(role) else {
            return AngelVectorMouthPose(width: face == .surprised ? 0.64 : 1,
                aperture: expression.restingMouth,
                roundness: face == .surprised ? 0.95 : 0.25,
                smile: expression.smile, upperTeeth: 0, lowerTeeth: 0, tongue: 0)
        }
        let intensity = min(1, max(0, strength))
        let opening: Double
        let width: Double
        let roundness: Double
        let upperTeeth: Double
        let lowerTeeth: Double
        let tongue: Double
        switch role {
        case 1: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0.18, 0.90, 0.34, 0, 0, 0)
        case 2: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0.58, 0.97, 0.46, 0.08, 0, 0.16)
        case 3: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0.72, 0.66, 0.98, 0, 0, 0.09)
        case 4: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0.28, 0.54, 1, 0, 0, 0)
        case 5: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0.27, 1.14, 0.22, 0.20, 0.08, 0)
        case 6: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0, 0.88, 0.20, 0, 0, 0)
        case 7: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0.14, 1.02, 0.20, 0.26, 0.20, 0)
        default: (opening, width, roundness, upperTeeth, lowerTeeth, tongue) = (0.95, 1.03, 0.53, 0.14, 0.06, 0.26)
        }
        return AngelVectorMouthPose(width: width,
            aperture: opening * (0.72 + 0.28 * intensity), roundness: roundness,
            smile: expression.smile, upperTeeth: upperTeeth,
            lowerTeeth: lowerTeeth, tongue: tongue)
    }

    /// Uses the portrait's shared time/active state. No timer, random positions,
    /// paid render service, sound request or speech-clip elapsed reset is needed.
    static func ornaments(time: Double, active: Bool,
                          expression: CharacterExpression) -> AngelVectorOrnamentPose {
        guard active, time.isFinite, time >= 0 else { return .still }
        let quiet = [.sad, .concerned, .afraid, .tired, .serious].contains(expression)
        let energy = quiet ? 0.42 : 1.0
        // Reduce before trigonometry to keep even very large finite input safe.
        let t = time.truncatingRemainder(dividingBy: 120 * .pi)
        let breath = sin(t * 0.48)
        let flutter = sin(t * 0.72 + 0.6)
        return AngelVectorOrnamentPose(leftWingDegrees: (breath * 1.3 + flutter * 0.5) * energy,
            rightWingDegrees: (-breath * 1.3 - flutter * 0.5) * energy,
            haloOffsetY: sin(t * 0.60) * 0.003,
            haloDegrees: sin(t * 0.30 + 0.4) * 0.35,
            sparkle: 0.36 + (sin(t * 0.48 + 1.2) * 0.11 + sin(t * 0.24) * 0.04) * energy)
    }
}
