import SwiftUI
import UIKit

/// Browse, preview, and pick a TTS voice from the full catalog
/// ("Voice 1"..., `GET /api/files/speech/tts/voices`). Session 21g
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
/// madness and chaos has some form and shape"): the list is now grouped into
/// loose sections served by the TTS proxy (/voices.json `categories` -- the
/// same public endpoint the web pickers read). Fail-soft: if the category
/// fetch misses, the flat numeric list renders exactly as before. Searching
/// always searches the WHOLE catalog flat -- sections are a browsing aid, not
/// a filter.
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
    @State private var categories: [VoiceGroup] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var search = ""
    @State private var previewing: String?

    /// One picker section. `name == nil` means "render flat, no header".
    struct VoiceGroup: Hashable {
        let name: String?
        let voices: [String]
    }

    /// The proxy's public catalog endpoint -- same host the fork's
    /// `speech.tts.openai.url` points at, same /voices.json the web client
    /// fetches cross-origin for audition text + categories. Unauthenticated
    /// by design (it serves labels, not audio).
    private static let catalogURL = URL(string: "https://inworld-tts-proxy-production.up.railway.app/voices.json")!

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

    /// Numeric-aware order ("Voice 2" before "Voice 10") and search filter.
    private var filtered: [String] {
        let base = voices.sorted { lhs, rhs in
            let ln = Int(lhs.filter(\.isNumber)) ?? 0
            let rn = Int(rhs.filter(\.isNumber)) ?? 0
            return ln == rn ? lhs < rhs : ln < rn
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    /// Sections for the current view state. Searching (or no category data)
    /// collapses to one flat unnamed group -- the pre-categories behavior.
    private var sections: [VoiceGroup] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.isEmpty, !categories.isEmpty else {
            return [VoiceGroup(name: nil, voices: filtered)]
        }
        let present = Set(voices)
        var seen = Set<String>()
        var out: [VoiceGroup] = []
        for group in categories {
            let vs = group.voices.filter { present.contains($0) && !seen.contains($0) }
            vs.forEach { seen.insert($0) }
            if !vs.isEmpty { out.append(VoiceGroup(name: group.name, voices: vs)) }
        }
        let rest = filtered.filter { !seen.contains($0) }
        if !rest.isEmpty {
            out.append(VoiceGroup(name: out.isEmpty ? nil : "More voices", voices: rest))
        }
        return out
    }

    /// Selection match, tolerant of a stored beta-era spelling
    /// ("Voice 340 (Beta)" selects "Voice 340" after the July 23 graduation).
    private func isSelected(_ v: String) -> Bool {
        v == selection || v == selection.replacingOccurrences(of: " (Beta)", with: "")
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
                        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !recentlyHeard.isEmpty {
                            Section {
                                ForEach(recentlyHeard.filter { voices.contains($0) }, id: \.self) { v in
                                    voiceRow(v)
                                }
                            } header: {
                                Text("Recently heard")
                                    .accessibilityAddTraits(.isHeader)
                            } footer: {
                                Text("The last few voices you auditioned, newest first.")
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
                                ForEach(group.voices, id: \.self) { v in
                                    voiceRow(v)
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
        HStack {
            Button {
                selection = v
                UIAccessibility.post(notification: .announcement, argument: "\(v) selected.")
                dismiss()
            } label: {
                HStack {
                    Text(v)
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
            .accessibilityHint("Picks this voice.")
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
        let list = await voice.availableVoices()
        voices = list
        loadFailed = list.isEmpty
        if !list.isEmpty {
            categories = await Self.fetchCategories()
        }
        isLoading = false
    }

    /// GET the proxy's /voices.json and pull `categories`. Any failure --
    /// network, shape, empty -- returns [] and the picker stays flat.
    private static func fetchCategories() async -> [VoiceGroup] {
        struct CatalogDTO: Decodable {
            struct CategoryDTO: Decodable {
                let name: String
                let voices: [String]
            }
            let categories: [CategoryDTO]?
        }
        var req = URLRequest(url: catalogURL)
        req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let dto = try? JSONDecoder().decode(CatalogDTO.self, from: data),
              let cats = dto.categories, !cats.isEmpty else {
            return []
        }
        return cats.map { VoiceGroup(name: $0.name, voices: $0.voices) }
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
