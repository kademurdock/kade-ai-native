import SwiftUI
import UIKit

// MARK: - Family history: Climb, the tree on a phone (Sep 29 2026)
//
// DESIGN 1.3. The focus person is a big card at the bottom (face or
// initials, name, years, the viewer's term, the plain chain, the side in
// words, the Research pill); their two parents are cards above it. Tap a
// parent to climb: that card becomes the focus (a spring, or a cross-fade
// when motion is not allowed). A missing parent reads "Not found yet". A
// trail of small faces at the top leads back ("You > Mom > Grandma"), and
// the children in this slice lead back down.
//
// It reads the same /tree slice as the chart. Climbing past the top of the
// slice (the server marks "more generations above") asks the screen for a
// slice centred on that person, then carries on.
//
// VoiceOver: the focus card is ONE element (the server's sentence) and opens
// the person's page; a parent card climbs, with "Open {name}" in its Actions
// rotor; after a climb the new focus is said and VoiceOver moves to it.

struct FamilyTreeClimb: View {
    let tree: FHTree
    var focus: AccessibilityFocusState<String?>.Binding
    /// Centre the slice on this person (past the loaded top, or back to
    /// someone no longer in it).
    let onNeedSlice: (FHPerson) -> Void

    static let focusKey = "climb-focus"

    @Environment(\.kadeNavigation) private var nav
    @KadeMotionPolicy private var motionAllowed: Bool
    /// Who is in focus (nil = the slice's own focus).
    @State private var target: FHPerson?
    /// The way back, first step first.
    @State private var trail: [FHPerson] = []

    private var boxes: [FHTreeBox] { tree.layout?.boxes ?? [] }
    private var edges: [FHTreeEdge] { tree.layout?.edges ?? [] }

    private var focusBox: FHTreeBox? {
        if let wanted = target?.id {
            if let exact = boxes.first(where: { $0.personId == wanted && $0.role == "focus" }) { return exact }
            return boxes.first(where: { $0.personId == wanted })
        }
        return boxes.first(where: { $0.role == "focus" }) ?? boxes.first(where: { $0.you == true })
    }

    private func boxFor(key: String) -> FHTreeBox? {
        boxes.first(where: { $0.key == key })
    }

    private func parents(of current: FHTreeBox) -> [FHTreeBox] {
        let found: [FHTreeBox] = edges.filter { $0.to == current.key }.compactMap { boxFor(key: $0.from) }
        return found.sorted { ($0.x ?? 0) < ($1.x ?? 0) }
    }

    private func children(of current: FHTreeBox) -> [FHTreeBox] {
        edges.filter { $0.from == current.key }.compactMap { boxFor(key: $0.to) }
    }

    private var move: Animation {
        motionAllowed ? Animation.spring(response: 0.35, dampingFraction: 0.85) : Animation.easeInOut(duration: 0.2)
    }

    private var cardTransition: AnyTransition {
        motionAllowed ? AnyTransition.move(edge: .top).combined(with: .opacity) : AnyTransition.opacity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !trail.isEmpty {
                trailRow
            }
            if boxes.isEmpty {
                Text("This tree has no chart to draw yet. The List shows everyone in it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let current = focusBox {
                parentsRow(current)
                focusCard(current)
                childrenRow(current)
            } else {
                FamilyLoadingLine()
                    .task(id: target?.id ?? "") {
                        if let target { onNeedSlice(target) }
                    }
            }
        }
    }

    // MARK: The way back

