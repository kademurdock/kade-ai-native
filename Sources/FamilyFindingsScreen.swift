import SwiftUI
import UIKit

// MARK: - Family history: Discoveries and Family mysteries (Sep 29 2026)
//
// DESIGN 1.10, in the server's words:
// - Discoveries (GET /findings): what the research found that is not
//   sensitive, one card each: the title and plain words, the proof words
//   (with the Research pill unless records prove it), the people as faces
//   with their terms, "Based on 8 sources: ...", Read the story, and for a
//   DNA finding "What this means for your DNA" (the DNA screen). The Family
//   mysteries row follows when this account may see them.
// - Family mysteries (GET /findings?group=mysteries): who some ancestors'
//   fathers were. The heading, the server's heads-up line and a Show button
//   come first; the same cards follow after Show. Children see the same as
//   adults (her decision); the heads-up is a courtesy.
// VoiceOver: each card is ONE element with Open {person}, Read the story
// and What this means for your DNA in the Actions rotor.

struct FamilyFindingsScreen: View {
    let apiClient: KadeAPIClient
    /// The Family mysteries screen rather than Discoveries.
    let mysteries: Bool

    @State private var answer: FHFindings?
    @State private var failure: String?
    @AccessibilityFocusState private var focusKey: String?

    private var title: String {
        if mysteries {
            return FamilyAccessRules.nonEmpty(answer?.title) ?? "Family mysteries"
        }
        return "Discoveries"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !mysteries {
                    FamilyHeading(text: title, level: .h1, focusOnArrival: true)
                }
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
        if let answer {
            if mysteries {
                mysteriesContent(answer)
            } else {
                discoveriesContent(answer)
            }
        } else if let failure {
            if mysteries {
                FamilyHeading(text: title, level: .h1, focusOnArrival: true)
            }
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            if mysteries {
                FamilyHeading(text: title, level: .h1, focusOnArrival: true)
            }
            FamilyLoadingLine()
        }
    }

    // MARK: Discoveries

    @ViewBuilder
    private func discoveriesContent(_ answer: FHFindings) -> some View {
        let cards: [FHFinding] = answer.discoveries.isEmpty ? answer.findings : answer.discoveries
        if cards.isEmpty {
            Text("There are no discoveries to show yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(Array(cards.enumerated()), id: \.offset) { pair in
            FamilyFindingCard(finding: pair.element, focus: $focusKey, focusKey: "discovery-\(pair.offset)", showsDNALink: true)
        }
        if let link = answer.mysteries {
            FamilyTileRow(tile: Self.mysteriesTile(link), icon: FamilyHomeIcons.symbol("mysteries"))
                .buttonStyle(KadeCardButtonStyle())
        }
    }

    /// The Family mysteries row: its title, and the heads-up as its detail.
    static func mysteriesTile(_ link: FHMysteriesLink) -> FHTile {
        FHTile(key: "mysteries",
               title: FamilyAccessRules.nonEmpty(link.title) ?? "Family mysteries",
               detail: link.headsUp,
               hint: "Opens behind a heads-up.",
               enabled: true,
               open: FHOpen(to: "mysteries"))
    }

    // MARK: Family mysteries

    @ViewBuilder
    private func mysteriesContent(_ answer: FHFindings) -> some View {
        if answer.available == false || answer.findings.isEmpty {
            FamilyHeading(text: title, level: .h1, focusOnArrival: true)
            Text("There are no family mysteries to show.")
                .foregroundStyle(.secondary)
        } else {
            FamilyHeadsUpGate(title: title,
                              headsUp: FamilyAccessRules.nonEmpty(answer.headsUp) ?? "This part may be news to some of the family.",
                              findings: answer.findings,
                              level: .h1,
                              focusOnArrival: true)
        }
    }

    // MARK: Loading

    @MainActor
    private func load(force: Bool) async {
        if !force, answer != nil { return }
        do {
            let fresh = try await FamilyHistoryService.shared.findings(group: mysteries ? "mysteries" : nil)
            answer = fresh
            failure = nil
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if answer == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }
}
