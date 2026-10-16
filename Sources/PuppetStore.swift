import Foundation

/// Oct 16 2026: puppet bodies for characters that have no hand-made rig. The
/// server compiles each saved body into a scene (GET /api/kade/agent-body/{id});
/// this keeps the prepared scenes in memory, a copy on disk for the next launch,
/// and the plain-words description VoiceOver reads on request.
///
/// Every request shares the account's pacing gate, so only a face stage asks the
/// server (once per character, then at most every 15 minutes, revalidated with
/// If-None-Match). Rows and pickers only read what is already cached.
/// Decoding, checking and preparing a scene never run on the main thread.
@MainActor
final class PuppetStore: ObservableObject {
    @Published private(set) var renderers: [String: PuppetRenderer] = [:]
    @Published private(set) var descriptions: [String: String] = [:]
    /// Characters the server said have no body (the Body row says so).
    @Published private(set) var bodiless = Set<String>()
    /// The Body editor's unsaved work per character, kept in memory when the
    /// person goes Back without saving, so opening it again brings it back.
    var editorDrafts: [String: PuppetEditorDraft] = [:]

    private let client: KadeAPIClient
    private var etags: [String: String] = [:]
    private var checkedAt: [String: Date] = [:]
    private var diskChecked = Set<String>()
    private var inFlight = Set<String>()
    private var recent: [String] = []
    private var generation = 0
    static let memoryLimit = 24
    static let refreshInterval: TimeInterval = 15 * 60

    init(client: KadeAPIClient) {
        self.client = client
    }

    func scene(for agentID: String?) -> PuppetRenderer? {
        guard let agentID else { return nil }
        return renderers[agentID]
    }

    func description(for agentID: String?) -> String? {
        guard let agentID else { return nil }
        return descriptions[agentID]
    }

    /// Disk only. Safe to call from every row; a miss is remembered.
    func loadCached(agentId: String) async {
        guard PuppetBodyFiles.isSafeID(agentId), renderers[agentId] == nil,
              !diskChecked.contains(agentId), !inFlight.contains(agentId) else { return }
        diskChecked.insert(agentId)
        let started = generation
        guard let body = await Task.detached(priority: .utility, operation: {
            PuppetBodyFiles.read(agentId: agentId)
        }).value, started == generation, renderers[agentId] == nil else { return }
        install(agentId, body)
    }

    func refreshIfNeeded(agentId: String) async {
        if let at = checkedAt[agentId], Date().timeIntervalSince(at) < Self.refreshInterval { return }
        await refresh(agentId: agentId)
    }

    /// Asks the server for this character's body. 304 keeps what is here; a
    /// body removed on the server removes it here too; any failure is quiet.
    func refresh(agentId: String) async {
        guard PuppetBodyFiles.isSafeID(agentId), !inFlight.contains(agentId) else { return }
        inFlight.insert(agentId)
        defer { inFlight.remove(agentId) }
        let started = generation
        if renderers[agentId] == nil, !diskChecked.contains(agentId) {
            diskChecked.insert(agentId)
            if let body = await Task.detached(priority: .utility, operation: {
                PuppetBodyFiles.read(agentId: agentId)
            }).value, started == generation {
                install(agentId, body)
            }
        }
        var request = client.request(path: "api/kade/agent-body/" + agentId, authorized: true)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if renderers[agentId] != nil, let etag = etags[agentId] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, http) = try? await client.send(request), started == generation else { return }
        checkedAt[agentId] = Date()
        guard http.statusCode == 200 else { return }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let outcome = await Task.detached(priority: .utility, operation: {
            PuppetBodyFiles.accept(data, agentId: agentId, etag: etag)
        }).value
        guard started == generation else { return }
        switch outcome {
        case .body(let body): install(agentId, body)
        case .noBody: forget(agentId)
        case .unreadable: break
        }
    }

    /// The Body editor loaded or saved this body: the reply has the same shape
    /// GET sends, so the chat stage and still faces change at once, and the
    /// next stage refresh is a cheap If-None-Match.
    func adopt(_ data: Data, agentId: String, etag: String?) async {
        guard PuppetBodyFiles.isSafeID(agentId) else { return }
        let started = generation
        let outcome = await Task.detached(priority: .userInitiated, operation: {
            PuppetBodyFiles.accept(data, agentId: agentId, etag: etag)
        }).value
        guard started == generation else { return }
        checkedAt[agentId] = Date()
        diskChecked.insert(agentId)
        switch outcome {
        case .body(let body): install(agentId, body)
        case .noBody: forget(agentId)
        case .unreadable: break
        }
    }

    /// The Body editor removed this body: back to the portrait everywhere.
    func removed(agentId: String) {
        guard PuppetBodyFiles.isSafeID(agentId) else { return }
        forget(agentId)
        checkedAt[agentId] = Date()
        Task.detached(priority: .utility) { PuppetBodyFiles.remove(agentId: agentId) }
    }

    /// Sign-out: nothing of one account's characters stays for the next.
    func reset() {
        generation += 1
        renderers = [:]
        descriptions = [:]
        bodiless = []
        editorDrafts = [:]
        etags = [:]
        checkedAt = [:]
        diskChecked = []
        recent = []
        Task.detached(priority: .utility) { PuppetBodyFiles.removeAll() }
    }

    private func install(_ agentId: String, _ body: PuppetBodyFiles.Loaded) {
        renderers[agentId] = body.renderer
        if bodiless.contains(agentId) { bodiless.remove(agentId) }
        if let text = body.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            descriptions[agentId] = text
        } else {
            descriptions[agentId] = nil
        }
        etags[agentId] = body.etag
        recent.removeAll { $0 == agentId }
        recent.append(agentId)
        while recent.count > Self.memoryLimit {
            // The description is tiny and stays; the drawing reloads from disk.
            let oldest = recent.removeFirst()
            renderers[oldest] = nil
            diskChecked.remove(oldest)
        }
    }

    private func forget(_ agentId: String) {
        renderers[agentId] = nil
        descriptions[agentId] = nil
        etags[agentId] = nil
        recent.removeAll { $0 == agentId }
        bodiless.insert(agentId)
    }
}

