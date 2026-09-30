import SwiftUI
import UIKit

// MARK: - Family history: your DNA (Sep 29 2026)
//
// DESIGN 1.7, one GET /dna, every word the server's. Top to bottom:
//  1. For the owner's full brothers and sisters, her test first: the
//     sentence that it counts for them too, then big cards in plain words
//     with faces and proof words ("12 of Ada's DNA cousins descend from the
//     family of your grandparents ..."). Half-siblings and descendants of a
//     tested line see only the cards about their own ancestors; guests and
//     relatives by marriage get no test section at all (the server decides).
//  2. Family mysteries behind their heads-up and a Show button.
//  3. "Details for DNA fans", collapsed: the method, the bands, the caveats,
//     each cluster and (when the research sends them) its matches.
//  4. Where your DNA comes from, on paper: the fan from the grandparents,
//     generation 1 to 7 (FamilyDNAFan.swift), and the ancestors named in it.
//  5. Where they were born, in counts (never percentages, never a chart).
//  6. Born across the ocean.
//  7. How much DNA you share with a relative, on average.
//  8. The footnote.
// VoiceOver: each card is ONE element with Open {person} in the Actions
// rotor; the fan is ONE adjustable element (swipe up or down for another
// generation).

struct FamilyDNAScreen: View {
    let apiClient: KadeAPIClient
    /// The viewer, their spouse or a child (changes only the on-paper parts).
    let forId: String?

    @State private var dna: FHDNA?
    @State private var failure: String?

    init(apiClient: KadeAPIClient, forId: String?) {
        self.apiClient = apiClient
        self.forId = forId
        _dna = State(initialValue: FamilyHistoryService.shared.cachedDNA(forId: forId))
    }

    private var title: String {
        FamilyAccessRules.nonEmpty(dna?.title) ?? "Your DNA"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                FamilyHeading(text: title, level: .h1, focusOnArrival: true)
                content
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
    }

