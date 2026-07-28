import SwiftUI

/// THE PROMPT LIBRARY — native prompts/presets (July 28 2026, leftovers
/// item 5; web parity). Browse every prompt you can see (yours + shared),
/// hear the one-liner on the row, open one to hear the full text, then
/// either copy it or drop it straight into a fresh chat with the main
/// agent — `ConversationDetailView(initialDraft:)` seeds the composer, so
/// "Use this prompt" is: tap, land in chat, the text is already in the
/// message field, hit Send (or edit it first). Saving a new prompt is a
/// small form on this same screen. Search matches names server-side.
struct PromptsView: View {
    @StateObject private var service: PromptsService
    @State private var searchText = ""
    @State private var openedGroup: KadePromptGroup?
    @State private var showNewPromptForm = false
    @State private var announcement: String?
    /// One keyboard mirror per screen visit; the refresh gesture re-fires it.
    @State private var mirroredToKadeKeys = false

    private let apiClient: KadeAPIClient
    private let mainAgentId: String?

    init(apiClient: KadeAPIClient, mainAgentId: String?) {
        self.apiClient = apiClient
        self.mainAgentId = mainAgentId
        _service = StateObject(wrappedValue: PromptsService(client: apiClient))
    }

    var body: some View {
        List {
            Section {
                if service.groups.isEmpty && !service.isLoading {
                    Text(
                        searchText.isEmpty
                            ? "No saved prompts yet. \u{201C}Save a new prompt\u{201D} below starts your library."
                            : "Nothing matches \u{201C}\(searchText)\u{201D}."
                    )
                    .foregroundStyle(.secondary)
                }
                ForEach(service.groups) { group in
                    Button {
                        openedGroup = group
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                            if let subtitle = group.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .accessibilityHint("Opens the full prompt, with Use and Copy.")
                    .onAppear {
                        if group.id == service.groups.last?.id {
                            Task { await service.loadMore() }
                        }
                    }
                }
                if service.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("Saved prompts")
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                Button {
                    showNewPromptForm = true
                } label: {
                    Label("Save a new prompt", systemImage: "plus")
                }
                .accessibilityHint("A short form: name, the prompt text, and an optional one-line description.")
            }
        }
        .navigationTitle("Prompts")
        .searchable(text: $searchText, prompt: "Search prompts by name")
        .onSubmit(of: .search) {
            Task { await service.loadGroups(name: searchText) }
        }
        .onChange(of: searchText) { _, newValue in
            // Clearing the field restores the full library without
            // needing a second explicit search action.
            if newValue.isEmpty {
                Task { await service.loadGroups() }
            }
        }
        .task {
            if service.groups.isEmpty { await service.loadGroups() }
            // KADE KEYS phase 2: opening the library is also what feeds
            // the keyboard its offline copy. Unstructured Task on purpose
            // -- the mirror takes up to ~18s behind the client's pacing
            // gate, and backing out of this screen must not strand a
            // half-written set (the writer only writes a COMPLETE list).
            if !mirroredToKadeKeys {
                mirroredToKadeKeys = true
                Task { await mirrorToKadeKeys() }
            }
        }
        .refreshable {
            await service.loadGroups(name: searchText.isEmpty ? nil : searchText)
            Task { await mirrorToKadeKeys() }
        }
        .overlay {
            if service.isLoading && service.groups.isEmpty {
                ProgressView("Loading prompts")
            }
        }
        .sheet(item: $openedGroup) { group in
            PromptDetailSheet(
                group: group,
                service: service,
                mainAgentId: mainAgentId,
                onAnnounce: { announcement = $0 }
            )
        }
        .sheet(isPresented: $showNewPromptForm) {
            NewPromptSheet(service: service) { announcement = $0 }
        }
        .onChange(of: announcement) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            announcement = nil
        }
    }
    /// KADE KEYS phase 2 (July 28 2026): mirror the first prompts (title +
    /// live production text) into the shared App Group container so the
    /// keyboard can type them offline. Economics: at most
    /// `KadeKeysSharedStore.maxPrompts` text fetches, each behind
    /// KadeAPIClient's own pacing gate, all fail-soft. The mirror only
    /// writes a COMPLETE list -- a cancelled or flaky pass leaves the
    /// keyboard's previous copy untouched rather than shrinking it.
    private func mirrorToKadeKeys() async {
        let candidates = service.groups
            .filter { $0.productionId != nil }
            .prefix(KadeKeysSharedStore.maxPrompts)
        guard !candidates.isEmpty else { return }
        var shared: [KadeKeysSharedStore.SharedPrompt] = []
        for group in candidates {
            if Task.isCancelled { return }
            guard let text = await service.promptText(for: group),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            shared.append(.init(title: group.name, text: text))
        }
        guard !shared.isEmpty else { return }
        KadeKeysSharedStore.write(shared)
    }

}

