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
    @State private var showingWeb = false
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
                    // Deliberately not marked .isHeader: the nav bar's own
                    // "Kade-AI" title already reads as the screen's heading,
                    // and a second heading right after it (this used to say
                    // "Kade-AI Native" -- internal build-track jargon a
                    // tester has no reason to know) was confusing on a real
                    // VoiceOver pass (Kade, TestFlight build 105, July 19
                    // 2026: landed on "Kade-AI" then immediately another
                    // heading "Kade-AI Native"). Kept as a plain welcoming
                    // line instead of removing it outright, since sighted
                    // testers still benefit from a real hero title.
                    Text("Welcome to Kade-AI")
                        .font(.largeTitle.bold())

                    // Same pass flagged this: "native app" / "web app" as if
                    // they're two separate products is an internal framing
                    // (this app vs. the Capacitor shell / kademurdock.com)
                    // that means nothing to a tester who just has one app
                    // called Kade-AI. Rewritten to describe what's HERE and
                    // point at the actual button for what's not, instead of
                    // narrating the rollout plan.
                    Text("Sign in to chat with your Kade-AI companions. For games, Spotter, and everything else, use \"Open Kade-AI web\" below.")
                        .font(.body)

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
                SafariView(url: URL(string: "https://kademurdock.com")!)
                    .ignoresSafeArea()
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
            Text("Signed in as \(user.displayName)")
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
            a11yFocus = .email
        default:
            break
        }
    }
}

/// SFSafariViewController wrapper — the "escape hatch" to the full web app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

#Preview {
    let client = KadeAPIClient()
    return ContentView()
        .environmentObject(AuthService(client: client))
        .environmentObject(ConversationsService(client: client))
        .environmentObject(AgentsService(client: client))
}
