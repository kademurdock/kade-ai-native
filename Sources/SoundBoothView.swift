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
    @State private var voiceDescription = ""
    @State private var gender = "female"
    @State private var mood = ""
    @State private var referenceURL = ""
    @State private var referenceName = ""

    // Advanced
    @State private var scene = ""
    @State private var shot = ""
    @State private var paceText = ""
    @State private var seedText = ""
    @State private var backgroundSFX = false
    @State private var studioQuality = false

    // Live state
    @State private var health: SoundBoothHealth?
    @State private var projects: [SoundBoothProject] = []
    @State private var estimate: SoundBoothEstimate?
    @State private var statusLine = "Loading the Sound Booth…"
    @State private var isWriting = false
    @State private var isRendering = false
    @State private var isImporting = false
    @State private var confirmArmed = false
    @State private var currentProjectId: String?
    @State private var currentJobId: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var savingTakeId: String?
    @State private var activeSheet: BoothSheet?
    @State private var showFileImporter = false
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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        .onChange(of: voiceLabel) { _, label in applyVoiceLabel(label) }
        /* An armed confirm is dropped the moment the script changes, so a
         * second tap can never spend on something she has since edited. Same
         * for a switched engine: the price is different, so the quote is. */
        .onChange(of: script) { _, _ in confirmArmed = false }
        .onChange(of: engine) { _, _ in confirmArmed = false; estimate = nil }
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

    // MARK: - Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Engine", selection: $engine) {
                Text("Scenema").tag("scenema")
                Text("Seed Audio").tag("seed")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Engine")
            .accessibilityHint(engineHint)
            Text(engineHint).font(.footnote).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var engineHint: String {
        if engine == "seed" {
            return "Seed Audio: a whole scene in one pass — up to three voices, music, sound effects, ambience. Back in seconds, about nineteen cents a minute. It is made on fal's servers, so the audio leaves the house."
        }
        return "Scenema: one actor performing, any length, real stage directions, on Kade's own graphics card — nothing leaves the house. It is queued, so it takes about a minute and a half per minute of audio, and about two cents a minute."
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
                : "Advanced. Every field the engine has, and the raw script to edit yourself.")
        }
    }

    // MARK: - Writing

    private var writingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should it say?").font(.headline).accessibilityAddTraits(.isHeader)

            TextEditor(text: $text)
                .frame(minHeight: 140)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel("What should it say")
                .accessibilityHint("Type the words you want performed, or describe a piece and use Write me one.")

            Button {
                KadeHaptics.press()
                activeSheet = .voicePicker
            } label: {
                HStack {
                    Text("Voice")
                    Spacer()
                    Text(voiceLabel.isEmpty ? "Not picked" : catalog.name(of: voiceLabel))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Voice, \(voiceLabel.isEmpty ? "not picked" : catalog.name(of: voiceLabel))")
            .accessibilityHint("Opens the voice wheel. The voice you land on is described in words for the engine — a clip you import beats a description for a specific person.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Or describe a voice in words").font(.subheadline)
                TextField("Woman in her sixties, Ozarks, warm and a little gravelly.", text: $voiceDescription, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityLabel("Describe a voice in words")
                    .accessibilityHint("Age, sex, build, accent, texture, manner. A description misses the age more often than it hits it, so import a clip when you want a specific person.")
            }

            Picker("Voice sex", selection: $gender) {
                Text("Female").tag("female")
                Text("Male").tag("male")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Voice sex")

            importRow

            if let moods = health?.moods, !moods.isEmpty {
                Picker("Mood", selection: $mood) {
                    Text("No particular mood").tag("")
                    ForEach(moods) { m in Text(m.label).tag(m.key) }
                }
                .accessibilityLabel("Mood")
                .accessibilityHint("Becomes a note to the actor between your sentences — what the speaker is doing and feeling, never how the recording should sound.")
            }

            if mode == "advanced" { advancedFields }

            HStack(spacing: 12) {
                Button {
                    KadeHaptics.press()
                    Task { await makeScript(kind: "format") }
                } label: {
                    Text("Turn my words into a script").frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .disabled(isWriting || isRendering)
                .accessibilityHint("Keeps every word you wrote and only adds the structure the engine needs.")
            }

            Button {
                KadeHaptics.press()
                Task { await makeScript(kind: "write") }
            } label: {
                Text("Write me one").frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .disabled(isWriting || isRendering)
            .accessibilityHint("Writes a whole piece from what you described in the box above.")
        }
    }

    private var importRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                KadeHaptics.press()
                showFileImporter = true
            } label: {
                HStack {
                    Label("Import a clip to clone", systemImage: "square.and.arrow.down")
                    Spacer()
                    if isImporting { ProgressView().accessibilityHidden(true) }
                }
            }
            .disabled(isImporting)
            .accessibilityLabel(referenceName.isEmpty ? "Import a clip to clone" : "Imported clip, \(referenceName). Double tap to pick a different one.")
            .accessibilityHint("Opens Files. Ten to twenty seconds of somebody talking is enough, and it is the reliable way to get a specific person's voice.")

            if !referenceName.isEmpty {
                HStack {
                    Text("Cloning: \(referenceName)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") {
                        referenceURL = ""
                        referenceName = ""
                        announce("Reference clip removed.")
                    }
                    .font(.footnote)
                    .accessibilityLabel("Remove the imported clip")
                }
            }
        }
    }

    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine settings").font(.subheadline.bold()).accessibilityAddTraits(.isHeader)

            TextField("Scene — a kitchen at dawn, rain outside", text: $scene)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Scene")
                .accessibilityHint("Where this happens. Sound from the scene is only added if you turn on scene sound below.")

            Picker("Shot", selection: $shot) {
                Text("Not set").tag("")
                Text("Close up").tag("closeup")
                Text("Wide").tag("wide")
                Text("Scene").tag("scene")
            }
            .accessibilityLabel("Shot")
            .accessibilityHint("How far away the listener is. Wide and Scene put the voice in a room instead of at your ear.")

            TextField("Pace — 1.0 is normal", text: $paceText)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Pace")
                .accessibilityHint("Between zero point five and three. One is normal speed.")

            TextField("Seed — leave empty for a new take", text: $seedText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Seed")
                .accessibilityHint("The same seed with the same script gives the same take again. Leave it empty for something new each time.")

            Toggle("Scene sound around the voice", isOn: $backgroundSFX)
                .accessibilityHint("Adds the room and the weather around the speaker instead of a clean voice on its own.")
            Toggle("Studio quality", isOn: $studioQuality)
                .accessibilityHint("Forty-eight kilohertz, a bigger file, and the same price.")
        }
        .padding(.vertical, 4)
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

            Button {
                KadeHaptics.press()
                Task { await renderTapped() }
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
            let scenemaOK = h.engines["scenema"]?.configured ?? false
            let seedOK = h.engines["seed"]?.configured ?? false
            statusLine = "Ready. Scenema \(scenemaOK ? "is available" : "is not set up"), Seed Audio \(seedOK ? "is available" : "is not set up")."
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
        voiceDescription = described
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
                    mimeType: mimeType(for: url)
                )
                referenceURL = imported.url
                referenceName = imported.name
                Earcons.shared.play(.actionDone)
                KadeHaptics.success()
                announce(imported.spoken)
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

    private func makeScript(kind: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 3 else {
            announce(kind == "write" ? "Say what you want made first." : "Type the words you want performed first.")
            return
        }
        isWriting = true
        defer { isWriting = false }
        announce(kind == "write" ? "Writing it…" : "Shaping your words…")
        do {
            let r = try await service.makeScript(
                engine: engine,
                mode: kind,
                text: body,
                voiceDescription: voiceDescription.isEmpty ? nil : voiceDescription,
                gender: gender,
                mood: mood.isEmpty ? nil : mood,
                scene: scene.isEmpty ? nil : scene,
                shot: shot.isEmpty ? nil : shot
            )
            script = r.script
            readback = r.readback ?? ""
            estimate = r.estimate
            confirmArmed = false
            var parts: [String] = []
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

    private func renderTapped() async {
        let s = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        /* HER STANDING RULE: the cost is SAID before it runs. First tap says
         * the price and arms; second tap spends. The armed state is dropped
         * whenever the script changes, so a stale confirm can never spend on
         * something she has since edited. */
        if !confirmArmed {
            confirmArmed = true
            let spoken = estimate?.spoken ?? localEstimateSentence(for: s)
            announce("\(spoken) Press Render again to go ahead.")
            return
        }
        confirmArmed = false
        isRendering = true
        defer { isRendering = false }
        var body: [String: Any] = [
            "engine": engine,
            "mode": mode,
            "script": s,
            "sourceText": text,
            "readback": readback,
            "gender": gender,
        ]
        if let pid = currentProjectId { body["projectId"] = pid }
        if !voiceDescription.isEmpty { body["voice_description"] = voiceDescription }
        if !referenceURL.isEmpty { body["reference_voice_url"] = referenceURL }
        if mode == "advanced" {
            if !scene.isEmpty { body["scene"] = scene }
            if !shot.isEmpty { body["shot"] = shot }
            if let p = Double(paceText), p >= 0.5, p <= 3 { body["pace"] = p }
            if let sd = Int(seedText), sd >= 0 { body["seed"] = sd }
            if backgroundSFX { body["background_sfx"] = true }
            if studioQuality { body["audio_quality"] = "high" }
        }
        announce("Sending it…")
        do {
            let r = try await service.render(body: body)
            currentProjectId = r.projectId ?? currentProjectId
            if r.queued == true, let job = r.jobId {
                currentJobId = job
                Earcons.shared.play(.actionStart)
                announce("Queued. \(r.estimate?.spoken ?? "") The phone will buzz when it is ready, and this screen will say so.")
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
        let wait = engine == "seed" ? "a few seconds to make" : "a couple of minutes to make"
        return "About \(secs) seconds of audio, \(wait), about \(cents) cents."
    }

    private func startPolling(_ jobId: String) {
        pollTask?.cancel()
        pollTask = Task {
            var last = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                guard let st = try? await service.status(jobId: jobId) else { continue }
                if st.state != last {
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
