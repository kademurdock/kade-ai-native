import PhotosUI
import SwiftUI
import UIKit

/// Create or edit one agent's core identity — see `AgentBuilderService`
/// for the server contract. Phase 1 shipped name, description,
/// persona/instructions, category, provider, model; Phase 2 added the TTS
/// voice picker, conversation starters, and an avatar photo (edit mode
/// only — the upload route needs an agent id to exist first). Tools/
/// actions, subagent edges, knowledge files, and version history are real
/// server capabilities deliberately not here yet.
///
/// One view handles both create and edit, matching this app's existing
/// shared-form precedent (`RoomListView`'s `NewRoomSheet` mirrors this same
/// "one sheet, `existingId == nil` decides the mode" shape, just without
/// the load-existing-data half). Presented as a `.sheet`, so a fresh
/// instance is created each time it's shown -- `.task` runs exactly once
/// per presentation, no extra guard needed beyond the `hasLoadedLookups`
/// flag this file still carries for consistency with every other screen
/// built this session.
struct AgentEditorView: View {
    let apiClient: KadeAPIClient
    let existingId: String?
    let onSaved: () -> Void

    @StateObject private var service: AgentBuilderService
    @Environment(\.dismiss) private var dismiss

    init(apiClient: KadeAPIClient, existingId: String?, onSaved: @escaping () -> Void) {
        self.apiClient = apiClient
        self.existingId = existingId
        self.onSaved = onSaved
        _service = StateObject(wrappedValue: AgentBuilderService(client: apiClient))
    }

    @State private var hasLoadedLookups = false
    @State private var isLoadingDetail = false
    @State private var loadError: String?
    @State private var categories: [AgentCategory] = []
    @State private var modelsConfig: [String: [String]] = [:]

    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var category = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var voice = ""
    @State private var showingVoicePicker = false
    @State private var starters: [String] = []
    @State private var availableTools: [AvailableTool] = []
    @State private var selectedTools: Set<String> = []
    /// Tool strings on the agent that aren't in the available-tools list
    /// (MCP entries, capabilities, anything newer than this build) ride
    /// along untouched on save — the editor only ever changes what it can
    /// actually display. If the lookup list itself failed to load, save
    /// sends nil and the server's tools stay exactly as they were.
    @State private var preservedUnknownTools: [String] = []
    @State private var toolsListLoaded = false
    @State private var showingVersionHistory = false
    @State private var loadedVersions: [AgentVersion] = []
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var pendingAvatarJpeg: Data?
    @State private var avatarNote: String?

    @State private var isSaving = false
    @State private var saveError: String?

    private var selectableCategories: [AgentCategory] {
        categories.filter { $0.value != "promoted" && $0.value != "all" }
    }

    private var sortedProviders: [String] {
        modelsConfig.keys.sorted()
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving && !isLoadingDetail
    }

