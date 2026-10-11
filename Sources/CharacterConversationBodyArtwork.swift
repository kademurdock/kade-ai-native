import Foundation

/// Registration for an unchanged atlas head over a code-authored conversation
/// body. This describes rendering only; it never grants access to an agent.
struct CharacterConversationBodyArtwork {
    enum Kind: String, CaseIterable, Hashable { case kiana, harley, lilly, witherspoon }

    /// A cloth-only window in an immutable original asset. Sampling this region
    /// at draw time preserves its material without baking another bitmap, loading
    /// a generated torso or carrying the old plate's hands into the new rig.
    struct MaterialPatch {
        let asset: String
        let imageWidth: Double
        let imageHeight: Double
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var isValid: Bool {
            [imageWidth, imageHeight, x, y, width, height].allSatisfy(\.isFinite)
                && imageWidth > 0 && imageHeight > 0 && x >= 0 && y >= 0
                && width > 0 && height > 0 && x + width <= imageWidth
                && y + height <= imageHeight && !asset.isEmpty
        }
    }

    let kind: Kind
    let existingBust: CharacterBustArtwork
    let rigID: String
    let agentID: String

    var rendererKey: String { "conversation-upper-body-\(kind.rawValue)-v1" }
    var bodyAsset: String? { kind == .kiana ? nil : existingBust.bodyAsset }

    var fabric: MaterialPatch {
        switch kind {
        case .kiana:
            // The cream knitting at the far left of the original neutral panel.
            // The rectangle contains no locs, skin, face or atlas gutter.
            return MaterialPatch(asset: "CharacterKianaFaces", imageWidth: 1254, imageHeight: 1254,
                x: 8, y: 373, width: 36, height: 37)
        case .harley:
            return MaterialPatch(asset: "CharacterHarleyBustBody", imageWidth: 1024, imageHeight: 1536,
                x: 373, y: 833, width: 88, height: 125)
        case .lilly:
            return MaterialPatch(asset: "CharacterLillyBustBody", imageWidth: 1254, imageHeight: 1254,
                x: 605, y: 623, width: 93, height: 157)
        case .witherspoon:
            return MaterialPatch(asset: "CharacterWitherspoonBustBody", imageWidth: 1024, imageHeight: 1536,
                x: 275, y: 659, width: 101, height: 195)
        }
    }

    var shirtFabric: MaterialPatch? {
        guard kind == .witherspoon else { return nil }
        return MaterialPatch(asset: "CharacterWitherspoonBustBody", imageWidth: 1024, imageHeight: 1536,
            x: 442, y: 780, width: 47, height: 181)
    }

    /// Interior skin only: none of these rectangles contains a finger outline,
    /// cuff edge or separate anatomy. The new continuous hand supplies its shape.
    var skin: MaterialPatch {
        switch kind {
        case .kiana:
            return MaterialPatch(asset: "CharacterKianaFaces", imageWidth: 1254, imageHeight: 1254,
                x: 352, y: 314, width: 29, height: 38)
        case .harley:
            return MaterialPatch(asset: "CharacterHarleyBustBody", imageWidth: 1024, imageHeight: 1536,
                x: 759, y: 968, width: 44, height: 48)
        case .lilly:
            return MaterialPatch(asset: "CharacterLillyBustBody", imageWidth: 1254, imageHeight: 1254,
                x: 692, y: 1037, width: 45, height: 35)
        case .witherspoon:
            return MaterialPatch(asset: "CharacterWitherspoonBustBody", imageWidth: 1024, imageHeight: 1536,
                x: 180, y: 1140, width: 38, height: 40)
        }
    }

    /// Kiana's rejected supporting plate is deliberately absent. Her neckline,
    /// shoulders and locs are supplied by the exact original atlas head cut.
    var requiredAssets: [String] {
        let prefix: String
        switch kind {
        case .kiana: prefix = "CharacterKiana"
        case .harley: prefix = "CharacterHarley"
        case .lilly: prefix = "CharacterLilly"
        case .witherspoon: prefix = "CharacterWitherspoon"
        }
        var names = [prefix + "Faces", prefix + "Mouths"]
        if kind != .witherspoon { names.append(prefix + "Nuance") }
        if let bodyAsset { names.append(bodyAsset) }
        if let mask = existingBust.maskAsset { names.append(mask) }
        return names
    }

    func stageHeight(side: Double) -> Double {
        CharacterDellaArticulatedGeometry.stageHeight(side: side)
    }

    static func approved(stage: Bool, side: Double, agentID: String?,
                         avatarPath: String?) -> CharacterConversationBodyArtwork? {
        guard let agentID, let bust = CharacterBustArtwork.approved(stage: stage, side: side,
            agentID: agentID, avatarPath: avatarPath) else { return nil }
        let kind: Kind
        let rigID: String
        switch agentID {
        case CharacterMotion.kianaID: kind = .kiana; rigID = CharacterMotion.kianaID
        case CharacterMotion.harleyID: kind = .harley; rigID = CharacterMotion.harleyID
        case CharacterMotion.lillyID, CharacterMotion.skyleeLillyID:
            kind = .lilly; rigID = CharacterMotion.lillyID
        case CharacterMotion.witherspoonID:
            kind = .witherspoon; rigID = CharacterMotion.witherspoonID
        default: return nil
        }
        return CharacterConversationBodyArtwork(kind: kind, existingBust: bust, rigID: rigID, agentID: agentID)
    }
}
