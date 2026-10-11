import Foundation

/// All points are fractions of the existing square portrait width. A taller
/// viewport adds room below that square without reducing the face's scale.
struct CharacterConversationPoint: Equatable {
    let x: Double
    let y: Double
    static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y) }
    func rotated(degrees: Double) -> Self {
        let radians = degrees * .pi / 180
        return Self(x: x * cos(radians) - y * sin(radians),
                    y: x * sin(radians) + y * cos(radians))
    }
    var length: Double { hypot(x, y) }
}

struct CharacterConversationArm: Equatable {
    let shoulder: CharacterConversationPoint
    let elbow: CharacterConversationPoint
    let wrist: CharacterConversationPoint
    let shoulderDegrees: Double
    let elbowDegrees: Double
    let wristDegrees: Double
    /// Local hand +Y points away from the wrist, continuously with the forearm.
    let handDegrees: Double
    let openness: Double
}

struct CharacterConversationBodyPose: Equatable {
    let viewerLeft: CharacterConversationArm
    let viewerRight: CharacterConversationArm
    let bodyDegrees: Double
    let bodyLift: Double
    let headDegrees: Double
    let headLift: Double

    /// Fixed order is shared with native evidence. Points precede angles and
    /// describe actual articulated joints, before the common torso transform.
    static let auditKeys = ["leftShoulderX", "leftShoulderY", "leftElbowX", "leftElbowY",
        "leftWristX", "leftWristY", "rightShoulderX", "rightShoulderY", "rightElbowX",
        "rightElbowY", "rightWristX", "rightWristY", "leftShoulderDegrees",
        "leftElbowDegrees", "leftWristDegrees", "rightShoulderDegrees",
        "rightElbowDegrees", "rightWristDegrees", "leftHandDegrees", "rightHandDegrees",
        "leftOpenness", "rightOpenness", "bodyDegrees", "bodyLift", "headDegrees", "headLift"]

    var auditValues: [String: Double] {
        let l = viewerLeft, r = viewerRight
        let values = [l.shoulder.x, l.shoulder.y, l.elbow.x, l.elbow.y, l.wrist.x, l.wrist.y,
            r.shoulder.x, r.shoulder.y, r.elbow.x, r.elbow.y, r.wrist.x, r.wrist.y,
            l.shoulderDegrees, l.elbowDegrees, l.wristDegrees, r.shoulderDegrees,
            r.elbowDegrees, r.wristDegrees, l.handDegrees, r.handDegrees, l.openness,
            r.openness, bodyDegrees, bodyLift, headDegrees, headLift]
        return Dictionary(uniqueKeysWithValues: zip(Self.auditKeys, values))
    }
}

enum CharacterConversationBodyGeometry {
    struct Registration {
        let leftShoulder: CharacterConversationPoint
        let rightShoulder: CharacterConversationPoint
        let leftElbow: CharacterConversationPoint
        let rightElbow: CharacterConversationPoint
        let leftWrist: CharacterConversationPoint
        let rightWrist: CharacterConversationPoint
        let upperRadius: Double
        let lowerRadius: Double
        let handScale: Double
        let bodyLimit: Double
    }

