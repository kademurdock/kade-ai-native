import SwiftUI
import UniformTypeIdentifiers

// OPEN VOICES IN THE SOUND BOOTH (Nov 15 2026): VoxCPM2 and Ming, the same
// panel the website shows (fork kadeSoundBoothOpenVoices.js and its page).
//
//   Design a voice:     a description and the words to say. Every try is a
//                       new take on a new voice number. A take can be kept as
//                       a saved voice.
//   Speak with a voice: a saved voice or an imported clip, the words, and an
//                       optional style in plain words.
//
// Routes under /api/kade/sound-booth: GET open-voices (engines and saved
// voices), POST open-voices/take, GET open-voices/take/:jobId, POST
// open-voices/stop, keep, keep-clip and forget. Takes are filed in My
// Creations by the server. Removing a voice only takes it off the list.
//
// VoiceOver: every control is labelled, status is announced, and focus moves
// only after an announcement has finished (the booth's own rule), to Stop
// while a take is made and to the new take when it is ready. The take's
// player is the booth's player sheet. No lazy containers here (Part 87).

// MARK: - Models

struct SoundBoothOpenVoiceEngine: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let about: String
    let maxDescription: Int?

    private enum CodingKeys: String, CodingKey { case id, label, about, maxDescription }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? id
        about = (try? c.decodeIfPresent(String.self, forKey: .about)) ?? ""
        maxDescription = try? c.decodeIfPresent(Int.self, forKey: .maxDescription)
    }
}

/// The /health block. Read leniently: an odd value here never breaks the booth.
struct SoundBoothOpenVoicesBlock: Decodable, Equatable {
    let engines: [SoundBoothOpenVoiceEngine]
    let coldNote: String

    private enum CodingKeys: String, CodingKey { case engines, coldNote }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        engines = (try? c?.decodeIfPresent([SoundBoothOpenVoiceEngine].self, forKey: .engines)) ?? []
        coldNote = (try? c?.decodeIfPresent(String.self, forKey: .coldNote)) ?? ""
    }
}

struct SoundBoothSavedVoice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let engine: String?
    let description: String?
    let seconds: Double?
    let url: String?

    private enum CodingKeys: String, CodingKey { case id, name, engine, description, seconds, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Saved voice"
        engine = try? c.decodeIfPresent(String.self, forKey: .engine)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        seconds = try? c.decodeIfPresent(Double.self, forKey: .seconds)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
    }

    /// "Grandpa, 12 seconds", as the web page lists it.
    var spokenName: String {
        guard let seconds, seconds > 0 else { return name }
        return "\(name), \(Int(seconds.rounded())) seconds"
    }
}

/// One answer from an Open voices route. Every field is optional, so one
/// shape reads them all.
struct SoundBoothOpenVoiceAnswer: Decodable {
    struct VoiceRef: Decodable { let id: String?; let name: String? }
    var engines: [SoundBoothOpenVoiceEngine]?
    var voices: [SoundBoothSavedVoice]?
    var coldNote: String?
    var jobId: String?
    var engine: String?
    var seed: Int?
    var coldLikely: Bool?
    var state: String?
    var spoken: String?
    var url: String?
    var seconds: Double?
    var error: String?
    var voice: VoiceRef?

    private enum CodingKeys: String, CodingKey {
        case engines, voices, coldNote, jobId, engine, seed, coldLikely, state, spoken, url, seconds, error, voice
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engines = try? c.decodeIfPresent([SoundBoothOpenVoiceEngine].self, forKey: .engines)
        voices = try? c.decodeIfPresent([SoundBoothSavedVoice].self, forKey: .voices)
        coldNote = try? c.decodeIfPresent(String.self, forKey: .coldNote)
        jobId = try? c.decodeIfPresent(String.self, forKey: .jobId)
        engine = try? c.decodeIfPresent(String.self, forKey: .engine)
        if let whole = try? c.decodeIfPresent(Int.self, forKey: .seed) { seed = whole }
        else if let number = try? c.decodeIfPresent(Double.self, forKey: .seed), number.isFinite { seed = Int(number) }
        coldLikely = try? c.decodeIfPresent(Bool.self, forKey: .coldLikely)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        spoken = try? c.decodeIfPresent(String.self, forKey: .spoken)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        seconds = try? c.decodeIfPresent(Double.self, forKey: .seconds)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        voice = try? c.decodeIfPresent(VoiceRef.self, forKey: .voice)
    }
}

