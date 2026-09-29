import SwiftUI
import UIKit

// MARK: - Family history: one person (Sep 29 2026)
//
// DESIGN 1.4, one GET /person/:id, every word the server's. Sections are
// headings (h2), top to bottom:
//  1. the header: the best picture (a slow drift only while motion is
//     allowed), the name (h1), "born a {surname}", other names, the years,
//     the viewer's term and side, the Research pill with its proof words;
//  2. Life in a nutshell, and what they lived through;
//  3. How you're related: the term, the plain chain, the generation ladder,
//     the path of faces (a drawing) with its words and a Steps list, and the
//     share of DNA on average ("Details for DNA fans" collapsed);
//  4. Pictures (FamilyPersonSections.swift): restored copies first with an
//     Original/Restored switch, one adjustable element under VoiceOver;
//  5. Life, 6. Family, 7. Records (collapsed, 10 at a time), 8. Grave
//     (collapsed), 9. Research findings, 10. Sources (collapsed).
// The toolbar: Centre the tree here, Add a memory, Share this picture.
//
// VoiceOver: the header is ONE heading element, the server's sentence
// ("Ada Example, 1850 to 1921. Your 2nd great-grandmother, Mom's side.
// Research finding, ..."), and VoiceOver starts on it. The route carries the
// name, so the heading is real before the page arrives. Closing the photo
// viewer hands VoiceOver back to what opened it.

struct FamilyPersonScreen: View {
    let apiClient: KadeAPIClient
    let route: FamilyPersonRoute

    @Environment(\.kadeNavigation) private var nav
    @State private var page: FHPersonPage?
    @State private var failure: String?
    @State private var viewer: FamilyViewerRequest?
    @State private var note: FamilyNoteRequest?
    @State private var share: ShareItem?
    /// What opened the viewer, so VoiceOver goes back there.
    @State private var returnKey: String?
    @State private var headingDone = false
    @AccessibilityFocusState private var focusKey: String?

    static let headingKey = "person-heading"

    init(apiClient: KadeAPIClient, route: FamilyPersonRoute) {
        self.apiClient = apiClient
        self.route = route
        _page = State(initialValue: FamilyHistoryService.shared.cachedPerson(route.id))
    }

    private var person: FHPerson? { page?.person }

