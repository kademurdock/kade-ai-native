import SwiftUI

/// Create or edit one agent's core identity — see `AgentBuilderService`
/// for the server contract and the Phase 1 scope note (name, description,
/// persona/instructions, category, provider, model; tools/actions,
/// subagent edges, knowledge files, TTS voice, conversation starters, and
/// version history are real but deliberately not here yet).
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Voice")
                        .accessibilityValue(voice.isEmpty ? "Default" : voice)
                        .accessibilityHint("Opens the voice library to browse, preview, and pick the voice this agent speaks in.")
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
                categories = await cats
                modelsConfig = await models
                if provider.isEmpty, let firstProvider = modelsConfig.keys.sorted().first {
                    provider = firstProvider
                    model = modelsConfig[firstProvider]?.first ?? ""
                }

                guard let existingId else { return }
                isLoadingDetail = true
                do {
                    let detail = try await service.loadDetail(id: existingId)
                    name = detail.name ?? ""
                    description = detail.description ?? ""
                    instructions = detail.instructions ?? ""
                    category = detail.category ?? ""
                    if let p = detail.provider, !p.isEmpty { provider = p }
                    if let m = detail.model, !m.isEmpty { model = m }
                    voice = detail.tts?.voiceId ?? ""
                } catch {
                    loadError = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't load that agent."
                }
                isLoadingDetail = false
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
            voice: voice
        )
        do {
            if let existingId {
                _ = try await service.updateAgent(id: existingId, fields: fields)
            } else {
                _ = try await service.createAgent(fields)
            }
            dismiss()
            onSaved()
        } catch {
            saveError = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't save. Try again."
        }
    }
}
