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
///
/// Part 119.3 (build 264), her word on 263: "take those categories out from
/// under the main 4... the textures and whatnot can go, and the description
/// in the name can go. Just say the name of the voice... sample longer
/// samples, if you're tired of hearing it you can move on... a toggle for the
/// voice you picked, basically controlling the temp, or delivery." So: no
/// Kind wheel — Who, then ONE wheel of every voice in that group, each row
/// just the voice's name (its tag word: "Flurry", "Cleat"); flicking plays
/// the FULL audition and moving on cuts it; and a Delivery control (Steady /
/// Balanced / Lively) saved per character on this phone and sent with every
/// clip that character speaks.
///
/// Sep 25 2026: the describer's narrator picker is this one too. It passes
/// its own voice list, shelves shown before the groups (My favourites,
/// Recently used, Good for describing), a note under "About this voice",
/// marks after names, auditions at her narration speed, and Add to
/// favourites / Make default (buttons for sight and Voice Control, the
/// Actions rotor for VoiceOver). All optional; the other screens pass none.
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
    /// Part 119.3: whose delivery this picker sets (an agent id). nil = no
    /// Delivery control on this surface.
    let deliveryAgentId: String?
    @State private var delivery: String = ""   // "" = the proxy's default

    /* Sep 25 2026, the describer's narrator picker. Every one of these is
     * optional and its default leaves the picker exactly as the other
     * screens have it: no shelves, no notes, no favourites, no default. */
    /// A short list shown as its own wheel before the four groups ("My
    /// favourites", "Recently used", "Good for describing"). Empty ones are skipped.
    struct Shelf: Hashable {
        let name: String
        let voices: [String]
    }
    let shelves: [Shelf]
    /// The voices to offer instead of the platform's list (the describer's own).
    let voiceList: [String]?
    /// Auditions at this pace (the API takes 0.5-1.5) and with this delivery
    /// when none is chosen here. nil = as before.
    let previewSpeed: Double?
    let previewDelivery: String?
    /// A sentence shown under "About this voice" (the describer's default and Fish notes).
    let noteFor: ((String) -> String?)?
    /// Words after a voice's name in the wheel and the search list ("your default, favourite").
    let markFor: ((String) -> String?)?
    let favorites: Set<String>
    let onToggleFavorite: ((String) async -> Void)?
    /// The voice already chosen as the default; "Make default" is not offered for it.
    let defaultVoice: String?
    let onMakeDefault: ((String) async -> Void)?
    @State private var narratorBusy = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice: VoiceService

    @State private var voices: [String] = []
    @State private var catalog: VoiceCatalog.Snapshot = .empty
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var search = ""
    @State private var previewing: String?
    @State private var previewTask: Task<Void, Never>?
    /// Part 129: "some of the voices are miscategorised" (a friend's word,
    /// relayed). The catalog's headings came from one machine ear on one
    /// neutral read; a person's ear beats it. One tap files the voice, its
    /// heading and what it actually sounds like on the feedback board, so
    /// the next catalog pass has receipts instead of a rumour.
    @State private var flagging = false
    @State private var flagBusy = false

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

    init(
        apiClient: KadeAPIClient,
        selection: Binding<String>,
        agentLines: [String] = [],
        defaultLabel: String? = nil,
        deliveryAgentId: String? = nil,
        voiceList: [String]? = nil,
        shelves: [Shelf] = [],
        previewSpeed: Double? = nil,
        previewDelivery: String? = nil,
        noteFor: ((String) -> String?)? = nil,
        markFor: ((String) -> String?)? = nil,
        favorites: Set<String> = [],
        onToggleFavorite: ((String) async -> Void)? = nil,
        defaultVoice: String? = nil,
        onMakeDefault: ((String) async -> Void)? = nil
    ) {
        self.apiClient = apiClient
        self._selection = selection
        self.agentLines = agentLines
        self.defaultLabel = defaultLabel
        self.deliveryAgentId = deliveryAgentId
        self.voiceList = voiceList
        self.shelves = shelves
        self.previewSpeed = previewSpeed
        self.previewDelivery = previewDelivery
        self.noteFor = noteFor
        self.markFor = markFor
        self.favorites = favorites
        self.onToggleFavorite = onToggleFavorite
        self.defaultVoice = defaultVoice
        self.onMakeDefault = onMakeDefault
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
        // The describer's shelves come first, so a favourite opens on My favourites.
        var shelved: [Who] = []
        for shelf in shelves {
            var kept: [String] = []
            for v in shelf.voices where present.contains(v) && !kept.contains(v) {
                kept.append(v)
            }
            if !kept.isEmpty {
                shelved.append(Who(name: shelf.name, kinds: [Kind(name: shelf.name, short: shelf.name, voices: kept)]))
            }
        }
        guard !catalog.categories.isEmpty else {
            return shelved + [Who(name: "All voices", kinds: [Kind(name: "All voices", short: "All voices", voices: voices)])]
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
        // Part 119.3: the kinds fold into ONE wheel per group, in the
        // catalog's order (which already runs bright -> husky -> seasoned).
        var out: [Who] = []
        for g in Self.groupOrder + [Self.moreGroup] {
            guard let ks = byGroup[g], !ks.isEmpty else { continue }
            let all = ks.flatMap { $0.voices }
            out.append(Who(name: g, kinds: [Kind(name: g, short: g, voices: all)]))
        }
        return shelved + out
    }

    /// The heading the wheel's voice is filed under. A shelf (My favourites)
    /// is not a heading, so the voice's own group is named instead.
    private var filedGroup: String {
        guard shelves.contains(where: { $0.name == group }) else { return group }
        for g in groups where !shelves.contains(where: { $0.name == g.name }) {
            if g.kinds.contains(where: { $0.voices.contains(wheelVoice) }) { return g.name }
        }
        return group
    }

    /// The voice's name as the wheel and the search list show it, with the
    /// describer's marks after it: "Flint (your default, favourite)".
    private func rowTitle(_ v: String) -> String {
        let name = catalog.name(of: v)
        guard let mark = markFor?(v), !mark.isEmpty else { return name }
        return "\(name) (\(mark))"
    }

    private func favoriteTitle(_ v: String) -> String {
        favorites.contains(v) ? "Remove from favourites" : "Add to favourites"
    }

    /// Whether the describer's "Make default" belongs to this voice.
    private func offersDefault(_ v: String) -> Bool {
        onMakeDefault != nil && !v.isEmpty && v != defaultVoice
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
                            : "Picks the voice the wheel is on: \(catalog.name(of: wheelVoice)).")
                }
            }
            .task { await load() }
            .onDisappear {
                previewTask?.cancel()
                voice.stopSpeaking()
            }
            // Only the describer passes favourites; nothing else ever changes them.
            .onChange(of: favorites) { _, _ in keepWheelOnVoice() }
        }
    }

    /// The wheels, her design. A plain scroll of controls, not a List, so the
    /// wheel pickers get their natural height. The pieces are their own views
    /// so no one body is too long for the type-checker.
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
                        whoPicker
                            .onChange(of: group) { _, _ in
                                guard !seeding else { return }
                                kind = activeGroup?.kinds.first?.name ?? ""
                                wheelVoice = wheelVoices.first ?? ""
                            }
                    }

                    voiceWheel

                    if !wheelVoice.isEmpty {
                        voiceDetails
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

    /// Her four groups as segments. With the describer's shelves there are
    /// too many for segments (every name would be cut off), so a menu.
    @ViewBuilder
    private var whoPicker: some View {
        if shelves.isEmpty {
            Picker("Who", selection: $group) {
                ForEach(groups, id: \.name) { g in
                    Text(g.name).tag(g.name)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Who")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kind of voice").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Picker("Kind of voice", selection: $group) {
                    ForEach(groups, id: \.name) { g in
                        Text(g.name).tag(g.name)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Kind of voice")
            }
        }
    }

    private var voiceWheel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voice").font(.footnote).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker("Voice", selection: $wheelVoice) {
                ForEach(wheelVoices, id: \.self) { v in
                    Text(rowTitle(v)).tag(v)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 170)
            .clipped()
            .accessibilityLabel("Voice")
            .accessibilityHint("Swipe up or down to flick through the voices. Each one plays its audition as you land on it; move on whenever you have heard enough. Done picks the one you are on.")
            .accessibilityActions {
                Button(previewing == wheelVoice ? "Stop" : "Play full audition") {
                    Task { await preview(wheelVoice, long: true) }
                }
                Button("Hear another sample") {
                    Task { await preview(wheelVoice, long: true, force: true) }
                }
                // The describer's two, last, so the actions above keep their places.
                if onToggleFavorite != nil, !wheelVoice.isEmpty {
                    Button(favoriteTitle(wheelVoice)) {
                        Task { await toggleFavorite(wheelVoice) }
                    }
                }
                if offersDefault(wheelVoice) {
                    Button("Make default") {
                        Task { await makeDefault(wheelVoice) }
                    }
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
                    // Part 119.3, her word: the long one. Moving on cuts it.
                    await preview(v, long: true, force: true)
                }
            }
        }
    }

    /// Under the wheel: about the voice (and the describer's note), Delivery,
    /// Play, the describer's narrator buttons, and Wrong section.
    private var voiceDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let about = catalog.describe[wheelVoice] {
                Text(about)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("About this voice: \(about)")
            }
            if let note = noteFor?(wheelVoice), !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if deliveryAgentId != nil {
                deliveryControl
            }
            HStack(spacing: 12) {
                Button {
                    Task { await preview(wheelVoice, long: true) }
                } label: {
                    Label(previewing == wheelVoice ? "Stop" : "Play full audition",
                          systemImage: previewing == wheelVoice ? "stop.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Plays the long audition in \(catalog.name(of: wheelVoice)).")
                if wheelVoice == current {
                    Label("Your current voice", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("This is your current voice.")
                }
            }
            if onToggleFavorite != nil || onMakeDefault != nil {
                narratorControls
            }
            flagButton
        }
    }

    private var deliveryControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Delivery").font(.footnote).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker("Delivery", selection: $delivery) {
                Text("Default").tag("")
                ForEach(VoiceService.deliveryOptions, id: \.value) { o in
                    Text(o.label).tag(o.value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Delivery")
            .accessibilityHint(deliveryAgentId == ReadingRoomPlayer.deliveryPreference ? "How much the reading voice varies its delivery. Saved for library reading on this phone. Default is Steady. The next audition and book passage use it." : "How much this voice varies its delivery. Steady is consistent, Lively has the most emotional range. Default is the platform setting. Saved for this character on this phone; the next audition and every reply use it.")
            .onChange(of: delivery) { _, v in
                guard !seeding, let id = deliveryAgentId else { return }
                VoiceService.setDelivery(v.isEmpty ? nil : v, forAgent: id)
                touched = true
                let spoken = VoiceService.deliveryOptions.first { $0.value == v }?.spoken ?? "Default delivery."
                UIAccessibility.post(notification: .announcement, argument: spoken)
                previewTask?.cancel()
                previewTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled, !wheelVoice.isEmpty else { return }
                    await preview(wheelVoice, long: true, force: true)
                }
            }
        }
    }

    /// The describer's two narrator actions, outside any row (a button inside
    /// a row is a VoiceOver problem). Hidden from VoiceOver only: the wheel's
    /// Actions rotor has both, and Voice Control still sees these buttons.
    private var narratorControls: some View {
        HStack(spacing: 12) {
            if onToggleFavorite != nil {
                Button {
                    Task { await toggleFavorite(wheelVoice) }
                } label: {
                    Label(favoriteTitle(wheelVoice), systemImage: favorites.contains(wheelVoice) ? "star.fill" : "star")
                }
                .buttonStyle(.bordered)
            }
            if offersDefault(wheelVoice) {
                Button {
                    Task { await makeDefault(wheelVoice) }
                } label: {
                    Label("Make default", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(narratorBusy)
        .accessibilityHidden(voiceOverOn)
    }

    private var flagButton: some View {
        Button {
            flagging = true
        } label: {
            Label("Wrong section?", systemImage: "flag")
                .font(.footnote)
        }
        .buttonStyle(.borderless)
        .disabled(flagBusy)
        .accessibilityHint("Tell Kade this voice is filed under the wrong heading. You say what it sounds like; the voice's name and its current heading go to the feedback board.")
        .confirmationDialog(
            "What does \(catalog.name(of: wheelVoice)) actually sound like?",
            isPresented: $flagging,
            titleVisibility: .visible
        ) {
            ForEach(Self.flagChoices, id: \.self) { choice in
                Button(choice) { Task { await flagVoice(as: choice) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is filed under \(filedGroup) right now.")
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
                UIAccessibility.post(notification: .announcement, argument: "\(catalog.name(of: v)) selected.")
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rowTitle(v))
                        Text(Self.spoken(v)).font(.footnote).foregroundStyle(.secondary)
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
            .accessibilityLabel("\(rowTitle(v)), \(Self.spoken(v))")
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
                // The describer's two, last, so the actions above keep their places.
                if onToggleFavorite != nil {
                    Button(favoriteTitle(v)) {
                        Task { await toggleFavorite(v) }
                    }
                }
                if offersDefault(v) {
                    Button("Make default") {
                        Task { await makeDefault(v) }
                    }
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
            UIAccessibility.post(notification: .announcement, argument: "\(catalog.name(of: wheelVoice)) selected.")
        }
        dismiss()
    }

    // MARK: - Load and preview

    private func load() async {
        isLoading = true
        loadFailed = false
        async let catalogTask = VoiceCatalog.shared.snapshot()
        let list: [String]
        if let voiceList, !voiceList.isEmpty {
            list = voiceList
        } else {
            list = await voice.availableVoices()
        }
        voices = list
        loadFailed = list.isEmpty
        catalog = await catalogTask
        // Seed the wheels from the stored pick, silently.
        seeding = true
        delivery = VoiceService.delivery(forAgent: deliveryAgentId) ?? ""
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

    static let flagChoices = ["A woman", "A man", "A kid or a teen", "A character or cartoon", "An older person", "A younger person"]

    /// File the miscategorisation as a plain feedback row (the same pile the
    /// Report-a-problem screen writes; Kade reads it on the feedback board).
    @MainActor private func flagVoice(as heard: String) async {
        let label = wheelVoice
        guard !label.isEmpty else { return }
        flagBusy = true
        defer { flagBusy = false }
        let name = catalog.name(of: label)
        let heading = filedGroup.isEmpty ? "(unknown heading)" : filedGroup
        do {
            try await FeedbackReportService(apiClient: apiClient).submit(
                category: "bug",
                subject: "Voice in the wrong section: \(name)",
                detail: "Filed from the voice picker on the phone. Voice: \(label). Filed under \"\(heading)\" — sounds like: \(heard.lowercased())."
            )
            Earcons.shared.play(.actionDone)
            UIAccessibility.post(notification: .announcement, argument: "Sent. \(name) reported as \(heard.lowercased()). Thank you.")
        } catch {
            Earcons.shared.play(.error)
            UIAccessibility.post(notification: .announcement, argument: "Couldn't send that report. \(error.localizedDescription)")
        }
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
        // No delivery chosen here: the surface's own (the describer's Steady), else the proxy's.
        let d = delivery.isEmpty ? previewDelivery : delivery
        if let sample = nextAgentSample(long: long) {
            await voice.previewVoice(v, sample: sample, delivery: d, speed: previewSpeed)
        } else if long, d != nil {
            // The long audition sentinel, with the delivery choice attached.
            await voice.previewVoice(v, sample: "Hi there. This is how I sound.", delivery: d, speed: previewSpeed)
        } else {
            await voice.previewVoice(v, long: long)
        }
        // playback finished (or failed) by the time previewVoice returns.
        if previewing == v { previewing = nil }
    }

    // MARK: - The describer's narrator actions

    /// The surface says what happened (it knows its own words); a second tap
    /// while one is saving is ignored.
    @MainActor private func toggleFavorite(_ v: String) async {
        guard let onToggleFavorite, !v.isEmpty, !narratorBusy else { return }
        narratorBusy = true
        defer { narratorBusy = false }
        await onToggleFavorite(v)
    }

    @MainActor private func makeDefault(_ v: String) async {
        guard let onMakeDefault, !v.isEmpty, !narratorBusy else { return }
        narratorBusy = true
        defer { narratorBusy = false }
        await onMakeDefault(v)
    }

    /// A favourite added or removed changes the shelves. The wheel stays on
    /// her voice, moving to the shelf or group that still holds it.
    private func keepWheelOnVoice() {
        guard !wheelVoice.isEmpty else { return }
        let groupGone = !groups.contains(where: { $0.name == group })
        guard groupGone || !wheelVoices.contains(wheelVoice) else { return }
        let keep = wheelVoice
        seeding = true
        point(at: keep)
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            seeding = false
        }
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
