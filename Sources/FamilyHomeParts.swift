import SwiftUI
import UIKit

// MARK: - Family history: Home's cards (Sep 29 2026)
//
// DESIGN 1.2, top to bottom: the hero (about the viewer, with 5 to 7 faces on
// a gentle arc, or one large portrait), "Your family in 60 seconds", the
// featured card (On this day, the ancestor of the week, a story), "New since
// your last visit", four big tiles, More, and the footnote. Every word is the
// server's (/home); these only draw them.
//
// VoiceOver: the hero is ONE element (the server's sentence); double tap opens
// the tree, and its Actions rotor opens each face's person and plays the
// reel. The face buttons stay real buttons for sight, Voice Control ("Tap
// Ada") and Switch Control, hidden only while VoiceOver runs. The featured
// cards are a plain list under VoiceOver, one card at a time for sight.

// MARK: - The hero

struct FamilyHeroCard: View {
    let hero: FHHero
    let faces: FHFaces?
    let reelTitle: String?

    @Environment(\.kadeNavigation) private var nav
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            words
            pictures
        }
        .familyCard()
    }

    private var treeRoute: FamilyRoute {
        hero.open?.route ?? .tree(focus: nil, name: "")
    }

    /// The row of faces (none when the server chose one portrait instead).
    private var people: [FHPerson] {
        guard let faces, faces.layout != "portrait" else { return [] }
        return faces.people
    }

    private var spoken: String {
        if let said = FamilyAccessRules.nonEmpty(hero.spoken) { return said }
        let parts: [String] = [hero.hello, hero.headline, hero.youAre, hero.stats, hero.follows].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    private var words: some View {
        NavigationLink(value: HomeRoute.library(.family(treeRoute))) {
            FamilyHeroWords(hero: hero)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens the family tree.")
        .accessibilityActions {
            ForEach(people) { person in
                Button(Self.openName(person)) { openPerson(person) }
            }
            if let reelTitle = FamilyAccessRules.nonEmpty(reelTitle) {
                Button("Play " + Self.lowerFirst(reelTitle)) {
                    nav.pushLibrary(.family(.reel))
                }
            }
        }
    }

    @ViewBuilder
    private var pictures: some View {
        if let portrait = faces?.portrait, people.isEmpty {
            FamilyHeroPortrait(portrait: portrait)
        } else if !people.isEmpty {
            FamilyFaceArc(people: people) { person in openPerson(person) }
                .accessibilityHidden(voiceOverOn)
        }
    }

    private func openPerson(_ person: FHPerson) {
        nav.pushLibrary(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))
    }

    /// "Open your grandfather, Dan Example".
    static func openName(_ person: FHPerson) -> String {
        let name: String = person.shownName
        guard let term = FamilyAccessRules.nonEmpty(person.term) else { return "Open " + name }
        return name.isEmpty ? "Open " + term : "Open " + term + ", " + name
    }

    /// "Your family in 60 seconds" -> "your family in 60 seconds".
    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).lowercased() + text.dropFirst()
    }
}

/// The hero's words, for sight.
struct FamilyHeroWords: View {
    let hero: FHHero

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hello = hero.hello {
                Text(hello).font(.title3).foregroundStyle(.secondary)
            }
            if let headline = hero.headline {
                Text(headline)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let youAre = hero.youAre {
                Text(youAre).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            if let stats = hero.stats {
                Text(stats).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let follows = hero.follows {
                Text(follows).font(.subheadline.italic()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Fewer than four photographed faces: one large portrait and its caption.
struct FamilyHeroPortrait: View {
    let portrait: FHPortrait

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyWidePhoto(image: portrait.image, size: .s, height: 240, longSide: 620)
            if let caption = portrait.caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(portrait.caption ?? portrait.image?.label ?? "")
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Faces on a gentle arc

/// 5 to 7 faces (4 at accessibility text sizes), the middle ones highest,
/// each a button to that person. They fade in once, 60 ms apart, only while
/// motion is allowed.
struct FamilyFaceArc: View {
    let people: [FHPerson]
    let onOpen: (FHPerson) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var shown = false

    /// The name line under each face.
    private let captionHeight: CGFloat = 18

    private var shownPeople: [FHPerson] {
        Array(people.prefix(typeSize.isAccessibilitySize ? 4 : 7))
    }

    private var regularSize: CGFloat { sizeClass == .regular ? 72 : 64 }

    var body: some View {
        GeometryReader { geo in
            arc(width: geo.size.width)
        }
        .frame(height: regularSize * 1.5 + captionHeight + 6)
        .task { shown = true }
    }

    private func arc(width: CGFloat) -> some View {
        let size: CGFloat = width < 340 ? 56 : regularSize
        let list: [FHPerson] = shownPeople
        let points: [FHPoint] = FamilyGeometry.faceArc(count: list.count, width: Double(width),
                                                       height: Double(size * 1.5), face: Double(size))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(list.enumerated()), id: \.offset) { pair in
                face(pair.element, index: pair.offset, size: size, points: points)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    @ViewBuilder
    private func face(_ person: FHPerson, index: Int, size: CGFloat, points: [FHPoint]) -> some View {
        if index < points.count {
            let x: CGFloat = CGFloat(points[index].x)
            let y: CGFloat = CGFloat(points[index].y) + (captionHeight + 4) / 2
            let fade: Animation? = motionAllowed ? Animation.easeOut(duration: 0.45).delay(0.06 * Double(index)) : nil
            FamilyFaceButton(person: person, size: size) { onOpen(person) }
                .opacity(shown || !motionAllowed ? 1 : 0)
                .animation(fade, value: shown)
                .position(x: x, y: y)
        }
    }
}

// MARK: - "Your family in 60 seconds"

struct FamilyReelCard: View {
    let reel: FHReel

    private var title: String { FamilyAccessRules.nonEmpty(reel.title) ?? "Your family in 60 seconds" }

    private var spoken: String {
        guard let detail = FamilyAccessRules.nonEmpty(reel.visibleDetail) else { return title }
        return title + ", " + detail
    }

    var body: some View {
        NavigationLink(value: HomeRoute.library(.family(.reel))) {
            VStack(alignment: .leading, spacing: 10) {
                if let cover = reel.cover {
                    FamilyWidePhoto(image: cover, size: .s, height: 170, longSide: 680, fill: true)
                }
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.brown)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title3.bold()).foregroundStyle(.primary)
                        if let detail = reel.visibleDetail {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens the cards, one at a time.")
        .accessibilityInputLabels([title])
        .familyCard()
    }
}
