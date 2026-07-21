import SwiftUI

/// Custom actions on one agent — API-backed abilities created in the web
/// Agent Builder (each is an OpenAPI spec the server validated and turned
/// into callable tools). Native scope, said plainly: LIST and REMOVE.
/// Creating one requires pasting an API description the client must parse
/// (the web uses librechat-data-provider's own OpenAPI parser), so creation
/// stays a web affair and this screen says so out loud instead of hiding
/// the button. See AgentBuilderService's actions section for the contract.
struct AgentActionsView: View {
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

    private struct ActionRow: Identifiable {
        let raw: [String: Any]
        var id: String { (raw["action_id"] as? String) ?? UUID().uuidString }
        var actionId: String? { raw["action_id"] as? String }
        var domain: String {
            guard let meta = raw["metadata"] as? [String: Any],
                  let domain = meta["domain"] as? String, !domain.isEmpty else {
                return "Unnamed action"
            }
            return domain
        }
    }

    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var rows: [ActionRow] = []
    @State private var statusText: String?
    @AccessibilityFocusState private var statusFocused: Bool

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
                if isLoading && rows.isEmpty {
                    ProgressView("Loading…")
                        .accessibilityLabel("Loading actions")
                } else if rows.isEmpty {
                    Text("No custom actions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        Text(row.domain)
                            .font(.body)
                            .accessibilityLabel("Action for \(row.domain)")
                            // swipeActions ONLY — see ConversationListView's
                            // rule; an explicit .accessibilityAction would
                            // double the rotor entry.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await remove(row) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("Actions on \(agentName)")
            } footer: {
                Text("Each action lets \(agentName) call an outside service — check a balance, place an order, look something up. Removing one takes that ability away immediately.")
            }

            Section {
                Text("Creating an action needs a pasted API description, which only the web builder can check and convert. Open Kade-AI web from the home screen, then Agent Builder, to add one — it shows up here afterward.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Adding actions")
            }
        }
        .navigationTitle("Actions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            let raw = try await service.loadActions(agentId: agentId)
            rows = raw.map { ActionRow(raw: $0) }
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't load the actions. Pull down to try again."
            statusFocused = true
        }
        isLoading = false
    }

    private func remove(_ row: ActionRow) async {
        guard let actionId = row.actionId else {
            statusText = "That action has no id — remove it from the web instead."
            statusFocused = true
            return
        }
        do {
            try await service.deleteAction(agentId: agentId, actionId: actionId)
            statusText = "Removed the \(row.domain) action."
            await load()
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't remove that action. Try again."
        }
        statusFocused = true
    }
}
