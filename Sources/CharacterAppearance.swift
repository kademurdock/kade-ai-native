import Foundation

/// On-demand descriptions of the current, prepared portrait art. The image
/// filename gate matters: creators can change avatars without leaving a
/// stale description attached to a new face. Figure packs will update this
/// copy when their final layered art is approved.
enum CharacterAppearance {
    static func description(agentID: String?, avatarPath: String?) -> String? {
        guard CharacterMotion.prepared(id: agentID, path: avatarPath) else { return nil }
        switch CharacterMotion.rigID(agentID) {
        case CharacterMotion.kianaID:
            return "In her current portrait, Kiana is a young Black woman with long dark locs threaded with pink and dark heart beads. She wears small heart earrings, layered heart necklaces, and a cream off-shoulder knit sweater. She smiles gently in a warm room."
        case CharacterMotion.dellaID:
            return "In her current portrait, Della is an older Black woman with short silver curls, small gold hoop earrings, and a warm expression. She wears a plum-purple cardigan over a cream blouse, against a teal background."
        case CharacterMotion.harleyID:
            return "In his current portrait, Harley has swept-back dark hair, a short salt-and-pepper beard, and an easy smile. He wears faded blue denim over a white T-shirt, with a warmly lit room behind him."
        case CharacterMotion.lillyID:
            return "In her current illustrated portrait, Lilly has long chestnut-brown hair and a lilac hoodie. She laughs with her eyes closed while two orange tabby cats peek out near her shoulders, against a glowing pink background."
        case CharacterMotion.witherspoonID:
            return "In her current portrait, Witherspoon has loosely pinned gray-brown hair, oval glasses, and a calm expression. She wears a forest-green cardigan over a cream blouse with a small open-book pin; bookshelves are behind her."
        default:
            return nil
        }
    }
}
