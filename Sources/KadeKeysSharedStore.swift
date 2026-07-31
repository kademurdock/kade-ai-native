import Foundation

/// KADE KEYS phase 2 (July 28 2026) -- the main app's half of the shared
/// App Group container. The Prompt Library mirrors its first prompts
/// (title + live production text) in here; the keyboard extension reads
/// them back OFFLINE and types them. Storage only -- no fetching, no
/// pacing, no UI -- so the whole contract between the two processes is
/// one JSON blob under one key, and either side can evolve behind it.
///
/// OS rule worth remembering (Apple's own capability table): a keyboard
/// can only READ this container when "Allow Full Access" is on -- the
/// shared-container gate and the network gate are the same switch. The
/// keyboard's code still never touches the network; without the switch
/// it just falls back to its six built-in phrases.
enum KadeKeysSharedStore {
    static let appGroupId = "group.com.kademurdock.kadeai"
    static let promptsKey = "kadeKeys.prompts.v1"
    /// Enough for a keyboard surface without turning it into a scroll
    /// marathon under VoiceOver; the FULL library stays in the app.
    static let maxPrompts = 12

    struct SharedPrompt: Codable {
        let title: String
        let text: String
    }

    // ── Dictation handoff (July 31 2026, her pivot: "I just want a
    // deepgram dictate... I want the keyboard to be just like the
    // [transcribe] part of my app") ────────────────────────────────────
    static let dictationKey = "kadeKeys.dictation.v1"
    struct SharedDictation: Codable {
        let text: String
        let at: Date
    }

    /// The app writes here when a keyboard-initiated dictation completes;
    /// the keyboard types it on its next activation and clears it.
    static func writeDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let defaults = UserDefaults(suiteName: appGroupId),
              let data = try? JSONEncoder().encode(SharedDictation(text: trimmed, at: Date())) else {
            return
        }
        defaults.set(data, forKey: dictationKey)
    }

    /// Replaces the mirrored set wholesale (the library is the source of
    /// truth; partial merges could resurrect deleted prompts). Fail-soft:
    /// if the suite or encode is unavailable, the keyboard simply keeps
    /// whatever copy it last saw.
    static func write(_ prompts: [SharedPrompt]) {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = try? JSONEncoder().encode(Array(prompts.prefix(maxPrompts))) else {
            return
        }
        defaults.set(data, forKey: promptsKey)
    }
}
