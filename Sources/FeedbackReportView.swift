import SwiftUI
import UIKit

// MARK: - Report a problem (session 23)
//
// Kade: "What else can we add to the release before we build?" The family
// tester loop, closed: Amber found two real bugs today and the report had to
// travel Amber -> Kade -> here by mouth. This screen lets any signed-in
// tester file a bug, an idea, or plain feedback from inside the app; it
// lands in the same pile the kade_feedback chat tool writes and Kade's
// /feedback-dashboard reads (fork route POST /api/kade/feedback, added
// alongside this screen).
//
// Accessibility notes, load-bearing as always:
// - Category is a segmented Picker with plain spoken labels.
// - The detail editor is a TextField(axis: .vertical) like the composer,
//   with a real label; the whole form is plain views, no Form-row traps.
// - Success = actionDone earcon + success haptic + a spoken confirmation,
//   then the sheet closes itself; failure = error pair + the message moves
//   VoiceOver focus to itself. Same vocabulary as everything else.

@MainActor
final class FeedbackReportService {
    struct ReportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let client: KadeAPIClient
    init(apiClient: KadeAPIClient) { client = apiClient }

    func submit(category: String, subject: String, detail: String) async throws {
        var req = client.request(path: "api/kade/feedback", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "category": category,
            "subject": subject,
            "detail": detail,
            "surface": "app",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            struct ErrBody: Decodable { let error: String? }
            let message = (try? JSONDecoder().decode(ErrBody.self, from: data))?.error
            throw ReportError(message: message ?? "Couldn't save your report. Try again.")
        }
    }
}

struct FeedbackReportView: View {
    let apiClient: KadeAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var category = "bug"
    @State private var subject = ""
    @State private var detail = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private enum Focus: Hashable { case error }
    @AccessibilityFocusState private var a11yFocus: Focus?

    private var service: FeedbackReportService { FeedbackReportService(apiClient: apiClient) }
    private var canSubmit: Bool {
        detail.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Found something broken, or wishing for something new? Say it here — it goes straight to Kade with your name on it, so she can follow up.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("What kind of report?").font(.subheadline)
                        Picker("What kind of report?", selection: $category) {
                            Text("Bug").tag("bug")
                            Text("Idea").tag("feature")
                            Text("Feedback").tag("feedback")
                        }
                        .pickerStyle(.segmented)
                        .sensoryFeedback(trigger: category) { _, _ in
                            FeedbackPrefs.gate(.selection)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("A short title (optional)").font(.subheadline)
                        TextField("Title", text: $subject)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Short title, optional")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("What happened, in your own words").font(.subheadline)
                        TextField("Describe it", text: $detail, axis: .vertical)
                            .lineLimit(4...10)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("What happened, in your own words")
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityFocused($a11yFocus, equals: .error)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if isSubmitting { ProgressView().padding(.trailing, 4) }
                            Text(isSubmitting ? "Sending…" : "Send report")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .accessibilityHint("Sends your report to Kade.")
                }
                .padding()
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await service.submit(
                category: category,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: "Report sent. Thank you — Kade will see it."
            )
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't save your report. Try again."
            Earcons.shared.play(.error)
            KadeHaptics.error()
            a11yFocus = .error
        }
    }
}
