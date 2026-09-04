import SwiftUI

/// MEMORY SHARING (Part 128, Sep 4 2026). Her ask, via Amber A: "she wants
/// Kiana and Della to have access to each other's memories so she doesn't
/// have to tell either of them something twice."
///
/// The split the server enforces: FACTS (memory cards, logbook lines) can be
/// read across the companions this seat talks to, labelled secondhand;
/// OPINIONS (each companion's take, its carried thread, what it has learned,
/// its canon) never are — those are what make each companion itself.
///
/// GET/PUT /api/kade/memory-share — { mode: off|all|list, agents, companions }.
@MainActor
final class MemorySharingService: ObservableObject {
    struct Companion: Decodable, Identifiable, Equatable {
        let agentId: String
        let name: String
        var id: String { agentId }
    }
    struct Setting: Decodable {
        let mode: String
        let agents: [String]
        let companions: [Companion]?
    }
    private struct ServerError: Decodable { let error: String? }
    struct SharingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let client: KadeAPIClient
    init(client: KadeAPIClient) { self.client = client }

    func load() async throws -> Setting {
        let req = client.request(path: "api/kade/memory-share", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw SharingError(message: "Could not read the sharing setting (\(http.statusCode)).") }
        return try JSONDecoder().decode(Setting.self, from: data)
    }

    func save(mode: String, agents: [String]) async throws {
        var req = client.request(path: "api/kade/memory-share", method: "PUT", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode, "agents": agents])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(ServerError.self, from: data))?.error ?? "Could not save that (\(http.statusCode))."
            throw SharingError(message: msg)
        }
    }
}

struct MemorySharingView: View {
    @StateObject private var service: MemorySharingService
    @State private var mode = "off"
    @State private var agents: Set<String> = []
    @State private var companions: [MemorySharingService.Companion] = []
    @State private var isLoading = true
    @State private var note: String?
    @State private var saving = false

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: MemorySharingService(client: apiClient))
    }

    var body: some View {
        Form {
            Section {
                Text("Your companions each keep their own memories of you. Sharing lets them read the facts the others were told — memory cards and logbook lines — marked as secondhand, so you never have to say a thing twice. Their opinions, and their own read of you, stay their own.")
                    .font(.callout)
            }
            if isLoading {
                Section { ProgressView("Loading the sharing setting…") }
            } else {
                Section("Who shares") {
                    Picker("Sharing", selection: $mode) {
                        Text("Off — each companion knows only what you told it").tag("off")
                        Text("All my companions").tag("all")
                        Text("Only the companions I pick").tag("list")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if mode == "list" {
                    Section("Pick who shares with each other") {
                        if companions.count < 2 {
                            Text("Only one companion has memories of you so far, so there is nobody to share with yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(companions) { c in
                            Toggle(c.name, isOn: Binding(
                                get: { agents.contains(c.agentId) },
                                set: { on in if on { agents.insert(c.agentId) } else { agents.remove(c.agentId) } }
                            ))
                        }
                    }
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Save sharing") }
                    }
                    .disabled(saving || (mode == "list" && agents.count < 2))
                    .accessibilityHint(mode == "list" && agents.count < 2 ? "Pick at least two companions first." : "Takes effect on your next message.")
                    if let note {
                        Text(note)
                            .font(.callout)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
        }
        .navigationTitle("Memory sharing")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            let s = try await service.load()
            mode = s.mode
            agents = Set(s.agents)
            companions = s.companions ?? []
            note = nil
        } catch {
            note = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        saving = true
        do {
            try await service.save(mode: mode, agents: Array(agents))
            note = "Saved. It takes effect on your next message."
            UIAccessibility.post(notification: .announcement, argument: "Sharing saved.")
        } catch {
            note = error.localizedDescription
        }
        saving = false
    }
}
