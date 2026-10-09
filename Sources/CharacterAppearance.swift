import Foundation

/// On-demand descriptions of stable features shared by portrait and puppet art. The image
/// filename gate matters: creators can change avatars without leaving a
/// stale description attached to a new face. Expressions and motion are never
/// announced frame by frame.
enum CharacterAppearance {
    static func description(agentID: String?, avatarPath: String?) -> String? {
        guard CharacterMotion.prepared(id: agentID, path: avatarPath) else { return nil }
        switch CharacterMotion.rigID(agentID) {
        case CharacterMotion.angelID:
            return "Angel is a little girl cherub with chestnut curls, large hazel-brown eyes and rosy cheeks. She wears a fully sleeved ivory robe with a high pearl collar and tiny shimmering jewels. Soft white feather wings rise behind her shoulders, and a pearl-gold halo floats above her curls."
        case CharacterMotion.kianaID:
            return "Kiana is a young Black woman with long dark locs threaded with pink and dark heart beads. She wears small heart earrings, layered heart necklaces, and a cream off-shoulder knit sweater."
        case CharacterMotion.dellaID:
            return "Della is an older Black woman with short silver curls, small gold hoop earrings, and a warm expression. She wears a plum-purple cardigan over a cream blouse."
        case CharacterMotion.harleyID:
            return "Harley has swept-back dark hair, a short salt-and-pepper beard, and an easy smile. He wears faded blue denim over a white T-shirt."
        case CharacterMotion.lillyID:
            return "Lilly is illustrated, with long chestnut-brown hair, floral earrings and a lilac hoodie. Two orange tabby cats peek out near her shoulders."
        case CharacterMotion.witherspoonID:
            return "Witherspoon is a woman and a librarian, with loosely pinned gray-brown hair, oval glasses, and a calm expression. She wears a forest-green cardigan over a cream blouse with a small open-book pin."
        default:
            return nil
        }
    }
}
