import Foundation

/// Session 26 (Kade: "can we put a box to check or something, where people
/// can choose their default agent, whether it's one I created or one they
/// own. They might not all vibe with Kiana, but they at least have her to
/// start with"): the device-local "main agent" — who the app opens a chat
/// with at launch (see `HomeRoute.mainChat`), and who a brand-new chat is
/// pointed at instead of interrogating the user with the picker first
/// (see `ConversationDetailView`'s seeding block).
///
/// UserDefaults on purpose, not a server pref: it works offline, survives
/// relaunches, adds no new fork surface, and the phone lane already keeps
/// its own per-user default server-side (bridge registration). The name is
/// stored beside the id so Settings can SAY who your main agent is even
/// before the roster has loaded.
enum DefaultAgentStore {
    private static let idKey = "kade.defaultAgentId"
    private static let nameKey = "kade.defaultAgentName"

    /// Kade's standing rule: everyone starts with Kiana until they choose.
    static let fallbackName = "Kiana"

    static var storedId: String? {
        UserDefaults.standard.string(forKey: idKey)
    }

    static var storedName: String? {
        UserDefaults.standard.string(forKey: nameKey)
    }

    /// What Settings displays: the chosen name, or Kiana until they choose.
    static var displayName: String {
        storedName ?? fallbackName
    }

    static func set(_ agent: KadeAgent) {
        UserDefaults.standard.set(agent.id, forKey: idKey)
        UserDefaults.standard.set(agent.name, forKey: nameKey)
    }

    /// The id a new chat should start pointed at. The stored pick wins even
    /// before the roster loads (it worked last send); once a roster is in
    /// hand, a stale stored id (agent unpublished or deleted) falls back to
    /// Kiana by name, and only then to nil — at which point the picker is
    /// the true last resort.
    static func resolveId(in agents: [KadeAgent]) -> String? {
        if let id = storedId {
            if agents.isEmpty || agents.contains(where: { $0.id == id }) {
                return id
            }
        }
        return agents.first(where: {
            $0.name.caseInsensitiveCompare(fallbackName) == .orderedSame
        })?.id
    }
}
