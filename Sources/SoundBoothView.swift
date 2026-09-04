import SwiftUI
import AVKit
import UniformTypeIdentifiers

// MARK: - The Sound Booth (Part 120, Sep 3 2026)
//
// HER SCREEN, in her own words (119.10): "all the settings and import and all
// that, but you write the stuff in the textbox right? And there's some button
// that will either generate your text idea into a full scenema script based on
// its formatting, or it can write a new one based on a description. Like, if I
// said, generate a blah blah blah, it could write something for me, but if I
// wanna write myself, I can, and can have enhanced formatting. Maybe even an
// easy and advanced mode."
//
// Part 120 added: the name (Sound Booth), Seed Audio as a second engine, and
// "it'll need to have working downloads and whatnot" plus "a way to import
// files."
//
// SHAPE, top to bottom:
//   1. ENGINE — Scenema (her own GPU, one actor performing, queued, ~2c/min)
//      or Seed Audio (fal, a whole scene with music and several voices,
//      seconds, ~19c/min). The hint says which one leaves the estate.
//   2. MODE — Easy / Advanced. Advanced reveals every engine field and lets
//      her edit the raw script.
//   3. WHAT SHOULD IT SAY — one big text box, then Voice (the existing wheel
//      picker, whose catalog sentence becomes the voice description), a
//      "describe a voice in words" field, an Import a clip row, and Mood.
//   4. Two buttons: "Turn my words into a script" keeps HER words and only
//      adds structure; "Write me one" drafts from a description.
//   5. THE SCRIPT — editable, with the plain-English read-back under it.
//   6. RENDER — says the cost out loud, then asks once more. Her standing
//      rule: the price is SAID before it runs.
//   7. LIBRARY — every piece, its takes, play, save to Files, re-render.
//
// NO LAZY CONTAINER ANYWHERE IN HERE. The Part-87 law: a lazy container
// allocates views as VoiceOver traverses them, and a state change during that
// traversal is the freeze race that cost builds 204-225. This screen writes
// state on a timer while VoiceOver may be reading it, which is exactly the
// third ingredient — so every list here is a plain VStack over a bounded set.

struct SoundBoothView: View {
    let apiClient: KadeAPIClient

    @StateObject private var service: SoundBoothService
    @Environment(\.dismiss) private var dismiss

    // What she is making
    @State private var engine = "scenema"
    @State private var mode = "easy"
    @State private var text = ""
    @State private var script = ""
    @State private var readback = ""
    @State private var voiceLabel = ""
    @State private var mood = ""
    /// "words" or "brief" — what the text box is holding. Drives the box's own
    /// label and the single button beneath it.
    @State private var inputMode = "words"
    /// Every engine setting, keyed by the guide's own key. Text and choice
    /// values are strings, numbers are their text, toggles are "1"/"". One
    /// dictionary, so a setting the guide adds tomorrow needs no new @State.
    @State private var values: [String: String] = [:]
    /// Imported clips, in order. Seed uses up to three (@Audio1–3); Scenema
    /// uses the first.
    @State private var clips: [(url: String, name: String)] = []

    // Live state
    @State private var health: SoundBoothHealth?
    @State private var guide: SoundBoothGuide?
    @State private var projects: [SoundBoothProject] = []
    @State private var estimate: SoundBoothEstimate?
    @State private var statusLine = "Loading the Sound Booth…"
    @State private var isWriting = false
    @State private var isRendering = false
    @State private var isImporting = false
    @State private var isSuggesting = false
    @State private var confirmArmed = false
    @State private var currentProjectId: String?
    @State private var currentJobId: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var savingTakeId: String?
    @State private var activeSheet: BoothSheet?
    @State private var showFileImporter = false
    @State private var showChooser = false
    @State private var showHowTo = false
    @State private var catalog: VoiceCatalog.Snapshot = .empty

