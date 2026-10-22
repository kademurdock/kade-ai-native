import SwiftUI
import Security

struct KadeWorkspaceProject: Decodable, Identifiable {
    let id: String
    let name: String
    let deviceId: String
    let allowEdits: Bool?
}

struct KadeWorkspaceDevice: Decodable, Identifiable {
    let id: String
    let name: String
    let capabilities: [String]?
    let revokedAt: String?
    let lastSeenAt: String?
}

struct KadeWorkspaceSession: Decodable, Identifiable {
    let id: String
    let projectId: String
    let title: String
    let runtime: String
    let model: String?
}

struct KadeWorkspaceRun: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let projectId: String
    let prompt: String
    let state: String
    let mode: String?
    let lastSequence: Int?
    let seenSequence: Int?
    let needsAttention: Bool?
    var active: Bool { ["queued", "running", "stopping"].contains(state) }
    func markingSeen(through sequence: Int) -> KadeWorkspaceRun {
        KadeWorkspaceRun(id: id, sessionId: sessionId, projectId: projectId, prompt: prompt,
            state: state, mode: mode, lastSequence: lastSequence,
            seenSequence: max(seenSequence ?? 0, sequence), needsAttention: needsAttention)
    }
    var statusWords: String {
        switch state {
        case "queued": return "Waiting for your computer"
        case "running": return "Working"
        case "stopping": return "Stopping"
        case "done": return "Finished"
        case "failed": return "Could not finish"
        case "stopped": return "Stopped"
        case "interrupted": return "Interrupted; review the saved actions"
        default: return "Status unavailable"
        }
    }
}

struct KadeWorkspaceEvent: Decodable, Identifiable {
    let sequence: Int
    let type: String
    let text: String?
    let state: String?
    let data: [String: String]?
    var id: Int { sequence }
    var costWords: String? {
        guard type == "result", let raw = data?["costUsd"] else { return nil }
        guard let cost = Double(raw), cost.isFinite, cost >= 0 else { return "Model cost: not reported." }
        return "Model cost: $" + String(format: "%.6f", cost) + "."
    }
    var usageWords: String? {
        guard type == "result", let raw = data?["usage"], let bytes = raw.data(using: .utf8),
              let usage = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        let fields = [("input_tokens", "input"), ("cached_input_tokens", "cached input"), ("output_tokens", "output"), ("total_tokens", "total")]
        let parts = fields.compactMap { field, label -> String? in
            guard let count = usage[field] as? Int, count >= 0 else { return nil }
            return "\(label) \(count)"
        }
        return parts.isEmpty ? nil : "Tokens: " + parts.joined(separator: ", ") + "."
    }
}

private struct WorkspacePendingStart: Codable {
    let projectId: String
    let prompt: String
    let runtime: String
    let model: String?
    let allowEdits: Bool
    let sessionRequestId: String
    let runRequestId: String
    var sessionId: String?
}

