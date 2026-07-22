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
    /// Session 24 (leftovers item 4): entry point to the archived
    /// conversations screen -- same `isPresented` destination pattern as
    /// `startingNewConversation` above.
    @State private var showingArchived = false

    // Session 14 (Kade: "maybe a rotor of actions in the conversations list
    // where you can delete stuff? Stuff like that.").
    //
    // Two deliberate calls, both mirroring what already works elsewhere in
    // this app:
    //
    // 1. Every row gets an explicit "Conversation actions" MENU BUTTON as
    //    its own sibling VoiceOver stop -- exactly the pattern the
    //    per-message actions menu shipped with in session 13, and chosen
    //    over relying only on `.swipeActions`. Swipe actions DO surface in
    //    VoiceOver's Actions rotor, but they're a rotor mode you have to
    //    already be in; a real button is findable by plain swipe navigation
    //    with nothing to know in advance. `.swipeActions` is added too, for
    //    the sighted muscle memory everyone else has from Mail.
    // 2. Delete asks for confirmation; rename opens a text-entry alert.
    //    Deleting a conversation is irreversible on the server, and this is
    //    a screen navigated by ear -- an accidental double-tap must not be
    //    able to destroy history silently.
    @State private var renamingConversation: KadeConversation?
    @State private var renameText: String = ""
    @State private var deletingConversation: KadeConversation?
    /// Session 26 (leftovers item 9): which conversation's share/export
    /// sheet is open. A SHEET, not a push -- no navigationDestination type
    /// registered, so the one-KadeConversation-per-stack rule is untouched.
    @State private var sharingConversation: KadeConversation?
    // Local, case- and diacritic-insensitive filter over the conversations
    // already loaded. Deliberately NOT the server's own `?search=` parameter:
    // that path runs through Meilisearch on the fork, which this deployment
    // doesn't guarantee is up, and a search box that silently returns
    // nothing when an unrelated service is down is worse than no search box.
    // Filtering what's in hand is instant, works with no network at all, and
    // degrades honestly -- the footer says how many are loaded so "not
    // found" never means "doesn't exist."
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

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
                .accessibilityHint("Starts a new conversation.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingArchived = true
                } label: {
                    Image(systemName: "archivebox")
                }
                .accessibilityLabel("Archived conversations")
                .accessibilityHint("Shows conversations you've archived, and lets you restore or delete them.")
            }
        }
        .navigationDestination(isPresented: $startingNewConversation) {
            ConversationDetailView(conversation: nil)
        }
        .navigationDestination(isPresented: $showingArchived) {
            ArchivedConversationsView()
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
        .onChange(of: startingNewConversation) { was, isNow in
            // Session 22 LIVE BUG (Amber A: made a new chat, backed out,
            // "couldn't get back in the chat she had just created"): the
            // .task above only fetches when the cached list is EMPTY, so a
            // conversation born inside the new-chat screen wasn't in the
            // list on return -- invisible until pull-to-refresh, which is
            // a buried gesture under VoiceOver. Returning from the
            // new-chat screen now refetches page one and lands VoiceOver
            // focus on the newest row -- the chat she was just inside --
            // so backing out and going back in works the way it reads.
            if was && !isNow {
                Task {
                    await conversationsService.loadFirstPage()
                    // Session 24 LIVE BUG (Kade: her newborn "New Chat"
                    // rows "can't be opened with VoiceOver"): this refetch
                    // waits behind KadeAPIClient's pacing gate, so it can
                    // finish SECONDS after the pop -- and if a row has
                    // already been double-tapped into by then (fast, and
                    // natural, for a screen-reader user who knows the
                    // list), the assignment below used to fire UNDER the
                    // pushed conversation, yanking VoiceOver focus onto a
                    // covered list row. From the chair that reads as "the
                    // chat never opened": you hear the row's name again and
                    // every swipe walks the covered list. RULE, same class
                    // as the never-do rules in PROJECT_STATUS: never move
                    // list focus while another screen sits pushed on top of
                    // the list.
                    if selectedConversation == nil && !startingNewConversation && !showingArchived {
                        focusedConversationID = conversationsService.conversations.first?.id
                    }
                }
            }
        }
        .onChange(of: conversationsService.conversations) { _, _ in
            // A deleted/archived row disappearing must not strand VoiceOver
            // focus on an element that no longer exists -- move it to
            // whatever is now first rather than letting the system pick.
            // Session 24: same covered-screen rule as the refetch guard
            // above -- the list can now also refresh from INSIDE a pushed
            // conversation (the newborn-title pickup in
            // ConversationDetailView), so only steer focus when this list
            // is actually the screen on top. Delete/archive (this guard's
            // real audience) always happen with the list on top anyway.
            if selectedConversation == nil, !startingNewConversation, !showingArchived,
               let current = focusedConversationID,
               !conversationsService.conversations.contains(where: { $0.id == current }) {
                focusedConversationID = conversationsService.conversations.first?.id
            }
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

    private var filteredConversations: [KadeConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversationsService.conversations }
        return conversationsService.conversations.filter {
            $0.displayTitle.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Plain `TextField` pinned above the list rather than the system
    /// `.searchable` bar -- same choice, for the same reason, as
    /// `AgentPickerView`'s search-first redesign (build 119): `.searchable`'s
    /// focus API (`.searchFocused`) requires iOS 18 and this project targets
    /// 17, and a hand-built field keeps focus behaviour identical across
    /// both screens. Unlike the agent picker, focus is NOT grabbed on
    /// appear here: the conversation list's job on open is to land you on
    /// your most recent conversation (deliberate, session 11), and hijacking
    /// that into a keyboard would undo a fix Kade specifically asked for.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search conversations", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityLabel("Search conversations")
                .accessibilityHint("Type to narrow the list to conversations whose name matches.")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var list: some View {
        VStack(spacing: 0) {
            searchField
            listBody
        }
    }

    private var listBody: some View {
        List {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchSummaryRow
            }
            ForEach(filteredConversations) { convo in
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
                .accessibilityHint("Opens this conversation.")
                // Rename/Archive/Delete live ONLY on `.swipeActions` below.
                // Session 21g: they used to ALSO be declared as explicit
                // `.accessibilityActions`, but `.swipeActions` already
                // surface as VoiceOver custom actions on their own, so every
                // action got announced TWICE in the Actions rotor (Kade:
                // "delete and share... listed twice"). Removing the explicit
                // set leaves exactly one, still one rotor flick from the row,
                // with the swipe kept as the sighted affordance. Do NOT
                // re-add `.accessibilityActions` alongside the swipe -- that
                // is exactly what caused the duplication.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingConversation = convo
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        beginRename(convo)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        Task { await conversationsService.archiveConversation(id: convo.id, title: convo.displayTitle) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button {
                        sharingConversation = convo
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }

            }
            if conversationsService.hasMore && searchText.isEmpty {
                loadMoreRow
            }
        }
        .listStyle(.plain)
        .refreshable {
            await conversationsService.loadFirstPage()
            // Session 23 garnish: fresh data landing is worth one light tap.
            KadeHaptics.tap()
        }
        .navigationDestination(item: $selectedConversation) { convo in
            ConversationDetailView(conversation: convo)
        }
        .sheet(item: $sharingConversation) { convo in
            ShareExportView(conversation: convo)
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
                Task { await conversationsService.deleteConversation(id: convo.id, title: convo.displayTitle) }
            }
            Button("Keep it", role: .cancel) { deletingConversation = nil }
        } message: { convo in
            Text("\(convo.displayTitle) and everything said in it will be gone for good. Archiving keeps it instead.")
        }
        .alert(
            "Rename conversation",
            isPresented: Binding(
                get: { renamingConversation != nil },
                set: { if !$0 { renamingConversation = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let convo = renamingConversation {
                    let newTitle = renameText
                    renamingConversation = nil
                    Task { await conversationsService.renameConversation(id: convo.id, title: newTitle) }
                }
            }
            Button("Cancel", role: .cancel) { renamingConversation = nil }
        } message: {
            Text("Give this conversation a name you'll recognise later.")
        }
        .onChange(of: conversationsService.actionMessage) { _, message in
            // Every row action is announced rather than left to be
            // inferred from a row quietly vanishing -- the whole point of
            // the actions menu is that this screen is worked by ear.
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            conversationsService.actionMessage = nil
        }
    }

    /// One-line "what am I looking at" summary while a filter is active.
    /// Its own VoiceOver stop on purpose: without it, typing into the search
    /// field and getting silence gives no way to tell "nothing matched" from
    /// "the list didn't update."
    private var searchSummaryRow: some View {
        Text(searchSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(searchSummary)
    }

    private var searchSummary: String {
        let count = filteredConversations.count
        let loaded = conversationsService.conversations.count
        if count == 0 {
            return "No matches in the \(loaded) conversations loaded so far. Clear the search and load more to look further back."
        }
        let noun = count == 1 ? "match" : "matches"
        return "\(count) \(noun) in the \(loaded) conversations loaded so far."
    }

    private func beginRename(_ convo: KadeConversation) {
        renameText = convo.displayTitle
        renamingConversation = convo
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
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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
