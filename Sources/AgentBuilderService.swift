import Foundation

/// Agent Builder — native port of LibreChat's own agent-authoring panel
/// (`com_sidepanel_agent_builder`/`AgentPanelSwitch`, confirmed session
/// 17/18 as a large, stock, multi-tab system: definition, knowledge,
/// tools/actions, subagent handoffs, version history). Kade's ask, after
/// being told plainly how big the real thing is: "Go all-in." Built as a
/// PHASED foundation rather than one giant unreviewable diff, same
/// discipline as every other feature this session — this file and its two
/// views are Phase 1: create, view, edit, and delete an agent's core
/// identity (name, description, persona, category, provider/model). Tools/
/// actions, subagent edges, knowledge files, TTS voice config, conversation
/// starters, and version history/revert are real, confirmed-existing
/// server capabilities (see `api/server/routes/agents/v1.js`, read end to
/// end) deliberately NOT wired up yet — each is its own substantial screen,
/// and landing all of them at once is exactly the kind of unreviewable
/// mega-commit this project's own history warns against. Scoped explicitly
/// in `NEXT_SESSION_PASTE.md` as Phase 2+.
///
///   GET  /api/agents/categories       JWT. -> 200 [{value,label,count,
///                                     description}, ...] plain array, NOT
///                                     wrapped in an object -- includes a
///                                     synthetic "promoted" (if any exist)
///                                     and always a trailing "all" entry.
///   GET  /api/models                  JWT. -> 200 {[provider]: [modelId]}
///                                     -- a flat dictionary, provider name
///                                     to its list of usable model ids.
///   GET  /api/agents                  JWT, `?limit=1000` (same call
///                                     `AgentsService` already makes) --
///                                     reused here with a richer decode
///                                     that keeps `author`, since this
///                                     screen filters to agents SHE
///                                     authored (Agent Builder is her own
///                                     workshop, not the marketplace
///                                     browse `AgentPickerView` already
///                                     covers).
///   GET  /api/agents/:id/expanded     JWT, EDIT permission. -> 200 the
///                                     FULL raw agent document -- only the
///                                     fields `AgentDetail` below declares
///                                     are decoded, everything else
///                                     (tools, tool_resources, edges, tts,
///                                     conversation_starters, ...) is
///                                     silently ignored by `Decodable`,
///                                     same treatment as every other
///                                     partial-decode in this app.
///   POST /api/agents                  JWT, body {name, description,
///                                     instructions, category, provider,
///                                     model} -> 201 (this app treats any
///                                     2xx as success rather than
///                                     hardcoding 201 specifically, since
///                                     the exact code isn't load-bearing
///                                     here).
///   PATCH /api/agents/:id             JWT, EDIT permission, same body
///                                     shape as create -> 200.
///   DELETE /api/agents/:id            JWT, DELETE permission -> 200.
@MainActor
final class AgentBuilderService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct AgentBuilderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable {
        let error: String?
        let userMessage: String?
    }

    private func errorMessage(from data: Data, fallback: String) -> String {
        let decoded = try? decoder.decode(ServerError.self, from: data)
        return decoded?.userMessage ?? decoded?.error ?? fallback
    }

    // MARK: - Lookups

    func loadCategories() async -> [AgentCategory] {
        do {
            let req = client.request(path: "api/agents/categories", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return [] }
            return try decoder.decode([AgentCategory].self, from: data)
        } catch {
            return []
        }
    }

    func loadModelsConfig() async -> [String: [String]] {
        do {
            let req = client.request(path: "api/models", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return [:] }
            return (try? decoder.decode([String: [String]].self, from: data)) ?? [:]
        } catch {
            return [:]
        }
    }

    // MARK: - Agents

    /// GET /api/agents/tools — the platform's available tools (TPlugin[]).
    /// Live-probed July 21 2026: 16 entries of {pluginKey, name, description,
    /// icon, isAuthRequired, authConfig}. Only the display fields matter here;
    /// server-side env supplies any credentials, so isAuthRequired is shown
    /// as a hint, never a blocker. Explicit Accept header: this route sits
    /// behind the anti-abuse layer and answers an SSE-style error to
    /// requests that don't look like a browser asking for JSON.
    func loadAvailableTools() async -> [AvailableTool] {
        do {
            var req = client.request(path: "api/agents/tools", method: "GET", authorized: true)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return [] }
            return try decoder.decode([AvailableTool].self, from: data)
        } catch {
            return []
        }
    }

    private struct AgentsPage: Decodable { let data: [AgentSummary] }

    /// Only agents `authoredByUserId` actually authored -- everyone else's
    /// (the marketplace at large) is what `AgentPickerView` already covers.
    func loadMyAgents(authoredByUserId: String) async -> [AgentSummary] {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(
                path: "api/agents",
                authorized: true,
                queryItems: [URLQueryItem(name: "limit", value: "1000")]
            )
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = "Couldn't load your agents. Try again."
                return []
            }
            let page = try decoder.decode(AgentsPage.self, from: data)
            return page.data
                .filter { $0.author == authoredByUserId }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            loadError = "Couldn't load your agents. Try again."
            return []
        }
    }

    func loadDetail(id: String) async throws -> AgentDetail {
        let req = client.request(path: "api/agents/\(id)/expanded", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't load that agent."))
        }
        return try decoder.decode(AgentDetail.self, from: data)
    }

    struct AgentFields {
        var name: String
        var description: String
        var instructions: String
        var category: String
        var provider: String
        var model: String
        /// TTS voice id ("Voice 42"), or empty to leave the agent on its
        /// name-hash default. Sent as `tts.voiceId`, the same shape
        /// `VoiceService` reads back.
        var voice: String
        /// Tappable opening lines shown when someone starts a chat with
        /// this agent. Always sent (an empty array deliberately clears
        /// them server-side, so deleting the last starter really deletes it).
        var starters: [String]
        /// The agent's full tools array — the editor's known toggles PLUS
        /// any strings it didn't recognize, preserved verbatim (see
        /// AgentEditorView's preservation note). nil = this save should not
        /// touch tools at all (the lookup list failed to load, so the
        /// editor can't know what it would be overwriting).
        var tools: [String]?
    }

    private func bodyJSON(_ fields: AgentFields) -> [String: Any] {
        var body: [String: Any] = [
            "name": fields.name,
            "description": fields.description,
            "instructions": fields.instructions,
            "category": fields.category,
            "provider": fields.provider,
            "model": fields.model,
        ]
        let v = fields.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { body["tts"] = ["voiceId": v] }
        body["conversation_starters"] = fields.starters
        if let tools = fields.tools { body["tools"] = tools }
        return body
    }

    func createAgent(_ fields: AgentFields) async throws -> AgentDetail {
        var req = client.request(path: "api/agents", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyJSON(fields))
        let (data, http) = try await client.send(req)
        guard (200...299).contains(http.statusCode) else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't create the agent."))
        }
        return try decoder.decode(AgentDetail.self, from: data)
    }

    func updateAgent(id: String, fields: AgentFields) async throws -> AgentDetail {
        var req = client.request(path: "api/agents/\(id)", method: "PATCH", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyJSON(fields))
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't save your changes."))
        }
        return try decoder.decode(AgentDetail.self, from: data)
    }

    func deleteAgent(id: String) async throws {
        let req = client.request(path: "api/agents/\(id)", method: "DELETE", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't delete that agent."))
        }
    }

    /// POST /api/agents/:id/duplicate — the server clones the agent (name
    /// gains a timestamped suffix) plus its actions, minus stored secrets,
    /// and answers 201 `{ agent, actions }`. Only the agent half matters here.
    func duplicateAgent(id: String) async throws -> AgentDetail {
        let req = client.request(path: "api/agents/\(id)/duplicate", method: "POST", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 201 else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't duplicate that agent."))
        }
        struct DuplicateResponse: Decodable { let agent: AgentDetail }
        return try decoder.decode(DuplicateResponse.self, from: data).agent
    }

    /// POST /api/agents/:agent_id/avatar/ — multipart, field name "file"
    /// (read off the web client's own upload code, the ground truth for
    /// this contract). The server resizes on its side; this app still
    /// pre-scales to JPEG so a 12-megapixel camera-roll photo isn't
    /// shipped raw over her cell connection.
    func uploadAvatar(id: String, jpegData: Data) async throws {
        let req = client.multipartRequest(
            path: "api/agents/\(id)/avatar/",
            authorized: true,
            fields: [],
            fileField: "file",
            fileData: jpegData,
            fileName: "avatar.jpg",
            fileMimeType: "image/jpeg"
        )
        let (data, http) = try await client.send(req)
        guard (200...299).contains(http.statusCode) else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't upload the photo."))
        }
    }

    /// POST /api/agents/:id/revert {version_index} — restores that snapshot
    /// (0-based index into `versions`, oldest first) and answers the updated
    /// agent. The restore itself becomes a new save, so nothing is ever lost:
    /// restoring is always undoable by restoring the state before it.
    func revertAgent(id: String, versionIndex: Int) async throws -> AgentDetail {
        var req = client.request(path: "api/agents/\(id)/revert", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["version_index": versionIndex])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't restore that version."))
        }
        return try decoder.decode(AgentDetail.self, from: data)
    }

    // MARK: - Knowledge files (Phase 3, session 18)
    //
    // Server contract read at fork rev 6ab48f1:
    //   GET  /api/files/agent/:agent_id  JWT, EDIT permission (non-authors
    //                                    get []) -> 200 [TFile] — every file
    //                                    attached to the agent across ALL of
    //                                    its tool_resources buckets, without
    //                                    saying which bucket each came from.
    //   POST /api/files                  JWT, multipart field "file" plus
    //                                    text fields {file_id (client
    //                                    UUID), endpoint: "agents",
    //                                    agent_id, tool_resource} ->
    //                                    processAgentFileUpload attaches the
    //                                    file id to that resource bucket.
    //   DELETE /api/files                JWT, JSON {files: [TFile], agent_id,
    //                                    tool_resource} — detaches AND
    //                                    deletes.
    //
    // Two deliberate shapes here, both born of documented gotchas:
    // - Raw-JSON round-trip: file objects are kept as [String: Any] and sent
    //   BACK verbatim on delete, never re-built from a partial Decodable
    //   (the "a write's echo is not the read's shape" rule — and TFile has
    //   storage fields like filepath/source this app should not pretend to
    //   know the full list of).
    // - Which bucket a file belongs to comes from the agent's OWN expanded
    //   document (tool_resources), so delete names the right resource
    //   instead of guessing "file_search" for files the web attached
    //   elsewhere.

    /// The agent's expanded document as raw JSON — for reading fields this
    /// app's `AgentDetail` deliberately doesn't model (tool_resources here;
    /// the connections editor reads `edges` the same way).
    func loadExpandedRaw(id: String) async throws -> [String: Any] {
        let req = client.request(path: "api/agents/\(id)/expanded", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't load that agent."))
        }
        return obj
    }

    /// file_id -> tool_resource bucket name, read off the expanded document.
    static func resourceByFileId(fromExpanded expanded: [String: Any]) -> [String: String] {
        var map: [String: String] = [:]
        guard let resources = expanded["tool_resources"] as? [String: Any] else { return map }
        for (bucket, value) in resources {
            guard let dict = value as? [String: Any],
                  let ids = dict["file_ids"] as? [String] else { continue }
            for fid in ids { map[fid] = bucket }
        }
        return map
    }

    func loadKnowledgeFiles(agentId: String) async throws -> [[String: Any]] {
        let req = client.request(path: "api/files/agent/\(agentId)", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200,
              let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AgentBuilderError(message: errorMessage(from: data, fallback: "Couldn't load the knowledge files."))
        }
        return arr
    }

    func uploadKnowledgeFile(agentId: String, data fileData: Data, fileName: String, mimeType: String) async throws {
        let req = client.multipartRequest(
            path: "api/files",
            authorized: true,
            fields: [
                ("file_id", UUID().uuidString),
                ("endpoint", "agents"),
                ("agent_id", agentId),
                ("tool_resource", "file_search"),
            ],
            fileField: "file",
            fileData: fileData,
            fileName: fileName,
            fileMimeType: mimeType
        )
        let (data, http) = try await client.send(req)
        guard (200...299).contains(http.statusCode) else {
            throw AgentBuilderError(message: uploadErrorMessage(from: data))
        }
    }

    /// The upload route answers errors as {message}; the shared helper reads
    /// {error}/{userMessage}, so this one route gets its own reader.
    private func uploadErrorMessage(from data: Data) -> String {
        struct UploadError: Decodable { let message: String? }
        return (try? decoder.decode(UploadError.self, from: data))?.message
            ?? errorMessage(from: data, fallback: "Couldn't add that file.")
    }

    func deleteKnowledgeFile(agentId: String, rawFile: [String: Any], toolResource: String) async throws {
        var req = client.request(path: "api/files", method: "DELETE", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "files": [rawFile],
            "agent_id": agentId,
            "tool_resource": toolResource,
        ])
        let (data, http) = try await client.send(req)
        guard (200...299).contains(http.statusCode) else {
            throw AgentBuilderError(message: uploadErrorMessage(from: data))
        }
    }
}

