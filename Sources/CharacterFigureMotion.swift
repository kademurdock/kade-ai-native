import Foundation

/// Device-side body motion, in degrees and fractions of the square canvas.
/// It reads the same output clock and direction as the existing face rig.
struct CharacterFigurePose: Equatable {
    let headAngle: Double
    let headNod: Double
    let torsoAngle: Double
    let torsoLift: Double
    let farArmAngle: Double
    let nearArmAngle: Double

    static let still = CharacterFigurePose(headAngle: 0, headNod: 0,
        torsoAngle: 0, torsoLift: 0, farArmAngle: 0, nearArmAngle: 0)
}

/// A presentation-only reference clock owned by one portrait. Sampling does
/// not publish state or wake a view. Sentence clips share a speaking turn;
/// an interruption, different character or motion-policy stop clears it.
/// Call only from the portrait's existing main-thread timeline.
final class CharacterBodyPerformanceClock {
    static let queueGap = 1.2
    private var identity: String?
    private var start: Double?
    private var lastSpeech: Double?
    private var lastSample: Double?

    func reset() {
        identity = nil
        start = nil
        lastSpeech = nil
        lastSample = nil
    }

    func elapsed(identity currentIdentity: String, time: Double, active: Bool,
                 presentation: CharacterPresentation) -> Double {
        guard active, time.isFinite, time >= 0 else { reset(); return 0 }
        if identity != currentIdentity || lastSample.map({ time < $0 }) == true {
            reset()
            identity = currentIdentity
        }
        lastSample = time
        switch presentation.activity {
        case .listening, .thinking:
            start = nil
            lastSpeech = nil
            return 0
        case .idle:
            guard let start, let lastSpeech, time - lastSpeech <= Self.queueGap else {
                self.start = nil
                self.lastSpeech = nil
                return 0
            }
            return time - start
        case .speaking:
            if let lastSpeech, time - lastSpeech > Self.queueGap { start = nil }
            if start == nil {
                // If the view appears mid-clip, catch up instead of replaying
                // a greeting. Clip elapsed is otherwise reserved for the face.
                let clipElapsed = presentation.elapsed.isFinite && presentation.elapsed >= 0
                    ? min(time, min(120, presentation.elapsed)) : 0
                start = time - clipElapsed
            }
            lastSpeech = time
            return time - start!
        }
    }
}

enum CharacterFigureMotion {
    /// Profiles are attached to the drawn rig, so both Lilly identities share
    /// one personality. They alter timing/energy without widening art limits.
    static func profile(id: String) -> (tempo: Double, energy: Double) {
        switch CharacterMotion.rigID(id) {
        case CharacterMotion.dellaID: return (0.72, 0.78)
        case CharacterMotion.harleyID: return (0.83, 0.90)
        case CharacterMotion.lillyID: return (1.18, 1.04)
        case CharacterMotion.kianaID: return (1.03, 0.96)
        case CharacterMotion.witherspoonID: return (0.67, 0.66)
        case CharacterMotion.angelID: return (1.12, 1.0)
        default: return (1, 0.88)
        }
    }

    /// An eased entrance, a readable hold, then a complete return to rest.
    /// Repeated speech syllables do not make hands swing like pendulums.
    static func pulse(_ elapsed: Double, start: Double, rise: Double,
                      hold: Double, fall: Double) -> Double {
        guard elapsed.isFinite, elapsed >= start else { return 0 }
        func smooth(_ value: Double) -> Double {
            let value = min(1, max(0, value))
            return value * value * (3 - 2 * value)
        }
        let t = elapsed - start
        if t < rise { return smooth(t / rise) }
        if t < rise + hold { return 1 }
        if t < rise + hold + fall { return 1 - smooth((t - rise - hold) / fall) }
        return 0
    }

    /// A turn gets one main gesture and two softer follow-throughs. Longer
    /// replies settle into an attentive posture; silence never waves an arm.
    static func gestureEnvelope(elapsed: Double, tempo: Double) -> Double {
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        let t = min(elapsed, 30) * tempo
        return pulse(t, start: 0, rise: 0.32, hold: 0.42, fall: 0.82)
            + 0.58 * pulse(t, start: 2.8, rise: 0.46, hold: 0.34, fall: 0.94)
            + 0.34 * pulse(t, start: 6.1, rise: 0.40, hold: 0.28, fall: 0.94)
    }

