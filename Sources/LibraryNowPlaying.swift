import SwiftUI

/// Sep 23 2026 redesign (A2) — the app-level home of the Library player, so a
/// book keeps playing while you move around the app.
///
/// THIS IS THE CONTRACT STUB the root (ContentView) is written against. The
/// Library work replaces the bodies; the names and signatures below are what
/// the root calls and must keep compiling:
///   - `LibraryNowPlaying.shared`
///   - `bind(client:voice:)`          root, once signed in
///   - `stop()`                       root, on sign-out
///   - `showPlayerRequest`            root bumps it; the Library tab shows the player
///   - `openItemRequest`              root sets an item id (search); the Library tab opens it
///   - `NowPlayingBar(openPlayer:)`   root places it above the tab bar; renders
///                                    nothing when no book or recording is open
@MainActor
final class LibraryNowPlaying: ObservableObject {
    static let shared = LibraryNowPlaying()

    /// Bumped by the root to ask the Library tab to show the player screen.
    @Published var showPlayerRequest = 0
    /// A Library item id the root wants opened on the Library tab.
    @Published var openItemRequest: String?

    func bind(client: KadeAPIClient, voice: VoiceService) {}

    /// Closes the player completely (sign-out).
    func stop() {}
}

/// The mini player above the tab bar. Stub: draws nothing.
struct NowPlayingBar: View {
    var openPlayer: () -> Void

    var body: some View {
        EmptyView()
    }
}
