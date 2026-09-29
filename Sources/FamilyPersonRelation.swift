import SwiftUI
import UIKit

// MARK: - Family history: a person's life and how you're related (Sep 29 2026)
//
// Split from FamilyPersonScreen.swift (DESIGN 4.11: small files).

// MARK: - Life in a nutshell

struct FamilyNutshellSection: View {
    let page: FHPersonPage

    var body: some View {
        if page.nutshell != nil || page.livedThrough != nil {
            VStack(alignment: .leading, spacing: 8) {
                FamilyHeading(text: "Life in a nutshell", level: .h2)
                if let nutshell = page.nutshell, let text = nutshell.text {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(nutshell.spokenOrText)
                }
                if let lived = FamilyAccessRules.nonEmpty(page.livedThrough) {
                    Text(lived)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - How you're related

struct FamilyRelationSection: View {
    let relation: FHRelationBlock

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyHeading(text: "How you're related", level: .h2)
            if let term = FamilyAccessRules.nonEmpty(relation.term) {
                Text(term).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let chain = FamilyAccessRules.nonEmpty(relation.chain) {
                Text(chain).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if relation.ladder.count > 1 {
                FamilyLadder(steps: relation.ladder)
            }
            if !relation.pathPeople.isEmpty {
                FamilyPathFaces(people: relation.pathPeople)
            }
            if let path = FamilyAccessRules.nonEmpty(relation.pathText) {
                Text(path).fixedSize(horizontal: false, vertical: true)
            }
            steps
            if let dna = FamilyAccessRules.nonEmpty(relation.dnaLine) {
                Text(dna).fixedSize(horizontal: false, vertical: true)
            }
            if let details = FamilyAccessRules.nonEmpty(relation.details) {
                DisclosureGroup("Details for DNA fans", isExpanded: $showDetails) {
                    Text(details)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// The path's people as links, in order.
    @ViewBuilder
    private var steps: some View {
        if relation.pathPeople.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                FamilyHeading(text: "Steps", level: .h3)
                ForEach(Array(relation.pathPeople.enumerated()), id: \.offset) { pair in
                    FamilyPersonRow(person: pair.element)
                }
            }
        }
    }
}

/// "You > Mom > Grandma > Her dad": a drawing for sight (the path's words
/// say the same thing), hidden from VoiceOver.
struct FamilyLadder: View {
    let steps: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 {
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(pair.element)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The small faces from you to them: a drawing, hidden from VoiceOver (the
/// path's words and the Steps list carry it).
struct FamilyPathFaces: View {
    let people: [FHPerson]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(people.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 14, height: 2)
                    }
                    FamilyPhoto(image: pair.element.face, size: .f, drawn: 40,
                                initials: pair.element.initials ?? "", side: pair.element.sideKind, circle: true)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityHidden(true)
    }
}
