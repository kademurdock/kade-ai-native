import SwiftUI

/// Connections — handoff edges from this agent to others. "Connect Big Tom
/// to Kiana" means: mid-conversation, this agent can hand the caller off to
/// that one when the topic fits. The web's Advanced panel authors exactly
/// `{from, to, edgeType: "handoff"}` (see AgentBuilderService's edges
/// section for the receipts); native ships add + remove, while editing an
/// edge's optional description/prompt refinements stays a web affair for
/// now — written down here so nobody mistakes that for an accident.
struct AgentConnectionsView: View {
    let apiClient: KadeAPIClient
    let agentId: String
    let agentName: String

    @StateObject private var service: AgentBuilderService

    init(apiClient: KadeAPIClient, agentId: String, agentName: String) {
        self.apiClient = apiClient
        self.agentId = agentId
        self.agentName = agentName
        _service = StateObject(wrappedValue: AgentBuilderService(client: apiClient))
    }

    private static let maxEdges = 10   // mirrors the web's MAX_HANDOFFS

    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var edges: [[String: Any]] = []
    @State private var allAgents: [AgentSummary] = []
    @State private var filter = ""
    @State private var statusText: String?
    @AccessibilityFocusState private var statusFocused: Bool

    /// Stable-enough row identity for a raw edge: target + position.
    private struct EdgeRow: Identifiable {
        let index: Int
        let raw: [String: Any]
        let targetLabel: String
        let detail: String?
        var id: String { "\(index)-\(targetLabel)" }
    }

    private var edgeRows: [EdgeRow] {
        edges.enumerated().map { index, raw in
            EdgeRow(
                index: index,
                raw: raw,
                targetLabel: targetLabel(raw),
                detail: (raw["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    private var existingTargets: Set<String> {
        var out: Set<String> = []
        for raw in edges {
            if let s = raw["to"] as? String { out.insert(s) }
            if let arr = raw["to"] as? [String] { out.formUnion(arr) }
        }
        return out
    }

    private var addCandidates: [AgentSummary] {
        let taken = existingTargets
        let base = allAgents.filter { $0.id != agentId && !taken.contains($0.id) }
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        let matched = trimmed.isEmpty
            ? base
            : base.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        return Array(matched.prefix(8))
    }

    var body: some View {
        List {
            if let statusText {
                Section {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityFocused($statusFocused)
                }
            }

            Section {
                if isLoading && edges.isEmpty {
                    ProgressView("Loading…")
                        .accessibilityLabel("Loading connections")
                } else if edges.isEmpty {
                    Text("No connections yet. \(agentName) can only ever answer alone until you add one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(edgeRows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hands off to \(row.targetLabel)")
                                .font(.body)
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Hands off to \(row.targetLabel).\(row.detail.map { " " + $0 } ?? "")")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await remove(at: row.index) }
                            } label: {
                                Text("Remove")
                            }
                        }
                        .accessibilityAction(named: "Remove") {
                            Task { await remove(at: row.index) }
                        }
                    }
                }
            } header: {
                Text("Who \(agentName) can hand off to")
            } footer: {
                Text("Mid-conversation, \(agentName) can pass the person to a connected companion when the topic fits. Up to \(Self.maxEdges) connections.")
            }

            if edges.count < Self.maxEdges {
                Section {
                    TextField("Type a name to narrow the list", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Search companions")
                        .accessibilityHint("Narrows the list of companions below.")

                    if allAgents.isEmpty && !isLoading {
                        Text("Couldn't load the companion list. Pull down to try again.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(addCandidates) { agent in
                            Button {
                                Task { await add(agent) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .foregroundStyle(Color.primary)
                                    if let d = agent.description, !d.isEmpty {
                                        Text(d)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .accessibilityLabel("Connect \(agent.name)")
                            .accessibilityHint("Adds \(agent.name) as a handoff target for \(agentName).")
                        }
                    }
                } header: {
                    Text("Add a connection")
                }
            }
        }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .refreshable { await load() }
    }

    private func targetLabel(_ raw: [String: Any]) -> String {
        let names: (String) -> String = { id in
            allAgents.first(where: { $0.id == id })?.name ?? id
        }
        if let s = raw["to"] as? String { return names(s) }
        if let arr = raw["to"] as? [String] { return arr.map(names).joined(separator: ", ") }
        return "unknown"
    }

    private func load() async {
        isLoading = true
        do {
            async let expandedTask = service.loadExpandedRaw(id: agentId)
            async let agentsTask = service.loadAllAgents()
            let expanded = try await expandedTask
            allAgents = await agentsTask
            edges = (expanded["edges"] as? [[String: Any]]) ?? []
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't load the connections. Pull down to try again."
            statusFocused = true
        }
        isLoading = false
    }

    private func add(_ agent: AgentSummary) async {
        guard edges.count < Self.maxEdges else { return }
        // Fresh read right before the write — another device could have
        // edited this agent since our last load, and a stale append would
        // silently drop that edit.
        do {
            let expanded = try await service.loadExpandedRaw(id: agentId)
            var current = (expanded["edges"] as? [[String: Any]]) ?? []
            guard current.count < Self.maxEdges else {
                statusText = "This agent already has \(Self.maxEdges) connections — remove one first."
                statusFocused = true
                return
            }
            current.append([
                "from": agentId,
                "to": agent.id,
                "edgeType": "handoff",
            ])
            try await service.updateEdges(id: agentId, edges: current)
            filter = ""
            statusText = "Connected. \(agentName) can now hand off to \(agent.name)."
            await load()
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't add that connection. Try again."
        }
        statusFocused = true
    }

    private func remove(at index: Int) async {
        do {
            let expanded = try await service.loadExpandedRaw(id: agentId)
            var current = (expanded["edges"] as? [[String: Any]]) ?? []
            guard index < current.count else {
                await load()
                return
            }
            let label = targetLabel(current[index])
            current.remove(at: index)
            try await service.updateEdges(id: agentId, edges: current)
            statusText = "Removed the connection to \(label)."
            await load()
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't remove that connection. Try again."
        }
        statusFocused = true
    }
}
