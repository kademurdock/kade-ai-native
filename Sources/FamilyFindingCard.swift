import SwiftUI
import UIKit

// MARK: - Family history: research findings (Sep 29 2026)
//
// A person's findings, and the one finding card that the person page, the
// DNA screen, Discoveries and Family mysteries share: the proof words always
// with it, the Research pill unless records prove it. Family mysteries open
// behind a heads-up and a Show button (FamilyHeadsUpGate), wherever they are.

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
    /// Where VoiceOver can be sent (the first card after Show, a new page).
    var focus: AccessibilityFocusState<String?>.Binding? = nil
    var focusKey: String = ""
    /// Discoveries: "What this means for your DNA" on a DNA finding.
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

// MARK: - Behind a heads-up

/// Family mysteries (who some ancestors' fathers were) never open by
/// themselves: first the server's heads-up line, then Show. After Show the
/// cards appear below, the count is said, and VoiceOver moves to the first
/// card. Hide puts them away again. Children see the same as adults (her
/// decision); this is a courtesy, not a lock.
struct FamilyHeadsUpGate: View {
    let title: String
    let headsUp: String
    let findings: [FHFinding]
    var level: AccessibilityHeadingLevel = .h2
    /// Open from the start (the Family mysteries screen, after its own Show).
    var startsOpen: Bool = false

    @State private var shown: Bool?
    @AccessibilityFocusState private var focusKey: String?

    private var isShown: Bool { shown ?? startsOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FamilyHeading(text: title, level: level)
            Text(headsUp)
                .fixedSize(horizontal: false, vertical: true)
            toggle
            if isShown {
                ForEach(Array(findings.enumerated()), id: \.offset) { pair in
                    FamilyFindingCard(finding: pair.element, focus: $focusKey, focusKey: Self.key(pair.offset))
                }
            }
        }
    }

    private var toggle: some View {
        Button {
            reveal(!isShown)
        } label: {
            Label(isShown ? "Hide" : "Show", systemImage: isShown ? "eye.slash" : "eye")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(isShown ? "Hide " + title : "Show " + title)
        .accessibilityInputLabels([isShown ? "Hide" : "Show"])
    }

    static func key(_ index: Int) -> String { "heads-up-\(index)" }

    private func reveal(_ open: Bool) {
        shown = open
        guard open else { return }
        let n: Int = findings.count
        FamilyAnnounce.say(n == 1 ? "1 card shown." : "\(n) cards shown.")
        guard n > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            focusKey = Self.key(0)
        }
    }
}
