import SwiftUI
import UIKit

// MARK: - Family history: a person's records, grave and sources (Sep 29 2026)
//
// Split from FamilyPersonSections.swift (DESIGN 4.11: small files). Records
// are collapsed and shown 10 at a time; a record card is ONE element whose
// double tap shows the transcription, with Open the scan and Open on
// Ancestry in the Actions rotor. The grave and the sources are collapsed too.

// MARK: - Records

struct FamilyRecordsSection: View {
    let records: [FHRecord]
    var focus: AccessibilityFocusState<String?>.Binding
    /// A scan to open, and the card's focus key (VoiceOver comes back there).
    let onScan: (FHImage, String) -> Void

    @State private var expanded = false
    @State private var page = 0
    private let pageSize = 10

    static func key(_ index: Int) -> String { "person-record-\(index)" }

    private var window: Range<Int> {
        FamilyPaging.window(total: records.count, page: page, size: pageSize)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            cards
        } label: {
            Text("Records, \(records.count)")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var cards: some View {
        let shown: Range<Int> = window
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(shown), id: \.self) { index in
                FamilyRecordCard(record: records[index], focus: focus, focusKey: Self.key(index)) { image in
                    onScan(image, Self.key(index))
                }
            }
            if records.count > pageSize {
                FamilyPageButtons(size: pageSize,
                                  hasPrevious: shown.lowerBound > 0,
                                  hasNext: shown.upperBound < records.count,
                                  previous: { turn(-1) },
                                  next: { turn(1) })
            }
        }
        .padding(.top, 8)
    }

    /// A new page: say what shows, then move to its first record.
    private func turn(_ step: Int) {
        let last: Int = FamilyPaging.pages(total: records.count, size: pageSize) - 1
        page = min(max(0, page + step), last)
        let shown: Range<Int> = FamilyPaging.window(total: records.count, page: page, size: pageSize)
        FamilyAnnounce.say(FamilyPaging.spoken(shown, total: records.count))
        let target: String = Self.key(shown.lowerBound)
        let binding = focus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            binding.wrappedValue = target
        }
    }
}

struct FamilyRecordCard: View {
    let record: FHRecord
    var focus: AccessibilityFocusState<String?>.Binding
    let focusKey: String
    let onScan: (FHImage) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.openURL) private var openURL
    @State private var showing = false

    private var title: String { FamilyAccessRules.nonEmpty(record.title) ?? "A record" }

    /// The server's sentence, with the mistake warning if it left it out.
    private var spoken: String {
        let said: String = FamilyAccessRules.nonEmpty(record.spoken) ?? title
        guard let wrong = record.wrongWords, !said.contains(wrong) else { return said }
        return said + " " + wrong
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if let wrong = record.wrongWords {
                Label {
                    Text(wrong).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.subheadline)
                .accessibilityHidden(true)
            }
            if showing {
                FamilyTranscription(record: record)
            }
            buttons
        }
        .familyCard()
    }

    private var summary: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(showing ? "Hide the transcription" : "Show the transcription")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let scan = record.image {
                    FamilyPhoto(image: scan, size: .t, drawn: 64)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint(showing ? "Hides the transcription." : "Shows the transcription.")
        .accessibilityFocused(focus, equals: focusKey)
        .accessibilityActions {
            if let scan = record.image {
                Button("Open the scan") { onScan(scan) }
            }
            if let url = record.url {
                Button("Open on Ancestry") { openURL(url) }
            }
        }
    }

    /// For sight and Voice Control; VoiceOver has them in the Actions rotor.
    @ViewBuilder
    private var buttons: some View {
        if record.image != nil || record.url != nil {
            HStack(spacing: 10) {
                if let scan = record.image {
                    Button("Open the scan") { onScan(scan) }
                }
                if let url = record.url {
                    Link("Open on Ancestry", destination: url)
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            .accessibilityHidden(voiceOverOn)
        }
    }
}

/// A record's words: its fields, then its household, each row one element.
struct FamilyTranscription: View {
    let record: FHRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(record.fields.enumerated()), id: \.offset) { pair in
                Text(Self.fieldLine(pair.element))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if record.household.count > 1 {
                FamilyHeading(text: "Household", level: .h3)
                ForEach(Array(record.household.enumerated()), id: \.offset) { pair in
                    Text(pair.element.filter { !$0.isEmpty }.joined(separator: ", "))
                        .font(pair.offset == 0 ? Font.caption.weight(.semibold) : Font.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 4)
    }

    /// "Relation to head: Wife".
    static func fieldLine(_ cells: [String]) -> String {
        guard let name = cells.first else { return "" }
        let rest: String = cells.dropFirst().filter { !$0.isEmpty }.joined(separator: ", ")
        return rest.isEmpty ? name : name + ": " + rest
    }
}

// MARK: - Grave

struct FamilyGraveSection: View {
    let grave: FHGrave
    var focus: AccessibilityFocusState<String?>.Binding
    let onOpen: ([FHImage], Int) -> Void

    @State private var expanded = false

    static func photoKey(_ index: Int) -> String { "person-grave-photo-\(index)" }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            details
        } label: {
            Text("Grave")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cemetery = FamilyAccessRules.nonEmpty(grave.cemetery) {
                Text(cemetery).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let place = FamilyAccessRules.nonEmpty(grave.place) {
                Text(place).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let dates = FamilyAccessRules.nonEmpty(grave.dates) {
                Text(dates)
            }
            if let inscription = FamilyAccessRules.nonEmpty(grave.inscription) {
                Text(inscription).italic().fixedSize(horizontal: false, vertical: true)
            }
            if let bio = FamilyAccessRules.nonEmpty(grave.bio) {
                Text(bio).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if !grave.photos.isEmpty {
                photos
            }
            if let url = grave.url {
                Link("Open the memorial", destination: url)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var photos: some View {
        let list: [FHImage] = grave.photos
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { pair in
                    Button {
                        onOpen(list, pair.offset)
                    } label: {
                        FamilyPhoto(image: pair.element, size: .t, drawn: 88)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(FamilyAccessRules.nonEmpty(pair.element.short) ?? pair.element.label)
                    .accessibilityHint("Opens the picture.")
                    .accessibilityFocused(focus, equals: Self.photoKey(pair.offset))
                }
            }
        }
    }
}

// MARK: - Sources

struct FamilySourcesSection: View {
    let sources: [FHSourceRow]
    let withheld: FHWithheld?

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(sources.enumerated()), id: \.offset) { pair in
                    row(pair.element)
                }
                if let text = FamilyAccessRules.nonEmpty(withheld?.text) {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Text("Sources, \(sources.count)")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func row(_ source: FHSourceRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.title ?? "A source")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let citation = FamilyAccessRules.nonEmpty(source.citation) {
                Text(citation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = source.url {
                Link(Self.linkWords(source.kind), destination: url)
                    .font(.subheadline)
            }
        }
    }

    static func linkWords(_ kind: String?) -> String {
        switch kind ?? "" {
        case "record": return "Open on Ancestry (needs an Ancestry account)"
        case "memorial": return "Open on Find a Grave"
        default: return "Open the source"
        }
    }
}