    static func pose(id: String, time: Double, level: Double, active: Bool,
                     presentation: CharacterPresentation,
                     performanceElapsed: Double? = nil) -> CharacterFigurePose {
        guard active, time.isFinite, time >= 0 else { return .still }
        let personality = profile(id: id)
        let rigID = CharacterMotion.rigID(id) ?? id
        let seed = rigID.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        let phase = Double(seed % 1000) / 1000 * 2 * Double.pi
        // Reduce before multiplication: even huge finite clocks remain safe.
        let t = time.truncatingRemainder(dividingBy: 120 * .pi) * personality.tempo
        let breath = sin(t * 0.82 + phase)
        let drift = sin(t * 0.31 + phase)
        let audio = level.isFinite && presentation.activity == .speaking
            ? min(1, max(0, (level - 0.008) * 5)) : 0
        let elapsed = performanceElapsed ?? presentation.elapsed
        let validElapsed = elapsed.isFinite && elapsed >= 0 ? elapsed : 0
        let gesture = gestureEnvelope(elapsed: validElapsed, tempo: personality.tempo)

        var head = drift * 0.64
        var nod = breath * 0.002
        var torso = drift * 0.25
        var lift = breath * 0.0022
        var farArm = 0.0
        var nearArm = 0.0

        switch presentation.activity {
        case .listening:
            // An occasional finite acknowledgement, with a long still hold.
            let cycle = (t + phase).truncatingRemainder(dividingBy: 8.8)
            let acknowledgement = pulse(cycle, start: 7.2, rise: 0.30, hold: 0.12, fall: 0.90)
            head += 1.05 + acknowledgement * 1.25
            nod += acknowledgement * 0.009
            torso -= 0.30
        case .thinking:
            head -= 2.7
            torso += 0.75
            nod += 0.001
        case .speaking:
            // Head, nod, torso, lift, far arm, near arm. The authored emotion
            // has a modest held posture as well as its larger finite gesture.
            let recipe: (Double, Double, Double, Double, Double, Double)
            switch presentation.expression {
            case .neutral:    recipe = (1.1, 0.002, 0.3, 0.001, 3, -4)
            case .warm:       recipe = (1.6, 0.004, -0.45, 0.001, 4, -8)
            case .amused:     recipe = (1.9, -0.003, -0.75, 0.004, 7, -9)
            case .serious:    recipe = (-0.5, 0.004, 0.5, 0, 3, -4)
            case .concerned:  recipe = (-1.6, 0.005, 0.8, -0.001, 2, -6)
            case .skeptical:  recipe = (-3.2, 0, 0.55, 0, 2, -4)
            case .surprised:  recipe = (3, -0.006, -1.4, 0.004, 10, -12)
            case .tender:     recipe = (-0.9, 0.004, 0.6, -0.001, 2, -6)
            case .calm:       recipe = (0.6, 0.003, 0.2, 0.001, 2, -3)
            case .confident:  recipe = (-0.65, -0.002, -0.9, 0.002, 6, -5)
            case .playful:    recipe = (2.4, 0.001, -0.75, 0.003, 5, -10)
            case .excited:    recipe = (2.8, -0.004, -1, 0.004, 11, -13)
            case .smug:       recipe = (-2, -0.001, -0.4, 0.001, 2, -5)
            case .curious:    recipe = (2.4, 0.003, 0.5, 0.001, 3, -5)
            case .thoughtful: recipe = (-2.8, 0.001, 1, 0, 1, -3)
            case .dry:        recipe = (-2.5, 0.001, 0.45, 0, 1, -3)
            case .frustrated: recipe = (-0.5, 0.002, 0.9, 0.001, 5, -6)
            case .angry:      recipe = (-0.8, 0.004, 0.8, 0.002, 8, -8)
            case .disgusted:  recipe = (-2.4, -0.002, 1, 0, 4, -4)
            case .afraid:     recipe = (-1.8, 0.004, 0.8, -0.002, 1, -4)
            case .sad:        recipe = (-1.6, 0.007, 0.6, -0.003, 1, -3)
            case .tired:      recipe = (1.8, 0.007, 0.8, -0.002, 0.5, -1)
            }
            let enter = pulse(min(validElapsed, 0.42), start: 0, rise: 0.42, hold: 1, fall: 1)
            let posture = enter * (0.36 + gesture * 0.64) * personality.energy
            let accent = gesture * audio * personality.energy
            head += recipe.0 * posture + audio * sin(t * 2.4 + phase) * 0.55
            nod += recipe.1 * posture + audio * 0.0016
            torso += recipe.2 * posture
            lift += recipe.3 * accent
            farArm = recipe.4 * accent
            nearArm = recipe.5 * accent
            if presentation.laughing {
                // A real authored laugh owns a short two-beat recoil. Its
                // clip clock remains appropriate for this explicit moment.
                let laugh = pulse(presentation.elapsed, start: 0.04, rise: 0.12, hold: 0.03, fall: 0.18)
                    + 0.68 * pulse(presentation.elapsed, start: 0.39, rise: 0.10, hold: 0.03, fall: 0.22)
                nod -= laugh * 0.004 * audio
                lift += laugh * 0.0025 * audio
                head += laugh * 1.2 * audio
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
