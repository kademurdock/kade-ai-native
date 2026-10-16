import SwiftUI
import UIKit

/// Oct 16 2026: the Body editor's state. Everything it shows comes from the
/// server (the catalog, previews, designs); the phone keeps only the draft
/// recipe and a local Undo list. A change asks for a preview 250 ms after the
/// last touch, one request at a time, so a dragged slider costs a few
/// previews, not one per step (every request also waits on the shared pacing
/// gate). The words that changed are said once the preview settles.
@MainActor
final class PuppetBuilderModel: ObservableObject {
    enum Busy: Equatable { case surprise, words, portrait, save, remove }

    @Published private(set) var catalog: PuppetCatalog?
    @Published private(set) var loadError: String?
    @Published private(set) var draft: PuppetJSON = .null
    /// What the server holds (nil: no body yet). Unsaved = the draft differs.
    @Published private(set) var savedRecipe: PuppetJSON?
    @Published private(set) var renderer: PuppetRenderer?
    @Published private(set) var description = ""
    @Published private(set) var baseRev = 0
    @Published private(set) var busy: Busy?
    @Published private(set) var history = PuppetEditHistory()
    @Published var status: String?
    /// A save found someone else's newer version (or their removal).
    @Published var conflict: PuppetBodyReply?

    let agentId: String
    private let service: PuppetBuilderService
    private weak var store: PuppetStore?
    private var defaults: PuppetJSON = .object([:])
    private var source = "editor"
    /// Bumped when a whole body arrives (a design, their version), so an older
    /// preview still in flight never draws over it.
    private var generation = 0
    private var previewWanted: PuppetJSON?
    private var previewRunning = false
    private var previewDebounce: Task<Void, Never>?
    private var previewError: String?
    private var announceTask: Task<Void, Never>?
    private var spokenDescription = ""
    private var loading = false

    init(client: KadeAPIClient, agentId: String) {
        self.agentId = agentId
        self.service = PuppetBuilderService(client: client)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The DEBUG gallery's offline editor (no store, no network).
    static func gallery(client: KadeAPIClient, sample: PuppetBuilderSample) -> PuppetBuilderModel {
        let model = PuppetBuilderModel(client: client, agentId: "agent_gallery_sample")
        model.service.sample = sample
        return model
    }
    #endif

    var hasSaved: Bool { savedRecipe != nil }
    var dirty: Bool { savedRecipe.map { $0 != draft } ?? true }
    var canSave: Bool { catalog != nil && busy == nil && draft != .null && dirty }

    func attach(_ store: PuppetStore) {
        #if DEBUG && targetEnvironment(simulator)
        if service.sample != nil { return }
        #endif
        self.store = store
    }

    func load() async {
        guard catalog == nil, !loading else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let catalogReply = try await service.catalog()
            let (body, data, etag) = try await service.body(agentId: agentId)
            defaults = catalogReply.defaults
            baseRev = body.recipe == nil ? 0 : body.rev
            savedRecipe = body.recipe
            draft = body.recipe ?? catalogReply.defaults
            renderer = body.renderer
            description = body.description
            spokenDescription = body.description
            if let kept = store?.editorDrafts[agentId], kept.recipe != draft {
                draft = kept.recipe
                baseRev = kept.baseRev
                source = kept.source
                status = "Your unsaved changes from before are back. Save keeps them."
            }
            catalog = catalogReply.catalog
            if renderer == nil || draft != body.recipe { schedulePreview() }
            await store?.adopt(data, agentId: agentId, etag: etag)
        } catch {
            loadError = message(error, "The body editor is unavailable right now.")
        }
    }

    // MARK: editing

    func choose(_ option: PuppetCatalog.Option, for control: PuppetCatalog.Control) {
        change(PuppetRecipeEdit.choosing(option.id, for: control, in: draft), label: control.name, key: control.id)
    }

