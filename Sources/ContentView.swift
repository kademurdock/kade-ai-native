import SwiftUI
import SafariServices

/// The app's root. Signed out: one screen to sign in (with Help and the web
/// app reachable before an account exists). Signed in: FIVE TABS — Talk,
/// Library, Create, Play, More (Sep 23 2026 redesign A1; see KadeTabs.swift
/// for why the grouped-sections Home gave way, and KadeTabPages.swift for what
/// each tab holds).
///
/// Accessibility is the whole point of this app, so the notes below are
/// load-bearing, not decoration:
/// - Each tab has its OWN NavigationStack and path, so going to Talk and back
///   to Library returns to the same spot. VoiceOver reads "Library, tab, 2 of 5".
/// - Every stack registers `HomeRoute` exactly once (the build-122 invariant,
///   now per stack). The three single-purpose handoff types still have one
///   `navigationDestination(item:)` each, in the one stack they belong to.
/// - Sign-in errors move VoiceOver focus to the error text and are spoken.
/// - Her standing rules: Spotter is the first button on the first tab; the app
///   opens into a chat with the main character; Back from that chat lands on
///   the conversation list (the Talk tab's root IS the list).
struct ContentView: View {
    // Round 3 of the Transcribe key: the foreground catcher needs to know
    // when the app becomes active (see consumePendingKadeKeysRequest).
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var agentsService: AgentsService
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var apiClient: KadeAPIClient
    @State private var selectedHarnessRunId: String?

    /// Session 14 (Kade asked for it by name): one tap into a Spotter call, no
    /// agent to pick and no conversation to open first. `agentId: nil` lets the
    /// ticket route use the account default for the session envelope; the
    /// Spotter takes over the voice immediately either way.
    @State private var callingSpotter = false
    /// Part 75 (Aug 21 2026): non-nil presents the agent-call screen -- set
    /// when a KADE_CALL push routes through `.agentCall`, cleared by the
    /// cover's own dismissal (item:-keyed).
    @State private var agentCallPayload: AgentCallPayload?
    @State private var spotterTranscript: SpotterTranscriptHandoff?
    /// Part 120 (Sep 3 2026) — a file waiting in the App Group from the share
    /// sheet. Non-nil pushes a chat with the default agent on the Talk tab,
    /// the file already attaching. Its OWN handoff type, deliberately: three
    /// `navigationDestination(item:)` modifiers keyed to the same type is the
    /// build-121 regression that stopped conversation rows opening.
    @State private var pendingShare: SharedFileHandoff?
    /// Part 181: a BOOK or RECORDING from the share sheet goes to the Library
    /// tab, not to a chat. Its own handoff type for the same build-121 reason.
    @State private var pendingLibraryShare: LibraryFileHandoff?
    /// Signed-out screen only (the signed-in web button lives on More).
    /// SFSafariViewController's own load-failure page is system chrome this app
    /// has no control over, so a failed load closes it and a real `.alert`
    /// (always announced by VoiceOver) says what happened instead.
    @State private var showingWeb = false
    @State private var webLoadFailed = false
    @State private var showWebLoadAlert = false
    /// Build 193: the front door from the sign-in screen — Safari onto
    /// /request-access.
    @State private var showingAskToJoin = false
    /// Sep 23 2026 redesign (B13): the sign-in screen's missing "Forgot your
    /// password?" — Safari onto the site's own reset page.
    @State private var showingForgotPassword = false
    @State private var showingHelpSignedOut = false
    /// Build 193: true when a lock-screen LISTEN action routed to the Brief
    /// screen — BriefView starts speaking on load.
    @State private var briefAutoListen = false
    @State private var email = ""
    @State private var password = ""

    /// Siri Shortcuts, Quick Actions and pushes park what they want here (see
    /// `KadeAppIntents.swift`). Observed rather than owned: it's a singleton
    /// that outlives any view.
    @ObservedObject private var router = IntentRouter.shared
    @ObservedObject private var chatPresence = KadeChatPresence.shared
    @ObservedObject private var unread = KadeUnread.shared
    /// Part 278: "Update Kade-AI?" when this copy is behind (KadeUpdateCheck).
    @ObservedObject private var updates = KadeUpdateCheck.shared

    /// The five tabs and each one's own place.
    @State private var tab: KadeTab = .talk
    @State private var talkPath: [HomeRoute] = []
    @State private var libraryPath: [HomeRoute] = []
    @State private var createPath: [HomeRoute] = []
    @State private var playPath: [HomeRoute] = []
    @State private var morePath: [HomeRoute] = []
    @State private var keyboardUp = false

    // Focus targets for VoiceOver on the sign-in screen.
    private enum Focus: Hashable { case status, error, email }
    @AccessibilityFocusState private var a11yFocus: Focus?

    private var statusText: String {
        switch auth.state {
        case .loading:            return "Checking your session…"
        case .signedOut:          return "Not signed in"
        case .signingIn:          return "Signing in…"
        case .signedIn(let u):    return "Signed in as \(u.displayName)"
        case .failed:             return "Not signed in"
        }
    }

