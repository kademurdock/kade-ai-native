import SwiftUI
import UIKit

// MARK: - Family history: Home's featured card, news, tiles and footnote (Sep 29 2026)
//
// Split from FamilyHomeParts.swift (DESIGN 4.11: small files). The featured
// cards are one at a time for sight and a plain list under VoiceOver; the
// four tiles are two across (one column at accessibility text sizes); every
// tile and row is one element with the server's words.

// MARK: - Featured: On this day, the ancestor of the week, a story

struct FamilyFeaturedCard: View {
    let items: [FHFeatured]

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var index = 0

    private var shown: [FHFeatured] { Array(items.prefix(3)) }
    private var safeIndex: Int { min(max(0, index), max(0, shown.count - 1)) }

    var body: some View {
        if voiceOverOn {
            VStack(spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.offset) { pair in
                    FamilyFeaturedItem(item: pair.element)
                }
            }
        } else if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                FamilyFeaturedItem(item: shown[safeIndex])
                    .id(safeIndex)
                    .transition(.opacity)
                if shown.count > 1 {
                    pager
                }
            }
        }
    }

    private var pager: some View {
        HStack {
            Button("Previous") { step(-1) }
                .disabled(safeIndex == 0)
                .accessibilityLabel("Previous featured card")
            Spacer()
            Text("\(safeIndex + 1) of \(shown.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Next") { step(1) }
                .disabled(safeIndex >= shown.count - 1)
                .accessibilityLabel("Next featured card")
        }
        .buttonStyle(.bordered)
    }

    private func step(_ by: Int) {
        let target: Int = min(max(0, safeIndex + by), max(0, shown.count - 1))
        withAnimation(motionAllowed ? .easeInOut(duration: 0.3) : nil) {
            index = target
        }
    }
}

/// One featured card: its title, a picture if it has one, its sentence.
struct FamilyFeaturedItem: View {
    let item: FHFeatured

    private var spoken: String {
        if let said = FamilyAccessRules.nonEmpty(item.spoken) { return said }
        return [item.title, item.text].compactMap { $0 }.joined(separator: ". ")
    }

    var body: some View {
        if let route = item.open?.route {
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
        VStack(alignment: .leading, spacing: 8) {
            if let title = item.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.brown)
            }
            if let image = item.image {
                FamilyWidePhoto(image: image, size: .s, height: 180, longSide: 680)
            }
            if let text = item.text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - New since your last visit

struct FamilyNewsStrip: View {
    let news: FHNews

    private var spoken: String { FamilyAccessRules.nonEmpty(news.spoken) ?? news.text ?? "" }

    var body: some View {
        if let route = news.open?.route {
            NavigationLink(value: HomeRoute.library(.family(route))) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .accessibilityHint("Opens what is new.")
            .familyCard()
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .familyCard()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(news.text ?? "", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.primary)
            if !news.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(news.images.prefix(8))) { image in
                        FamilyPhoto(image: image, size: .t, drawn: 34)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Tiles and More

/// The four big tiles, two across (one column at accessibility text sizes).
struct FamilyTileGrid: View {
    let tiles: [FHTile]
    let onNote: (String?) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                ForEach(tiles) { tile in
                    tileView(tile)
                }
            }
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<rowCount, id: \.self) { row in
                    GridRow {
                        ForEach(rowTiles(row)) { tile in
                            tileView(tile)
                        }
                    }
                }
            }
        }
    }

    private var rowCount: Int { (tiles.count + 1) / 2 }

    private func rowTiles(_ row: Int) -> [FHTile] {
        let start: Int = row * 2
        let end: Int = min(tiles.count, start + 2)
        return start < end ? Array(tiles[start..<end]) : []
    }

    private func tileView(_ tile: FHTile) -> some View {
        FamilyTileRow(tile: tile, icon: FamilyHomeIcons.symbol(tile.key), onNote: onNote, big: true)
            .buttonStyle(KadeCardButtonStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// More: Stories, Discoveries, Family mysteries, Everyone in the tree, the
/// game, Add a memory.
struct FamilyMoreRows: View {
    let rows: [FHTile]
    let onNote: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyHeading(text: "More", level: .h2)
            ForEach(rows) { tile in
                FamilyTileRow(tile: tile, icon: FamilyHomeIcons.symbol(tile.key), onNote: onNote)
                    .buttonStyle(KadeCardButtonStyle())
            }
        }
    }
}

enum FamilyHomeIcons {
    static func symbol(_ key: String) -> String {
        switch key {
        case "tree": return "tree"
        case "photos", "gallery": return "photo.on.rectangle"
        case "whereWhen", "map": return "clock.arrow.circlepath"
        case "dna": return "point.3.connected.trianglepath.dotted"
        case "stories": return "book"
        case "discoveries": return "magnifyingglass"
        case "mysteries": return "questionmark.circle"
        case "people": return "person.3"
        case "play": return "gamecontroller"
        case "note": return "square.and.pencil"
        default: return "chevron.right.circle"
        }
    }
}

// MARK: - Coming soon, the footnote, and the owner's links

struct FamilyHomeFooter: View {
    let home: FHHome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let soon = FamilyAccessRules.nonEmpty(home.comingSoon) {
                Text(soon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let footnote = FamilyAccessRules.nonEmpty(home.footnote) {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if home.isOwner == true {
                ownerLinks
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The owner's two web pages, opened in Safari.
    private var ownerLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(accountsTitle, destination: Self.page("accounts"))
                .accessibilityHint("Opens the website in Safari.")
            Link(notesTitle, destination: Self.page("notes"))
                .accessibilityHint("Opens the website in Safari.")
        }
    }

    private var accountsTitle: String {
        let asks: Int = home.owner?.asks ?? 0
        return asks > 0 ? "Who can see this (\(asks) asking to be added)" : "Who can see this"
    }

    private var notesTitle: String {
        let notes: Int = home.owner?.notes ?? 0
        return notes > 0 ? "Notes from the family (\(notes))" : "Notes from the family"
    }

    static func page(_ name: String) -> URL {
        URL(string: "https://kademurdock.com/family-history#/" + name) ?? URL(string: "https://kademurdock.com")!
    }
}
