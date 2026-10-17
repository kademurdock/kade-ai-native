import SwiftUI
import UIKit

/// The Agent work screen's way in: "Background tasks, 2 running". The count
/// is fetched quietly; until it lands (or if it can't) the row just says
/// "Background tasks".
struct BackgroundTasksLink: View {
    let apiClient: KadeAPIClient
    @State private var running: Int?

    var body: some View {
        NavigationLink(KadeSoulWords.taskLinkLabel(running: running)) {
            BackgroundTasksView(apiClient: apiClient)
        }
        .accessibilityHint("Jobs a character is working on for you in the background.")
        .task { await count() }
    }

    @MainActor
    private func count() async {
        let request = apiClient.request(path: "api/kade/soul/tasks/list", authorized: true)
        guard let (data, http) = try? await apiClient.send(request), http.statusCode == 200,
              let list = try? JSONDecoder().decode(KadeBackgroundTaskList.self, from: data) else { return }
        running = list.tasks.filter(\.isRunning).count
    }
}

private struct BackgroundTaskCancelReply: Decodable {
    let ok: Bool?
    let note: String?
    let error: String?
}

/// Oct 16 2026: jobs a character took on for the person in the background
/// (server: services/kadeTasks.js). Same shape as Agent work: a status line
/// VoiceOver re-reads as it changes, a Refresh button, one card per task.
///
/// Each card is ONE VoiceOver element (title, character, status in plain
/// words, the result or the error, and the cost), with Open the conversation
/// and Stop it in the Actions rotor. The visible buttons under it step aside
/// for VoiceOver only, her standing rule; Voice Control still reaches them.
struct BackgroundTasksView: View {
    let apiClient: KadeAPIClient
    @Environment(\.kadeNavigation) private var navigation
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var tasks: [KadeBackgroundTask] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var status = "Loading your background tasks…"
    @State private var stopping: KadeBackgroundTask?
    @State private var stoppingId: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Jobs a character is working on for you in the background. When one finishes, the character writes to you in a conversation.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(.subheadline)
                    .accessibilityAddTraits(.updatesFrequently)
                Button("Refresh") { refresh() }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || stoppingId != nil)
                    .accessibilityLabel("Refresh background tasks")
                    .accessibilityHint("Checks where each task is.")

                if loaded && tasks.isEmpty {
                    Text("No background tasks yet. When a character takes on a job for you in the background, it shows up here.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(tasks) { task in
                    card(task)
                }
                Text("About stopping").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Stop it ends a task where it is. What already ran is still charged, and nothing is posted to the conversation.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Background tasks")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
        .onDisappear { work?.cancel() }
        .alert(
            "Stop this task?",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            presenting: stopping
        ) { task in
            Button("Stop it", role: .destructive) { stop(task) }
            Button("Keep it going", role: .cancel) { stopping = nil }
        } message: { task in
            Text("\(task.title.isEmpty ? "This task" : task.title) stops where it is. What already ran is still charged.")
        }
    }

    private func card(_ task: KadeBackgroundTask) -> some View {
        let conversationId = task.openableConversationId
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title.isEmpty ? "A background task" : task.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.agentName.isEmpty {
                    Text(task.agentName).font(.subheadline)
                }
                Text(KadeSoulWords.taskStatusWords(task.status)).fontWeight(.semibold)
                if task.status == "done", !task.preview.isEmpty {
                    Text(task.preview).fixedSize(horizontal: false, vertical: true)
                }
                if task.status == "failed", !task.error.isEmpty {
                    Text(task.error).fixedSize(horizontal: false, vertical: true)
                }
                if let cost = KadeSoulWords.costWords(chargedUSD: task.chargedUSD, quotedMostUSD: task.quotedMostUSD) {
                    Text(cost).font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KadeSoulWords.taskSpoken(task))
            .accessibilityAddTraits(.isHeader)
            .accessibilityActions {
                if let conversationId {
                    Button("Open the conversation") { open(conversationId) }
                }
                if task.isRunning {
                    Button("Stop it") { stopping = task }
                }
            }

            if conversationId != nil || task.isRunning {
                HStack(spacing: 12) {
                    if let conversationId {
                        Button("Open the conversation") { open(conversationId) }
                            .buttonStyle(.bordered)
                    }
                    if task.isRunning {
                        Button(stoppingId == task.id ? "Stopping…" : "Stop it", role: .destructive) {
                            stopping = task
                        }
                        .buttonStyle(.bordered)
                        .disabled(stoppingId != nil)
                    }
                }
                .accessibilityHidden(voiceOverOn)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The same door the "conversation" push uses (ContentView); a chat that
    /// can't be loaded is said out loud there.
    private func open(_ conversationId: String) {
        navigation.openConversationId(conversationId)
    }

    private func refresh() {
        work = Task { await load() }
    }

    @MainActor
    private func load(quiet: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        status = loaded ? "Checking your background tasks…" : "Loading your background tasks…"
        if !quiet { KadeSoulSpeech.polite(status) }
        let request = apiClient.request(path: "api/kade/soul/tasks/list", authorized: true)
        do {
            let (data, http) = try await apiClient.send(request)
            guard http.statusCode == 200 else {
                status = http.statusCode == 401
                    ? "Please sign in again to check your background tasks."
                    : "Couldn't check your background tasks." + (loaded ? " Your previous list is still here." : "") + " Try Refresh."
                if !quiet { KadeSoulSpeech.polite(status) }
                return
            }
            guard let list = try? JSONDecoder().decode(KadeBackgroundTaskList.self, from: data) else {
                status = "Couldn't read your background tasks. Try Refresh."
                if !quiet { KadeSoulSpeech.polite(status) }
                return
            }
            tasks = list.tasks
            loaded = true
            status = KadeSoulWords.taskListSummary(tasks)
            if !quiet { KadeSoulSpeech.polite(status) }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                status = "Check your background tasks when you are ready."
                return
            }
            status = "Connection lost." + (loaded ? " Your previous list is still here." : "") + " Try Refresh when you are online."
            if !quiet { KadeSoulSpeech.polite(status) }
        }
    }

    private func stop(_ task: KadeBackgroundTask) {
        stopping = nil
        guard stoppingId == nil else { return }
        stoppingId = task.id
        work = Task { @MainActor in
            var request = apiClient.request(
                path: "api/kade/soul/tasks/\(task.taskId)/cancel",
                method: "POST",
                authorized: true
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            let spoken: String
            do {
                let (data, http) = try await apiClient.send(request)
                let reply = try? JSONDecoder().decode(BackgroundTaskCancelReply.self, from: data)
                if http.statusCode == 200, reply?.ok != false {
                    let note = (reply?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    spoken = note.isEmpty ? "Stopped." : note
                } else if http.statusCode == 409 {
                    spoken = KadeSoulWords.stopRefusedWords(reply?.error)
                } else {
                    spoken = "Couldn't stop it right now. Try again in a moment."
                }
            } catch {
                spoken = "Couldn't stop it. Check your connection and try again."
            }
            stoppingId = nil
            await load(quiet: true)
            KadeSoulSpeech.result(spoken)
        }
    }
}
