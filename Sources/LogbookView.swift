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

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: LogbookService(client: apiClient))
    }

    private var days: [(date: String, spoken: String, entries: [LogbookService.LogbookEntry])] {
        guard let page else { return [] }
        var byDate: [String: [LogbookService.LogbookEntry]] = [:]
        for e in page.entries {
            byDate[e.date, default: []].append(e)
        }
        return byDate.keys.sorted(by: >).map { key in
            (key, byDate[key]!.first!.spokenDate, byDate[key]!)
        }
    }

    var body: some View {
        List {
            if let error = service.loadError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            if let page, page.enabled == false {
                Section {
                    Text("The logbook is currently paused — nothing new is being written.")
                        .foregroundStyle(.secondary)
                }
            }
            if let page, page.entries.isEmpty, service.loadError == nil {
                Section {
                    Text("Nothing here yet. Your logbook fills up as you share your days with your companions — or add a line yourself with the plus button.")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Nothing here yet. Your logbook fills up as you share your days with your companions, or add a line yourself with the add entry button.")
                }
            }
            ForEach(days, id: \.date) { day in
                Section {
                    ForEach(day.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text)
                            Text(entry.holder)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.text). \(entry.holder).")
                        .accessibilityAction(named: "Edit this entry") {
                            editText = entry.text
                            entryEditing = entry
                        }
                        .accessibilityAction(named: "Forget this entry") {
                            entryPendingForget = entry
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                editText = entry.text
                                entryEditing = entry
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                entryPendingForget = entry
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(day.spoken)
                }
            }
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
        } catch {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func forget(_ entry: LogbookService.LogbookEntry) async {
        entryPendingForget = nil
        do {
            try await service.forget(entry: entry)
            KadeHaptics.success()
            UIAccessibility.post(notification: .announcement, argument: "Entry forgotten.")
            await reload()
        } catch {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }
}
