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
        /// Aug 4 2026: identifies the dictation SESSION this text came
        /// from, so the keyboard can refuse to type the same session
        /// twice. Scenario it exists for: the raw transcript is written
        /// immediately (safety net), she swipes back fast and the keyboard
        /// types it, THEN the auto-cleanup lands and overwrites the blob
        /// with the polished version -- without the id, her next keyboard
        /// activation would type the cleaned copy AGAIN into whatever
        /// field she's in. Optional so blobs written by older app builds
        /// still decode (they just skip the double-type guard).
        let id: String?
    }

    /// The app writes here when a keyboard-initiated dictation completes;
    /// the keyboard types it on its next activation and clears it. The
    /// same `takeId` is passed for a raw write and its later cleaned
    /// overwrite -- see `SharedDictation.id`.
    static func writeDictation(_ text: String, takeId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let defaults = UserDefaults(suiteName: appGroupId),
              let data = try? JSONEncoder().encode(SharedDictation(text: trimmed, at: Date(), id: takeId)) else {
            return
        }
        defaults.set(data, forKey: dictationKey)
    }

    // ── Custom quick phrases (Aug 4 2026, her call: "people should be
    // able to customise their own prompt library just like their own
    // dictionary... instead of canned crap") ───────────────────────────
    /// Mirror of the account's /api/kade/keyboard-phrases list. The main
    /// app refreshes it on the phrases screen and after every edit; the
    /// keyboard reads it offline (Full Access gate, same as everything
    /// else in this container) and falls back to its built-ins only when
    /// this has never been written or is empty.
    static let customPhrasesKey = "kadeKeys.customPhrases.v1"

    static func writeCustomPhrases(_ phrases: [String]) {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = try? JSONEncoder().encode(Array(phrases.prefix(12))) else {
            return
        }
        defaults.set(data, forKey: customPhrasesKey)
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
