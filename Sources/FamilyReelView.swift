import SwiftUI
import UIKit

// MARK: - Family history: "Your family in 60 seconds" (Sep 29 2026)
//
// DESIGN 1.2 item 2: 6 to 8 cards the server builds (you; your
// grandparents; the oldest known ancestor; the ocean crossing; a mystery
// solved; where most of them lived; "Explore your tree"), each one big
// picture and one sentence. It never plays by itself.
// - Sight: swipeable pages, with Previous and Next buttons and "2 of 7".
// - VoiceOver: a plain list of the same cards, each ONE element (its
//   sentence); a card that leads somewhere opens it on double tap.
// The cards come from /home (usually already here from Home).

struct FamilyReelView: View {
    let apiClient: KadeAPIClient

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var reel: FHReel?
    @State private var failure: String?
    @State private var index = 0

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _reel = State(initialValue: FamilyHistoryService.shared.cachedHome()?.reel)
    }

    private var title: String {
        FamilyAccessRules.nonEmpty(reel?.title) ?? "Your family in 60 seconds"
    }

    private var cards: [FHReelCard] { reel?.cards ?? [] }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !cards.isEmpty {
            if voiceOverOn {
                list
            } else {
                pages
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FamilyHeading(text: title, level: .h1, focusOnArrival: true)
                    waiting
                }
                .padding()
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var waiting: some View {
        if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else if reel != nil {
            Text("There are no cards to show yet.")
                .foregroundStyle(.secondary)
        } else {
            FamilyLoadingLine()
        }
    }

    // MARK: VoiceOver: a list

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FamilyHeading(text: title, level: .h1, focusOnArrival: true)
                ForEach(Array(cards.enumerated()), id: \.offset) { pair in
                    FamilyReelListCard(card: pair.element)
                }
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Sight: pages

    private var pages: some View {
        VStack(spacing: 12) {
            FamilyHeading(text: title, level: .h1, focusOnArrival: true)
                .padding(.horizontal)
            TabView(selection: $index) {
                ForEach(Array(cards.enumerated()), id: \.offset) { pair in
                    FamilyReelPage(card: pair.element)
                        .padding(.horizontal)
                        .tag(pair.offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            controls
        }
        .padding(.vertical)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack {
            Button("Previous") { step(-1) }
                .disabled(index <= 0)
                .accessibilityLabel("Previous card")
            Spacer()
            Text("\(min(index + 1, cards.count)) of \(cards.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Next") { step(1) }
                .disabled(index >= cards.count - 1)
                .accessibilityLabel("Next card")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
    }

    private func step(_ by: Int) {
        let target: Int = min(max(0, index + by), max(0, cards.count - 1))
        let move: Animation? = motionAllowed ? Animation.easeInOut(duration: 0.3) : nil
        withAnimation(move) {
            index = target
        }
    }

    // MARK: Loading

    @MainActor
    private func load(force: Bool = false) async {
        if !force, !cards.isEmpty { return }
        do {
            let home = try await FamilyHistoryService.shared.home(since: FamilyMemory.string(FamilyMemory.seenVersion))
            reel = home.reel ?? FHReel()
            failure = nil
        } catch {
            if LibraryLoad.cancelled(error) { return }
            failure = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
        }
    }
}

// MARK: - One card

/// A card's big picture: its photo, else its people's faces, else a symbol.
struct FamilyReelPicture: View {
    let card: FHReelCard
    let height: CGFloat

    var body: some View {
        if let first = card.images.first {
            FamilyWidePhoto(image: first, size: .s, height: height, longSide: 700)
        } else if card.people.count > 1 {
            FamilyReelFaces(people: Array(card.people.prefix(4)))
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else if let person = card.people.first {
            FamilyPhoto(image: person.face, size: .f, drawn: min(height, 180),
                        initials: person.initials ?? "", side: person.sideKind, circle: true)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            Image(systemName: FamilyReelPicture.symbol(card.key))
                .font(.system(size: 64))
                .foregroundStyle(.brown)
                .frame(maxWidth: .infinity)
                .frame(height: height * 0.6)
                .accessibilityHidden(true)
        }
    }

    static func symbol(_ key: String) -> String {
        switch key {
        case "places": return "map"
        case "ocean": return "sailboat"
        case "mystery": return "magnifyingglass"
        case "end": return "tree"
        default: return "person.3"
        }
    }
}

/// Up to four faces, two by two, each with a first name (grandparents).
struct FamilyReelFaces: View {
    let people: [FHPerson]

    var body: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                ForEach(Array(people.prefix(2))) { person in
                    face(person)
                }
            }
            if people.count > 2 {
                GridRow {
                    ForEach(Array(people.dropFirst(2).prefix(2))) { person in
                        face(person)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func face(_ person: FHPerson) -> some View {
        VStack(spacing: 4) {
            FamilyPhoto(image: person.face, size: .f, drawn: 88,
                        initials: person.initials ?? "", side: person.sideKind, circle: true)
            Text(FamilyAccessRules.nonEmpty(person.first) ?? person.shownName)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

/// One page for sight: the picture, then the sentence; the whole page opens
/// where the card leads.
struct FamilyReelPage: View {
    let card: FHReelCard

    var body: some View {
        if let route = card.open?.route {
            NavigationLink(value: HomeRoute.library(.family(route))) {
                page
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
        } else {
            page
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private var spoken: String { FamilyAccessRules.nonEmpty(card.spoken) ?? card.text ?? "" }

    private var page: some View {
        VStack(spacing: 18) {
            FamilyReelPicture(card: card, height: 280)
            Text(card.text ?? "")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
        .contentShape(Rectangle())
    }
}

/// One card in the VoiceOver list: ONE element, its sentence.
struct FamilyReelListCard: View {
    let card: FHReelCard

    private var spoken: String { FamilyAccessRules.nonEmpty(card.spoken) ?? card.text ?? "" }

    var body: some View {
        if let route = card.open?.route {
            NavigationLink(value: HomeRoute.library(.family(route))) {
                words
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .familyCard()
        } else {
            words
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .familyCard()
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyReelPicture(card: card, height: 160)
            Text(card.text ?? "")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