/// One category from `GET /api/agents/categories`. `count`/`description`
/// are absent on the two synthetic entries ("promoted"/"all") the server
/// adds itself, so both stay optional.
struct AgentCategory: Decodable, Identifiable, Hashable {
    let value: String
    let label: String
    let count: Int?
    let description: String?
    var id: String { value }
}

/// One of HER agents, as listed by `GET /api/agents` — a richer decode
/// than `KadeAgent` (`AgentsService`'s type) specifically because this
/// screen needs `author` to filter to her own; `KadeAgent` deliberately
/// never needed it (the chat switcher shows everyone's).
struct AgentSummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let author: String?
}

/// The full-enough detail for editing — decoded from `GET /api/agents/:id
/// /expanded`'s raw agent document, keeping only the fields this app's
/// Phase 1 editor actually shows. Everything else on that response
/// (tools, tool_resources, edges, tts, conversation_starters, ...) is
/// silently ignored, same treatment `KadeAgent`'s own doc comment
/// describes for the marketplace list.
struct AgentDetail: Decodable, Identifiable, Hashable {
    struct TTSInfo: Decodable, Hashable { let voiceId: String? }
    let id: String
    let name: String?
    let description: String?
    let instructions: String?
    let category: String?
    let provider: String?
    let model: String?
    let author: String?
    /// The agent's configured TTS voice, if any (same `tts.voiceId` shape
    /// `VoiceService.resolveVoice` reads). Lets the editor show and keep the
    /// current voice instead of silently resetting it on save.
    let tts: TTSInfo?
    /// Tappable opening lines, editable in Phase 2.
    let conversation_starters: [String]?
    /// The agent's enabled tool keys (kade_notify, flux, ...), editable in
    /// Phase 2. Unknown entries are preserved by the editor, never dropped.
    let tools: [String]?
    /// Prior saved states, oldest first — every save pushes the pre-save
    /// snapshot here server-side. Lenient subset: a snapshot carries the
    /// full agent document, but only these fields are needed to label a
    /// history row and pick one to restore.
    let versions: [AgentVersion]?
}

/// One entry of an agent's `versions` array (a full prior snapshot,
/// decoded leniently — every field optional on purpose).
struct AgentVersion: Decodable, Hashable {
    let name: String?
    let description: String?
    let model: String?
    let updatedAt: String?
}

/// One entry from `GET /api/agents/tools` — see loadAvailableTools.
struct AvailableTool: Decodable, Identifiable, Hashable {
    let pluginKey: String
    let name: String
    let description: String?
    let isAuthRequired: Bool?
    var id: String { pluginKey }
}
