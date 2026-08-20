import SwiftUI
import UIKit

/// Aug 8 2026 — THE LOGBOOK SCREEN (native twin of the web's You -> Your
/// Logbook, on the same /api/diary lane). The dated record her companions
/// keep of her days: browse by day newest-first, hear who holds each entry,
/// forget any entry for good, add a line by voice or keyboard (manual adds
/// are shared — written in HER logbook, so any companion may recall them;
/// the add sheet says so in plain words). VoiceOver-first, MemoriesView's
/// house patterns: one combined element per entry, forget on the actions
/// rotor, every change announced.
struct LogbookView: View {
    @StateObject private var service: LogbookService
    @State private var page: LogbookService.LogbookPage?
    @State private var addingNew = false
    @State private var newText = ""
    @State private var entryPendingForget: LogbookService.LogbookEntry?
    @State private var entryEditing: LogbookService.LogbookEntry?
    @State private var editText = ""
    @State private var busy = false

    /* Aug 20 2026 — WINDOWED AND EAGER, LAID OUT LIKE THE TRANSCRIPT.
     * `/api/diary` hands back the WHOLE logbook in one response — no
     * pagination server-side — so this count is unbounded and grows every
     * day she talks to anybody. The transcript's bargain applies here too:
     * a plain `VStack` renders every row it holds EAGERLY, which is exactly
     * why it doesn't race VoiceOver the way a lazy container does, and the
     * window is what keeps that eagerness affordable.
     *
     * 120 rather than the transcript's 48 because a logbook row is one line
     * of text and a holder name — no toolbar, no voice controls, no think
     * block. RAISING THIS MEANS RE-TESTING WITH VOICEOVER ACTUALLY ON,
     * not eyeballing it in the simulator. See ConversationDetailView's
     * `transcriptWindowMaxTested` writeup for why that sentence is there. */
    private static let entryWindow = 120
    @State private var windowGenerations = 1

    /* Aug 20 2026 — FOCUS MANAGEMENT (her report: "still kinda weird with vo
     * focus"). The relayout fixed the CONTAINER; this fixes where focus goes
     * after something changes under it. Previously: nothing was bound, so an
     * edit, a forget, or loading more rebuilt the whole VStack and VoiceOver
     * dropped focus to the top of the screen every time — which on a logbook
     * means she loses her place in her own diary after every single action.
     * The transcript solved this with `.accessibilityFocused` per row; same
     * pattern here, keyed on entry id.
     *
     * ⚠️ UNVERIFIED ON DEVICE. Written while we were deliberately not spending
     * a build. The sleep before each focus set is the pragmatic fix for
     * SwiftUI needing a render pass before it can resolve a focus target;
     * if focus still lands wrong, that delay is the first knob, and posting
     * a UIAccessibility .layoutChanged with the element is the fallback. */
    @AccessibilityFocusState private var a11yFocus: String?

