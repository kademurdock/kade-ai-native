import SwiftUI
import UIKit

/// Browse, preview, and pick a TTS voice from the full catalog
/// (`GET /api/files/speech/tts/voices`). Session 21g
/// (Kade: "needs to be a way to go through the voices in the agent builder").
///
/// Self-contained on purpose: it takes a `KadeAPIClient` and stands up its own
/// `VoiceService` for the catalog + preview, so it can be dropped into any
/// surface (Agent Builder today, a conversation/settings override next)
/// without depending on an injected environment object being present.
///
/// Blind-first: each row is ONE button that PICKS the voice, with a rotor
/// "Preview" action to hear it; the visible speaker button is the sighted
/// affordance and is hidden from VoiceOver, the same pattern the message row
/// uses so the Actions rotor never lists a thing twice.
///
/// July 23 2026 (Kade: "I'd like to have voices loosely categorised... so the
/// madness and chaos has some form and shape"): sections served by the TTS
/// proxy (/voices.json `categories`).
///
/// Part 119 (Sep 2 2026) — catch-up to the described catalog (Part 118):
///   * CATEGORY FIRST, her ask, the web builder is the spec: one "Category"
///     row at the top (23 described categories with counts, "All voices"
///     last), then the list for that category. Opens on the category that
///     holds the current pick, so the checkmark is on the first screen.
///   * A pick stored in an OLD spelling ("Voice 69", "Voice 340 (Beta)")
///     keeps its checkmark: the proxy's `renames` map says which described
///     label it became. Nothing is rewritten until she picks again — the old
///     spelling still speaks, the proxy resolves it forever.
///   * Each row carries the proxy's one-sentence `describe` as its VoiceOver
///     hint and as a second line for sighted eyes; search matches it too, so
///     "husky" or "storyteller" finds voices.
///   Fail-soft throughout: if /voices.json misses, the flat list renders
///   exactly as before, no category row. Searching always searches the WHOLE
///   catalog flat -- sections are a browsing aid, not a filter.
struct VoicePickerView: View {
    let apiClient: KadeAPIClient
    @Binding var selection: String
    /// Part 116 (build 260, proposal 6): the character's own quotable lines.
    /// Non-empty = previews read one of THESE (a different one each play)
    /// instead of the generic pooled script, so the voice is heard as "your
    /// agent's voice" — her words for why the long script fell short.
    let agentLines: [String]
    @State private var lastAgentLine: String?
    /// Build 261: what the empty pick means on THIS surface. In a
    /// conversation it is "the character's own voice" (clear my override);
    /// in the builder it is "no specific voice". nil = do not offer a row.
    let defaultLabel: String?
    /// Build 261: the last eight voices you auditioned, newest first, so
    /// comparing across hundreds stops being a memory test.
    @State private var recentlyHeard: [String] = RecentVoices.ids

    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice: VoiceService

    @State private var voices: [String] = []
    @State private var catalog: VoiceCatalog.Snapshot = .empty
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var search = ""
    @State private var previewing: String?
    /// The category she chose this open. nil = not chosen yet, so the picker
    /// derives one (the current pick's category, else the first).
    @State private var chosenCategory: String?

    /// One picker section. `name == nil` means "render flat, no header".
    struct VoiceGroup: Hashable {
        let name: String?
        let voices: [String]
    }

    /// The "All voices" choice in the category row. Last, as on the web.
    private static let allCategories = "__all__"
    /// Voices the served list carries that no category claims (a voice added
    /// after the last catalog build). Never hidden — they get their own group.
    private static let moreCategory = "Not yet described"

    init(apiClient: KadeAPIClient, selection: Binding<String>, agentLines: [String] = [], defaultLabel: String? = nil) {
        self.apiClient = apiClient
        self._selection = selection
        self.agentLines = agentLines
        self.defaultLabel = defaultLabel
        _voice = StateObject(wrappedValue: VoiceService(client: apiClient))
    }

