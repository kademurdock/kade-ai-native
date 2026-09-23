import SwiftUI

/// Sep 23 2026 — THE TAB BAR (redesign A1). Kade, approving the whole
/// redesign: "not as a trial, but as a real run."
///
/// Session 18 chose grouped sections over bottom tabs when Home had 13
/// buttons. By build 311 Home had 23 (24 for an admin) and sat two Backs
/// behind the chat the app opens into, under a title that said "Kade-AI"
/// rather than Home, so a newcomer never found it. Five tabs put every place
/// one tap from anywhere, and VoiceOver reads each as "Library, tab, 2 of 5".
///
/// Her standing rules ride along unchanged: Spotter is the first thing on the
/// first tab; the app still opens into a chat with the main character; Back
/// from any chat still lands on the conversation list.
enum KadeTab: String, CaseIterable, Hashable {
    case talk, library, create, play, more

    var title: String {
        switch self {
        case .talk: return "Talk"
        case .library: return "Library"
        case .create: return "Create"
        case .play: return "Play"
        case .more: return "More"
        }
    }

    var systemImage: String {
        switch self {
        case .talk: return "bubble.left.and.bubble.right.fill"
        case .library: return "books.vertical.fill"
        case .create: return "wand.and.stars"
        case .play: return "gamecontroller.fill"
        case .more: return "ellipsis.circle.fill"
        }
    }
}

/// What a screen deep inside a tab can ask the app root to do, without owning
/// any navigation path itself. The root fills these in; the defaults do
/// nothing, so a screen shown somewhere without the root (a preview, a sheet)
/// fails soft instead of crashing.
struct KadeNavigation {
    /// Open a saved conversation on the Talk tab, over the conversation list.
    var openConversation: (KadeConversation) -> Void = { _ in }
    /// Start a fresh chat on the Talk tab. `nil` = the main character.
    var startChat: (String?) -> Void = { _ in }
    /// Go to any screen the app has a route for (switches tab if needed).
    var open: (HomeRoute) -> Void = { _ in }
    /// Switch tabs, keeping each tab's place.
    var select: (KadeTab) -> Void = { _ in }
    /// Straight into a Spotter call.
    var callSpotter: () -> Void = {}
    /// Open one Library item by id on the Library tab.
    var openLibraryItem: (String) -> Void = { _ in }
}

private struct KadeNavigationKey: EnvironmentKey {
    static let defaultValue = KadeNavigation()
}

extension EnvironmentValues {
    var kadeNavigation: KadeNavigation {
        get { self[KadeNavigationKey.self] }
        set { self[KadeNavigationKey.self] = newValue }
    }
}
