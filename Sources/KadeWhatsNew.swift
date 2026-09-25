import SwiftUI

/// Sep 23 2026 redesign (B12). A "What's new" card that shows ONCE after an
/// update, at the top of the Talk tab, in plain words, with a way to hear more
/// (Help's What's new section) and a way to put it away.
///
/// Who sees it: people updating from an older build. A brand-new install has
/// never seen the old app, so "what's new" would mean nothing to them; the test
/// is whether this device already holds any of the app's saved settings
/// (only real, persisted values count, never registered defaults).
@MainActor
final class KadeWhatsNew: ObservableObject {
    static let shared = KadeWhatsNew()

    /// Rewrite these with every release that changes something people will
    /// notice, and keep Help's "What's new" entry saying the same thing.
    static let title = "What's new: pictures, and your own narrator"
    static let body = "The app has painted pictures now. With VoiceOver, a screen's picture is described after everything else on it, Help reads them all under What the app looks like, and Settings can skip them. Described videos keep your favourite narrators on your account and keep playing outside the app, and Library actions are in the Actions rotor."

    private let seenKey = "kade.whatsNew.seenVersion"
    @Published private(set) var showCard = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private init() {
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: seenKey)
        if seen == version { return }
        if seen == nil {
            let persisted = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
            let updating = persisted.keys.contains { $0.hasPrefix("kade") && $0 != seenKey }
            guard updating else {
                // First install: remember this version so the card waits for
                // the NEXT update instead.
                defaults.set(version, forKey: seenKey)
                return
            }
        }
        showCard = true
    }

    func dismiss() {
        UserDefaults.standard.set(version, forKey: seenKey)
        showCard = false
    }
}

/// The card itself. A heading, the words, and two sibling buttons — never
/// combined into one element (the Amber rule).
struct KadeWhatsNewCard: View {
    @ObservedObject private var whatsNew = KadeWhatsNew.shared
    @Environment(\.kadeNavigation) private var nav

    var body: some View {
        if whatsNew.showCard {
            VStack(alignment: .leading, spacing: 10) {
                // Part 292: the house at dusk, silent here (the card sits on
                // the busiest screen); Help's "What the app looks like" and
                // the sign-in screen carry the words.
                KadePaintedHeader(imageName: "ArtHouseAtDusk", symbol: "house.fill", tint: .indigo, height: 90)
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(KadeWhatsNew.title)
                        .font(.headline)
                        // Wraps at large text sizes instead of cutting off.
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(KadeWhatsNew.body)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        whatsNew.dismiss()
                        nav.open(.help)
                    } label: {
                        Text("Tell me more")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens Help, where the newest changes are at the top.")
                    Button {
                        whatsNew.dismiss()
                        UIAccessibility.post(notification: .announcement, argument: "Put away. Help keeps the list of what's new.")
                    } label: {
                        Text("Got it")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Puts this card away. It won't show again until the next update.")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kadeGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
