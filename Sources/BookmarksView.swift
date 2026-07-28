import SwiftUI

/// BOOKMARKS — the native home for conversation tags (July 28 2026,
/// leftovers item 3; web parity). Three jobs on one screen:
///   1. the shelf: every tag, with its conversation count, as a real
///      VoiceOver list (rows are Buttons, ArchivedConversationsView's
///      pattern — swipe actions surface through the rotor AND live in a
///      context menu, discoverable both ways);
///   2. the browse: tap a tag, get the conversations carrying it (the
///      server filters via GET /api/convos?tags=<name>), tap one, land in
///      the full chat exactly as from the main list;
///   3. the shelf-keeping: add, rename, and delete tags right here.
/// Putting a tag ON a conversation lives in `TagEditorSheet`, reached from
/// the conversation list's context menu — the chat toolbar keeps its
/// deliberately calm two-icon bar (session 25's rule, untouched).
struct BookmarksView: View {
    @StateObject private var service: TagsService
    @State private var newTagName = ""
    @State private var renamingTag: KadeTag?
    @State private var renameText = ""
    @State private var deletingTag: KadeTag?
    @State private var announcement: String?

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: TagsService(client: apiClient))
    }

    var body: some View {
        List {
            Section {
                if service.tags.isEmpty && !service.isLoading {
                    // The empty shelf explains ITSELF — a blind user
                    // arriving here for the first time hears what
                    // bookmarks are and where the "add" lives, instead
                    // of an unexplained empty list.
                    Text(
                        "No bookmarks yet. Add one below, then attach it to any "
                        + "conversation from the conversation list: touch and hold "
                        + "a conversation (or use the VoiceOver rotor's actions) "
                        + "and choose Bookmark."
                    )
                    .foregroundStyle(.secondary)
                    .accessibilitySortPriority(1)
                }
                ForEach(service.tags) { tag in
                    NavigationLink(value: tag) {
                        HStack {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.red)
                                .accessibilityHidden(true)
                            Text(tag.tag)
                            Spacer()
                            if let count = tag.count, count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tag.spokenSummary)
                        .accessibilityHint("Shows the conversations with this bookmark.")
                    }
                    .contextMenu {
                        renameButton(for: tag)
                        deleteButton(for: tag)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        deleteButton(for: tag)
                        renameButton(for: tag)
                    }
                }
            } header: {
                Text("Your bookmarks")
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                HStack {
                    TextField("New bookmark name", text: $newTagName)
                        .textInputAutocapitalization(.never)
                        .onSubmit { addTag() }
                    Button("Add") { addTag() }
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityHint("Creates the bookmark so you can attach it to conversations.")
                }
            } header: {
                Text("Add a bookmark")
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .navigationTitle("Bookmarks")
        .navigationDestination(for: KadeTag.self) { tag in
            TaggedConversationsView(tag: tag.tag, service: service)
        }
        .task { await service.loadTags() }
        .refreshable { await service.loadTags() }
        .overlay {
            if service.isLoading && service.tags.isEmpty {
                ProgressView("Loading bookmarks")
            }
        }
        .alert(
            "Rename bookmark",
            isPresented: Binding(get: { renamingTag != nil }, set: { if !$0 { renamingTag = nil } })
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard let tag = renamingTag else { return }
                let newName = renameText
                Task {
                    if await service.renameTag(tag.tag, to: newName) {
                        announce("Renamed to \(newName).")
                    } else {
                        announce("Couldn't rename that bookmark.")
                    }
                }
                renamingTag = nil
            }
            Button("Cancel", role: .cancel) { renamingTag = nil }
        } message: {
            Text("The bookmark keeps its conversations under the new name.")
        }
        .confirmationDialog(
            "Delete the bookmark \u{201C}\(deletingTag?.tag ?? "")\u{201D}?",
            isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete bookmark", role: .destructive) {
                guard let tag = deletingTag else { return }
                Task {
                    if await service.deleteTag(tag.tag) {
                        announce("Deleted \(tag.tag). The conversations themselves are untouched.")
                    } else {
                        announce("Couldn't delete that bookmark.")
                    }
                }
                deletingTag = nil
            }
            Button("Cancel", role: .cancel) { deletingTag = nil }
        } message: {
            Text("Conversations keep living in your list — only the bookmark goes away.")
        }
        .onChange(of: announcement) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            announcement = nil
        }
    }

    private func renameButton(for tag: KadeTag) -> some View {
        Button {
            renameText = tag.tag
            renamingTag = tag
        } label: {
            Label("Rename", systemImage: "pencil")
        }
    }

    private func deleteButton(for tag: KadeTag) -> some View {
        Button(role: .destructive) {
            deletingTag = tag
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func addTag() {
        let name = newTagName
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        newTagName = ""
        Task {
            if await service.createTag(name) {
                announce("Added bookmark \(name).")
            } else {
                announce("Couldn't add that bookmark.")
            }
        }
    }

    private func announce(_ message: String) {
        announcement = message
    }
}

/// The conversations carrying one tag. Rows push the real chat — same
/// value-based navigation the main list uses, so back lands here.
struct TaggedConversationsView: View {
    let tag: String
    @ObservedObject var service: TagsService

    @State private var conversations: [KadeConversation] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selected: KadeConversation?

    var body: some View {
        List {
            if conversations.isEmpty && !isLoading && loadError == nil {
                Text("Nothing carries this bookmark yet.")
                    .foregroundStyle(.secondary)
            }
            if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            }
            ForEach(conversations) { convo in
                Button {
                    selected = convo
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(convo.displayTitle)
                            .lineLimit(2)
                        if let relative = KadeDateFormatting.relative(from: convo.updatedAt) {
                            Text(relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityHint("Opens this conversation.")
            }
            if nextCursor != nil {
                Button("Load more") { Task { await loadPage() } }
            }
        }
        .navigationTitle(tag)
        .navigationDestination(item: $selected) { convo in
            ConversationDetailView(conversation: convo)
        }
        .task { await loadFirstPage() }
        .refreshable { await loadFirstPage() }
        .overlay {
            if isLoading && conversations.isEmpty { ProgressView("Loading") }
        }
    }

    private func loadFirstPage() async {
        nextCursor = nil
        conversations = []
        await loadPage()
    }

    private func loadPage() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.conversations(withTag: tag, cursor: nextCursor)
            conversations.append(contentsOf: page.conversations.filter { convo in
                !conversations.contains(where: { $0.id == convo.id })
            })
            nextCursor = page.nextCursor
            loadError = nil
        } catch {
            loadError = "Couldn't load these conversations. Pull to try again."
        }
    }
}

/// Attach/detach bookmarks on ONE conversation — presented as a sheet from
/// the conversation list's context menu. Toggle rows (real checkmarks with
/// `.isSelected` traits), an inline "new bookmark" field, one Save. The
/// server takes the FULL resulting list in a single PUT.
struct TagEditorSheet: View {
    let conversationId: String
    let conversationTitle: String
    /// Owned, not observed: this sheet is presented from closures that
    /// re-evaluate while it's up (the conversation list re-renders under
    /// it), and an @ObservedObject built inline there would be recreated
    /// mid-edit, dropping the loading state. @StateObject pins one
    /// instance to the sheet's lifetime.
    @StateObject private var service: TagsService
    let onSaved: (String) -> Void

    init(
        conversationId: String,
        conversationTitle: String,
        apiClient: KadeAPIClient,
        onSaved: @escaping (String) -> Void
    ) {
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.onSaved = onSaved
        _service = StateObject(wrappedValue: TagsService(client: apiClient))
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTags: Set<String> = []
    @State private var loaded = false
    @State private var newTagName = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if service.tags.isEmpty && loaded {
                        Text("No bookmarks yet — add one below and it goes straight onto this conversation.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(service.tags) { tag in
                        Button {
                            toggle(tag.tag)
                        } label: {
                            HStack {
                                Text(tag.tag)
                                Spacer()
                                if selectedTags.contains(tag.tag) {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(selectedTags.contains(tag.tag) ? [.isSelected] : [])
                        .accessibilityHint(
                            selectedTags.contains(tag.tag)
                                ? "Removes this bookmark from the conversation."
                                : "Puts this bookmark on the conversation."
                        )
                    }
                } header: {
                    Text("Bookmarks on \u{201C}\(conversationTitle)\u{201D}")
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    HStack {
                        TextField("New bookmark name", text: $newTagName)
                            .textInputAutocapitalization(.never)
                            .onSubmit { addAndSelect() }
                        Button("Add") { addAndSelect() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Add a new bookmark")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .navigationTitle("Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving\u{2026}" : "Save") { save() }
                        .disabled(saving || !loaded)
                }
            }
            .task {
                if service.tags.isEmpty { await service.loadTags() }
                selectedTags = Set(await service.tagsForConversation(id: conversationId))
                loaded = true
            }
            .overlay {
                if !loaded { ProgressView("Loading bookmarks") }
            }
        }
    }

    private func toggle(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func addAndSelect() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newTagName = ""
        Task {
            if await service.createTag(name) {
                selectedTags.insert(name)
            }
        }
    }

    private func save() {
        saving = true
        // Keep the server's shelf order for the ones that stay; append
        // anything brand-new (created here, not yet in the shelf list) at
        // the end rather than dropping it.
        let shelfOrder = service.tags.map(\.tag).filter { selectedTags.contains($0) }
        let strays = selectedTags.subtracting(shelfOrder)
        let finalList = shelfOrder + strays.sorted()
        Task {
            let ok = await service.setTags(finalList, onConversation: conversationId)
            saving = false
            if ok {
                onSaved(
                    finalList.isEmpty
                        ? "Bookmarks cleared."
                        : "Bookmarked: \(finalList.joined(separator: ", "))."
                )
                dismiss()
            } else {
                onSaved("Couldn't save bookmarks for this conversation.")
            }
        }
    }
}
