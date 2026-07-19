import SwiftUI

/// Phase 2: the conversation list. VoiceOver notes:
/// - Each row combines title + relative time into one swipe stop with a
///   clear hint of what tapping does.
/// - Loading / error / empty states are each a single, clearly-worded block
///   rather than a bare spinner or blank screen.
/// - Pagination is an explicit "Load more" button, not silent infinite
///   scroll — a predictable, discoverable action beats a scroll-triggered
///   fetch that a screen-reader user can't see coming.
struct ConversationListView: View {
    @EnvironmentObject private var conversationsService: ConversationsService

    var body: some View {
        Group {
            if conversationsService.isLoadingList && conversationsService.conversations.isEmpty {
                ProgressView("Loading your conversations…")
                    .accessibilityLabel("Loading your conversations")
            } else if let error = conversationsService.listError, conversationsService.conversations.isEmpty {
                errorState(error)
            } else if conversationsService.conversations.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if conversationsService.conversations.isEmpty {
                await conversationsService.loadFirstPage()
            }
        }
    }

    private var list: some View {
        List {
            ForEach(conversationsService.conversations) { convo in
                NavigationLink(value: convo) {
                    row(for: convo)
                }
            }
            if conversationsService.hasMore {
                loadMoreRow
            }
        }
        .listStyle(.plain)
        .refreshable { await conversationsService.loadFirstPage() }
        .navigationDestination(for: KadeConversation.self) { convo in
            ConversationDetailView(conversation: convo)
        }
    }

    private func row(for convo: KadeConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(convo.displayTitle)
                .font(.body)
            if let relative = KadeDateFormatting.relative(from: convo.updatedAt) {
                Text(relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this conversation and reads its history.")
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if conversationsService.isLoadingMore {
                ProgressView()
                    .accessibilityLabel("Loading more conversations")
            } else {
                Button("Load more conversations") {
                    Task { await conversationsService.loadMore() }
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No conversations yet")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Start a chat on the web app and it'll show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await conversationsService.loadFirstPage() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}
