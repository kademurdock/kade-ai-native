import Foundation

/// Nov 12 2026 (platform audit, wave 2): one place for the app's own kill
/// switches. Each is a UserDefaults key that defaults ON; setting it to false
/// on a test device puts that feature back exactly as it was before. Every
/// feature here also has a server-side switch, so the usual undo is on the
/// server and these exist for a device that needs the old path alone.
enum KadeAppSwitches {
    private static func on(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    /// Phase 3 A1: spoken tool names from the stream's kade.toolLabels.
    static var toolLabels: Bool { on("kade.switch.toolLabels") }
    /// Phase 3 A2: saved replies read from /api/kade/messages with kade.readableText.
    static var readableText: Bool { on("kade.switch.readableText") }
    /// Phase 3 A3: request pacing numbers from /api/kade/client-config.
    static var clientConfig: Bool { on("kade.switch.clientConfig") }
    /// Decision 24: voice speed, delivery and fillers follow the account.
    static var voiceSync: Bool { on("kade.switch.voiceSync") }
    /// GW-6: chat requests say kadeLive when Hear replies is on.
    static var kadeLive: Bool { on("kade.switch.kadeLive") }
    /// Phase 4 pick 4: a dropped reply stream picks itself back up.
    static var streamResume: Bool { on("kade.switch.streamResume") }
    /// Phase 4 pick 2: listen to a described video while it is being made.
    static var listenAhead: Bool { on("kade.switch.listenAhead") }
    /// Nov 13 2026: the soft "still waiting" chime while a caught-up listener
    /// waits for the next section (also follows the Sound effects setting).
    static var waitingChime: Bool { on("kade.switch.waitingChime") }
}
