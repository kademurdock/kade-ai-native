import SwiftUI

/// Phase 4: pick which agent/character answers the NEXT message in an
/// open conversation.
///
/// This does not change anything about the conversation itself server-side —
/// the fork reads `agent_id` fresh off EACH send request rather than locking
/// a conversation to whichever agent started it. Confirmed live 2026-07-19:
/// sent a second turn in the same conversationId with a different `agent_id`
/// than the first turn, and the reply came back attributed to the NEW agent
/// while the first turn's reply stayed attributed to the original one (see
/// docs/ENDPOINTS.md). So "switching" here is purely client-side state —
/// which id this view hands back to `ConversationDetailView`, which passes
/// it to `MessageSendingService.send` on the next send.
///
/// VoiceOver notes: search uses the standard `.searchable` field (rotor-
/// reachable); each row is one combined element (name + description +
/// "Currently selected" when applicable) with a clear hint of what tapping
/// does, matching the row pattern used in `ConversationListView`.
struct AgentPickerView: View {
    @EnvironmentObject private var agentsService: AgentsService
    let currentAgentId: String?
    let onSelect: (KadeAgent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [KadeAgent] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return agentsService.agents }
        return agentsService.agents.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.description ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if agentsService.isLoading && agentsService.agents.isEmpty {
                    ProgressView("Loading agents…")
                        .accessibilityLabel("Loading agents")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = agentsService.loadError, agentsService.agents.isEmpty {
                    errorState(error)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    Text(searchText.isEmpty ? "No agents available." : "No agents match \"\(searchText)\".")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .navigationTitle("Choose agent")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search agents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await agentsService.loadIfNeeded() }
        }
    }

    private var list: some View {
        List(filtered) { agent in
            Button {
                onSelect(agent)
                dismiss()
            } label: {
                row(for: agent)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    private func row(for agent: KadeAgent) -> some View {
        let isSelected = agent.id == currentAgentId
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.body)
                if let description = agent.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleLabel(for: agent, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Switches to this agent for your next message.")
    }

    private func accessibleLabel(for agent: KadeAgent, isSelected: Bool) -> String {
        var parts = [agent.name]
        if let description = agent.description, !description.isEmpty {
            parts.append(description)
        }
        if isSelected { parts.append("Currently selected") }
        return parts.joined(separator: ". ")
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            Button("Try again") { Task { await agentsService.loadIfNeeded() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    let client = KadeAPIClient()
    return AgentPickerView(currentAgentId: nil, onSelect: { _ in })
        .environmentObject(AgentsService(client: client))
}