/// One prompt, opened: the full text (selectable, one VoiceOver element),
/// Use in a new chat, Copy, and Delete when it's yours to delete.
private struct PromptDetailSheet: View {
    let group: KadePromptGroup
    @ObservedObject var service: PromptsService
    let mainAgentId: String?
    let onAnnounce: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var loadFailed = false
    @State private var usingPrompt = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle = group.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let text {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if loadFailed {
                        Text("Couldn't load this prompt's text. Close and try again.")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Loading the prompt")
                    }
                }
                .padding()
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        usingPrompt = true
                    } label: {
                        Label("Use in a new chat", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text == nil)
                    .accessibilityHint("Opens a fresh chat with this prompt already typed into the message field.")

                    HStack {
                        Button {
                            UIPasteboard.general.string = text
                            onAnnounce("Prompt copied.")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(text == nil)

                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Deletes this prompt from the library. The server refuses if it isn't yours.")
                    }
                }
                .padding()
                .background(.thinMaterial)
            }
            .navigationDestination(isPresented: $usingPrompt) {
                ConversationDetailView(
                    conversation: nil,
                    initialAgentId: mainAgentId,
                    initialDraft: text
                )
            }
            .confirmationDialog(
                "Delete \u{201C}\(group.name)\u{201D} from the library?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete prompt", role: .destructive) {
                    Task {
                        if await service.deleteGroup(group) {
                            onAnnounce("Deleted \(group.name).")
                            dismiss()
                        } else {
                            onAnnounce("Couldn't delete that one - it may not be yours to delete.")
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                text = await service.promptText(for: group)
                loadFailed = (text == nil)
            }
        }
    }
}

/// The "save a new prompt" form: name + text required, one-liner and
/// category optional. Nothing fancy — the web builder remains the place
/// for variables and versioning; this covers the everyday "keep this
/// prompt where my thumb can find it."
private struct NewPromptSheet: View {
    @ObservedObject var service: PromptsService
    let onAnnounce: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var oneliner = ""
    @State private var category = ""
    @State private var saving = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.trimmingCharacters(in: .whitespaces).isEmpty
            && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } header: {
                    Text("What's it called?")
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    TextField("The prompt itself", text: $text, axis: .vertical)
                        .lineLimit(6...16)
                } header: {
                    Text("The prompt")
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    TextField("One-line description (optional)", text: $oneliner)
                    TextField("Category (optional)", text: $category)
                } header: {
                    Text("Extras")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .navigationTitle("New prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving\u{2026}" : "Save") {
                        saving = true
                        Task {
                            let ok = await service.createPrompt(
                                name: name,
                                text: text,
                                category: category,
                                oneliner: oneliner
                            )
                            saving = false
                            if ok {
                                onAnnounce("Saved \(name) to the library.")
                                dismiss()
                            } else {
                                onAnnounce("Couldn't save the prompt. Check the name and text and try again.")
                            }
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
