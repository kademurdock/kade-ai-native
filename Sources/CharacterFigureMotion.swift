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

/// One bounded observation shared by the face, body and attached hand groups.
/// `energy` is decoration only: the mouth still reads the raw output meter.
struct CharacterBodyPerformanceSample: Equatable {
    var elapsed: Double = 0
    var activityElapsed: Double = 0
    var energy: Double = 0
    var accentElapsed: Double = 0
    var accentScale: Double = 0
    var gestureVariant: Int = 0
    var attentionVariant: Int = 0
    var previousExpression: CharacterExpression = .neutral
    var expressionBlend: Double = 1
    static let still = CharacterBodyPerformanceSample()
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

    private var sampledIdentity: String?
    private var sampledEpisode: String?
    private var sampledActivity: CharacterActivity?
    private var sampledPhase: CharacterOutputPhase = .stopped
    private var sampledAt: Double?
    private var sourceElapsed: Double?
    private var turnElapsed = 0.0
    private var activityElapsed = 0.0
    private var bodyEnergy = 0.0
    private var accentElapsed = 0.0
    private var accentScale = 0.0
    private var gestureVariant = 0
    private var attentionVariant = 0
    private var accentsUsed = 0
    private var lastAccentTurn = 0.0
    private var gapElapsed = 0.0
    private var silentElapsed = 0.0
    private var expression: CharacterExpression = .neutral
    private var previousExpression: CharacterExpression = .neutral
    private var transitionElapsed = 0.28

    func reset() {
        identity = nil
        start = nil
        lastSpeech = nil
        lastSample = nil
        resetSample()
    }

    private func resetSample() {
        sampledIdentity = nil
        sampledEpisode = nil
        sampledActivity = nil
        sampledPhase = .stopped
        sampledAt = nil
        sourceElapsed = nil
        turnElapsed = 0
        activityElapsed = 0
        bodyEnergy = 0
        accentElapsed = 0
        accentScale = 0
        gestureVariant = 0
        attentionVariant = 0
        accentsUsed = 0
        lastAccentTurn = 0
        gapElapsed = 0
        silentElapsed = 0
        expression = .neutral
        previousExpression = .neutral
        transitionElapsed = 0.28
    }

    /// Source-clock progress crosses sentence boundaries, but does not spend
    /// a gesture while paused. Only smoothing dt is capped at 250 ms: a sparse
    /// audit or a resumed source still catches up and settles its finite hands.
    func sample(identity currentIdentity: String, time: Double, level: Double,
                active: Bool, presentation: CharacterPresentation) -> CharacterBodyPerformanceSample {
        guard active, time.isFinite, time >= 0 else { resetSample(); return .still }
        let explicit = presentation.outputPhase != .unspecified && presentation.outputPhase != .stopped
        if explicit {
            let owner = String(currentIdentity.split(separator: "|", maxSplits: 1).first ?? "")
            guard presentation.activity == .speaking, presentation.outputSpeakerID == owner,
                  let key = presentation.outputEpisodeKey, !key.isEmpty, key.count <= 128,
                  presentation.elapsed.isFinite, presentation.elapsed >= 0 else {
                resetSample()
                return .still
            }
        }
        if sampledIdentity != currentIdentity || sampledAt.map({ time < $0 }) == true {
            resetSample()
            sampledIdentity = currentIdentity
        }
        let wallDelta = sampledAt.map { min(120, max(0, time - $0)) } ?? 0
        let smoothingDelta = min(0.25, wallDelta)
        sampledAt = time
        let rig = CharacterMotion.rigID(String(currentIdentity.split(separator: "|", maxSplits: 1).first ?? "")) ?? currentIdentity
        let episode = explicit ? presentation.outputEpisodeKey : nil
        let seed = (rig + "|" + (episode ?? "attention")).utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }

