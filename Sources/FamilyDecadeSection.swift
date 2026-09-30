import SwiftUI
import UIKit

// MARK: - Family history: one decade of Through the years (Sep 29 2026)
//
// DESIGN 1.6, every word the server's:
// - the decade's heading (h2, "1880s"), always drawn;
// - a card with its best photo (it opens the viewer) and one line ("41 of
//   your ancestors were alive");
// - the context lines, the heart of the screen ("12 of your ancestors were
//   adults during the Civil War");
// - a thin band of lifelines, one lane each (the server packs the lanes),
//   the decade's end at the top, with a small face where a life begins. It
//   is ONE element with the server's summary ("1880s: 41 ancestors alive,
//   12 events"): a picture area is never a silent zone;
// - the events, 12 at a time ("Next 12" moves VoiceOver to the first new
//   one). An event about one person opens their page.

struct FamilyDecadeSection: View {
    let decade: FHDecade
    let people: [String: FHPerson]
    let lanes: Int
    let onPhoto: (FHImage) -> Void

    @State private var page = 0
    @AccessibilityFocusState private var focusKey: String?

    private let pageSize = 12

    private var title: String {
        FamilyAccessRules.nonEmpty(decade.title) ?? (decade.decade.map { String($0) + "s" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyHeading(text: title, level: .h2)
            summaryCard
            contextLines
            if !decade.bars.isEmpty, let start = decade.decade {
                FamilyDecadeBand(decade: start, bars: decade.bars, people: people, lanes: lanes)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(FamilyAccessRules.nonEmpty(decade.spoken) ?? title)
                    .accessibilityAddTraits(.isImage)
            }
            events
        }
        .padding(.bottom, 8)
    }

    // MARK: The card

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            if let photo = decade.photo {
                Button {
                    onPhoto(photo)
                } label: {
                    FamilyPhoto(image: photo, size: .t, drawn: 72)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(photo.label)
                .accessibilityHint("Opens the picture.")
                .accessibilityInputLabels(["Picture"])
            }
            if let summary = FamilyAccessRules.nonEmpty(decade.summary) {
                Text(summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var contextLines: some View {
        if !decade.context.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(decade.context.enumerated()), id: \.offset) { pair in
                    contextLine(pair.element)
                }
            }
            .familyCard()
        }
    }

    private func contextLine(_ line: FHContextLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = FamilyAccessRules.nonEmpty(line.title) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            if let text = FamilyAccessRules.nonEmpty(line.text) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.contextSpoken(line))
    }

    /// "The Civil War. 12 of your ancestors were adults during the Civil War."
    static func contextSpoken(_ line: FHContextLine) -> String {
        let said: String = FamilyAccessRules.nonEmpty(line.spoken) ?? line.text ?? ""
        guard let title = FamilyAccessRules.nonEmpty(line.title) else { return said }
        return title + ". " + said
    }

    // MARK: Events, 12 at a time

