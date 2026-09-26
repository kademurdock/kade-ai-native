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
//   0. (Sep 23 2026, redesign B8) WHAT DO YOU WANT TO MAKE — four plain
//      goals: a song, a scene or story with voices, music or sound effects,
//      reading something in a voice. The goal picks the engine and shows only
//      its form; the engine cards below now live under "Advanced: choose the
//      engine", and the last goal opens straight away next time.
//   1. ENGINE — AuK HQ (her own GPU, one actor performing, queued, ~2c/min)
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
    @State private var showFailedProjects = true
    private var visibleProjects: [SoundBoothProject] {
        projects.filter { showFailedProjects || !["failed", "cancelled"].contains($0.state) || !($0.takes ?? []).isEmpty || $0.hasRecoverableAudio == true }
    }
    @State private var writingUndo: (engine: String, script: String, lyrics: String)?
    private var isEffects: Bool { engine == "stable" }
    private var usesDirectPrompt: Bool { isMusic || isEffects }
    private var isMusic: Bool { engine == "lyria" || engine == "yue2" }
    @State private var engine = "scenema"
    @State private var mode = "easy"
    @State private var text = ""
    @State private var trackTitle = ""
    @State private var renameProject: SoundBoothProject?
    @State private var renameTitle = ""
    @State private var showRename = false
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
    /// Imported clips, in order. Seed uses up to three (@Audio1–3); AuK HQ
    /// uses the first.
    @State private var clips: [(url: String, name: String)] = []

    private struct WorkspaceDraft {
        var mode = "easy"
        var text = ""
        var title = ""
        var script = ""
        var readback = ""
        var voiceLabel = ""
        var mood = ""
        var inputMode = "words"
        var values: [String: String] = [:]
        var clips: [(url: String, name: String)] = []
        var importError = ""
        var projectId: String? = nil
        var newVoice = false
    }
    @State private var drafts: [String: WorkspaceDraft] = [:]
    @State private var showEngineDetails = false

    // What she wants to make (redesign B8, Sep 23 2026). The last goal and the
    // engine last used for it are remembered, so the booth opens straight into
    // them; `choosingGoal` is the front door with the four choices.
    @AppStorage("kade.soundBooth.goal") private var savedGoal = ""
    @AppStorage("kade.soundBooth.engine") private var savedEngine = ""
    @State private var choosingGoal = false
    @State private var showEngineChoice = false
    /// Set by a goal pick, so the engine card's own sentence does not talk
    /// over "Making a song. The form is below."
    @State private var quietEngineChange = false
    /// The goal announcement VoiceOver is still speaking. Focus moves to the
    /// form's first field once it has been heard, not on top of it.
    @State private var focusAfterAnnouncement: String?
    /// Nil while the four choices are showing.
    private var goal: BoothGoal? { choosingGoal ? nil : BoothGoal(rawValue: savedGoal) }

    // Live state
    @State private var health: SoundBoothHealth?
    @State private var guide: SoundBoothGuide?
    @State private var projects: [SoundBoothProject] = []
    @State private var estimate: SoundBoothEstimate?
    @State private var statusLine = "Loading the Sound Booth…"
    @State private var isTranscribing = false
    @State private var isWriting = false
    @State private var isRendering = false
    @State private var isImporting = false
    @State private var importError = ""
    @State private var isSuggesting = false
    @State private var confirmArmed = false
    @State private var showRenderConfirmation = false
    @State private var renderConfirmationMessage = ""
    @State private var quoteVersion = 0
    @State private var starterId = ""
    @State private var newVoice = false
    @State private var currentProjectId: String?
    @State private var currentJobId: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var savingTakeId: String?
    @State private var activeSheet: BoothSheet?
    @State private var showFileImporter = false
    /// Part 293: the media link (YouTube, another media site, or a direct
    /// audio or video file) being pasted for a YuE2 cover.
    @State private var mediaLink = ""
    /// True only while a media link is being brought in. Its own flag, so the
    /// link button says "Importing from the link…" and the Files button keeps
    /// its label (and each shows its own spinner) whichever import is running.
    @State private var isImportingLink = false
    @State private var showChooser = false
    @State private var showHowTo = false
    @State private var catalog: VoiceCatalog.Snapshot = .empty

    @AccessibilityFocusState private var focusStatus: Bool
    /// B8: where VoiceOver lands after the goal changes.
    @AccessibilityFocusState private var boothFocus: BoothFocus?

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: SoundBoothService(apiClient: apiClient))
        /* B8: open straight into the last goal, on the engine last used for it
         * (a YuE2 regular lands on YuE2, not back on Lyria), or on the four
         * choices the first time. */
        if let last = BoothGoal(rawValue: UserDefaults.standard.string(forKey: "kade.soundBooth.goal") ?? "") {
            let used = UserDefaults.standard.string(forKey: "kade.soundBooth.engine") ?? ""
            _engine = State(initialValue: last.engines.contains(used) ? used : last.engines[0])
        } else {
            _choosingGoal = State(initialValue: true)
        }
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

    /// B8: what she wants to make, in plain words. Each goal owns the engines
    /// that can make it, and the first is the one the booth picks: Lyria for a
    /// song (the guide's own "start with Lyria"), with YuE2 one tap away under
    /// Advanced; Seed Audio for several voices; Stable Audio, the booth's
    /// sound-effects lane, for music or sounds with no singing; AuK HQ for one
    /// voice. Every engine belongs to exactly one goal, so the heading above
    /// the form always matches the form.
    private enum BoothGoal: String, CaseIterable, Identifiable {
        case song, scene, sounds, reading
        var id: String { rawValue }

        var engines: [String] {
            switch self {
            case .song: return ["lyria", "yue2"]
            case .scene: return ["seed"]
            case .sounds: return ["stable"]
            case .reading: return ["scenema"]
            }
        }
        static func forEngine(_ key: String) -> BoothGoal {
            allCases.first { $0.engines.contains(key) } ?? .reading
        }
        var title: String {
            switch self {
            case .song: return "A song"
            case .scene: return "A scene or story with voices"
            case .sounds: return "Music or sound effects"
            case .reading: return "Reading something in a voice"
            }
        }
        /// Shown under the title; VoiceOver gets the same idea from the hint.
        var caption: String {
            switch self {
            case .song: return "Words and music, sung."
            case .scene: return "Several voices, music and sound effects."
            case .sounds: return "No singing."
            case .reading: return "One voice performing your words."
            }
        }
        var spokenLabel: String {
            switch self {
            case .song: return "Make a song"
            case .scene: return "Make a scene or story with voices"
            case .sounds: return "Make music or sound effects"
            case .reading: return "Read something in a voice"
            }
        }
        var hint: String {
            switch self {
            case .song: return "Opens the song form. Describe a song, or bring your own words, and a singer performs it with music."
            case .scene: return "Opens the scene form. Several people talk, with music and sound effects around them, like a radio play."
            case .sounds: return "Opens the sound form. Describe the music or sounds you want. Nobody sings or speaks."
            case .reading: return "Opens the reading form. Type your words, and one voice performs them with real acting."
            }
        }
        /// The first half of the announcement after a pick.
        var making: String {
            switch self {
            case .song: return "Making a song"
            case .scene: return "Making a scene or story with voices"
            case .sounds: return "Making music or sound effects"
            case .reading: return "Reading something in a voice"
            }
        }
        var symbol: String {
            switch self {
            case .song: return "music.mic"
            case .scene: return "theatermasks.fill"
            case .sounds: return "waveform"
            case .reading: return "book.fill"
            }
        }
        var tint: Color {
            switch self {
            case .song: return .pink
            case .scene: return .orange
            case .sounds: return .teal
            case .reading: return .purple
            }
        }
    }

    private enum BoothFocus: Hashable { case question, firstField }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                /* C4: the booth's painted banner. Decoration only (hidden from
                 * VoiceOver, never takes a tap); the gradient stands in until
                 * the picture is in the asset catalog. */
                KadePaintedHeader(imageName: "HeaderSoundBooth", symbol: "mic.and.signal.meter.fill", tint: .indigo, height: 110)
                if let goal { changeGoalButton(goal) } else { goalChoices }
                statusBlock
                if let goal {
                    goalHeader(goal)
                    scriptSection
                    if !usesDirectPrompt {
                        DisclosureGroup("Voice, references, and writing desk") {
                            modeSection
                            writingSection
                        }
                    }
                    DisclosureGroup("Starting points and new projects") { starterSection }
                } else {
                    // A render picked back up on the front door can still be stopped.
                    stopRenderButton
                }
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
                    selection: Binding(get: { voiceLabel }, set: { voiceLabel = $0; applyVoiceLabel($0) }),
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
         * wildcard. AuK HQ's README says reference audio is WAV or MP3;
         * M4A rides along because that is what a voice memo actually is.
         * Seed also takes OGG. An .ogg offered to AuK HQ is refused with a
         * sentence that says so, rather than rendering without the clone. */
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: engine == "seed" || engine == "yue2"
                ? [.wav, .mp3, .mpeg4Audio, .init(filenameExtension: "ogg") ?? .audio]
                : [.wav, .mp3, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        /* An armed confirm is dropped the moment the script changes, so a
         * second tap can never spend on something she has since edited. Same
         * for a switched engine: the price is different, so the quote is. */
        .onChange(of: text) { _, _ in invalidateQuote() }
        .onChange(of: mood) { _, _ in invalidateQuote() }
        .onChange(of: script) { _, _ in invalidateQuote() }
        .onChange(of: values) { _, _ in invalidateQuote() }
        .onChange(of: clips.map { $0.url }) { _, _ in invalidateQuote() }
        .onChange(of: inputMode) { _, _ in
            if engine != "lyria", let m = currentInput { announce("\(m.boxLabel). \(m.boxHint)") }
        }
        .onChange(of: engine) { _, e in
            invalidateQuote()
            /* B8: a goal pick announces itself ("Making a song…"); the engine
             * card's sentence would talk over it. Every other engine change
             * still says which engine and where it runs. */
            if quietEngineChange { quietEngineChange = false; return }
            if let g = guide?.engines[e] {
                announce("\(g.name). \(g.tagline) \(g.where)")
            }
        }
        /* B8: the goal announcement is heard in full, THEN VoiceOver lands on
         * the form's first field. Moving focus on top of the announcement would
         * cut it off. Without VoiceOver nothing is spoken and nothing moves. */
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) { note in
            guard let waiting = focusAfterAnnouncement,
                  (note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String) == waiting else { return }
            focusAfterAnnouncement = nil
            if goal != nil && activeSheet == nil { boothFocus = .firstField }
        }
        .alert("Generation stopped", isPresented: $showRenderConfirmation) {
            Button("OK", role: .cancel) { }
        } message: { Text(renderConfirmationMessage) }
        .alert("Rename track", isPresented: $showRename) {
            TextField("Track title", text: $renameTitle)
            Button("Save title") { Task { await saveTitle() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Up to 80 characters. This changes the saved title without generating audio.") }
        .onAppear { Task { await load() } }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    private func invalidateQuote() {
        confirmArmed = false
        estimate = nil
        quoteVersion += 1
    }

    private var workspaceBusy: Bool { isWriting || isRendering || isImporting || isImportingLink || currentJobId != nil }
    private var editorTitle: String { isEffects ? "Sound description" : isMusic ? "Music direction" : engine == "seed" ? "Scene script" : "Performance script" }
    private var generateLabel: String {
        if engine == "scenema" && values["auk_task"] == "edit" { return "Edit recording" }
        return isEffects ? "Generate sounds" : isMusic ? "Make music" : engine == "seed" ? "Generate scene" : "Perform script"
    }
    private var editorHint: String {
        if isEffects { return "Describe the foreground sound, quieter background layers, their distance and the space around them. Ask for no speech or music when you want only environmental sound." }
        if engine == "yue2" { return "Describe the style and singing voice. Add lyrics in song settings, or use Write my song idea. For a cover, import a source recording there. Its melody guides a new arrangement; it does not clone the singer." }
        if engine == "lyria" { return "Describe the genre, instruments, mood, singing voice if wanted, structure and length. Send this direction straight to Lyria. Put exact words to sing in Your own lyrics below." }
        if engine == "seed" { return "Describe the setting, sounds and each voice. Include exact dialogue and identify reference voices as @Audio1, @Audio2 or @Audio3." }
        return "Write only the words to perform. A reference clip supplies its voice and accent. To change the recording, use Edit; adding another accent is experimental. Use Seed Audio for sound effects."
    }

    private func selectEngine(_ next: String) {
        guard next != engine else { settleGoal(on: next); return }
        guard !workspaceBusy else { announce("Finish the current operation or stop the render before switching workspaces."); return }
        drafts[engine] = WorkspaceDraft(mode: mode, text: text, title: trackTitle, script: script, readback: readback, voiceLabel: voiceLabel, mood: mood, inputMode: inputMode, values: values, clips: clips, importError: importError, projectId: currentProjectId, newVoice: newVoice)
        let draft = drafts[next] ?? WorkspaceDraft()
        trackTitle = draft.title; engine = next; mode = draft.mode; text = draft.text; script = draft.script
        readback = draft.readback; voiceLabel = draft.voiceLabel; mood = draft.mood
        inputMode = draft.inputMode; values = draft.values; clips = draft.clips; importError = draft.importError
        currentProjectId = draft.projectId; newVoice = draft.newVoice
        starterId = ""; showHowTo = false; showEngineDetails = false
        invalidateQuote()
        settleGoal(on: next)
    }

    // MARK: - What do you want to make? (redesign B8, Sep 23 2026)

    /// The front door. A newcomer used to meet the heading "Engine" and five
    /// model names; now it is one plain question and four goals, each of which
    /// picks its engine. Every engine is still there, under Advanced in each
    /// goal's form.
    private var goalChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to make?")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($boothFocus, equals: .question)
            ForEach(BoothGoal.allCases) { g in
                Button { chooseGoal(g) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.title)
                            Text(g.caption).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: g.symbol)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeTileLabelStyle(tint: g.tint))
                .accessibilityLabel(g.spokenLabel)
                .accessibilityHint(g.hint)
            }
        }
    }

    /// Back to the four choices. Nothing is cleared: every engine keeps its
    /// draft while the screen is open, the same as switching engines.
    private func changeGoalButton(_ g: BoothGoal) -> some View {
        Button {
            KadeHaptics.press()
            focusAfterAnnouncement = nil
            choosingGoal = true
            Task {
                // One render pass for the question to exist (the LogbookView wait).
                try? await Task.sleep(nanoseconds: 350_000_000)
                if goal == nil && activeSheet == nil { boothFocus = .question }
            }
        } label: {
            Label("Change what you're making", systemImage: "arrow.uturn.left")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KadeCardButtonStyle())
        .disabled(workspaceBusy)
        .accessibilityLabel("Change what you're making")
        .accessibilityValue(g.title)
        .accessibilityHint(workspaceBusy
            ? "Available once the current job finishes or is stopped."
            : "Goes back to the four choices: a song, a scene or story with voices, music or sound effects, or reading something in a voice. Your work here is kept while this screen is open.")
    }

    /// The top of a goal's form: what she is making, which engine is making
    /// it, and the way to every other engine.
    private func goalHeader(_ g: BoothGoal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(g.title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text("\(g.caption) Made with \(Self.engineName(engine)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            engineSection
        }
    }

    /// A goal picks its engine (the booth's own pick for it, or the engine
    /// already in use when that one makes this too), shows only that form,
    /// says so, and hands VoiceOver the form's first field once the sentence
    /// has been heard (see the announcement hook on `body`).
    private func chooseGoal(_ g: BoothGoal) {
        let target = g.engines.contains(engine) ? engine : g.engines[0]
        guard target == engine || !workspaceBusy else {
            announce("Finish the current operation or stop the render before switching workspaces.")
            return
        }
        KadeHaptics.press()
        quietEngineChange = target != engine
        selectEngine(target)
        let spoken = "\(g.making). The form is below."
        focusAfterAnnouncement = spoken
        Task {
            // Let the choices leave and VoiceOver settle before speaking.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard goal == g else { focusAfterAnnouncement = nil; return }
            announce(spoken)
        }
    }

    /// The form on screen always belongs to the engine in use, so whatever
    /// switches the engine (a goal, an Advanced card, Pick one for me, Open in
    /// the booth, a cover) also settles which goal is showing, and remembers
    /// it for next time.
    private func settleGoal(on key: String) {
        savedGoal = BoothGoal.forEngine(key).rawValue
        savedEngine = key
        choosingGoal = false
    }

    private var starterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start something").font(.headline)
            Picker(isEffects ? "A sound starting point" : isMusic ? "A music starting point" : engine == "seed" ? "A scene starting point" : "A performance starting point", selection: $starterId) {
                Text("Choose a starting point").tag("")
                ForEach((guide?.starters ?? []).filter { $0.engine == engine }) { item in Text(item.title).tag(item.id) }
            }
            Button("Start a new project from this") {
                guard let starter = guide?.starters?.first(where: { $0.id == starterId }) else { return }
                currentProjectId = nil; values = [:]; clips = []; importError = ""; newVoice = false
                trackTitle = starter.title; script = starter.script; text = ""; readback = ""; mood = ""
                if engine == "lyria" { values["instrumental"] = starter.script.contains("Instrumental only, no vocals.") ? "1" : "" }
                invalidateQuote()
                announce("Starting \(starter.title). The starting point is ready to edit. Nothing has been generated.")
            }.disabled(starterId.isEmpty || workspaceBusy)
            Text("Free to load. These replace the current editor; finish or save your work first. Generation starts with one press; cost information is shown by the button.").font(.caption)
            Button("New blank project") {
                currentProjectId = nil; trackTitle = ""; script = ""; text = ""; readback = ""; mood = ""
                voiceLabel = ""; values = [:]; clips = []; importError = ""; newVoice = false
                invalidateQuote(); announce("New blank project. Other engine drafts are kept.")
            }.disabled(workspaceBusy)
            if engine == "scenema" {
            Button("Try a different designed voice next time") {
                newVoice = true; values.removeValue(forKey: "seed"); invalidateQuote()
                announce("The next preview or render will try a new voice. Imported clips still supply their own voice identity.")
            }.disabled(workspaceBusy)
            }
        }
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

    /// B8: every engine, one tap down. The goal already picked one; this is for
    /// choosing another, and for the side-by-side explanation. Pick one for me
    /// stays out in the open.
    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Advanced: choose the engine", isExpanded: $showEngineChoice) {
                engineCards.padding(.top, 6)
            }
            .accessibilityHint("Shows all five engines, with what each is for, where it runs and what it costs. What you chose to make has already picked one.")

            if guide != nil {
                Button {
                    Task { await suggestEngine() }
                } label: {
                    HStack {
                        Label("Pick one for me from what I typed", systemImage: "wand.and.stars")
                        if isSuggesting { ProgressView().accessibilityHidden(true) }
                    }
                }
                .disabled(isSuggesting || workspaceBusy)
                .accessibilityHint("Reads what is in the box and says which engine fits, and why. Free.")
            }
        }
    }

    private var engineCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let guide {
                /* Two DESCRIBED cards instead of a two-word segmented control.
                 * Her ask: "people will not know the difference." Each card
                 * says what it is, where it runs, what it costs, what it is
                 * for and not for — as one spoken element, then a button. */
                ForEach(["scenema", "lyria", "yue2", "stable", "seed"], id: \.self) { key in
                    if let g = guide.engines[key] {
                        Button {
                            KadeHaptics.press()
                            selectEngine(key)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(g.name) — \(g.tagline)").font(.subheadline.bold())
                                    Spacer()
                                    if engine == key {
                                        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                                    }
                                }

                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(engine == key ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(engine == key ? Color.accentColor : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .disabled(workspaceBusy)
                        .accessibilityLabel("\(g.name). \(g.tagline)")
                        .accessibilityValue(engine == key ? "Selected" : "")
                        .accessibilityHint(engine == key ? "This is the engine you are using." : "Double tap to use this engine.")
                    }
                }

                if let selected = currentEngine {
                    DisclosureGroup("About \(selected.name)", isExpanded: $showEngineDetails) {
                        Text(selected.where).font(.footnote)
                        Text(selected.cost).font(.footnote)
                        Text("Best for: \(selected.bestFor.joined(separator: "; ")).").font(.footnote)
                        Text("Not for: \(selected.notFor.joined(separator: "; ")).").font(.footnote)
                    }
                }
                Text("Each engine keeps its own draft while this screen is open.").font(.caption)
                DisclosureGroup(isExpanded: $showChooser) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(guide.chooser.answer).font(.footnote)
                        ForEach(guide.chooser.rules, id: \.self) { r in
                            Text("\(Self.engineName(r.pick)) when \(r.when).")
                                .font(.footnote)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(guide.chooser.question).font(.subheadline.bold())
                }
                .accessibilityHint("Opens a short explanation of when to use which engine.")
            } else {
                Picker("Engine", selection: Binding(get: { engine }, set: { selectEngine($0) })) {
                    Text("AuK HQ").tag("scenema")
                    Text("Seed Audio").tag("seed")
                    Text("Lyria").tag("lyria")
                    Text("YuE2").tag("yue2")
                    Text("Stable Audio").tag("stable")
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
        "scenema": ["auk_task", "instruction", "voice_description", "reference_voice_url", "gen_seconds"],
        "seed": ["voice", "audio_urls"],
        /* Lyria has three knobs and they all belong on the easy side: there is
         * nothing advanced about it, because the brief IS the control. */
        "lyria": ["instrumental", "lyrics", "keep_lyrics"],
    ]

    /// One place the three engines are named, so a fourth never needs hunting.
    static func engineName(_ key: String) -> String {
        switch key {
        case "seed": return "Seed Audio"
        case "lyria": return "Lyria"
        case "yue2": return "YuE2"
        case "stable": return "Stable Audio"
        default: return "AuK HQ"
        }
    }

    private var writingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(engine == "seed" ? "Build your scene" : "Prepare the performance").font(.headline).accessibilityAddTraits(.isHeader)

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
            DictationButton(apiClient: apiClient, text: $text, fieldName: "sound idea")

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
                if let recipes = g.recipes, !recipes.isEmpty {
                    DisclosureGroup("Voice design and editing ideas") {
                        Text("These fill in an editable example. They do not start a paid generation. Review the wording and change it to what you want.")
                            .font(.footnote)
                        ForEach(Array(recipes.enumerated()), id: \.offset) { _, recipe in
                            Button(recipe.label) {
                                values["auk_task"] = recipe.task
                                if recipe.task == "speech" { clips = [] }
                                values[recipe.task == "speech" ? "voice_description" : "instruction"] = recipe.text
                                invalidateQuote()
                                announce("Example filled in. Edit it to suit your idea. No generation started.")
                            }
                        }
                    }
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
                if st.key == "lyrics" {
                    TextEditor(text: binding(st.key))
                        .disabled(isTranscribing)
                        .frame(minHeight: 150)
                        .padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                        .accessibilityLabel(st.label)
                        .accessibilityHint(st.hint)
                } else {
                    TextField(st.hint, text: binding(st.key), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .accessibilityLabel(st.label)
                        .accessibilityHint(st.hint)
                }
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
                    get: { values[st.key].map { $0 == "1" } ?? st.defaultBool ?? false },
                    set: { values[st.key] = $0 ? "1" : "" }
                ))
                .accessibilityHint(st.hint)
                Text(st.hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        case "range":
            VStack(alignment: .leading, spacing: 4) {
                Text("\(st.label): \((Double(values[st.key] ?? "") ?? st.defaultNumber ?? 0).formatted())").font(.subheadline)
                Slider(value: Binding(
                    get: { Double(values[st.key] ?? "") ?? st.defaultNumber ?? st.min ?? 0 },
                    set: { values[st.key] = String($0) }
                ), in: (st.min ?? 0)...(st.max ?? 100), step: st.step ?? 1)
                .accessibilityLabel(st.label)
                .accessibilityValue((Double(values[st.key] ?? "") ?? st.defaultNumber ?? 0).formatted())
                .accessibilityHint(st.hint)
                Text(st.hint).font(.footnote).foregroundStyle(.secondary)
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
            .disabled(workspaceBusy || clips.count >= st.clipMax)
            .accessibilityLabel(clips.isEmpty ? st.label : "\(st.label). \(clips.count) of \(st.clipMax) imported.")
            .accessibilityHint(st.hint + " Opens Files.")
            Text(st.hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)

            if clips.count < st.clipMax, let row = mediaLinkRow(for: st) {
                linkImportRow(row.link, locked: row.locked)
            }

            if !importError.isEmpty {
                Text(importError + " Retry the import or discard this failed attempt before generating.")
                    .font(.footnote)
                Button("Discard failed import") {
                    importError = ""; invalidateQuote()
                    announce("Failed import discarded. Review the attached clips before generating.")
                }
            }
            if engine == "yue2" && !clips.isEmpty {
                Button("Transcribe reference lyrics") { Task { await transcribeLyrics() } }
                    .disabled(workspaceBusy || !importError.isEmpty)
                    .accessibilityHint("Tries to hear the sung words. Review and correct the draft; singing can be misheard. Undo writing change restores your previous lyrics. No music generation or credit deduction.")
                Text("Draft lyrics can contain wrong or missing words. Review before generating. This uses the transcription service and does not deduct credits.").font(.footnote)
            }
            ForEach(Array(clips.prefix(st.clipMax).enumerated()), id: \.offset) { i, clip in
                HStack {
                    Text(clipPrefix(max: st.clipMax, index: i) + clip.name)
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
                        guard !workspaceBusy else { return }
                        clips.remove(at: i)
                        announce("Clip removed.")
                    }
                    .font(.footnote)
                    .disabled(workspaceBusy)
                    .accessibilityLabel("Remove \(clip.name)")
                }
            }
        }
    }

    /// "@Audio2: " for Seed's numbered clips, "Covering: " for a YuE2 cover,
    /// "Cloning: " for an AuK voice.
    private func clipPrefix(max: Int, index: Int) -> String {
        if max > 1 { return "@Audio\(index + 1): " }
        return engine == "yue2" ? "Covering: " : "Cloning: "
    }

    /// Part 293, the Family feature pack: which media-link row the cover field
    /// gets. Live when the server sent `link` for this account. Greyed out,
    /// with the server's reason, when it sent `lockedLink` instead, or when a
    /// `link` says it is unavailable or the pack map says media links are off
    /// for this account. Nil only when the server offers links to nobody (its
    /// switch is off), so the row is never hidden from one person alone.
    private func mediaLinkRow(for st: SoundBoothGuide.Setting) -> (link: SoundBoothGuide.Setting.Link, locked: String?)? {
        if let live = st.link {
            if live.available == false || health?.features?.mediaLinks == false {
                return (live, live.locked ?? KadeFamilyFeatures.note)
            }
            return (live, nil)
        }
        if let greyed = st.lockedLink {
            return (greyed, greyed.locked ?? KadeFamilyFeatures.note)
        }
        return nil
    }

    /// Part 293: paste a media link for a YuE2 cover, beside the Files import.
    /// With `locked` set (no Family feature pack) the same row is drawn greyed
    /// out: the field, Paste and the import button are disabled, VoiceOver's
    /// hint on each says why, and the reason is also shown as text.
    private func linkImportRow(_ link: SoundBoothGuide.Setting.Link, locked: String?) -> some View {
        let empty = mediaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hint = (link.hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocked = locked != nil
        let reason: String = locked ?? ""
        let fieldHint: String = isLocked ? reason : (hint.isEmpty ? "A link to one song or video." : hint)
        let pasteHint: String = isLocked ? reason : "Puts the link you copied into the media link field."
        var buttonHint: String = "Brings in the sound from the link as the recording to cover. " + hint
        if empty { buttonHint = "Available once a link is in the media link field." }
        if isLocked { buttonHint = reason }
        return VStack(alignment: .leading, spacing: 6) {
            Text(link.label).font(.subheadline).accessibilityHidden(true)
            TextField("Paste a media link", text: $mediaLink)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { Task { await importMediaLink() } }
                .disabled(workspaceBusy || isLocked)
                .accessibilityLabel(link.label)
                .accessibilityHint(fieldHint)
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    let pasted = strings.first ?? ""
                    Task { @MainActor in pasteMediaLink(pasted, button: link.button) }
                }
                .disabled(workspaceBusy || isLocked)
                .accessibilityHint(pasteHint)
                Button {
                    KadeHaptics.press()
                    Task { await importMediaLink() }
                } label: {
                    HStack {
                        Text(isImportingLink ? "Importing from the link…" : link.button)
                        if isImportingLink { ProgressView().accessibilityHidden(true) }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(workspaceBusy || empty || isLocked)
                .accessibilityHint(buttonHint)
            }
            if isLocked {
                // The reason, visible too: a greyed-out box must say why.
                Text(reason).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            } else if !hint.isEmpty {
                Text(hint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private func pasteMediaLink(_ pasted: String, button: String) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { announce("There is no link to paste. Copy the song's or video's link first."); return }
        mediaLink = text
        announce("Link pasted. Choose \(button) to bring in the song.")
    }

    /// Brings in the sound from a media link as the YuE2 cover recording. The
    /// server checks the length before downloading and refuses playlists,
    /// anything over six minutes, private addresses and accounts without the
    /// Family feature pack, each in its own words; its answer matches a file
    /// import, so the clip row, player and Transcribe reference lyrics work
    /// unchanged.
    private func importMediaLink() async {
        let link = mediaLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { announce("Paste a media link first."); return }
        guard !workspaceBusy else { announce("Finish the current operation before importing a reference."); return }
        invalidateQuote(); showRenderConfirmation = false
        isImportingLink = true; importError = ""
        defer { isImportingLink = false }
        let sourceEngine = engine
        announce("Bringing in the sound from the link. This can take up to two minutes.")
        do {
            let imported = try await service.importReferenceLink(link: link, engine: engine)
            guard engine == sourceEngine else { return }
            clips.append((url: imported.url, name: imported.name))
            mediaLink = ""
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            announce(imported.spoken)
        } catch {
            Earcons.shared.play(.error)
            importError = (error as? LocalizedError)?.errorDescription ?? "The song could not be brought in from that link."
            announce(importError)
        }
    }

    // MARK: - Script

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editorTitle).font(.headline).accessibilityAddTraits(.isHeader)
            Text(editorHint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            if usesDirectPrompt, let g = currentEngine {
                DisclosureGroup(isEffects ? "How to describe sounds" : "How to direct the music", isExpanded: $showHowTo) {
                    ForEach(Array(g.howToWrite.enumerated()), id: \.offset) { _, tip in Text(tip).font(.footnote) }
                }
            }

            TextField("Track title (optional)", text: $trackTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Track title")
                .accessibilityHint("Up to 80 characters. Leave blank to use the first seven words of your direction. You can rename it in the library.")
                // B8: the first field of every goal's form, where a goal pick lands.
                .accessibilityFocused($boothFocus, equals: .firstField)
            TextEditor(text: $script)
                .font(.system(.body, design: usesDirectPrompt ? .default : .monospaced))
                .frame(minHeight: 160)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel(editorTitle)
                .accessibilityHint(editorHint)
            DictationButton(apiClient: apiClient, text: $script, fieldName: "script")

            if usesDirectPrompt, let g = currentEngine {
                DisclosureGroup(isEffects ? "Sound settings" : "Lyrics, covers, and song settings") {
                Text(isEffects ? "Sound options" : "Song options").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(g.settings.filter { values["instrumental"] != "1" || ($0.key != "lyrics" && $0.key != "keep_lyrics") }) { setting in
                    settingRow(setting)
                }
                }
            }

            if !isEffects {
                HStack {
                    Button(engine == "yue2" ? "Write my song idea" : isMusic ? "Shape my music idea" : "Write a script from this") {
                        Task { await quickDraft() }
                    }.disabled(workspaceBusy)
                    Button("Surprise me", systemImage: "dice") { Task { await inspire() } }.disabled(workspaceBusy)
                }
                if let previous = writingUndo, previous.engine == engine {
                    Button("Undo writing change") {
                        script = previous.script; values["lyrics"] = previous.lyrics; writingUndo = nil
                        invalidateQuote(); announce("Previous writing restored.")
                    }.disabled(workspaceBusy)
                }
                Text(isMusic
                    ? "Writing help does not generate audio. Surprise me asks the writer to invent an original song idea, about ten seconds and a fraction of a cent; drafting uses the writing model."
                    : "Writing help does not generate audio. Surprise me is free; drafting uses the writing model.").font(.footnote)
            }
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
                    Text("Hear this voice first — 15 seconds").frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .disabled(workspaceBusy || !importError.isEmpty)
                .accessibilityHint("Renders one short sample line in the voice you described, so you can hear the actor before spending on the whole piece.")
            }

            Button {
                KadeHaptics.press()
                Task { await renderTapped(preview: false) }
            } label: {
                Text(generateLabel).frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeHeroButtonStyle())
            .disabled(workspaceBusy || !importError.isEmpty || (script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && values["auk_task"] != "edit"))
            .accessibilityHint("Starts generation immediately using these settings and any imported reference. " + (currentEngine?.cost ?? ""))
            Text(currentEngine?.cost ?? localEstimateSentence(for: script)).font(.footnote)

            stopRenderButton
        }
    }

    /// In the form under the render button, and on the front door when a render
    /// was picked back up before any goal was chosen (B8).
    @ViewBuilder
    private var stopRenderButton: some View {
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

    // MARK: - Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library").font(.headline).accessibilityAddTraits(.isHeader)

            Toggle("Show failed and stopped attempts", isOn: $showFailedProjects)
                .accessibilityHint("Finished takes and recoverable parts stay visible. This does not delete anything.")
            if visibleProjects.isEmpty {
                Text("No projects match this view. Turn on Show failed and stopped attempts to include those without audio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // Plain VStack, never a lazy one — see the Part 87 note above.
                VStack(spacing: 14) {
                    ForEach(visibleProjects) { p in
                        projectRow(p)
                    }
                }
            }
        }
    }

    private func saveTitle() async {
        guard let project = renameProject else { return }
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else { announce("Use a title from 1 to 80 characters."); return }
        do {
            try await service.rename(projectId: project.id, title: title)
            if currentProjectId == project.id { trackTitle = title }
            await loadProjects(); announce("Title saved: \(title)")
        } catch { announce((error as? LocalizedError)?.errorDescription ?? "Could not save the title.") }
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

            /* Sep 25 2026: what a Lyria take sang, kept apart from the
             * readback above ("What you will hear") and closed until asked
             * for, so a long lyric sheet is never read out as the row. */
            if let sung = p.sungLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !sung.isEmpty {
                DisclosureGroup {
                    Text(sung)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text("Words it sang")
                        .font(.caption.bold())
                        .accessibilityLabel("Words it sang, \(p.title)")
                }
                .accessibilityHint("Shows the words this song sang. They are not part of What you will hear.")
            }

            if p.state == "failed", let error = p.lastError, !error.isEmpty {
                Text("Generation stopped. \(error)")
                    .font(.callout)
                    .accessibilityLabel("Render failed. \(error)")
            }

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
                            .accessibilityHint("Downloads it and opens the share sheet. Save to Files keeps a copy on this phone.")
                            if take.masterUrl != nil {
                                Button("WAV master") {
                                    Task { await save(take: take, title: p.title, master: true) }
                                }
                                .disabled(savingTakeId != nil)
                                .accessibilityLabel("Save WAV master for \(take.label(number: takes.count - idx))")
                            }

                            Spacer()
                        }
                        HStack {
                            if p.engine == "lyria" || p.engine == "yue2" {
                                Button("Cover this take") { prepareCover(take, project: p) }
                            } else if p.engine != "stable" {
                                Button("Use this voice") { prepareTake(take, title: p.title, editing: false) }
                                Button("Edit this take") { prepareTake(take, title: p.title, editing: true) }
                            }
                        }
                        .disabled(workspaceBusy)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Rename track") {
                    renameProject = p; renameTitle = p.title; showRename = true
                }.accessibilityLabel("Rename \(p.title)")
                Button("Open in the booth") { openInBooth(p) }
                    .accessibilityHint(p.engine == "stable" ? "Loads this sound description and settings so you can make another take." : p.engine == "lyria" ? "Loads this music direction, lyrics and song settings so you can edit them and make another take." : "Loads this script, its voice and its settings back into the boxes above so you can change it and render again.")
                Spacer()
                Button(role: .destructive) {
                    Task { await remove(p) }
                } label: { Text("Remove") }
                .accessibilityLabel("Remove \(p.title)")
                .accessibilityHint("Removes this project from the Sound Booth library. The recording itself stays in My Creations.")
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
            let lyriaOK = h.engines["lyria"]?.configured ?? false
            /* B8 (Sep 23 2026): the question she said people would have is now
             * asked by the front door in plain words, so the chooser's
             * engine-by-engine answer moved under Advanced, "Which engine should
             * I use?". Without a guide, this still says what is set up. */
            let fallback = "AuK HQ \(scenemaOK ? "is available" : "is not set up"), Seed Audio \(seedOK ? "is available" : "is not set up"), Lyria \(lyriaOK ? "is available" : "is not set up")."
            statusLine = h.guide == nil ? "Ready. " + fallback : "Ready."
        } catch {
            statusLine = (error as? LocalizedError)?.errorDescription ?? "Couldn't open the Sound Booth."
        }
        await loadProjects()
        if currentJobId == nil, let latest = projects.first, latest.state == "failed" {
            announce("Your latest render stopped. \(latest.lastError ?? "No finished audio was returned.") The saved attempt is in the library below.")
        }
    }

    private func loadProjects() async {
        do {
            projects = try await service.projects()
            // C3: a render that ended while the booth was closed still has its
            // lock-screen card up; the list says how it ended.
            service.settleRenderCards(with: projects)
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
         * American · flurry"); AuK HQ wants a SENTENCE. The catalog's own
         * describe line is exactly that sentence, which is why the ear
         * pipeline's output is worth carrying here rather than inventing a
         * second vocabulary. Fall back to the label with the middle dot
         * spoken as a comma. */
        let described = catalog.describe[label] ?? label.replacingOccurrences(of: " · ", with: ", ")
        values["voice_description"] = described
        announce("Voice set to \(catalog.name(of: label)). \(described)")
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        guard !workspaceBusy else { announce("Finish the current operation before importing a reference."); return }
        invalidateQuote(); showRenderConfirmation = false
        switch result {
        case .failure(let err):
            importError = "Couldn't open that file. \(err.localizedDescription)"
            announce(importError)
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true; importError = ""
            defer { isImporting = false }
            /* A Files URL is security-scoped: without this pair the read
             * fails with a permission error that looks exactly like a missing
             * file. */
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 20 * 1024 * 1024 else {
                    importError = "That clip is bigger than twenty megabytes. Ten to twenty seconds is all it needs."
                    announce(importError)
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
                importError = (error as? LocalizedError)?.errorDescription ?? "Couldn't read that file. \(error.localizedDescription)"
                announce(importError)
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

    /// Everything the guide's settings hold, typed for the wire. Toggles keep
    /// explicit off values; numbers only when they parse and sit in range; empty
    /// strings are dropped. The guide's own min/max are the rails, so a value
    /// the engine cannot take never leaves the phone.
    private func collectedSettings() -> [String: Any] {
        var out: [String: Any] = [:]
        guard let g = currentEngine else { return out }
        for st in g.settings {
            let raw = (values[st.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch st.kind {
            case "toggle":
                let enabled = values[st.key].map { $0 == "1" } ?? st.defaultBool ?? false
                if st.key == "audio_quality" { out[st.key] = enabled ? "high" : "low" }
                else { out[st.key] = enabled }
            case "number", "range":
                guard let n = Double(raw) else { continue }
                if let lo = st.min, n < lo { continue }
                if let hi = st.max, n > hi { continue }
                out[st.key] = (["seed", "pitch", "count", "steps", "weirdness"].contains(st.key)) ? Int(n.rounded()) : n
            case "clip":
                continue
            default:
                if !raw.isEmpty { out[st.key] = raw }
            }
        }
        if engine == "lyria" {
            if out["instrumental"] as? Bool == true { out.removeValue(forKey: "lyrics"); out.removeValue(forKey: "keep_lyrics") }
            return out
        }
        if engine != "yue2" && engine != "stable" && out["gender"] == nil { out["gender"] = "female" }
        if !clips.isEmpty {
            if engine == "seed" { out["audio_urls"] = clips.prefix(3).map { $0.url } }
            else { out["reference_voice_url"] = clips[0].url }
        }
        return out
    }

    private func transcribeLyrics() async {
        guard !workspaceBusy, importError.isEmpty, let reference = clips.first?.url else { return }
        writingUndo = (engine, script, values["lyrics"] ?? "")
        let sourceEngine = engine
        isTranscribing = true; isWriting = true
        defer { isTranscribing = false; isWriting = false }
        announce("Listening for the sung words. Your current lyrics are kept until the draft is ready.")
        do {
            let draft = try await service.transcribeLyrics(url: reference)
            guard engine == sourceEngine, clips.first?.url == reference else { return }
            values["lyrics"] = draft.transcript
            invalidateQuote(); announce(draft.warning)
        } catch { announce((error as? LocalizedError)?.errorDescription ?? "Could not hear the words. Your lyrics are kept.") }
    }

    private func suggestEngine() async {
        guard !workspaceBusy else { return }
        let sourceEngine = engine
        let sourceVersion = quoteVersion
        // Lyria, YuE2 and Stable Audio show only the script box; the brief box is Scenema and Seed's.
        let t = (usesDirectPrompt ? script : text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { announce("Type something in the box first, then I can suggest."); return }
        isSuggesting = true
        defer { isSuggesting = false }
        do {
            let r = try await service.suggest(text: t)
            guard engine == sourceEngine, quoteVersion == sourceVersion, !workspaceBusy else { return }
            let hasDraft = drafts[r.engine] != nil || r.engine == engine
            selectEngine(r.engine)
            if !hasDraft {
                if usesDirectPrompt { script = t } else { text = t; inputMode = "brief" }
            }
            // The engine change announces its own card; the reason follows.
            try? await Task.sleep(nanoseconds: 900_000_000)
            announce(r.reason + (r.sure ? "" : " Change it if that is not what you meant."))
        } catch {
            announce((error as? LocalizedError)?.errorDescription ?? "Couldn't suggest right now.")
        }
    }

    private func inspire() async {
        guard !workspaceBusy else { return }
        /// Songs: the writer invents the idea (fork POST /sound-booth/idea). The
        /// list below is only what she gets when the writer cannot be reached.
        if isMusic {
            let original = script, requestEngine = engine
            isWriting = true
            defer { isWriting = false }
            announce("Thinking up a song nobody has written. The writer is brainstorming and throwing ideas away, so give it about ten seconds.")
            // Part 293: the chosen YuE2 Style rides along, so a Kids song idea comes back clean.
            if let idea = try? await service.songIdea(band: engine == "yue2" ? values["band"] : nil), !idea.isEmpty {
                guard engine == requestEngine, script == original else { announce("Your editor changed while the idea was being made. Your current text is kept."); return }
                writingUndo = (engine, script, values["lyrics"] ?? "")
                script = idea
                invalidateQuote(); announce("A new song idea is in the editor. Choose Surprise me again for another, or develop it with the writing button. Undo restores your previous writing.")
                return
            }
            guard engine == requestEngine, script == original else { return }
            announce("The writer could not be reached, so this idea comes from the short list.")
        }
        writingUndo = (engine, script, values["lyrics"] ?? "")
        let place = ["a midnight train", "a seaside town", "a kitchen in a thunderstorm", "an old theatre"].randomElement() ?? "home"
        let turn = ["an unexpected reunion", "a promise kept", "a small act of courage", "something thought lost"].randomElement() ?? "a reunion"
        script = isMusic ? "Warm acoustic folk about \(place) and \(turn). An expressive lead vocal, a memorable chorus and a gentle build, about two minutes." : "Write a short vivid story about \(place) and \(turn), with a satisfying ending."
        invalidateQuote(); announce("A new idea is in the editor. Help write this can develop it. Undo restores your previous writing.")
    }

    private func quickDraft() async {
        guard !workspaceBusy else { return }
        let original = script
        let originalLyrics = values["lyrics"] ?? ""
        let requestEngine = engine
        let version = quoteVersion
        let idea = (script.isEmpty ? text : script).trimmingCharacters(in: .whitespacesAndNewlines)
        /* A song pasted whole into the lyrics box, with no direction typed, is
         * sorted by the server with no writer and no charge, so it needs no
         * idea of its own. Anything else still needs one. */
        let lyricsPasteOnly = isMusic && idea.count < 3 && Self.looksLikeSongPaste(originalLyrics)
        guard idea.count >= 3 || lyricsPasteOnly else { announce("Write an idea first, or choose Surprise me."); return }
        isWriting = true
        defer { isWriting = false }
        announce(lyricsPasteOnly
            ? "Sorting the song you pasted into the lyrics box."
            : isMusic
            ? "Writing your song. The writer takes its time, about five minutes, then goes back over it like a producer. You will get a notice when the draft is ready."
            : "Writing a draft from your idea.")
        do {
            let result = try await service.makeScript(engine: engine, mode: "write", text: idea,
                voiceDescription: values["voice_description"], gender: values["gender"] ?? "female",
                mood: nil, scene: nil, shot: nil, lyrics: isMusic ? originalLyrics : nil,
                band: engine == "yue2" ? values["band"] : nil)
            guard engine == requestEngine, script == original, quoteVersion == version else {
                announce("Your writing or settings changed. Your current text is kept."); return
            }
            let placed = placeSongDraft(result, engine: engine, lyricsBefore: originalLyrics)
            guard let draft = placed.direction else { announce(placed.lead); return }
            writingUndo = (engine, original, originalLyrics)
            script = draft; readback = result.readback ?? ""; invalidateQuote()
            announce(placed.lead + "Draft ready in the editor. You can edit or undo it. No audio has been generated.")
        } catch { announce((error as? LocalizedError)?.errorDescription ?? "The writing desk could not finish. Your text is kept.") }
    }

    /// True when text holds a song pasted whole from ChatGPT's three boxes
    /// (a "Lyrics Box" or "Tag Box" heading). Only decides whether the phone
    /// may send it without an idea; the server does the real sorting and says
    /// plainly when it is not a paste.
    private static func looksLikeSongPaste(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("lyrics box") || lower.contains("lyric box") || lower.contains("tag box") || lower.contains("tags box")
    }

    /// Where a song draft's parts go, and what to say first (Sep 25 2026, the
    /// web's sortDraft rules). The draft arrives as "direction, then Lyrics:".
    ///   - Lyria: the desk's words move into Your own lyrics only when that box
    ///     is empty; words she wrote there stay, and she is told when the
    ///     desk's copy differed.
    ///   - YuE2: the desk's words replace the lyrics (YuE2 will not sing
    ///     without them), and she is told when hers were different.
    ///   - A paste the server sorted (`pasted`): its words land wherever it
    ///     put them, and what the paste is missing is said as "One thing to fix
    ///     first", instead of the writer error.
    ///   - A paste in the lyrics box sorted while the writer drafted
    ///     (`pasteSorted.lyrics`): those words go in the lyrics box.
    /// `direction` is nil when nothing should change; `lead` then says why.
    private func placeSongDraft(_ result: SoundBoothScriptResult, engine: String, lyricsBefore: String) -> (direction: String?, lead: String) {
        var draft = result.screenplay ?? result.script
        let pasted = result.pasted == true
        guard engine == "yue2" || engine == "lyria" else { return (draft, Self.noteLead(result.note)) }
        let mine = lyricsBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = currentEngine?.settings.first(where: { $0.key == "lyrics" })?.label
            ?? (engine == "lyria" ? "Your own lyrics" : "Lyrics")
        var lead = ""
        var deskBlock = false
        if let boundary = draft.range(of: "\nLyrics:", options: .caseInsensitive) {
            deskBlock = true
            let deskWords = String(draft[boundary.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            draft = String(draft[..<boundary.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if engine == "lyria" && !pasted && !mine.isEmpty {
                if deskWords != mine && !(result.note ?? "").contains("were kept") {
                    lead = "Your own lyrics were kept as you wrote them; the copy the desk put in its draft was left out. "
                }
            } else {
                values["lyrics"] = deskWords
                if !pasted && !deskWords.isEmpty {
                    if mine.isEmpty {
                        lead = "The words the desk wrote are now in \(box), under Lyrics, covers, and song settings. "
                    } else if deskWords != mine {
                        lead = "\(box) now holds the desk version of your words; Undo writing change brings back yours. "
                    }
                }
            }
        }
        let sortedWords = (result.pasteSorted?.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sortedWords.isEmpty && (!deskBlock || engine == "lyria") {
            values["lyrics"] = sortedWords
        } else if !deskBlock && engine == "yue2" && !pasted {
            return (nil, "The writer did not return separate lyrics. Your idea is kept.")
        }
        lead += Self.noteLead(result.note)
        if pasted, let problem = result.problem?.trimmingCharacters(in: .whitespacesAndNewlines), !problem.isEmpty {
            lead += "One thing to fix first: \(problem) "
        }
        return (draft, lead)
    }

    /// The server's note, trimmed, with a space after it; empty when none.
    private static func noteLead(_ note: String?) -> String {
        let said = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "" : said + " "
    }

    private func makeScript(kind: String) async {
        guard engine != "lyria", !workspaceBusy else { return }
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
                clipURLs: engine == "lyria" ? [] : clips.prefix(engine == "seed" ? 3 : 1).map { $0.url }
            )
            script = r.screenplay ?? r.script
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
        guard !isWriting else { announce("Wait for the writing draft to finish."); return }
        guard !isImporting, !isImportingLink else { announce("Wait for the reference clip to finish importing."); return }
        guard importError.isEmpty else { announce("The reference import failed. Retry it or choose Discard failed import before generating."); return }
        guard !isRendering, currentJobId == nil else { announce("A render is already in progress. Wait for it or stop it first."); return }
        if trackTitle.count > 80 { announce("Use a title up to 80 characters."); return }
        if engine == "yue2", let settings = currentEngine?.settings {
            for setting in settings where ["number", "range"].contains(setting.kind) {
                let raw = (values[setting.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty { continue }
                guard let number = Double(raw), number.isFinite,
                      number >= (setting.min ?? -Double.greatestFiniteMagnitude),
                      number <= (setting.max ?? Double.greatestFiniteMagnitude),
                      setting.step != 1 || number.rounded() == number else {
                    announce("Check \(setting.label). \(setting.hint)"); return
                }
            }
        }
        let st = collectedSettings()
        let s = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preview || !s.isEmpty || (st["auk_task"] as? String == "edit") else { announce(isEffects ? "Describe your sounds first." : isMusic ? "Describe the music you want first." : "Write a script first."); return }
        var body = st
        if engine != "lyria" && !clips.isEmpty { body["referenceExpected"] = true }
        body["title"] = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        body["engine"] = engine; body["mode"] = mode
        body["sourceText"] = text; body["readback"] = readback
        if s.isEmpty {
            let voice = (st["voice_description"] as? String ?? "A warm, clear adult voice.").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            body["script"] = "<speak voice=\"\(voice)\" gender=\"\((st["gender"] as? String) ?? "female")\"></speak>"
        } else { body["script"] = s }
        if preview { body["preview"] = true }
        if newVoice { body["newVoice"] = true }
        if let pid = currentProjectId { body["projectId"] = pid }
        isRendering = true
        defer { isRendering = false }
        /* C3: a lock-screen card for the render. Lyria and Seed Audio record
         * inside this one request, so theirs starts now; a queued engine's
         * starts once the server has the job, below. */
        let cardName = renderCardName(preview: preview)
        var cardWords = "Recording"
        var card = health?.engines[engine]?.queued == false
            ? service.startRenderCard(kind: cardName.kind, title: cardName.title, status: cardWords) : nil
        do {
            confirmArmed = false
            announce(preview ? "Sending the voice sample…" : "Sending the render…")
            let sourceEngine = engine
            let r = try await service.render(body: body)
            newVoice = false; currentProjectId = r.projectId ?? currentProjectId
            // Sep 25 2026: a song pasted whole was sorted by the server first;
            // the editor takes the sorted boxes so it shows what was sent.
            let sortedSentence = applyPasteSorted(r.pasteSorted, engine: sourceEngine)
            let pasteNote = (r.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if r.queued == true, let job = r.jobId {
                currentJobId = job; Earcons.shared.play(.actionStart)
                if card == nil {
                    cardWords = "Waiting its turn"
                    card = service.startRenderCard(kind: cardName.kind, title: cardName.title, status: cardWords)
                }
                // Filed under the project, so a later visit can still move it on.
                service.fileRenderCard(card, under: currentProjectId ?? job, showing: cardWords)
                let estimateWords = r.estimate?.spoken ?? ""
                // The paste note rides in front of the estimate already; said once.
                let noteWords = pasteNote.isEmpty || estimateWords.contains(pasteNote) ? "" : pasteNote + " "
                let leaveWords = (engine == "yue2" || isEffects) ? " You can leave this screen. A notification will open the Sound Booth when all takes finish." : " Progress will be read here. Long pieces continue while this screen is open."
                announce((preview ? "Voice sample queued. " : "Queued. ") + noteWords + estimateWords + leaveWords + sortedSentence)
                startPolling(job)
            } else {
                service.finishRenderCard(id: card, status: "Ready to play")
                Earcons.shared.play(.actionDone); KadeHaptics.success()
                // The server's own sentence first (a paste note, Lyria's "it
                // wrote words for it"), then the booth's.
                let serverWords = (r.spoken ?? r.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let lead = serverWords.isEmpty ? "" : serverWords + " "
                announce(lead + "Ready. The recording is in your library below and in My Creations." + sortedSentence)
                await loadProjects()
            }
        } catch {
            service.finishRenderCard(id: card, status: SoundBoothService.cardReason((error as? LocalizedError)?.errorDescription ?? error.localizedDescription), failed: true)
            announce((error as? LocalizedError)?.errorDescription ?? "The render could not be confirmed. Check the library before retrying.")
        }
    }

    /// Sep 25 2026: a render whose paste the server sorted. The phone sends a
    /// song pasted whole from ChatGPT unsorted; the server renders only the
    /// direction and the words, and hands back where it put them. The editor
    /// takes those boxes, so what she reads is what was sent, and Undo writing
    /// change brings back what she pasted. Returns the sentence to add, or "".
    private func applyPasteSorted(_ sorted: SoundBoothPasteSorted?, engine sourceEngine: String) -> String {
        guard let sorted, engine == sourceEngine else { return "" }
        let beforeScript = script
        let beforeLyrics = values["lyrics"] ?? ""
        var changed = false
        if let direction = sorted.script, direction != beforeScript {
            script = direction
            changed = true
        }
        if let words = sorted.lyrics, words != beforeLyrics {
            values["lyrics"] = words
            changed = true
        }
        guard changed else { return "" }
        writingUndo = (sourceEngine, beforeScript, beforeLyrics)
        return " The editor now shows your song as it was sorted. Undo writing change brings back what you pasted."
    }

    /// C3: what the lock-screen card calls this render. The kind picks the
    /// card's symbol; the title is the one she gave it, or the first few words
    /// of what she typed.
    private func renderCardName(preview: Bool) -> (kind: String, title: String) {
        let kind: String
        let lead: String
        switch engine {
        case "lyria", "yue2": kind = "song"; lead = "Your song"
        case "seed": kind = "scene"; lead = "Your scene"
        case "stable": kind = "sound"; lead = "Your sounds"
        default:
            kind = "scene"
            lead = preview ? "Your voice sample" : (values["auk_task"] == "edit" ? "Your edit" : "Your reading")
        }
        let named = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = (usesDirectPrompt || text.isEmpty) ? script : text
        let firstWords = typed
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(6)
            .joined(separator: " ")
        let name = named.isEmpty ? firstWords : named
        return (kind, name.isEmpty ? lead : "\(lead): \(name)")
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
        /* Lyria is the one per-SONG price in the booth: the brief's length says
         * nothing at all about how long the record comes out, so this must not
         * quote a duration for it the way it does for the speech engines. */
        if engine == "lyria" {
            let perSong = health?.engines["lyria"]?.usdPerSong ?? 0.08
            return "About \(max(1, Int((perSong * 100).rounded()))) cents for the song, whatever length it comes out. Lyria is priced per song, not per minute. Usually back in under a minute."
        }
        if isEffects { return currentEngine?.cost ?? "Provider cost: 2.06 cents per recording. No credit balance deduction during this trial." }
        if engine == "yue2" { return "YuE2 uses a sleeping GPU at about $1.22 per hour. Startup, generation and ten minutes awake afterward are billed. There is no reliable per-song estimate yet." }
        if engine == "scenema" {
            return "AuK HQ uses a sleeping GPU. Startup and processing are billed. A reliable cost and wait estimate is not available yet. Longer work runs in sections."
        }
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
        // C3: the render's lock-screen card is filed under its project (renderTapped).
        let cardKey = currentProjectId ?? jobId
        pollTask = Task {
            var last = ""
            var ticks = 0
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                let st: SoundBoothStatus
                do { st = try await service.status(jobId: jobId); failures = 0 }
                catch {
                    failures += 1
                    if failures == 1 || failures % 4 == 0 { announce("Cannot check progress right now. The render may still be working. Checking again shortly.") }
                    continue
                }
                ticks += 1
                // C3: the service only touches the card on a new stage, or when
                // known progress moves a tenth or more.
                if !st.isFinished {
                    service.updateRenderCard(under: cardKey, status: st.cardStatus, progress: st.cardProgress)
                }
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
                        service.finishRenderCard(under: cardKey, status: "Ready to play")
                        Earcons.shared.play(.actionDone)
                        KadeHaptics.success()
                    } else {
                        service.finishRenderCard(under: cardKey, status: st.state == "cancelled" ? "Stopped" : SoundBoothService.cardReason(st.error), failed: true)
                        Earcons.shared.play(.error)
                        if st.state == "failed" {
                            showFailedProjects = true
                            renderConfirmationMessage = st.error ?? st.spoken ?? "No finished recording was returned. Your saved attempt remains in the library."
                            showRenderConfirmation = true
                        }
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
            let result = try await service.cancel(jobId: jobId)
            if result.state == "done" { announce(result.spoken ?? "That take just finished. Checking its result."); return }
            pollTask?.cancel(); pollTask = nil
            service.finishRenderCard(under: currentProjectId ?? jobId, status: "Stopped", failed: true)
            currentJobId = nil
            announce(result.spoken ?? "Stopped. Completed recordings are kept.")
            await loadProjects()
        } catch {
            announce((error as? LocalizedError)?.errorDescription ?? "Couldn't stop that render.")
        }
    }

    private func save(take: SoundBoothTake, title: String, master: Bool = false) async {
        guard savingTakeId == nil else { return }
        savingTakeId = take.id
        defer { savingTakeId = nil }
        do {
            let fileURL = try await service.download(take: take, title: title, master: master)
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            activeSheet = .share(ShareItem(fileURL: fileURL))
        } catch {
            Earcons.shared.play(.error)
            KadeHaptics.error()
            announce((error as? LocalizedError)?.errorDescription ?? "Couldn't fetch that recording. Try again.")
        }
    }

    private func prepareTake(_ take: SoundBoothTake, title: String, editing: Bool) {
        guard !workspaceBusy else { announce("Finish the current operation first."); return }
        selectEngine("scenema")
        currentProjectId = nil
        values["auk_task"] = editing ? "edit" : "speech"
        if editing { values["instruction"] = ""; values.removeValue(forKey: "gen_seconds") }
        importError = ""
        clips = [(url: take.masterUrl ?? take.url, name: title)]
        invalidateQuote()
        announce(editing ? "Take attached. Describe the edit you want. The original is kept." : "Voice reference attached. Write the words you want this voice to say.")
        focusStatus = true
    }

    private func prepareCover(_ take: SoundBoothTake, project: SoundBoothProject) {
        guard !workspaceBusy else { announce("Finish the current operation first."); return }
        selectEngine("yue2")
        trackTitle = String((project.title + " (cover)").prefix(80))
        currentProjectId = nil
        values = ["lyrics": project.options?["lyrics"]?.asFieldText ?? ""]
        script = project.screenplay ?? project.script
        importError = ""
        clips = [(url: take.masterUrl ?? take.url, name: project.title)]
        invalidateQuote()
        announce("Song attached for a YuE2 cover. Describe the new style and check the lyrics. The original is kept.")
        focusStatus = true
    }

    private func openInBooth(_ p: SoundBoothProject) {
        guard !workspaceBusy else { announce("Finish the current operation first."); return }
        selectEngine(p.engine)
        trackTitle = p.title
        currentProjectId = p.id
        mode = p.mode == "advanced" ? "advanced" : "easy"
        text = p.sourceText ?? ""
        script = p.screenplay ?? p.script
        readback = p.readback ?? ""
        estimate = nil
        confirmArmed = false
        values = [:]; clips = []; importError = ""; newVoice = false
        if let seed = p.voiceSeed { values["seed"] = String(seed) }
        if let opts = p.options {
            for (k, v) in opts {
                if let t = v.asFieldText { values[k] = (k == "audio_quality" && t == "high") ? "1" : t }
            }
        }
        if p.engine == "seed", case .array(let references) = p.options?["audio_urls"] {
            clips = references.compactMap { if case .string(let url) = $0 { return (url: url, name: "Saved reference") }; return nil }
        } else if case .string(let url) = p.options?["reference_voice_url"] { clips = [(url: url, name: "Saved reference")] }
        announce("Opened \(p.title). Its draft and settings are restored. Change what you like and generate another take.")
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
    @Environment(\.dismiss) private var dismiss

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
                // The sheet had no way out: a swipe-down is not a VoiceOver
                // gesture and a label on the player hid AVKit's own controls.
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityHint("Stops playing and goes back.")
                    }
                }
                .accessibilityAction(.escape) { dismiss() }
        }
    }
}