        guard presentation.activity == .speaking, presentation.outputPhase != .stopped else {
            if sampledActivity != presentation.activity {
                activityElapsed = 0
                attentionVariant = Int(seed % 3)
            } else {
                // Ambient breathing and head motion must keep progressing
                // during a long visible rest. Only finite speech gestures use
                // the 120-second ceiling; the active timeline still owns all
                // wakeups and its policy stop resets this clock immediately.
                activityElapsed = min(time, activityElapsed + wallDelta)
            }
            sampledActivity = presentation.activity
            sampledPhase = .stopped
            sourceElapsed = nil
            bodyEnergy = 0
            if sampledEpisode == nil {
                sampledEpisode = nil
                turnElapsed = 0
                accentElapsed = 0
                accentScale = 0
            } else {
                // Retain only the last explicit episode's finite budget. A
                // briefly drained streamed pump must not buy a new entrance.
                accentElapsed = min(120, accentElapsed + wallDelta)
            }
            gapElapsed = 0
            silentElapsed = 0
            return CharacterBodyPerformanceSample(activityElapsed: activityElapsed,
                attentionVariant: attentionVariant, previousExpression: presentation.expression)
        }
        let phase: CharacterOutputPhase = explicit ? presentation.outputPhase : .playing
        let clipElapsed = presentation.elapsed.isFinite && presentation.elapsed >= 0 ? min(120, presentation.elapsed) : 0
        let fresh = sampledEpisode != episode || (!explicit && sampledActivity != .speaking)
            || (!explicit && wallDelta > Self.queueGap)
        let oldGap = gapElapsed
        let oldSilence = silentElapsed
        var progress = 0.0
        if fresh {
            sampledEpisode = episode
            turnElapsed = clipElapsed
            accentElapsed = clipElapsed
            accentScale = 1
            gestureVariant = Int(seed % 3)
            attentionVariant = Int((seed >> 4) % 3)
            accentsUsed = 3 // Entrance and two softer, finite follow-throughs.
            lastAccentTurn = 0
            gapElapsed = 0
            silentElapsed = 0
            bodyEnergy = 0
            expression = presentation.expression
            previousExpression = expression
            transitionElapsed = 0.28
        } else if phase == .playing || phase == .paused {
            if !explicit { progress = wallDelta }
            else if let sourceElapsed, clipElapsed >= sourceElapsed {
                progress = clipElapsed - sourceElapsed
            } else {
                // A source elapsed reset belongs to the next sentence, not a
                // fresh entrance. Never count an unseen, long queue gap here.
                progress = sampledPhase == .queuedGap || sampledPhase == .stopped
                    ? clipElapsed : min(Self.queueGap, wallDelta)
            }
            turnElapsed = min(120, turnElapsed + progress)
            accentElapsed = min(120, accentElapsed + progress)
        }
        if phase == .queuedGap {
            gapElapsed = min(120, gapElapsed + wallDelta)
            accentElapsed = min(120, accentElapsed + wallDelta)
        } else if phase == .playing { gapElapsed = 0 }
        if phase == .playing || phase == .paused { sourceElapsed = clipElapsed }
        activityElapsed = turnElapsed

        let target = phase == .playing && level.isFinite ? min(1, max(0, (level - 0.008) * 5)) : 0
        if phase != .paused {
            let duration = target > bodyEnergy ? 0.32 : 0.58
            let smoothed = bodyEnergy + (target - bodyEnergy) * (1 - exp(-smoothingDelta / duration))
            let maximumStep = smoothingDelta * 2.5
            bodyEnergy += min(maximumStep, max(-maximumStep, smoothed - bodyEnergy))
            bodyEnergy = min(1, max(0, bodyEnergy))
            silentElapsed = target < 0.03 ? min(120, silentElapsed + progress) : 0
        }
        let changedCue = presentation.expression != expression
        if changedCue && phase != .paused {
            previousExpression = expression
            expression = presentation.expression
            transitionElapsed = 0
        } else if phase != .paused { transitionElapsed = min(0.28, transitionElapsed + smoothingDelta) }

        // A later authored cue or a genuine audible restart can spend at most
        // two extra gestures, after the opening recipe has completely settled.
        // Speech amplitude alone cannot turn every syllable into a new accent.
        let tempo = CharacterFigureMotion.profile(id: rig).tempo
        let settled = accentElapsed * tempo >= (accentScale == 1 ? 9.0 : 2.1)
        if !fresh, phase == .playing, target > 0.06, accentsUsed < 5,
           turnElapsed < 22, turnElapsed - lastAccentTurn >= 3.2, settled,
           changedCue || oldGap >= 0.55 || oldSilence >= 0.55 {
            accentElapsed = 0
            accentScale = changedCue ? 0.50 : 0.36
            gestureVariant = Int((seed &+ UInt32(accentsUsed)) % 3)
            lastAccentTurn = turnElapsed
            accentsUsed += 1
        }
        sampledActivity = .speaking
        sampledPhase = phase
        let blend = transitionElapsed / 0.28
        return CharacterBodyPerformanceSample(elapsed: turnElapsed, activityElapsed: activityElapsed,
            energy: bodyEnergy, accentElapsed: accentElapsed, accentScale: accentScale,
            gestureVariant: gestureVariant, attentionVariant: attentionVariant,
            previousExpression: previousExpression, expressionBlend: blend * blend * (3 - 2 * blend))
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