// MARK: - Service

@MainActor
final class SoundBoothOpenVoicesService {
    struct Reply {
        /// The HTTP status, or 0 when the server could not be reached.
        let status: Int
        let answer: SoundBoothOpenVoiceAnswer
        var ok: Bool { status == 200 }
        /// The server's sentence, or `fallback`.
        func sentence(_ fallback: String) -> String {
            let said = (answer.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty ? fallback : said
        }
    }

    private let client: KadeAPIClient
    init(apiClient: KadeAPIClient) { client = apiClient }

    private func call(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 60) async -> Reply {
        var req = client.request(path: "api/kade/sound-booth/" + path, method: body == nil ? "GET" : "POST", authorized: true, timeout: timeout)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, http) = try await client.send(req)
            let answer = (try? JSONDecoder().decode(SoundBoothOpenVoiceAnswer.self, from: data)) ?? SoundBoothOpenVoiceAnswer()
            return Reply(status: http.statusCode, answer: answer)
        } catch {
            var answer = SoundBoothOpenVoiceAnswer()
            answer.error = "Connection lost. Try again."
            return Reply(status: 0, answer: answer)
        }
    }

    func list() async -> Reply { await call("open-voices") }
    func take(_ body: [String: Any]) async -> Reply { await call("open-voices/take", body: body) }
    func status(jobId: String) async -> Reply {
        let safe = jobId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))) ?? jobId
        return await call("open-voices/take/" + safe, timeout: 30)
    }
    func stop(jobId: String) async -> Reply { await call("open-voices/stop", body: ["jobId": jobId]) }
    func keep(jobId: String, name: String) async -> Reply { await call("open-voices/keep", body: ["jobId": jobId, "name": name]) }
    func keepClip(url: String, name: String, words: String, seconds: Double?) async -> Reply {
        var body: [String: Any] = ["clipUrl": url, "name": name, "clipWords": words]
        if let seconds { body["seconds"] = seconds }
        return await call("open-voices/keep-clip", body: body)
    }
    func forget(voiceId: String) async -> Reply { await call("open-voices/forget", body: ["voiceId": voiceId]) }
}

// MARK: - The panel

struct SoundBoothOpenVoicesView: View {
    let apiClient: KadeAPIClient
    /// What /health listed, so the panel can draw before its own list answers.
    let engines: [SoundBoothOpenVoiceEngine]
    let coldNote: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var booth: SoundBoothService
    @State private var service: SoundBoothOpenVoicesService

    init(apiClient: KadeAPIClient, engines: [SoundBoothOpenVoiceEngine], coldNote: String) {
        self.apiClient = apiClient
        self.engines = engines
        self.coldNote = coldNote
        _booth = StateObject(wrappedValue: SoundBoothService(apiClient: apiClient))
        _service = State(initialValue: SoundBoothOpenVoicesService(apiClient: apiClient))
        _engineList = State(initialValue: engines)
        _engineId = State(initialValue: engines.first?.id ?? "")
        _cold = State(initialValue: coldNote)
    }

    struct Take: Identifiable, Equatable {
        let id: String          // the job id
        let number: Int
        let engineLabel: String
        let seed: Int?
        let seconds: Double?
        let url: String
        var keptAs: String?

        var title: String {
            var words = "Take \(number), \(engineLabel)"
            if let seed { words += ", voice number \(seed)" }
            if let seconds, seconds > 0 { words += ", \(Int(seconds.rounded())) seconds" }
            return words
        }
    }

    private enum Mode: String { case design, speak }
    private enum Focus: Hashable { case status, make, stop, voice, take(String) }
    private struct PlayItem: Identifiable { let id = UUID(); let url: URL; let title: String }

    @State private var engineList: [SoundBoothOpenVoiceEngine]
    @State private var engineId: String
    @State private var cold: String
    @State private var voices: [SoundBoothSavedVoice] = []
    @State private var loaded = false
    @State private var mode: Mode = .design
    @State private var describe = ""
    @State private var voiceChoice = "clip"
    @State private var clip: (url: String, name: String, seconds: Double?)?
    @State private var clipWords = ""
    @State private var clipName = ""
    @State private var style = ""
    @State private var words = ""
    @State private var seedText = ""
    @State private var jobId: String?
    @State private var starting = false
    @State private var isImporting = false
    @State private var showImporter = false
    @State private var coldSaid = false
    @State private var lastSpoken = Date.distantPast
    @State private var pollTask: Task<Void, Never>?
    @State private var takes: [Take] = []
    @State private var takeNames: [String: String] = [:]
    @State private var keeping: String?
    @State private var confirmForget = false
    @State private var playing: PlayItem?
    @State private var statusLine = "Loading your voices…"
    @State private var pendingFocus: (message: String, target: Focus)?
    @AccessibilityFocusState private var focus: Focus?

