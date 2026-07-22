import SwiftUI
import UIKit

/// Session 24, leftovers item 4: the native screen the archive action never
/// had. Archiving on this app used to be a one-way door -- the row left the
/// main list and there was NOWHERE native to see it again (web only). For a
/// screen navigated by ear that reads as deletion with extra steps, so this
/// view closes the loop: browse what's archived, open one read-and-reply,
/// restore it, or delete it for real.
///
/// Patterns deliberately copied from `ConversationListView`, the screen
/// whose behavior is already proven in her hands:
/// - rows are plain Buttons driving `.navigationDestination(item:)` (the
///   session-11 activation fix -- never NavigationLink(value:), never
///   `.accessibilityElement(children:.ignore)` on a Button);
/// - row actions live ONLY on `.swipeActions` (they surface as VoiceOver
///   custom actions on their own; adding `.accessibilityActions` too would
///   double-announce -- the session-21g lesson);
/// - explicit "Load more" button, no silent infinite scroll;
/// - every action outcome is spoken via `ConversationsService.actionMessage`
///   -- announced by THIS view, see the `.onChange` note below.
/// Dedicated push type for opening an archived conversation -- NOT a bare
/// `KadeConversation`, and that's load-bearing: this screen is pushed from
/// `ConversationListView`, whose stack ALREADY registers a
/// `.navigationDestination(item:)` keyed to `KadeConversation`. Two
/// registrations for one type in one stack is exactly the build-121
/// regression (row taps silently die) that `SpotterTranscriptHandoff` and
/// `ChatTranscriptHandoff` exist to prevent. Same cure here.
struct ArchivedConversationOpen: Identifiable, Hashable {
    let conversation: KadeConversation
    var id: String { conversation.conversationId }
}

struct ArchivedConversationsView: View {
    @EnvironmentObject private var conversationsService: ConversationsService

    @State private var rows: [KadeConversation] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var selectedConversation: ArchivedConversationOpen?
    @State private var deletingConversation: KadeConversation?
    @AccessibilityFocusState private var focusedRowID: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading archived conversations…")
                    .accessibilityLabel("Loading archived conversations")
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        Task { await loadFirstPage() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if rows.isEmpty {
                await loadFirstPage()
                focusedRowID = rows.first?.id
            }
        }
        // Announcements for restore/delete land here, NOT on the main
        // list's identical observer: this screen sits pushed ON TOP of
        // `ConversationListView`, whose own `.onChange` also fires (covered
        // views stay live) and clears `actionMessage` -- but posting from
        // here too would risk a double announcement. So this view announces
        // ONLY messages its own actions produced, marked by the service
        // leaving them intact: in practice the list-under-the-stack
        // announces first and nils the message, which is one announcement,
        // spoken globally -- exactly what's wanted. This observer is the
        // fallback for the day that screen isn't beneath us.
        .onChange(of: conversationsService.actionMessage) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            conversationsService.actionMessage = nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Nothing archived")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Swipe on any conversation in your list and choose Archive to tuck it away here without deleting it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        List {
            ForEach(rows) { convo in
                Button {
                    selectedConversation = ArchivedConversationOpen(conversation: convo)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(convo.displayTitle)
                            .font(.body)
                        if let relative = KadeDateFormatting.relative(from: convo.updatedAt) {
                            Text(relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityFocused($focusedRowID, equals: convo.id)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibleLabel(for: convo))
                .accessibilityHint("Opens this archived conversation.")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingConversation = convo
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await restore(convo) }
                    } label: {
                        Label("Restore", systemImage: "tray.and.arrow.up")
                    }
                }
            }
            if nextCursor != nil {
                HStack {
                    Spacer()
                    if isLoadingMore {
                        ProgressView()
                            .accessibilityLabel("Loading more archived conversations")
                    } else {
                        Button("Load more archived conversations") {
                            Task { await loadMore() }
                        }
                    }
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await loadFirstPage()
            KadeHaptics.tap()
        }
        .navigationDestination(item: $selectedConversation) { open in
            ConversationDetailView(conversation: open.conversation)
        }
        .alert(
            "Delete conversation?",
            isPresented: Binding(
                get: { deletingConversation != nil },
                set: { if !$0 { deletingConversation = nil } }
            ),
            presenting: deletingConversation
        ) { convo in
            Button("Delete", role: .destructive) {
                deletingConversation = nil
                Task {
                    if await conversationsService.deleteConversation(id: convo.id, title: convo.displayTitle) {
                        removeRow(convo.id)
                    }
                }
            }
            Button("Keep it", role: .cancel) { deletingConversation = nil }
        } message: { convo in
            Text("\(convo.displayTitle) and everything said in it will be gone for good. Restoring keeps it instead.")
        }
    }

    private func accessibleLabel(for convo: KadeConversation) -> String {
        if let relative = KadeDateFormatting.relative(from: convo.updatedAt) {
            return "\(convo.displayTitle). Archived. \(relative)"
        }
        return "\(convo.displayTitle). Archived."
    }

    private func restore(_ convo: KadeConversation) async {
        if await conversationsService.unarchiveConversation(id: convo.id, title: convo.displayTitle) {
            removeRow(convo.id)
        }
    }

    /// A restored/deleted row leaves THIS list -- move VoiceOver focus to a
    /// neighbor rather than letting it strand on a gone element (same
    /// stranding rule the main list already follows).
    private func removeRow(_ id: String) {
        let index = rows.firstIndex { $0.id == id }
        rows.removeAll { $0.id == id }
        if focusedRowID == id {
            if let index, index < rows.count {
                focusedRowID = rows[index].id
            } else {
                focusedRowID = rows.last?.id
            }
        }
    }

    private func loadFirstPage() async {
        isLoading = rows.isEmpty
        loadError = nil
        do {
            let page = try await conversationsService.fetchArchivedPage(cursor: nil)
            rows = page.conversations
            nextCursor = page.nextCursor
        } catch {
            loadError = "Couldn't load your archived conversations. Check your connection and try again."
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await conversationsService.fetchArchivedPage(cursor: cursor)
            rows.append(contentsOf: page.conversations)
            nextCursor = page.nextCursor
        } catch {
            // Silent on purpose -- the rows already loaded stay usable and
            // "Load more" remains to try again, same as the main list.
        }
    }
}
