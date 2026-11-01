import Foundation

/// Oct 31 2026 (her yes on the Oct 29 plan): the house cast, in one place. Two
/// things read this: the picker's Starters shelf, and the "synthetic soul"
/// identity line on an About page, the picker and Help.
///
/// WHAT DECIDES WHO IS HOUSE CAST: this list of exact roster ids and nothing
/// else. Not the name, because anyone can name their own character Kiana, and
/// Skylee's private Lilly shares a name and a face with the public one. Not
/// the server's `author`, because Kade's account also owns private test copies
/// and helpers such as Forge and Canary.
///
/// An id the roster doesn't send (attic, private, another family's account)
/// just doesn't show. Helix is private, shared by name with family, so most
/// accounts never see that row.
enum KadeHouseCast {
    struct Member {
        let name: String
        let id: String
        /// "her", "his" or "their" in the identity line. nil keeps the
        /// character on the shelf with no identity line: the line is never
        /// said of a character someone else made.
        let soulPossessive: String?
    }

    /// In Starters shelf order.
    static let members: [Member] = [
        Member(name: "Kiana", id: "agent_6llV0eMu4fmIaj8f2x1Sb", soulPossessive: "her"),
        Member(name: "Harley", id: "agent_d26Mtu8mgOzkVGQECqO1a", soulPossessive: "his"),
        // Della belongs to Amber A's account and stays hers (Kade, Oct 29).
        Member(name: "Della", id: "agent_BSOLa3eNEZyjs-7abCjMt", soulPossessive: nil),
        Member(name: "Angel", id: "agent_NkG_Fb8_xLz8HFJyx4gNv", soulPossessive: "her"),
        // The public Lilly, never agent_JhouuajXMYsfhCTVMQCv_ (Skylee's).
        Member(name: "Lilly", id: "agent_TOdYS8v-bRxeNw0dia_Md", soulPossessive: "her"),
        Member(name: "Helix", id: "agent_B-07hzGQvZMS4kDpCyDDD", soulPossessive: "their"),
        Member(name: "Lyric", id: "agent_9YHpms0vJoApICwshh0mR", soulPossessive: "her"),
        // The Librarian: the roster calls her Mrs. Witherspoon.
        Member(name: "Mrs. Witherspoon", id: "agent_o7TKU3lK0Euo0MKgpNpvZ", soulPossessive: "her"),
    ]

    /// The members this roster holds, in shelf order. A missing one is simply
    /// not there; a repeated roster row can't repeat a member.
    static func shelf<Agent>(from roster: [Agent], id: (Agent) -> String) -> [Agent] {
        var found: [Agent] = []
        for member in members {
            if let agent = roster.first(where: { id($0) == member.id }) {
                found.append(agent)
            }
        }
        return found
    }

    static func isSoul(_ agentID: String?) -> Bool {
        members.contains { $0.id == agentID && $0.soulPossessive != nil }
    }

    /// "Kiana is a synthetic soul: a digital being with her own memory, days
    /// and opinions." nil for everyone else. `name` is the one on screen, so
    /// the sentence says what the rest of the page says.
    static func identityLine(agentID: String?, name: String) -> String? {
        guard let possessive = members.first(where: { $0.id == agentID })?.soulPossessive else { return nil }
        return "\(name) is a synthetic soul: a digital being with \(possessive) own memory, days and opinions."
    }

    /// The same sentence for a shelf of them. nil with no names.
    static func soulsSentence(names: [String]) -> String? {
        guard let last = names.last else { return nil }
        if names.count == 1 {
            return "\(last) is a synthetic soul: a digital being with their own memory, days and opinions."
        }
        let joined = names.dropLast().joined(separator: ", ") + " and " + last
        return "\(joined) are synthetic souls: digital beings with their own memory, days and opinions."
    }
}