    private var busy: Bool { jobId != nil || starting }
    private var engine: SoundBoothOpenVoiceEngine? { engineList.first(where: { $0.id == engineId }) ?? engineList.first }
    private var chosenVoice: SoundBoothSavedVoice? { voices.first(where: { $0.id == voiceChoice }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(statusLine)
                        .font(.subheadline)
                        .accessibilityFocused($focus, equals: .status)
                    if engineList.isEmpty {
                        Text(loaded ? "Open voices are not available right now. Try again later." : "Checking which voice engines are ready…")
                            .font(.body)
                    } else {
                        introBlock
                        enginePicker
                        modePicker
                        if mode == .design { designBlock } else { speakBlock }
                        wordsBlock
                        makeBlock
                        takesBlock
                    }
                }
                .padding()
            }
            .navigationTitle("Open voices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityHint(busy ? "Goes back to the Sound Booth. A take being made still lands in My Creations." : "Goes back to the Sound Booth.")
                }
            }
            .accessibilityAction(.escape) { dismiss() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.clipTypes, allowsMultipleSelection: false) { result in
            Task { await importClip(result) }
        }
        .sheet(item: $playing) { item in
            BoothPlayerSheet(url: item.url, title: item.title)
        }
        .confirmationDialog(
            "Remove \(chosenVoice?.name ?? "this voice") from your voices?",
            isPresented: $confirmForget,
            titleVisibility: .visible
        ) {
            Button("Remove \(chosenVoice?.name ?? "this voice")", role: .destructive) { Task { await forgetVoice() } }
            Button("Keep it", role: .cancel) { say("Kept \(chosenVoice?.name ?? "the voice").") }
        } message: {
            Text("The recording stays in My Creations.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) { note in
            guard let waiting = pendingFocus,
                  (note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String) == waiting.message else { return }
            pendingFocus = nil
            if playing == nil { focus = waiting.target }
        }
        .onAppear { Task { await load() } }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    // MARK: Sections

    private var introBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Design a voice from a description, or speak with a voice you saved. Each take is saved in My Creations. GPU time is billed.")
                .font(.footnote)
            if !cold.isEmpty {
                Text(cold).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Voice engine", selection: $engineId) {
                ForEach(engineList) { e in Text(e.label).tag(e.id) }
            }
            .accessibilityLabel("Voice engine")
            .accessibilityHint(engine?.about ?? "")
            .disabled(busy)
            if let about = engine?.about, !about.isEmpty {
                Text(about).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private var modePicker: some View {
        Picker("Design a voice or speak with one", selection: Binding(
            get: { mode },
            set: { next in
                guard next != mode else { return }
                mode = next
                if next == .design {
                    say("Design a voice. Describe it, then type the words to say.")
                } else {
                    say(voices.isEmpty
                        ? "Speak with a voice. You have no saved voices yet, so import a clip, or keep a designed take first."
                        : "Speak with a voice. Pick a saved voice or import a clip.")
                }
            }
        )) {
            Text("Design a voice").tag(Mode.design)
            Text("Speak with a voice").tag(Mode.speak)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Design a voice or speak with one")
    }

    private var designBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Describe the voice").font(.subheadline)
            TextField("A warm older man with a slow Southern drawl", text: $describe, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityLabel("Describe the voice")
                .accessibilityHint(describeHint)
            Text(describeHint).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var describeHint: String {
        var hint = "For example: a warm older man with a slow Southern drawl and a little gravel. Each try makes a new voice."
        if let most = engine?.maxDescription { hint += " Up to \(most) characters." }
        return hint
    }

    private var speakBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Saved voice", selection: $voiceChoice) {
                    ForEach(voices) { v in Text(v.spokenName).tag(v.id) }
                    Text("An imported clip").tag("clip")
                }
                .accessibilityLabel("Saved voice")
                .accessibilityHint("Your saved voices, newest first. Or choose An imported clip and import one below.")
                .accessibilityFocused($focus, equals: .voice)
                Text("Your saved voices, newest first. Or choose An imported clip and import one below.")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if let saved = chosenVoice {
                if let link = saved.url, let url = URL(string: link) {
                    Button("Play \(saved.name)") { playing = PlayItem(url: url, title: saved.name) }
                        .accessibilityHint("Plays the saved voice's recording.")
                }
                Button("Remove \(saved.name) from my list", role: .destructive) { confirmForget = true }
                    .disabled(busy)
                    .accessibilityHint("Asks first. The recording stays in My Creations.")
            } else {
                clipBlock
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Style (optional)").font(.subheadline)
                TextField("Slightly faster, cheerful tone", text: $style)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Style, optional")
                    .accessibilityHint("Plain words, for example: slightly faster, cheerful tone.")
            }
        }
    }

    private var clipBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                KadeHaptics.press()
                showImporter = true
            } label: {
                HStack {
                    Label(clip == nil ? "Import a clip" : "Import a different clip", systemImage: "square.and.arrow.down")
                    Spacer()
                    if isImporting { ProgressView().accessibilityHidden(true) }
                }
            }
            .disabled(isImporting || busy)
            .accessibilityHint("Opens Files. WAV, MP3 or M4A. A clear recording of one person talking. Ten to thirty seconds works best.")
            if let clip {
                HStack {
                    Text("Voice clip: " + clip.name + (clip.seconds.map { ", \(Int($0.rounded())) seconds" } ?? ""))
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if let url = URL(string: clip.url) {
                        Button("Play") { playing = PlayItem(url: url, title: clip.name) }
                            .font(.footnote)
                            .accessibilityLabel("Play the imported clip, \(clip.name)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What the clip says, word for word (optional)").font(.subheadline)
                TextField("Leave empty if unsure", text: $clipWords, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityLabel("What the clip says, word for word, optional")
                    .accessibilityHint("Only for a clip of thirty seconds or less. Exact words make the copy closer. Leave it empty if unsure.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Name for this clip's voice").font(.subheadline)
                TextField("Name", text: $clipName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name for this clip's voice")
                    .accessibilityHint("Up to 80 characters.")
            }
            Button("Keep this clip as a saved voice") { Task { await keepClip() } }
                .disabled(busy || keeping != nil)
                .accessibilityHint("Adds the clip to your saved voices, so you can pick it next time.")
        }
    }

    private var wordsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Words to say").font(.subheadline)
                TextEditor(text: $words)
                    .frame(minHeight: 110)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                    .accessibilityLabel("Words to say")
                    .accessibilityHint("Up to 5,000 characters. For a voice you plan to keep, a sentence or two is best.")
                Text("Up to 5,000 characters. For a voice you plan to keep, a sentence or two is best.")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice number (optional)").font(.subheadline)
                TextField("Leave empty", text: $seedText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Voice number, optional")
                    .accessibilityHint("Leave it empty for a new take every try. Type a take's number to hear that take again.")
            }
        }
    }

    private var makeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            /* Make stays usable while a take runs, so VoiceOver never loses
             * its place; a press then says how to stop it (the web page's rule). */
            Button {
                KadeHaptics.press()
                Task { await make() }
            } label: {
                Text("Make a take").frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeHeroButtonStyle())
            .accessibilityValue(busy ? "A take is being made" : "")
            .accessibilityHint("Makes one take with these settings. It is saved in My Creations. GPU time is billed.")
            .accessibilityFocused($focus, equals: .make)
            if let job = jobId {
                Button(role: .destructive) {
                    Task { await stop(job) }
                } label: {
                    Text("Stop this take").frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .accessibilityHint("Stops the take being made. Nothing is kept from it.")
                .accessibilityFocused($focus, equals: .stop)
            }
        }
    }

    @ViewBuilder
    private var takesBlock: some View {
        if !takes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Takes").font(.headline).accessibilityAddTraits(.isHeader)
                // Plain VStack over a bounded list, never a lazy one (Part 87).
                ForEach(takes) { take in takeRow(take) }
            }
        }
    }

    private func takeRow(_ take: Take) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(take.title)
                .font(.subheadline.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .take(take.id))
            if let url = URL(string: take.url) {
                Button("Play take \(take.number)") { playing = PlayItem(url: url, title: "Take \(take.number)") }
                    .accessibilityHint("Opens the player.")
            }
            if let seed = take.seed {
                Button("Use voice number \(seed) again") {
                    seedText = String(seed)
                    say("Voice number set to \(seed). The next take uses this voice again.")
                }
                .font(.footnote)
                .accessibilityHint("Puts this take's number in Voice number.")
            }
            if let kept = take.keptAs {
                Text("Kept as \(kept)").font(.footnote)
            } else {
                TextField("Name for this voice", text: Binding(
                    get: { takeNames[take.id] ?? "" },
                    set: { takeNames[take.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name for take \(take.number)'s voice")
                .accessibilityHint("Up to 80 characters.")
                Button("Keep take \(take.number) as a saved voice") { Task { await keep(take) } }
                    .disabled(keeping != nil)
                    .accessibilityHint("Adds this take to your saved voices, so Speak with a voice can use it.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: Speaking and focus

    private func say(_ message: String, then target: Focus? = nil) {
        statusLine = message
        if let target { pendingFocus = (message: message, target: target) } else { pendingFocus = nil }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func sayUrgent(_ message: String, then target: Focus? = nil) {
        statusLine = message
        if let target { pendingFocus = (message: message, target: target) } else { pendingFocus = nil }
        KadeAnnounce.high(message)
    }

    // MARK: Actions

    private func load() async {
        let r = await service.list()
        loaded = true
        guard r.ok else {
            if engineList.isEmpty { sayUrgent(r.sentence("Could not load your voices. Try again.")) }
            else { statusLine = r.sentence("Could not load your saved voices. Try again.") }
            return
        }
        if let listed = r.answer.engines {
            engineList = listed
            if !listed.contains(where: { $0.id == engineId }) { engineId = listed.first?.id ?? "" }
        }
        if let note = r.answer.coldNote, !note.isEmpty { cold = note }
        voices = r.answer.voices ?? []
        if !voices.isEmpty && voiceChoice == "clip" && clip == nil { voiceChoice = voices[0].id }
        if engineList.isEmpty {
            say("Open voices are not available right now.")
        } else {
            let names = engineList.map { $0.label }.joined(separator: " and ")
            let count = voices.count == 1 ? "1 saved voice" : "\(voices.count) saved voices"
            say("Open voices with \(names). You have \(count).")
        }
    }

    private func reloadVoices(select id: String? = nil) async {
        let r = await service.list()
        guard r.ok else { return }
        voices = r.answer.voices ?? []
        if let id, voices.contains(where: { $0.id == id }) { voiceChoice = id }
        else if !voices.contains(where: { $0.id == voiceChoice }) { voiceChoice = voices.first?.id ?? "clip" }
    }

    private func make() async {
        if busy { say("A take is still being made. Choose Stop this take to end it."); return }
        guard let engine else { say("No voice engine is ready right now."); return }
        var body: [String: Any] = ["engine": engine.id, "mode": mode.rawValue, "text": words]
        let seed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seed.isEmpty { body["seed"] = seed }
        if mode == .design {
            body["description"] = describe
        } else {
            body["style"] = style
            if let saved = chosenVoice {
                body["voiceId"] = saved.id
            } else {
                guard let clip else { sayUrgent("Import a clip first, or pick a saved voice."); return }
                body["clipUrl"] = clip.url
                body["clipWords"] = clipWords
                if let seconds = clip.seconds { body["clipSeconds"] = seconds }
            }
        }
        starting = true
        say("Starting a take…")
        let r = await service.take(body)
        starting = false
        if r.status == 409, let job = r.answer.jobId {
            follow(job, message: r.sentence("Your last take is still being made. You will hear when it is ready."))
            return
        }
        guard r.ok, let job = r.answer.jobId else {
            Earcons.shared.play(.error)
            sayUrgent(r.sentence("The take could not start."))
            return
        }
        Earcons.shared.play(.actionStart)
        var message = "Making a take."
        if r.answer.coldLikely != false && !coldSaid {
            coldSaid = true
            let note = (r.answer.coldNote ?? "").isEmpty ? cold : (r.answer.coldNote ?? "")
            if !note.isEmpty { message += " " + note }
        }
        follow(job, message: message + " You will hear when it is ready.")
    }

    private func follow(_ job: String, message: String) {
        jobId = job
        lastSpoken = Date()
        say(message, then: .stop)
        pollTask?.cancel()
        pollTask = Task { await poll(job) }
    }

    private func poll(_ job: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled || jobId != job { return }
            let r = await service.status(jobId: job)
            if Task.isCancelled || jobId != job { return }
            let d = r.answer
            if r.ok, d.state == "done", let url = d.url, !url.isEmpty {
                jobId = nil
                addTake(d, jobId: job, url: url)
                return
            }
            /* A lost connection or a slow answer is not the end of a take:
             * keep checking. Only a clear failed or stopped state, or a take
             * the server no longer knows, ends it here. */
            let gone = r.status >= 400 && r.status < 500
            if gone || d.state == "failed" || d.state == "cancelled" {
                jobId = nil
                Earcons.shared.play(.error)
                sayUrgent(r.sentence("The take did not finish."), then: .make)
                return
            }
            if let spoken = d.spoken, !spoken.isEmpty, Date().timeIntervalSince(lastSpoken) > 20 {
                lastSpoken = Date()
                say(spoken)
            }
        }
    }

    private func addTake(_ d: SoundBoothOpenVoiceAnswer, jobId job: String, url: String) {
        let label = engineList.first(where: { $0.id == d.engine })?.label ?? d.engine ?? engine?.label ?? "Open voice"
        let take = Take(id: job, number: takes.count + 1, engineLabel: label, seed: d.seed, seconds: d.seconds, url: url, keptAs: nil)
        takes.insert(take, at: 0)
        Earcons.shared.play(.actionDone)
        KadeHaptics.success()
        say("Take \(take.number) is ready. Play it, or keep it as a saved voice.", then: .take(job))
    }

    private func stop(_ job: String) async {
        let r = await service.stop(jobId: job)
        guard r.ok else { sayUrgent(r.sentence("Stop was not confirmed. Try Stop again.")); return }
        pollTask?.cancel(); pollTask = nil
        jobId = nil
        say("Stopped. Nothing was kept from this take.", then: .make)
    }

    private func keep(_ take: Take) async {
        let name = (takeNames[take.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { sayUrgent("Give the voice a name first."); return }
        keeping = take.id
        defer { keeping = nil }
        let r = await service.keep(jobId: take.id, name: String(name.prefix(80)))
        guard r.ok else { sayUrgent(r.sentence("The voice did not save.")); return }
        if let index = takes.firstIndex(where: { $0.id == take.id }) { takes[index].keptAs = String(name.prefix(80)) }
        await reloadVoices()
        KadeHaptics.success()
        say(r.answer.spoken ?? "Saved \(name) to your voices.")
    }

    private func keepClip() async {
        guard let clip else { sayUrgent("Import a clip first."); return }
        let name = clipName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { sayUrgent("Give the voice a name first."); return }
        keeping = "clip"
        defer { keeping = nil }
        let r = await service.keepClip(url: clip.url, name: String(name.prefix(80)), words: clipWords, seconds: clip.seconds)
        guard r.ok else { sayUrgent(r.sentence("The voice did not save.")); return }
        await reloadVoices(select: r.answer.voice?.id)
        KadeHaptics.success()
        say(r.answer.spoken ?? "Saved \(name) to your voices.", then: .voice)
    }

    private func forgetVoice() async {
        guard let saved = chosenVoice else { return }
        let r = await service.forget(voiceId: saved.id)
        guard r.ok else { sayUrgent(r.sentence("Could not remove it. Try again.")); return }
        await reloadVoices()
        say(r.answer.spoken ?? "Removed from your voices. The recording stays in My Creations.", then: .voice)
    }

    private static let clipTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .wav, .mpeg4Audio]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        return types
    }()

    private func importClip(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            sayUrgent("Couldn't open that file. \(error.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            defer { isImporting = false }
            // A Files URL is security-scoped; without this pair the read fails.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 20 * 1024 * 1024 else {
                    sayUrgent("That clip is over twenty megabytes. Import a shorter clip.")
                    return
                }
                say("Importing \(url.lastPathComponent)…")
                let mime = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? "audio/mpeg"
                let imported = try await booth.importReference(data: data, fileName: url.lastPathComponent, mimeType: mime, engine: "scenema")
                clip = (url: imported.url, name: imported.name, seconds: imported.seconds)
                voiceChoice = "clip"
                if clipName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let base = (imported.name as NSString).deletingPathExtension
                    clipName = String(base.prefix(80))
                }
                Earcons.shared.play(.actionDone)
                let length = imported.seconds.map { ", \(Int($0.rounded())) seconds" } ?? ""
                say("Clip imported\(length). It will be the voice for the next take.")
            } catch {
                clip = nil
                Earcons.shared.play(.error)
                sayUrgent((error as? LocalizedError)?.errorDescription ?? "That clip could not be imported.")
            }
        }
    }
}
