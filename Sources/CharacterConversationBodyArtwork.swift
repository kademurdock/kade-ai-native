import Foundation

/// Registration for an unchanged atlas head over a code-authored conversation
/// body. This describes rendering only; it never grants access to an agent.
struct CharacterConversationBodyArtwork {
    enum Kind: String, CaseIterable, Hashable { case kiana, harley, lilly, witherspoon }

    let kind: Kind
    let existingBust: CharacterBustArtwork
    let rigID: String
    let agentID: String

    var rendererKey: String { "conversation-upper-body-\(kind.rawValue)-v1" }
    var bodyAsset: String? { kind == .kiana ? nil : existingBust.bodyAsset }

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
