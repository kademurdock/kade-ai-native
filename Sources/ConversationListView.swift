import SwiftUI

/// Phase 2: the conversation list. VoiceOver notes:
/// - Each row combines title + relative time into one swipe stop with a
///   clear hint of what tapping does.
/// - Loading / error / empty states are each a single, clearly-worded block
///   rather than a bare spinner or blank screen.
/// - Pagination is an explicit "Load more" button, not silent infinite
///   scroll — a predictable, discoverable action beats a scroll-triggered
///   fetch that a screen-reader user can't see coming.
/// - Sep 23 2026 redesign: this is the ROOT of the Talk tab (A1). Rows show
///   the character's face and name (B3) under date headings (B6), and the
///   empty state has a real "Start a new chat" button (B10).
struct ConversationListView: View {
    /// Redesign A1: the Talk tab's own block (Call your Spotter first, her
    /// standing rule, then Describe and Transcribe), passed in by the tab
    /// root. When set, it is the FIRST section of the list, above the rows
    /// and above the loading, error and empty states alike, so Spotter is
    /// always the first thing on this screen. `nil` (plain
    /// `ConversationListView()`) is the screen as it always was. `var` with a
    /// default, not `let`, so the synthesized memberwise init takes it as a
    /// defaulted parameter (the reasoning on
    /// `ConversationDetailView.initialAgentId`).
    var talkHeader: AnyView? = nil

    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var apiClient: KadeAPIClient
    /// Redesign B3: who each chat is with, for the row's "with Kiana" line
    /// and its spoken label.
    @EnvironmentObject private var agentsService: AgentsService
    // Session 11: drives navigation programmatically now instead of via
    // NavigationLink(value:) -- see the row Button's doc comment in
    // `conversationButton(for:)` for why.
    @State private var selectedConversation: KadeConversation?
    /// Bookmarks (session 33, leftovers item 3): which conversation the
    /// tag-editor sheet is open FOR. Sheet-not-push, same reasoning as the
    /// share sheet right below it.
    @State private var taggingConversation: KadeConversation?
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
    /// Redesign A1: as the Talk tab's root, the list gets covered by screens
    /// none of the flags above know about (Spotter, Describe, the launch
    /// chat, a chat opened from another tab all push through the tab's own
    /// path), and leaving the tab hides it too. The session-24 rule (never
    /// move focus while another screen sits on top of the list) has to see
    /// those, so the list tracks itself: SwiftUI runs onDisappear when
    /// something is pushed over it or its tab is left, and onAppear when it
    /// is back. `listCoverings` counts the covers, so a refetch that started
    /// on the way back can tell whether anything covered the list again
    /// before it finished.
    @State private var listOnScreen = false
    @State private var listCoverings = 0

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
            // Redesign A1: with the Talk header the screen is ALWAYS the
            // list; loading, error and empty render as a row under the header
            // (`listStateRow`), so the header keeps one identity, and
            // VoiceOver keeps its place on it, when the first page lands.
            if talkHeader != nil {
                list
            } else if conversationsService.isLoadingList && conversationsService.conversations.isEmpty {
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
            // Redesign A1: only WITHOUT the Talk header. As the Talk tab's
            // root, VoiceOver starts at the top, where Spotter is (her
            // standing rule: Spotter first), so nothing is steered on appear.
            // Coming back from a conversation still lands on its row (the
            // `selectedConversation` and new-chat handlers below).
            if talkHeader == nil {
                focusedConversationID = conversationsService.conversations.first?.id
            }
            // Redesign B3: names for the rows' "with Kiana" line. A no-op
            // once the roster is in, which every chat screen loads anyway.
            await agentsService.loadIfNeeded()
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
                // Redesign A1: anything pushed over the list (or a tab
                // switch) while this refetch waits bumps `listCoverings`.
                let coveringsAtReturn = listCoverings
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
                    if selectedConversation == nil && !startingNewConversation && !showingArchived
                        && listCoverings == coveringsAtReturn {
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
            // Redesign A1: `listOnScreen` also covers what the Talk tab
            // pushes through its own path, and other tabs.
            if selectedConversation == nil, !startingNewConversation, !showingArchived, listOnScreen,
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

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredConversations: [KadeConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Build 261: pinned rows first (stable within each group), the way
        // the voice picker keeps your voices up top.
        guard !query.isEmpty else {
            let all = conversationsService.conversations
            return all.filter { $0.isPinned } + all.filter { !$0.isPinned }
        }
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
    /// Redesign A1: under the Talk header the field rides INSIDE the list,
    /// below the header (see `list`), which is why the clear button is
    /// `.borderless`: in a List row a default-style button turns the whole
    /// row into its tap target, so a tap beside the field would clear it.
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
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
            // Without the Talk header the search field stays pinned above
            // the list, as it always was. With it, the field moves into the
            // list under the header (`listBody`), so Spotter stays first.
            if talkHeader == nil {
                searchField
            }
            listBody
        }
        // Redesign A1: see `listOnScreen`.
        .onAppear { listOnScreen = true }
        .onDisappear {
            listOnScreen = false
            listCoverings += 1
        }
    }

    private var listBody: some View {
        List {
            // Redesign A1: the Talk tab's own block (Call your Spotter first,
            // her standing rule) is the FIRST section, above every state.
            if let talkHeader {
                Section {
                    talkHeader
                }
            }
            if conversationsService.conversations.isEmpty {
                // Only reached under the Talk header: without it, `body`
                // shows these states full screen instead of the list.
                Section {
                    listStateRow
                        .listRowSeparator(.hidden)
                }
            } else {
                if talkHeader != nil {
                    Section {
                        searchField
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                }
                if isSearching {
                    // Redesign B6: a search shows the flat filtered list, as
                    // it always did, with no date groups.
                    Section {
                        searchSummaryRow
                        ForEach(filteredConversations) { convo in
                            conversationButton(for: convo)
                        }
                    }
                } else {
                    // Redesign B6: real headings (Pinned, Today, Yesterday,
                    // This week, This month, Earlier), so the Headings rotor
                    // jumps by date.
                    ForEach(conversationGroups, id: \.title) { group in
                        Section {
                            ForEach(group.conversations) { convo in
                                conversationButton(for: convo)
                            }
                        } header: {
                            Text(group.title)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                if conversationsService.hasMore && searchText.isEmpty {
                    Section {
                        loadMoreRow
                    }
                }
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
        .sheet(item: $taggingConversation) { convo in
            // The sheet owns its own TagsService (@StateObject inside) and
            // loads the shelf + this conversation's current tags in its
            // own `.task` -- nothing shared across screens to keep in sync.
            TagEditorSheet(
                conversationId: convo.id,
                conversationTitle: convo.displayTitle,
                apiClient: apiClient
            ) { spokenResult in
                UIAccessibility.post(notification: .announcement, argument: spokenResult)
            }
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

    /// One conversation row, wired the same way in every section (the date
    /// groups and the flat search results), so the accessibility contract
    /// has exactly one home (`AgentPickerView.rowButton(for:)`'s pattern).
    private func conversationButton(for convo: KadeConversation) -> some View {
        Button {
            selectedConversation = convo
        } label: {
            row(for: convo)
        }
        .buttonStyle(.plain)
        .accessibilityFocused($focusedConversationID, equals: convo.id)
        // Session 11 history: rows could be VoiceOver-SELECTED but
        // not ACTIVATED; the fix landed on a plain Button driving
        // local selection + .navigationDestination(item:), with
        // children:.ignore + an explicit label -- and that .ignore
        // half survived until today.
        // Session 22 (Amber A, build 146): her "New Chat" row read
        // fine but double-tap did NOTHING, while her longer-titled
        // voice-chat row in the SAME list opened -- the exact
        // layout-dependent signature of the build-139 Amber rule.
        // children:.ignore on a Button costs it direct VoiceOver
        // activation; double-tap degrades to a synthesized tap at a
        // layout-dependent point that can miss per row shape and
        // text size (server, data, and the strict decode were all
        // live-exonerated first -- the failure had to be this row).
        // A Button flattens its label natively and the explicit
        // accessibilityLabel below still overrides the reading, so
        // dropping .ignore is byte-identical to VoiceOver. Same fix
        // 1bd0ccb applied to the admin + archived rows.
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
        // Build 261: pin/unpin on the leading edge; surfaces in the
        // Actions rotor like the others (no accessibilityActions --
        // that would read twice).
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task { await conversationsService.setPinned(id: convo.id, pinned: !convo.isPinned, title: convo.displayTitle) }
            } label: {
                Label(convo.isPinned ? "Unpin" : "Pin to top", systemImage: convo.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
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
            Button {
                taggingConversation = convo
            } label: {
                Label("Bookmark", systemImage: "bookmark")
            }
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

    /// Redesign B3: "Pinned. Grocery list, with Kiana, 2 hours ago". The face
    /// on the row is decoration, so the label says who the chat is with.
    private func accessibleLabel(for convo: KadeConversation) -> String {
        let pin = convo.isPinned ? "Pinned. " : ""
        var parts = [convo.displayTitle]
        if let name = characterName(for: convo) {
            parts.append("with \(name)")
        }
        if let relative = KadeDateFormatting.relative(from: convo.updatedAt) {
            parts.append(relative)
        }
        return pin + parts.joined(separator: ", ")
    }

    /// Redesign B3: the character this chat is with, by name. nil when the
    /// roster doesn't know (not loaded yet, a removed character, or none), and
    /// then the row simply leaves "with …" out.
    private func characterName(for convo: KadeConversation) -> String? {
        let name = agentsService.name(for: convo.agentId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The row's visible second line: "with Kiana · 2 hours ago".
    private func detailLine(for convo: KadeConversation) -> String? {
        var parts: [String] = []
        if let name = characterName(for: convo) {
            parts.append("with \(name)")
        }
        if let relative = KadeDateFormatting.relative(from: convo.updatedAt) {
            parts.append(relative)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func row(for convo: KadeConversation) -> some View {
        HStack(spacing: 12) {
            // Redesign B3: the character's face. Decoration: it hides itself
            // from VoiceOver and takes no taps (the row's label says the
            // name), and it's a fixed 44 pt square, so a picture that
            // arrives late never moves the row.
            KadeCharacterFace(agentID: convo.agentId, name: characterName(for: convo) ?? "", size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if convo.isPinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(convo.displayTitle)
                        .font(.body)
                }
                if let detail = detailLine(for: convo) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        // The whole row takes the tap, the face and the space after the
        // title included (the face ignores touches itself).
        .contentShape(Rectangle())
    }

    /// Redesign B6: the dated groups, in the order they're shown. "This
    /// week" is the previous 7 days, "This month" the previous 30.
    private enum DateGroup: CaseIterable {
        case today, yesterday, thisWeek, thisMonth, earlier

        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek: return "This week"
            case .thisMonth: return "This month"
            case .earlier: return "Earlier"
            }
        }
    }

    /// Redesign B6: the rows under real headings: "Pinned" (only if any),
    /// then the dated groups, each left out when empty. Every group keeps the
    /// list's own order (newest first), and a pinned row sits only under
    /// Pinned, so no conversation is ever listed twice (the list keys rows by
    /// conversation id).
    private var conversationGroups: [(title: String, conversations: [KadeConversation])] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        var pinned: [KadeConversation] = []
        var dated: [DateGroup: [KadeConversation]] = [:]
        for convo in conversationsService.conversations {
            if convo.isPinned {
                pinned.append(convo)
            } else {
                dated[dateGroup(for: convo, calendar: calendar, startOfToday: startOfToday), default: []].append(convo)
            }
        }
        var groups: [(title: String, conversations: [KadeConversation])] = []
        if !pinned.isEmpty {
            groups.append((title: "Pinned", conversations: pinned))
        }
        for group in DateGroup.allCases {
            if let rows = dated[group], !rows.isEmpty {
                groups.append((title: group.title, conversations: rows))
            }
        }
        return groups
    }

    /// By `updatedAt`. A date that won't parse goes to Earlier; one slightly
    /// in the future (a phone clock behind the server's) counts as Today.
    private func dateGroup(for convo: KadeConversation, calendar: Calendar, startOfToday: Date) -> DateGroup {
        guard let date = KadeDateFormatting.date(from: convo.updatedAt) else { return .earlier }
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? Int.max
        if days < 0 { return .today }
        if days <= 7 { return .thisWeek }
        if days <= 30 { return .thisMonth }
        return .earlier
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

    /// Loading, error or empty as ONE row under the Talk header, checked in
    /// the same order `body` checks them when there's no header.
    @ViewBuilder
    private var listStateRow: some View {
        if conversationsService.isLoadingList {
            ProgressView("Loading your conversations…")
                .accessibilityLabel("Loading your conversations")
                .frame(maxWidth: .infinity)
                .padding(.vertical)
        } else if let error = conversationsService.listError {
            errorState(error)
                .frame(maxWidth: .infinity)
        } else {
            emptyState
                .frame(maxWidth: .infinity)
        }
    }

    /// Redesign B10: the empty screen teaches: what goes here, plus one
    /// VISIBLE button to do it. (The audit: the old line pointed at a "New
    /// Conversation" button that was only a pencil icon.) The words stay one
    /// VoiceOver stop, and the button is their sibling. The old
    /// `.accessibilityElement(children: .combine)` wraps the words only,
    /// never the button (the Amber rule).
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("No conversations yet")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                // Session 11: used to say "Start a chat on the web app and
                // it'll show up here" -- true when this was written, no longer
                // true now that starting one is possible right here.
                Text("Start one with \(DefaultAgentStore.displayName), or anyone you like.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            Button("Start a new chat") {
                startingNewConversation = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Starts a new conversation.")
        }
        .padding()
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
