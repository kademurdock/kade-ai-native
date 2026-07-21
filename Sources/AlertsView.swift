import SwiftUI

/// Alerts — recent reminders/check-ins plus how they reach her. See
/// `AlertsService` for the server contract and for what was deliberately
/// not ported (browser web-push subscribe).
///
/// Layout follows `SettingsView`'s proven List-with-Sections shape, and the
/// recent rows follow the List-row accessibility pattern every list in this
/// app uses (`.accessibilityElement(children: .ignore)` + one explicit
/// label per row — fine in Lists, broken in Forms, per the build-135
/// Voice-row lesson recorded in `AgentEditorView`).
struct AlertsView: View {
    let apiClient: KadeAPIClient

    @StateObject private var service: AlertsService

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: AlertsService(client: apiClient))
    }

    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var recent: [RecentNudge] = []

    @State private var reminders = "chat"
    @State private var birthday = "off"
    @State private var birthdayDate = ""
    @State private var phone = ""

    @State private var isSaving = false
    @State private var isTesting = false
    /// One status line for save/test outcomes; VoiceOver focus moves here so
    /// the result is spoken without hunting (same contract as sign-in's
    /// status line on the home screen).
    @State private var statusText: String?
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        List {
            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("Try again") {
                        Task { await load() }
                    }
                }
            }

            Section {
                if isLoading && recent.isEmpty {
                    ProgressView("Loading…")
                        .accessibilityLabel("Loading your alerts")
                } else if recent.isEmpty {
                    Text("Nothing yet. Reminders, birthday wishes, and check-in notes will show up here once they start arriving.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recent) { nudge in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rowTitle(nudge))
                                .font(.headline)
                            Text(nudge.text)
                                .font(.body)
                            Text(rowDetail(nudge))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(rowTitle(nudge)). \(nudge.text). \(rowDetail(nudge))")
                    }
                }
            } header: {
                Text("Recent")
            } footer: {
                Text("The last 15 things Kade-AI sent your way, newest first.")
            }

            Section {
                Picker("Reminders", selection: $reminders) {
                    ForEach(AlertsService.channels, id: \.self) { c in
                        Text(AlertsService.channelLabel(c)).tag(c)
                    }
                }
                .accessibilityHint("How reminders reach you: in chat, as a phone notification, as a phone call, or off.")

                Picker("Birthday wishes", selection: $birthday) {
                    ForEach(AlertsService.channels, id: \.self) { c in
                        Text(AlertsService.channelLabel(c)).tag(c)
                    }
                }
                .accessibilityHint("How your birthday wish arrives on the day.")

                if birthday != "off" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Birthday (month-day)").font(.subheadline)
                        TextField("07-04", text: $birthdayDate)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityLabel("Birthday, month dash day")
                            .accessibilityHint("Two digits for the month, a dash, two digits for the day. For example, zero seven dash zero four for July fourth.")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone number for calls").font(.subheadline)
                    TextField("Ten digits", text: $phone)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Phone number for calls")
                        .accessibilityHint("Ten digits. Only used when a delivery choice above is set to phone call.")
                }

                Button {
                    Task { await save() }
                } label: {
                    Text(isSaving ? "Saving…" : "Save delivery choices")
                }
                .disabled(isSaving)
            } header: {
                Text("How alerts reach you")
            } footer: {
                Text("In chat means the next companion you talk to passes it along. Phone notification uses this phone. Phone call rings the number above.")
            }

            Section {
                Button {
                    Task { await sendTest() }
                } label: {
                    Text(isTesting ? "Sending…" : "Send a test alert")
                }
                .disabled(isTesting)
                .accessibilityHint("Sends a real test through your own delivery choices and tells you which way it went out.")

                if let statusText {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityFocused($statusFocused)
                }
            } footer: {
                Text("If a test lands as a phone notification, notifications are working end to end on this phone.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .refreshable { await load() }
    }

    private func rowTitle(_ nudge: RecentNudge) -> String {
        let raw = (nudge.type ?? "reminder")
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private func rowDetail(_ nudge: RecentNudge) -> String {
        var parts: [String] = []
        if let channel = nudge.channel {
            parts.append("via \(AlertsService.channelLabel(channel).lowercased())")
        }
        if nudge.deliveredAt == nil {
            parts.append("waiting for your next chat")
        }
        if let created = nudge.createdAt, let rel = KadeDateFormatting.relative(from: created) {
            parts.append(rel)
        }
        return parts.joined(separator: ", ")
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let response = try await service.load()
            recent = response.recent ?? []
            if let prefs = response.prefs {
                reminders = AlertsService.channels.contains(prefs.reminders ?? "") ? (prefs.reminders ?? "chat") : "chat"
                birthday = AlertsService.channels.contains(prefs.birthday ?? "") ? (prefs.birthday ?? "off") : "off"
                birthdayDate = prefs.birthdayDate ?? ""
                phone = prefs.phone ?? ""
            }
        } catch {
            loadError = (error as? AlertsService.AlertsError)?.message ?? "Couldn't load your alerts. Pull down to try again."
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.savePrefs(
                reminders: reminders,
                birthday: birthday,
                birthdayDate: birthdayDate.trimmingCharacters(in: .whitespaces),
                phone: phone.trimmingCharacters(in: .whitespaces)
            )
            statusText = "Saved."
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
        } catch {
            statusText = (error as? AlertsService.AlertsError)?.message ?? "Couldn't save. Try again."
            Earcons.shared.play(.error)
            KadeHaptics.error()
        }
        statusFocused = true
    }

    private func sendTest() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let channel = try await service.sendTest()
            statusText = channel == "chat"
                ? "Test sent — it rides along in your next chat."
                : "Test sent as a \(AlertsService.channelLabel(channel).lowercased())."
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
        } catch {
            statusText = (error as? AlertsService.AlertsError)?.message ?? "Couldn't send a test. Try again."
            Earcons.shared.play(.error)
            KadeHaptics.error()
        }
        statusFocused = true
    }
}
