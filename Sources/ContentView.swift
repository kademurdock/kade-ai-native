import SwiftUI
import SafariServices

/// Phase 1 home screen: sign in against kademurdock.com, then show
/// "Signed in as …". Accessibility is the whole point of this app, so the
/// notes below are load-bearing, not decoration:
/// - The title is a real VoiceOver heading (rotor "Headings" lands on it).
/// - The status line is ONE combined element, read in a single swipe, and it
///   is the source of truth for the current auth state.
/// - Sign-in errors move VoiceOver focus to the error text and are spoken.
/// - On successful sign-in, focus jumps to the status line so the user hears
///   "Signed in as …" without hunting for it.
struct ContentView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var agentsService: AgentsService
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var apiClient: KadeAPIClient

    // Session 14 (Kade asked for it by name): one tap from the home screen
    // straight into a Spotter call, no agent to pick and no conversation to
    // open first. The server has supported exactly this since July 18 --
    // `{type:'hello', spotterDirect:true}` on the call socket, a parameter
    // `CallView` has carried since session 13 but which nothing in the app
    // had ever actually SET to true. Placed HERE rather than in the
    // conversation list's toolbar deliberately: "I need eyes right now" is a
    // top-level, time-sensitive thing to want, and it should never be two
    // screens and a picker deep. `agentId: nil` lets the ticket route use
    // the account default for the session envelope; the Spotter takes over
    // the voice immediately either way, so which character nominally opened
    // the call is not something the caller ever hears.
    @State private var callingSpotter = false
    @State private var spotterTranscript: SpotterTranscriptHandoff?
    @State private var showingWeb = false
    // Kade tapped "Open Kade-AI web" (build 106/107) and hit what she
    // described as an "error image" -- unconfirmed whether that was
    // specifically this button, but SFSafariViewController's own built-in
    // load-failure page is system chrome this app has no control over and
    // no guarantee is well-labeled for VoiceOver. Rather than leave that
    // as the only possible outcome, SafariView now reports load failures
    // back here via `loadFailed`, and a real .alert (guaranteed to be
    // announced by VoiceOver) replaces whatever Safari's own error page
    // would have shown.
    @State private var webLoadFailed = false
    @State private var showWebLoadAlert = false
    @State private var email = ""
    @State private var password = ""

    /// Siri Shortcuts park what they want here (see `KadeAppIntents.swift`).
    /// Observed rather than owned: it's a singleton that outlives any view.
    @ObservedObject private var router = IntentRouter.shared
    /// Programmatic navigation for the two new home-screen destinations AND
    /// for anything Siri asks for. ONE `navigationDestination(item:)`, ONE
    /// brand-new type, declared exactly once at the root of this stack --
    /// the invariant build 122 exists to protect. `KadeConversation` still
    /// has exactly one destination in the whole app, and it is not this one.
    @State private var route: HomeRoute?

    // Focus targets for VoiceOver.
    private enum Focus: Hashable { case status, error, email }
    @AccessibilityFocusState private var a11yFocus: Focus?

    private var buildString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v), build \(b)"
    }

    private var statusText: String {
        switch auth.state {
        case .loading:            return "\(buildString) · checking your session…"
        case .signedOut:          return "\(buildString) · not signed in"
        case .signingIn:          return "\(buildString) · signing in…"
        case .signedIn(let u):    return "\(buildString) · signed in as \(u.displayName)"
        case .failed:             return "\(buildString) · not signed in"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Session 11: the "Welcome to Kade-AI" hero line
                    // above this used to live here, right under the nav
                    // bar's own "Kade-AI" title -- Kade confirmed it reads
                    // like a doubled title ("yeah it says that twice") and
                    // said to just remove it ("it's already there
                    // basically"), so it's gone; the nav bar title alone
                    // covers the screen's heading now.
                    //
                    // Same pass flagged this: "native app" / "web app" as if
                    // they're two separate products is an internal framing
                    // (this app vs. the Capacitor shell / kademurdock.com)
                    // that means nothing to a tester who just has one app
                    // called Kade-AI. Rewritten to describe what's HERE and
                    // point at the actual button for what's not, instead of
                    // narrating the rollout plan.
                    // Kade (build 108 testing, July 19 2026): this line
                    // still made sense before sign-in, but reads oddly once
                    // she's already signed in ("sign in to chat" when she's
                    // mid-conversation makes no sense) -- now only shown
                    // while there's actually a sign-in step ahead of her.
                    // Session 13 (calling + Spotter/Live shipped natively,
                    // commit 4b83b34): this line used to send Spotter
                    // seekers straight to the web button, which stopped
                    // being true the moment Spotter could be reached from
                    // right here (call any agent, then "Bring in your
                    // Spotter" mid-call) -- caught from the build's own CI
                    // screenshot, not guessed. Games/Game Room genuinely
                    // aren't ported, so that half of the line still holds.
                    // Session 17/18: the Game Room leaderboard and the
                    // Matchmaker are now native (see the two new buttons
                    // below) -- but this line only ever shows BEFORE
                    // sign-in, and both of those require signing in same
                    // as everything else here, so the copy itself still
                    // reads true for who actually sees it. Actually
                    // PLAYING a game was never blocked either way, on web
                    // or natively: it happens through ordinary chat ("deal
                    // me in" to any companion), since the game engine
                    // lives server-side and the web's own GameTable widget
                    // is decorative/aria-hidden by design (see
                    // GameRoomService's doc comment) -- there was never a
                    // real gap there, just an unadvertised capability, now
                    // written down in Help.
                    if !isSignedIn {
                        Text("Sign in to chat with your Kade-AI companions and call your Spotter. For games and everything else, use \"Open Kade-AI web\" below.")
                            .font(.body)
                    }

                    statusSection

                    Group {
                        switch auth.state {
                        case .signedIn(let user):
                            signedInSection(user)
                        case .loading:
                            EmptyView()
                        default:
                            signInForm
                        }
                    }

                    // Session 18 (grouped sections): while signed IN, Help and
                    // Open web live inside the "Settings and help" section
                    // above -- rendering this block too would put two
                    // identical Help buttons on one screen. Signed out it
                    // stays, so Help is reachable before signing in.
                    if !isSignedIn {
                        webButton
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle("Kade-AI")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingWeb) {
                SafariView(url: URL(string: "https://kademurdock.com")!, loadFailed: $webLoadFailed)
                    .ignoresSafeArea()
            }
            .onChange(of: webLoadFailed) { _, failed in
                guard failed else { return }
                showingWeb = false
                webLoadFailed = false
                // Small delay so the alert doesn't try to present while the
                // sheet is still mid-dismiss -- same reasoning as the
                // deliberate delay in ConversationDetailView's scroll-to-
                // bottom, just applied to a presentation transition instead
                // of a scroll.
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
            .navigationDestination(item: $route) { destination in
                switch destination {
                case .mainChat:
                    // The launch chat: seeded with the stored main agent
                    // (or Kiana once the roster loads — see
                    // DefaultAgentStore.resolveId and the seeding block in
                    // ConversationDetailView), with the Spotter shortcut in
                    // its toolbar so the opening screen keeps Spotter one
                    // tap away (her standing rule).
                    ConversationDetailView(
                        conversation: nil,
                        initialAgentId: DefaultAgentStore.resolveId(in: agentsService.agents),
                        showSpotterShortcut: true
                    )
                case .transcribe:
                    TranscribeView(apiClient: apiClient)
                case .help:
                    HelpView(apiClient: apiClient)
                case .conversations:
                    ConversationListView()
                case .describe:
                    DescribeView(apiClient: apiClient)
                case .quickDictate:
                    TranscribeView(apiClient: apiClient, quickMode: true)
                case .matchmaker:
                    MatchmakerView(apiClient: apiClient)
                case .parlor:
                    ParlorView(apiClient: apiClient)
                case .gameRoom:
                    GameRoomView(apiClient: apiClient)
                case .debateRoom:
                    RoomListView(apiClient: apiClient)
                case .agentBuilder:
                    AgentManagerView(apiClient: apiClient, currentUserId: currentUserIdOrEmpty)
                case .settings:
                    SettingsView(apiClient: apiClient)
                case .alerts:
                    AlertsView(apiClient: apiClient)
                case .myCreations:
                    MyCreationsView(apiClient: apiClient)
                case .wallOfFame:
                    WallOfFameView(apiClient: apiClient)
                case .admin:
                    AdminView(apiClient: apiClient)
                }
            }
        }
        .onChange(of: authStateID) { _, _ in
            handleStateChange()
            // A Siri phrase can easily land before a saved session has
            // finished restoring, or while she's still signed out. Rather
            // than drop it, it waits here and runs the moment there's an
            // account to run it against.
            handlePendingIntent()
        }
        .onChange(of: router.pending) { _, _ in handlePendingIntent() }
        .onAppear { handlePendingIntent() }
    }

    // MARK: - Sections

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.headline)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($a11yFocus, equals: .status)
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                Text("Email").font(.subheadline)
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Email")
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
        }
    }

    private func signedInSection(_ user: KadeUser) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Session 11 (Kade: "it also says signed in as kade murdock
            // twice"): this used to repeat "Signed in as {name}" verbatim,
            // duplicating the Status line right above it -- which already
            // carries that exact phrase on purpose (a11yFocus jumps there
            // on sign-in specifically so it's the FIRST thing heard). Kept
            // a real heading here (a rotor landmark, the only one on this
            // screen once signed in) but reworded it so it stops repeating
            // the Status line word for word; the email is still useful
            // detail Status doesn't carry.
            Text("Your account")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(user.email)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Session 18 (Kade's pick via AskUserQuestion: "grouped sections"
            // over real bottom tabs): the home screen had grown to 13 buttons
            // in one flat run. Three labeled section headers -- Talk, Tools,
            // Settings and help -- each a real VoiceOver heading, so the
            // Headings rotor jumps between groups instead of swiping the
            // whole list. Spotter deliberately stays the FIRST button in the
            // first section: "keep it one-tap, always" is her standing rule.
            Text("Talk")
                .font(.headline)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)

            Button {
                // Session 23 garnish: the one big action gets the one
                // medium tap -- gated like every haptic in the app.
                KadeHaptics.press()
                callingSpotter = true
            } label: {
                Label("Call your Spotter", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeHeroButtonStyle())
            .accessibilityLabel("Call your Spotter")
            .accessibilityHint("Starts a live call with your visual companion straight away, without picking anyone first.")
            .fullScreenCover(isPresented: $callingSpotter) {
                CallView(
                    agentId: nil,
                    agentName: "Your Spotter",
                    apiClient: apiClient,
                    spotterDirect: true,
                    onOpenTranscript: { convo in
                        spotterTranscript = SpotterTranscriptHandoff(conversation: convo)
                    }
                )
            }
            // Post-call handoff for a Spotter call started from here.
            // Its OWN destination type, deliberately -- see
            // `SpotterTranscriptHandoff` and the build-121 regression it
            // fixes (three `navigationDestination(item:)` modifiers all
            // keyed to `KadeConversation` in one stack, which broke the
            // conversation list's row taps).
            .navigationDestination(item: $spotterTranscript) { handoff in
                ConversationDetailView(conversation: handoff.conversation)
            }

            // Deliberately a `route` push rather than the `NavigationLink`
            // this used to be, and the reason is load-bearing rather than
            // stylistic: Siri's "open my conversations" can fire at ANY
            // moment, including while a conversation list is already on the
            // stack. Two `ConversationListView`s in one stack would each
            // re-declare `.navigationDestination(item:)` for
            // `KadeConversation` -- precisely the collision that stopped
            // conversation rows opening in build 121. Routing both the
            // button and the Siri phrase through one optional `HomeRoute`
            // makes a second copy structurally impossible: one optional can
            // only hold one destination at a time.
            Button { route = .conversations } label: {
                Label("Your conversations", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeTileLabelStyle(tint: .blue))
            .accessibilityHint("Opens your conversation list.")

            // Session 18: native notification history — the one genuinely
            // missing piece of the web's four tabs per the session-17/18
            // tabs writeup. Lives in Talk (it is things Kade-AI SAID to
            // you), not Tools. No Siri phrase (the provider sits at
            // Apple's 10-shortcut cap — see KadeAppIntents) and no Quick
            // Action (iOS shows 4; five are already declared).
            Button { route = .alerts } label: {
                Label("Alerts", systemImage: "bell")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeTileLabelStyle(tint: .orange))
            .accessibilityHint("Your recent reminders and check-ins, and how they reach you.")

            Text("Tools")
                .font(.headline)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)

            // Session 25 (Kade approved the audit list: "All four"): Tools
            // was 8 identical full-width rows -- a long scroll for a
            // section used a couple of taps at a time. Now a 2-column tile
            // grid: SAME order, SAME spoken labels (each tile pins its
            // accessibilityLabel to the exact full phrase the old row
            // spoke), SAME hints -- by ear nothing changed except there is
            // half as far to go. Visible titles are shortened to fit
            // tiles; the spoken ones are not.
            //
            // Per-tool history, carried from the row era: Transcribe --
            // session 15 ("consider the transcriber app... they need to go
            // native as well"). Describe -- session 16, the other half of
            // "as much accessible native as possible." Matchmaker / Game
            // Room -- session 17/18 ports (read/quiz-only, tractable in one
            // session; see their services). Debate Room -- same night,
            // upgraded from "too large" on a full route read (475 lines,
            // no WebSocket; see RoomService.swift). Agent Builder -- "Go
            // head with agent builder," built phased (see
            // AgentBuilderService.swift). My Creations / Wall of Fame --
            // session 23, the last two user-facing web-only pages; no Siri
            // phrases (10-cap) or Quick Actions (4-of-5) -- same
            // constraint notes as Alerts.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                toolTile("Transcribe", spoken: "Transcribe a voice memo", icon: "waveform", tint: .purple, hint: "Records what you say and turns it into text you can edit, tidy up and share.", destination: .transcribe)
                toolTile("Describe", spoken: "Describe a photo, video, or document", icon: "plus.viewfinder", tint: .teal, hint: "Take or choose a photo or video, or pick a document, and get it described or read back to you.", destination: .describe)
                toolTile("Matchmaker", spoken: "Matchmaker", icon: "person.2.fill", tint: .pink, hint: "Five quick questions, then three companions who might be a good fit.", destination: .matchmaker)
                toolTile("The Parlor", spoken: "The Parlor", icon: "suit.club.fill", tint: .mint, hint: "Every game on a menu — play your own cards with buttons, seat characters if you want company, and a house narrator calls the table.", destination: .parlor)
                toolTile("Game Room", spoken: "Game Room", icon: "gamecontroller", tint: .green, hint: "Family standings and recent results from games played in chat.", destination: .gameRoom)
                toolTile("Debate Room", spoken: "Debate Room", icon: "person.3.fill", tint: .indigo, hint: "Set a topic, cast 2 to 6 companions, and let them go back and forth. Also reaches the Conversation Hall.", destination: .debateRoom)
                toolTile("Agent Builder", spoken: "Agent Builder", icon: "person.crop.circle.badge.plus", tint: .cyan, hint: "Create or edit your own companions.", destination: .agentBuilder)
                toolTile("My Creations", spoken: "My Creations", icon: "photo.stack", tint: .yellow, hint: "Every picture, video, and song you've made — play them, save them to Photos, or put them on the family Wall of Fame.", destination: .myCreations)
                toolTile("Wall of Fame", spoken: "Wall of Fame", icon: "trophy", tint: .brown, hint: "Creations the whole family chose to share, newest first.", destination: .wallOfFame)
            }

            Text("Settings and help")
                .font(.headline)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)

            // Session 17, later still (Kade: "We also need a native way
            // to access settings like speech and whatnot. Accessability
            // low vision stuff like that."). Pronunciation Dictionary
            // moved under here too -- see SettingsView's doc comment; this
            // resolves the "still-open tabs decision" its own previous
            // doc comment had flagged.
            Button { route = .settings } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeTileLabelStyle(tint: .gray))
            .accessibilityHint("Speech, accessibility, and pronunciation dictionary settings.")

            Button { route = .help } label: {
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

            // Session 24 (leftovers item 10, the "natural big rock"): the
            // native Admin section -- usage dashboard, feedback triage, and
            // the activity-logs drill-down. Server-gated (requireAdminAccess
            // on every route); this card renders only for an ADMIN account,
            // so nobody else ever hears a section they can't use.
            if user.role == "ADMIN" {
                Text("Admin")
                    .font(.headline)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)

                Button { route = .admin } label: {
                    Label("Admin dashboard", systemImage: "chart.bar.doc.horizontal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeTileLabelStyle(tint: .red))
                .accessibilityHint("Usage and spending, feedback reports, and activity logs. Only admin accounts see this.")
            }

            Button(role: .destructive, action: auth.signOut) {
                Text("Sign out").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Signs you out and clears your saved session on this device.")
        }
    }

    /// One home Tools tile (session 25 grid). The VISIBLE title is short
    /// so tiles fit two-up; the SPOKEN label is pinned to the exact phrase
    /// the old full-width row used, so the grid change is invisible by ear.
    private func toolTile(_ title: String, spoken: String, icon: String, tint: Color, hint: String, destination: HomeRoute) -> some View {
        Button { route = destination } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(KadeCardButtonStyle())
        .labelStyle(KadeGridTileLabelStyle(tint: tint))
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
    }

    private var webButton: some View {
        VStack(spacing: 12) {
            // Session 15: help finally lives INSIDE the app. It sits above
            // the web button on purpose -- "how do I do this" should be
            // answerable without leaving for a browser, and someone looking
            // for help is exactly the person least well served by being
            // handed a web view.
            Button { route = .help } label: {
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

    private var isSignedIn: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    /// For `AgentManagerView`, which needs to filter `GET /api/agents` down
    /// to the ones SHE authored. Empty string is a safe, fail-soft default
    /// (agentBuilder's route button only exists inside `signedInSection`,
    /// so this should never actually be read while signed out) rather than
    /// an implicitly-unwrapped assumption.
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

    /// Runs whatever a Siri phrase asked for, but only once there is
    /// actually an account to run it against -- otherwise the request stays
    /// parked in `IntentRouter` and this gets called again on sign-in.
    private func handlePendingIntent() {
        guard router.pending != nil, isSignedIn else { return }
        guard let destination = router.consume() else { return }
        switch destination {
        case .spotterCall:
            // Straight into the call, no intermediate screen. This is the
            // whole point of the phrase.
            callingSpotter = true
        case .transcribe:
            route = .transcribe
        case .conversations:
            route = .conversations
        case .describe:
            route = .describe
        case .quickDictate:
            route = .quickDictate
        case .matchmaker:
            route = .matchmaker
        case .gameRoom:
            route = .gameRoom
        case .debateRoom:
            route = .debateRoom
        case .agentBuilder:
            route = .agentBuilder
        case .settings:
            route = .settings
        }
    }

    private func handleStateChange() {
        switch auth.state {
        case .signedIn:
            password = ""
            a11yFocus = .status          // "Signed in as …" gets spoken
            // Session 26 chat-first launch: the moment a session lands
            // (cold-start restore or a fresh sign-in), open the main-agent
            // chat — unless a Siri intent is already waiting (it routes
            // right after this and must win) or something is already
            // pushed. Home remains one Back away underneath.
            if route == nil && router.pending == nil {
                route = .mainChat
            }
        case .failed:
            a11yFocus = .error           // error gets spoken
        case .signedOut:
            // Cold launch with no saved session, OR just tapped "Sign out" —
            // either way land VoiceOver straight on the email field instead
            // of leaving focus dangling on a control that just disappeared.
            conversationsService.reset()   // never show the last user's list to the next signed-in session
            agentsService.reset()          // and never show a stale agent list either (Phase 4)
            voiceService.reset()           // and stop any playback / drop cached voice picks (Phase 5)
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

/// Home-screen Spotter call's post-call transcript push. Separate type from
/// `ChatTranscriptHandoff` on purpose: both live inside the SAME
/// NavigationStack, and `.navigationDestination(item:)` keys its destination
/// by TYPE across that whole stack -- two handoffs sharing one type would
/// re-create exactly the collision this pair exists to prevent. See
/// `ChatTranscriptHandoff` for the full story.
struct SpotterTranscriptHandoff: Identifiable, Hashable {
    let conversation: KadeConversation
    var id: String { conversation.conversationId }
}

/// The home screen's own programmatic destinations. Its own dedicated type,
/// declared in exactly one `navigationDestination(item:)` at the root of the
/// home stack.
///
/// The rule this obeys, and the reason it is written down here rather than
/// only in a commit message: `.navigationDestination(item:)` registers by
/// the item's TYPE for the entire enclosing `NavigationStack`, not for the
/// view it is written on. Two modifiers bound to the same type in one stack
/// means SwiftUI honours one and silently ignores the rest -- no crash, no
/// warning, just a screen that reads correctly and does nothing when you
/// activate it. That shipped once (build 121) and cost a build to find.
enum HomeRoute: Identifiable, Hashable {
    /// Session 26 (her call: "the first thing people should do when they
    /// open the app is land in a chat with an agent... What if I'm rushing
    /// and need to say something quick to my main agent?"): the launch
    /// destination — a fresh chat pointed at the main agent, pushed the
    /// moment sign-in lands. Home stays one Back away underneath it.
    case mainChat
    case transcribe
    case help
    case conversations
    case describe
    case quickDictate
    case matchmaker
    case parlor
    case gameRoom
    case debateRoom
    case agentBuilder
    case settings
    case alerts
    case myCreations
    case wallOfFame
    case admin

    var id: String {
        switch self {
        case .mainChat: return "mainChat"
        case .transcribe: return "transcribe"
        case .help: return "help"
        case .conversations: return "conversations"
        case .describe: return "describe"
        case .quickDictate: return "quickDictate"
        case .matchmaker: return "matchmaker"
        case .parlor: return "parlor"
        case .gameRoom: return "gameRoom"
        case .debateRoom: return "debateRoom"
        case .agentBuilder: return "agentBuilder"
        case .settings: return "settings"
        case .alerts: return "alerts"
        case .myCreations: return "myCreations"
        case .wallOfFame: return "wallOfFame"
        case .admin: return "admin"
        }
    }
}
