import SwiftUI
import UIKit

/// Browse, preview, and pick a TTS voice from the full catalog
/// ("Voice 1"..."Voice 326", `GET /api/files/speech/tts/voices`). Session 21g
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
struct VoicePickerView: View {
    let apiClient: KadeAPIClient
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice: VoiceService

    @State private var voices: [String] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var search = ""
    @State private var previewing: String?

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
                        ForEach(filtered, id: \.self) { v in
                            voiceRow(v)
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
                    if v == selection {
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
            .accessibilityValue(v == selection ? "Selected" : "")
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
        isLoading = false
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
