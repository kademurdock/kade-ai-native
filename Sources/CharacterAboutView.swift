import SwiftUI
import UIKit

/// Who an About screen is about. Its own small type, so a sheet or a
/// navigation destination keyed to it can never collide with another
/// destination type (the build-121 rule).
struct CharacterAboutTarget: Identifiable, Hashable {
    let agentId: String
    let name: String
    var id: String { agentId }
}

/// How the soul screens speak. Loading and error news is low priority, so it
/// waits for VoiceOver to finish what it is saying (the chat screen's
/// manners). A result the person asked for ("Forgotten.") is said a moment
/// after an alert closes, so the closing doesn't swallow it.
enum KadeSoulSpeech {
    @MainActor
    static func polite(_ text: String) {
        UIAccessibility.post(
            notification: .announcement,
            argument: NSAttributedString(
                string: text,
                attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low]
            )
        )
    }

    @MainActor
    static func result(_ text: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}

/// Oct 16 2026: About a character, for the person talking to it. How the
/// character is coming in, when you last talked, the character's own days,
/// and your moments together, each of which you can forget.
///
/// What this never shows: the character's private opinion of the person. The
/// server doesn't send it and nothing here may guess at it (Kade's decision).
///
/// VoiceOver: each section title is a heading; each journal day starts with
/// its own heading; each moment is ONE element whose words say who said it,
/// what it was, why it stuck and when, with Forget in the Actions rotor. The
/// visible Forget button steps aside for VoiceOver only (Voice Control and
/// Switch Control still reach it by name), her standing rule.
struct CharacterAboutView: View {
    let target: CharacterAboutTarget
    /// True when shown as a sheet over a conversation: adds Done.
    var showsDone = false

    @EnvironmentObject private var apiClient: KadeAPIClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var snapshot: KadeSoulSnapshot?
    @State private var loading = false
    @State private var loadError: String?
    @State private var forgetting: KadeSoulMoment?
    @State private var forgettingId: String?

    private var name: String {
        let trimmed = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "This character" : trimmed
    }

    var body: some View {
        List {
            if let snapshot {
                content(snapshot)
            } else if let loadError {
                Section {
                    Text(loadError)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { Task { await load() } }
                        .disabled(loading)
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Loading…")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { if snapshot == nil { await load() } }
        .refreshable { await load() }
        .alert(
            "Forget this moment?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { moment in
            Button("Forget", role: .destructive) { Task { await forget(moment) } }
            Button("Keep it", role: .cancel) { forgetting = nil }
        } message: { moment in
            Text("This removes \u{201C}\(moment.quote)\u{201D} from your moments with \(name). It can't be undone.")
        }
    }

    @ViewBuilder
    private func content(_ soul: KadeSoulSnapshot) -> some View {
        Section {
            Text(KadeSoulWords.moodSentence(name: name, words: soul.mood?.words))
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            heading("How \(name) is coming in")
        }

        Section {
            Text(KadeSoulWords.lastTalkedSentence(soul.lastTalkedAt))
        } header: {
            heading("Last time you talked")
        }

        Section {
            if soul.days.isEmpty {
                Text("\(name) hasn't written about a day yet.")
            } else {
                ForEach(soul.days) { day in
                    dayRow(day)
                }
            }
        } header: {
            heading("\(name)'s days")
        } footer: {
            Text("\(name)'s own journal, the same for everyone \(name) talks to.")
        }

        Section {
            if soul.moments.isEmpty {
                Text("No moments saved yet. They collect as you two talk.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(soul.moments) { moment in
                    momentRow(moment)
                }
            }
        } header: {
            heading("Your moments together")
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .accessibilityAddTraits(.isHeader)
    }

    private func dayRow(_ day: KadeSoulDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(KadeSoulWords.dayHeading(day.day) ?? day.day)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(day.text)
                .fixedSize(horizontal: false, vertical: true)
            if !day.following.isEmpty {
                Text("Following this week: \(day.following)")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func momentRow(_ moment: KadeSoulMoment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(KadeSoulWords.momentSpeakerWords(moment.speaker, name: name)): \u{201C}\(moment.quote)\u{201D}")
                    .fixedSize(horizontal: false, vertical: true)
                Text(KadeSoulWords.momentKindLine(kind: moment.kind, why: moment.why))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = moment.createdAt.flatMap(KadeSoulWords.parseDate) {
                    Text(KadeSoulWords.shortDate(date))
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KadeSoulWords.momentSpoken(moment, name: name))
            .accessibilityAction(named: "Forget this moment") { forgetting = moment }

            Button(forgettingId == moment.id ? "Forgetting…" : "Forget", role: .destructive) {
                forgetting = moment
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .disabled(forgettingId != nil)
            .accessibilityLabel("Forget this moment")
            .accessibilityInputLabels(["Forget", "Forget this moment"])
            .accessibilityHidden(voiceOverOn)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        guard KadeSoulWords.isCharacterId(target.agentId) else {
            loadError = "There's nothing to show about \(name) yet."
            KadeSoulSpeech.polite(loadError ?? "")
            return
        }
        loading = true
        defer { loading = false }
        if snapshot == nil {
            loadError = nil
            KadeSoulSpeech.polite("Loading.")
        }
        let request = apiClient.request(path: "api/kade/soul/\(target.agentId)", authorized: true)
        do {
            let (data, http) = try await apiClient.send(request)
            guard http.statusCode == 200 else {
                failed(http.statusCode == 401
                    ? "Please sign in again to see this."
                    : "Couldn't load this right now. Try again in a moment.")
                return
            }
            guard let fresh = try? JSONDecoder().decode(KadeSoulSnapshot.self, from: data) else {
                failed("Couldn't read this right now. Try again in a moment.")
                return
            }
            snapshot = fresh
            loadError = nil
            KadeSoulSpeech.polite("Loaded.")
        } catch {
            // Leaving the screen cancels the request; that needs no words.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            failed("Couldn't load this. Check your connection and try again.")
        }
    }

    @MainActor
    private func failed(_ message: String) {
        if snapshot == nil {
            loadError = message
            KadeSoulSpeech.polite(message)
        } else {
            KadeSoulSpeech.polite(message + " What was here is still shown.")
        }
    }

    @MainActor
    private func forget(_ moment: KadeSoulMoment) async {
        forgetting = nil
        guard forgettingId == nil else { return }
        forgettingId = moment.id
        defer { forgettingId = nil }
        let request = apiClient.request(
            path: "api/kade/soul/\(target.agentId)/moments/\(moment.id)",
            method: "DELETE",
            authorized: true
        )
        do {
            let (_, http) = try await apiClient.send(request)
            // 404: it was already gone, which is what was asked for.
            if http.statusCode == 200 || http.statusCode == 404 {
                snapshot?.moments.removeAll { $0.id == moment.id }
                KadeSoulSpeech.result("Forgotten.")
            } else {
                KadeSoulSpeech.result("Couldn't forget that right now. Try again in a moment.")
            }
        } catch {
            KadeSoulSpeech.result("Couldn't forget that. Check your connection and try again.")
        }
    }
}
