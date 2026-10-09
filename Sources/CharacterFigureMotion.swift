import Foundation

/// Device-side body motion, in degrees and fractions of the square canvas.
/// It reads the same output clock and direction as the existing face rig.
struct CharacterFigurePose {
    let headAngle: Double
    let headNod: Double
    let torsoAngle: Double
    let torsoLift: Double
    let farArmAngle: Double
    let nearArmAngle: Double

    static let still = CharacterFigurePose(headAngle: 0, headNod: 0,
        torsoAngle: 0, torsoLift: 0, farArmAngle: 0, nearArmAngle: 0)
}

enum CharacterFigureMotion {
    static func pose(id: String, time: Double, level: Double, active: Bool,
                     presentation: CharacterPresentation) -> CharacterFigurePose {
        guard active, time.isFinite, time >= 0 else { return .still }
        let seed = id.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        let phase = Double(seed % 1000) / 1000 * 2 * Double.pi
        let breath = sin(time * 0.95 + phase)
        let sway = sin(time * 0.48 + phase)
        let audio = level.isFinite && presentation.activity == .speaking
            ? min(1, max(0, (level - 0.008) * 5)) : 0
        let speakingBeat = audio * sin(time * 3.1 + phase)
        let start = presentation.elapsed.isFinite && presentation.elapsed >= 0
            ? sin(min(1, presentation.elapsed / 0.8) * Double.pi) : 0

        var head = sway * 1.5 + speakingBeat * 2.7
        var nod = breath * 0.003 + audio * (0.003 + 0.005 * abs(speakingBeat))
        var torso = sway * 0.8 + speakingBeat * 0.6
        var lift = breath * 0.003 + audio * 0.002
        var farArm = audio * (4 + 4 * sin(time * 2.1 + phase))
        var nearArm = audio * (-5 - 5 * sin(time * 2.4 + phase + 0.7))

        switch presentation.activity {
        case .listening:
            let listeningBeat = max(0, sin(time * 0.9 + phase))
            nod += listeningBeat * 0.007
            head += listeningBeat * 1.5
        case .thinking:
            head -= 3.5
            torso += 1.5
            nearArm -= 4
        case .speaking:
            switch presentation.expression {
            case .surprised, .excited:
                head += 3.5 * start
                farArm += 8 * start
                nearArm -= 8 * start
            case .warm, .amused, .playful, .tender:
                head += 1.5 * start
                nearArm -= 5 * start
            case .concerned, .sad, .afraid:
                head -= 2 * start
                nearArm += 4 * start
            case .skeptical, .dry:
                head -= 3 * start
            default:
                break
            }
        case .idle:
            break
        }

        func bound(_ value: Double, _ limit: Double) -> Double { min(limit, max(-limit, value)) }
        return CharacterFigurePose(headAngle: bound(head, 7), headNod: bound(nod, 0.018),
            torsoAngle: bound(torso, 3), torsoLift: bound(lift, 0.008),
            farArmAngle: bound(farArm, 14), nearArmAngle: bound(nearArm, 16))
    }
}
