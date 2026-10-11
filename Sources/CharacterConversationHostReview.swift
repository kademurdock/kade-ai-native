import SwiftUI
import UIKit

/// Recognizes bundled conversation artwork; the authenticated roster still
/// decides which characters a person can talk to. Host and portrait reserve
/// the same tall frame only when the exact identity, assets and room agree.
enum CharacterConversationHostReview {
    private enum Resources {
        // Static properties initialize independently, after the exact identity
        // gate. Opening Kiana never decodes the other characters' atlas packs.
        static let kiana = CharacterConversationHostReview.present(CharacterMotion.kianaID, CharacterMotion.kianaFile)
        static let harley = CharacterConversationHostReview.present(CharacterMotion.harleyID, CharacterMotion.harleyFile)
        static let lilly = CharacterConversationHostReview.present(CharacterMotion.lillyID, CharacterMotion.lillyFile)
        static let witherspoon = CharacterConversationHostReview.present(CharacterMotion.witherspoonID, CharacterMotion.witherspoonFile)
    }
    private static func present(_ id: String, _ file: String) -> Bool {
        guard let artwork = CharacterConversationBodyArtwork.approved(stage: true,
            side: 208, agentID: id, avatarPath: "/images/" + file) else { return false }
        return artwork.requiredAssets.allSatisfy { UIImage(named: $0) != nil }
    }

    static func available(enabled: Bool, stage: Bool = true, side: Double = 208,
                          agentID: String?, avatarPath: String?) -> Bool {
        guard enabled else { return false }
        if agentID == CharacterMotion.dellaID {
            return CharacterDellaHostReview.available(enabled: enabled, stage: stage,
                side: side, agentID: agentID, avatarPath: avatarPath)
        }
        guard let artwork = CharacterConversationBodyArtwork.approved(stage: stage, side: side,
            agentID: agentID, avatarPath: avatarPath) else { return false }
        switch artwork.kind {
        case .kiana: return Resources.kiana
        case .harley: return Resources.harley
        case .lilly: return Resources.lilly
        case .witherspoon: return Resources.witherspoon
        }
    }
}
