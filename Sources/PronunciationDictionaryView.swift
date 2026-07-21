import SwiftUI

/// Settings-adjacent screen for the per-user pronunciation dictionary --
/// see `PronunciationDictionaryService` for the server contract. Lives on
/// the home screen for now, same as Matchmaker/Game Room/Debate Room/Agent
/// Builder before a real Settings tab exists to hold it (session 17/18's
/// still-open tabs decision); moving it there later is just relocating one
/// button and one HomeRoute case.
///
/// Editing an EXISTING entry only lets you change its pronunciation, never
/// its word -- the server upserts by `term` (see the service's doc
/// comment), so editing the term text here would silently create a
/// second, orphaned entry rather than renaming the first one. Add a fresh
/// entry and delete the old one instead if the WORD itself was wrong.
///
/// VoiceOver notes mirror AgentManagerView's proven row pattern: a plain
/// Button driving local navigation state, `.ignore` + an explicit label
/// (never `.combine`), Delete as both a rotor action and a swipe action.
struct PronunciationDictionaryView: View {
    @StateObject private var service: PronunciationDictionaryService

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: PronunciationDictionaryService(client: apiClient))
    }

    @State private var entries: [PronunciationEntry] = []
    @State private var hasLoaded = false
    /// ONE sheet-driving value covering both add and edit -- two separate
    /// `.sheet` modifiers at the same view level is a proven-unreliable
    /// pattern in this app (the exact bug `DescribeView` and
    /// `AgentManagerView` both folded away for the same reason).
    @State private var activeSheet: EntrySheet?
    @State private var deletingEntry: PronunciationEntry?
    @State private var isDeleting = false

    private enum EntrySheet: Identifiable {
        case new
        case edit(PronunciationEntry)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let entry): return "edit:\(entry.id)"
            }
        }
    }

    var body: some View {
        Group {
            if let error = service.loadError, entries.isEmpty {
                errorState(error)
            } else if service.isLoading && !hasLoaded {
                ProgressView("Loading your dictionary…")
                    .accessibilityLabel("Loading your pronunciation dictionary")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Pronunciation Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .new
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a word")
                .accessibilityHint("Teach Kade-AI how to recognize and say a name or word.")
            }
        }
        .task {
            guard !hasLoaded else { return }
            await reload()
        }
        .refreshable { await reload() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .new:
                PronunciationEntryEditor(existing: nil) { term, pronunciation in
                    try await service.saveEntry(term: term, pronunciation: pronunciation)
                    await reload()
                }
            case .edit(let entry):
                PronunciationEntryEditor(existing: entry) { _, pronunciation in
                    try await service.saveEntry(term: entry.term, pronunciation: pronunciation)
                    await reload()
                }
            }
        }
        .alert(
            "Remove this word?",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            ),
            presenting: deletingEntry
        ) { entry in
            Button("Remove", role: .destructive) {
                Task { await confirmDelete(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\"\(entry.term)\" will go back to however Kade-AI would normally say it.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No words added yet.")
                .font(.headline)
            Text("Add a name or word Kade-AI mishears or mispronounces, and how it should actually sound -- like Kade said as \"Katie.\" It helps recognize your voice on calls and Transcribe, and reads it back correctly in voice messages and Spotter calls.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add a word") { activeSheet = .new }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            Button("Try again") { Task { await reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button {
                        activeSheet = .edit(entry)
                    } label: {
                        row(for: entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.term), pronounced \(entry.pronunciation)")
                    .accessibilityHint("Opens this word to change its pronunciation.")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deletingEntry = entry
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Used to help Kade-AI recognize and say these words correctly in calls, voice messages, and transcripts.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for entry: PronunciationEntry) -> some View {
        HStack {
            Text(entry.term).font(.body)
            Spacer()
            Text(entry.pronunciation)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        entries = await service.loadEntries()
        hasLoaded = true
    }

    private func confirmDelete(_ entry: PronunciationEntry) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await service.deleteEntry(id: entry.id)
            entries.removeAll { $0.id == entry.id }
        } catch {
            // Fail-soft, matching AgentManagerView's delete: the row
            // stays, she can try the swipe/rotor action again.
        }
        deletingEntry = nil
    }
}

/// Add/edit sheet -- deliberately tiny (two fields) rather than reusing
/// AgentEditorView's heavier multi-section pattern, since a dictionary
/// entry only ever has a word and its pronunciation. Editing an EXISTING
/// entry keeps `term` read-only (see this file's top-level doc comment for
/// why) -- only a brand-new entry can set it.
private struct PronunciationEntryEditor: View {
    let existing: PronunciationEntry?
    let onSave: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var pronunciation: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    private enum Field { case term, pronunciation }
    @FocusState private var focusedField: Field?

    init(existing: PronunciationEntry?, onSave: @escaping (String, String) async throws -> Void) {
        self.existing = existing
        self.onSave = onSave
        _term = State(initialValue: existing?.term ?? "")
        _pronunciation = State(initialValue: existing?.pronunciation ?? "")
    }

    private var canSave: Bool {
        !term.trimmingCharacters(in: .whitespaces).isEmpty
            && !pronunciation.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if existing != nil {
                        HStack {
                            Text("Word").foregroundStyle(.secondary)
                            Spacer()
                            Text(term)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        TextField("Word (like Kade)", text: $term)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .term)
                            .accessibilityLabel("Word")
                            .accessibilityHint("The name or word as it's normally spelled.")
                    }
                    TextField("Pronounced like (like Katie)", text: $pronunciation)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .pronunciation)
                        .accessibilityLabel("Pronounced like")
                        .accessibilityHint("Spell it the way it sounds, so it's recognized and read back correctly.")
                } footer: {
                    Text("Spell the pronunciation the way it sounds -- for example, Kade pronounced \"Katie.\"")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel(errorMessage)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add a word" : "Edit pronunciation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .onAppear {
                focusedField = existing == nil ? .term : .pronunciation
            }
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await onSave(
                term.trimmingCharacters(in: .whitespaces),
                pronunciation.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't save. Try again."
        }
    }
}
