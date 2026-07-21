import SwiftUI
import UIKit

/// Agent Builder — your own agents: list, create, edit, delete, duplicate.
/// See `AgentBuilderService` for the server contract and exactly what's
/// deliberately not wired up yet. VoiceOver notes mirror
/// `ConversationListView`/`RoomListView`'s proven row pattern: a plain
/// Button driving local navigation state, `.ignore` + explicit label
/// (never `.combine`), Delete as both a rotor action and a swipe action.
struct AgentManagerView: View {
    @StateObject private var service: AgentBuilderService
    private let apiClient: KadeAPIClient
    private let currentUserId: String

    init(apiClient: KadeAPIClient, currentUserId: String) {
        self.apiClient = apiClient
        self.currentUserId = currentUserId
        _service = StateObject(wrappedValue: AgentBuilderService(client: apiClient))
    }

    @State private var agents: [AgentSummary] = []
    @State private var hasLoaded = false
    // ONE sheet-driving value covering both create and edit -- two
    // separate `.sheet` modifiers at the same level is a proven-unreliable
    // pattern in this app (one can silently win and the other never
    // present, the exact bug `DescribeView` folded away for the same
    // reason). `AgentSheet` is the single source of truth for which mode,
    // if any, is showing.
    @State private var activeSheet: AgentSheet?
    @State private var deletingAgent: AgentSummary?
    @State private var isDeleting = false
    @State private var isDuplicating = false

    private enum AgentSheet: Identifiable {
        case new
        case edit(String)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let agentId): return "edit:\(agentId)"
            }
        }
    }

    var body: some View {
        Group {
            if let error = service.loadError, agents.isEmpty {
                errorState(error)
            } else if service.isLoading && !hasLoaded {
                ProgressView("Loading your agents…")
                    .accessibilityLabel("Loading your agents")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if agents.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Agent Builder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .new
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New agent")
                .accessibilityHint("Create a new companion from scratch.")
            }
        }
        .task {
            guard !hasLoaded else { return }
            await reload()
            hasLoaded = true
        }
        .refreshable { await reload() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .new:
                AgentEditorView(apiClient: apiClient, existingId: nil) {
                    Task { await reload() }
                }
            case .edit(let agentId):
                AgentEditorView(apiClient: apiClient, existingId: agentId) {
                    Task { await reload() }
                }
            }
        }
        .alert(
            "Delete this agent?",
            isPresented: Binding(
                get: { deletingAgent != nil },
                set: { if !$0 { deletingAgent = nil } }
            ),
            presenting: deletingAgent
        ) { agent in
            Button("Delete", role: .destructive) {
                Task { await confirmDelete(agent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { agent in
            Text("Deletes \"\(agent.name)\" for good. Conversations you already had with it stay in your history.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No agents of your own yet.")
                .font(.headline)
            Text("Build a companion with their own name, persona, and voice in the conversation.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New agent") { activeSheet = .new }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            Button("Try again") { Task { await reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(agents) { agent in
                Button {
                    activeSheet = .edit(agent.id)
                } label: {
                    row(for: agent)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibleLabel(for: agent))
                .accessibilityHint("Opens this agent to edit it.")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingAgent = agent
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await duplicate(agent) }
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(for agent: AgentSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.name).font(.body)
            if let description = agent.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibleLabel(for agent: AgentSummary) -> String {
        var parts = [agent.name]
        if let description = agent.description, !description.isEmpty { parts.append(description) }
        return parts.joined(separator: ". ")
    }

    private func reload() async {
        agents = await service.loadMyAgents(authoredByUserId: currentUserId)
        hasLoaded = true
    }

    /// Server-side clone (`POST /:id/duplicate`) — the copy lands in the
    /// list with a timestamped name, ready to rename and edit. Spoken
    /// confirmation because the only visual change is a new row appearing.
    private func duplicate(_ agent: AgentSummary) async {
        guard !isDuplicating else { return }
        isDuplicating = true
        defer { isDuplicating = false }
        do {
            let copy = try await service.duplicateAgent(id: agent.id)
            await reload()
            UIAccessibility.post(
                notification: .announcement,
                argument: "Duplicated. \(copy.name ?? agent.name) is in your list, ready to edit."
            )
        } catch {
            let message = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't duplicate that agent."
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func confirmDelete(_ agent: AgentSummary) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await service.deleteAgent(id: agent.id)
            agents.removeAll { $0.id == agent.id }
        } catch {
            // Fail-soft, matching RoomListView's delete: the row stays,
            // she can try the swipe/rotor action again.
        }
        deletingAgent = nil
    }
}
