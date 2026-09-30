import SwiftUI
import UIKit

// MARK: - Family history: pieces the family screens share (Sep 29 2026)
//
// - FamilyMemory: the few things kept per account on this phone (the version
//   Home last showed, the tree's view), under the account's own id.
// - FamilyAnnounce: news said at normal priority, queued behind what
//   VoiceOver is already saying (KadeAnnounce.high is only for "now").
// - FamilyPersonRow: one person in a list, ONE element with the server's
//   sentence, opening the person's page.
// - FamilyFaceButton: a face (or initials) with a first name under it, for
//   the Home arc, the tree's trail and the relation path. A real button for
//   sight, Voice Control and Switch Control; the screens hide these while
//   VoiceOver runs, because the card they sit in carries the same actions.
// - FamilyPageButtons: "Previous 48" and "Next 48", never a lazy stack.
// Every word shown is the server's; the few fixed words here are headings
// and button names.

// MARK: - Per-account memory

@MainActor
enum FamilyMemory {
    /// "kade.family.<name>.<account>", or nil before anyone is signed in.
    static func key(_ name: String) -> String? {
        guard let userId = FamilySession.shared.userId, !userId.isEmpty else { return nil }
        return "kade.family." + name + "." + FamilyCacheNames.safe(userId)
            + FamilyCacheNames.archiveSuffix(FamilyHistoryService.shared.archiveId)
    }

    static func string(_ name: String) -> String? {
        guard let key = key(name) else { return nil }
        return UserDefaults.standard.string(forKey: key)
    }

    static func set(_ value: String?, _ name: String) {
        guard let key = key(name) else { return }
        if let value, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The family-history version Home last showed this account ("New since
    /// your last visit" counts from it).
    static let seenVersion = "seen"
    /// Climb, Chart or List.
    static let treeMode = "treeMode"
    /// The game's best score ("3/5").
    static let playBest = "playBest"
}

// MARK: - Saying things

@MainActor
enum FamilyAnnounce {
    /// News at normal priority: queued, never cutting off what is being said.
    static func say(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: words)
    }
}

// MARK: - One person in a list

/// A person as a row: face or initials, name, years and the viewer's term,
/// the side in words (its colour is only a second cue), and the Research
/// pill. ONE element whose label is the server's sentence; it opens the
/// person's page. `centre`, when given, adds "Centre the tree here" to the
/// Actions rotor (the tree's own list re-centres in place).
struct FamilyPersonRow: View {
    let person: FHPerson
    /// The row's own sentence when the server wrote one for this list.
    var spoken: String? = nil
    /// "stepfather", "adoptive mother", "probable father".
    var kindText: String? = nil
    var centre: ((FHPerson) -> Void)? = nil

    @ScaledMetric(relativeTo: .body) private var faceSize: CGFloat = 44

    var body: some View {
        NavigationLink(value: HomeRoute.library(.family(.person(route)))) {
            rowLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sentence)
        .accessibilityInputLabels(inputLabels)
        .accessibilityActions {
            if let centre {
                Button("Centre the tree here") { centre(person) }
            }
        }
    }

    private var route: FamilyPersonRoute {
        FamilyPersonRoute(id: person.id, name: person.shownName)
    }

    private var sentence: String {
        let said: String = FamilyAccessRules.nonEmpty(spoken) ?? person.spokenOrName
        guard let kind = FamilyAccessRules.nonEmpty(kindText) else { return said }
        return said + " " + kind + "."
    }

    private var inputLabels: [String] {
        [person.shownName, person.term ?? ""].filter { !$0.isEmpty }
    }

    /// "1930–1999 · your grandfather" (sight only; VoiceOver hears the sentence).
    private var detailLine: String? {
        let term: String? = FamilyAccessRules.nonEmpty(kindText) ?? FamilyAccessRules.nonEmpty(person.term)
        let bits: [String] = [person.years ?? person.lifespan ?? "", term ?? ""].filter { !$0.isEmpty }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            FamilyPhoto(image: person.face, size: .f, drawn: faceSize,
                        initials: person.initials ?? "", side: person.sideKind, circle: true)
            FamilyPersonWords(person: person, detail: detailLine)
            if person.research != nil {
                FamilyResearchPill()
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A person's name, detail line and side, for sight.
struct FamilyPersonWords: View {
    let person: FHPerson
    let detail: String?
    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        let tint: Color = FamilySideColor.color(person.sideKind, contrast: highContrast)
        VStack(alignment: .leading, spacing: 2) {
            Text(person.shownName)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let side = FamilyAccessRules.nonEmpty(person.sideText) {
                Text(side)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - A face with a name under it

/// One face (or initials in the side colour) with a first name under it.
/// Voice Control answers to "Tap Ada"; the label is the server's sentence.
struct FamilyFaceButton: View {
    let person: FHPerson
    let size: CGFloat
    var showsName: Bool = true
    var spoken: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                FamilyPhoto(image: person.face, size: .f, drawn: size,
                            initials: person.initials ?? "", side: person.sideKind, circle: true)
                if showsName {
                    Text(firstName)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: size + 16)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FamilyAccessRules.nonEmpty(spoken) ?? person.spokenOrName)
        .accessibilityInputLabels(inputLabels)
    }

    private var firstName: String {
        FamilyAccessRules.nonEmpty(person.first) ?? person.shownName
    }

    private var inputLabels: [String] {
        [person.first ?? "", person.shownName, person.term ?? ""].filter { !$0.isEmpty }
    }
}

// MARK: - Pages of a long list

/// "Previous 48" and "Next 48" (pages are replaced, never appended). Both
/// stay visible to VoiceOver: they are the only way to the next page.
struct FamilyPageButtons: View {
    let size: Int
    let hasPrevious: Bool
    let hasNext: Bool
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: previous) {
                Label("Previous \(size)", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasPrevious)
            Button(action: next) {
                Label("Next \(size)", systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasNext)
        }
    }
}

// MARK: - A plain card

extension View {
    /// The family screens' card: a rounded panel, solid under Reduce
    /// Transparency and Increase Contrast (kadeGlass does both).
    func familyCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kadeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
