import SwiftUI
import UIKit

/// Pick a TTS voice from the described catalog
/// (`GET /api/files/speech/tts/voices` + the proxy's public `/voices.json`).
///
/// Self-contained on purpose: it takes a `KadeAPIClient` and stands up its own
/// `VoiceService` for the catalog + preview, so it can be dropped into any
/// surface (Agent Builder, a conversation's voice override) without depending
/// on an injected environment object being present.
///
/// Part 119.1 (Sep 2 2026) — HER DESIGN, after hearing build 262's list:
/// "a native picker, or multiple of them, that play the voice preview as you
/// flick through the voices. Like you could have grown men, grown women, kids
/// and teens, characters. Then because it's a picker, when you hit done that
/// would be the voice you pick. You could have a picker for the voices under
/// each category. Something to make it look smaller and cleaner and more
/// organised."
///
/// So, top to bottom:
///   1. "Use the character's own voice" — a switch (conversation surface) or
///      "No specific voice" (builder). On = the pickers fold away.
///   2. WHO — a segmented control: Women · Men · Kids and teens · Characters.
///   3. KIND — a wheel of that group's categories from the proxy ("bright and
///      high, young" … "from abroad"). Hidden when the group has one kind.
///   4. VOICE — a wheel of that category's voices. **Flicking it plays the
///      quick preview of the voice you land on** (debounced, so a fast spin
///      does not stack hellos). VoiceOver: the wheel is adjustable — swipe up
///      or down, hear the label, then hear the voice.
///   5. One sentence about the voice under the wheel, and a Play button for
///      the full audition (also on the rotor).
///   Done commits whatever the wheel shows. Cancel leaves the pick alone.
///
/// The search field is still there: type "husky" or "British" and the wheels
/// give way to a flat list of matches across every category (the descriptions
/// are searched too); tap one to pick it.
///
/// An old pick ("Voice 69") opens the wheels on the described label it became
/// (the proxy's `renames`); nothing is written back until Done. Fail-soft: no
/// catalog → one wheel of every voice in served order.
///
/// Spoken labels: the catalog writes "smooth grown man · cleat". VoiceOver
/// read the middle dot as "dot" (her note on 262), so every label this view
/// SHOWS or SPEAKS uses a comma instead. The stored value keeps the dot.
struct VoicePickerView: View {
    let apiClient: KadeAPIClient
    @Binding var selection: String
    /// Part 116 (build 260, proposal 6): the character's own quotable lines.
    /// Non-empty = previews read one of THESE (a different one each play)
    /// instead of the generic pooled script.
    let agentLines: [String]
    @State private var lastAgentLine: String?
    /// Build 261: what the empty pick means on THIS surface. In a
    /// conversation it is "the character's own voice" (clear my override);
    /// in the builder it is "no specific voice". nil = do not offer it.
    let defaultLabel: String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice: VoiceService

    @State private var voices: [String] = []
    @State private var catalog: VoiceCatalog.Snapshot = .empty
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var search = ""
    @State private var previewing: String?
    @State private var previewTask: Task<Void, Never>?

    // The wheels.
    @State private var useDefault = false
    @State private var group: String = ""
    @State private var kind: String = ""
    @State private var wheelVoice: String = ""
    /// True while the wheels are being set from the stored pick, so the seed
    /// does not play a preview or count as a change.
    @State private var seeding = true
    /// She moved something. Done writes only if this is true (or the switch
    /// moved), so opening and closing the sheet never picks a voice for her.
    @State private var touched = false

    struct Kind: Hashable {
        let name: String        // the proxy's full category name
        let short: String       // what the wheel shows: the name without its group
        let voices: [String]
    }
    struct Who: Hashable {          // not "Group": that name is SwiftUI's
        let name: String
        let kinds: [Kind]
    }

    /// Voices the served list carries that no category claims (a voice added
    /// after the last catalog build). Never hidden — they get their own group.
    private static let moreGroup = "More"
    private static let groupOrder = ["Women", "Men", "Kids and teens", "Characters"]

    init(apiClient: KadeAPIClient, selection: Binding<String>, agentLines: [String] = [], defaultLabel: String? = nil) {
        self.apiClient = apiClient
        self._selection = selection
        self.agentLines = agentLines
        self.defaultLabel = defaultLabel
        _voice = StateObject(wrappedValue: VoiceService(client: apiClient))
    }