    @ViewBuilder
    private var content: some View {
        if let dna {
            sections(dna)
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    @ViewBuilder
    private func sections(_ dna: FHDNA) -> some View {
        Group {
            if let follows = FamilyAccessRules.nonEmpty(dna.follows) {
                Text(follows)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let test = dna.test {
                FamilyDNATestSection(test: test, screenTitle: title)
            }
            if let paper = dna.paper, !paper.generations.isEmpty {
                FamilyPaperSection(paper: paper)
            }
        }
        Group {
            if let places = dna.birthplaces, !places.rows.isEmpty || !places.byGen.isEmpty {
                FamilyBirthplacesSection(birthplaces: places)
            }
            if let abroad = dna.abroad {
                FamilyAbroadSection(abroad: abroad)
            }
            if let compare = dna.compare, !compare.averages.isEmpty {
                FamilyCompareSection(compare: compare)
            }
            if let footnote = FamilyAccessRules.nonEmpty(dna.test?.footnote) {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func load(force: Bool) async {
        if !force, dna != nil { return }
        do {
            let fresh = try await FamilyHistoryService.shared.dna(forId: forId)
            dna = fresh
            failure = nil
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if dna == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }
}

// MARK: - The owner's test

/// What the owner's DNA test found, said for this viewer: the sentence, the
/// cards, the family mysteries behind their heads-up, and the details.
struct FamilyDNATestSection: View {
    let test: FHDNATest
    let screenTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = FamilyAccessRules.nonEmpty(test.title), title != screenTitle {
                FamilyHeading(text: title, level: .h2)
            }
            if let intro = FamilyAccessRules.nonEmpty(test.intro) {
                Text(intro)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(test.cards.enumerated()), id: \.offset) { pair in
                FamilyFindingCard(finding: pair.element.asFinding)
            }
            if let mysteries = test.mysteries, !mysteries.cards.isEmpty {
                FamilyHeadsUpGate(title: "Family mysteries",
                                  headsUp: FamilyAccessRules.nonEmpty(mysteries.headsUp) ?? "This part may be news to some of the family.",
                                  findings: mysteries.cards.map { $0.asFinding })
            }
            if let details = test.details, details.hasAnything {
                FamilyDNADetails(details: details)
            }
        }
    }
}

extension FHDetails {
    var hasAnything: Bool { !rows.isEmpty || !caveats.isEmpty || !clusters.isEmpty }
}

/// "Details for DNA fans", collapsed: the method rows, the caveats, and
/// each cluster with its band, its size and its matches.
struct FamilyDNADetails: View {
    let details: FHDetails

    @State private var open = false

    private var title: String {
        FamilyAccessRules.nonEmpty(details.title) ?? "Details for DNA fans"
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(details.rows.enumerated()), id: \.offset) { pair in
                    Text(pair.element).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(details.caveats.enumerated()), id: \.offset) { pair in
                    Text(pair.element)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(details.clusters.enumerated()), id: \.offset) { pair in
                    FamilyClusterDetail(cluster: pair.element)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }
}

/// One cluster: its title, band and size, then a line per match.
struct FamilyClusterDetail: View {
    let cluster: FHCluster

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = FamilyAccessRules.nonEmpty(cluster.title) {
                FamilyHeading(text: title, level: .h3)
            }
            if let summary = summaryLine {
                Text(summary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(cluster.matches.enumerated()), id: \.offset) { pair in
                Text(Self.matchLine(pair.element))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "12 DNA cousins, about 90 to 400 cM".
    private var summaryLine: String? {
        var parts: [String] = []
        if let n = cluster.members {
            parts.append(n == 1 ? "1 DNA cousin" : "\(n) DNA cousins")
        }
        if let band = FamilyAccessRules.nonEmpty(cluster.band) {
            parts.append(band)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "Invented Match One, 120 cM shared, 6 segments".
    static func matchLine(_ match: FHMatch) -> String {
        var parts: [String] = []
        if let name = FamilyAccessRules.nonEmpty(match.name) { parts.append(name) }
        if let cM = match.cM { parts.append(FHText.number(cM) + " cM shared") }
        if let segments = match.segments { parts.append(segments == 1 ? "1 segment" : "\(segments) segments") }
        if let note = FamilyAccessRules.nonEmpty(match.note) { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Where they were born, born abroad, how much you share

/// Birthplaces in counts ("9 in {state}"), for the generation the server
/// chose, with a menu of the other generations that have any. Never a
/// percentage and never a bar: this is not an ethnicity estimate.
struct FamilyBirthplacesSection: View {
    let birthplaces: FHBirthplaces

    @State private var chosenGen: Int?

    private var choices: [FHBirthplaces] {
        birthplaces.byGen.isEmpty ? [birthplaces] : birthplaces.byGen
    }

    private var shown: FHBirthplaces {
        if let chosenGen, let found = choices.first(where: { $0.gen == chosenGen }) { return found }
        return birthplaces
    }

    var body: some View {
        let entry: FHBirthplaces = shown
        VStack(alignment: .leading, spacing: 10) {
            FamilyHeading(text: "Where they were born", level: .h2)
            if choices.count > 1 {
                generationMenu
            }
            if let title = FamilyAccessRules.nonEmpty(entry.title) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(entry.rows.enumerated()), id: \.offset) { pair in
                Text(Self.rowWords(pair.element))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let unknown = entry.unknown, unknown > 0 {
                Text("\(unknown) not known yet")
                    .foregroundStyle(.secondary)
            }
            if let note = FamilyAccessRules.nonEmpty(birthplaces.note) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var generationMenu: some View {
        Menu {
            ForEach(Array(choices.enumerated()), id: \.offset) { pair in
                Button(pair.element.title ?? "Generation \(pair.element.gen ?? 0)") {
                    chosenGen = pair.element.gen
                    FamilyAnnounce.say(pair.element.spoken ?? pair.element.text ?? "")
                }
            }
        } label: {
            Label("Choose a generation", systemImage: "list.number")
        }
        .font(.subheadline)
    }

    /// "9 in {state}".
    static func rowWords(_ row: FHBirthplaceRow) -> String {
        let place: String = row.place ?? ""
        guard let count = row.count else { return place }
        return "\(count) in \(place)"
    }
}

/// "4 of your ancestors were born outside the United States", with a row
/// for each (the person, and where and when they were born).
struct FamilyAbroadSection: View {
    let abroad: FHAbroad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyHeading(text: "Born across the ocean", level: .h2)
            if let text = FamilyAccessRules.nonEmpty(abroad.text) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(abroad.spoken ?? text)
            }
            ForEach(Array(abroad.rows.enumerated()), id: \.offset) { pair in
                row(pair.element)
            }
        }
    }

    @ViewBuilder
    private func row(_ row: FHAbroadRow) -> some View {
        if let person = row.person {
            VStack(alignment: .leading, spacing: 2) {
                FamilyPersonRow(person: person, spoken: Self.sentence(person, row.text))
                if let text = FamilyAccessRules.nonEmpty(row.text) {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 56)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    static func sentence(_ person: FHPerson, _ text: String?) -> String {
        guard let text = FamilyAccessRules.nonEmpty(text) else { return person.spokenOrName }
        return person.spokenOrName + " " + text
    }
}

/// How much DNA you share with a relative, on paper, on average.
struct FamilyCompareSection: View {
    let compare: FHCompare

    @State private var showDetails = false

    private var hasDetails: Bool { compare.averages.contains { FamilyAccessRules.nonEmpty($0.details) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyHeading(text: FamilyAccessRules.nonEmpty(compare.title) ?? "How much DNA you share with a relative", level: .h2)
            ForEach(Array(compare.averages.enumerated()), id: \.offset) { pair in
                Text(pair.element.shownText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasDetails {
                DisclosureGroup("Details for DNA fans", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(compare.averages.enumerated()), id: \.offset) { pair in
                            if let details = FamilyAccessRules.nonEmpty(pair.element.details) {
                                Text(details).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let note = FamilyAccessRules.nonEmpty(compare.note) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
