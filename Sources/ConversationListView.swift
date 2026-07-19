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
    // Session 11: drives navigation programmatically now instead of via
    // NavigationLink(value:) -- see the row Button's doc comment in `list`
    // for why.
    @State private var selectedConversation: KadeConversation?
    // Session 11, cont. (Kade, right after confirming rows activate now:
    // "it puts you on a random conversation when you open them, like your
    // focus"): without this, VoiceOver's initial focus when this screen
    // appears -- and its focus when returning here after opening a
    // conversation -- is whatever the system happens to land on, not
    // anything this app chose. Explicitly steering it (same
    // @AccessibilityFocusState pattern ContentView already uses for its
    // sign-in flow) makes it behave like Mail/Messages: land on the first
    // row on a fresh open, land back on the row you just came from when you
    // return.
    @AccessibilityFocusState private var focusedConversationID: String?
    // Session 11 (Kade: "I don't see a way to make a new conversation") --
    // separate from `selectedConversation` on purpose: that one always
    // carries a real, already-existing KadeConversation, and folding "no
    // conversation yet" into the same optional would mean every place that
    // reads it has to re-decide which kind of nil it's looking at.
    @State private var startingNewConversation = false

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startingNewConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New conversation")
                .accessibilityHint("Starts a new conversation and lets you pick who to talk to.")
            }
        }
        .navigationDestination(isPresented: $startingNewConversation) {
            ConversationDetailView(conversation: nil)
        }
        .task {
            if conversationsService.conversations.isEmpty {
                await conversationsService.loadFirstPage()
            }
            // Runs every time this screen freshly appears (a new push of
            // this view, per NavigationLink), whether or not the fetch
            // above actually ran -- so re-opening the list a second time in
            // the same session still gets a predictable starting focus.
            focusedConversationID = conversationsService.conversations.first?.id
        }
        .onChange(of: selectedConversation) { oldValue, newValue in
            // Returned from a conversation (was set, now nil going back to
            // this list): restore focus to the row they came from instead
            // of leaving it to the system.
            if newValue == nil, let opened = oldValue {
                focusedConversationID = opened.id
            }
        }
    }

    private var list: some View {
        List {
            ForEach(conversationsService.conversations) { convo in
                Button {
                    selectedConversation = convo
                } label: {
                    row(for: convo)
                }
                .buttonStyle(.plain)
                .accessibilityFocused($focusedConversationID, equals: convo.id)
                // Session 11 (Kade's first real report on this screen,
                // build 110, after signing in successfully): rows could be
                // VoiceOver-SELECTED (read aloud) but not ACTIVATED (double-
                // tap did nothing). The build-107 fix moved
                // .accessibilityElement(children: .combine) from the LABEL
                // onto the NavigationLink(value:) control itself, matching
                // the diagnosis at the time -- but that turned out to still
                // be unreliable for carrying the link's own push action;
                // nobody had actually re-confirmed it worked before three
                // more phases shipped on top of it. Switched to the ONE
                // pattern already proven safe elsewhere in this app
                // (AgentPickerView.list): a plain Button -- whose native
                // tap/VoiceOver-activate action is tied directly to its own
                // `action` closure, not reconstructed through an
                // accessibility-children modifier -- driving LOCAL selection
                // state, paired with .navigationDestination(item:) instead
                // of NavigationLink's own destination wiring. `.ignore` +
                // an explicit accessibilityLabel (not `.combine`) reads the
                // row as one clean stop without asking SwiftUI to merge an
                // interactive control's action through the same modifier
                // that assembles its label.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibleLabel(for: convo))
                .accessibilityHint("Opens this conversation and reads its history.")
            }
            if conversationsService.hasMore {
                loadMoreRow
            }
        }
        .listStyle(.plain)
        .refreshable { await conversationsService.loadFirstPage() }
        .navigationDestination(item: $selectedConversation) { convo in
            ConversationDetailView(conversation: convo)
        }
    }

    private func accessibleLabel(for convo: KadeConversation) -> String {
        if let relative = KadeDateFormatting.relative(from: convo.updatedAt) {
            return "\(convo.displayTitle). \(relative)"
        }
        return convo.displayTitle
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
    }

    // No .accessibilityElement wrapping here: it's a plain Button ("Load
    // more conversations") or ProgressView (own label already set), each
    // fine as its own natural VoiceOver stop -- combining the container
    // would swallow the Button's tap action, the same bug fixed above.
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
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No conversations yet")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            // Session 11: used to say "Start a chat on the web app and
            // it'll show up here" -- true when this was written, no longer
            // true now that starting one is possible right here.
            Text("Tap New Conversation above to start one.")
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
    }
}
