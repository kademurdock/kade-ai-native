import Foundation

/// Authored outlines use either the study's world coordinates (Harley) or the
/// unchanged 414-pixel neutral atlas panel (Lilly and her static companions).
enum CharacterBustOutline: String, Hashable {
    case harleyHead, lillyHead, lillyLeftCat, lillyRightCat, kianaHead, dellaHead, witherspoonHead

    var usesAtlasCoordinates: Bool { self != .harleyHead }
}

struct CharacterBustFaceCore {
    let x: Double
    let y: Double
    let radiusX: Double
    let radiusY: Double
}

struct CharacterBustMaskPlacement {
    let x: Double
    let y: Double
    let side: Double
}

struct CharacterBustMotionLimits {
    let headDegrees: Double
    let bodyDegrees: Double
    let headOffsetPixels: Double
    let bodyOffsetPixels: Double

    static let harley = CharacterBustMotionLimits(headDegrees: 2, bodyDegrees: 0.5,
        headOffsetPixels: 3, bodyOffsetPixels: 2)
    static let lilly = CharacterBustMotionLimits(headDegrees: 1.95, bodyDegrees: 0.22,
        headOffsetPixels: 1.7, bodyOffsetPixels: 0)
}

/// Native close busts preserve the approved face atlas. Each supporting body is
/// one plate; independent arm/hand rigs remain a separate future art contract.
struct CharacterBustArtwork {
    let bodyAsset: String
    let maskAsset: String?
    let bodyX: Double
    let bodyY: Double
    let bodyWidth: Double
    let bodyHeight: Double
    let cropX: Double
    let cropY: Double
    let cropSide: Double
    let panelX: Double
    let panelY: Double
    let panelSide: Double
    let neckX: Double
    let neckY: Double
    let waistX: Double
    let waistY: Double
    let faceCore: CharacterBustFaceCore?
    let headOutline: CharacterBustOutline
    let accessoryOutlines: [CharacterBustOutline]
    let motionLimits: CharacterBustMotionLimits
    var maskPlacement: CharacterBustMaskPlacement? = nil
    /// Mandatory for Kiana's reused concept: the generated head is excluded.
    /// Applied in world coordinates to the supporting image before body motion.
    var bodyClipMinY: Double? = nil

    var requiredAssets: [String] { [bodyAsset] + (maskAsset.map { [$0] } ?? []) }

    var isValid: Bool {
        let values = [bodyX, bodyY, bodyWidth, bodyHeight, cropX, cropY, cropSide,
            panelX, panelY, panelSide, neckX, neckY, waistX, waistY,
            motionLimits.headDegrees, motionLimits.bodyDegrees,
            motionLimits.headOffsetPixels, motionLimits.bodyOffsetPixels]
        guard values.allSatisfy(\.isFinite), bodyWidth > 0, bodyHeight > 0,
              cropSide > 0, panelSide > 0, !bodyAsset.isEmpty,
              maskAsset.map({ !$0.isEmpty }) ?? true else { return false }
        if let mask = maskPlacement {
            guard [mask.x, mask.y, mask.side].allSatisfy(\.isFinite),
                  mask.side > 0, maskAsset != nil else { return false }
        }
        if let core = faceCore {
            guard [core.x, core.y, core.radiusX, core.radiusY].allSatisfy(\.isFinite),
                  core.radiusX > 0, core.radiusY > 0 else { return false }
        }
        if let minimum = bodyClipMinY {
            guard minimum.isFinite, minimum >= bodyY, minimum < bodyY + bodyHeight else { return false }
        }
        if headOutline == .kianaHead {
            guard let minimum = bodyClipMinY,
                  minimum >= CharacterKianaBustGeometry.bodyClipMinY else { return false }
        }
        return [motionLimits.headDegrees, motionLimits.bodyDegrees,
            motionLimits.headOffsetPixels, motionLimits.bodyOffsetPixels].allSatisfy { $0 >= 0 }
    }