    @AccessibilityFocusState private var focusStatus: Bool

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: SoundBoothService(apiClient: apiClient))
    }

    /// ONE sheet per view (the DescribeView rule).
    enum BoothSheet: Identifiable {
        case voicePicker
        case player(URL, String)
        case share(ShareItem)
        var id: String {
            switch self {
            case .voicePicker: return "voice"
            case .player(let u, _): return "player-\(u.absoluteString)"
            case .share(let i): return "share-\(i.id.uuidString)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusBlock
                engineSection
                modeSection
                writingSection
                scriptSection
                librarySection
            }
            .padding()
        }
        .navigationTitle("Sound Booth")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .voicePicker:
                VoicePickerView(
                    apiClient: apiClient,
                    selection: $voiceLabel,
                    defaultLabel: "No particular voice"
                )
            case .player(let url, let title):
                BoothPlayerSheet(url: url, title: title)
            case .share(let item):
                ShareSheet(item: item)
            }
        }
        /* Import a clip to clone. `.fileImporter` is the Files browser, which
         * is where a voice memo actually lives on this phone — and it reaches
         * iCloud Drive, Dropbox and anything else with a Files provider, so
         * "share from" and "import" are the same door here. */
        /* Part 121.3: the types each ENGINE can actually read, not a
         * wildcard. Scenema's README says reference audio is WAV or MP3;
         * M4A rides along because that is what a voice memo actually is.
         * Seed also takes OGG. An .ogg offered to Scenema is refused with a
         * sentence that says so, rather than rendering without the clone. */
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: engine == "seed"
                ? [.wav, .mp3, .mpeg4Audio, .init(filenameExtension: "ogg") ?? .audio]
                : [.wav, .mp3, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        .onChange(of: voiceLabel) { _, label in applyVoiceLabel(label) }
        /* An armed confirm is dropped the moment the script changes, so a
         * second tap can never spend on something she has since edited. Same
         * for a switched engine: the price is different, so the quote is. */
        .onChange(of: script) { _, _ in confirmArmed = false }
        .onChange(of: inputMode) { _, _ in
            if let m = currentInput { announce("\(m.boxLabel). \(m.boxHint)") }
        }
        .onChange(of: engine) { _, e in
            confirmArmed = false
            estimate = nil
            if let g = guide?.engines[e] {
                announce("\(g.name). \(g.tagline) \(g.where)")
            }
        }
        .onAppear { Task { await load() } }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    // MARK: - Status

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.primary)
            if isWriting || isRendering || currentJobId != nil {
                ProgressView().accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        /* ONE live region on this screen. Three polite regions fight and
         * VoiceOver drops all but one — the estimate, the render state and
         * every error all speak through this single line. */
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($focusStatus)
    }

    // MARK: - Engine (from the guide)

    private var currentEngine: SoundBoothGuide.Engine? { guide?.engines[engine] }
    private var currentInput: SoundBoothGuide.InputMode? {
        guide?.input?.modes.first { $0.key == inputMode }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine").font(.headline).accessibilityAddTraits(.isHeader)

            if let guide {
                /* Two DESCRIBED cards instead of a two-word segmented control.
                 * Her ask: "people will not know the difference." Each card
                 * says what it is, where it runs, what it costs, what it is
                 * for and not for — as one spoken element, then a button. */
                ForEach(["scenema", "seed"], id: \.self) { key in
                    if let g = guide.engines[key] {
                        Button {
                            KadeHaptics.press()
                            engine = key
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(g.name) — \(g.tagline)").font(.subheadline.bold())
                                    Spacer()
                                    if engine == key {
                                        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                                    }
                                }
                                Text(g.where).font(.caption)
                                Text(g.cost).font(.caption)
                                Text("Best for: \(g.bestFor.joined(separator: "; ")).").font(.caption)
                                Text("Not for: \(g.notFor.joined(separator: "; ")).").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(engine == key ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(engine == key ? Color.accentColor : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(g.spoken)
                        .accessibilityValue(engine == key ? "Selected" : "")
                        .accessibilityHint(engine == key ? "This is the engine you are using." : "Double tap to use this engine.")
                    }
                }

                DisclosureGroup(isExpanded: $showChooser) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(guide.chooser.answer).font(.footnote)
                        ForEach(guide.chooser.rules, id: \.self) { r in
                            Text("\(r.pick == "seed" ? "Seed Audio" : "Scenema") when \(r.when).")
                                .font(.footnote)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(guide.chooser.question).font(.subheadline.bold())
                }
                .accessibilityHint("Opens a short explanation of when to use which engine.")

                Button {
                    Task { await suggestEngine() }
                } label: {
                    HStack {
                        Label("Pick one for me from what I typed", systemImage: "wand.and.stars")
                        if isSuggesting { ProgressView().accessibilityHidden(true) }
                    }
                }
                .disabled(isSuggesting)
                .accessibilityHint("Reads what is in the box and says which engine fits, and why. Free.")
            } else {
                Picker("Engine", selection: $engine) {
                    Text("Scenema").tag("scenema")
                    Text("Seed Audio").tag("seed")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Mode", selection: $mode) {
                Text("Easy").tag("easy")
                Text("Advanced").tag("advanced")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Mode")
            .accessibilityHint(mode == "easy"
                ? "Easy. Type what you want said, pick a voice and a mood, and the script desk shapes it."
                : "Advanced. Every setting this engine has, and the raw script to edit yourself.")
        }
    }

    // MARK: - Writing

    /// Which settings Easy shows. Everything else waits behind Advanced.
    private static let easyKeys: [String: [String]] = [
        "scenema": ["voice_description", "gender", "reference_voice_url"],
        "seed": ["voice", "audio_urls"],
    ]

    private var writingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should it say?").font(.headline).accessibilityAddTraits(.isHeader)

            /* ⭐ THE FIX FOR THE REAL CONFUSION (Part 121.1, her question).
             * The two buttons were never the problem: ONE BOX MEANT TWO
             * THINGS. Typing "a bedtime story about a fox" and pressing
             * "Turn my words into a script" performs those words out loud —
             * it succeeds, it spends, and by ear nothing announces the
             * mistake. So the choice sits ABOVE the box, the box's own label
             * changes with it, and only ONE button exists at a time. */
            if let input = guide?.input {
                Text(input.question).font(.subheadline.bold())
                Picker(input.question, selection: $inputMode) {
                    ForEach(input.modes) { m in Text(m.label).tag(m.key) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(input.question)
                .accessibilityHint(currentInput?.boxHint ?? "")
            }

            if let m = currentInput {
                Text(m.boxLabel).font(.subheadline)
                Text(m.boxHint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }

            TextEditor(text: $text)
                .frame(minHeight: 140)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel(currentInput?.boxLabel ?? "What should it say")
                .accessibilityHint(currentInput?.boxHint ?? "Type the words you want performed.")

            if let g = currentEngine {
                DisclosureGroup(isExpanded: $showHowTo) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(g.howToWrite.enumerated()), id: \.offset) { _, tip in
                            Text(tip).font(.footnote)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("How to write for \(g.name)").font(.subheadline.bold())
                }
                .accessibilityHint("Opens the tips for getting a good result from this engine.")
            }

            if engine == "scenema" {
                Button {
                    KadeHaptics.press()
                    activeSheet = .voicePicker
                } label: {
                    HStack {
                        Text("Voice from the wheel")
                        Spacer()
                        Text(voiceLabel.isEmpty ? "Not picked" : catalog.name(of: voiceLabel))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Voice from the wheel, \(voiceLabel.isEmpty ? "not picked" : catalog.name(of: voiceLabel))")
                .accessibilityHint("Opens the voice wheel. The voice you land on is described in words for the engine, into the Describe the voice box below.")
            }

            if let g = currentEngine {
                let keys = Self.easyKeys[engine] ?? []
                let shown = g.settings.filter { mode == "advanced" || keys.contains($0.key) }
                ForEach(shown) { setting in
                    settingRow(setting)
                }
            }

            if let moods = health?.moods, !moods.isEmpty {
                Picker("Mood", selection: $mood) {
                    Text("No particular mood").tag("")
                    ForEach(moods) { m in Text(m.label).tag(m.key) }
                }
                .accessibilityLabel("Mood")
                .accessibilityHint("Becomes a note to the actor between your sentences — what the speaker is doing and feeling, never how the recording should sound.")
            }

            Button {
                KadeHaptics.press()
                Task { await makeScript(kind: inputMode == "brief" ? "write" : "format") }
            } label: {
                Text(currentInput?.button ?? "Turn my words into a script").frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .disabled(isWriting || isRendering)
            .accessibilityHint(currentInput?.buttonHint ?? "")
        }
    }

    /// One setting, rendered from the guide. The hint is the accessibility
    /// hint AND the visible footnote, so what a sighted person reads and what
    /// VoiceOver says are the same sentence.
    @ViewBuilder
    private func settingRow(_ st: SoundBoothGuide.Setting) -> some View {
        switch st.kind {
        case "text":
            VStack(alignment: .leading, spacing: 4) {
                Text(st.label).font(.subheadline)
                TextField(st.hint, text: binding(st.key), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityLabel(st.label)
                    .accessibilityHint(st.hint)
                Text(st.hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        case "choice":
            VStack(alignment: .leading, spacing: 4) {
                Picker(st.label, selection: binding(st.key, fallback: st.defaultString ?? "")) {
                    ForEach(st.options ?? [], id: \.self) { o in
                        Text(o.isEmpty ? "None" : o.replacingOccurrences(of: "_", with: " ").capitalized).tag(o)
                    }
                }
                .accessibilityLabel(st.label)
                .accessibilityHint(st.hint)
                Text(st.hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        case "toggle":
            VStack(alignment: .leading, spacing: 4) {
                Toggle(st.label, isOn: Binding(
                    get: { values[st.key] == "1" },
                    set: { values[st.key] = $0 ? "1" : "" }
                ))
                .accessibilityHint(st.hint)
                Text(st.hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        case "number":
            VStack(alignment: .leading, spacing: 4) {
                Text(st.label).font(.subheadline)
                TextField(st.defaultNumber.map { "normal is \($0.formatted())" } ?? "leave empty", text: binding(st.key))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(st.label)
                    .accessibilityHint(st.hint)
                Text(st.hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        case "clip":
            importRow(setting: st)
        default:
            EmptyView()
        }
    }

    private func binding(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { values[key] ?? fallback }, set: { values[key] = $0 })
    }

    private func importRow(setting st: SoundBoothGuide.Setting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                KadeHaptics.press()
                showFileImporter = true
            } label: {
                HStack {
                    Label(st.label, systemImage: "square.and.arrow.down")
                    Spacer()
                    if isImporting { ProgressView().accessibilityHidden(true) }
                }
            }
            .disabled(isImporting || clips.count >= st.clipMax)
            .accessibilityLabel(clips.isEmpty ? st.label : "\(st.label). \(clips.count) of \(st.clipMax) imported.")
            .accessibilityHint(st.hint + " Opens Files.")
            Text(st.hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)

            ForEach(Array(clips.prefix(st.clipMax).enumerated()), id: \.offset) { i, clip in
                HStack {
                    Text("\(st.clipMax > 1 ? "@Audio\(i + 1): " : "Cloning: ")\(clip.name)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    /* Her ask. Hearing the sample is the only way to know the
                     * right one is attached — believing it is not the same. */
                    Button {
                        guard let u = URL(string: clip.url) else { return }
                        activeSheet = .player(u, clip.name)
                    } label: {
                        Label("Play", systemImage: "play.circle")
                    }
                    .font(.footnote)
                    .accessibilityLabel("Play the imported clip, \(clip.name)")
                    Button("Remove") {
                        clips.remove(at: i)
                        announce("Clip removed.")
                    }
                    .font(.footnote)
                    .accessibilityLabel("Remove \(clip.name)")
                }
            }
        }
    }

    // MARK: - Script

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The script").font(.headline).accessibilityAddTraits(.isHeader)

            TextEditor(text: $script)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel("The script")
                .accessibilityHint("This is what gets performed. You can edit it here before rendering.")

            if !readback.isEmpty {
                Text(readback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("What you will hear. \(readback)")
            }

            if engine == "scenema" {
                Button {
                    KadeHaptics.press()
                    Task { await renderTapped(preview: true) }
                } label: {
                    Text("Hear this voice first — 15 seconds, about a penny").frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .disabled(isRendering || currentJobId != nil)
                .accessibilityHint("Renders one short sample line in the voice you described, so you can hear the actor before spending on the whole piece.")
            }

            Button {
                KadeHaptics.press()
                Task { await renderTapped(preview: false) }
            } label: {
                Text(confirmArmed ? "Render — confirm" : "Render").frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeHeroButtonStyle())
            .disabled(isRendering || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityHint(confirmArmed
                ? "Double tap again to spend it and start the render."
                : "Says what it will cost first, then asks once more before spending.")

            if let job = currentJobId {
                Button(role: .destructive) {
                    Task { await stopRender(job) }
                } label: {
                    Text("Stop this render").frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .accessibilityHint("Cancels the render that is running now.")
            }
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library").font(.headline).accessibilityAddTraits(.isHeader)

            if projects.isEmpty {
                Text("Nothing here yet. What you make will be saved here, and the audio also lands in My Creations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // Plain VStack, never a lazy one — see the Part 87 note above.
                VStack(spacing: 14) {
                    ForEach(projects) { p in
                        projectRow(p)
                    }
                }
            }
        }
    }

    private func projectRow(_ p: SoundBoothProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.title).font(.subheadline.bold())
                Text("\(p.engineLabel) · \(p.stateWord)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let r = p.readback, !r.isEmpty {
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(p.summary)

            let takes = p.takes ?? []
            if !takes.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(takes.enumerated()), id: \.element.id) { idx, take in
                        HStack(spacing: 10) {
                            Button {
                                guard let u = URL(string: take.url) else { return }
                                activeSheet = .player(u, p.title)
                            } label: {
                                Label("Play", systemImage: "play.circle")
                            }
                            .accessibilityLabel("Play \(take.label(number: takes.count - idx))")

                            Button {
                                Task { await save(take: take, title: p.title) }
                            } label: {
                                if savingTakeId == take.id {
                                    ProgressView().accessibilityHidden(true)
                                } else {
                                    Label("Save or share", systemImage: "square.and.arrow.up")
                                }
                            }
                            .disabled(savingTakeId != nil)
                            .accessibilityLabel("Save or share \(take.label(number: takes.count - idx))")
                            .accessibilityHint("Downloads it and opens the share sheet — Save to Files keeps a copy on this phone, or send it to someone.")
                            Spacer()
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Open in the booth") { openInBooth(p) }
                    .accessibilityHint("Loads this script, its voice and its settings back into the boxes above so you can change it and render again.")
                Spacer()
                Button(role: .destructive) {
                    Task { await remove(p) }
                } label: { Text("Remove") }
                .accessibilityLabel("Remove \(p.title)")
                .accessibilityHint("Takes the script out of the library. The recording itself stays in My Creations.")
            }
            .font(.footnote)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: - Actions

    private func announce(_ msg: String) {
        statusLine = msg
        UIAccessibility.post(notification: .announcement, argument: msg)
    }

    private func load() async {
        catalog = await VoiceCatalog.shared.snapshot()
        do {
            let h = try await service.health()
            health = h
            guide = h.guide
            let scenemaOK = h.engines["scenema"]?.configured ?? false
            let seedOK = h.engines["seed"]?.configured ?? false
            /* The first thing the screen says is the one-line answer to the
             * question she said people would have. */
            let fallback = "Scenema \(scenemaOK ? "is available" : "is not set up"), Seed Audio \(seedOK ? "is available" : "is not set up")."
            statusLine = "Ready. " + (h.guide?.chooser.answer ?? fallback)
        } catch {
            statusLine = (error as? LocalizedError)?.errorDescription ?? "Couldn't open the Sound Booth."
        }
        await loadProjects()
    }

    private func loadProjects() async {
        do {
            projects = try await service.projects()
            // A render that finished while the app was closed still needs
            // watching if it is somehow still open — pick it back up.
            if currentJobId == nil,
               let working = projects.first(where: { $0.isWorking }),
               let job = working.jobs?.last {
                currentJobId = job
                currentProjectId = working.id
                startPolling(job)
            }
        } catch {
            // A library that fails to load must not stamp on a render's
            // status line — this is the quiet one.
            projects = projects
        }
    }

    private func applyVoiceLabel(_ label: String) {
        guard !label.isEmpty else { return }
        /* The wheel picks a LABEL ("husky low middle-aged woman, Black
         * American · flurry"); Scenema wants a SENTENCE. The catalog's own
         * describe line is exactly that sentence, which is why the ear
         * pipeline's output is worth carrying here rather than inventing a
         * second vocabulary. Fall back to the label with the middle dot
         * spoken as a comma. */
        let described = catalog.describe[label] ?? label.replacingOccurrences(of: " · ", with: ", ")
        values["voice_description"] = described
        announce("Voice set to \(catalog.name(of: label)). \(described)")
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let err):
            announce("Couldn't open that file. \(err.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            defer { isImporting = false }
            /* A Files URL is security-scoped: without this pair the read
             * fails with a permission error that looks exactly like a missing
             * file. */
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 20 * 1024 * 1024 else {
                    announce("That clip is bigger than twenty megabytes. Ten to twenty seconds is all it needs.")
                    return
                }
                let imported = try await service.importReference(
                    data: data,
                    fileName: url.lastPathComponent,
                    mimeType: mimeType(for: url),
                    engine: engine
                )
                clips.append((url: imported.url, name: imported.name))
                Earcons.shared.play(.actionDone)
                KadeHaptics.success()
                announce(imported.spoken + (engine == "seed" ? " It is @Audio\(clips.count). Name it in the script." : ""))
            } catch {
                Earcons.shared.play(.error)
                announce((error as? LocalizedError)?.errorDescription ?? "Couldn't read that file. \(error.localizedDescription)")
            }
        }
    }

    private func mimeType(for url: URL) -> String {
        if let t = UTType(filenameExtension: url.pathExtension.lowercased()),
           let mime = t.preferredMIMEType {
            return mime
        }
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/m4a"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        default: return "audio/mpeg"
        }
    }

    /// Everything the guide's settings hold, typed for the wire. Toggles go
    /// only when on; numbers only when they parse and sit in range; empty
    /// strings are dropped. The guide's own min/max are the rails, so a value
    /// the engine cannot take never leaves the phone.
    private func collectedSettings() -> [String: Any] {
        var out: [String: Any] = [:]
        guard let g = currentEngine else { return out }
        for st in g.settings {
            let raw = (values[st.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch st.kind {
            case "toggle":
                if raw == "1" { out[st.key] = st.key == "audio_quality" ? "high" : true }
            case "number":
                guard let n = Double(raw) else { continue }
                if let lo = st.min, n < lo { continue }
                if let hi = st.max, n > hi { continue }
                out[st.key] = (st.key == "seed" || st.key == "pitch") ? Int(n.rounded()) : n
            case "clip":
                continue
            default:
                if !raw.isEmpty { out[st.key] = raw }
            }
        }
        if out["gender"] == nil { out["gender"] = "female" }
        if !clips.isEmpty {
            if engine == "seed" { out["audio_urls"] = clips.prefix(3).map { $0.url } }
            else { out["reference_voice_url"] = clips[0].url }
        }
        return out
    }

    private func suggestEngine() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { announce("Type something in the box first, then I can suggest."); return }
        isSuggesting = true
        defer { isSuggesting = false }
        do {
            let r = try await service.suggest(text: t)
            engine = r.engine
            // The engine change announces its own card; the reason follows.
            try? await Task.sleep(nanoseconds: 900_000_000)
            announce(r.reason + (r.sure ? "" : " Change it if that is not what you meant."))
        } catch {
            announce((error as? LocalizedError)?.errorDescription ?? "Couldn't suggest right now.")
        }
    }

    private func makeScript(kind: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 3 else {
            announce(kind == "write" ? "Say what you want made first." : "Type the words you want performed first.")
            return
        }
        isWriting = true
        defer { isWriting = false }
        announce(kind == "write" ? "Writing it…" : "Shaping your words…")
        let st = collectedSettings()
        do {
            let r = try await service.makeScript(
                engine: engine,
                mode: kind,
                text: body,
                voiceDescription: st["voice_description"] as? String,
                gender: (st["gender"] as? String) ?? "female",
                mood: mood.isEmpty ? nil : mood,
                scene: st["scene"] as? String,
                shot: st["shot"] as? String,
                clipURLs: clips.prefix(engine == "seed" ? 3 : 1).map { $0.url }
            )
            script = r.script
            readback = r.readback ?? ""
            estimate = r.estimate
            confirmArmed = false
            var parts: [String] = []
            /* The mismatch question speaks FIRST — it is the one thing that
             * can make everything after it wrong. */
            if let mm = r.mismatch, !mm.isEmpty { parts.append(mm) }
            if let rb = r.readback, !rb.isEmpty { parts.append(rb) }
            if let sp = r.estimate?.spoken { parts.append(sp) }
            if let p = r.problem { parts.append("One thing to fix first: \(p)") }
            Earcons.shared.play(.actionDone)
            announce(parts.isEmpty ? "Script ready." : parts.joined(separator: " "))
        } catch {
            Earcons.shared.play(.error)
            announce((error as? LocalizedError)?.errorDescription ?? "The script desk had trouble. Try again.")
        }
    }

    private func renderTapped(preview: Bool) async {
        let s = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let st = collectedSettings()
        if preview {
            guard !s.isEmpty || st["voice_description"] != nil else {
                announce("Describe the voice first, or write a script, so there is a voice to preview.")
                return
            }
        } else {
            guard !s.isEmpty else { return }
            /* HER STANDING RULE: the cost is SAID before it runs. First tap
             * says the price and arms; second tap spends. The armed state is
             * dropped whenever the script or engine changes. A preview costs
             * about a penny and says so on its own button, so it runs on one
             * tap. */
            if !confirmArmed {
                confirmArmed = true
                let spoken = estimate?.spoken ?? localEstimateSentence(for: s)
                /* ⭐ THE ELEVEN-CENT LESSON (Part 121.3): her first web render
                 * was quoted, confirmed and paid for with no clip attached,
                 * and she only found out by listening. The quote says which
                 * it is, every time, before the money moves. */
                let cloneLine = clips.isEmpty
                    ? " No clip attached, so the voice comes from your description."
                    : " Cloning \(clips.map { $0.name }.joined(separator: ", "))."
                announce("\(spoken)\(cloneLine) Press Render again to go ahead.")
                return
            }
        }
        confirmArmed = false
        isRendering = true
        defer { isRendering = false }
        var body: [String: Any] = st
        body["engine"] = engine
        body["mode"] = mode
        body["sourceText"] = text
        body["readback"] = readback
        if s.isEmpty, preview {
            let voice = (st["voice_description"] as? String ?? "A warm, clear adult voice.").replacingOccurrences(of: "\"", with: "&quot;")
            body["script"] = "<speak voice=\"\(voice)\" gender=\"\((st["gender"] as? String) ?? "female")\">Here is how I sound.</speak>"
        } else {
            body["script"] = s
        }
        if preview { body["preview"] = true }
        if let pid = currentProjectId { body["projectId"] = pid }
        announce(preview ? "Making a fifteen second sample…" : "Sending it…")
        do {
            let r = try await service.render(body: body)
            currentProjectId = r.projectId ?? currentProjectId
            if r.queued == true, let job = r.jobId {
                currentJobId = job
                Earcons.shared.play(.actionStart)
                announce((preview ? "Voice sample queued. " : "Queued. ") + (r.estimate?.spoken ?? "") + " The phone will buzz when it is ready, and this screen will say so.")
                startPolling(job)
            } else {
                Earcons.shared.play(.actionDone)
                KadeHaptics.success()
                let cents = max(1, Int(((r.costUSD ?? 0) * 100).rounded()))
                announce("Ready. \(r.seconds ?? 0) seconds of audio, about \(cents) cents. It is in your library below and in My Creations.")
                await loadProjects()
            }
        } catch {
            Earcons.shared.play(.error)
            KadeHaptics.error()
            announce((error as? LocalizedError)?.errorDescription ?? "That render could not start.")
        }
    }

    /// Only used when the server has not given us an estimate yet (she edited
    /// the script by hand and never pressed a script button). Same 2.6
    /// words-per-second constant the bridge and the fork use, so all three
    /// agree rather than each guessing differently.
    private func localEstimateSentence(for s: String) -> String {
        let stripped = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        let words = stripped.split(whereSeparator: { $0.isWhitespace }).count
        let secs = max(1, Int((Double(words) / 2.6).rounded()))
        let cents = engine == "seed"
            ? max(1, Int((Double(secs) / 60.0 * 18.75).rounded()))
            : max(1, Int((Double(secs) / 60.0 * 2.0).rounded()) + 2)
        // Part 126 (Sep 4 2026): the honest wait. A cold graphics card measured
        // up to seven minutes and a warm one under a minute (Part 122–123), so
        // "a couple of minutes" was a promise the booth could not keep either
        // way. The server's estimate names which case she is in; this is only
        // the fallback when it did not answer.
        let wait = engine == "seed" ? "a few seconds to make" : "under a minute if a card is awake, up to seven if one has to wake up"
        return "About \(secs) seconds of audio, \(wait), about \(cents) cents."
    }

    private func startPolling(_ jobId: String) {
        pollTask?.cancel()
        pollTask = Task {
            var last = ""
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                guard let st = try? await service.status(jobId: jobId) else { continue }
                ticks += 1
                // Part 126: speak on a state CHANGE, on the finish, and every
                // other poll (30 s) while unfinished — the web's rule since
                // Part 122. Silence between "queued" and "done" is what a
                // screen reader turns into "this app is broken", and the
                // server's line now counts the wait and names the give-up.
                if st.state != last || st.isFinished || ticks % 2 == 0 {
                    last = st.state
                    announce(st.spoken ?? st.state)
                }
                if st.isFinished {
                    if st.state == "done" {
                        Earcons.shared.play(.actionDone)
                        KadeHaptics.success()
                    } else {
                        Earcons.shared.play(.error)
                    }
                    currentJobId = nil
                    await loadProjects()
                    return
                }
            }
        }
    }

    private func stopRender(_ jobId: String) async {
        do {
            try await service.cancel(jobId: jobId)
            pollTask?.cancel(); pollTask = nil
            currentJobId = nil
            announce("Stopped.")
            await loadProjects()
        } catch {
            announce((error as? LocalizedError)?.errorDescription ?? "Couldn't stop that render.")
        }
    }

    private func save(take: SoundBoothTake, title: String) async {
        guard savingTakeId == nil else { return }
        savingTakeId = take.id
        defer { savingTakeId = nil }
        do {
            let fileURL = try await service.download(take: take, title: title)
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            activeSheet = .share(ShareItem(fileURL: fileURL))
        } catch {
            Earcons.shared.play(.error)
            KadeHaptics.error()
            announce((error as? LocalizedError)?.errorDescription ?? "Couldn't fetch that recording. Try again.")
        }
    }

    private func openInBooth(_ p: SoundBoothProject) {
        currentProjectId = p.id
        engine = p.engine
        mode = p.mode == "advanced" ? "advanced" : "easy"
        text = p.sourceText ?? ""
        script = p.script
        readback = p.readback ?? ""
        estimate = nil
        confirmArmed = false
        if let opts = p.options {
            for (k, v) in opts {
                if let t = v.asFieldText { values[k] = (k == "audio_quality" && t == "high") ? "1" : t }
            }
        }
        announce("Opened \(p.title). Change what you like and render again.")
        focusStatus = true
    }

    private func remove(_ p: SoundBoothProject) async {
        do {
            try await service.delete(projectId: p.id)
            if currentProjectId == p.id { currentProjectId = nil }
            announce("Removed \(p.title). The recording is still in My Creations.")
            await loadProjects()
        } catch {
            announce((error as? LocalizedError)?.errorDescription ?? "Couldn't remove that.")
        }
    }
}

/// Audio player sheet. AVKit's controls are properly labelled for VoiceOver
/// out of the box, which is why this is a VideoPlayer over an audio URL
/// rather than a hand-rolled transport — the same choice My Creations made.
private struct BoothPlayerSheet: View {
    let url: URL
    let title: String
    @State private var player = AVPlayer()

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    player.play()
                }
                .onDisappear { player.pause() }
                .accessibilityLabel("Player. \(title)")
        }
    }
}
