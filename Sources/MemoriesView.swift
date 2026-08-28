import SwiftUI

/// Aug 7 2026 — THE MEMORIES SCREEN (her pick: full screen). Every memory
/// card the platform keeps about the signed-in person: hear them, edit
/// them, forget them, add one by hand — grouped exactly the way scope
/// works (shared cards first under "Everyone," then each character's own
/// bucket). VoiceOver-first: one combined element per card (topic, the
/// memory itself, who holds it, when it changed), edit/forget on the
/// actions rotor, usage read as a plain sentence, and every change
/// announced. The remembering master switch (server-side personalization
/// flag, same one the web panel flips) sits at the top.
struct MemoriesView: View {
    /// Kept for the ChatGPT-import push (Aug 28 2026) — the service wraps it
    /// for card CRUD, but GptImportView needs the client itself.
    private let apiClient: KadeAPIClient
    @StateObject private var service: MemoriesService
    @State private var page: MemoriesService.MemoriesPage?
    @State private var rememberingOn = true
    @State private var editingCard: MemoriesService.MemoryCard?
    @State private var addingNew = false
    @State private var cardPendingForget: MemoriesService.MemoryCard?
    @State private var busyMessage: String?
    /// Aug 28 2026 — the week's consolidation trail ("what changed this
    /// week"). Empty = the section does not render at all.
    @State private var weekChanges: [MemoriesService.LedgerChange] = []
    /// Bool-based push, the house pattern (see SettingsView's own doc note).
    @State private var showingImport = false

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: MemoriesService(client: apiClient))
    }

    private var groups: [(title: String, cards: [MemoriesService.MemoryCard])] {
        guard let page else { return [] }
        var shared: [MemoriesService.MemoryCard] = []
        var byAgent: [String: [MemoriesService.MemoryCard]] = [:]
        for card in page.memories {
            if let name = card.agentName, !(card.agentId ?? "").isEmpty {
                byAgent[name, default: []].append(card)
            } else if !(card.agentId ?? "").isEmpty {
                byAgent["One character's own", default: []].append(card)
            } else {
                shared.append(card)
            }
        }
        var out: [(String, [MemoriesService.MemoryCard])] = []
        if !shared.isEmpty { out.append(("Everyone", shared)) }
        for key in byAgent.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            out.append((key, byAgent[key]!))
        }
        return out
    }

    private func weekChangeSpoken(_ change: MemoriesService.LedgerChange) -> String {
        var parts = ["\(change.spokenKey), \(change.spokenAction)"]
        if let note = change.note, !note.isEmpty { parts.append(note) }
        let day = when(change.createdAt)
        if !day.isEmpty { parts.append(day) }
        return parts.joined(separator: ". ")
    }

    private func when(_ iso: String?) -> String {
        guard let iso else { return "" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return "" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $rememberingOn) {
                    Text("Remembering is on")
                }
                .onChange(of: rememberingOn) { _, newValue in
                    Task {
                        do {
                            try await service.setRemembering(newValue)
                            UIAccessibility.post(notification: .announcement, argument: newValue ? "Remembering turned on." : "Remembering turned off.")
                        } catch {
                            rememberingOn = !newValue // honest revert on failure
                            busyMessage = error.localizedDescription
                        }
                    }
                }
                .accessibilityHint("While this is on, your companions keep small memory cards about what you share. Turn it off and nothing new is saved.")
            } footer: {
                if let page, let total = page.totalTokens, total > 0 {
                    Text(usageSentence(page))
                } else {
                    Text("Your companions file small memory cards about what you share — a good friend taking notes. Cards a character heard privately stay with that character.")
                }
            }

            Section {
                Button {
                    showingImport = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bring your ChatGPT memories")
                            .font(.body.weight(.semibold))
                        Text("Moving in? Paste the list ChatGPT kept about you, or upload your export — your companions know you from day one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Bring your ChatGPT memories. Moving in? Paste the list ChatGPT kept about you, or upload your export. Opens the import screen.")
            }

            /// "What changed this week" (Aug 28 2026) — the ledger the
            /// consolidation pass has kept since Part 69, finally readable
            /// here. One combined VoiceOver element per change: topic, what
            /// happened to it, when, and the pass's own note if it left one.
            /// Nothing here is editable — it is a trail, not a control; the
            /// cards above are where corrections live.
            if !weekChanges.isEmpty {
                Section {
                    ForEach(weekChanges) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(change.spokenKey) — \(change.spokenAction)")
                                .font(.subheadline.weight(.semibold))
                            if let note = change.note, !note.isEmpty {
                                Text(note)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if !when(change.createdAt).isEmpty {
                                Text(when(change.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(weekChangeSpoken(change))
                    }
                } header: {
                    Text("What changed this week")
                } footer: {
                    Text("The housekeeping pass keeps a trail of every card it touches, so nothing is ever quietly lost.")
                }
            }

            if service.isLoading && page == nil {
                Section {
                    ProgressView("Loading memories…")
                        .accessibilityLabel("Loading memories")
                }
            } else if let error = service.loadError, page == nil {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { Task { await reload() } }
                }
            } else if let page, page.memories.isEmpty {
                Section {
                    Text("No memory cards yet. They'll appear here as your companions get to know you — or add one yourself with the plus button.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.cards) { card in
                        Button {
                            editingCard = card
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.spokenKey)
                                    .font(.headline)
                                Text(card.value)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                if !when(card.updated_at).isEmpty {
                                    Text("Updated \(when(card.updated_at))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(card.spokenKey). \(card.value). Held by \(group.title == "Everyone" ? "everyone" : group.title).\(when(card.updated_at).isEmpty ? "" : " Updated \(when(card.updated_at)).")")
                        .accessibilityHint("Double tap to edit this memory.")
                        .accessibilityAction(named: "Forget this memory") {
                            cardPendingForget = card
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                cardPendingForget = card
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .navigationTitle("Memories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingNew = true
                } label: {
                    Label("Add a memory", systemImage: "plus")
                }
                .accessibilityHint("Write a memory card yourself — it saves as a shared card every companion can see.")
            }
        }
        .navigationDestination(isPresented: $showingImport) {
            GptImportView(apiClient: apiClient)
        }
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(item: $editingCard) { card in
            MemoryEditSheet(
                title: card.spokenKey,
                original: card.value
            ) { newValue in
                try await service.update(card: card, newValue: newValue)
                UIAccessibility.post(notification: .announcement, argument: "Memory updated.")
                await reload()
            }
        }
        .sheet(isPresented: $addingNew) {
            MemoryAddSheet { key, value in
                try await service.create(key: key, value: value)
                UIAccessibility.post(notification: .announcement, argument: "Memory saved.")
                await reload()
            }
        }
        .confirmationDialog(
            "Forget this memory?",
            isPresented: Binding(get: { cardPendingForget != nil }, set: { if !$0 { cardPendingForget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget it", role: .destructive) {
                guard let card = cardPendingForget else { return }
                cardPendingForget = nil
                Task {
                    do {
                        try await service.delete(card: card)
                        KadeHaptics.success()
                        UIAccessibility.post(notification: .announcement, argument: "Forgotten.")
                        await reload()
                    } catch {
                        busyMessage = error.localizedDescription
                    }
                }
            }
            Button("Keep it", role: .cancel) { cardPendingForget = nil }
        } message: {
            Text(cardPendingForget.map { "\"\($0.spokenKey)\" goes away for good — the character simply won't know it anymore." } ?? "")
        }
        .alert("Memory trouble", isPresented: Binding(get: { busyMessage != nil }, set: { if !$0 { busyMessage = nil } })) {
            Button("OK") { busyMessage = nil }
        } message: {
            Text(busyMessage ?? "")
        }
    }

    private func usageSentence(_ page: MemoriesService.MemoriesPage) -> String {
        let count = page.memories.count
        var sentence = "\(count) memory card\(count == 1 ? "" : "s") on file"
        if let pct = page.usagePercentage {
            sentence += ", using about \(pct) percent of the memory space"
        }
        return sentence + "."
    }

    private func reload() async {
        page = await service.load()
        weekChanges = await service.loadWeekChanges()
    }
}

/// Edit one card's text. The topic key stays put — renames are the memory
/// keeper's business; this sheet is for correcting the remembered truth.
private struct MemoryEditSheet: View {
    let title: String
    let original: String
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var errorText: String?

    init(title: String, original: String, onSave: @escaping (String) async throws -> Void) {
        self.title = title
        self.original = original
        self.onSave = onSave
        _text = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .accessibilityLabel("The memory")
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                dismiss()
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Add a card by hand — topic plus the memory, saved shared.
private struct MemoryAddSheet: View {
    let onSave: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Topic (like: dad health, cat Kasper)", text: $key)
                        .accessibilityLabel("Topic")
                    TextEditor(text: $value)
                        .frame(minHeight: 120)
                        .accessibilityLabel("The memory")
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    } else {
                        Text("Saves as a shared card — every companion will know it.")
                    }
                }
            }
            .navigationTitle("New memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .lowercased().replacingOccurrences(of: " ", with: "_")
                                try await onSave(cleanKey, value.trimmingCharacters(in: .whitespacesAndNewlines))
                                dismiss()
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                    .disabled(saving
                        || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
