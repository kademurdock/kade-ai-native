import Foundation

/// Part 119 (Sep 2 2026): the described voice catalog, in one place.
///
/// Part 118 turned the catalog from numbers ("Voice 69") into described
/// labels ("husky low middle-aged woman, Black American · flurry"). The
/// proxy's public `/voices.json` now carries, alongside the July `categories`:
///
///   `renames`   old spelling -> current label, 1,044 of them. A pick stored
///               before the change ("Voice 69", "Voice 340 (Beta)", "Birta")
///               still SPEAKS (the proxy resolves hidden aliases forever) but
///               is no longer in the served list, so without this map it lost
///               its checkmark in the picker and read as a number in the
///               agent editor.
///   `describe`  label -> one plain sentence about the sound. Read as the
///               row's hint and shown under the label.
///   `tags`      label -> its one-word tag ("flurry"). Not used yet.
///
/// Fetched once per launch and shared by every surface that shows a voice
/// label (picker, agent editor). Fail-soft: every accessor works on an empty
/// catalog and the picker then renders the flat list exactly as before.
///
/// Mirrors the fork's `hooks/Audio/useVoiceCatalog.ts` + `utils/voiceLabels.ts`
/// (`normalizeVoiceLabel`) so web and native agree on which stored spelling
/// selects which row.
actor VoiceCatalog {
    static let shared = VoiceCatalog()

    struct Category: Hashable {
        let name: String
        let voices: [String]
    }

    struct Snapshot {
        let categories: [Category]
        let renames: [String: String]
        let describe: [String: String]
        /// label -> its one-word tag ("flurry"). Part 119.3: the wheel shows
        /// this as the voice's NAME, her word ("just say the name of the voice").
        let tags: [String: String]
        static let empty = Snapshot(categories: [], renames: [:], describe: [:], tags: [:])
        var isEmpty: Bool { categories.isEmpty && renames.isEmpty && describe.isEmpty }
    }

    /// The proxy's public catalog endpoint -- same host the fork's
    /// `speech.tts.openai.url` points at, same /voices.json the web client
    /// fetches cross-origin. Unauthenticated by design (labels, not audio).
    static let catalogURL = URL(string: "https://inworld-tts-proxy-production.up.railway.app/voices.json")!

    private var cached: Snapshot?
    private var inflight: Task<Snapshot, Never>?

    /// The catalog, fetched at most once per launch (a failed fetch is NOT
    /// cached, so a picker opened later on a working connection gets it).
    func snapshot() async -> Snapshot {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        let task = Task { await Self.fetch() }
        inflight = task
        let snap = await task.value
        inflight = nil
        if !snap.isEmpty { cached = snap }
        return snap
    }

    private static func fetch() async -> Snapshot {
        struct DTO: Decodable {
            struct CategoryDTO: Decodable {
                let name: String
                let voices: [String]
            }
            let categories: [CategoryDTO]?
            let renames: [String: String]?
            let describe: [String: String]?
            let tags: [String: String]?
        }
        var req = URLRequest(url: catalogURL)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            return .empty
        }
        return Snapshot(
            categories: (dto.categories ?? []).map { Category(name: $0.name, voices: $0.voices) },
            renames: dto.renames ?? [:],
            describe: dto.describe ?? [:],
            tags: dto.tags ?? [:]
        )
    }
}

extension VoiceCatalog.Snapshot {
    /// Map a STORED value onto the served list, the same way the web does
    /// (`normalizeVoiceLabel`):
    ///   - already in the list -> itself
    ///   - an old spelling the proxy renamed -> the described label
    ///   - a beta-era spelling ("Voice 340 (Beta)") -> its graduated form
    ///   - anything else -> nil (caller keeps its own fallback)
    func normalize(_ stored: String, in voices: [String]) -> String? {
        let s = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if voices.contains(s) { return s }
        if let renamed = renames[s], voices.contains(renamed) { return renamed }
        let graduated = s.replacingOccurrences(of: " (Beta)", with: "")
        if graduated != s, voices.contains(graduated) { return graduated }
        if let renamed = renames[graduated], voices.contains(renamed) { return renamed }
        return nil
    }

    /// What to SHOW for a stored value when the served list is not at hand:
    /// the renamed label if the proxy knows one, else the value itself.
    func displayLabel(_ stored: String) -> String {
        let s = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if let renamed = renames[s] { return renamed }
        let graduated = s.replacingOccurrences(of: " (Beta)", with: "")
        if let renamed = renames[graduated] { return renamed }
        return s
    }

    /// The category a label is filed under, if any.
    func category(of label: String) -> String? {
        categories.first { $0.voices.contains(label) }?.name
    }

    /// The voice's NAME for the wheel: its tag word, capitalised ("Flurry").
    /// A voice with no tag yet (not described) shows its full label with the
    /// middle dot spoken as a comma.
    func name(of label: String) -> String {
        if let t = tags[label], !t.isEmpty { return t.prefix(1).uppercased() + t.dropFirst() }
        return label.replacingOccurrences(of: " · ", with: ", ")
    }
}
