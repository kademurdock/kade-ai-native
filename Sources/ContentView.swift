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
                    if !isSignedIn {
                        Text("Sign in to chat with your Kade-AI companions. For games, Spotter, and everything else, use \"Open Kade-AI web\" below.")
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

                    webButton

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
        }
        .onChange(of: authStateID) { _, _ in handleStateChange() }
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

            NavigationLink {
                ConversationListView()
            } label: {
                Label("Your conversations", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens your conversation list.")

            Button(role: .destructive, action: auth.signOut) {
                Text("Sign out").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Signs you out and clears your saved session on this device.")
        }
    }

    private var webButton: some View {
        Button { showingWeb = true } label: {
            Label("Open Kade-AI web", systemImage: "safari")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Opens the full Kade-AI web app in a browser inside this app.")
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

    private func handleStateChange() {
        switch auth.state {
        case .signedIn:
            password = ""
            a11yFocus = .status          // "Signed in as …" gets spoken
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
        .environmentObject(AuthService(client: client))
        .environmentObject(ConversationsService(client: client))
        .environmentObject(AgentsService(client: client))
        .environmentObject(VoiceService(client: client))
}