/// Unsaved Body editor work: the recipe, the revision it started from and how
/// it was made (editor, words, picture or surprise).
struct PuppetEditorDraft {
    let recipe: PuppetJSON
    let baseRev: Int
    let source: String
}

/// The disk half: Caches/puppets/{agentId}.json holds the last good scene with
/// its rev, scene hash and ETag. Runs off the main actor.
enum PuppetBodyFiles {
    struct Loaded: @unchecked Sendable {
        let renderer: PuppetRenderer
        let description: String?
        let etag: String?
    }
    enum Outcome: @unchecked Sendable {
        case body(Loaded)
        case noBody
        case unreadable
    }
    private struct Cached: Codable {
        let agentId: String
        let rev: Int
        let sceneHash: String?
        let etag: String?
        let description: String?
        let scene: PuppetScene
    }
    private struct Response: Decodable {
        let rev: Int?
        let sceneHash: String?
        let description: String?
        let scene: PuppetScene?
        let hasScene: Bool

        enum CodingKeys: String, CodingKey { case rev, sceneHash, description, scene }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rev = try? c.decodeIfPresent(Int.self, forKey: .rev)
            sceneHash = try? c.decodeIfPresent(String.self, forKey: .sceneHash)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            hasScene = c.contains(.scene) && !((try? c.decodeNil(forKey: .scene)) ?? true)
            scene = try? c.decodeIfPresent(PuppetScene.self, forKey: .scene)
        }
    }

    /// Agent ids are short and URL-safe; anything else is never a file name.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 96 && id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("puppets", isDirectory: true)
    }

    private static func file(_ agentId: String) -> URL? {
        guard isSafeID(agentId) else { return nil }
        return folder?.appendingPathComponent(agentId + ".json")
    }

    private static func prepare(_ scene: PuppetScene, description: String?, etag: String?) -> Loaded? {
        guard let prepared = PuppetPreparedScene(scene: scene) else { return nil }
        return Loaded(renderer: PuppetRenderer(prepared), description: description ?? scene.description, etag: etag)
    }

    static func read(agentId: String) -> Loaded? {
        guard let url = file(agentId), let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              cached.agentId == agentId else { return nil }
        return prepare(cached.scene, description: cached.description, etag: cached.etag)
    }

    /// Checks and prepares a server reply, and keeps a good one on disk.
    static func accept(_ data: Data, agentId: String, etag: String?) -> Outcome {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return .unreadable }
        guard response.hasScene else {
            if let url = file(agentId) { try? FileManager.default.removeItem(at: url) }
            return .noBody
        }
        guard let scene = response.scene,
              let loaded = prepare(scene, description: response.description, etag: etag) else { return .unreadable }
        if let directory = folder, let url = file(agentId) {
            let cached = Cached(agentId: agentId, rev: response.rev ?? 0, sceneHash: response.sceneHash,
                etag: etag, description: response.description ?? scene.description, scene: scene)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(cached) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
        return .body(loaded)
    }

    static func remove(agentId: String) {
        if let url = file(agentId) { try? FileManager.default.removeItem(at: url) }
    }

    static func removeAll() {
        if let directory = folder { try? FileManager.default.removeItem(at: directory) }
    }
}