    var body: some View {
        Group {
            if case .signedIn(let user) = auth.state {
                signedInTabs(user)
            } else {
                signedOutStack
            }
        }
        /* ⭐ PART 109 — the data-use gate sits on the ROOT, not on any one
         * button, so it covers every screen this app can reach and the
         * signed-out -> signed-in transition too. `.constant` is deliberate:
         * the cover is owned by auth state plus stored consent, never by a
         * local toggle, so no stray dismiss can leave a signed-in session
         * behind an unanswered ask. */
        .fullScreenCover(isPresented: .constant(consentPending)) {
            if let uid = signedInUserId {
                DataUseConsentView(
                    userId: uid,
                    onAgree: { consentBump &+= 1 },
                    onDecline: { auth.signOut() }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onOpenURL { url in handleOpenURL(url) }
        // Aug 5 2026 ROUND 3 of the Transcribe key (her tap-1-silence report):
        // the keyboard ARMS a request in the App Group and tells her to switch
        // apps — and THIS is the catcher: the moment the app foregrounds with a
        // fresh request (under 3 minutes old), it consumes it and drops straight
        // into keyboard-mode Transcribe, already listening.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            consumePendingKadeKeysRequest()
            consumePendingShare()
            if isSignedIn {
                Task { await KadeUnread.shared.refresh(client: apiClient) }
                Task { await KadeUpdateCheck.shared.check(client: apiClient) }
                // Settled once per sign-in; this only asks again after a
                // network failure left it undecided.
                Task { await DescribedVideoAccess.shared.check(client: apiClient) }
            }
        }
        .onAppear {
#if DEBUG
            startScreenshotTourIfAsked()
#endif
            consumePendingKadeKeysRequest()
            consumePendingShare()
        }
        .onChange(of: authStateID) { old, _ in
            handleStateChange(from: old)
            // A Siri phrase can easily land before a saved session has
            // finished restoring, or while she's still signed out. Rather
            // than drop it, it waits here and runs the moment there's an
            // account to run it against.
            handlePendingIntent()
        }
        .onChange(of: router.pending) { _, _ in handlePendingIntent() }
        .onAppear { handlePendingIntent() }
    }

    // MARK: - Signed in: the five tabs

    private func signedInTabs(_ user: KadeUser) -> some View {
        TabView(selection: tabSelection) {
            talkStack
                .tabItem { Label(KadeTab.talk.title, systemImage: KadeTab.talk.systemImage) }
                .tag(KadeTab.talk)
            libraryStack
                .tabItem { Label(KadeTab.library.title, systemImage: KadeTab.library.systemImage) }
                .tag(KadeTab.library)
            createStack
                .tabItem { Label(KadeTab.create.title, systemImage: KadeTab.create.systemImage) }
                .tag(KadeTab.create)
            playStack
                .tabItem { Label(KadeTab.play.title, systemImage: KadeTab.play.systemImage) }
                .tag(KadeTab.play)
            moreStack(user)
                .tabItem { Label(KadeTab.more.title, systemImage: KadeTab.more.systemImage) }
                .badge(unread.total + (updates.available == nil ? 0 : 1))
                .tag(KadeTab.more)
        }
        .environment(\.kadeNavigation, navigation)
        .onAppear {
            LibraryNowPlaying.shared.bind(client: apiClient, voice: voiceService)
        }
        // Part 278: the update alert, on a view of its own (never two
        // presentations on one view, the build-121 rule).
        .background {
            Color.clear
                .alert(
                    updates.prompt.map { updates.title(for: $0) } ?? "Update Kade-AI?",
                    isPresented: updateAlertShowing,
                    presenting: updates.prompt
                ) { offer in
                    Button("Update") { updates.openUpdate(offer) }
                    if !offer.required {
                        Button("Not now", role: .cancel) { updates.notNow(offer) }
                    }
                } message: { offer in
                    Text(updates.message(for: offer))
                }
        }
        .fullScreenCover(isPresented: $callingSpotter) {
            CallView(
                agentId: nil,
                agentName: "Your Spotter",
                apiClient: apiClient,
                spotterDirect: true,
                onOpenTranscript: { convo in
                    tab = .talk
                    spotterTranscript = SpotterTranscriptHandoff(conversation: convo)
                }
            )
        }
        // Part 75: the agent-call screen, item:-keyed off the parked KADE_CALL
        // payload. Deliberately on a DIFFERENT view than the Spotter's cover --
        // two presentation modifiers on one view is exactly the collision
        // class build 121 paid for.
        .background {
            Color.clear
                .fullScreenCover(item: $agentCallPayload) { call in
                    CallView(
                        agentId: call.agentId.isEmpty ? nil : call.agentId,
                        agentName: call.agentName,
                        apiClient: apiClient,
                        callPlanId: call.planId,
                        onOpenTranscript: { convo in
                            tab = .talk
                            spotterTranscript = SpotterTranscriptHandoff(conversation: convo)
                        }
                    )
                }
        }
    }

    /// Re-tapping the tab you are already on goes back to that tab's start,
    /// the way every iPhone app with tabs behaves.
    private var tabSelection: Binding<KadeTab> {
        Binding(
            get: { tab },
            set: { newTab in
                if newTab == tab { popToRoot(newTab) }
                tab = newTab
            }
        )
    }

    private func popToRoot(_ which: KadeTab) {
        switch which {
        case .talk: talkPath = []
        case .library: libraryPath = []
        case .create: createPath = []
        case .play: playPath = []
        case .more: morePath = []
        }
    }

    /// The Talk tab. Its root IS the conversation list (her Part 112 rule:
    /// "no matter what conversation I'm in, when I get out of it, it should
    /// take me to my conversations"), with Spotter, Talk to your main
    /// character, Describe and Transcribe riding at its top.
    private var talkStack: some View {
        NavigationStack(path: $talkPath) {
            ConversationListView(talkHeader: AnyView(TalkHeader()))
                .toolbar { ToolbarItem(placement: .topBarLeading) { searchButton(on: .talk) } }
                .navigationDestination(for: HomeRoute.self) { route in destination(route) }
                /* The shared file opens a chat with whoever her main agent is,
                 * with the file already attaching and her note pre-typed. She
                 * still presses Send: a share sheet must not be able to post
                 * into a conversation without a person deciding to. */
                .navigationDestination(item: $pendingShare) { handoff in
                    ConversationDetailView(
                        conversation: nil,
                        initialAgentId: DefaultAgentStore.resolveId(in: agentsService.agents),
                        initialDraft: handoff.note,
                        initialSharedFileURL: handoff.url
                    )
                }
                // Post-call handoff for a Spotter or agent call started from
                // the root. Its OWN destination type, deliberately -- see
                // `SpotterTranscriptHandoff`.
                .navigationDestination(item: $spotterTranscript) { handoff in
                    ConversationDetailView(conversation: handoff.conversation)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { nowPlayingInset }
    }

    private var libraryStack: some View {
        NavigationStack(path: $libraryPath) {
            ReadingRoomView(apiClient: apiClient)
                .toolbar { ToolbarItem(placement: .topBarLeading) { searchButton(on: .library) } }
                .navigationDestination(for: HomeRoute.self) { route in destination(route) }
                .navigationDestination(item: $pendingLibraryShare) { handoff in
                    ReadingRoomView(apiClient: apiClient, incomingFile: handoff.url, incomingName: handoff.displayName)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { nowPlayingInset }
    }

    private var createStack: some View {
        NavigationStack(path: $createPath) {
            CreateHomeView()
                .toolbar { ToolbarItem(placement: .topBarLeading) { searchButton(on: .create) } }
                .navigationDestination(for: HomeRoute.self) { route in destination(route) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { nowPlayingInset }
    }

    private var playStack: some View {
        NavigationStack(path: $playPath) {
            PlayHomeView()
                .toolbar { ToolbarItem(placement: .topBarLeading) { searchButton(on: .play) } }
                .navigationDestination(for: HomeRoute.self) { route in destination(route) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { nowPlayingInset }
    }

    private func moreStack(_ user: KadeUser) -> some View {
        NavigationStack(path: $morePath) {
            MoreHomeView(user: user, apiClient: apiClient)
                .navigationDestination(for: HomeRoute.self) { route in destination(route) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { nowPlayingInset }
    }

    /// A2: the Library's mini player sits above the tab bar on every tab, so a
    /// book keeps its controls wherever you go. It steps aside inside a
    /// conversation (the composer owns the bottom there) and while the keyboard
    /// is up; it draws nothing when no book or recording is open.
    @ViewBuilder
    private var nowPlayingInset: some View {
        if !chatPresence.inChat && !keyboardUp && !consentPending {
            NowPlayingBar(openPlayer: openLibraryPlayer)
        }
    }

    /// Search opens on top of whichever tab you're on, so Back returns you to
    /// exactly where you were.
    private func searchButton(on which: KadeTab) -> some View {
        Button {
            push(.search, on: which)
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("Search everything")
        .accessibilityHint("Finds places in the app, characters, your chats and the Library.")
    }

    private func push(_ route: HomeRoute, on which: KadeTab) {
        tab = which
        switch which {
        case .talk: talkPath.append(route)
        case .library: libraryPath.append(route)
        case .create: createPath.append(route)
        case .play: playPath.append(route)
        case .more: morePath.append(route)
        }
    }

    private func openLibraryPlayer() {
        tab = .library
        libraryPath = []
        LibraryNowPlaying.shared.showPlayerRequest += 1
    }

    /// What screens deep inside a tab may ask of the root (KadeTabs.swift).
    private var navigation: KadeNavigation {
        KadeNavigation(
            openConversation: { convo in go(.savedChat(convo)) },
            startChat: { agentId in startChat(agentId) },
            open: { route in go(route) },
            select: { which in tab = which },
            callSpotter: {
                KadeHaptics.press()
                callingSpotter = true
            },
            openLibraryItem: { id in
                tab = .library
                libraryPath = []
                LibraryNowPlaying.shared.openItemRequest = id
            }
        )
    }

    private func startChat(_ agentId: String?) {
        if let agentId, agentId != DefaultAgentStore.resolveId(in: agentsService.agents) {
            go(.chatWith(agentId))
        } else {
            go(.mainChat)
        }
    }

    /// The one door onto every tab's path. Each destination has a home tab;
    /// going there selects that tab and shows the destination on top of the
    /// tab's start page, so Back always lands somewhere that makes sense. A
    /// conversation (`.mainChat`, `.savedChat`, `.chatWith`) always opens over
    /// the conversation list — her rule about exits, unchanged. The switch is
    /// exhaustive on purpose: a new route must be given a home or the build
    /// breaks.
    private func go(_ destination: HomeRoute) {
        switch destination {
        case .alerts: unread.markSeen(.alerts)
        case .announcements: unread.markSeen(.announcements)
        case .agentWork: unread.markSeen(.agentWork)
        default: break
        }
        switch destination {
        case .mainChat, .savedChat, .chatWith, .transcribe, .describe, .quickDictate, .kadeKeysDictate:
            tab = .talk
            talkPath = [destination]
        case .conversations:
            tab = .talk
            talkPath = []
        case .readingRoom:
            tab = .library
            libraryPath = []
        case .soundBooth, .myCreations, .wallOfFame, .agentBuilder, .prompts, .describedVideo:
            tab = .create
            createPath = [destination]
        case .parlor, .lounge, .gameRoom, .debateRoom, .matchmaker, .marketplace:
            tab = .play
            playPath = [destination]
        case .feedbackReports:
            // A real parent route makes Back reliable, including another
            // notification tapped while already in Admin.
            tab = .more
            morePath = [.admin, .feedbackReports]
        case .alerts, .announcements, .agentWork, .bookmarks, .settings, .settingsSearch,
             .search, .help, .admin, .brief, .accessRequests:
            tab = .more
            morePath = [destination]
        }
    }

    /// Every destination, built in one place. Each tab's stack registers this
    /// once (`navigationDestination(for: HomeRoute.self)`).
    @ViewBuilder
    private func destination(_ route: HomeRoute) -> some View {
        switch route {
        case .mainChat:
            // The launch chat and "Talk to <main character>": seeded with the
            // stored main agent (or Kiana once the roster loads), with the
            // Spotter shortcut in its toolbar so the opening screen keeps
            // Spotter one tap away (her standing rule).
            ConversationDetailView(
                conversation: nil,
                initialAgentId: DefaultAgentStore.resolveId(in: agentsService.agents),
                showSpotterShortcut: true
            )
        case .chatWith(let agentId):
            ConversationDetailView(conversation: nil, initialAgentId: agentId)
        case .transcribe:
            TranscribeView(apiClient: apiClient)
        case .help:
            HelpView(apiClient: apiClient)
        case .conversations:
            // Never pushed onto the Talk stack (whose root already is the
            // list — a second copy would re-register KadeConversation there,
            // the build-121 collision). Kept buildable for exhaustiveness.
            ConversationListView()
        case .agentWork:
            AgentWorkView(apiClient: apiClient, selectedRunId: selectedHarnessRunId) { conversation in
                go(.savedChat(conversation))
            }
        case .savedChat(let conversation):
            ConversationDetailView(conversation: conversation)
        case .describe:
            DescribeView(apiClient: apiClient)
        case .quickDictate:
            TranscribeView(apiClient: apiClient, quickMode: true)
        case .kadeKeysDictate:
            TranscribeView(apiClient: apiClient, quickMode: true, keyboardMode: true)
        case .matchmaker:
            MatchmakerView(apiClient: apiClient)
        case .parlor:
            ParlorView(apiClient: apiClient)
        case .lounge:
            ClubhouseView(apiClient: apiClient)
        case .gameRoom:
            GameRoomView(apiClient: apiClient)
        case .debateRoom:
            RoomListView(apiClient: apiClient)
        case .agentBuilder:
            AgentManagerView(apiClient: apiClient, currentUserId: currentUserIdOrEmpty)
        case .marketplace:
            MarketplaceView(currentUserId: currentUserIdOrEmpty)
        case .bookmarks:
            BookmarksView(apiClient: apiClient)
        case .prompts:
            PromptsView(
                apiClient: apiClient,
                mainAgentId: DefaultAgentStore.resolveId(in: agentsService.agents)
            )
        case .settings:
            SettingsView(apiClient: apiClient)
        case .settingsSearch(let query):
            SettingsView(apiClient: apiClient, initialQuery: query)
        case .search:
            KadeSearchView(apiClient: apiClient)
        case .brief:
            // Build 193: reachable three ways — Settings row, the morning
            // push's action buttons (autoListen from the lock-screen LISTEN),
            // and a plain tap on the push.
            BriefView(apiClient: apiClient, autoListen: briefAutoListen)
        case .accessRequests:
            // Build 195: the doorbell push deep-link.
            AccessRequestsView(apiClient: apiClient)
        case .alerts:
            AlertsView(apiClient: apiClient)
        case .announcements:
            // Part 112: the broadcast push's deep link — What's New digests,
            // full text, newest first, including missed ones.
            AnnouncementsView(apiClient: apiClient)
        case .soundBooth:
            SoundBoothView(apiClient: apiClient)
        case .describedVideo(let start):
            // Sep 24 2026: make a described video (owner trial; the Create
            // tile, search entry and Library button appear only for an
            // account the server lets in — DescribedVideoAccess).
            DescribedVideoView(apiClient: apiClient, start: start)
        case .readingRoom:
            // Never pushed (the Library tab's root is the Library).
            ReadingRoomView(apiClient: apiClient)
        case .myCreations:
            MyCreationsView(apiClient: apiClient)
        case .wallOfFame:
            WallOfFameView(apiClient: apiClient)
        case .admin:
            AdminView(apiClient: apiClient)
        case .feedbackReports:
            AdminFeedbackView(service: AdminService(client: apiClient))
        }
    }

    // MARK: - Signed out

    private var signedOutStack: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !isRestoring {
                        welcome
                    }

                    statusSection

                    if !isRestoring {
                        signInForm
                    }

                    webButton

                    Spacer(minLength: 0)
                }
                .padding()
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                // Part 292: one container, so the house's words (sorted last)
                // come after the form and the web button, never before them.
                .accessibilityElement(children: .contain)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Kade-AI")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingHelpSignedOut) {
                HelpView()
            }
            .sheet(isPresented: $showingWeb) {
                SafariView(url: URL(string: "https://kademurdock.com")!, loadFailed: $webLoadFailed)
                    .ignoresSafeArea()
            }
            .onChange(of: webLoadFailed) { _, failed in
                guard failed else { return }
                showingWeb = false
                showingAskToJoin = false
                showingForgotPassword = false
                webLoadFailed = false
                // Small delay so the alert doesn't try to present while the
                // sheet is still mid-dismiss.
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    showWebLoadAlert = true
                }
            }
            .alert("Couldn't load Kade-AI web", isPresented: $showWebLoadAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
        }
    }

    /// C4: the four characters with drawn faces say hello before an account
    /// exists — decorative, hidden from VoiceOver; the sentence under them
    /// carries the meaning.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Part 292: the house on the hill, dressed for the season. Its
            // words are the last thing on this screen for VoiceOver.
            KadePaintedHeader(imageName: KadeArt.seasonalHouse(), symbol: "house.fill", tint: .indigo, height: 150, described: true)
            HStack(spacing: 10) {
                KadeCharacterFace(agentID: CharacterMotion.kianaID, name: "Kiana", size: 60, face: .smile)
                KadeCharacterFace(agentID: CharacterMotion.harleyID, name: "Harley", size: 60, face: .smile)
                KadeCharacterFace(agentID: CharacterMotion.dellaID, name: "Della", size: 60, face: .smile)
                KadeCharacterFace(agentID: CharacterMotion.lillyID, name: "Lilly", size: 60, face: .smile)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            Text("Your characters, conversations, and shared moments. Kiana, Harley, Della and Lilly are a few of the characters waiting to talk with you. Sign in to get started.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            /* PART 91 — flagged for contrast by Apple's audit. `.secondary` is
             * about 4.4:1 on white; this line is how anybody tells whether they
             * are signed in, so it is primary. */
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($a11yFocus, equals: .status)
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            // B13: phone numbers sign in too (the newcomer audit), so the
            // field says so.
            VStack(alignment: .leading, spacing: 4) {
                Text("Email or phone number").font(.subheadline)
                TextField("Email or phone number", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Email or phone number")
                    .accessibilityFocused($a11yFocus, equals: .email)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Password").font(.subheadline)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Password")
                    .onSubmit(submit)
            }

            if case .failed(let message) = auth.state {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Sign-in error. \(message)")
                    .accessibilityFocused($a11yFocus, equals: .error)
            }

            Button(action: submit) {
                HStack {
                    if isSigningIn { ProgressView().padding(.trailing, 4) }
                    Text(isSigningIn ? "Signing in…" : "Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)
            .accessibilityHint("Signs in to your Kade-AI account on kademurdock.com.")

            /* B13: the missing way back in. The site's own reset page, same
             * link style as Ask to join below (primary + underline, 44-point
             * target, `.plain` so the tint can't undo the contrast fix —
             * see the Part 91 notes on Ask to join). */
            Button {
                showingForgotPassword = true
            } label: {
                Text("Forgot your password?")
                    .font(.callout)
                    .underline()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the page that sends you a link to set a new password.")
            .sheet(isPresented: $showingForgotPassword) {
                SafariView(url: URL(string: "https://kademurdock.com/forgot-password")!, loadFailed: $webLoadFailed)
            }

            /* Build 193 — THE FRONT DOOR: accounts here are personal invites,
             * and this is how a new person asks for one. PART 91: primary +
             * underline for contrast (the accent tint measured about 3:1), a
             * 44-point frame plus contentShape for the tap target, and `.plain`
             * so the Button's tint cannot re-colour the label (the second pass
             * the audit forced). */
            Button {
                showingAskToJoin = true
            } label: {
                Text("New here without a code? Ask to join")
                    .font(.callout)
                    .underline()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the request page. Kade approves people herself — if she knows you, expect to hear back.")
            .sheet(isPresented: $showingAskToJoin) {
                SafariView(url: URL(string: "https://kademurdock.com/request-access")!, loadFailed: $webLoadFailed)
            }
        }
    }

    private var webButton: some View {
        VStack(spacing: 12) {
            // Session 15: help lives INSIDE the app, above the web button on
            // purpose -- someone looking for help is exactly the person least
            // well served by being handed a web view.
            Button { showingHelpSignedOut = true } label: {
                Label("Help", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeTileLabelStyle(tint: .mint))
            .accessibilityHint("How everything in the app works, section by section.")

            Button { showingWeb = true } label: {
                Label("Open Kade-AI web", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeTileLabelStyle(tint: .blue))
            .accessibilityHint("Opens the full Kade-AI web app in a browser inside this app.")
        }
    }

    // MARK: - State glue

    private var isSigningIn: Bool {
        if case .signingIn = auth.state { return true }
        return false
    }

    private var isRestoring: Bool {
        if case .loading = auth.state { return true }
        return false
    }

    private var isSignedIn: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    /* ⭐ PART 109 — THE DATA-USE GATE. App Review rejected build 245 under
     * 5.1.1(i)/5.1.2(i) because the app sent a person's words to third-party AI
     * services without telling them what was sent, who received it, or asking
     * first. So this is a fullScreenCover with no dismiss gesture and no skip;
     * the only ways past it are Agree or sign out, and NOTHING the user types,
     * records, photographs or shares can reach a server before they have said
     * yes. It reads `auth.state` directly, so a restored session at launch is
     * gated exactly like a fresh sign-in; an account that already agreed to
     * the CURRENT version never sees it again. */
    /// UserDefaults does not publish, so recording consent would not by itself
    /// re-run `body` and the cover would stay up over an agreed session.
    /// Reading this inside `consentPending` — which `body` reads — is what makes
    /// Agree take effect immediately. `&+=` because it only has to CHANGE.
    @State private var consentBump = 0

    /// Part 278: the update alert waits while the data-use notice or a call
    /// covers the tabs, and shows the moment they are gone.
    private var updateAlertShowing: Binding<Bool> {
        Binding(
            get: { updates.prompt != nil && !consentPending && !callingSpotter && agentCallPayload == nil },
            set: { showing in
                if !showing { updates.prompt = nil }
            }
        )
    }

    private var consentPending: Bool {
        _ = consentBump
        guard case .signedIn(let user) = auth.state else { return false }
        return !DataUseConsent.hasAgreed(userId: user.id)
    }

    private var signedInUserId: String? {
        if case .signedIn(let user) = auth.state { return user.id }
        return nil
    }

    /// For `AgentManagerView` / `MarketplaceView`. Empty string is a safe,
    /// fail-soft default (both are only reachable while signed in).
    private var currentUserIdOrEmpty: String {
        if case .signedIn(let user) = auth.state { return user.id }
        return ""
    }

    /// A cheap identity for the current state so onChange fires on transitions.
    private var authStateID: String {
        switch auth.state {
        case .loading: return "loading"
        case .signedOut: return "signedOut"
        case .signingIn: return "signingIn"
        case .signedIn(let u): return "signedIn:\(u.id)"
        case .failed(let m): return "failed:\(m)"
        }
    }

    private func submit() {
        guard !isSigningIn else { return }
        let e = email, p = password
        Task { await auth.signIn(email: e, password: p) }
    }

    /// Links into the app: the keyboard's dictation hand-off, and (redesign
    /// C2/C3/C7) the home screen widget, the lock-screen job card and the
    /// Call Spotter control.
    ///   kadeai://kadekeys-dictate
    ///   kadeai://spotter
    ///   kadeai://talk            kadeai://talk?agent=<agent id>
    ///   kadeai://library         kadeai://library/continue
    ///   kadeai://search
    ///   kadeai://jobs            (a job card: just open the app where it was)
    /// Signed out, she just lands on sign-in; nothing to route.
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "kadeai", isSignedIn else { return }
        let host = url.host ?? ""
        // KADE KEYS dictate (July 31 2026): keyboards can't touch the mic (OS
        // law, the Wispr dance), so the app records and hands the text back
        // through the App Group container.
        if host == "kadekeys-dictate" || url.path.contains("kadekeys-dictate") {
            // Round 3: the keyboard also ARMS an App-Group request in case this
            // URL never fires. It DID fire, so clear the armed copy so the next
            // ordinary foreground can't double-start a session.
            UserDefaults(suiteName: "group.com.kademurdock.kadeai")?
                .removeObject(forKey: "kadeKeys.transcribeRequest.v1")
            go(.kadeKeysDictate)
            return
        }
        switch host {
        case "spotter":
            KadeHaptics.press()
            callingSpotter = true
        case "talk":
            let agent = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "agent" })?.value
            startChat(agent?.isEmpty == false ? agent : nil)
        case "library":
            if url.path.contains("continue") {
                openLibraryPlayer()
            } else {
                go(.readingRoom)
            }
        case "search":
            go(.search)
        case "jobs":
            // The lock-screen progress card (KadeWidgets): an upload opens
            // the Library, a described video its own screen, a song or scene
            // the Sound Booth.
            let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "kind" })?.value ?? ""
            if kind == "described-video" {
                go(.describedVideo(DescribedVideoStart(openLatest: true)))
            } else {
                go(kind == "upload" ? .readingRoom : .soundBooth)
            }
        default:
            break
        }
    }

#if DEBUG
    /// SCREENSHOT TOUR (July 31 2026, the App Store sprint). Debug-only by
    /// construction — the Release archive never contains this code. CI's
    /// simulator step launches with SIMCTL_CHILD_KADE_TOUR=1 plus the test
    /// seat's credentials, and this walks the app through its best rooms on a
    /// timer while the workflow snaps frames. Never runs on a real device,
    /// never with real accounts.
    ///
    /// Sep 23 2026 redesign: the tour walks the five tabs, and each stop drops
    /// a marker file (`tour-stop-N.txt`, holding the stop's name) in the app's
    /// Documents folder, so the `ios-redesign-tour` workflow photographs each
    /// screen when it has actually arrived instead of on a guessed timer.
    private func startScreenshotTourIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard env["KADE_TOUR"] == "1",
              let tourEmail = env["KADE_TOUR_EMAIL"],
              let tourPass = env["KADE_TOUR_PASS"] else { return }
        Task {
            tourMark(0, "launch")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await auth.signIn(email: tourEmail, password: tourPass)
            // The test seat on a fresh simulator has never seen the data-use
            // notice. This tour is DEBUG-only and simulator-only, so it
            // records the answer rather than photographing the notice at
            // every stop. Release builds contain none of this.
            if case .signedIn(let user) = auth.state {
                DataUseConsent.record(for: user.id)
                consentBump &+= 1
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let stops: [(String, () -> Void)] = [
                ("launch-chat", { tab = .talk; talkPath = [.mainChat] }),
                ("talk", { tab = .talk; talkPath = [] }),
                ("library", { tab = .library; libraryPath = [] }),
                ("create", { tab = .create; createPath = [] }),
                ("play", { tab = .play; playPath = [] }),
                ("more", { tab = .more; morePath = [] }),
                ("search", { tab = .more; morePath = [.search] }),
                ("settings", { go(.settings) }),
                ("sound-booth", { go(.soundBooth) }),
                ("help", { go(.help) }),
                ("marketplace", { go(.marketplace) }),
                ("saved-chat", {
                    if let convo = conversationsService.conversations.first {
                        go(.savedChat(convo))
                    } else {
                        go(.conversations)
                    }
                }),
            ]
            for (index, stop) in stops.enumerated() {
                stop.1()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                tourMark(index + 1, stop.0)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func tourMark(_ index: Int, _ name: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? name.write(to: docs.appendingPathComponent("tour-stop-\(index).txt"), atomically: true, encoding: .utf8)
    }
#endif

    /// Runs whatever a Siri phrase, Quick Action or push asked for, but only
    /// once there is actually an account to run it against -- otherwise the
    /// request stays parked in `IntentRouter` and this gets called again on
    /// sign-in.
    private func handlePendingIntent() {
        guard router.pending != nil, isSignedIn else { return }
        guard let destination = router.consume() else { return }
        switch destination {
        case .spotterCall:
            // Straight into the call, no intermediate screen. This is the
            // whole point of the phrase.
            callingSpotter = true
        case .transcribe:
            go(.transcribe)
        case .conversations:
            go(.conversations)
        case .describe:
            go(.describe)
        case .quickDictate:
            go(.quickDictate)
        case .matchmaker:
            go(.matchmaker)
        case .gameRoom:
            go(.gameRoom)
        case .debateRoom:
            go(.debateRoom)
        case .agentBuilder:
            go(.agentBuilder)
        case .settings:
            go(.settings)
        case .brief:
            briefAutoListen = false
            go(.brief)
        case .briefListen:
            briefAutoListen = true
            go(.brief)
        case .accessRequests:
            go(.accessRequests)
        case .agentCall:
            // Part 75: the payload was parked next to the destination --
            // consume it the same one-shot way. A ring with no payload
            // (shouldn't happen) just opens the app normally.
            if let call = router.pendingAgentCall {
                router.pendingAgentCall = nil
                agentCallPayload = call
            }
        case .feedbackReports:
            go(.feedbackReports)
        case .adminHub:
            go(.admin)
        case .agentWork:
            selectedHarnessRunId = router.pendingHarnessRunId
            router.pendingHarnessRunId = nil
            go(.agentWork)
        case .announcements:
            go(.announcements)
        case .readingRoom:
            go(.readingRoom)
        case .soundBooth:
            go(.soundBooth)
        case .describedVideo:
            // The "your described video is ready" push (bridge agentId
            // described-video, route "described-video"): the finished video,
            // even while another is still working.
            go(.describedVideo(DescribedVideoStart(openFinished: true)))
        }
    }

    /// Round 3 of the Kade Keys Transcribe flow (Aug 5 2026): the keyboard
    /// ARMS a request in the App Group (programmatic keyboard→app opening
    /// proved dead on her iOS); this consumes a FRESH request (under 3 minutes)
    /// the moment the app foregrounds and drops straight into keyboard-mode
    /// Transcribe, already listening. Stale requests clear silently — an armed
    /// tap from yesterday can never surprise her. Consume-once by removeObject
    /// BEFORE the freshness check.
    private func consumePendingKadeKeysRequest() {
        guard isSignedIn else { return }
        // Round 5: the request rides TWO carriers — the shared defaults key
        // AND an atomic file marker (the keyboard can get suspended before its
        // defaults flush reaches disk; the file write is synchronous and
        // survives). Whichever is freshest wins; both are cleared.
        var stamp: Double = 0
        let key = "kadeKeys.transcribeRequest.v1"
        let defaults = UserDefaults(suiteName: "group.com.kademurdock.kadeai")
        if let defaults {
            stamp = max(stamp, defaults.double(forKey: key))
            defaults.removeObject(forKey: key)
        }
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.kademurdock.kadeai"
        ) {
            let marker = container.appendingPathComponent("kadeKeysTranscribeRequest.txt")
            if let text = try? String(contentsOf: marker, encoding: .utf8), let fileStamp = Double(text) {
                stamp = max(stamp, fileStamp)
            }
            try? FileManager.default.removeItem(at: marker)
        }
        guard stamp > 0, Date().timeIntervalSince1970 - stamp < 180 else { return }
        go(.kadeKeysDictate)
    }

    /* SHARE TO YOUR AGENT (Part 120). The extension parked a file in the App
     * Group and told her to open the app; this is the catcher. Consume once,
     * honour a staleness window, and do nothing at all when signed out (the
     * share survives in the container until she signs in, and the 30-minute
     * window in KadeShareStore is what stops it surprising her days later). */
    private func consumePendingShare() {
        guard isSignedIn, pendingShare == nil, pendingLibraryShare == nil else { return }
        guard let taken = KadeShareStore.take() else { return }
        /* Part 181: a book file or a recording is for the Library. Anything
         * else keeps the Part 120 path into a chat with her main agent. */
        if LibraryFileHandoff.isLibraryKind(taken.pending.kind, name: taken.pending.displayName) {
            tab = .library
            libraryPath = []
            pendingLibraryShare = LibraryFileHandoff(url: taken.url, displayName: taken.pending.displayName)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Opening the Library to donate \(taken.pending.displayName)."
            )
            return
        }
        tab = .talk
        talkPath = []
        pendingShare = SharedFileHandoff(
            url: taken.url,
            displayName: taken.pending.displayName,
            note: taken.pending.note
        )
        UIAccessibility.post(
            notification: .announcement,
            argument: "Opening a chat to send \(taken.pending.displayName)."
        )
    }

    private func handleStateChange(from previous: String) {
        switch auth.state {
        case .signedIn(let user):
            password = ""
            // A fresh sign-in says so; a quiet session restore at launch does not.
            if previous == "signingIn" {
                UIAccessibility.post(notification: .announcement, argument: "Signed in as \(user.displayName).")
            }
            Task { await KadeUnread.shared.refresh(client: apiClient, force: true) }
            // Part 278: after the launch chat has settled, see whether this
            // copy is behind. The alert itself waits for the data-use notice.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await KadeUpdateCheck.shared.check(client: apiClient)
            }
            // Sep 24 2026: may this account make described videos? Asked once
            // per sign-in, after the launch chat has settled. A refusal hides
            // the feature silently (the owner trial; App Review never sees it).
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await DescribedVideoAccess.shared.check(client: apiClient)
            }
            // Session 26 chat-first launch: the moment a session lands
            // (cold-start restore or a fresh sign-in), open the main-agent
            // chat on the Talk tab — unless a Siri intent is already waiting
            // (it routes right after this and must win) or something is
            // already open there. The conversation list is its tab's root, so
            // Back from the chat lands on the list (Part 112).
            if talkPath.isEmpty && router.pending == nil {
                tab = .talk
                talkPath = [.mainChat]
            }
        case .failed:
            a11yFocus = .error           // error gets spoken
        case .signedOut:
            // Cold launch with no saved session, OR just tapped "Sign out" —
            // land VoiceOver on the sign-in field, and never show the last
            // person's lists, place or book to the next one.
            conversationsService.reset()
            agentsService.reset()
            voiceService.reset()
            LibraryNowPlaying.shared.stop()
            KadeUnread.shared.reset()
            DescribedVideoAccess.shared.reset()
            talkPath = []
            libraryPath = []
            createPath = []
            playPath = []
            morePath = []
            tab = .talk
            a11yFocus = .email
        default:
            break
        }
    }
}

/// SFSafariViewController wrapper — the "escape hatch" to the full web app.
/// Reports a failed initial page load back to the caller via `loadFailed`
/// (set true) rather than silently leaving Safari's own built-in error page
/// on screen, which this app has no control over the accessibility of.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    @Binding var loadFailed: Bool

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let parent: SafariView
        init(_ parent: SafariView) { self.parent = parent }

        func safariViewController(
            _ controller: SFSafariViewController,
            didCompleteInitialLoad didLoadSuccessfully: Bool
        ) {
            if !didLoadSuccessfully {
                parent.loadFailed = true
            }
        }
    }
}

#Preview {
    let client = KadeAPIClient()
    return ContentView()
        .environmentObject(client)
        .environmentObject(AuthService(client: client))
        .environmentObject(ConversationsService(client: client))
        .environmentObject(AgentsService(client: client))
        .environmentObject(VoiceService(client: client))
        // Session 17: MessageRow now reads this via the environment too.
        .environmentObject(AppearancePreferences())
}

/// A call's post-call transcript push. Separate type from
/// `ChatTranscriptHandoff` on purpose: `.navigationDestination(item:)` keys its
/// destination by TYPE across a whole stack -- two handoffs sharing one type
/// would re-create exactly the collision this pair exists to prevent. See
/// `ChatTranscriptHandoff` for the full story.
struct SpotterTranscriptHandoff: Identifiable, Hashable {
    let conversation: KadeConversation
    var id: String { conversation.conversationId }
}

/// Part 120 — a file handed over by the share extension, on its way into a
/// chat. Its own single-purpose type for the same reason
/// `SpotterTranscriptHandoff` is one: `navigationDestination(item:)` registers
/// by TYPE across the whole stack, and build 121 shipped three of them all
/// keyed to `KadeConversation?`, which made conversation rows stop opening.
struct SharedFileHandoff: Identifiable, Hashable {
    let url: URL
    let displayName: String
    let note: String?
    var id: String { url.absoluteString }
}

/// Part 181 — a shared file bound for the Library (a book to be read by a
/// voice, or a recording to donate). Declared in exactly one
/// `navigationDestination(item:)`, like its two siblings above.
struct LibraryFileHandoff: Identifiable, Hashable {
    let url: URL
    let displayName: String
    var id: String { url.absoluteString }
    static let bookExts: Set<String> = ["zip", "epub", "txt", "docx", "html", "htm", "xhtml"]
    static let audioExts: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "ogg", "oga", "opus", "flac", "aiff", "aif"]
    static func isLibraryKind(_ kind: String, name: String) -> Bool {
        if kind == "book" || kind == "recording" || kind == "link" { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return bookExts.contains(ext) || audioExts.contains(ext)
    }
}

/// Counts the conversation screens on display so the root's Now Playing bar
/// can step aside for a composer. Pushed conversations are not all on a root
/// path (the conversation list pushes its own), so the screens report
/// themselves.
final class KadeChatPresence: ObservableObject {
    static let shared = KadeChatPresence()
    @Published private(set) var open = 0
    var inChat: Bool { open > 0 }
    func appeared() { open += 1 }
    func disappeared() { open = max(0, open - 1) }
}

/// The app's own programmatic destinations, registered once per tab stack
/// with `navigationDestination(for: HomeRoute.self)`.
///
/// The rule this obeys, and the reason it is written down here rather than
/// only in a commit message: `navigationDestination` registers by TYPE for the
/// entire enclosing `NavigationStack`, not for the view it is written on. Two
/// registrations for the same type in one stack means SwiftUI honours one and
/// silently ignores the rest -- no crash, no warning, just a screen that reads
/// correctly and does nothing when you activate it. That shipped once (build
/// 121) and cost a build to find.
enum HomeRoute: Identifiable, Hashable {
    /// Session 26 (her call: "the first thing people should do when they open
    /// the app is land in a chat with an agent"): a fresh chat pointed at the
    /// main character, opened the moment sign-in lands, over the conversation
    /// list (Part 112, her rule about exits).
    case mainChat
    /// Sep 23 2026 redesign: a fresh chat with one particular character
    /// (search results, the home screen widget).
    case chatWith(String)
    case transcribe
    case help
    case conversations
    case agentWork
    case savedChat(KadeConversation)
    case describe
    case quickDictate
    case kadeKeysDictate
    case matchmaker
    case parlor
    case lounge
    case gameRoom
    case debateRoom
    case agentBuilder
    case marketplace
    case bookmarks
    case prompts
    case settings
    /// Sep 23 2026 redesign (A3): Settings opened with its own search already
    /// typed, from the app-wide search.
    case settingsSearch(String)
    /// Sep 23 2026 redesign (A3): search everything.
    case search
    case alerts
    /// Part 120 (Sep 3 2026) — the Sound Booth.
    case soundBooth
    /// Sep 24 2026 — make a described video: plainly, from a Library video
    /// (book + track), or on the newest finished one (a push or a card).
    case describedVideo(DescribedVideoStart)
    /// Part 181 (Sep 11 2026) — the Library (born the Reading Room). Its own
    /// tab since the redesign.
    case readingRoom
    case myCreations
    case wallOfFame
    case admin
    case feedbackReports
    case brief
    case accessRequests
    /// Part 112: the What's New history — where a broadcast push's tap lands
    /// (route name "announcements"), and where a digest you MISSED can still
    /// be read. See AnnouncementsView for the whole story.
    case announcements

    var id: String {
        switch self {
        case .mainChat: return "mainChat"
        case .chatWith(let agentId): return "chatWith-\(agentId)"
        case .transcribe: return "transcribe"
        case .help: return "help"
        case .conversations: return "conversations"
        case .agentWork: return "agentWork"
        case .savedChat(let conversation): return "savedChat-\(conversation.conversationId)"
        case .describe: return "describe"
        case .quickDictate: return "quickDictate"
        case .kadeKeysDictate: return "kadeKeysDictate"
        case .matchmaker: return "matchmaker"
        case .parlor: return "parlor"
        case .lounge: return "lounge"
        case .gameRoom: return "gameRoom"
        case .debateRoom: return "debateRoom"
        case .agentBuilder: return "agentBuilder"
        case .marketplace: return "marketplace"
        case .bookmarks: return "bookmarks"
        case .prompts: return "prompts"
        case .settings: return "settings"
        case .settingsSearch(let query): return "settingsSearch-\(query)"
        case .search: return "search"
        case .alerts: return "alerts"
        case .soundBooth: return "soundBooth"
        case .describedVideo(let start):
            return "describedVideo-\(start.book ?? "")-\(start.track ?? 0)-\(start.openLatest)-\(start.openFinished)"
        case .readingRoom: return "readingRoom"
        case .myCreations: return "myCreations"
        case .wallOfFame: return "wallOfFame"
        case .admin: return "admin"
        case .feedbackReports: return "feedbackReports"
        case .brief: return "brief"
        case .accessRequests: return "accessRequests"
        case .announcements: return "announcements"
        }
    }
}
