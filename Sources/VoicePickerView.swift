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

    init(apiClient: KadeAPIClient, selection: Binding<String>) {
        self.apiClient = apiClient
        self._selection = selection
        _voice = StateObject(wrappedValue: VoiceService(client: apiClient))
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
                Button(previewing == v ? "Stop preview" : "Preview voice") {
                    Task { await preview(v) }
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

    private func preview(_ v: String) async {
        if previewing == v {
            voice.stopSpeaking()
            previewing = nil
            return
        }
        previewing = v
        await voice.previewVoice(v)
        // playback finished (or failed) by the time previewVoice returns.
        if previewing == v { previewing = nil }
    }
}