    func setSlider(_ value: Double, for control: PuppetCatalog.Control) {
        change(PuppetRecipeEdit.setting(slider: value, for: control, in: draft), label: control.name, key: control.id)
    }

    private func change(_ next: PuppetJSON, label: String, key: String) {
        guard catalog != nil, next != draft else { return }
        history.record(before: draft, label: label, key: key)
        draft = next
        source = "editor"
        status = nil
        schedulePreview()
    }

    func undo() {
        guard busy == nil, let entry = history.undo() else { return }
        draft = entry.recipe
        source = "editor"
        status = "Undone: \(entry.label)."
        say(status ?? "")
        schedulePreview()
    }

    // MARK: previews

    private func schedulePreview() {
        previewDebounce?.cancel()
        previewDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.previewWanted = self.draft
            self.drainPreviews()
        }
    }

    /// One preview request at a time; the newest draft wins. Never cancelled
    /// mid-flight, so a request is never thrown away after taking its turn.
    private func drainPreviews() {
        guard !previewRunning else { return }
        previewRunning = true
        Task { [weak self] in await self?.runPreviews() }
    }

    private func runPreviews() async {
        while let recipe = previewWanted {
            previewWanted = nil
            let started = generation
            do {
                let reply = try await service.preview(recipe)
                guard started == generation else { continue }
                if let drawn = reply.renderer { renderer = drawn }
                if status != nil, status == previewError { status = nil }
                previewError = nil
                if !reply.description.isEmpty, reply.description != description {
                    description = reply.description
                    // A first body's words are on screen; only later changes are said.
                    if spokenDescription.isEmpty { spokenDescription = reply.description } else { descriptionChanged() }
                }
            } catch {
                if previewWanted == nil, started == generation {
                    previewError = message(error, "The preview could not be drawn. Your change is kept.")
                    status = previewError
                }
            }
        }
        previewRunning = false
    }

    /// Says the sentences that changed since the last thing said, once the
    /// words have been still for a moment (a slider run speaks once).
    private func descriptionChanged() {
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            let changed = PuppetDescriptionText.changedSentences(before: self.spokenDescription, after: self.description)
            self.spokenDescription = self.description
            self.say(changed)
        }
    }

    /// Polite and queued: VoiceOver finishes what it is saying first.
    func say(_ text: String) {
        guard !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: text, attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: true)]))
    }

    // MARK: designs

    func surprise() async {
        let seed = "\(agentId)-\(Int(Date().timeIntervalSince1970 * 1000))"
        await design(.surprise, label: "Surprise me", source: "surprise") { try await $0.surprise(seed: seed) }
    }

    /// True when the new look arrived (the words sheet then closes).
    func fromWords(_ words: String) async -> Bool {
        let trimmed = String(words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
        guard trimmed.count >= 3 else {
            status = "Describe the look in a few words first."
            return false
        }
        let base = draft
        return await design(.words, label: "Describe it in words", source: "words") {
            try await $0.fromWords(trimmed, base: base)
        }
    }

    func fromPortrait() async {
        let id = agentId
        await design(.portrait, label: "Match the portrait", source: "picture") { try await $0.fromPortrait(agentId: id) }
    }

    @discardableResult
    private func design(_ kind: Busy, label: String, source madeBy: String,
                        _ run: (PuppetBuilderService) async throws -> PuppetBodyReply) async -> Bool {
        guard busy == nil, catalog != nil else { return false }
        busy = kind
        status = "Designing…"
        if kind != .surprise { say("Designing. This can take a few seconds.") }
        defer { busy = nil }
        do {
            let reply = try await run(service)
            guard let recipe = reply.recipe else {
                throw PuppetBuilderService.Failure(message: "That design came back empty. Try again.")
            }
            history.record(before: draft, label: label, key: "design-" + UUID().uuidString)
            generation += 1
            previewDebounce?.cancel()
            previewWanted = nil
            announceTask?.cancel()
            draft = recipe
            if let drawn = reply.renderer { renderer = drawn }
            description = reply.description
            spokenDescription = reply.description
            source = madeBy
            var spoken = "New look. " + reply.description
            if let cost = reply.costUSD {
                let line = "This cost about \(PuppetDescriptionText.dollars(cost))."
                status = line
                spoken += " " + line
            } else {
                status = "New look ready. Save keeps it."
            }
            say(spoken)
            return true
        } catch {
            let words = message(error, "That did not work. Try again.")
            status = words
            say(words)
            return false
        }
    }

    // MARK: saving

    func save(overRev: Int? = nil) async {
        guard busy == nil, catalog != nil, draft != .null else { return }
        busy = .save
        defer { busy = nil }
        let sent = draft
        do {
            switch try await service.save(agentId: agentId, recipe: sent, baseRev: overRev ?? baseRev, source: source) {
            case .saved(let reply, let data):
                baseRev = reply.rev
                savedRecipe = sent
                store?.editorDrafts[agentId] = nil
                status = "Body saved. Chat and calls show it now."
                say(status ?? "")
                // The PUT reply is GET's shape; its ETag is GET's "rev-sceneHash".
                await store?.adopt(data, agentId: agentId, etag: reply.sceneHash.map { "\"\(reply.rev)-\($0)\"" })
            case .conflict(let latest):
                conflict = latest
            }
        } catch {
            let words = message(error, "That body could not be saved.")
            status = words
            say(words)
        }
    }

    func loadTheirs(_ latest: PuppetBodyReply) {
        conflict = nil
        history.record(before: draft, label: "Load their version", key: "theirs-" + UUID().uuidString)
        generation += 1
        previewDebounce?.cancel()
        previewWanted = nil
        announceTask?.cancel()
        baseRev = latest.recipe == nil ? 0 : latest.rev
        savedRecipe = latest.recipe
        source = "editor"
        status = nil
        if let recipe = latest.recipe {
            draft = recipe
            if let drawn = latest.renderer { renderer = drawn } else { schedulePreview() }
            description = latest.description
            spokenDescription = latest.description
            say("Their version is loaded. " + latest.description)
        } else {
            draft = defaults
            schedulePreview()
            say("They removed the body. Save gives this character a body again.")
        }
    }

    func keepMineAndSave(over latest: PuppetBodyReply) async {
        conflict = nil
        await save(overRev: latest.rev)
    }

    func remove() async {
        guard busy == nil, hasSaved else { return }
        busy = .remove
        defer { busy = nil }
        do {
            try await service.remove(agentId: agentId)
            store?.removed(agentId: agentId)
            store?.editorDrafts[agentId] = nil
            history.record(before: draft, label: "Remove body", key: "remove-" + UUID().uuidString)
            baseRev = 0
            savedRecipe = nil
            source = "editor"
            draft = defaults
            schedulePreview()
            status = "Body removed. The character shows its portrait again."
            say(status ?? "")
        } catch {
            let words = message(error, "That body could not be removed.")
            status = words
            say(words)
        }
    }

    /// Going Back without saving keeps the work in memory for next time.
    func keepUnsavedDraft() {
        guard catalog != nil, draft != .null else { return }
        let changed = hasSaved ? dirty : history.canUndo
        store?.editorDrafts[agentId] = changed ? PuppetEditorDraft(recipe: draft, baseRev: baseRev, source: source) : nil
    }

    private func message(_ error: Error, _ fallback: String) -> String {
        if let failure = error as? PuppetBuilderService.Failure { return failure.message }
        if error is URLError { return "The connection dropped. Check the internet and try again." }
        return fallback
    }
}