    private var trailRow: some View {
        let steps: [(offset: Int, element: FHPerson)] = FamilyGeometry.trimTrail(Array(trail.enumerated()), keep: 5)
        return HStack(spacing: 6) {
            ForEach(steps, id: \.offset) { step in
                FamilyFaceButton(person: step.element, size: 36, showsName: true,
                                 spoken: Self.backWords(step.element)) {
                    back(to: step.offset)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
    }

    /// "Back to your mom, Cora Example".
    static func backWords(_ person: FHPerson) -> String {
        let name: String = person.shownName
        guard let term = FamilyAccessRules.nonEmpty(person.term) else { return "Back to " + name }
        return "Back to " + term + ", " + name
    }

    // MARK: Parents above

    @ViewBuilder
    private func parentsRow(_ current: FHTreeBox) -> some View {
        let found: [FHTreeBox] = parents(of: current)
        let moreAbove: Bool = (current.moreAbove ?? 0) > 0 && tree.focus != current.personId
        if found.isEmpty && moreAbove {
            FamilyLoadingLine(text: "Loading the generation above")
                .task(id: current.key) {
                    if let person = current.person { onNeedSlice(person) }
                }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(found) { parent in
                    parentCard(parent)
                }
                if found.count < 2 {
                    FamilyClimbMissing()
                }
                if found.isEmpty {
                    FamilyClimbMissing()
                }
            }
        }
    }

    @ViewBuilder
    private func parentCard(_ parent: FHTreeBox) -> some View {
        if let person = parent.person {
            Button {
                climb(to: parent)
            } label: {
                FamilyClimbCard(person: person, big: false, you: parent.you == true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FamilyAccessRules.nonEmpty(parent.spoken) ?? person.spokenOrName)
            .accessibilityHint("Climbs up to them.")
            .accessibilityInputLabels([person.shownName, person.term ?? ""].filter { !$0.isEmpty })
            .accessibilityActions {
                Button(FamilyHeroCard.openName(person)) { openPage(person) }
            }
            .transition(cardTransition)
        }
    }

    // MARK: The focus

    @ViewBuilder
    private func focusCard(_ current: FHTreeBox) -> some View {
        if let person = current.person {
            NavigationLink(value: HomeRoute.library(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))) {
                FamilyClimbCard(person: person, big: true, you: current.you == true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FamilyAccessRules.nonEmpty(current.spoken) ?? person.spokenOrName)
            .accessibilityHint("Opens their page.")
            .accessibilityInputLabels([person.shownName, person.term ?? ""].filter { !$0.isEmpty })
            .accessibilityFocused(focus, equals: Self.focusKey)
            .id(person.id)
            .transition(cardTransition)
        }
    }

    // MARK: Back down

    @ViewBuilder
    private func childrenRow(_ current: FHTreeBox) -> some View {
        let kids: [FHTreeBox] = children(of: current)
        if !kids.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FamilyHeading(text: "Children", level: .h3)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(kids) { kid in
                            childButton(kid)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func childButton(_ kid: FHTreeBox) -> some View {
        if let person = kid.person {
            FamilyFaceButton(person: person, size: 52, showsName: true,
                             spoken: FamilyAccessRules.nonEmpty(kid.spoken) ?? person.spokenOrName) {
                goDown(to: person)
            }
            .accessibilityHint("Moves down to them.")
        }
    }

    // MARK: Moving

    private func climb(to parent: FHTreeBox) {
        guard let current = focusBox?.person, let next = parent.person else { return }
        withAnimation(move) {
            trail.append(current)
            target = next
        }
        arrive(FamilyAccessRules.nonEmpty(parent.spoken) ?? next.spokenOrName)
    }

    private func goDown(to person: FHPerson) {
        guard let current = focusBox?.person else { return }
        withAnimation(move) {
            if let last = trail.last, last.id == person.id {
                trail.removeLast()
            } else {
                trail.append(current)
            }
            target = person
        }
        arrive(person.spokenOrName)
    }

    private func back(to index: Int) {
        guard index >= 0, index < trail.count else { return }
        let person: FHPerson = trail[index]
        withAnimation(move) {
            trail = Array(trail.prefix(index))
            target = person
        }
        arrive(person.spokenOrName)
    }

    /// Says who is in focus now, then moves VoiceOver to their card.
    private func arrive(_ words: String) {
        FamilyAnnounce.say(words)
        let binding = focus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            binding.wrappedValue = Self.focusKey
        }
    }

    private func openPage(_ person: FHPerson) {
        nav.pushLibrary(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))
    }
}

// MARK: - A card

/// One person on the climb: face or initials, name, years, term, the chain
/// (big card only), the side in words and the Research pill. The research
/// outline is dotted; the viewer's own card has a thick border.
struct FamilyClimbCard: View {
    let person: FHPerson
    var big: Bool = false
    var you: Bool = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @KadeContrastPolicy private var highContrast: Bool

    private var faceSize: CGFloat { big ? 96 : 64 }

    var body: some View {
        let tint: Color = FamilySideColor.color(person.sideKind, contrast: highContrast)
        let width: CGFloat = you ? 3 : (highContrast ? 2 : 1)
        let dash: [CGFloat] = person.research != nil ? [5, 3] : []
        Group {
            if big && !typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 14) {
                    face
                    words
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    face
                    words
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tint.opacity(0.85), style: StrokeStyle(lineWidth: width, dash: dash)))
        .contentShape(Rectangle())
    }

    private var face: some View {
        FamilyPhoto(image: person.face, size: .f, drawn: faceSize,
                    initials: person.initials ?? "", side: person.sideKind, circle: true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(person.shownName)
                .font(big ? Font.title3.bold() : Font.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let years = person.years ?? person.lifespan {
                Text(years).font(.subheadline).foregroundStyle(.secondary)
            }
            if let term = person.term {
                Text(term).font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            if big, let chain = person.chain {
                Text(chain).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            FamilyPersonSideLine(person: person)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The side in words (its colour only a second cue), and the Research pill
/// with its proof words.
struct FamilyPersonSideLine: View {
    let person: FHPerson
    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        let tint: Color = FamilySideColor.color(person.sideKind, contrast: highContrast)
        VStack(alignment: .leading, spacing: 4) {
            if let side = FamilyAccessRules.nonEmpty(person.sideText) {
                Text(side)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            if let research = person.research {
                FamilyResearchPill()
                if let proof = FamilyAccessRules.nonEmpty(research.text) {
                    Text(proof)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A parent nobody has found yet: drawn as a dashed empty card, never a
/// silhouette.
struct FamilyClimbMissing: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark")
                .font(.title2)
            Text("Not found yet")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Parent not found yet")
    }
}
