import SwiftUI
import UIKit

// MARK: - Family history: a person's page, section by section (Sep 29 2026)
//
// Each section of DESIGN 1.4 is its own small view (the type-checker stays
// fast), in the server's words:
// - Pictures: up to 20 thumbnails and "All {n} pictures". Restored copies
//   come first (her Sep 29 decision) with an Original/Restored switch. Under
//   VoiceOver the strip is ONE adjustable element ("Pictures of Ada", "3 of
//   12, {short label}"; swipe up or down, double tap opens the viewer); the
//   thumbnails stay buttons for sight and Voice Control ("Photo 3").
// - Life: one row per fact, each one element.
// - Family: parents, spouses, brothers and sisters, children, with step,
//   adoptive and probable spelled out.
// Records, the grave and the sources are in FamilyPersonRecords.swift, the
// findings in FamilyFindingCard.swift, the nutshell and the relation in
// FamilyPersonRelation.swift.

// MARK: - Pictures

struct FamilyPicturesStrip: View {
    let items: [FHImage]
    let total: Int
    let first: String
    let personId: String
    var focus: AccessibilityFocusState<String?>.Binding
    /// The pictures as shown (restored or original), and which one.
    let onOpen: ([FHImage], Int) -> Void

    static let focusKey = "person-pictures"

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var current = 0
    /// Show the originals rather than the restored copies.
    @State private var originals = false

    private let thumb: CGFloat = 88

    private var hasCopies: Bool { items.contains { $0.otherCopy != nil } }

    /// Each picture once, as the chosen copy (a list that carries both copies
    /// of one photo shows it once).
    private var shownItems: [FHImage] {
        guard hasCopies else { return items }
        let wantOriginals: Bool = originals
        let mapped: [FHImage] = items.map { (image: FHImage) -> FHImage in
            if wantOriginals == image.isRestoredCopy, let other = image.otherCopyImage() { return other }
            return image
        }
        var seen = Set<String>()
        return mapped.filter { seen.insert($0.id).inserted }
    }

    private var safeCurrent: Int { min(max(0, current), max(0, shownItems.count - 1)) }

    private var restoredLabel: String {
        FamilyAccessRules.nonEmpty(items.first(where: { $0.restoredLabel != nil })?.restoredLabel)
            ?? "Restored with AI: colours and repairs may be guessed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyHeading(text: "Pictures", level: .h2)
            if hasCopies {
                copyPicker
            }
            if voiceOverOn {
                spokenStrip
            } else {
                buttonStrip
            }
            allLink
        }
    }

    private var copyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Show restored or original photos", selection: $originals) {
                Text("Restored").tag(false)
                Text("Original").tag(true)
            }
            .pickerStyle(.segmented)
            if !originals {
                Text(restoredLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// For sight, Voice Control and Switch Control: each thumbnail a button.
    private var buttonStrip: some View {
        let list: [FHImage] = shownItems
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { pair in
                    let voiceName: String = "Photo \(pair.offset + 1)"
                    Button {
                        onOpen(list, pair.offset)
                    } label: {
                        FamilyPhoto(image: pair.element, size: .t, drawn: thumb)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(FamilyAccessRules.nonEmpty(pair.element.short) ?? pair.element.label)
                    .accessibilityInputLabels([voiceName])
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Under VoiceOver: ONE adjustable element for the whole strip.
    private var spokenStrip: some View {
        let list: [FHImage] = shownItems
        return HStack(spacing: 8) {
            ForEach(Array(list.prefix(6).enumerated()), id: \.offset) { pair in
                FamilyPhoto(image: pair.element, size: .t, drawn: thumb)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pictures of " + first)
        .accessibilityValue(value(list))
        .accessibilityHint("Swipe up or down to hear each picture. Double tap to open it.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: current = min(safeCurrent + 1, max(0, list.count - 1))
            case .decrement: current = max(safeCurrent - 1, 0)
            @unknown default: break
            }
        }
        .accessibilityAction { onOpen(list, safeCurrent) }
        .accessibilityFocused(focus, equals: Self.focusKey)
    }

    /// "3 of 12, Photo: your grandfather, Dan Example".
    private func value(_ list: [FHImage]) -> String {
        guard list.indices.contains(safeCurrent) else { return "" }
        let picture: FHImage = list[safeCurrent]
        let words: String = FamilyAccessRules.nonEmpty(picture.short) ?? picture.label
        return "\(safeCurrent + 1) of \(list.count), " + words
    }

    private var allWords: String {
        total == 1 ? "All 1 picture" : "All \(total) pictures"
    }

    private var allLink: some View {
        NavigationLink(value: HomeRoute.library(.family(.gallery(FamilyGalleryRoute(kind: "all", person: personId))))) {
            Label(allWords, systemImage: "photo.on.rectangle")
        }
        .accessibilityHint("Opens every picture of " + first + ".")
    }
}

// MARK: - Life

struct FamilyLifeSection: View {
    let rows: [FHLifeRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyHeading(text: "Life", level: .h2)
            ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                row(pair.element)
            }
        }
    }

    private func row(_ row: FHLifeRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.year.map { String($0) } ?? "")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text ?? "")
                    .fixedSize(horizontal: false, vertical: true)
                if let sources = FamilyAccessRules.nonEmpty(row.sources) {
                    Text(sources).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(row))
    }

    /// The server's sentence, and how many sources back it.
    static func spoken(_ row: FHLifeRow) -> String {
        let yearWords: String = row.year.map { String($0) + ": " } ?? ""
        let said: String = FamilyAccessRules.nonEmpty(row.spoken) ?? (yearWords + (row.text ?? ""))
        guard let sources = FamilyAccessRules.nonEmpty(row.sources) else { return said }
        return said + " " + sources + "."
    }
}

// MARK: - Family

struct FamilyFamilySection: View {
    let family: FHFamily

    private var isEmpty: Bool {
        family.parents.isEmpty && family.spouses.isEmpty && family.siblings.isEmpty && family.children.isEmpty
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                FamilyHeading(text: "Family", level: .h2)
                group("Parents", family.parents)
                group("Spouses", family.spouses)
                group("Brothers and sisters", family.siblings)
                group("Children", family.children)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ people: [FHPerson]) -> some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                FamilyHeading(text: title, level: .h3)
                ForEach(Array(people.enumerated()), id: \.offset) { pair in
                    FamilyPersonRow(person: pair.element, kindText: pair.element.kindText)
                }
            }
        }
    }
}
