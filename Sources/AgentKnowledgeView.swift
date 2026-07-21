import SwiftUI
import UniformTypeIdentifiers

/// Knowledge files for one agent — documents the agent can pull answers
/// from (server-side RAG via the fork's file_search pipeline; this
/// deployment runs the RAG + pg_vector services, so uploads embed for
/// real). Pushed from `AgentEditorView` the same Bool-`navigationDestination`
/// way Version history is. See `AgentBuilderService`'s knowledge section
/// for the full server contract and the two raw-JSON round-trip rules.
struct AgentKnowledgeView: View {
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

    /// One row: the server's raw file JSON plus the tool_resources bucket it
    /// belongs to (from the agent's own expanded document).
    struct Row: Identifiable {
        let raw: [String: Any]
        let resource: String
        var id: String { (raw["file_id"] as? String) ?? (raw["filename"] as? String ?? UUID().uuidString) }
        var filename: String { (raw["filename"] as? String) ?? "Unnamed file" }
        var bytes: Int { (raw["bytes"] as? Int) ?? 0 }
    }

    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var rows: [Row] = []
    @State private var showingImporter = false
    @State private var isUploading = false
    @State private var statusText: String?
    @AccessibilityFocusState private var statusFocused: Bool

    /// 100MB soft guard — big enough for any real document, small enough to
    /// fail fast with words instead of a long silent cell-data upload.
    private static let maxUploadBytes = 100 * 1024 * 1024

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .utf8PlainText, .rtf, .json, .commaSeparatedText, .html]
        for ext in ["docx", "md", "markdown", "pptx", "xlsx", "log"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    var body: some View {
        List {
            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label(isUploading ? "Adding…" : "Add a document", systemImage: "doc.badge.plus")
                }
                .disabled(isUploading)
                .accessibilityHint("Picks a document from Files. \(agentName) will be able to search it and use it in answers.")

                if let statusText {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityFocused($statusFocused)
                }
            } footer: {
                Text("PDFs, Word documents, text, and similar. Adding a file takes a moment while it's made searchable.")
            }

            Section {
                if isLoading && rows.isEmpty {
                    ProgressView("Loading…")
                        .accessibilityLabel("Loading knowledge files")
                } else if rows.isEmpty {
                    Text("No knowledge files yet. \(agentName) answers from persona and chat alone until you add some.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.filename)
                                .font(.body)
                            Text(Self.sizeLabel(row.bytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.filename), \(Self.sizeLabel(row.bytes))")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await remove(row) }
                            } label: {
                                Text("Remove")
                            }
                        }
                        .accessibilityAction(named: "Remove") {
                            Task { await remove(row) }
                        }
                    }
                }
            } header: {
                Text("Files \(agentName) can search")
            }
        }
        .navigationTitle("Knowledge")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .refreshable { await load() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            // Same Result<[URL], Error> shape as TranscribeView/DescribeView's
            // proven importers — matching the in-app precedent exactly rather
            // than the single-URL sibling API nothing here has compiled yet.
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await upload(url) }
            case .failure:
                statusText = "Couldn't open that file. Try again."
                statusFocused = true
            }
        }
    }

    private static func sizeLabel(_ bytes: Int) -> String {
        guard bytes > 0 else { return "size unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func load() async {
        isLoading = true
        do {
            async let filesTask = service.loadKnowledgeFiles(agentId: agentId)
            async let expandedTask = service.loadExpandedRaw(id: agentId)
            let files = try await filesTask
            let resourceMap = AgentBuilderService.resourceByFileId(fromExpanded: try await expandedTask)
            rows = files.map { raw in
                let fid = raw["file_id"] as? String ?? ""
                return Row(raw: raw, resource: resourceMap[fid] ?? "file_search")
            }
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't load the files. Pull down to try again."
            statusFocused = true
        }
        isLoading = false
    }

    private func upload(_ url: URL) async {
        // Security-scoped: files picked from the Files app require this
        // bracket or the read silently fails outside the sandbox. Same
        // pattern TranscribeView's import uses.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            statusText = "Couldn't read that file. Try again."
            statusFocused = true
            return
        }
        guard data.count <= Self.maxUploadBytes else {
            statusText = "That file is bigger than 100 megabytes. Pick something smaller."
            statusFocused = true
            return
        }
        isUploading = true
        statusText = "Adding \(url.lastPathComponent)…"
        do {
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            try await service.uploadKnowledgeFile(
                agentId: agentId,
                data: data,
                fileName: url.lastPathComponent,
                mimeType: mime
            )
            statusText = "Added \(url.lastPathComponent). \(agentName) can search it now."
            await load()
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't add that file. Try again."
        }
        isUploading = false
        statusFocused = true
    }

    private func remove(_ row: Row) async {
        do {
            try await service.deleteKnowledgeFile(agentId: agentId, rawFile: row.raw, toolResource: row.resource)
            statusText = "Removed \(row.filename)."
            await load()
        } catch {
            statusText = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't remove that file. Try again."
        }
        statusFocused = true
    }
}
