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
///
/// Layout notes (added 2026-07-19, after Kade's real-use feedback that a
/// flat alphabetical list of her ~221 owned agents was "spammy and hard
/// to scroll through," asking for something quicker with "short
/// explanatory labels"): when NOT searching, the list is now a Recent
/// section (your last few picks, fastest path back to who you just used)
/// followed by real category sections straight off the server's own
/// `category` field. While searching, it collapses back to one flat
/// filtered list, since search already does the narrowing.
struct AgentPickerView: View {
    @EnvironmentObject private var agentsService: AgentsService
    let currentAgentId: String?
    let onSelect: (KadeAgent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filtered: [KadeAgent] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return agentsService.agents }
        return agentsService.agents.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.description ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var recentAgents: [KadeAgent] {
        let byId = Dictionary(uniqueKeysWithValues: agentsService.agents.map { ($0.id, $0) })
        return RecentAgents.ids.compactMap { byId[$0] }
    }

    /// Groups the full agent list by their server-provided `category`
    /// (companions, roleplay, personal, expert, creative, ...), sorted
    /// alphabetically with an "Other" bucket last for anything missing a
    /// category. Each bucket is itself sorted by agent name.
    private var groupedByCategory: [(title: String, agents: [KadeAgent])] {
        var buckets: [String: [KadeAgent]] = [:]
        for agent in agentsService.agents {
            let raw = agent.category?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = raw.isEmpty ? "Other" : raw
            buckets[key, default: []].append(agent)
        }
        let sortedKeys = buckets.keys.sorted { lhs, rhs in
            if lhs == "Other" { return false }
            if rhs == "Other" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return sortedKeys.map { key in
            (
                title: key.localizedCapitalized,
                agents: buckets[key]!.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
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
                } else if agentsService.agents.isEmpty {
                    Text("No agents available.")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isSearching && filtered.isEmpty {
                    Text("No agents match \"\(searchText)\".")
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
        List {
            if isSearching {
                ForEach(filtered) { agent in
                    rowButton(for: agent)
                }
            } else {
                if !recentAgents.isEmpty {
                    Section {
                        ForEach(recentAgents) { agent in
                            rowButton(for: agent)
                        }
                    } header: {
                        Text("Recent")
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                ForEach(groupedByCategory, id: \.title) { group in
                    Section {
                        ForEach(group.agents) { agent in
                            rowButton(for: agent)
                        }
                    } header: {
                        Text(group.title)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// One row, wired up identically everywhere it's used (Recent section,
    /// category sections, and the flat search results) so there's exactly
    /// one place that owns the accessibility contract instead of three
    /// copies that could drift apart.
    private func rowButton(for agent: KadeAgent) -> some View {
        Button {
            RecentAgents.record(agent.id)
            onSelect(agent)
            dismiss()
        } label: {
            row(for: agent)
        }
        .buttonStyle(.plain)
        // Grouping lives on the Button itself, not nested inside its
        // label (row(for:)) -- the same fix applied across
        // ConversationListView this session after Kade's first real
        // pass found rows that select but don't activate when the
        // wrapping is on the label subtree instead of the control.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleLabel(for: agent, isSelected: agent.id == currentAgentId))
        .accessibilityAddTraits(agent.id == currentAgentId ? [.isSelected] : [])
        .accessibilityHint("Switches to this agent for your next message.")
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
    }

    private func accessibleLabel(for agent: KadeAgent, isSelected: Bool) -> String {
        var parts = [agent.name]
        if let description = agent.description, !description.isEmpty {
            parts.append(shortDescription(description))
        }
        if isSelected { parts.append("Currently selected") }
        return parts.joined(separator: ". ")
    }

    /// Kade's ask was "short explanatory labels" -- this is separate from
    /// the visual `.lineLimit(2)` truncation on the row, because VoiceOver
    /// reads the FULL accessibility label regardless of how much text fits
    /// on screen. Caps to the first sentence, or ~90 characters if there's
    /// no sentence break, so scanning 221 agents by ear doesn't mean
    /// sitting through a paragraph per row.
    private func shortDescription(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        if let firstEnderIndex = trimmed.firstIndex(where: { sentenceEnders.contains($0) }) {
            let sentence = trimmed[..<trimmed.index(after: firstEnderIndex)]
            if sentence.count <= 120 {
                return String(sentence)
            }
        }
        let limit = 90
        if trimmed.count <= limit { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<cutoff]) + "…"
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

/// Lightweight, non-sensitive "recently used agents" tracker. Deliberately
/// backed by UserDefaults, not Keychain -- Keychain in this app is reserved
/// for sensitive data (access token, user record; see Keychain.swift), and
/// which characters you've picked recently doesn't belong there.
enum RecentAgents {
    private static let key = "kade.recentAgentIds"
    private static let maxEntries = 8

    static var ids: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ id: String) {
        var current = ids
        current.removeAll { $0 == id }
        current.insert(id, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        UserDefaults.standard.set(current, forKey: key)
    }
}

#Preview {
    let client = KadeAPIClient()
    return AgentPickerView(currentAgentId: nil, onSelect: { _ in })
        .environmentObject(AgentsService(client: client))
}
