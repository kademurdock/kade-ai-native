import SwiftUI
import SafariServices

/// Phase 0 hello-world screen.
/// Accessibility notes:
/// - Title is a real VoiceOver heading (rotor "Headings" lands on it).
/// - Status line is one combined element so VoiceOver reads it in a single swipe.
/// - The web button is a plain Button with a clear label; it opens the full
///   Kade-AI web app in an in-app Safari sheet.
struct ContentView: View {
    @State private var showingWeb = false

    private var buildString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v), build \(b)"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Kade-AI Native")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                Text("Hello, Keighty. This is the native core app. Chat, voice, and notifications will live here; everything else stays on the web app.")
                    .font(.body)

                // Screen-reader-checkable status/debug line.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.headline)
                    Text("\(buildString) · not signed in")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Button {
                    showingWeb = true
                } label: {
                    Label("Open Kade-AI web", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens the full Kade-AI web app in a browser inside this app.")

                Spacer()
            }
            .padding()
            .navigationTitle("Kade-AI")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingWeb) {
                SafariView(url: URL(string: "https://kademurdock.com")!)
                    .ignoresSafeArea()
            }
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

#Preview { ContentView() }
