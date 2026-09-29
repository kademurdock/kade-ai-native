import SwiftUI
import UIKit

// MARK: - Family history: the tree as a chart (Sep 29 2026)
//
// DESIGN 1.3 and 4.5. The server lays the tree out in box units (`boxes`
// with x and row, `edges`, `couples`, `width`, `rows`); Swift only multiplies
// by the box size for the chosen step (Fit, Normal, Large, grown with the
// text size), so a bigger step lays the tree out again with bigger boxes
// instead of zooming a picture of it. A 2D scroll view, scrolled to the
// focus after every new slice.
// - Lines: one Canvas, hidden from VoiceOver. Solid "born to", dashed step or
//   adoptive, dotted probable or doubtful; the legend says so in words.
//   Increase Contrast draws them 2 points wide.
// - Boxes: a 40-point face or initials, the name (two lines at most), the
//   years, the term, the side in words and the Research pill; the viewer's
//   own box has a thick border and a "You" tag; a chevron marks more
//   generations above. Tap: the person's page. Long press or the Actions
//   rotor: Centre the tree here, How are we related?, Show their parents.
// - VoiceOver walks the boxes in the server's `order` (nearest first, like
//   the List), and pictures load in that order too.

struct FamilyTreeChart: View {
    let tree: FHTree
    let layout: FHTreeLayout
    let scale: FamilyTreeScale
    let revision: Int
    var focus: AccessibilityFocusState<String?>.Binding
    let onCentre: (FHPerson) -> Void

    @ScaledMetric(relativeTo: .body) private var baseWidth: CGFloat = 150
    @ScaledMetric(relativeTo: .body) private var baseHeight: CGFloat = 132
    @ScaledMetric(relativeTo: .body) private var baseGap: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var baseRow: CGFloat = 172
    @KadeContrastPolicy private var highContrast: Bool
    @KadeMotionPolicy private var motionAllowed: Bool

    private var metrics: FamilyTreeMetrics {
        FamilyTreeMetrics(boxWidth: Double(baseWidth), boxHeight: Double(baseHeight),
                          gapX: Double(baseGap), rowHeight: Double(baseRow)).scaled(scale)
    }

    /// Nearest first: the order VoiceOver walks and pictures load in.
    private var ranks: [String: Int] {
        var out: [String: Int] = [:]
        for (i, key) in layout.order.enumerated() where out[key] == nil {
            out[key] = i
        }
        return out
    }

    var body: some View {
        let m: FamilyTreeMetrics = metrics
        let size: FHPoint = m.canvas(width: layout.width ?? 1, rows: layout.rows ?? 1)
        let rank: [String: Int] = ranks
        let ordered: [FHTreeBox] = layout.boxes.sorted { (rank[$0.key] ?? Int.max) < (rank[$1.key] ?? Int.max) }
        let segments: [FamilyTreeSegment] = FamilyTreeSegment.build(layout: layout, metrics: m)
        let slide: Animation = motionAllowed ? Animation.spring(response: 0.45, dampingFraction: 0.85) : Animation.easeInOut(duration: 0.2)
        VStack(spacing: 0) {
            summary
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        FamilyTreeLines(segments: segments, width: CGFloat(size.x), height: CGFloat(size.y),
                                        lineWidth: highContrast ? 2 : 1)
                        ForEach(ordered) { box in
                            placed(box, metrics: m, rank: rank[box.key] ?? ordered.count)
                        }
                    }
                    .frame(width: CGFloat(size.x), height: CGFloat(size.y), alignment: .topLeading)
                    .animation(slide, value: revision)
                    .animation(slide, value: scale)
                    .padding(24)
                    .accessibilityElement(children: .contain)
                }
                .task(id: "\(revision)-\(scale.rawValue)") {
                    await scrollToFocus(proxy)
                }
            }
            legend
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let said = tree.summary {
            Text(said.text ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .accessibilityLabel(said.spokenOrText)
                .accessibilitySortPriority(1)
        }
    }

    @ViewBuilder
    private var legend: some View {
        if !tree.legend.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tree.legend) { row in
                    Text(row.text ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }

    private func placed(_ box: FHTreeBox, metrics m: FamilyTreeMetrics, rank: Int) -> some View {
        let corner: FHPoint = m.origin(x: box.x ?? 0, row: box.row ?? 0)
        return FamilyTreeBoxView(box: box, onCentre: onCentre)
            .frame(width: CGFloat(m.boxWidth), height: CGFloat(m.boxHeight))
            .accessibilityFocused(focus, equals: box.key)
            .accessibilitySortPriority(Double(10_000 - rank))
            .id(box.key)
            .padding(.leading, CGFloat(corner.x))
            .padding(.top, CGFloat(corner.y))
    }

    @MainActor
    private func scrollToFocus(_ proxy: ScrollViewProxy) async {
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        guard let key = layout.boxes.first(where: { $0.role == "focus" })?.key ?? layout.order.first else { return }
        let glide: Animation? = motionAllowed ? Animation.easeInOut(duration: 0.45) : nil
        withAnimation(glide) {
            proxy.scrollTo(key, anchor: .center)
        }
    }
}

// MARK: - Lines