    /// Exact ID/avatar gates never grant access to an agent. The authenticated
    /// server roster remains authoritative, including private Lilly.
    static func approved(stage: Bool, side: Double,
                         agentID: String?, avatarPath: String?) -> CharacterBustArtwork? {
        guard stage, side.isFinite, side >= 160,
              CharacterMotion.prepared(id: agentID, path: avatarPath) else { return nil }
        let artwork: CharacterBustArtwork
        switch agentID {
        case CharacterMotion.harleyID: artwork = harleyReview
        case CharacterMotion.kianaID: artwork = CharacterKianaBustGeometry.artwork
        case CharacterMotion.lillyID, CharacterMotion.skyleeLillyID: artwork = lillyReview
        case CharacterMotion.dellaID: artwork = CharacterDellaBustGeometry.artwork
        case CharacterMotion.witherspoonID: artwork = CharacterWitherspoonBustGeometry.artwork
        default: return nil
        }
        return artwork.isValid ? artwork : nil
    }

    /// Explicit manual review uses the same production geometry. The renderer
    /// also verifies bundled resources. Compact stages keep the full portrait, whose
    /// face remains easier to read at 84, 104 and 132 points.
    static func review(enabled: Bool, stage: Bool, side: Double,
                       agentID: String?, avatarPath: String?) -> CharacterBustArtwork? {
        guard enabled else { return nil }
        return approved(stage: stage, side: side, agentID: agentID, avatarPath: avatarPath)
    }

    private static let harleyReview = CharacterBustArtwork(
        bodyAsset: "CharacterHarleyBustBody", maskAsset: "CharacterHarleyBustMask",
        bodyX: 0, bodyY: 0, bodyWidth: 1024, bodyHeight: 1536,
        cropX: 242, cropY: 0, cropSide: 540,
        panelX: 243, panelY: 25, panelSide: 538,
        neckX: 512, neckY: 460, waistX: 512, waistY: 780,
        faceCore: CharacterBustFaceCore(x: 529, y: 284, radiusX: 81, radiusY: 96),
        headOutline: .harleyHead, accessoryOutlines: [], motionLimits: .harley)

    /// A close crop of the existing browser candidate. The full atlas panel
    /// remains 620/700 of the stage width; both original cats fit beside it.
    private static let lillyReview = CharacterBustArtwork(
        bodyAsset: "CharacterLillyBustBody", maskAsset: nil,
        bodyX: 0, bodyY: 170, bodyWidth: 1024, bodyHeight: 1024,
        cropX: 180, cropY: 0, cropSide: 700,
        panelX: 225, panelY: 40, panelSide: 620,
        neckX: 588, neckY: 496, waistX: 565, waistY: 950,
        faceCore: nil, headOutline: .lillyHead,
        accessoryOutlines: [.lillyLeftCat, .lillyRightCat], motionLimits: .lilly)
}

/// Angles are degrees; offsets are pixels in the original 1024-pixel world.
/// Native screenshot and device review are still required before approval.
struct CharacterBustPose {
    let headAngle: Double
    let bodyAngle: Double
    let headOffsetY: Double
    let bodyOffsetY: Double
}

enum CharacterBustMotion {
    /// Reuses the existing local performance clock with the small motion range
    /// reviewed in the web study. No independent audio or animation service.
    static func pose(_ figure: CharacterFigurePose,
                     limits: CharacterBustMotionLimits = .harley) -> CharacterBustPose {
        func fraction(_ value: Double, limit: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(1, max(-1, value / limit))
        }
        return CharacterBustPose(
            headAngle: fraction(figure.headAngle, limit: 7) * limits.headDegrees,
            bodyAngle: fraction(figure.torsoAngle, limit: 3) * limits.bodyDegrees,
            headOffsetY: fraction(figure.headNod, limit: 0.018) * limits.headOffsetPixels,
            bodyOffsetY: -fraction(figure.torsoLift, limit: 0.008) * limits.bodyOffsetPixels)
    }
}