/// The expression buttons under the preview: what each one plays.
enum PuppetTryExpression: String, CaseIterable, Identifiable {
    case smile, laugh, surprised, thinking, sad, wink
    var id: String { rawValue }

    var name: String {
        switch self {
        case .smile: return "Smile"
        case .laugh: return "Laugh"
        case .surprised: return "Surprised"
        case .thinking: return "Thinking"
        case .sad: return "Sad"
        case .wink: return "Wink"
        }
    }

    var presentation: CharacterPresentation {
        switch self {
        case .smile: return CharacterPresentation(expression: .amused)
        case .laugh: return CharacterPresentation(expression: .amused, laughing: true)
        case .surprised: return CharacterPresentation(expression: .surprised)
        case .thinking: return CharacterPresentation(expression: .thoughtful)
        case .sad: return CharacterPresentation(expression: .sad)
        case .wink: return CharacterPresentation(expression: .playful)
        }
    }
}

/// Oct 16 2026: the Body editor, VoiceOver first. The moving preview is for
/// the people watching (hidden from VoiceOver, still under Reduce Motion); the
/// "Current look" words are the body for everyone else, and the words that
/// change are said after each change. Every control comes from the server's
/// catalog: lists for parts and colours (the colour's name is what is read),
/// sliders that say their nearer end, and one list per accessory slot.
struct PuppetBuilderView: View {
    let agentId: String
    let agentName: String
    @StateObject private var model: PuppetBuilderModel
    @EnvironmentObject private var puppets: PuppetStore
    @EnvironmentObject private var agents: AgentsService
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var trying: PuppetTryExpression? = nil
    @State private var tryTask: Task<Void, Never>? = nil
    @State private var onScreen = false
    @State private var showingWords = false
    @State private var confirmingRemove = false
    /// DEBUG gallery only: the row the screen starts scrolled to.
    private var scrollTarget: String? = nil
    static let stageSide: CGFloat = 200