    var body: some View {
        NavigationStack {
            Form {
                if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.red)
                    }
                }
                if isLoadingDetail {
                    ProgressView("Loading…")
                        .accessibilityLabel("Loading agent details")
                } else {
                    Section("Name") {
                        TextField("Name", text: $name)
                            .accessibilityLabel("Name")
                    }
                    Section("Description") {
                        TextField("A short line describing them", text: $description, axis: .vertical)
                            .accessibilityLabel("Description")
                    }
                    Section("Persona and instructions") {
                        TextField("Who they are, how they talk, what they know", text: $instructions, axis: .vertical)
                            .lineLimit(6...20)
                            .accessibilityLabel("Persona and instructions")
                    }
                    Section("Category") {
                        if selectableCategories.isEmpty {
                            Text("No categories available.").foregroundStyle(.secondary)
                        } else {
                            Picker("Category", selection: $category) {
                                Text("None").tag("")
                                ForEach(selectableCategories) { cat in
                                    Text(cat.label).tag(cat.value)
                                }
                            }
                            .accessibilityLabel("Category")
                        }
                    }
                    Section("Model") {
                        if sortedProviders.isEmpty {
                            Text("No models available.").foregroundStyle(.secondary)
                        } else {
                            Picker("Provider", selection: $provider) {
                                ForEach(sortedProviders, id: \.self) { p in
                                    Text(p).tag(p)
                                }
                            }
                            .accessibilityLabel("Provider")
                            .onChange(of: provider) { _, newValue in
                                let available = modelsConfig[newValue] ?? []
                                if !available.contains(model) {
                                    model = available.first ?? ""
                                }
                            }
                            let modelsForProvider = modelsConfig[provider] ?? []
                            if !modelsForProvider.isEmpty {
                                Picker("Model", selection: $model) {
                                    ForEach(modelsForProvider, id: \.self) { m in
                                        Text(m).tag(m)
                                    }
                                }
                                .accessibilityLabel("Model")
                            }
                        }
                    }
                    Section("Voice") {
                        Button {
                            showingVoicePicker = true
                        } label: {
                            HStack {
                                Text("Voice")
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Text(voice.isEmpty ? "Default" : voice)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        // NO .accessibilityElement(children: .ignore) here: that
                        // combo strips the button trait + double-tap activation
                        // on rows inside a FORM specifically (Kade, on-device,
                        // build 135: "it says voice but it isn't a pressable
                        // button") — while the identical pattern in Lists
                        // (agent rows, room rows, dictionary rows) works fine.
                        // An explicit label keeps the reading clean; the native
                        // element keeps it a real button.
                        .accessibilityLabel("Voice")
                        .accessibilityValue(voice.isEmpty ? "Default" : voice)
                        .accessibilityHint("Opens the voice library to browse, preview, and pick the voice this agent speaks in.")
                    }
                    Section {
                        ForEach(starters.indices, id: \.self) { i in
                            TextField("Starter \(i + 1)", text: starterBinding(at: i), axis: .vertical)
                                .accessibilityLabel("Conversation starter \(i + 1)")
                        }
                        .onDelete { starters.remove(atOffsets: $0) }
                        if starters.count < Self.maxStarters {
                            Button {
                                starters.append("")
                            } label: {
                                Label("Add a starter", systemImage: "plus")
                            }
                            .accessibilityHint("Adds another suggested opening line. Swipe up or down on a starter for its delete action.")
                        }
                    } header: {
                        Text("Conversation starters")
                    } footer: {
                        Text("Up to \(Self.maxStarters) tappable opening lines people see when they start a chat with this agent.")
                    }
                    if !availableTools.isEmpty {
                        Section {
                            DisclosureGroup {
                                ForEach(availableTools) { tool in
                                    Toggle(isOn: toolBinding(tool.pluginKey)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(tool.name)
                                            if let d = tool.description, !d.isEmpty {
                                                Text(d)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(3)
                                            }
                                        }
                                    }
                                    .accessibilityLabel(tool.name)
                                    .accessibilityHint(tool.description ?? "")
                                }
                            } label: {
                                Text("Tools")
                                    .accessibilityLabel("Tools. \(selectedTools.count) turned on.")
                                    .accessibilityHint("Expands the list of abilities this agent can use, like making pictures or sending phone notifications.")
                            }
                        } footer: {
                            Text("\(selectedTools.count) of \(availableTools.count) tools turned on. Tools give this agent real abilities — a picture maker, a phone-call placer, and so on.")
                        }
                    }
                    if existingId != nil {
                        Section {
                            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                                HStack {
                                    Text("Avatar photo")
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                    Text(pendingAvatarJpeg == nil ? "Choose…" : "Ready to save")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel("Avatar photo")
                            .accessibilityValue(pendingAvatarJpeg == nil ? "None chosen yet" : "Photo chosen, uploads when you save")
                            .accessibilityHint("Picks a photo from your library to use as this agent's picture.")
                            if let avatarNote {
                                Text(avatarNote)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Avatar")
                        }
                        Section {
                            Button {
                                showingVersionHistory = true
                            } label: {
                                HStack {
                                    Text("Version history")
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                    Text(loadedVersions.isEmpty ? "None yet" : "\(loadedVersions.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            // Same Form-row rule as the Voice button above.
                            .accessibilityLabel("Version history")
                            .accessibilityValue(loadedVersions.isEmpty ? "No earlier versions yet" : "\(loadedVersions.count) earlier version\(loadedVersions.count == 1 ? "" : "s")")
                            .accessibilityHint("Every save keeps the version it replaced. Open to restore any earlier one.")
                        }
                    }
                    if let saveError {
                        Section { Text(saveError).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(existingId == nil ? "New agent" : "Edit agent")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingVoicePicker) {
                VoicePickerView(apiClient: apiClient, selection: $voice)
            }
            .navigationDestination(isPresented: $showingVersionHistory) {
                if let existingId {
                    AgentVersionHistoryView(
                        apiClient: apiClient,
                        agentId: existingId,
                        versions: loadedVersions,
                        onReverted: {
                            Task { await loadExisting(existingId) }
                        }
                    )
                }
            }
            .onChange(of: avatarPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    guard let raw = try? await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: raw) else {
                        avatarNote = "Couldn't read that photo. Try a different one."
                        return
                    }
                    pendingAvatarJpeg = Self.avatarJpeg(from: image)
                    avatarNote = pendingAvatarJpeg == nil
                        ? "Couldn't prepare that photo. Try a different one."
                        : "Photo ready — it uploads when you press Save."
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .task {
                guard !hasLoadedLookups else { return }
                hasLoadedLookups = true

                async let cats = service.loadCategories()
                async let models = service.loadModelsConfig()
                async let tools = service.loadAvailableTools()
                categories = await cats
                modelsConfig = await models
                availableTools = await tools
                toolsListLoaded = !availableTools.isEmpty
                if provider.isEmpty, let firstProvider = modelsConfig.keys.sorted().first {
                    provider = firstProvider
                    model = modelsConfig[firstProvider]?.first ?? ""
                }

                guard let existingId else { return }
                await loadExisting(existingId)
            }
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let fields = AgentBuilderService.AgentFields(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            provider: provider,
            model: model,
            voice: voice,
            starters: starters
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            tools: toolsListLoaded
                ? preservedUnknownTools + availableTools.map(\.pluginKey).filter { selectedTools.contains($0) }
                : nil
        )
        do {
            if let existingId {
                _ = try await service.updateAgent(id: existingId, fields: fields)
                // Fields are saved server-side at this point even if the
                // photo below fails — a retry just re-saves the same values.
                if let jpeg = pendingAvatarJpeg {
                    try await service.uploadAvatar(id: existingId, jpegData: jpeg)
                }
            } else {
                _ = try await service.createAgent(fields)
            }
            dismiss()
            onSaved()
        } catch {
            saveError = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't save. Try again."
        }
    }

    /// Loads (or after a version restore, RE-loads) the agent into the form.
    private func loadExisting(_ id: String) async {
        isLoadingDetail = true
        do {
            let detail = try await service.loadDetail(id: id)
            name = detail.name ?? ""
            description = detail.description ?? ""
            instructions = detail.instructions ?? ""
            category = detail.category ?? ""
            if let p = detail.provider, !p.isEmpty { provider = p }
            if let m = detail.model, !m.isEmpty { model = m }
            voice = detail.tts?.voiceId ?? ""
            starters = detail.conversation_starters ?? []
            let agentTools = detail.tools ?? []
            let known = Set(availableTools.map { $0.pluginKey })
            selectedTools = Set(agentTools.filter { known.contains($0) })
            preservedUnknownTools = agentTools.filter { !known.contains($0) }
            loadedVersions = detail.versions ?? []
            loadError = nil
        } catch {
            loadError = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't load that agent."
        }
        isLoadingDetail = false
    }

    private static let maxStarters = 4

    private func toolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { selectedTools.contains(key) },
            set: { on in
                if on { selectedTools.insert(key) } else { selectedTools.remove(key) }
            }
        )
    }

    /// Index-guarded binding — a starter row can be deleted out from under
    /// an in-flight keyboard commit, and an unguarded `$starters[i]` is an
    /// index-out-of-range crash waiting for exactly that moment.
    private func starterBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < starters.count ? starters[index] : "" },
            set: { newValue in
                if index < starters.count { starters[index] = newValue }
            }
        )
    }

    /// Downscale to a sane avatar size and re-encode as JPEG — camera-roll
    /// photos can arrive as multi-megabyte HEIC, and JPEG at ~1024px is
    /// both universally parseable server-side and plenty for an avatar.
    private static func avatarJpeg(from image: UIImage, maxEdge: CGFloat = 1024) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxEdge / longest)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return scaled.jpegData(compressionQuality: 0.85)
    }
}
