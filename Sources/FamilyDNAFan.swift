import SwiftUI
import UIKit

// MARK: - Family history: where your DNA comes from, on paper (Sep 29 2026)
//
// DESIGN 1.7, section 5. It opens at the grandparents: four quarters with
// four big faces. A generation stepper goes from the parents out to the 6th
// great-grandparents (1 to 7), and the server's words say how many have a
// name ("14 of your 32 3rd great-grandparents have a name"), with its note
// that these are averages. Research slots are striped and labelled, unknown
// slots are an empty dashed outline, and a half-tree viewer sees only the
// side the tree follows, as a half fan. Colour is never the only cue: the
// legend and the list say the same in words.
//
// VoiceOver: the fan is ONE adjustable element. Its label is the section's
// title, its value the server's "Generation 2, grandparents: 4 of 4 known";
// swipe up or down for the next or previous generation (the visible stepper
// is hidden while VoiceOver runs, never from Voice Control). The Actions
// rotor opens each named person in the generation (up to 16). Under the fan,
// the ancestors of that generation, 32 at a time: "{term}, {name}, ... On
// average 1 in 32."

struct FamilyPaperSection: View {
    let paper: FHPaper

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.kadeNavigation) private var nav
    @State private var chosen: Int?
    @State private var page = 0
    @AccessibilityFocusState private var focusKey: String?

    private let pageSize = 32

    private var generations: [FHGeneration] {
        paper.generations.filter { !$0.wedges.isEmpty }
    }

    /// Where it opens: the grandparents (the server's startGen).
    private var startIndex: Int {
        let start: Int = paper.startGen ?? 2
        return generations.firstIndex(where: { $0.gen == start }) ?? 0
    }

    private var current: Int {
        min(max(0, chosen ?? startIndex), max(0, generations.count - 1))
    }

    private var title: String {
        FamilyAccessRules.nonEmpty(paper.title) ?? "Where your DNA comes from, on paper"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FamilyHeading(text: title, level: .h2)
            if generations.indices.contains(current) {
                generationBlock(generations[current])
            }
            if let note = FamilyAccessRules.nonEmpty(paper.note) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func generationBlock(_ gen: FHGeneration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            fanElement(gen)
            stepper(gen)
                .accessibilityHidden(voiceOverOn)
            if let text = FamilyAccessRules.nonEmpty(gen.text) {
                Text(text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FamilyFanLegend(hasResearch: gen.wedges.contains { $0.isResearch })
            ancestorList(gen)
        }
    }

    // MARK: The fan

    private func fanElement(_ gen: FHGeneration) -> some View {
        ZStack {
            FamilyFanDrawing(generation: gen, half: paper.half == true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(Self.value(gen))
                .accessibilityHint("Swipe up or down for another generation.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
                .accessibilityActions {
                    ForEach(Self.named(gen).prefix(16)) { person in
                        Button(FamilyHeroCard.openName(person)) { open(person) }
                    }
                }
            FamilyFanFaceButtons(generation: gen, half: paper.half == true) { person in open(person) }
                .accessibilityHidden(voiceOverOn)
        }
        .accessibilityIgnoresInvertColors(true)
    }

    /// "Generation 2, grandparents: 4 of 4 known".
    static func value(_ gen: FHGeneration) -> String {
        if let said = FamilyAccessRules.nonEmpty(gen.spoken) { return said }
        let named: Int = gen.named ?? gen.wedges.filter { $0.isNamed }.count
        let slots: Int = gen.slots ?? gen.wedges.count
        return "Generation \(gen.gen ?? 0): \(named) of \(slots) known"
    }

    static func named(_ gen: FHGeneration) -> [FHPerson] {
        gen.wedges.compactMap { (wedge: FHWedge) -> FHPerson? in wedge.isNamed ? wedge.person : nil }
    }

    /// Previous and Next generation, and which one this is (for sight and
    /// Voice Control).
    private func stepper(_ gen: FHGeneration) -> some View {
        HStack(spacing: 12) {
            Button {
                step(-1)
            } label: {
                Label("Previous generation", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(current <= 0)
            .accessibilityLabel("Previous generation")
            Text(Self.stepperWords(gen))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Button {
                step(1)
            } label: {
                Label("Next generation", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(current >= generations.count - 1)
            .accessibilityLabel("Next generation")
        }
    }

    /// "Generation 2: grandparents".
    static func stepperWords(_ gen: FHGeneration) -> String {
        let n: String = "Generation \(gen.gen ?? 0)"
        guard let name = FamilyAccessRules.nonEmpty(gen.name) else { return n }
        return n + ": " + name
    }

    private func step(_ by: Int) {
        let target: Int = min(max(0, current + by), max(0, generations.count - 1))
        guard target != current else { return }
        chosen = target
        page = 0
        // VoiceOver says the adjustable element's new value by itself.
    }

    private func open(_ person: FHPerson) {
        nav.pushLibrary(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))
    }

    // MARK: The ancestors in this generation, 32 at a time

    private func ancestorList(_ gen: FHGeneration) -> some View {
        let wedges: [FHWedge] = gen.wedges.filter { $0.isNamed }
        let window: Range<Int> = FamilyPaging.window(total: wedges.count, page: page, size: pageSize)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(wedges[window].enumerated()), id: \.offset) { pair in
                if let person = pair.element.person {
                    FamilyPersonRow(person: person, spoken: Self.rowSentence(pair.element, person))
                        .accessibilityFocused($focusKey, equals: Self.rowKey(person.id))
                }
            }
            if wedges.count > pageSize {
                FamilyPageButtons(size: pageSize,
                                  hasPrevious: window.lowerBound > 0,
                                  hasNext: window.upperBound < wedges.count,
                                  previous: { turn(-1, wedges) },
                                  next: { turn(1, wedges) })
            }
        }
    }

    /// "Your grandfather, Dan Example, 1930 to 1999, Dad's side. On average 1 in 4."
    static func rowSentence(_ wedge: FHWedge, _ person: FHPerson) -> String {
        guard let share = FamilyAccessRules.nonEmpty(wedge.share) else { return person.spokenOrName }
        return person.spokenOrName + " On average " + share + "."
    }

    static func rowKey(_ id: String) -> String { "fan-row-" + id }

    private func turn(_ by: Int, _ wedges: [FHWedge]) {
        let last: Int = FamilyPaging.pages(total: wedges.count, size: pageSize) - 1
        page = min(max(0, page + by), last)
        let window: Range<Int> = FamilyPaging.window(total: wedges.count, page: page, size: pageSize)
        FamilyAnnounce.say(FamilyPaging.spoken(window, total: wedges.count))
        guard window.lowerBound < wedges.count, let first = wedges[window.lowerBound].person else { return }
        let key: String = Self.rowKey(first.id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            focusKey = key
        }
    }
}

// MARK: - The drawing

/// Where the fan sits in its frame: the middle of the bottom edge, and how
/// big it is. A whole fan is the upper half circle; a half fan is one quarter
/// of it (the father's side on the left, the mother's on the right). The
/// frame is always a little wider than twice its height (`aspect`).
struct FamilyFanFrame {
    let size: CGSize

    static let aspect: CGFloat = 1.9

    var outer: Double {
        let fits: CGFloat = min(size.width / 2 - 6, size.height - 8)
        return Double(max(20, fits))
    }
    var inner: Double { outer * 0.26 }
    var centre: FHPoint { FHPoint(x: Double(size.width / 2), y: Double(size.height - 4)) }

    static func arcs(_ gen: FHGeneration, half: Bool) -> [FHArc] {
        let rightSide: Bool = gen.wedges.first?.side == "mother"
        return FamilyGeometry.fanWedges(count: gen.wedges.count, half: half, rightSide: rightSide)
    }
}

extension View {
    /// The fan's frame: as wide as there is room for (520 points at most),
    /// and a little under half as high.
    func familyFanFrame() -> some View {
        aspectRatio(FamilyFanFrame.aspect, contentMode: .fit)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
    }
}

/// The wedges of one generation: filled in the side's colour when named,
/// striped when a research finding, an empty dashed outline when unknown.
/// Faces are laid over it (at most 16). A drawing: the element that holds it
/// carries the words.
struct FamilyFanDrawing: View {
    let generation: FHGeneration
    let half: Bool

    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        GeometryReader { geo in
            let frame = FamilyFanFrame(size: geo.size)
            ZStack(alignment: .topLeading) {
                wedges(frame)
                faces(frame)
            }
        }
        .familyFanFrame()
    }

    private func wedges(_ frame: FamilyFanFrame) -> some View {
        let arcs: [FHArc] = FamilyFanFrame.arcs(generation, half: half)
        let list: [FHWedge] = generation.wedges
        let contrast: Bool = highContrast
        return Canvas { context, _ in
            for (i, arc) in arcs.enumerated() where i < list.count {
                let path: Path = Self.path(frame: frame, arc: arc)
                Self.paint(context, path: path, wedge: list[i], contrast: contrast)
            }
        }
        .frame(width: frame.size.width, height: frame.size.height)
    }

    static func path(frame: FamilyFanFrame, arc: FHArc) -> Path {
        let steps: Int = max(2, Int(arc.sweep / 4))
        let points: [FHPoint] = FamilyGeometry.wedgeOutline(center: frame.centre, inner: frame.inner,
                                                            outer: frame.outer, arc: arc, steps: steps)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for p in points.dropFirst() {
            path.addLine(to: CGPoint(x: p.x, y: p.y))
        }
        path.closeSubpath()
        return path
    }

    static func paint(_ context: GraphicsContext, path: Path, wedge: FHWedge, contrast: Bool) {
        let lineWidth: CGFloat = contrast ? 2 : 1
        if wedge.isResearch {
            let tint: Color = FamilySideColor.color(.research, contrast: contrast)
            context.fill(path, with: .color(tint.opacity(0.18)))
            var striped = context
            striped.clip(to: path)
            striped.stroke(stripes(path.boundingRect), with: .color(tint.opacity(0.7)), lineWidth: 1)
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: lineWidth, dash: [4, 3]))
        } else if wedge.isNamed {
            let tint: Color = FamilySideColor.color(FHSide(raw: wedge.side), contrast: contrast)
            context.fill(path, with: .color(tint.opacity(contrast ? 0.45 : 0.3)))
            context.stroke(path, with: .color(tint), lineWidth: lineWidth)
        } else {
            context.fill(path, with: .color(Color.secondary.opacity(0.06)))
            context.stroke(path, with: .color(Color.secondary.opacity(contrast ? 0.9 : 0.5)),
                           style: StrokeStyle(lineWidth: lineWidth, dash: [3, 4]))
        }
    }

    /// Diagonal stripes across a rectangle, 7 points apart.
    static func stripes(_ rect: CGRect) -> Path {
        var path = Path()
        let span: CGFloat = rect.width + rect.height
        var x: CGFloat = -rect.height
        while x < span {
            path.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            x += 7
        }
        return path
    }

    /// Faces (or initials) in the named wedges, for 16 wedges or fewer.
    @ViewBuilder
    private func faces(_ frame: FamilyFanFrame) -> some View {
        let size: CGFloat = CGFloat(FamilyGeometry.fanFaceSize(slots: generation.wedges.count))
        if size > 0 {
            let arcs: [FHArc] = FamilyFanFrame.arcs(generation, half: half)
            let radius: Double = (frame.inner + frame.outer) / 2
            ForEach(Array(generation.wedges.enumerated()), id: \.offset) { pair in
                if pair.offset < arcs.count, pair.element.isNamed, let person = pair.element.person {
                    let spot: FHPoint = FamilyGeometry.point(center: frame.centre, radius: radius, degrees: arcs[pair.offset].middle)
                    FamilyPhoto(image: person.face, size: .f, drawn: size,
                                initials: person.initials ?? "", side: person.sideKind, circle: true)
                        .position(x: spot.x, y: spot.y)
                }
            }
        }
    }
}

/// Clear buttons over the faces, so a face can be tapped (and named to Voice
/// Control: "Tap Dan"). Hidden while VoiceOver runs; the fan's Actions rotor
/// opens the same people.
struct FamilyFanFaceButtons: View {
    let generation: FHGeneration
    let half: Bool
    let onOpen: (FHPerson) -> Void

    var body: some View {
        GeometryReader { geo in
            let frame = FamilyFanFrame(size: geo.size)
            let size: CGFloat = CGFloat(FamilyGeometry.fanFaceSize(slots: generation.wedges.count))
            let arcs: [FHArc] = FamilyFanFrame.arcs(generation, half: half)
            let radius: Double = (frame.inner + frame.outer) / 2
            ZStack(alignment: .topLeading) {
                if size > 0 {
                    ForEach(Array(generation.wedges.enumerated()), id: \.offset) { pair in
                        if pair.offset < arcs.count, pair.element.isNamed, let person = pair.element.person {
                            let spot: FHPoint = FamilyGeometry.point(center: frame.centre, radius: radius, degrees: arcs[pair.offset].middle)
                            Button {
                                onOpen(person)
                            } label: {
                                Color.clear.frame(width: max(44, size), height: max(44, size))
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityLabel(person.spokenOrName)
                            .accessibilityInputLabels([person.first ?? "", person.shownName].filter { !$0.isEmpty })
                            .position(x: spot.x, y: spot.y)
                        }
                    }
                }
            }
        }
        .familyFanFrame()
    }
}

/// What the fan's fills mean, in words (colour is never the only cue).
struct FamilyFanLegend: View {
    let hasResearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Filled: has a name. Dashed and empty: not known yet.")
            if hasResearch {
                Text("Striped: a research finding, not proven by records.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