    init(apiClient: KadeAPIClient, agentId: String, agentName: String) {
        self.agentId = agentId
        self.agentName = agentName
        _model = StateObject(wrappedValue: PuppetBuilderModel(client: apiClient, agentId: agentId))
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The DEBUG gallery's offline editor.
    init(model: @autoclosure @escaping () -> PuppetBuilderModel, agentId: String, agentName: String,
         scrollTarget: String? = nil) {
        self.agentId = agentId
        self.agentName = agentName
        self.scrollTarget = scrollTarget
        _model = StateObject(wrappedValue: model())
    }
    #endif

    private var agent: KadeAgent? { agents.agents.first { $0.id == agentId } }
    /// Unknown until the roster loads; the server then says if there is none.
    private var hasPortrait: Bool { agent.map { $0.avatar?.filepath != nil } ?? true }
    private var handMade: Bool { CharacterMotion.prepared(id: agentId, path: agent?.avatar?.filepath) }

    var body: some View {
        ScrollViewReader { proxy in
            controlList
                .onChange(of: model.catalog != nil) { _, loaded in
                    guard loaded, let scrollTarget else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        proxy.scrollTo(scrollTarget, anchor: .top)
                    }
                }
        }
        .navigationTitle("Puppet body")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await model.save() } }
                    .disabled(!model.canSave)
                    .accessibilityLabel("Save body")
                    .accessibilityInputLabels([Text("Save"), Text("Save body")])
                    .accessibilityValue(model.busy == .save ? "Saving" : "")
                    .accessibilityHint("Saves this body for \(agentName). Chat and calls show it right away.")
            }
        }
        .task {
            model.attach(puppets)
            await model.load()
        }
        .onAppear { onScreen = true }
        .onDisappear {
            onScreen = false
            model.keepUnsavedDraft()
        }
        .sheet(isPresented: $showingWords) { PuppetWordsSheet(model: model) }
        .alert("Someone else changed this body", isPresented: conflictShown, presenting: model.conflict) { latest in
            Button("Load theirs") { model.loadTheirs(latest) }
            Button("Keep mine and save") { Task { await model.keepMineAndSave(over: latest) } }
        } message: { latest in
            Text(conflictMessage(latest))
        }
        .alert("Remove this body?", isPresented: $confirmingRemove) {
            Button("Remove body", role: .destructive) { Task { await model.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(agentName) goes back to the portrait in chat and calls.")
        }
    }

    private var controlList: some View {
        List {
            lookSection
            if let catalog = model.catalog {
                actionSection
                ForEach(catalog.sections) { section in
                    let controls = section.controls.filter(\.isEditable)
                    if !controls.isEmpty {
                        Section {
                            ForEach(controls) { control in controlRow(control).id(control.id) }
                        } header: {
                            Text(section.name).accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                if model.hasSaved { removeSection }
            } else if let error = model.loadError {
                Section {
                    Text(error)
                    Button("Try again") { Task { await model.load() } }
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().accessibilityHidden(true)
                        Text("Loading the body parts…")
                    }
                }
            }
        }
    }

    private func conflictMessage(_ latest: PuppetBodyReply) -> String {
        latest.recipe == nil
            ? "They removed the body. Load theirs goes back to the portrait; Keep mine saves yours."
            : "Their version: " + latest.description
    }

    private var conflictShown: Binding<Bool> {
        Binding(get: { model.conflict != nil }, set: { if !$0 { model.conflict = nil } })
    }

    // MARK: preview and words

    private var lookSection: some View {
        Section {
            stage
            expressionButtons
            VStack(alignment: .leading, spacing: 4) {
                Text("Current look").font(.headline)
                Text(lookText).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current look: " + lookText)
            // One line that is always there, so nothing below moves when it changes.
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(model.catalog == nil && model.status == nil)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The character is told how it looks, so when someone asks “what do you look like?” it answers from this description.")
                if handMade {
                    Text("This character also has a hand-made animated face, which chat and calls keep using.")
                }
            }
        }
    }

    private var stage: some View {
        ZStack {
            if let renderer = model.renderer {
                PuppetStageView(renderer: renderer, agentID: agentId,
                    presentation: { trying?.presentation ?? .idle }, hostActive: onScreen)
            } else {
                RoundedRectangle(cornerRadius: 22).fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: Self.stageSide, height: Self.stageSide)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    private var expressionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try an expression")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 96), spacing: 8)],
                      spacing: 8) {
                ForEach(PuppetTryExpression.allCases) { expression in
                    Button { play(expression) } label: {
                        Text(expression.name).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.renderer == nil)
                    .accessibilityHint("Plays this expression on the moving picture for a few seconds, for anyone watching the screen.")
                    .accessibilityAddTraits(trying == expression ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Try an expression")
    }

    private func play(_ expression: PuppetTryExpression) {
        tryTask?.cancel()
        trying = expression
        model.say("Showing \(expression.name.lowercased()) on the picture.")
        tryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            trying = nil
        }
    }

    private var lookText: String {
        if !model.description.isEmpty { return model.description }
        return model.catalog == nil && model.loadError == nil ? "Loading…" : "No description yet."
    }

    private var statusLine: String {
        if let status = model.status { return status }
        guard model.catalog != nil else { return " " }
        if !model.hasSaved { return "Not saved yet. Save gives \(agentName) this body." }
        return model.dirty ? "Unsaved changes. Save keeps them." : "Saved. Chat and calls show this body."
    }

    // MARK: actions

    private var actionSection: some View {
        Section {
            actionButton("Surprise me", icon: "dice", kind: .surprise,
                hint: "Makes a random new look. Nothing is saved until you tap Save.") {
                Task { await model.surprise() }
            }
            .id("actions")
            actionButton("Describe it in words", icon: "text.bubble", kind: .words,
                hint: "Type or dictate the look you want. A small paid design that changes only what your words mention.") {
                showingWords = true
            }
            actionButton("Match the portrait", icon: "person.crop.square", kind: .portrait,
                hint: hasPortrait ? "Designs a body that looks like \(agentName)'s portrait. A small paid design."
                    : "\(agentName) has no portrait yet. Add an avatar photo in the editor first.") {
                Task { await model.fromPortrait() }
            }
            .disabled(!hasPortrait)
            Button { model.undo() } label: {
                Label("Undo last change", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.history.canUndo || model.busy != nil)
            .accessibilityValue(model.history.lastLabel ?? "Nothing to undo")
            .accessibilityHint("Goes back one change. The Undo list lives on this phone until you leave this screen.")
        } header: {
            Text("Quick looks").accessibilityAddTraits(.isHeader)
        }
    }

    private func actionButton(_ title: String, icon: String, kind: PuppetBuilderModel.Busy, hint: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer(minLength: 8)
                if model.busy == kind { ProgressView().accessibilityHidden(true) }
            }
        }
        .disabled(model.busy != nil)
        .accessibilityLabel(title)
        .accessibilityValue(model.busy == kind ? "Working" : "")
        .accessibilityHint(hint)
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) { confirmingRemove = true } label: {
                Text("Remove body")
            }
            .disabled(model.busy != nil)
            .accessibilityHint("Asks first, then \(agentName) goes back to the portrait.")
        }
    }

    // MARK: controls

    @ViewBuilder private func controlRow(_ control: PuppetCatalog.Control) -> some View {
        if control.kind == .slider {
            PuppetSliderRow(control: control, model: model)
        } else {
            let chosen = PuppetRecipeEdit.selectedOption(control, in: model.draft)
            NavigationLink {
                PuppetOptionList(control: control, model: model)
            } label: {
                PuppetControlLabel(control: control, chosen: chosen)
            }
            .accessibilityLabel(control.name)
            .accessibilityValue(chosen?.name ?? "Not chosen")
        }
    }
}

/// A list row's words: the control's name and what it is set to now.
private struct PuppetControlLabel: View {
    let control: PuppetCatalog.Control
    let chosen: PuppetCatalog.Option?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Text(control.name).foregroundStyle(Color.primary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            HStack(spacing: 8) {
                if control.kind == .color { PuppetSwatch(hex: chosen?.hex) }
                Text(chosen?.name ?? "Not chosen")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
    }
}

/// One slider. VoiceOver hears the control's name, the nearer end in the
/// catalog's own words with the percent, and both ends in the hint.
private struct PuppetSliderRow: View {
    let control: PuppetCatalog.Control
    @ObservedObject var model: PuppetBuilderModel

    var body: some View {
        let value = PuppetRecipeEdit.sliderValue(control, in: model.draft)
        VStack(alignment: .leading, spacing: 4) {
            Text(control.name).accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { model.setSlider($0, for: control) }), in: 0...1, step: 0.1)
                .accessibilityLabel(control.name)
                .accessibilityValue(PuppetRecipeEdit.sliderWords(value, low: control.low, high: control.high))
                .accessibilityHint("Goes from \(control.low) to \(control.high).")
            HStack {
                Text(control.low)
                Spacer(minLength: 8)
                Text(control.high).multilineTextAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }
}

/// The options of one part, colour or accessory slot. Choosing one changes the
/// preview at once and stays on this list, so options can be tried in a row;
/// Back returns to the editor. Nothing saves until Save.
struct PuppetOptionList: View {
    let control: PuppetCatalog.Control
    @ObservedObject var model: PuppetBuilderModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var onScreen = false

    var body: some View {
        let selected = PuppetRecipeEdit.selectedID(control, in: model.draft)
        List {
            if typeSize.isAccessibilitySize {
                Section { preview(side: 160) }
            }
            Section {
                ForEach(control.options) { option in
                    Button { model.choose(option, for: control) } label: {
                        HStack(spacing: 12) {
                            if control.kind == .color { PuppetSwatch(hex: option.hex) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name).foregroundStyle(Color.primary)
                                if !option.extraNote.isEmpty {
                                    Text(option.extraNote).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                                .opacity(option.id == selected ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(option.name)
                    .accessibilityHint(hint(option))
                    .accessibilityAddTraits(option.id == selected ? .isSelected : [])
                }
            } footer: {
                Text("Each choice changes the picture and the words right away. Nothing is saved until you tap Save on the body screen.")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                preview(side: 132)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .navigationTitle(control.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private func preview(side: CGFloat) -> some View {
        ZStack {
            if let renderer = model.renderer {
                PuppetStageView(renderer: renderer, agentID: model.agentId, hostActive: onScreen)
            } else {
                RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func hint(_ option: PuppetCatalog.Option) -> String {
        if control.kind == .accessory && option.id.isEmpty { return "Wears nothing here." }
        if option.fantasy { return option.extraNote.isEmpty ? "A fantasy colour." : option.extraNote + ". A fantasy colour." }
        return option.extraNote
    }
}

/// A colour's swatch, for the eyes only: the name beside it is what is read.
struct PuppetSwatch: View {
    let hex: String?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 26

    var body: some View {
        Group {
            if let color = Self.color(hex) {
                Circle().fill(color)
            } else {
                // "Same as hair", "Natural": no colour of their own.
                Image(systemName: "circle.lefthalf.filled").resizable().foregroundStyle(.secondary)
            }
        }
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    static func color(_ hex: String?) -> Color? {
        guard let hex, hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }
}

/// "Describe it in words": a plain text box that takes typing or dictation,
/// and Make it. The words change only what they mention (the current body is
/// sent along as the base). A small paid design; its cost is shown after.
private struct PuppetWordsSheet: View {
    @ObservedObject var model: PuppetBuilderModel
    @Environment(\.dismiss) private var dismiss
    @State private var words = ""
    @State private var problem: String? = nil
    @FocusState private var editing: Bool

    private var ready: Bool { words.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && model.busy == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $words)
                        .frame(minHeight: 150)
                        .focused($editing)
                        .accessibilityLabel("Describe the look")
                        .accessibilityHint("For example: a tall cowboy with a gray handlebar mustache. Typing and dictation both work.")
                        .onChange(of: words) { _, new in
                            if new.count > 1500 { words = String(new.prefix(1500)) }
                        }
                } header: {
                    Text("Describe the look")
                } footer: {
                    Text("For example: a tall cowboy with a gray handlebar mustache. Your words change only what they mention. This is a small paid design; the cost shows when it is done.")
                }
                Section {
                    if model.busy == .words {
                        HStack(spacing: 10) {
                            ProgressView().accessibilityHidden(true)
                            Text("Designing…")
                        }
                    } else if let problem {
                        Text(problem)
                    } else {
                        Text("When the words read right, tap Make it at the top right.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Describe it in words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make it") {
                        Task {
                            problem = nil
                            if await model.fromWords(words) { dismiss() } else { problem = model.status }
                        }
                    }
                    .disabled(!ready)
                    .accessibilityHint("Designs a body from your words. A small paid design.")
                }
            }
            .task {
                // The keyboard comes up by itself for touch; VoiceOver starts on the title.
                guard !UIAccessibility.isVoiceOverRunning else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                editing = true
            }
        }
    }
}

/// The "Body" row in the agent editor: the body in words, and the way into
/// the editor. The words come from the same cache the chat stage uses.
struct PuppetBodyLink: View {
    let apiClient: KadeAPIClient
    let agentId: String
    let agentName: String
    @EnvironmentObject private var puppets: PuppetStore

    var body: some View {
        NavigationLink {
            PuppetBuilderView(apiClient: apiClient, agentId: agentId, agentName: agentName)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Puppet body").foregroundStyle(Color.primary)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Puppet body")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the body editor: a drawn body that moves while this character talks.")
        .task(id: agentId) {
            await puppets.loadCached(agentId: agentId)
            await puppets.refreshIfNeeded(agentId: agentId)
        }
    }

    private var summary: String {
        if let words = puppets.description(for: agentId) { return words }
        if puppets.bodiless.contains(agentId) { return "No body yet. The character shows its portrait." }
        return "Open to see or build this character's body."
    }
}