    private var title: String {
        FamilyAccessRules.nonEmpty(person?.shownName) ?? FamilyAccessRules.nonEmpty(route.name) ?? "Family history"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FamilyPersonHeader(page: page, fallbackName: title, focus: $focusKey) { image in
                    openViewer([image], at: 0, from: Self.headingKey)
                }
                content
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .task { await arrive() }
        .refreshable { await load(force: true) }
        .background {
            Color.clear.fullScreenCover(item: $viewer, onDismiss: { returnFocus() }) { asked in
                FamilyPhotoViewer(request: asked)
            }
        }
        .sheet(item: $note) { asked in
            FamilyNoteSheet(request: asked)
        }
        .sheet(item: $share) { item in
            ShareSheet(item: item)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let page {
            sections(page)
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    @ViewBuilder
    private func sections(_ page: FHPersonPage) -> some View {
        Group {
            FamilyNutshellSection(page: page)
            if let relation = page.relation {
                FamilyRelationSection(relation: relation)
            }
            if let pictures = page.pictures, !pictures.items.isEmpty {
                FamilyPicturesStrip(items: pictures.items, total: pictures.total ?? pictures.items.count,
                                    first: firstName, personId: route.id, focus: $focusKey) { items, index in
                    openViewer(items, at: index, from: FamilyPicturesStrip.focusKey)
                }
            }
            if !page.life.isEmpty {
                FamilyLifeSection(rows: page.life)
            }
            if let family = page.family {
                FamilyFamilySection(family: family)
            }
        }
        Group {
            if !page.records.isEmpty {
                FamilyRecordsSection(records: page.records, focus: $focusKey) { image, key in
                    openViewer([image], at: 0, from: key)
                }
            }
            if let grave = page.grave {
                FamilyGraveSection(grave: grave, focus: $focusKey) { photos, index in
                    openViewer(photos, at: index, from: FamilyGraveSection.photoKey(index))
                }
            }
            if !page.findings.isEmpty {
                FamilyFindingsSection(findings: page.findings)
            }
            if !page.sources.isEmpty || page.withheld != nil {
                FamilySourcesSection(sources: page.sources, withheld: page.withheld)
            }
        }
    }

    private var firstName: String {
        FamilyAccessRules.nonEmpty(person?.first) ?? title
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    centreTree()
                } label: {
                    Label("Centre the tree here", systemImage: "tree")
                }
                Button {
                    addMemory()
                } label: {
                    Label("Add a memory", systemImage: "square.and.pencil")
                }
                if page?.share?.allowed == true, page?.header != nil {
                    Button {
                        Task { await shareHeader() }
                    } label: {
                        Label("Share this picture", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("More for " + title)
        }
    }

    private func centreTree() {
        nav.pushLibrary(.family(.tree(focus: route.id, name: title)))
    }

    private func addMemory() {
        note = FamilyNoteRequest(personId: route.id, kind: "memory", title: "Add a memory",
                                 prompt: "Do you know something about " + firstName + "?")
    }

    @MainActor
    private func shareHeader() async {
        guard let header = page?.header else { return }
        guard let file = await FamilyImageLoader.shared.shareFile(for: header) else {
            FamilyAnnounce.say("Could not get this picture to share. Try again in a moment.")
            return
        }
        share = ShareItem(fileURL: file)
    }

    // MARK: The viewer

    private func openViewer(_ items: [FHImage], at index: Int, from key: String) {
        guard !items.isEmpty else { return }
        returnKey = key
        viewer = FamilyViewerRequest(items: items, start: index)
    }

    /// Back from the viewer: VoiceOver returns to what opened it.
    private func returnFocus() {
        guard let key = returnKey else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            focusKey = key
        }
    }

    // MARK: Loading

    /// First arrival: the heading takes VoiceOver focus once, then the page loads.
    @MainActor
    private func arrive() async {
        if !headingDone {
            headingDone = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                focusKey = Self.headingKey
            }
        }
        await load(force: false)
    }

    @MainActor
    private func load(force: Bool) async {
        if !force, page != nil { return }
        do {
            let fresh = try await FamilyHistoryService.shared.person(route.id)
            page = fresh
            failure = nil
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
}

// MARK: - The header

struct FamilyPersonHeader: View {
    let page: FHPersonPage?
    let fallbackName: String
    var focus: AccessibilityFocusState<String?>.Binding
    let onPicture: (FHImage) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.kadeNavigation) private var nav

    private var person: FHPerson? { page?.person }

    /// The server's sentence, or the name alone before the page arrives.
    private var spoken: String {
        FamilyAccessRules.nonEmpty(person?.spoken) ?? fallbackName
    }

    /// A slow drift on a portrait or grave photo at the screen size, never
    /// on a face crop or a record.
    private var drifts: Bool {
        let kind: String = page?.headerKind ?? ""
        return kind == "portrait" || kind == "grave"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            picture
            words
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
                .accessibilityFocused(focus, equals: FamilyPersonScreen.headingKey)
            duplicateNote
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let header = page?.header {
            Button {
                onPicture(header)
            } label: {
                FamilyWidePhoto(image: header, size: .s, height: 260, longSide: 680, panning: drifts)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(header.label)
            .accessibilityHint("Opens the picture.")
            .accessibilityInputLabels(["Picture"])
            .accessibilityHidden(voiceOverOn)
        } else if let person {
            FamilyPhoto(image: nil, drawn: 112, initials: person.initials ?? "", side: person.sideKind, circle: true)
                .frame(maxWidth: .infinity)
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(person?.shownName ?? fallbackName)
                .font(.title.bold())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let bornA = FamilyAccessRules.nonEmpty(person?.bornA) {
                Text(bornA).font(.subheadline).foregroundStyle(.secondary)
            }
            if let others = otherNames {
                Text(others).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let years = FamilyAccessRules.nonEmpty(person?.years) {
                Text(years).font(.headline).foregroundStyle(.secondary)
            }
            if let term = FamilyAccessRules.nonEmpty(person?.term) {
                Text(term).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            if let person {
                FamilyPersonSideLine(person: person)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var otherNames: String? {
        let names: [String] = (person?.otherNames ?? []).filter { !$0.isEmpty && $0 != person?.name }
        return names.isEmpty ? nil : "Also known as " + names.joined(separator: ", ")
    }

    /// "This is a second copy of {name} in the tree" and Open the main entry.
    @ViewBuilder
    private var duplicateNote: some View {
        if let duplicate = person?.duplicate {
            VStack(alignment: .leading, spacing: 6) {
                if let text = FamilyAccessRules.nonEmpty(duplicate.text) {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                if let mainId = FamilyAccessRules.nonEmpty(duplicate.id) {
                    NavigationLink(value: HomeRoute.library(.family(.person(FamilyPersonRoute(id: mainId, name: duplicate.name ?? ""))))) {
                        Text("Open the main entry")
                    }
                }
            }
            .familyCard()
        }
    }
}