    static func registration(_ kind: CharacterConversationBodyArtwork.Kind) -> Registration {
        switch kind {
        case .kiana:
            // The original off-shoulder knit starts higher on the viewer's left.
            // These sockets sit under that cloth, not below the atlas square.
            return Registration(leftShoulder: .init(x: 0.12, y: 0.84), rightShoulder: .init(x: 0.88, y: 0.90),
                leftElbow: .init(x: 0.13, y: 1.09), rightElbow: .init(x: 0.87, y: 1.12),
                leftWrist: .init(x: 0.29, y: 1.26), rightWrist: .init(x: 0.71, y: 1.26),
                upperRadius: 0.066, lowerRadius: 0.036, handScale: 0.142, bodyLimit: 0.55)
        case .harley:
            return Registration(leftShoulder: .init(x: 0.20, y: 0.86), rightShoulder: .init(x: 0.80, y: 0.86),
                leftElbow: .init(x: 0.17, y: 1.09), rightElbow: .init(x: 0.83, y: 1.09),
                leftWrist: .init(x: 0.30, y: 1.25), rightWrist: .init(x: 0.70, y: 1.25),
                upperRadius: 0.066, lowerRadius: 0.040, handScale: 0.148, bodyLimit: 0.75)
        case .lilly:
            // Original cats occupy the sides of the square, above these hands.
            return Registration(leftShoulder: .init(x: 0.23, y: 0.87), rightShoulder: .init(x: 0.77, y: 0.87),
                leftElbow: .init(x: 0.19, y: 1.09), rightElbow: .init(x: 0.81, y: 1.09),
                leftWrist: .init(x: 0.31, y: 1.26), rightWrist: .init(x: 0.69, y: 1.26),
                upperRadius: 0.061, lowerRadius: 0.036, handScale: 0.136, bodyLimit: 0.65)
        case .witherspoon:
            return Registration(leftShoulder: .init(x: 0.22, y: 0.85), rightShoulder: .init(x: 0.78, y: 0.85),
                leftElbow: .init(x: 0.18, y: 1.09), rightElbow: .init(x: 0.82, y: 1.09),
                leftWrist: .init(x: 0.31, y: 1.25), rightWrist: .init(x: 0.69, y: 1.25),
                upperRadius: 0.063, lowerRadius: 0.036, handScale: 0.142, bodyLimit: 0.42)
        }
    }

    /// A genuine two-bone chain: elbow and wrist are recomputed from rotated
    /// rest vectors. Hand rotation never translates or detaches the wrist.
    static func arm(shoulder: CharacterConversationPoint, elbow: CharacterConversationPoint,
                    wrist: CharacterConversationPoint, shoulderDegrees: Double,
                    elbowDegrees: Double, wristDegrees: Double, openness: Double) -> CharacterConversationArm {
        let upper = (elbow - shoulder).rotated(degrees: shoulderDegrees)
        let lower = (wrist - elbow).rotated(degrees: shoulderDegrees + elbowDegrees)
        let posedElbow = shoulder + upper
        let posedWrist = posedElbow + lower
        return CharacterConversationArm(shoulder: shoulder, elbow: posedElbow, wrist: posedWrist,
            shoulderDegrees: shoulderDegrees, elbowDegrees: elbowDegrees, wristDegrees: wristDegrees,
            handDegrees: atan2(lower.y, lower.x) * 180 / .pi - 90 + wristDegrees,
            openness: openness)
    }

