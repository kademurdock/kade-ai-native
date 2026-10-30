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

    struct Category: Hashable, Sendable {
        let name: String
        let voices: [String]
    }

    struct Snapshot: Sendable {
        let categories: [Category]
        let renames: [String: String]
        let describe: [String: String]
        /// label -> its one-word tag ("flurry"). Part 119.3: the wheel shows
        /// this as the voice's NAME, her word ("just say the name of the voice").
        let tags: [String: String]
        var providers: [String: String] = [:]
        static let empty = Snapshot(categories: [], renames: [:], describe: [:], tags: [:])
        var isEmpty: Bool { categories.isEmpty && renames.isEmpty && describe.isEmpty }
    }

    /// The proxy's public catalog endpoint -- same host the fork's
    /// `speech.tts.openai.url` points at, same /voices.json the web client
    /// fetches cross-origin. Unauthenticated by design (labels, not audio).
    static let catalogURL = URL(string: "https://inworld-tts-proxy-production.up.railway.app/voices.json")!

    private var cached: Snapshot?
    private var inflight: Task<Snapshot, Never>?
    private var lastFailure: Date?
    private let fetchSnapshot: @Sendable () async -> Snapshot

    /// Oct 16 2026: speech only asks in the background, at most once a minute
    /// after a failed fetch, so a dead catalog never costs every sentence.
    static let speechRetryInterval: TimeInterval = 60

    init(fetchSnapshot: @escaping @Sendable () async -> Snapshot = { await VoiceCatalog.fetch() }) {
        self.fetchSnapshot = fetchSnapshot
    }

    /// The catalog, fetched at most once per launch (a failed fetch is NOT
    /// cached, so a picker opened later on a working connection gets it).
    func snapshot() async -> Snapshot {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        let fetch = fetchSnapshot
        let task = Task { await fetch() }
        inflight = task
        let snap = await task.value
        inflight = nil
        if !snap.isEmpty { cached = snap; lastFailure = nil } else { lastFailure = Date() }
        return snap
    }

    /// For speech, which must never wait on the 1.5 MB catalog: the provider
    /// map when it is already here, else nil (and the caller falls back).
    func cachedProviders() -> [String: String]? { cached?.providers }

    /// Today's label for a stored spelling ("Voice 69"), also for speech: the
    /// spelling as it stands when the catalog is not here yet.
    func cachedLabel(_ stored: String) -> String { cached?.displayLabel(stored) ?? stored }

    /// Start loading the catalog without waiting for it (launch, and speech
    /// that found nothing cached). A recent failure waits out the retry interval.
    func prefetch() {
        guard cached == nil, inflight == nil else { return }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < Self.speechRetryInterval { return }
        Task { _ = await self.snapshot() }
    }

    /// A catalog replacement can leave a session's cached headings referring
    /// to entirely different voices. Refresh once before showing a flat list.
    /// A failed refresh keeps the catalog the session already had.
    func snapshot(matching voices: [String]) async -> Snapshot {
        let snap = await snapshot()
        guard !voices.isEmpty, !snap.hasCategories(matching: voices) else { return snap }
        cached = nil
        let refreshed = await snapshot()
        if refreshed.isEmpty, !snap.isEmpty {
            cached = snap
            return snap
        }
        return refreshed
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
            let providers: [String: String]?
        }
        // The protocol policy honours the proxy's max-age=300 for repeat opens.
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
            tags: dto.tags ?? [:],
            providers: dto.providers ?? [:]
        )
    }
}

extension VoiceCatalog.Snapshot {
    func hasCategories(matching voices: [String]) -> Bool {
        let visible = Set(voices)
        return categories.contains { category in category.voices.contains { visible.contains($0) } }
    }

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
