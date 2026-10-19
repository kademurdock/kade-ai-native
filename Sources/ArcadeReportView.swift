import SwiftUI
import UIKit

/// REPORT A PROBLEM WITH THIS GAME (Oct 19 2026, App Store guideline 4.7.1).
///
/// Opened from a playable game's row (Actions rotor and long-press menu),
/// from the game's own Settings sheet, and, for the Arcade as a whole, from
/// the foot of the Arcade screen. It sends through the app's EXISTING
/// feedback path, FeedbackReportService (POST /api/kade/feedback, category
/// "bug"), so the report lands on Kade's feedback board beside every other
/// report, with the game's id and version in its text (ArcadeReport).
///
/// Same vocabulary as Report a problem: a real label on the one field, the
/// actionDone earcon, a success haptic and a spoken confirmation, then it
/// closes itself; a failure plays the error pair and moves VoiceOver to the
/// message.
struct ArcadeReportView: View {
    let apiClient: KadeAPIClient
    let target: ArcadeReportTarget
    /// Where it was sent from, for the board ("Arcade list", "Game settings").
    let place: String
    /// False when pushed inside a sheet that already has its own navigation
    /// (the game's Settings): then Back returns to Settings.
    let standalone: Bool
    /// From a running game's Settings: how the game ran (no account details),
    /// read when Send is pressed and sent with the report, so a game that
    /// failed to start reaches Kade without any copying.
    let ran: (@MainActor () -> String)?

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @AccessibilityFocusState private var errorFocused: Bool

    init(apiClient: KadeAPIClient, target: ArcadeReportTarget, place: String,
         standalone: Bool = true, ran: (@MainActor () -> String)? = nil) {
        self.apiClient = apiClient
        self.target = target
        self.place = place
        self.standalone = standalone
        self.ran = ran
    }

    var body: some View {
        if standalone {
            NavigationStack {
                form
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            }
        } else {
            form
        }
    }

    private var intro: String {
        if target.gameId.isEmpty {
            return "Tell Kade what went wrong in the Arcade. It goes straight to her with your name on it, so she can follow up."
        }
        let base = "Tell Kade what went wrong with \(target.title). The report carries the game's name and version, and your name, so she can follow up."
        return ran == nil ? base : base + " How the game has run on this iPhone goes with it too, with no account details."
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(intro)
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What went wrong, in a few words")
                        .font(.subheadline)
                        .accessibilityHidden(true)
                    TextField("Describe it", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("What went wrong, in a few words")
                        .disabled(isSending)
                    // Like Report a problem. Not over a running game (its
                    // Settings): the recorder would take the game's sound.
                    if standalone {
                        DictationButton(apiClient: apiClient, text: $note, fieldName: "report")
                            .disabled(isSending)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityFocused($errorFocused)
                }

                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if isSending { ProgressView().padding(.trailing, 4) }
                        Text(isSending ? "Sending" : "Send report")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ArcadeReport.canSend(note) || isSending)
                .accessibilityHint("Sends the report to Kade.")
            }
            .padding()
        }
        .navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func send() async {
        guard ArcadeReport.canSend(note), !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        let howItRan: String? = ran?()
        do {
            try await FeedbackReportService(apiClient: apiClient).submit(
                category: "bug",
                subject: ArcadeReport.subject(target),
                detail: ArcadeReport.detail(note: note, target: target, from: place, ran: howItRan)
            )
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            UIAccessibility.post(notification: .announcement, argument: ArcadeReport.sentLine)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't send your report. Try again."
            Earcons.shared.play(.error)
            KadeHaptics.error()
            errorFocused = true
        }
    }
}
