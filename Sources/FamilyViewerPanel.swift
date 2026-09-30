import SwiftUI
import UIKit

// MARK: - Family history: the words under a picture (Sep 29 2026)
//
// The photo viewer's panel, in the server's words (/media/:id/info, else
// what the picture reference carried): the caption; the Original/Restored
// switch with the restored copy's label ("Restored with AI: colours and
// repairs may be guessed") and what the restoring changed; the people as
// links with their terms; the date and place; the Description, marked
// "Described automatically"; the words in the picture, marked "Read
// automatically"; "Do you know who this is?"; and "Ask for this photo to be
// restored" where the server allows it. Solid under Reduce Transparency and
// Increase Contrast, so the words never sit on a see-through panel.

struct FamilyViewerPanel: View {
    /// The copy on screen.
    let image: FHImage?
    /// The picture as the screen listed it (the switch's starting point).
    let item: FHImage?
    let info: FHMediaInfo?
    @Binding var showDescription: Bool
    let said: String?
    let busy: Bool
    let onSwitch: (Bool) -> Void
    let onPerson: (FHPerson) -> Void
    let onWho: () -> Void
    let onRestore: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @KadeContrastPolicy private var highContrast: Bool
    @State private var showText = false
    @State private var showSource = false

    private var solid: Bool { reduceTransparency || highContrast }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                captionLine
                copySwitch
                peopleLinks
                dateLine
                if let warning = FamilyAccessRules.nonEmpty(info?.evidenceWarning) {
                    FamilyEvidenceWarning(words: warning)
                }
                descriptionBox
                textBox
                sourceBox
                actions
                if let said {
                    Text(said)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: typeSize.isAccessibilitySize ? 440 : 300)
        .background(panelColor.ignoresSafeArea(edges: .bottom))
    }

    private var panelColor: Color {
        solid ? Color(.systemBackground) : Color(.systemBackground).opacity(0.94)
    }

    // MARK: Caption and copies

    @ViewBuilder
    private var captionLine: some View {
        if let caption = FamilyAccessRules.nonEmpty(info?.caption) ?? FamilyAccessRules.nonEmpty(item?.caption) ?? FamilyAccessRules.nonEmpty(image?.short) {
            Text(caption)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasOtherCopy: Bool { item?.otherCopy != nil }
    private var restoredOnScreen: Bool { image?.isRestoredCopy ?? false }

    private var restoredLabel: String {
        FamilyAccessRules.nonEmpty(image?.restoredLabel) ?? FamilyAccessRules.nonEmpty(item?.restoredLabel)
            ?? "Restored with AI: colours and repairs may be guessed"
    }

    @ViewBuilder
    private var copySwitch: some View {
        if hasOtherCopy {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Which copy", selection: Binding(get: { restoredOnScreen }, set: { (wanted: Bool) in onSwitch(wanted) })) {
                    Text("Restored").tag(true)
                    Text("Original").tag(false)
                }
                .pickerStyle(.segmented)
                if restoredOnScreen {
                    Text(restoredLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notes = FamilyAccessRules.nonEmpty(info?.restoredNotes) {
                        Text(notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if restoredOnScreen {
            Text(restoredLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: People, date and place

    private var people: [FHPerson] {
        if let known = info?.people, !known.isEmpty { return known }
        return item?.people ?? []
    }

    @ViewBuilder
    private var peopleLinks: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if info?.newspaperSource != nil || image?.categoryKind == .record {
                    Text("People linked to this record")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(people) { person in
                    Button {
                        onPerson(person)
                    } label: {
                        HStack(spacing: 10) {
                            FamilyPhoto(image: person.face, size: .f, drawn: 32,
                                        initials: person.initials ?? "", side: person.sideKind, circle: true)
                            Text(Self.nameAndTerm(person))
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityLabel(FamilyHeroCard.openName(person))
                    .accessibilityInputLabels([person.shownName])
                }
            }
        }
    }

    /// "Dan Example, your grandfather".
    static func nameAndTerm(_ person: FHPerson) -> String {
        guard let term = FamilyAccessRules.nonEmpty(person.term) else { return person.shownName }
        return person.shownName + ", " + term
    }

    @ViewBuilder
    private var dateLine: some View {
        let bits: [String] = [image?.date ?? item?.date ?? "", image?.place ?? item?.place ?? ""].filter { !$0.isEmpty }
        if !bits.isEmpty {
            Text(bits.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(bits.joined(separator: ", "))
        }
    }

    // MARK: Description and text

    private var descriptionWords: String? {
        FamilyAccessRules.nonEmpty(info?.description) ?? FamilyAccessRules.nonEmpty(image?.description)
    }

    private var described: Bool {
        (info?.described ?? image?.described) == "auto"
    }

    @ViewBuilder
    private var descriptionBox: some View {
        if let words = descriptionWords {
            DisclosureGroup("Description", isExpanded: $showDescription) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(words)
                        .fixedSize(horizontal: false, vertical: true)
                    if described {
                        Text(FamilyAccessRules.nonEmpty(info?.describedNote) ?? "Described automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
    }

    private var textWords: String? {
        FamilyAccessRules.nonEmpty(info?.text) ?? FamilyAccessRules.nonEmpty(image?.text)
    }

    private var textAuto: Bool {
        (info?.textAuto ?? image?.textAuto) == true
    }

    @ViewBuilder
    private var textBox: some View {
        if let words = textWords {
            DisclosureGroup("Read the text", isExpanded: $showText) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(words)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if textAuto {
                        Text(FamilyAccessRules.nonEmpty(info?.textNote) ?? "Read automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Source

    /// The saved citation remains readable even after a provider membership
    /// ends; visiting the source website is a separate optional action.
    @ViewBuilder
    private var sourceBox: some View {
        let newspaper = info?.newspaperSource
        let source = info?.source ?? newspaper.map { FHSourceLabel(citation: $0.citation, url: $0.sourceUrl) }
        if source != nil || newspaper != nil {
            let source = source ?? FHSourceLabel()
            let title = FamilyAccessRules.nonEmpty(source.title)
            let citation = FamilyAccessRules.nonEmpty(source.citation)
            if title != nil || citation != nil || source.website != nil || newspaper != nil {
                DisclosureGroup("Source", isExpanded: $showSource) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let title {
                            Text(title).fixedSize(horizontal: false, vertical: true)
                        }
                        if let citation, citation != (title ?? "") {
                            Text(citation)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if let website = source.website {
                            Link("Open source website", destination: website)
                                .accessibilityHint("Opens the source provider's website.")
                        }
                        if let newspaper {
                            FamilyNewspaperDetails(source: newspaper, showIndexedPersonRole: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: Notes to the owner

    /// The server says whether asking makes sense; without its word, only an
    /// old photograph or grave photo with no restored copy yet (never a
    /// record or a document, whose writing restoring could change).
    private var mayAskRestore: Bool {
        if let said = info?.canAskRestore { return said }
        guard let image, !image.isRestoredCopy, image.restored == nil else { return false }
        switch image.categoryKind {
        case .portrait, .photo, .grave: return true
        case .record, .document, .story, .restored, .other: return false
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Do you know who this is?") { onWho() }
                .accessibilityHint("Sends a note to the tree's owner.")
            if mayAskRestore {
                Button(busy ? "Asking…" : "Ask for this photo to be restored") { onRestore() }
                    .disabled(busy)
                    .accessibilityHint("Adds a request to the tree's owner's notes. Nothing is changed on this phone.")
            }
        }
        .buttonStyle(.bordered)
    }
}

/// A visible, readable caution; the words come from the source review.
struct FamilyEvidenceWarning: View {
    let words: String

    var body: some View {
        Label {
            Text(words).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct FamilyNewspaperDetails: View {
    let source: FHNewspaperSource
    var showIndexedPersonRole = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line("Saved coverage", source.coverage)
            line("Main article subject", source.principalArticleSubject)
            if showIndexedPersonRole {
                line("Indexed person's role", source.indexedPersonRole)
            }
            line("Identity review", source.identityReview?.note)
            if source.linkedTreeIdentityVerified == false {
                Text("The indexed name has not been verified as the linked person in this family tree.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(source.limitations.enumerated()), id: \.offset) { pair in
                if let words = FamilyAccessRules.nonEmpty(pair.element) {
                    Text(words).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ label: String, _ words: String?) -> some View {
        if let words = FamilyAccessRules.nonEmpty(words) {
            Text(label + ": " + words).fixedSize(horizontal: false, vertical: true)
        }
    }
}
