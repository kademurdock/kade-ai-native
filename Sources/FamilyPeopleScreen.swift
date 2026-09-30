import SwiftUI
import UIKit

// MARK: - Family history: everyone in the tree (Sep 29 2026)
//
// DESIGN 1.11. Three groups (Ancestors under generation headings, Blood
// relatives nearest first, By marriage), 60 people at a time from
// GET /people; "Next 60" and "Previous 60" replace the page, say which
// people show ("Showing 61 to 120 of 412") and move VoiceOver to the first
// of them. Search (GET /search?q=) says how many were found ("12 people
// found"). Each person is ONE row with the server's sentence; it opens their
// page, and "Centre the tree here" is in the Actions rotor. Never a lazy
// stack: a page is at most 60 rows.

/// One of the three groups (the server's `group` key, and its name).
struct FamilyPeopleGroup: Identifiable {
    let key: String
    let title: String

    var id: String { key }
}

struct FamilyPeopleScreen: View {
    let apiClient: KadeAPIClient

    @Environment(\.kadeNavigation) private var nav
    @State private var group = "ancestor"
    @State private var from = 0
    @State private var page: FHPeople?
    @State private var failure: String?
    @State private var query = ""
    @State private var found: FHPeople?
    @State private var sayPage = false
    @AccessibilityFocusState private var focusKey: String?

    private let pageSize = 60

    static let groups: [FamilyPeopleGroup] = [
        FamilyPeopleGroup(key: "ancestor", title: "Ancestors"),
        FamilyPeopleGroup(key: "blood", title: "Blood relatives"),
        FamilyPeopleGroup(key: "marriage", title: "By marriage"),
    ]

    private var loadKey: String { "\(group)|\(from)" }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FamilyHeading(text: "Everyone in the tree", level: .h1, focusOnArrival: true)
                if searching {
                    searchResults
                } else {
                    groupPicker
                    listContent
                }
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Everyone in the tree")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search the tree by name")
        .task(id: loadKey) { await load() }
        .task(id: query) { await search() }
        .refreshable { await load() }
    }

    // MARK: Groups and pages

    private var groupBinding: Binding<String> {
        Binding(get: { group }, set: { (picked: String) in
            guard picked != group else { return }
            group = picked
            from = 0
            sayPage = true
        })
    }

    private var groupPicker: some View {
        Picker("Show", selection: groupBinding) {
            ForEach(Self.groups) { choice in
                Text(choice.title).tag(choice.key)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var listContent: some View {
        if let page {
            pageRows(page)
            if page.prev != nil || page.next != nil {
                FamilyPageButtons(size: pageSize,
                                  hasPrevious: page.prev != nil,
                                  hasNext: page.next != nil,
                                  previous: { turn(to: page.prev) },
                                  next: { turn(to: page.next) })
            }
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load() }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    @ViewBuilder
    private func pageRows(_ page: FHPeople) -> some View {
        if page.sections.isEmpty && page.people.isEmpty {
            Text("Nobody in this group yet.")
                .foregroundStyle(.secondary)
        } else if page.sections.isEmpty {
            ForEach(Array(page.people.enumerated()), id: \.offset) { pair in
                personRow(pair.element, spoken: nil)
            }
        } else {
            ForEach(Array(page.sections.enumerated()), id: \.offset) { pair in
                section(pair.element)
            }
        }
    }

    private func section(_ section: FHPeopleSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading = FamilyAccessRules.nonEmpty(section.heading) {
                FamilyHeading(text: heading, level: section.level == 3 ? .h3 : .h2)
            }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { pair in
                if let person = pair.element.person {
                    personRow(person, spoken: pair.element.spoken)
                }
            }
        }
    }

    private func personRow(_ person: FHPerson, spoken: String?) -> some View {
        FamilyPersonRow(person: person, spoken: spoken, centre: { (chosen: FHPerson) in
            nav.pushLibrary(.family(.tree(focus: chosen.id, name: chosen.shownName)))
        })
        .accessibilityFocused($focusKey, equals: Self.rowKey(person.id))
    }

    static func rowKey(_ id: String) -> String { "people-" + id }

    private func turn(to start: Int?) {
        guard let start else { return }
        sayPage = true
        from = max(0, start)
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        if let found {
            Text(FamilyAccessRules.nonEmpty(found.text) ?? Self.countWords(found.people.count))
                .font(.headline)
                .accessibilityLabel(FamilyAccessRules.nonEmpty(found.spoken) ?? Self.countWords(found.people.count))
            ForEach(Array(found.people.prefix(pageSize).enumerated()), id: \.offset) { pair in
                personRow(pair.element, spoken: nil)
            }
        } else {
            FamilyLoadingLine(text: "Searching")
        }
    }

    static func countWords(_ n: Int) -> String {
        if n == 0 { return "No one found" }
        return n == 1 ? "1 person found" : "\(n) people found"
    }

    // MARK: Loading

    @MainActor
    private func load() async {
        do {
            let fresh = try await FamilyHistoryService.shared.people(group: group, from: from)
            show(fresh)
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if page == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }

    /// A new page or group: say which people show, then move to the first.
    private func show(_ fresh: FHPeople) {
        page = fresh
        failure = nil
        guard sayPage else { return }
        sayPage = false
        let start: Int = fresh.from ?? 0
        let count: Int = fresh.count ?? fresh.people.count
        let words: String = FamilyAccessRules.nonEmpty(fresh.pageSpoken)
            ?? FamilyPaging.spoken(start..<(start + count), total: fresh.total ?? count)
        FamilyAnnounce.say(words)
        let firstId: String? = fresh.sections.first(where: { !$0.rows.isEmpty })?.rows.first?.person?.id ?? fresh.people.first?.id
        guard let firstId else { return }
        let key: String = Self.rowKey(firstId)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            focusKey = key
        }
    }

    /// Waits for her to stop typing, then asks; says how many were found.
    @MainActor
    private func search() async {
        let asked: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else {
            found = nil
            return
        }
        do {
            try await Task.sleep(nanoseconds: 450_000_000)
        } catch {
            return
        }
        do {
            let result = try await FamilyHistoryService.shared.search(asked)
            if Task.isCancelled { return }
            found = result
            FamilyAnnounce.say(FamilyAccessRules.nonEmpty(result.spoken) ?? Self.countWords(result.people.count))
        } catch {
            if LibraryLoad.cancelled(error) || Task.isCancelled { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            FamilyAnnounce.say(message)
        }
    }
}