    /// Mirror of the web builder's `extractAgentLines` (fork,
    /// AgentVoicePicker.tsx) so both surfaces pick the same kinds of lines:
    /// quoted spans 25–220 chars from the persona first, then sentences from
    /// the description. Anything that looks like a template, tag, or link is
    /// skipped.
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
        let rest = agentLines.filter { $0 != first }.shuffled().prefix(2)
        return ([first] + rest).joined(separator: " ")
    }

    // MARK: - Labels

    /// "smooth grown man · cleat" → "smooth grown man, cleat". What is shown
    /// and what VoiceOver says; the stored value keeps the dot.
    static func spoken(_ label: String) -> String {
        label.replacingOccurrences(of: " · ", with: ", ")
    }

    /// The stored pick mapped onto the served list (old spelling → described
    /// label). nil when nothing is picked or the pick is unknown to the list.
    private var current: String? {
        catalog.normalize(selection, in: voices)
    }

    // MARK: - Groups and kinds

    /// Her four groups, each holding the proxy's categories that start with
    /// its name, plus "More" for anything the list carries that no category
    /// claims. No catalog → one group, one kind, every voice in served order.
    private var groups: [Who] {
        let present = Set(voices)
        guard !catalog.categories.isEmpty else {
            return [Who(name: "All voices", kinds: [Kind(name: "All voices", short: "All voices", voices: voices)])]
        }
        var seen = Set<String>()
        var byGroup: [String: [Kind]] = [:]
        for c in catalog.categories {
            let vs = c.voices.filter { present.contains($0) && !seen.contains($0) }
            vs.forEach { seen.insert($0) }
            guard !vs.isEmpty else { continue }
            let g = Self.groupOrder.first { c.name == $0 || c.name.hasPrefix($0 + ",") || c.name.hasPrefix($0 + " ") } ?? Self.moreGroup
            var short = c.name
            if short.hasPrefix(g + ", ") { short = String(short.dropFirst(g.count + 2)) }
            byGroup[g, default: []].append(Kind(name: c.name, short: short, voices: vs))
        }
        let rest = voices.filter { !seen.contains($0) }
        if !rest.isEmpty {
            byGroup[Self.moreGroup, default: []].append(Kind(name: "Not yet described", short: "Not yet described", voices: rest))
        }
        var out: [Who] = []
        for g in Self.groupOrder + [Self.moreGroup] {
            if let ks = byGroup[g], !ks.isEmpty { out.append(Who(name: g, kinds: ks)) }
        }
        return out
    }

    private var activeGroup: Who? { groups.first { $0.name == group } ?? groups.first }
    private var activeKind: Kind? { activeGroup?.kinds.first { $0.name == kind } ?? activeGroup?.kinds.first }
    private var wheelVoices: [String] { activeKind?.voices ?? [] }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whole-catalog search: label OR the proxy's description.
    private var searched: [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return voices }
        return voices.filter {
            $0.localizedCaseInsensitiveContains(q)
                || (catalog.describe[$0] ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// Put the wheels on a voice: its group, its kind, itself.
    private func point(at v: String) {
        for g in groups {
            for k in g.kinds where k.voices.contains(v) {
                group = g.name
                kind = k.name
                wheelVoice = v
                return
            }
        }
    }

    // MARK: - Body

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
                } else if isSearching {
                    searchResults
                } else {
                    wheels
                }
            }
            .searchable(text: $search, prompt: "Search voices — husky, British, storyteller")
            .navigationTitle("Choose a voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit() }
                        .accessibilityHint(useDefault
                            ? "Clears your own pick."
                            : "Picks the voice the wheel is on: \(Self.spoken(wheelVoice)).")
                }
            }
            .task { await load() }
            .onDisappear {
                previewTask?.cancel()
                voice.stopSpeaking()
            }
        }
    }

    /// The wheels, her design. A plain scroll of controls, not a List, so the
    /// wheel pickers get their natural height.
    private var wheels: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let defaultLabel {
                    Toggle(isOn: $useDefault) {
                        Label(defaultLabel, systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityHint(useDefault
                        ? "On. This character speaks in the voice its creator chose. Turn off to pick your own."
                        : "Off. Turn on to clear your own pick.")
                    .onChange(of: useDefault) { _, on in
                        if !seeding { touched = true }
                        if on { previewTask?.cancel(); voice.stopSpeaking(); previewing = nil }
                    }
                }

                if !useDefault {
                    if groups.count > 1 {
                        Picker("Who", selection: $group) {
                            ForEach(groups, id: \.name) { g in
                                Text(g.name).tag(g.name)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Who")
                        .onChange(of: group) { _, _ in
                            guard !seeding else { return }
                            kind = activeGroup?.kinds.first?.name ?? ""
                            wheelVoice = wheelVoices.first ?? ""
                        }
                    }

                    if let g = activeGroup, g.kinds.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Kind").font(.footnote).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Picker("Kind", selection: $kind) {
                                ForEach(g.kinds, id: \.name) { k in
                                    Text("\(k.short) (\(k.voices.count))").tag(k.name)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 110)
                            .clipped()
                            .accessibilityLabel("Kind of voice")
                            .accessibilityHint("Swipe up or down to change the kind. The voice wheel below follows.")
                            .onChange(of: kind) { _, _ in
                                guard !seeding else { return }
                                wheelVoice = wheelVoices.first ?? ""
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Picker("Voice", selection: $wheelVoice) {
                            ForEach(wheelVoices, id: \.self) { v in
                                Text(Self.spoken(v)).tag(v)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 170)
                        .clipped()
                        .accessibilityLabel("Voice")
                        .accessibilityHint("Swipe up or down to flick through the voices. Each one says hello as you land on it. Done picks the one you are on.")
                        .accessibilityActions {
                            Button(previewing == wheelVoice ? "Stop" : "Play full audition") {
                                Task { await preview(wheelVoice, long: true) }
                            }
                            Button("Hear another sample") {
                                Task { await preview(wheelVoice, long: true, force: true) }
                            }
                        }
                        .onChange(of: wheelVoice) { _, v in
                            guard !seeding, !v.isEmpty else { return }
                            touched = true
                            // Debounced: a fast spin lands once, then speaks once.
                            previewTask?.cancel()
                            previewTask = Task {
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                guard !Task.isCancelled else { return }
                                await preview(v, long: false, force: true)
                            }
                        }
                    }

                    if !wheelVoice.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if let about = catalog.describe[wheelVoice] {
                                Text(about)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("About this voice: \(about)")
                            }
                            HStack(spacing: 12) {
                                Button {
                                    Task { await preview(wheelVoice, long: true) }
                                } label: {
                                    Label(previewing == wheelVoice ? "Stop" : "Play full audition",
                                          systemImage: previewing == wheelVoice ? "stop.fill" : "speaker.wave.2.fill")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Plays the long audition in \(Self.spoken(wheelVoice)).")
                                if wheelVoice == current {
                                    Label("Your current voice", systemImage: "checkmark.circle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel("This is your current voice.")
                                }
                            }
                        }
                    }
                } else if selection.isEmpty {
                    Text("No voice picked yet — this character uses its default voice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    /// Search: a flat list of matches across every category. Tap picks.
    private var searchResults: some View {
        List {
            Section {
                ForEach(searched, id: \.self) { v in
                    voiceRow(v)
                }
            } footer: {
                if searched.isEmpty {
                    Text("No voice matches that. Try a word about the sound — husky, bright, Southern, British, storyteller.")
                } else {
                    Text("\(searched.count) voices. Tap one to pick it; the Preview action on the rotor plays it.")
                }
            }
        }
        .listStyle(.plain)
    }

    private func voiceRow(_ v: String) -> some View {
        let about = catalog.describe[v]
        let isCurrent = v == current
        return HStack {
            Button {
                selection = v
                UIAccessibility.post(notification: .announcement, argument: "\(Self.spoken(v)) selected.")
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.spoken(v))
                        if let about {
                            Text(about).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if isCurrent {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            // The value below already says it; the symbol's
                            // own label made 262 say "Selected" twice.
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.spoken(v))
            .accessibilityValue(isCurrent ? "Selected" : "")
            .accessibilityHint(about ?? "Picks this voice.")
            .accessibilityActions {
                Button(previewing == v ? "Stop preview" : "Play full audition") {
                    Task { await preview(v, long: true) }
                }
                Button("Quick preview") {
                    Task { await preview(v, long: false) }
                }
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

    // MARK: - Commit

    private func commit() {
        previewTask?.cancel()
        voice.stopSpeaking()
        if useDefault {
            if !selection.isEmpty || touched {
                selection = ""
                UIAccessibility.post(notification: .announcement, argument: "\(defaultLabel ?? "Default voice"). Your own pick is cleared.")
            }
        } else if touched, !wheelVoice.isEmpty, wheelVoice != selection {
            selection = wheelVoice
            RecentVoices.record(wheelVoice)
            UIAccessibility.post(notification: .announcement, argument: "\(Self.spoken(wheelVoice)) selected.")
        }
        dismiss()
    }

    // MARK: - Load and preview

    private func load() async {
        isLoading = true
        loadFailed = false
        async let listTask = voice.availableVoices()
        async let catalogTask = VoiceCatalog.shared.snapshot()
        let list = await listTask
        voices = list
        loadFailed = list.isEmpty
        catalog = await catalogTask
        // Seed the wheels from the stored pick, silently.
        seeding = true
        useDefault = defaultLabel != nil && selection.isEmpty
        if let c = current {
            point(at: c)
        } else if let last = RecentVoices.ids.compactMap({ catalog.normalize($0, in: voices) }).first {
            point(at: last)      // the last voice she auditioned, a better start than row one
        } else {
            group = groups.first?.name ?? ""
            kind = activeGroup?.kinds.first?.name ?? ""
            wheelVoice = wheelVoices.first ?? ""
        }
        isLoading = false
        // Let the seeded values settle before onChange starts counting.
        try? await Task.sleep(nanoseconds: 100_000_000)
        seeding = false
    }

    private func preview(_ v: String, long: Bool = true, force: Bool = false) async {
        if previewing == v, long, !force {
            voice.stopSpeaking()
            previewing = nil
            return
        }
        if force { voice.stopSpeaking() }
        RecentVoices.record(v)
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
/// Same shape as `RecentAgents` in AgentPickerView. Part 119.1: also what
/// the wheels open on when nothing is picked yet.
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