    static func gestureEnvelope(performance: CharacterBodyPerformanceSample, tempo: Double) -> Double {
        guard performance.accentElapsed.isFinite, performance.accentElapsed >= 0,
              performance.accentScale.isFinite, performance.accentScale > 0,
              tempo.isFinite, tempo > 0 else { return 0 }
        let variant = min(2, max(0, performance.gestureVariant))
        let t = min(performance.accentElapsed, 120) * min(2, tempo)
        let main = pulse(t, start: 0, rise: 0.32 + Double(variant) * 0.05,
            hold: 0.42 + Double(variant) * 0.04, fall: 0.82 + Double(variant) * 0.08)
        // Later accents are single gestures, not another three-part entrance.
        guard performance.accentScale >= 1 else { return main * performance.accentScale }
        return main
            + 0.58 * pulse(t, start: 2.8 + Double(variant) * 0.22, rise: 0.46, hold: 0.34, fall: 0.94)
            + 0.34 * pulse(t, start: 6.1 + Double(variant) * 0.32, rise: 0.40, hold: 0.28, fall: 0.94)
    }

    static func pose(id: String, time: Double, level: Double, active: Bool,
                     presentation: CharacterPresentation,
                     performanceElapsed: Double? = nil,
                     performance: CharacterBodyPerformanceSample? = nil) -> CharacterFigurePose {
        guard active, time.isFinite, time >= 0 else { return .still }
        let personality = profile(id: id)
        let rigID = CharacterMotion.rigID(id) ?? id
        let seed = rigID.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        let phase = Double(seed % 1000) / 1000 * 2 * Double.pi
        // Reduce before multiplication: even huge finite clocks remain safe.
        let motionTime = performance?.activityElapsed ?? time
        let t = (motionTime.isFinite && motionTime >= 0 ? motionTime : 0)
            .truncatingRemainder(dividingBy: 120 * .pi) * personality.tempo
        let breath = sin(t * 0.82 + phase)
        let drift = sin(t * 0.31 + phase)
        let audio = presentation.activity == .speaking
            ? min(1, max(0, performance?.energy ?? (level.isFinite ? (level - 0.008) * 5 : 0))) : 0
        let elapsed = performanceElapsed ?? presentation.elapsed
        let validElapsed = elapsed.isFinite && elapsed >= 0 ? elapsed : 0
        let gesture = performance.map { gestureEnvelope(performance: $0, tempo: personality.tempo) }
            ?? gestureEnvelope(elapsed: validElapsed, tempo: personality.tempo)

        var head = drift * 0.64
        var nod = breath * 0.002
        var torso = drift * 0.25
        var lift = breath * 0.0022
        var farArm = 0.0
        var nearArm = 0.0

        switch presentation.activity {
        case .listening:
            // An occasional finite acknowledgement, with a long still hold.
            let variant = Double(performance?.attentionVariant ?? 0)
            let period = performance == nil ? 8.8 : 11.2 + variant * 1.8
            let cycle = (t + phase).truncatingRemainder(dividingBy: period)
            let acknowledgement = pulse(cycle, start: performance == nil ? 7.2 : 3.0 + variant * 1.4,
                rise: 0.30, hold: 0.12, fall: 0.90)
            let lean = performance == nil ? 1.05 : [-0.85, 0.65, 1.15][min(2, max(0, performance!.attentionVariant))]
            let enter = performance.map { min(1, $0.activityElapsed / 0.45) } ?? 1
            head += lean * enter + acknowledgement * 1.25
            nod += acknowledgement * 0.009
            torso -= 0.30
        case .thinking:
            let variant = Double(performance?.attentionVariant ?? 0)
            let enter = performance.map { min(1, $0.activityElapsed / 0.55) } ?? 1
            let consider = performance.map { pulse($0.activityElapsed, start: 1.8 + variant * 0.4,
                rise: 0.50, hold: 0.65, fall: 1.15) } ?? 0
            head -= (2.7 - variant * 0.35) * enter + consider * 0.45
            torso += 0.75 * enter
            nod += 0.001
        case .speaking:
            // Head, nod, torso, lift, far arm, near arm. The authored emotion
            // has a modest held posture as well as its larger finite gesture.
            func recipe(for expression: CharacterExpression) -> (Double, Double, Double, Double, Double, Double) {
            let recipe: (Double, Double, Double, Double, Double, Double)
            switch expression {
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
            return recipe
            }
            let next = recipe(for: presentation.expression)
            let old = recipe(for: performance?.previousExpression ?? presentation.expression)
            let mix = min(1, max(0, performance?.expressionBlend ?? 1))
            func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * mix }
            let recipe = (blend(old.0, next.0), blend(old.1, next.1), blend(old.2, next.2),
                blend(old.3, next.3), blend(old.4, next.4), blend(old.5, next.5))
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
