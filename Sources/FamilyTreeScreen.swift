import SwiftUI
import UIKit

// MARK: - Family history: the family tree (Sep 29 2026)
//
// DESIGN 1.3 and 4.5. One GET /tree slice (the server lays the tree out in
// box units and writes every sentence), drawn three ways:
// - Climb (FamilyTreeClimb.swift): the phone's picture. The focus person is
//   a big card with their two parents above; tap a parent to climb.
// - Chart (FamilyTreeChart.swift): the whole slice as boxes and lines.
// - List (below): generation headings, one row per person, the VoiceOver
//   default.
// The choice is kept per account. Defaults: List while VoiceOver runs, Chart
// on a wide screen, else Climb.
//
// "Centre the tree here" loads the new slice first, then moves the boxes
// (a spring, or a short cross-fade when motion is not allowed), says the
// server's summary ("Centred on your great-grandmother, Ada Example. 25
// people shown.") and then moves VoiceOver to the focus.

enum FamilyTreeMode: String, CaseIterable, Identifiable {
    case climb, chart, list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .climb: return "Climb"
        case .chart: return "Chart"
        case .list: return "List"
        }
    }
}

struct FamilyTreeScreen: View {
    let apiClient: KadeAPIClient
    let focus: String?
    let name: String

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @KadeMotionPolicy private var motionAllowed: Bool
    /// The person the slice is centred on (nil = the viewer).
    @State private var centre: String?
    @State private var tree: FHTree?
    @State private var failure: String?
    @State private var up = 3
    @State private var down = 1
    @State private var scale: FamilyTreeScale = .normal
    /// Chosen here or remembered for this account; nil = the default.
    @State private var chosenMode: FamilyTreeMode?
    /// Moves on at every new slice (the chart animates and scrolls on it).
    @State private var revision = 0
    @State private var announceNext = false
    @AccessibilityFocusState private var focusedKey: String?

    init(apiClient: KadeAPIClient, focus: String?, name: String) {
        self.apiClient = apiClient
        self.focus = focus
        self.name = name
        _centre = State(initialValue: focus)
        _tree = State(initialValue: FamilyHistoryService.shared.cachedTree(focus: focus, up: 3, down: 1))
        _chosenMode = State(initialValue: FamilyTreeMode(rawValue: FamilyMemory.string(FamilyMemory.treeMode) ?? ""))
    }

    private var title: String {
        FamilyAccessRules.nonEmpty(name) ?? "Your family tree"
    }

    private var mode: FamilyTreeMode {
        if let chosenMode { return chosenMode }
        if voiceOverOn { return .list }
        if sizeClass == .regular || verticalSizeClass == .compact { return .chart }
        return .climb
    }

    private var modeBinding: Binding<FamilyTreeMode> {
        Binding(get: { mode }, set: { (picked: FamilyTreeMode) in
            chosenMode = picked
            FamilyMemory.set(picked.rawValue, FamilyMemory.treeMode)
        })
    }

    private var loadKey: String { "\(centre ?? "")|\(up)|\(down)" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            modeContent
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { await load() }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyHeading(text: title, level: .h1, focusOnArrival: true)
            Picker("Show the tree as", selection: modeBinding) {
                ForEach(FamilyTreeMode.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            if mode == .chart {
                chartMenus
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var chartMenus: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Box size", selection: $scale) {
                    Text("Fit").tag(FamilyTreeScale.fit)
                    Text("Normal").tag(FamilyTreeScale.normal)
                    Text("Large").tag(FamilyTreeScale.large)
                }
            } label: {
                Label("Box size", systemImage: "textformat.size")
            }
            Menu {
                Picker("Generations up", selection: $up) {
                    ForEach([3, 4, 6, 8], id: \.self) { n in
                        Text(Self.depthWords(n, "up")).tag(n)
                    }
                }
                Picker("Generations down", selection: $down) {
                    ForEach([1, 2, 4], id: \.self) { n in
                        Text(Self.depthWords(n, "down")).tag(n)
                    }
                }
            } label: {
                Label("Show more generations", systemImage: "arrow.up.and.down")
            }
        }
        .font(.subheadline)
    }

