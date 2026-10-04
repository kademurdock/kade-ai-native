import SwiftUI
import UIKit

// MARK: - Family history: research findings (Sep 29 2026)
//
// A person's findings and the card shared by person pages and the DNA screen:
// the proof words always with it, the Research pill unless records prove it.

// MARK: - Research findings

struct FamilyFindingsSection: View {
    let findings: [FHFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyHeading(text: "Research findings", level: .h2)
            ForEach(Array(findings.enumerated()), id: \.offset) { pair in
                FamilyFindingCard(finding: pair.element)
            }
        }
    }
}

/// One finding: title, plain words, the proof words (with the Research pill
/// unless records prove it), the evidence, its people and its story. ONE
/// element under VoiceOver, with Open {person}, Read the story and (for a
/// DNA finding, where asked) What this means for your DNA in the Actions
/// rotor; the same links stay on screen for sight, Voice Control and Switch
/// Control, hidden only while VoiceOver runs.
struct FamilyFindingCard: View {
    let finding: FHFinding
    /// Where VoiceOver can be sent on a new page.
    var focus: AccessibilityFocusState<String?>.Binding? = nil
    var focusKey: String = ""
    /// Optional "What this means for your DNA" action on a DNA finding.
    var showsDNALink: Bool = false

    @Environment(\.kadeNavigation) private var nav
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    private var isResearch: Bool { (finding.proof ?? "records") != "records" }

    private var hasDNALink: Bool { showsDNALink && finding.dna == true }

    private var spoken: String {
        if let said = FamilyAccessRules.nonEmpty(finding.spoken) { return said }
        let parts: [String] = [finding.title, finding.text ?? finding.summary, finding.proofText].compactMap { $0 }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            focusedWords
            links
                .accessibilityHidden(voiceOverOn)
        }
        .familyCard()
    }

    private var wordsElement: some View {
        words
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityActions { actions }
    }

    @ViewBuilder
    private var focusedWords: some View {
        if let focus {
            wordsElement.accessibilityFocused(focus, equals: focusKey)
        } else {
            wordsElement
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = finding.title {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let text = finding.text ?? finding.summary {
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isResearch {
                    FamilyResearchPill()
                }
                if let proof = FamilyAccessRules.nonEmpty(finding.proofText) {
                    Text(proof).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let evidence = FamilyAccessRules.nonEmpty(finding.evidence) {
                Text(evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        ForEach(finding.people) { person in
            Button(FamilyHeroCard.openName(person)) { openPerson(person) }
        }
        if let slug = FamilyAccessRules.nonEmpty(finding.storySlug) {
            Button("Read the story") { openStory(slug) }
        }
        if hasDNALink {
            Button("What this means for your DNA") { openDNA() }
        }
    }

    @ViewBuilder
    private var links: some View {
        if !finding.people.isEmpty || finding.storySlug != nil || hasDNALink {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(finding.people) { person in
                    Button {
                        openPerson(person)
                    } label: {
                        HStack(spacing: 8) {
                            FamilyPhoto(image: person.face, size: .f, drawn: 28,
                                        initials: person.initials ?? "", side: person.sideKind, circle: true)
                            Text(FamilyViewerPanel.nameAndTerm(person)).font(.subheadline)
                        }
                    }
                    .accessibilityInputLabels([person.shownName])
                }
                if let slug = FamilyAccessRules.nonEmpty(finding.storySlug) {
                    Button("Read the story") { openStory(slug) }
                        .buttonStyle(.bordered)
                }
                if hasDNALink {
                    Button("What this means for your DNA") { openDNA() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func openPerson(_ person: FHPerson) {
        nav.pushLibrary(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))
    }

    private func openStory(_ slug: String) {
        nav.pushLibrary(.family(.story(slug: slug, title: "")))
    }

    private func openDNA() {
        nav.pushLibrary(.family(.dna(forId: nil)))
    }
}