    /// Mirror of the web builder's `extractAgentLines` (fork,
    /// AgentVoicePicker.tsx) so both surfaces pick the same kinds of lines:
    /// quoted spans 25–220 chars from the persona first (example exchanges
    /// are almost always in quotes), then sentences from the description.
    /// Anything that looks like a template, tag, or link is skipped.
    static func extractAgentLines(instructions: String?, description: String?) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func push(_ raw: String) {
            let t = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard t.count >= 25, t.count <= 220 else { return }
            if t.contains("{") || t.contains("}") || t.contains("<") || t.contains(">") || t.contains("http://") || t.contains("https://") { return }
            let k = t.lowercased()
            if !seen.contains(k) { seen.insert(k); out.append(t) }
        }
        let text = instructions ?? ""
        if let re = try? NSRegularExpression(pattern: "[\"\u{201C}]([^\"\u{201C}\u{201D}\n]{25,220})[\"\u{201D}]") {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                push(ns.substring(with: m.range(at: 1)))
            }
        }
        if out.isEmpty, let description, !description.isEmpty {
            var sentence = ""
            for ch in description {
                sentence.append(ch)
                if ".!?".contains(ch) { push(sentence); sentence = "" }
            }
            push(sentence)
        }
        return Array(out.prefix(40))
    }

    /// One of the agent's lines, never the same one twice in a row.
    private func nextAgentSample(long: Bool) -> String? {
        guard !agentLines.isEmpty else { return nil }
        var pool = agentLines
        if pool.count > 1, let last = lastAgentLine { pool.removeAll { $0 == last } }
        guard let first = pool.randomElement() else { return nil }
        lastAgentLine = first
        guard long, agentLines.count > 1 else { return first }
        // the long audition strings up to three different lines
        let rest = agentLines.filter { $0 != first }.shuffled().prefix(2)
        return ([first] + rest).joined(separator: " ")
    }

    // MARK: - Selection

    /// The stored pick mapped onto the served list (old spelling -> described
    /// label). nil when nothing is picked or the pick is unknown to the list.
    private var current: String? {
        catalog.normalize(selection, in: voices)
    }

    /// Selection match, tolerant of a stored old spelling: "Voice 69" checks
    /// the described row it became; "Voice 340 (Beta)" checks "Voice 340".
    private func isSelected(_ v: String) -> Bool {
        v == current
    }

    // MARK: - Categories

    /// The served categories, each trimmed to voices the list actually has,
    /// plus a trailing group for anything no category claims.
    private var groups: [VoiceGroup] {
        guard !catalog.categories.isEmpty else { return [] }
        let present = Set(voices)
        var seen = Set<String>()
        var out: [VoiceGroup] = []
        for c in catalog.categories {
            let vs = c.voices.filter { present.contains($0) && !seen.contains($0) }
            vs.forEach { seen.insert($0) }
            if !vs.isEmpty { out.append(VoiceGroup(name: c.name, voices: vs)) }
        }
        let rest = voices.filter { !seen.contains($0) }
        if !rest.isEmpty {
            out.append(VoiceGroup(name: Self.moreCategory, voices: rest))
        }
        return out
    }

    /// Which category the list is showing: her choice this open, else the
    /// one holding the current pick, else the first served category.
    private var activeCategory: String {
        if let chosenCategory { return chosenCategory }
        if let current, let g = groups.first(where: { $0.voices.contains(current) })?.name { return g }
        return groups.first?.name ?? Self.allCategories
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whole-catalog search: label OR the proxy's description ("husky",
    /// "British", "storyteller"). Served order, no numeric sort -- the
    /// described list is already in category order.
    private var searched: [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return voices }
        return voices.filter {
            $0.localizedCaseInsensitiveContains(q)
                || (catalog.describe[$0] ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// Sections for the current view state.
    ///   searching            -> one flat group of matches across the catalog
    ///   no categories served -> one flat group (the pre-July behaviour)
    ///   "All voices"         -> every category with its header
    ///   a category           -> that category alone, no header (the row above names it)
    private var sections: [VoiceGroup] {
        if isSearching { return [VoiceGroup(name: nil, voices: searched)] }
        let gs = groups
        guard !gs.isEmpty else { return [VoiceGroup(name: nil, voices: voices)] }
        let active = activeCategory
        if active == Self.allCategories { return gs }
        if let g = gs.first(where: { $0.name == active }) {
            return [VoiceGroup(name: nil, voices: g.voices)]
        }
        return gs
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading voices…")
                        .accessibilityLabel("Loading voices")
                } else if loadFailed {
                    ContentUnavailableView {
                        Text("Couldn't load voices")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    List {
                        if selection.isEmpty {
                            Text("No voice picked yet — this agent uses its default voice.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        // Build 261 (her ask: "no way to go back to the agent
                        // default voice"): the way back, first in the list.
                        if let defaultLabel {
                            Section {
                                Button {
                                    selection = ""
                                    UIAccessibility.post(notification: .announcement, argument: "\(defaultLabel). Your own pick is cleared.")
                                    dismiss()
                                } label: {
                                    HStack {
                                        Label(defaultLabel, systemImage: "arrow.uturn.backward")
                                        if selection.isEmpty {
                                            Spacer()
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(defaultLabel)
                                .accessibilityValue(selection.isEmpty ? "Selected" : "")
                                .accessibilityHint("Clears your own voice pick so this character speaks in the voice its creator chose.")
                            }
                        }
                        // Part 119: category first. A pushed list of the 23
                        // described categories with counts, "All voices" last.
                        // Hidden while searching -- search is whole-catalog.
                        if !isSearching, groups.count > 1 {
                            Section {
                                Picker(selection: Binding(
                                    get: { activeCategory },
                                    set: { chosenCategory = $0 }
                                )) {
                                    ForEach(groups, id: \.self) { g in
                                        Text("\(g.name ?? "") (\(g.voices.count))").tag(g.name ?? "")
                                    }
                                    Text("All voices (\(voices.count))").tag(Self.allCategories)
                                } label: {
                                    Text("Category")
                                }
                                .pickerStyle(.navigationLink)
                                .accessibilityHint("Opens the list of voice categories. Pick one and the voices below change to that category.")
                            } footer: {
                                Text(activeCategory == Self.allCategories
                                    ? "Every voice, grouped by category."
                                    : "Showing one category. Search finds voices in every category.")
                            }
                        }
                        if !isSearching, !recentlyHeard.isEmpty {
                            let recent = recentlyHeard.compactMap { catalog.normalize($0, in: voices) }
                            if !recent.isEmpty {
                                Section {
                                    ForEach(recent, id: \.self) { v in
                                        voiceRow(v)
                                    }
                                } header: {
                                    Text("Recently heard")
                                        .accessibilityAddTraits(.isHeader)
                                } footer: {
                                    Text("The last few voices you auditioned, newest first.")
                                }
                            }
                        }
                        ForEach(sections, id: \.self) { group in
                            if let name = group.name {
                                Section(name) {
                                    ForEach(group.voices, id: \.self) { v in
                                        voiceRow(v)
                                    }
                                }
                            } else {
                                Section {
                                    ForEach(group.voices, id: \.self) { v in
                                        voiceRow(v)
                                    }
                                } footer: {
                                    if isSearching && group.voices.isEmpty {
                                        Text("No voice matches that. Try a word about the sound — husky, bright, Southern, British, storyteller.")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $search, prompt: "Search voices")
            .navigationTitle("Choose a voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .onDisappear { voice.stopSpeaking() }
        }
    }

    private func voiceRow(_ v: String) -> some View {
        let about = catalog.describe[v]
        return HStack {
            Button {
                selection = v
                UIAccessibility.post(notification: .announcement, argument: "\(v) selected.")
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v)
                        if let about {
                            Text(about)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if isSelected(v) {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(v)
            .accessibilityValue(isSelected(v) ? "Selected" : "")
            // Part 119: the proxy's one sentence about the sound is the hint,
            // so a swipe through the list says what each voice IS before
            // the audition is asked for.
            .accessibilityHint(about ?? "Picks this voice.")
            .accessibilityActions {
                // Aug 6 2026 (her premium-native pass): BOTH lengths, named
                // honestly. Full audition = the steered four-mood monologue
                // (same one the web builder plays); quick = a two-second
                // hello for fast browsing.
                Button(previewing == v ? "Stop preview" : "Play full audition") {
                    Task { await preview(v, long: true) }
                }
                Button("Quick preview") {
                    Task { await preview(v, long: false) }
                }
                // Build 261: every sample is drawn fresh from the proxy's
                // bucket, so "another" is simply "again" -- named so a
                // listener knows it will be different.
                Button("Hear another sample") {
                    Task { await preview(v, long: true, force: true) }
                }
            }

            Button {
                Task { await preview(v) }
            } label: {
                Image(systemName: previewing == v ? "speaker.wave.2.fill" : "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .accessibilityHidden(true)
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        // Both fetches in flight together: the served list (authorised) and
        // the public catalog (categories, renames, describe).
        async let listTask = voice.availableVoices()
        async let catalogTask = VoiceCatalog.shared.snapshot()
        let list = await listTask
        voices = list
        loadFailed = list.isEmpty
        catalog = await catalogTask
        isLoading = false
    }

    private func preview(_ v: String, long: Bool = true, force: Bool = false) async {
        if previewing == v, long, !force {
            voice.stopSpeaking()
            previewing = nil
            return
        }
        if force { voice.stopSpeaking() }
        RecentVoices.record(v)
        recentlyHeard = RecentVoices.ids
        previewing = v
        if let sample = nextAgentSample(long: long) {
            await voice.previewVoice(v, sample: sample)
        } else {
            await voice.previewVoice(v, long: long)
        }
        // playback finished (or failed) by the time previewVoice returns.
        if previewing == v { previewing = nil }
    }
}


/// Build 261: the last eight voices auditioned on this device, newest first.
/// Same shape as `RecentAgents` in AgentPickerView.
enum RecentVoices {
    private static let key = "kade.recentVoiceLabels"
    private static let maxEntries = 8

    static var ids: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ label: String) {
        var current = ids
        current.removeAll { $0 == label }
        current.insert(label, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        UserDefaults.standard.set(current, forKey: key)
    }
}