    @ViewBuilder
    private var events: some View {
        if !decade.events.isEmpty {
            let window: Range<Int> = FamilyPaging.window(total: decade.events.count, page: page, size: pageSize)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(decade.events[window].enumerated()), id: \.offset) { pair in
                    eventRow(pair.element, number: window.lowerBound + pair.offset)
                }
                if decade.events.count > pageSize {
                    FamilyPageButtons(size: pageSize,
                                      hasPrevious: window.lowerBound > 0,
                                      hasNext: window.upperBound < decade.events.count,
                                      previous: { turn(-1) },
                                      next: { turn(1) })
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: FHEvent, number: Int) -> some View {
        let words: String = event.text ?? ""
        let said: String = FamilyAccessRules.nonEmpty(event.spoken) ?? words
        let key: String = Self.eventKey(decade.decade ?? 0, number)
        if let id = FamilyAccessRules.nonEmpty(event.personId) {
            NavigationLink(value: HomeRoute.library(.family(.person(FamilyPersonRoute(id: id, name: people[id]?.shownName ?? ""))))) {
                eventLabel(words, research: event.research == true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(event.research == true ? said + " Research finding." : said)
            .accessibilityHint("Opens their page.")
            .accessibilityFocused($focusKey, equals: key)
        } else {
            eventLabel(words, research: event.research == true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(said)
                .accessibilityFocused($focusKey, equals: key)
        }
    }

    private func eventLabel(_ words: String, research: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(words)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if research {
                FamilyResearchPill()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    static func eventKey(_ decade: Int, _ number: Int) -> String { "event-\(decade)-\(number)" }

    private func turn(_ by: Int) {
        let total: Int = decade.events.count
        let last: Int = FamilyPaging.pages(total: total, size: pageSize) - 1
        page = min(max(0, page + by), last)
        let window: Range<Int> = FamilyPaging.window(total: total, page: page, size: pageSize)
        FamilyAnnounce.say(FamilyPaging.spoken(window, total: total))
        let key: String = Self.eventKey(decade.decade ?? 0, window.lowerBound)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            focusKey = key
        }
    }
}

// MARK: - The band of lifelines

/// One decade's lifelines: a lane each, the decade's end at the top and its
/// start at the bottom, in the side's colour (a life known only from
/// research in the research colour), with a small face where a life begins
/// in this decade (12 at most). A drawing: the element that holds it says
/// the server's summary.
struct FamilyDecadeBand: View {
    let decade: Int
    let bars: [FHBar]
    let people: [String: FHPerson]
    let lanes: Int

    @KadeContrastPolicy private var highContrast: Bool

    private let height: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                lines(width: geo.size.width)
                births(width: geo.size.width)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
        .accessibilityIgnoresInvertColors(true)
    }

    private func lines(width: CGFloat) -> some View {
        let list: [FHBar] = bars
        let lanesCount: Int = max(1, lanes)
        let contrast: Bool = highContrast
        let bandHeight: Double = Double(height)
        let start: Int = decade
        return Canvas { context, _ in
            let barWidth: CGFloat = max(2, min(6, width / CGFloat(lanesCount) * 0.6))
            for bar in list {
                guard let from = bar.from else { continue }
                let to: Int = bar.to ?? from
                guard let span = FamilyGeometry.barSpan(from: from, to: to, decade: start, height: bandHeight) else { continue }
                let x: Double = FamilyGeometry.laneX(lane: bar.lane ?? 0, lanes: lanesCount, width: Double(width))
                let rect = CGRect(x: CGFloat(x) - barWidth / 2, y: CGFloat(span.top),
                                  width: barWidth, height: max(2, CGFloat(span.bottom - span.top)))
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                let side: FHSide = bar.research == true ? .research : FHSide(raw: bar.side)
                context.fill(path, with: .color(FamilySideColor.color(side, contrast: contrast)))
            }
        }
        .frame(width: width, height: height)
    }

    /// Faces where a life begins in this decade.
    private func births(width: CGFloat) -> some View {
        let lanesCount: Int = max(1, lanes)
        let born: [FHBar] = Array(bars.filter { ($0.from ?? 0) >= decade && ($0.from ?? 0) < decade + 10 }.prefix(12))
        let size: CGFloat = 18
        return ZStack(alignment: .topLeading) {
            ForEach(Array(born.enumerated()), id: \.offset) { pair in
                let bar: FHBar = pair.element
                let person: FHPerson? = people[bar.personId ?? ""]
                let x: Double = FamilyGeometry.laneX(lane: bar.lane ?? 0, lanes: lanesCount, width: Double(width))
                let y: Double = FamilyGeometry.yearY(Double(bar.from ?? decade), decade: decade, height: Double(height))
                FamilyPhoto(image: person?.face, size: .f, drawn: size,
                            initials: person?.initials ?? "", side: FHSide(raw: bar.side), circle: true)
                    .position(x: x, y: min(max(Double(size) / 2, y), Double(height) - Double(size) / 2))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}
