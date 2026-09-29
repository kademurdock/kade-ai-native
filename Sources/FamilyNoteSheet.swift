import SwiftUI
import UIKit

// MARK: - Family history: a note to the tree's owner (Sep 29 2026)
//
// DESIGN 1.13: "Add a memory" (Home > More, a person's page) and "Do you
// know who this is?" (the photo viewer). One labelled field of up to 2,000
// characters and Send; POST /note; the action earcon and the server's own
// thanks ("Sent to Ada. Thank you."), then it closes. Only the tree's owner
// reads notes. "Ask for this photo to be restored" is the same route with
// kind "restore-request", sent in one tap from the viewer (no sheet).

/// What a note is about, and the sheet's words.
struct FamilyNoteRequest: Identifiable {
    let id = UUID()
    var personId: String? = nil
    var mediaId: String? = nil
    /// "memory", "who" or "restore-request".
    var kind: String = "memory"
    var title: String = "Add a memory"
    /// The field's label and what VoiceOver says for it.
    var prompt: String = "What would you like the family to know?"
}

struct FamilyNoteSheet: View {
    let request: FamilyNoteRequest

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?
    @AccessibilityFocusState private var fieldFocused: Bool
    private let limit = 2000

    var body: some View {
        NavigationStack {
            form
                .navigationTitle(request.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarButtons }
        }
        .accessibilityAction(.escape) { dismiss() }
        .onChange(of: text) { _, newValue in
            if newValue.count > limit { text = String(newValue.prefix(limit)) }
        }
        .task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            if Task.isCancelled { return }
            fieldFocused = true
        }
    }

    private var form: some View {
        Form {
            Section {
                Text(request.prompt)
                    .font(.headline)
                    .accessibilityHidden(true)
                TextField(request.prompt, text: $text, axis: .vertical)
                    .lineLimit(5...12)
                    .accessibilityLabel(request.prompt)
                    .accessibilityFocused($fieldFocused)
            } footer: {
                Text("\(text.count) of \(limit) characters")
            }
            if let problem {
                Section {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(sending ? "Sending…" : "Send") {
                Task { await send() }
            }
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func send() async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !sending else { return }
        sending = true
        problem = nil
        do {
            let sent = try await FamilyHistoryService.shared.note(personId: request.personId, mediaId: request.mediaId,
                                                                  kind: request.kind, text: words)
            sending = false
            Earcons.shared.play(.actionDone)
            KadeAnnounce.high(FamilyAccessRules.nonEmpty(sent.text) ?? "Sent. Thank you.")
            dismiss()
        } catch {
            sending = false
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            problem = message
            Earcons.shared.play(.error)
            FamilyAnnounce.say(message)
        }
    }
}

/// "Ask for this photo to be restored": one tap, into the owner's notes.
@MainActor
enum FamilyRestoreAsk {
    /// Sends the request and says what happened (the server's words first).
    static func send(mediaId: String) async -> String {
        do {
            let sent = try await FamilyHistoryService.shared.note(mediaId: mediaId, kind: "restore-request",
                                                                  text: "Please restore this photo if you can.")
            Earcons.shared.play(.actionDone)
            return FamilyAccessRules.nonEmpty(sent.text) ?? "Asked. Thank you."
        } catch {
            Earcons.shared.play(.error)
            return (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
        }
    }
}