/// One line to draw: its points and its dash (none for "born to").
struct FamilyTreeSegment {
    let points: [CGPoint]
    let dash: [CGFloat]

    static func dash(for kind: String?) -> [CGFloat] {
        switch kind ?? "birth" {
        case "step", "adopted": return [6, 4]
        case "probable", "doubtful": return [1.5, 4]
        default: return []
        }
    }

    /// Parent to child as an elbow (down, across, down), and a short line
    /// between each couple.
    static func build(layout: FHTreeLayout, metrics m: FamilyTreeMetrics) -> [FamilyTreeSegment] {
        var boxes: [String: FHTreeBox] = [:]
        for box in layout.boxes { boxes[box.key] = box }
        let w: Double = m.boxWidth
        let h: Double = m.boxHeight
        let gapY: Double = max(0, m.rowHeight - m.boxHeight)
        var out: [FamilyTreeSegment] = []
        for edge in layout.edges {
            guard let parent = boxes[edge.from], let child = boxes[edge.to] else { continue }
            let p: FHPoint = m.origin(x: parent.x ?? 0, row: parent.row ?? 0)
            let c: FHPoint = m.origin(x: child.x ?? 0, row: child.row ?? 0)
            let startX: Double = p.x + w / 2
            let startY: Double = p.y + h
            let endX: Double = c.x + w / 2
            let endY: Double = c.y
            let midY: Double = endY > startY ? endY - gapY / 2 : (startY + endY) / 2
            let points: [CGPoint] = [
                CGPoint(x: startX, y: startY),
                CGPoint(x: startX, y: midY),
                CGPoint(x: endX, y: midY),
                CGPoint(x: endX, y: endY),
            ]
            out.append(FamilyTreeSegment(points: points, dash: dash(for: edge.kind)))
        }
        for pair in layout.couples where pair.count == 2 {
            guard let a = boxes[pair[0]], let b = boxes[pair[1]] else { continue }
            let pa: FHPoint = m.origin(x: a.x ?? 0, row: a.row ?? 0)
            let pb: FHPoint = m.origin(x: b.x ?? 0, row: b.row ?? 0)
            let left: FHPoint = pa.x <= pb.x ? pa : pb
            let right: FHPoint = pa.x <= pb.x ? pb : pa
            let y: Double = left.y + h / 2
            let points: [CGPoint] = [CGPoint(x: left.x + w, y: y), CGPoint(x: right.x, y: y)]
            out.append(FamilyTreeSegment(points: points, dash: []))
        }
        return out
    }
}

/// Every line, in one Canvas. Decoration only: hidden from VoiceOver.
struct FamilyTreeLines: View {
    let segments: [FamilyTreeSegment]
    let width: CGFloat
    let height: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        Canvas { context, _ in
            for segment in segments {
                guard let first = segment.points.first else { continue }
                var path = Path()
                path.move(to: first)
                for point in segment.points.dropFirst() {
                    path.addLine(to: point)
                }
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: segment.dash)
                context.stroke(path, with: .color(Color.primary.opacity(0.45)), style: style)
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - A box

struct FamilyTreeBoxView: View {
    let box: FHTreeBox
    let onCentre: (FHPerson) -> Void

    @Environment(\.kadeNavigation) private var nav
    @KadeContrastPolicy private var highContrast: Bool

    private var person: FHPerson? { box.person }
    private var research: Bool { person?.research != nil }
    private var moreAbove: Bool { (box.moreAbove ?? 0) > 0 }

    var body: some View {
        Button {
            openPage()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FamilyAccessRules.nonEmpty(box.spoken) ?? person?.spokenOrName ?? "")
        .accessibilityHint("Opens their page.")
        .accessibilityInputLabels([person?.shownName ?? "", person?.term ?? ""].filter { !$0.isEmpty })
        .accessibilityActions { actions }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        if let person {
            Button("Centre the tree here") { onCentre(person) }
            Button("How are we related?") { openPage() }
            if moreAbove {
                Button("Show their parents") { onCentre(person) }
            }
        }
    }

    private func openPage() {
        guard let person else { return }
        nav.pushLibrary(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))
    }

    private var content: some View {
        let tint: Color = FamilySideColor.color(person?.sideKind ?? .unknown, contrast: highContrast)
        let border: CGFloat = box.you == true ? 3 : (highContrast ? 2 : 1)
        let dash: [CGFloat] = research ? [4, 3] : []
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                FamilyPhoto(image: person?.face, size: .f, drawn: 40,
                            initials: person?.initials ?? "", side: person?.sideKind ?? .unknown, circle: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person?.shownName ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if let years = person?.years {
                        Text(years).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if let term = person?.term {
                Text(term).font(.caption).foregroundStyle(.primary).lineLimit(2).minimumScaleFactor(0.8)
            }
            HStack(spacing: 4) {
                if let side = person?.sideText {
                    Text(side).font(.caption2.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
                }
                Spacer(minLength: 0)
                if box.you == true {
                    Text("You")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(tint.opacity(0.2)))
                }
                if moreAbove {
                    Image(systemName: "chevron.up")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }
            if research {
                FamilyResearchPill()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(0.9), style: StrokeStyle(lineWidth: border, dash: dash)))
        .contentShape(Rectangle())
    }
}
