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
    static let title = "What's new: Open voices, and Clean up or change, in the Sound Booth"
    static let body = "The Sound Booth has Open voices. Design a voice from a description, or speak with a voice you saved or a clip you bring in, using VoxCPM2 or Ming. Ming has its own controls: a built-in voice, emotion, speed, pitch, volume, language and sound tags. Keep the takes you like as saved voices; every take is also in My Creations. The booth can also clean up or change a recording: pick what to do, and it shows only the choices that job uses."

    /// 2.2.21's words, kept for Help's "In 2.2.21" entry.
    static let body2221 = "VoiceOver no longer stays turned down after the app plays a sound, a voice or a film: when the app goes quiet it lets the sound go, so VoiceOver comes back to its own volume. " + followAlongNews

    /// Nov 14 2026 (Tellavision Follow along): the release words for the
    /// build that carries it. Help's What's new shows them only where Follow
    /// along is offered (it starts with the administrator alone). 2.2.21:
    /// the server offers it to everyone, so `body` carries these words.
    static let followAlongNews = "New: Follow along with my TV. On a finished described video, your phone listens to the same film playing on your TV, finds your place, and speaks the descriptions in the gaps, in your VoiceOver voice. Pause the TV and it waits; skip and it finds the new place. A soft chime means a line did not fit: pause the TV to hear it. The film's sound is checked on your phone and never saved or sent."

    private let seenKey = "kade.whatsNew.seenVersion"
    @Published private(set) var showCard = false

    /// What "seen" means: this version AND these words. Sep 27 2026: 2.2.1
    /// reached TestFlight twice (build 317, then the Library build), so a
    /// card keyed on the version alone never showed the second build's news
    /// to anyone who had put the first one away. New words show once more;
    /// the same words never do.
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "\(short) \(Self.title)"
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