    /// "3 generations up", "1 generation down".
    static func depthWords(_ n: Int, _ way: String) -> String {
        (n == 1 ? "1 generation " : "\(n) generations ") + way
    }

    @ViewBuilder
    private var modeContent: some View {
        if let tree {
            switch mode {
            case .climb:
                ScrollView {
                    FamilyTreeClimb(tree: tree, focus: $focusedKey) { person in
                        recentre(person, announce: false)
                    }
                    .padding()
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            case .chart:
                chart(tree)
            case .list:
                ScrollView {
                    FamilyTreeList(tree: tree, focus: $focusedKey) { person in
                        recentre(person, announce: true)
                    }
                    .padding()
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            ScrollView {
                waiting
                    .padding()
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func chart(_ tree: FHTree) -> some View {
        if let layout = tree.layout, !layout.boxes.isEmpty {
            FamilyTreeChart(tree: tree, layout: layout, scale: scale, revision: revision, focus: $focusedKey) { person in
                recentre(person, announce: true)
            }
        } else {
            ScrollView {
                Text("This tree has no chart to draw yet. The List shows everyone in it.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var waiting: some View {
        if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load() }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    // MARK: Loading and re-centring

    /// Centres the tree on someone else: the new slice loads first (the task
    /// follows `centre`), then everything moves at once.
    private func recentre(_ person: FHPerson, announce: Bool) {
        guard !person.id.isEmpty else { return }
        if person.id == (tree?.focus ?? "") && centre != nil {
            if announce { sayCentred(tree) }
            return
        }
        announceNext = announce
        centre = person.id
    }

    @MainActor
    private func load() async {
        failure = nil
        if let cached = FamilyHistoryService.shared.cachedTree(focus: centre, up: up, down: down) {
            show(cached)
            return
        }
        do {
            let fresh = try await FamilyHistoryService.shared.tree(focus: centre, up: up, down: down)
            show(fresh)
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if tree == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }

    private func show(_ fresh: FHTree) {
        if tree != fresh {
            let move: Animation = motionAllowed ? Animation.spring(response: 0.45, dampingFraction: 0.85) : Animation.easeInOut(duration: 0.2)
            withAnimation(move) {
                tree = fresh
                revision += 1
            }
        }
        if announceNext {
            announceNext = false
            sayCentred(fresh)
        }
    }

    /// The server's summary, then VoiceOver moves to the focus.
    private func sayCentred(_ shown: FHTree?) {
        guard let shown else { return }
        let words: String = FamilyAccessRules.nonEmpty(shown.summary?.spoken) ?? shown.summary?.text ?? ""
        FamilyAnnounce.say(words)
        let target: String? = focusTarget(shown)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            focusedKey = target
        }
    }

    private func focusTarget(_ shown: FHTree) -> String? {
        switch mode {
        case .chart:
            return shown.layout?.boxes.first(where: { $0.role == "focus" })?.key
        case .climb:
            return FamilyTreeClimb.focusKey
        case .list:
            return FamilyTreeList.summaryKey
        }
    }
}

// MARK: - List

/// The tree as text: the summary, the legend, then generation headings
/// ("Parents", "Grandparents", ... "Brothers and sisters", "Spouses",
/// "Children"), each row ONE element with the server's sentence. Step,
/// adoptive and doubtful parents are listed under their child, with the kind
/// spelled out. Long generations show 60 at a time.
struct FamilyTreeList: View {
    let tree: FHTree
    var focus: AccessibilityFocusState<String?>.Binding
    let onCentre: (FHPerson) -> Void

    static let summaryKey = "tree-summary"
    private let pageSize = 60
    @State private var pages: [Int: Int] = [:]

    var body: some View {
        let extras: [String: [FHExtraParent]] = extrasByChild
        VStack(alignment: .leading, spacing: 14) {
            summary
            legend
            focusExtras(extras)
            ForEach(Array(tree.list.enumerated()), id: \.offset) { pair in
                section(pair.element, index: pair.offset, extras: extras)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let said = tree.summary {
            Text(said.text ?? "")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(said.spokenOrText)
                .accessibilityFocused(focus, equals: Self.summaryKey)
        }
    }

    @ViewBuilder
    private var legend: some View {
        if !tree.legend.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tree.legend) { row in
                    Text(row.text ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Extra parents by the child's person id.
    private var extrasByChild: [String: [FHExtraParent]] {
        let boxes: [FHTreeBox] = tree.layout?.boxes ?? []
        var out: [String: [FHExtraParent]] = [:]
        for extra in tree.layout?.extraParents ?? [] {
            guard let key = extra.childKey,
                  let child = boxes.first(where: { $0.key == key })?.personId else { continue }
            out[child, default: []].append(extra)
        }
        return out
    }

    private var focusId: String? {
        tree.layout?.boxes.first(where: { $0.role == "focus" })?.personId ?? tree.focus
    }

    @ViewBuilder
    private func focusExtras(_ extras: [String: [FHExtraParent]]) -> some View {
        if let focusId, let list = extras[focusId], !list.isEmpty {
            extraRows(list)
        }
    }

    private func extraRows(_ list: [FHExtraParent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.enumerated()), id: \.offset) { pair in
                if let person = pair.element.person {
                    FamilyPersonRow(person: person, kindText: pair.element.kindText, centre: onCentre)
                        .padding(.leading, 24)
                }
            }
        }
    }

    private func section(_ section: FHPeopleSection, index: Int, extras: [String: [FHExtraParent]]) -> some View {
        let rows: [FHPersonRow] = section.rows.filter { $0.person != nil }
        let window: Range<Int> = FamilyPaging.window(total: rows.count, page: pages[index] ?? 0, size: pageSize)
        return VStack(alignment: .leading, spacing: 6) {
            FamilyHeading(text: section.heading ?? "", level: section.level == 3 ? .h3 : .h2)
            ForEach(Array(rows[window].enumerated()), id: \.offset) { pair in
                row(pair.element, section: index, extras: extras)
            }
            if rows.count > pageSize {
                FamilyPageButtons(size: pageSize,
                                  hasPrevious: window.lowerBound > 0,
                                  hasNext: window.upperBound < rows.count,
                                  previous: { turn(section: index, by: -1, rows: rows) },
                                  next: { turn(section: index, by: 1, rows: rows) })
            }
        }
    }

    @ViewBuilder
    private func row(_ row: FHPersonRow, section: Int, extras: [String: [FHExtraParent]]) -> some View {
        if let person = row.person {
            FamilyPersonRow(person: person, spoken: row.spoken, centre: onCentre)
                .accessibilityFocused(focus, equals: Self.rowKey(section: section, id: person.id))
            if let list = extras[person.id], !list.isEmpty {
                extraRows(list)
            }
        }
    }

    static func rowKey(section: Int, id: String) -> String {
        "tree-row-\(section)-\(id)"
    }

    /// A new page: say which people show, then move to the first of them.
    private func turn(section: Int, by step: Int, rows: [FHPersonRow]) {
        let current: Int = pages[section] ?? 0
        let last: Int = FamilyPaging.pages(total: rows.count, size: pageSize) - 1
        let next: Int = min(max(0, current + step), last)
        pages[section] = next
        let window: Range<Int> = FamilyPaging.window(total: rows.count, page: next, size: pageSize)
        FamilyAnnounce.say(FamilyPaging.spoken(window, total: rows.count))
        guard window.lowerBound < rows.count, let first = rows[window.lowerBound].person else { return }
        let key: String = Self.rowKey(section: section, id: first.id)
        let binding = focus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            binding.wrappedValue = key
        }
    }
}