    private func focusAfterRender(_ id: String?) async {
        guard let id else { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        a11yFocus = id
    }

    /// The entry VoiceOver should land on once `entry` is gone: the next one
    /// down, or the one above it if it was last. Computed BEFORE the delete.
    private func neighborOf(_ entry: LogbookService.LogbookEntry) -> String? {
        let flat = windowedEntries
        guard let i = flat.firstIndex(where: { $0.id == entry.id }) else { return nil }
        if i + 1 < flat.count { return flat[i + 1].id }
        if i > 0 { return flat[i - 1].id }
        return nil
    }

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: LogbookService(client: apiClient))
    }

    private var windowedEntries: [LogbookService.LogbookEntry] {
        guard let page else { return [] }
        let newestFirst = page.entries.sorted { $0.date > $1.date }
        return Array(newestFirst.prefix(Self.entryWindow * windowGenerations))
    }

    private var hiddenEarlierCount: Int {
        guard let page else { return 0 }
        return max(0, page.entries.count - windowedEntries.count)
    }

    private var hiddenEarlierHint: String {
        let noun = hiddenEarlierCount == 1 ? "entry" : "entries"
        return "\(hiddenEarlierCount) older \(noun) not shown yet."
    }

    private var days: [(date: String, spoken: String, entries: [LogbookService.LogbookEntry])] {
        guard let page else { return [] }
        var byDate: [String: [LogbookService.LogbookEntry]] = [:]
        for e in windowedEntries {
            byDate[e.date, default: []].append(e)
        }
        return byDate.keys.sorted(by: >).map { key in
            (key, byDate[key]!.first!.spokenDate, byDate[key]!)
        }
    }

    var body: some View {
        /* Aug 20 2026 — WAS A `List` WITH PER-DAY `Section`s. Three things
         * were wrong with that under VoiceOver, and they compounded:
         *
         * 1. `List` is a LAZY CONTAINER. It is the same family as the
         *    `LazyVStack` that build 225 tore out of the transcript after
         *    twenty-two builds — rows materialize as the accessibility tree
         *    is being walked, which is the shape of Apple's 814208 race.
         *    This screen is smaller so it stuttered instead of freezing.
         * 2. Every row carried BOTH `.accessibilityAction(named:)` AND
         *    `.swipeActions`, and SwiftUI publishes swipe actions into the
         *    actions rotor automatically. So every entry offered FOUR
         *    actions — "Edit this entry", "Forget this entry", "Edit",
         *    "Forget" — two of them duplicates with worse labels.
         * 3. `Section` headers are a list affordance, not a heading, so the
         *    Headings rotor had nothing in it and she had to swipe through
         *    every day linearly to reach an older one.
         *
         * Now it is the transcript's layout: `ScrollView` + plain `VStack`,
         * one combined element per row, actions on the actions rotor only,
         * and the day markers carry `.isHeader` so the NATIVE Headings rotor
         * jumps day to day. Deliberately NOT a custom `accessibilityRotor` —
         * two of those were the actual send-time freeze wedge found in
         * build 214, and the Headings trait gets the same navigation out of
         * plain UIAccessibility without re-entering that machinery. */
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = service.loadError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                if let page, page.enabled == false {
                    Text("The logbook is currently paused — nothing new is being written.")
                        .foregroundStyle(.secondary)
                }
                if let page, page.entries.isEmpty, service.loadError == nil {
                    Text("Nothing here yet. Your logbook fills up as you share your days with your companions — or add a line yourself with the plus button.")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Nothing here yet. Your logbook fills up as you share your days with your companions, or add a line yourself with the add entry button.")
                }
                ForEach(days, id: \.date) { day in
                    Text(day.spoken)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 4)
                    ForEach(day.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text)
                            Text(entry.holder)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.text). \(entry.holder).")
                        .accessibilityFocused($a11yFocus, equals: entry.id)
                        .accessibilityAction(named: "Edit this entry") {
                            editText = entry.text
                            entryEditing = entry
                        }
                        .accessibilityAction(named: "Forget this entry") {
                            entryPendingForget = entry
                        }
                        /* Long-press for sighted users, replacing the swipe
                         * actions the `List` used to provide. VoiceOver reaches
                         * the same two operations through the actions rotor
                         * above, so this adds no duplicate entries. */
                        .contextMenu {
                            Button {
                                editText = entry.text
                                entryEditing = entry
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                entryPendingForget = entry
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                }
                if hiddenEarlierCount > 0 {
                    Button {
                        let firstNew = windowedEntries.count
                        windowGenerations += 1
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Loaded earlier entries."
                        )
                        let revealed = windowedEntries
                        if firstNew < revealed.count {
                            Task { await focusAfterRender(revealed[firstNew].id) }
                        }
                    } label: {
                        Text("Show earlier entries")
                    }
                    .accessibilityLabel("Show earlier entries")
                    .accessibilityHint(hiddenEarlierHint)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Your Logbook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newText = ""
                    addingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add entry")
                .accessibilityHint("Write or dictate a line for today. Anything you add here can be recalled by any of your companions.")
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .overlay {
            if service.isLoading && page == nil {
                ProgressView("Loading your logbook…")
            }
        }
        .sheet(isPresented: $addingNew) {
            NavigationStack {
                Form {
                    Section {
                        TextEditor(text: $newText)
                            .frame(minHeight: 120)
                            .accessibilityLabel("Entry text")
                            .accessibilityHint("What happened, or how the day went. Dictation works here.")
                    } footer: {
                        Text("Dated today, in your own words. Any of your companions can recall entries you add here.")
                    }
                }
                .navigationTitle("Add to your logbook")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { addingNew = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await saveNew() }
                        }
                        .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                }
            }
        }
        .sheet(item: $entryEditing) { entry in
            NavigationStack {
                Form {
                    Section {
                        TextEditor(text: $editText)
                            .frame(minHeight: 120)
                            .accessibilityLabel("Entry text")
                            .accessibilityHint("Fix the wording. Dictation works here. The entry keeps its date and who holds it.")
                    } footer: {
                        Text("From \(entry.spokenDate). Only the wording changes — the date and who holds the entry stay put.")
                    }
                }
                .navigationTitle("Edit entry")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { entryEditing = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await saveEdit(entry) }
                        }
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                }
            }
        }
        .confirmationDialog(
            "Forget this entry for good?",
            isPresented: Binding(
                get: { entryPendingForget != nil },
                set: { if !$0 { entryPendingForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget it", role: .destructive) {
                if let entry = entryPendingForget {
                    Task { await forget(entry) }
                }
            }
            Button("Keep it", role: .cancel) { entryPendingForget = nil }
        } message: {
            Text(entryPendingForget?.text ?? "")
        }
    }

    private func reload() async {
        page = await service.load()
    }

    private func saveNew() async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await service.add(text: text)
            addingNew = false
            KadeHaptics.success()
            UIAccessibility.post(notification: .announcement, argument: "Saved to your logbook.")
            await reload()
        } catch {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func saveEdit(_ entry: LogbookService.LogbookEntry) async {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await service.edit(entry: entry, newText: text)
            entryEditing = nil
            KadeHaptics.success()
            UIAccessibility.post(notification: .announcement, argument: "Entry updated.")
            await reload()
            await focusAfterRender(entry.id)
        } catch {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func forget(_ entry: LogbookService.LogbookEntry) async {
        entryPendingForget = nil
        // Neighbour is resolved BEFORE the delete, while the entry still exists.
        let landing = neighborOf(entry)
        do {
            try await service.forget(entry: entry)
            KadeHaptics.success()
            UIAccessibility.post(notification: .announcement, argument: "Entry forgotten.")
            await reload()
            await focusAfterRender(landing)
        } catch {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }
}
