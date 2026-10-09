import Foundation

/// Geometry from the existing Harley exact-atlas art study. The body is one
/// plate: sleeves and hands are not separately articulated. This is review
/// data, not an entry in the approved production figure registry.
struct CharacterBustArtwork {
    let bodyAsset: String
    let maskAsset: String
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
    let coreX: Double
    let coreY: Double
    let coreRadiusX: Double
    let coreRadiusY: Double

    /// The caller must also enforce DEBUG simulator compilation and resource
    /// availability. Compact stages keep the existing full portrait, whose
    /// face remains easier to read at 84, 104 and 132 points.
    static func review(enabled: Bool, stage: Bool, side: Double,
                       agentID: String?, avatarPath: String?) -> CharacterBustArtwork? {
        guard enabled, stage, side.isFinite, side >= 160,
              agentID == CharacterMotion.harleyID,
              CharacterMotion.prepared(id: agentID, path: avatarPath) else { return nil }
        return harleyReview
    }

    private static let harleyReview = CharacterBustArtwork(
        bodyAsset: "CharacterHarleyBustBody", maskAsset: "CharacterHarleyBustMask",
        bodyWidth: 1024, bodyHeight: 1536,
        cropX: 242, cropY: 0, cropSide: 540,
        panelX: 243, panelY: 25, panelSide: 538,
        neckX: 512, neckY: 460, waistX: 512, waistY: 780,
        coreX: 529, coreY: 284, coreRadiusX: 81, coreRadiusY: 96)
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
    static func pose(_ figure: CharacterFigurePose) -> CharacterBustPose {
        func fraction(_ value: Double, limit: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(1, max(-1, value / limit))
        }
        return CharacterBustPose(
            headAngle: fraction(figure.headAngle, limit: 7) * 2,
            bodyAngle: fraction(figure.torsoAngle, limit: 3) * 0.5,
            headOffsetY: fraction(figure.headNod, limit: 0.018) * 3,
            bodyOffsetY: -fraction(figure.torsoLift, limit: 0.008) * 2)
    }
}
