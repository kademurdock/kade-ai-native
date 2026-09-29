import SwiftUI
import UIKit

// MARK: - Family history: where each route goes (Sep 29 2026)
//
// Family screens live inside the Library tab's stack, pushed as
// `HomeRoute.library(.family(...))`: no new HomeRoute and no new
// navigationDestination (the build-121 rule: each stack registers HomeRoute
// once). From another tab: `nav.pushLibrary(.family(...))`.
//
// Every route is gated here. An account that may not open the family history
// (or whose answer is not in yet) meets FamilyLockedView, with the server's
// reason and Ask to be added, never a blank screen; that covers deep links,
// Search hits and Help's "Where is". If access is lost while a family screen
// is open, the screen turns into the locked view at once.

struct FamilyDestination: View {
    let route: FamilyRoute
    let apiClient: KadeAPIClient
    @ObservedObject private var access = FamilyHistoryAccess.shared

    init(route: FamilyRoute, apiClient: KadeAPIClient) {
        self.route = route
        self.apiClient = apiClient
        FamilyHistoryService.shared.bind(client: apiClient)
    }

    var body: some View {
        if route.needsAccess && access.isOpen {
            screen
        } else {
            FamilyLockedView(apiClient: apiClient)
        }
    }

    /// One initialiser per route, no inline bodies (type-checking stays cheap).
    @ViewBuilder
    private var screen: some View {
        switch route {
        case .home:
            FamilyHomeView(apiClient: apiClient)
        case .reel:
            FamilyReelView(apiClient: apiClient)
        case .tree(let focus, let name):
            FamilyTreeScreen(apiClient: apiClient, focus: focus, name: name)
        case .person(let person):
            FamilyPersonScreen(apiClient: apiClient, route: person)
        case .gallery(let gallery):
            FamilyGalleryScreen(apiClient: apiClient, route: gallery)
        case .whereWhen(let map):
            FamilyTimelineScreen(apiClient: apiClient, map: map)
        case .dna(let forId):
            FamilyDNAScreen(apiClient: apiClient, forId: forId)
        case .stories:
            FamilyListScreen(apiClient: apiClient, mode: .stories)
        case .story(let slug, let title):
            FamilyStoryScreen(apiClient: apiClient, slug: slug, title: title)
        case .discoveries:
            FamilyListScreen(apiClient: apiClient, mode: .discoveries)
        case .mysteries:
            FamilyListScreen(apiClient: apiClient, mode: .mysteries)
        case .people:
            FamilyListScreen(apiClient: apiClient, mode: .people)
        case .play:
            FamilyPlayScreen(apiClient: apiClient)
        case .locked:
            FamilyLockedView(apiClient: apiClient)
        }
    }
}

// MARK: - Closed to this account

/// Why this account cannot open the family history, in the server's words,
/// with Ask to be added for an unmatched account ("Asked on {date}" after).
/// While the answer is not in yet it says "Checking" and asks; if the site
/// cannot be reached, Try again is focused and announced.
struct FamilyLockedView: View {
    let apiClient: KadeAPIClient
    @ObservedObject private var access = FamilyHistoryAccess.shared
    @State private var said: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FamilyHeading(text: "Family history", level: .h1, focusOnArrival: true)
                content
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Family history")
        .navigationBarTitleDisplayMode(.inline)
        .task { await access.check(client: apiClient) }
        .refreshable { await access.check(client: apiClient, force: true) }
    }

    @ViewBuilder
    private var content: some View {
        switch access.state {
        case .unknown:
            checking
        case .open:
            openNote
        case .locked, .unavailable:
            reason
        }
    }

    @ViewBuilder
    private var checking: some View {
        if access.checkFailed {
            FamilyTryAgain(message: "Could not reach the family history.") {
                Task { await access.check(client: apiClient, force: true) }
            }
        } else {
            FamilyLoadingLine(text: "Checking")
        }
    }

    /// The locked route opened by an account that may open it after all.
    private var openNote: some View {
        NavigationLink(value: HomeRoute.library(.family(.home))) {
            Text("Open Family history")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Your account can open it.")
    }

    private var reason: some View {
        let words: FamilyRowWords = access.words
        return VStack(alignment: .leading, spacing: 12) {
            Text(words.detail)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !words.hint.isEmpty {
                Text(words.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            askArea(words.ask)
            if let said {
                Text(said)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func askArea(_ ask: FamilyAskState) -> some View {
        switch ask {
        case .hidden:
            EmptyView()
        case .ask:
            Button {
                Task { await askNow() }
            } label: {
                Text(access.asking ? "Asking…" : "Ask to be added")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(access.asking)
            .accessibilityHint("Sends the tree's owner a request to match your account.")
        case .asked(let when):
            Text(when)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func askNow() async {
        let words = await access.ask()
        guard !words.isEmpty else { return }
        said = words
        KadeAnnounce.high(words)
    }
}

// MARK: - Search everything

/// The "Family history" hit in Search everything: live for the family, and
/// for everyone else dimmed with the same reason as the Library row. It
/// still opens (the locked view says why, and offers Ask to be added).
struct FamilySearchRow: View {
    let place: KadeSearchPlace
    @Environment(\.kadeNavigation) private var nav
    @ObservedObject private var access = FamilyHistoryAccess.shared

    var body: some View {
        let words: FamilyRowWords = access.words
        let caption: String = words.enabled ? place.caption : words.detail
        Button {
            nav.open(place.route)
        } label: {
            Label(place.title, systemImage: place.symbol)
        }
        .buttonStyle(.plain)
        .labelStyle(KadeRowLabelStyle(tint: words.enabled ? place.tint : .gray, caption: caption))
        .accessibilityLabel("\(place.title). \(caption)")
        .accessibilityHint(words.enabled ? "Takes you there." : "Says why it is closed to your account.")
        .accessibilityInputLabels([place.title])
    }
}