    static func pose(artwork: CharacterConversationBodyArtwork, active: Bool,
                     presentation: CharacterPresentation, figurePose: CharacterFigurePose,
                     elapsed: Double, outputLevel: Double,
                     performance: CharacterBodyPerformanceSample? = nil) -> CharacterConversationBodyPose {
        let r = registration(artwork.kind)
        func bound(_ value: Double, _ limit: Double) -> Double {
            value.isFinite ? min(limit, max(-limit, value)) : 0
        }
        var left = (0.0, 0.0, 0.0), right = (0.0, 0.0, 0.0)
        var openness = 0.12
        let valid = active && elapsed.isFinite && elapsed >= 0
        if valid {
            let tempo = CharacterFigureMotion.profile(id: artwork.rigID).tempo
            let sourceTime = performance?.activityElapsed ?? elapsed
            let t = sourceTime.isFinite && sourceTime >= 0
                ? sourceTime.truncatingRemainder(dividingBy: 120) : 0
            switch presentation.activity {
            case .speaking:
                // The shared slow envelope supplies energy. Raw syllable-level
                // audio is reserved for the existing face, never these joints.
                let ownerMatches = presentation.outputSpeakerID == artwork.agentID
                let legacyOwner = presentation.outputPhase == .unspecified
                    && (presentation.outputSpeakerID == nil || ownerMatches)
                let sampledHold = performance != nil && (presentation.outputPhase == .paused
                    || presentation.outputPhase == .queuedGap)
                let playingOwner = (presentation.outputPhase == .playing || sampledHold) && ownerMatches
                    && presentation.outputEpisodeKey.map { !$0.isEmpty && $0.count <= 128 } == true
                guard legacyOwner || playingOwner else { break }
                // Pauses hold the clock's existing pose; sentence gaps consume
                // its release envelope. Neither phase reads a fresh audio level.
                let fallbackEnergy = outputLevel.isFinite && outputLevel > 0.008 ? 0.35 : 0
                let energy = max(0, bound(performance?.energy ?? fallbackEnergy, 1))
                let envelope = performance.map {
                    CharacterFigureMotion.gestureEnvelope(performance: $0, tempo: tempo)
                } ?? CharacterFigureMotion.gestureEnvelope(elapsed: elapsed, tempo: tempo)
                let amount = max(0, bound(envelope, 1)) * energy
                func recipe(_ expression: CharacterExpression) -> (Double, Double, Double, Double) {
                    let inward: Bool
                    let strength: Double
                    switch expression {
                    case .warm, .tender, .concerned, .sad, .afraid, .tired:
                        inward = true; strength = expression == .tired ? 0.35 : 0.72
                    case .surprised, .excited, .amused, .playful:
                        inward = false; strength = 1
                    case .skeptical, .dry, .curious, .thoughtful, .disgusted:
                        inward = true; strength = 0.55
                    default: inward = false; strength = 0.65
                    }
                    return ((inward ? -3 : 3) * strength, (inward ? -18 : -27) * strength,
                            -8 * strength, (inward ? 0.30 : 0.80) * strength)
                }
                let old = recipe(performance?.previousExpression ?? presentation.expression)
                let next = recipe(presentation.expression)
                let mix = max(0, bound(performance?.expressionBlend ?? 1, 1))
                func blend(_ a: Double, _ b: Double) -> Double {
                    if mix == 0 { return a }
                    if mix == 1 { return b }
                    return a + (b - a) * mix
                }
                let shoulder = blend(old.0, next.0), elbow = blend(old.1, next.1)
                let wrist = blend(old.2, next.2), open = blend(old.3, next.3)
                let alternate = (performance?.gestureVariant ?? 0) % 2 == 1
                let leading = alternate ? 0.68 : 1.0
                let following = alternate ? 1.0 : 0.68
                left = (shoulder * amount * leading, elbow * amount * leading,
                        wrist * amount * leading)
                right = (-shoulder * amount * following, -elbow * amount * following,
                         -wrist * amount * following)
                openness += open * amount
            case .listening:
                let attention = Double((performance?.attentionVariant ?? 0) % 3)
                let acknowledgement = CharacterFigureMotion.pulse((t + attention * 2.4)
                    .truncatingRemainder(dividingBy: 18), start: 13, rise: 0.9, hold: 0.5, fall: 1.5)
                left = (-0.5 * acknowledgement, -3 * acknowledgement, -2 * acknowledgement)
                right = (0.8 * acknowledgement, 4 * acknowledgement, 2 * acknowledgement)
                openness += 0.08 * acknowledgement
            case .thinking:
                let enter = CharacterFigureMotion.pulse(min(max(0, t), 1.2),
                    start: 0, rise: 1.2, hold: 120, fall: 1)
                left = (0, -4 * enter, -2 * enter)
                right = (0.6 * enter, 8 * enter, 3 * enter)
                openness += 0.03 * enter
            case .idle: break
            }
        }
        let l = arm(shoulder: r.leftShoulder, elbow: r.leftElbow, wrist: r.leftWrist,
            shoulderDegrees: bound(left.0, 4), elbowDegrees: bound(left.1, 28),
            wristDegrees: bound(left.2, 10), openness: min(1, openness))
        let rr = arm(shoulder: r.rightShoulder, elbow: r.rightElbow, wrist: r.rightWrist,
            shoulderDegrees: bound(right.0, 4), elbowDegrees: bound(right.1, 28),
            wristDegrees: bound(right.2, 10), openness: min(1, openness))
        let limits = artwork.existingBust.motionLimits
        return CharacterConversationBodyPose(viewerLeft: l, viewerRight: rr,
            bodyDegrees: valid ? bound(figurePose.torsoAngle / 3 * r.bodyLimit, r.bodyLimit) : 0,
            bodyLift: valid ? bound(figurePose.torsoLift * 0.30, 0.0024) : 0,
            headDegrees: valid ? bound(figurePose.headAngle / 7 * limits.headDegrees, limits.headDegrees) : 0,
            headLift: valid ? bound(figurePose.headNod / 0.018 * limits.headOffsetPixels
                / artwork.existingBust.cropSide, limits.headOffsetPixels / artwork.existingBust.cropSide) : 0)
    }
}
