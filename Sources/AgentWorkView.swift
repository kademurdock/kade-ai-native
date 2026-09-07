import SwiftUI
import UIKit

private struct AgentWorkItem: Decodable, Identifiable {
    let taskId: String
    let conversationId: String
    let status: String
    let title: String
    let createdAt: String
    let canOpenConversation: Bool
    var id: String { taskId }

    var statusLabel: String {
        switch status {
        case "starting": return "Starting"
        case "running": return "Working"
        case "completed": return "Reply saved"
        case "stopped": return "Stopped"
        case "failed": return "Could not finish"
        case "interrupted": return "Interrupted"
        default: return "Status unavailable"
        }
    }

    var dateLabel: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: createdAt) else { return createdAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AgentWorkPage: Decodable {
    let tasks: [AgentWorkItem]
    let nextCursor: String?
}
private struct WorkOptions: Decodable { let codingJobs: Bool }

/// Request receipts are read-only here; opening a saved chat never resends a turn.
struct AgentWorkView: View {
    let apiClient: KadeAPIClient
    var selectedRunId: String? = nil
    let onOpenConversation: (KadeConversation) -> Void
    @EnvironmentObject private var conversationsService: ConversationsService
    @State private var items: [AgentWorkItem] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var codingJobs = false
    @State private var status = "Loading your requests…"
    @State private var openingID: String?
    @State private var blocked = false
    @State private var loadTask: Task<Void, Never>?
    @AccessibilityFocusState private var focusedTask: String?

    var body: some View {
      if let selectedRunId {
        CodingWorkView(apiClient: apiClient, runId: selectedRunId)
      } else {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Check work after a connection drops. Open the chat to read the reply or stop a running request.")
                if codingJobs { NavigationLink("Coding jobs") { CodingWorkView(apiClient: apiClient) } }
                Text(status)
                    .font(.subheadline)
                    .accessibilityAddTraits(.updatesFrequently)
                Button("Refresh requests") { refresh() }
                    .buttonStyle(.borderedProminent)
                    .disabled(blocked || loading || openingID != nil)
                    .accessibilityHint("Checks existing work. Does not send your message again.")

                if loaded && items.isEmpty {
                    Text("No requests to show yet. New ordinary chat requests appear here. Your earlier conversations are still in Conversations.")
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($focusedTask, equals: item.id)
                        Text(item.statusLabel).fontWeight(.semibold)
                        Text(item.dateLabel).font(.subheadline)
                        if item.canOpenConversation {
                            Button(openingID == item.id ? "Opening chat…" : "Open chat") {
                                open(item)
                            }
                            .buttonStyle(.bordered)
                            .disabled(blocked || loading || openingID != nil)
                            .accessibilityLabel("Open chat: \(item.title), \(item.dateLabel)")
                        } else {
                            Text(item.status == "running" || item.status == "starting"
                                 ? "The chat is not saved yet. Check again in a moment."
                                 : "No saved chat is available for this request.")
                                .font(.subheadline)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                if cursor != nil {
                    Button("Show older requests") {
                        loadTask = Task { await load(older: true) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(blocked || loading || openingID != nil)
                }
                Text("About these statuses").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Reply saved means the agent's reply is in the chat. Read it for evidence of any action. Interrupted means a finished reply could not be confirmed; check the chat and action receipts before sending again. Stopping a run does not undo actions it already performed.")
                Text("Temporary chats, regenerated replies and separate voice or coding sessions may not appear. Interrupted work does not automatically restart.")
                    .font(.subheadline)
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Agent work")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
        .onDisappear { loadTask?.cancel() }
      }
    }

    private func refresh() {
        loadTask = Task { await load() }
    }

    @MainActor
    private func load(older: Bool = false) async {
        guard !loading && !blocked else { return }
        focusedTask = nil
        loading = true
        defer {
            loading = false
            if !Task.isCancelled && focusedTask == nil {
                UIAccessibility.post(notification: .announcement, argument: status)
            }
        }
        status = older ? "Loading older requests…" : "Checking your requests…"
        do {
            if !loaded {
                let optionsRequest = apiClient.request(path: "api/kade/work-options", authorized: true)
                let (optionsData, optionsResponse) = try await apiClient.send(optionsRequest)
                try Task.checkCancellation()
                if optionsResponse.statusCode == 403 {
                    blocked = true
                    status = "Access was refused. Requests have stopped."
                    return
                }
                if optionsResponse.statusCode == 200 {
                    codingJobs = try JSONDecoder().decode(WorkOptions.self, from: optionsData).codingJobs
                }
            }
            let query = older ? cursor.map { [URLQueryItem(name: "before", value: $0)] } ?? [] : []
            let req = apiClient.request(path: "api/agents/chat/tasks", authorized: true, queryItems: query)
            let (data, http) = try await apiClient.send(req)
            try Task.checkCancellation()
            guard http.statusCode == 200 else {
                if http.statusCode == 403 {
                    blocked = true
                    status = "Access was refused. Requests have stopped. Please try again later."
                    return
                }
                status = http.statusCode == 401
                    ? "Please sign in again to check your requests."
                    : "Could not check your requests. Your previous list is still here. Try Refresh."
                return
            }
            let page = try JSONDecoder().decode(AgentWorkPage.self, from: data)
            let existing = older ? Set(items.map(\.id)) : []
            let fresh = page.tasks.filter { !existing.contains($0.id) }
            items = older ? items + fresh : fresh
            cursor = page.nextCursor
            loaded = true
            status = "\(items.count) \(items.count == 1 ? "request" : "requests") shown."
            if older { focusedTask = fresh.first?.id }
        } catch is CancellationError {
            status = "Check your requests when you are ready."
        } catch {
            status = "Connection lost. Your previous list is still here. Try Refresh when you are online."
        }
    }

    private func open(_ item: AgentWorkItem) {
        guard openingID == nil else { return }
        openingID = item.id
        loadTask = Task { @MainActor in
            defer { openingID = nil }
            let conversation = await conversationsService.fetchConversation(id: item.conversationId)
            guard !Task.isCancelled else { return }
            if let conversation {
                onOpenConversation(conversation)
            } else {
                status = "The chat could not be opened. It may have been deleted, or your connection may have dropped. Try Refresh."
                UIAccessibility.post(notification: .announcement, argument: status)
            }
        }
    }
}