/// Private prompts and stable request identifiers stay in this account's Keychain.
/// Persisting before the first POST lets an explicit retry recover its receipt.
private enum WorkspaceStartJournal {
    static func account() -> String? {
        guard let data = Keychain.data(for: .user),
              let user = try? JSONDecoder().decode(KadeUser.self, from: data) else { return nil }
        return user.id
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.kademurdock.kadeai.workspace-start",
         kSecAttrAccount as String: account]
    }
    static func load(_ account: String) -> WorkspacePendingStart? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WorkspacePendingStart.self, from: data)
    }
    static func save(_ pending: WorkspacePendingStart, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        let request = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = request
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    static func clear(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

private struct WorkspaceServiceError: LocalizedError {
    let message: String
    let status: Int?
    init(message: String, status: Int? = nil) { self.message = message; self.status = status }
    var errorDescription: String? { message }
}

@MainActor
private struct WorkspaceAPI {
    let client: KadeAPIClient
    let account: String
    func request<T: Decodable>(_ suffix: String, method: String = "GET", body: [String: Any]? = nil,
                               query: [URLQueryItem]? = nil, as type: T.Type) async throws -> T {
        try Task.checkCancellation()
        guard WorkspaceStartJournal.account() == account else { throw CancellationError() }
        var request = client.request(path: "api/kade/workspaces/" + suffix, method: method, authorized: true, queryItems: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await client.send(request)
        try Task.checkCancellation()
        guard WorkspaceStartJournal.account() == account else { throw CancellationError() }
        guard (200...299).contains(response.statusCode) else {
            let words: String
            switch response.statusCode {
            case 401: words = "Please sign in again to check workspaces."
            case 403: words = "Workspace access was refused."
            case 404: words = "Workspaces are not available on this server yet."
            case 409: words = "This computer already has work, or this request conflicts with saved work. Refresh to check it."
            default: words = "The workspace request could not be completed. Try Refresh."
            }
            throw WorkspaceServiceError(message: words, status: response.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
    }
    func pages<Page: Decodable, Item>(_ suffix: String, as type: Page.Type,
                                     items: (Page) -> [Item], cursor: (Page) -> String?) async throws -> [Item] {
        var output: [Item] = []
        var before: String?
        var previous = Set<String>()
        repeat {
            let page = try await request(suffix, query: before.map { [URLQueryItem(name: "before", value: $0)] }, as: type)
            output += items(page)
            before = cursor(page)
            if let before, !previous.insert(before).inserted {
                throw WorkspaceServiceError(message: "The workspace list stopped before all saved records were loaded. Try Refresh.")
            }
        } while before != nil
        return output
    }
}

private struct WorkspaceProjectsReply: Decodable { let projects: [KadeWorkspaceProject]; let nextCursor: String? }
private struct WorkspaceDevicesReply: Decodable { let devices: [KadeWorkspaceDevice]; let nextCursor: String? }
private struct WorkspaceSessionsReply: Decodable { let sessions: [KadeWorkspaceSession]; let nextCursor: String? }
private struct WorkspaceRunsReply: Decodable { let runs: [KadeWorkspaceRun]; let nextCursor: String? }
private struct WorkspaceSessionReply: Decodable { let session: KadeWorkspaceSession }
private struct WorkspaceRunReply: Decodable { let run: KadeWorkspaceRun }
private struct WorkspaceEventsReply: Decodable { let events: [KadeWorkspaceEvent]; let nextCursor: Int? }
private struct WorkspaceEmptyReply: Decodable {}

@MainActor
struct WorkspaceView: View {
    let apiClient: KadeAPIClient
    @State private var account = WorkspaceStartJournal.account()
    @State private var projects: [KadeWorkspaceProject] = []
    @State private var devices: [KadeWorkspaceDevice] = []
    @State private var sessions: [KadeWorkspaceSession] = []
    @State private var runs: [KadeWorkspaceRun] = []
    @State private var runCursor: String?
    @State private var projectId = ""
    @State private var sessionId = ""
    @State private var runtime = "inspect"
    @State private var model = ""
    @State private var prompt = ""
    @State private var allowEdits = false
    @State private var busy = false
    @State private var status = "Loading workspaces…"
    @State private var pending: WorkspacePendingStart?
    @State private var selectedRunId: String?
    @State private var events: [KadeWorkspaceEvent] = []
    @State private var eventRequestRevision = 0
    @State private var work: Task<Void, Never>?
    @State private var visible = false

    private var api: WorkspaceAPI? { account.map { WorkspaceAPI(client: apiClient, account: $0) } }
    private var project: KadeWorkspaceProject? { projects.first { $0.id == projectId } }
    private var session: KadeWorkspaceSession? { sessions.first { $0.id == sessionId } }
    private var availableSessions: [KadeWorkspaceSession] { sessions.filter { $0.projectId == projectId } }
    private var selectedRun: KadeWorkspaceRun? { runs.first { $0.id == selectedRunId } }
    private var sessionMode: String? { runs.first { $0.sessionId == sessionId }?.mode }
    private var engines: [String] {
        let capabilities = devices.first { $0.id == project?.deviceId }?.capabilities ?? []
        let supported = ["inspect", "codex", "claude", "custom"].filter { capabilities.contains($0) }
        return supported.isEmpty ? ["inspect"] : supported
    }

    var body: some View {
        List {
            Section {
                Text("Choose a folder already shared by your Windows app. Your computer must stay on and connected while its agent works.")
                Text("The folder is the working directory. Codex's sandbox and settings govern access, including which other files it can read.").font(.footnote)
                Text(status).accessibilityAddTraits(.updatesFrequently)
                Button("Refresh workspaces") { refresh() }.disabled(busy)
            }
            if projects.isEmpty {
                Section {
                    Text("On Windows, open Workspaces, enable the computer, then choose a folder. The folder appears here after Refresh.")
                }
            }
            if !projects.isEmpty || pending != nil {
                Section("Start or continue work") {
                    Picker("Workspace", selection: $projectId) {
                        ForEach(projects) { item in Text(item.name).tag(item.id) }
                    }.disabled(busy || pending != nil)
                    if let device = devices.first(where: { $0.id == project?.deviceId }) {
                        Text("Computer: \(device.name)")
                        if device.revokedAt != nil { Text("This computer is disabled. Enable it in the Windows app.") }
                        if let stamp = device.lastSeenAt { Text("Last connected: \(KadeDateFormatting.relative(from: stamp) ?? stamp)") }
                    }
                    Picker("Conversation", selection: $sessionId) {
                        Text("New conversation").tag("")
                        ForEach(availableSessions) { item in Text(item.title).tag(item.id) }
                    }.disabled(busy || pending != nil)
                    if let session {
                        Text("Engine: \(session.runtime). Model: \(session.model ?? "engine default").")
                        Text("Continuing keeps this conversation's edit policy. Choose New conversation to change it.")
                    } else {
                        Picker("Agent engine", selection: $runtime) {
                            ForEach(engines, id: \.self) { engine in
                                Text(engine == "inspect" ? "Folder inspection, no AI charges" : engine.capitalized).tag(engine)
                            }
                        }.disabled(busy || pending != nil)
                        TextField("Model, optional", text: $model).disabled(busy || pending != nil)
                    }
                    Text("What should the agent do?").accessibilityAddTraits(.isHeader)
                    TextEditor(text: $prompt).frame(minHeight: 110)
                        .accessibilityLabel("What should the agent do?")
                        .disabled(busy || pending != nil)
                    if project?.allowEdits == true {
                        Toggle("Allow edits for this run", isOn: $allowEdits).disabled(busy || pending != nil || !sessionId.isEmpty)
                    } else { Text("Read-only workspace. Edit access can be granted on Windows.") }
                    Text("Folder inspection only inventories files. Coding engines use their own account or API billing.")
                        .font(.footnote)
                    if pending != nil {
                        Text("A start may already have been accepted. Check saved start uses the same request identifiers.")
                    }
                    Button(pending == nil ? "Start run" : "Check saved start") { start() }
                        .disabled(busy || (pending == nil && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            Section("Saved work") {
                if runs.isEmpty { Text("No workspace runs yet.") }
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(run.prompt).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(run.statusWords)
                        if (run.lastSequence ?? 0) > (run.seenSequence ?? 0) { Text("New saved actions") }
                        if run.needsAttention == true { Text("Needs your attention") }
                        Button(selectedRunId == run.id ? "Refresh saved actions" : "Read saved actions") {
                            if selectedRunId == run.id { work = Task { await loadEvents(run.id) } }
                            else { events = []; selectedRunId = run.id }
                        }.disabled(busy)
                        if selectedRunId == run.id {
                            ForEach(events) { event in
                                if let text = event.text, !text.isEmpty { Text(text).textSelection(.enabled) }
                                if let cost = event.costWords { Text(cost) }
                                if let usage = event.usageWords { Text(usage) }
                            }
                            if events.isEmpty { Text("No saved actions yet.") }
                        }
                        if run.active {
                            Button("Stop this run", role: .destructive) { stop(run) }.disabled(busy)
                        }
                    }.padding(.vertical, 6)
                }
                if runCursor != nil { Button("Load older runs") { work = Task { await loadOlderRuns() } }.disabled(busy) }
            }
        }
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            visible = true
            if let account, let restored = WorkspaceStartJournal.load(account) {
                pending = restored
                projectId = restored.projectId
                sessionId = restored.sessionId ?? ""
                runtime = restored.runtime
                model = restored.model ?? ""
                prompt = restored.prompt
                allowEdits = restored.allowEdits
            }
            await load()
        }
        .task(id: selectedRunId) {
            guard let identity = selectedRunId else { return }
            repeat {
                await loadEvents(identity)
                let unreadActions = (selectedRun?.lastSequence ?? 0) > (events.map(\.sequence).max() ?? 0)
                guard !Task.isCancelled, selectedRun?.active == true || unreadActions else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: projectId) { _, _ in
            guard pending == nil else { return }
            sessionId = ""
            allowEdits = false
            if !engines.contains(runtime) { runtime = engines.first ?? "inspect" }
        }
        .onChange(of: sessionId) { _, _ in
            guard pending == nil else { return }
            allowEdits = sessionMode == "edit" && project?.allowEdits == true
        }
        .onDisappear {
            visible = false
            work?.cancel()
        }
    }

    private func refresh() { work = Task { await load() } }

    @MainActor private func load() async {
        guard !busy, let api else { return }
        busy = true
        defer { busy = false }
        do {
            let allDevices = try await api.pages("devices", as: WorkspaceDevicesReply.self, items: { $0.devices }, cursor: { $0.nextCursor })
            let allProjects = try await api.pages("projects", as: WorkspaceProjectsReply.self, items: { $0.projects }, cursor: { $0.nextCursor })
            let allSessions = try await api.pages("sessions", as: WorkspaceSessionsReply.self, items: { $0.sessions }, cursor: { $0.nextCursor })
            let runReply = try await api.request("runs", as: WorkspaceRunsReply.self)
            devices = allDevices
            projects = allProjects
            sessions = allSessions
            runs = runReply.runs
            runCursor = runReply.nextCursor
            if !projects.contains(where: { $0.id == projectId }) { projectId = projects.first?.id ?? "" }
            if let pending, let saved = runs.first(where: { $0.sessionId == pending.sessionId && $0.prompt == pending.prompt }) {
                // The stable POST remains authoritative; matching text alone never clears its journal.
                selectedRunId = saved.id
            }
            status = projects.isEmpty ? "No shared folders yet." : "\(projects.count) workspaces. \(runs.count) saved runs."
        } catch is CancellationError {
        } catch { status = error.localizedDescription }
    }

    @MainActor private func loadOlderRuns() async {
        guard !busy, let api, let cursor = runCursor else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await api.request("runs", query: [URLQueryItem(name: "before", value: cursor)], as: WorkspaceRunsReply.self)
            guard reply.nextCursor != cursor else { throw WorkspaceServiceError(message: "Older runs could not be paged. Try Refresh.") }
            let known = Set(runs.map(\.id))
            runs += reply.runs.filter { !known.contains($0.id) }
            runCursor = reply.nextCursor
            status = "\(runs.count) saved runs shown."
        } catch is CancellationError {
        } catch { status = error.localizedDescription }
    }

    @MainActor private func start() {
        guard !busy, let api, let account else { return }
        guard model.utf16.count <= 160, prompt.utf16.count <= 20000 else {
            status = "Use a model name up to 160 characters and a request up to 20,000 characters."
            return
        }
        var request: WorkspacePendingStart
        if let pending { request = pending }
        else {
            guard let project else { return }
            request = WorkspacePendingStart(projectId: project.id, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                runtime: session?.runtime ?? runtime, model: session?.model ?? (model.isEmpty ? nil : model),
                allowEdits: allowEdits && project.allowEdits == true,
                sessionRequestId: UUID().uuidString, runRequestId: UUID().uuidString, sessionId: session?.id)
        }
        guard !request.prompt.isEmpty, WorkspaceStartJournal.save(request, account: account) else {
            status = "Could not save the start receipt on this phone. Nothing was sent."
            return
        }
        pending = request
        busy = true
        status = "Starting the saved request…"
        work = Task { @MainActor in
            do {
                if request.sessionId == nil {
                    var body: [String: Any] = ["requestId": request.sessionRequestId, "projectId": request.projectId,
                        "title": String(request.prompt.prefix(100)), "runtime": request.runtime]
                    if let model = request.model { body["model"] = model }
                    let reply = try await api.request("sessions", method: "POST", body: body, as: WorkspaceSessionReply.self)
                    request.sessionId = reply.session.id
                    pending = request
                    guard WorkspaceStartJournal.save(request, account: account) else {
                        throw WorkspaceServiceError(message: "The conversation was saved, but its receipt could not be saved on this phone. Check saved work before trying again.")
                    }
                }
                let reply = try await api.request("runs", method: "POST", body: ["requestId": request.runRequestId,
                    "sessionId": request.sessionId!, "prompt": request.prompt, "mode": request.allowEdits ? "edit" : "inspect"], as: WorkspaceRunReply.self)
                WorkspaceStartJournal.clear(account)
                pending = nil
                prompt = ""
                allowEdits = false
                sessionId = reply.run.sessionId
                selectedRunId = reply.run.id
                busy = false
                await load()
                status = "Run saved. \(reply.run.statusWords)."
            } catch is CancellationError {
                busy = false
            } catch {
                busy = false
                if let rejection = error as? WorkspaceServiceError, let code = rejection.status,
                   (400...499).contains(code), code != 408 {
                    WorkspaceStartJournal.clear(account)
                    pending = nil
                    status = error.localizedDescription + " The start was refused; your prompt is still here."
                } else {
                    status = error.localizedDescription + " Check saved start before starting another run."
                }
            }
        }
    }

    @MainActor private func loadEvents(_ identity: String) async {
        guard visible, let api else { return }
        eventRequestRevision += 1
        let revision = eventRequestRevision
        do {
            let after = events.map(\.sequence).max() ?? 0
            let reply = try await api.request("runs/\(identity)/events", query: [URLQueryItem(name: "after", value: String(after))], as: WorkspaceEventsReply.self)
            let runReply = try await api.request("runs/\(identity)", as: WorkspaceRunReply.self)
            guard visible, selectedRunId == identity, eventRequestRevision == revision else { return }
            let known = Set(events.map(\.sequence))
            events += reply.events.filter { !known.contains($0.sequence) }
            if let index = runs.firstIndex(where: { $0.id == identity }) { runs[index] = runReply.run }
            else { runs.insert(runReply.run, at: 0) }
            let through = events.map(\.sequence).max() ?? 0
            if through > 0 {
                let _: WorkspaceEmptyReply = try await api.request("seen", method: "POST", body: ["kind": "run", "id": identity, "throughSequence": through], as: WorkspaceEmptyReply.self)
                if visible, selectedRunId == identity, let index = runs.firstIndex(where: { $0.id == identity }) {
                    runs[index] = runs[index].markingSeen(through: through)
                }
            }
        } catch is CancellationError {
        } catch { if visible { status = "Could not refresh saved actions. " + error.localizedDescription } }
    }

    @MainActor private func stop(_ run: KadeWorkspaceRun) {
        guard !busy, let api else { return }
        busy = true
        work = Task { @MainActor in
            do {
                let reply = try await api.request("runs/\(run.id)/stop", method: "POST", body: [:], as: WorkspaceRunReply.self)
                if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index] = reply.run }
                status = reply.run.statusWords + ". Stopping does not undo completed actions."
            } catch is CancellationError {
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}
