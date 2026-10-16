import Foundation

/// Oct 16 2026: the Body editor's server calls, all under
/// /api/kade/agent-body (the fork's kadeAgentBody.js). Same request style as
/// `AgentBuilderService`: one shared client and its pacing gate, the server's
/// own `error` words when something fails, and any 2xx is success.
///
///   GET    /catalog                 sections -> controls (choice, color, slider,
///                                   accessory {slot}) + the kit's default recipe
///   GET    /:agentId                the saved body + scene, or { recipe: null }
///   POST   /preview                 { recipe } -> scene + description, nothing saved
///   PUT    /:agentId                { recipe, baseRev, source }; 409 { latest }
///                                   when someone saved first
///   DELETE /:agentId                back to the plain portrait
///   POST   /surprise                { seed } -> a random body, nothing saved
///   POST   /from-words              { words, base } -> a body (small paid call, costUSD)
///   POST   /:agentId/from-portrait  a body like the avatar (small paid call, costUSD)
///
/// Every body reply is the same shape; scenes are decoded, checked and
/// prepared off the main thread, like `PuppetStore`'s.
@MainActor
final class PuppetBuilderService {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum SaveResult {
        /// The saved body, and the raw reply for `PuppetStore.adopt`.
        case saved(PuppetBodyReply, Data)
        /// Someone else saved (or removed) first: their version.
        case conflict(PuppetBodyReply)
    }

    private let client: KadeAPIClient
    #if DEBUG && targetEnvironment(simulator)
    /// The DEBUG gallery's offline answers; never set in the app.
    var sample: PuppetBuilderSample?
    #endif

    init(client: KadeAPIClient) {
        self.client = client
    }

    private struct ServerError: Decodable { let error: String? }

    private func failure(_ data: Data, _ fallback: String) -> Failure {
        let words = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
        return Failure(message: words.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
    }

    private func call(_ path: String, method: String = "GET", body: (any Encodable)? = nil,
                      timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = client.request(path: "api/kade/agent-body/" + path, method: method, authorized: true, timeout: timeout)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return try await client.send(req)
    }

    private func reply(_ data: Data, _ fallback: String, conflict: Bool = false) async throws -> PuppetBodyReply {
        guard let reply = await Task.detached(priority: .userInitiated, operation: {
            conflict ? PuppetBodyReply.decodeConflict(data) : PuppetBodyReply.decode(data)
        }).value else { throw Failure(message: fallback) }
        return reply
    }

    private struct Recipe: Encodable { let recipe: PuppetJSON }
    private struct Save: Encodable { let recipe: PuppetJSON; let baseRev: Int; let source: String }
    private struct Seed: Encodable { let seed: String }
    private struct Words: Encodable { let words: String; let base: PuppetJSON }

    func catalog() async throws -> PuppetCatalogReply {
        #if DEBUG && targetEnvironment(simulator)
        if let sample { return try JSONDecoder().decode(PuppetCatalogReply.self, from: sample.catalog) }
        #endif
        let (data, http) = try await call("catalog")
        guard http.statusCode == 200 else { throw failure(data, "The body parts catalog is unavailable right now.") }
        guard let decoded = await Task.detached(priority: .userInitiated, operation: {
            try? JSONDecoder().decode(PuppetCatalogReply.self, from: data)
        }).value else { throw Failure(message: "The body parts catalog did not make sense to this app. Try again later.") }
        return decoded
    }

    /// The saved body, its raw reply and ETag (both for `PuppetStore.adopt`).
    func body(agentId: String) async throws -> (PuppetBodyReply, Data, String?) {
        #if DEBUG && targetEnvironment(simulator)
        if let sample { return (try await reply(sample.body, "No sample body."), sample.body, nil) }
        #endif
        guard PuppetBodyFiles.isSafeID(agentId) else { throw Failure(message: "That character's body could not be found.") }
        var req = client.request(path: "api/kade/agent-body/" + agentId, authorized: true)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw failure(data, "That body could not be loaded.") }
        return (try await reply(data, "That body could not be read."), data, http.value(forHTTPHeaderField: "ETag"))
    }

    func preview(_ recipe: PuppetJSON) async throws -> PuppetBodyReply {
        #if DEBUG && targetEnvironment(simulator)
        if let sample { return try await reply(sample.body, "No sample body.") }
        #endif
        let (data, http) = try await call("preview", method: "POST", body: Recipe(recipe: recipe))
        guard (200...299).contains(http.statusCode) else { throw failure(data, "That body could not be drawn.") }
        return try await reply(data, "That body could not be drawn.")
    }

    func save(agentId: String, recipe: PuppetJSON, baseRev: Int, source: String) async throws -> SaveResult {
        #if DEBUG && targetEnvironment(simulator)
        if let sample { return .saved(try await reply(sample.body, "No sample body."), sample.body) }
        #endif
        guard PuppetBodyFiles.isSafeID(agentId) else { throw Failure(message: "That body could not be saved.") }
        let (data, http) = try await call(agentId, method: "PUT",
            body: Save(recipe: recipe, baseRev: baseRev, source: source))
        if http.statusCode == 409 {
            return .conflict(try await reply(data, "Someone else changed this body. Go back and open it again.",
                conflict: true))
        }
        guard (200...299).contains(http.statusCode) else { throw failure(data, "That body could not be saved.") }
        return .saved(try await reply(data, "The body was saved, but the reply could not be read."), data)
    }

    func remove(agentId: String) async throws {
        #if DEBUG && targetEnvironment(simulator)
        if sample != nil { return }
        #endif
        guard PuppetBodyFiles.isSafeID(agentId) else { throw Failure(message: "That body could not be removed.") }
        let (data, http) = try await call(agentId, method: "DELETE")
        guard (200...299).contains(http.statusCode) else { throw failure(data, "That body could not be removed.") }
    }

    func surprise(seed: String) async throws -> PuppetBodyReply {
        #if DEBUG && targetEnvironment(simulator)
        if let sample { return try await reply(sample.body, "No sample body.") }
        #endif
        let (data, http) = try await call("surprise", method: "POST", body: Seed(seed: seed))
        guard (200...299).contains(http.statusCode) else { throw failure(data, "Surprise me is unavailable right now.") }
        return try await reply(data, "That surprise could not be drawn.")
    }

    /// A small paid design; the reply carries `costUSD` (the person's price).
    func fromWords(_ words: String, base: PuppetJSON) async throws -> PuppetBodyReply {
        #if DEBUG && targetEnvironment(simulator)
        if let sample { return try await reply(sample.body, "No sample body.") }
        #endif
        let (data, http) = try await call("from-words", method: "POST", body: Words(words: words, base: base), timeout: 120)
        guard (200...299).contains(http.statusCode) else { throw failure(data, "The body designer is having a moment. Try again.") }
        return try await reply(data, "That design could not be drawn.")
    }

    /// A small paid look at the agent's avatar; the reply carries `costUSD`.
    func fromPortrait(agentId: String) async throws -> PuppetBodyReply {
        #if DEBUG && targetEnvironment(simulator)
        if let sample { return try await reply(sample.body, "No sample body.") }
        #endif
        guard PuppetBodyFiles.isSafeID(agentId) else { throw Failure(message: "This character has no portrait to work from.") }
        let (data, http) = try await call(agentId + "/from-portrait", method: "POST", timeout: 120)
        guard (200...299).contains(http.statusCode) else { throw failure(data, "The body designer is having a moment. Try again.") }
        return try await reply(data, "That design could not be drawn.")
    }
}

/// One body as the server sends it. `renderer` is nil when there is no scene
/// or the scene fails the shared check (the editor then keeps its last one).
struct PuppetBodyReply: @unchecked Sendable {
    let rev: Int
    let source: String?
    let recipe: PuppetJSON?
    let description: String
    let sceneHash: String?
    let costUSD: Double?
    let renderer: PuppetRenderer?

    fileprivate struct Wire: Decodable {
        let rev: Int?
        let source: String?
        let recipe: PuppetJSON?
        let description: String?
        let sceneHash: String?
        let costUSD: Double?
        let scene: PuppetScene?

        enum CodingKeys: String, CodingKey { case rev, source, recipe, description, sceneHash, costUSD, scene }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A whole number either way, whatever encoder wrote it.
            rev = (try? c.decodeIfPresent(Int.self, forKey: .rev))
                ?? (try? c.decodeIfPresent(Double.self, forKey: .rev)).flatMap { $0.isFinite ? Int($0) : nil }
            source = try? c.decodeIfPresent(String.self, forKey: .source)
            recipe = try? c.decodeIfPresent(PuppetJSON.self, forKey: .recipe)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            sceneHash = try? c.decodeIfPresent(String.self, forKey: .sceneHash)
            costUSD = try? c.decodeIfPresent(Double.self, forKey: .costUSD)
            scene = try? c.decodeIfPresent(PuppetScene.self, forKey: .scene)
        }
    }

    private struct ConflictWire: Decodable { let latest: Wire? }

    /// Off the main thread: decode, check and prepare the scene once.
    static func decode(_ data: Data) -> PuppetBodyReply? {
        (try? JSONDecoder().decode(Wire.self, from: data)).map(make)
    }

    /// A 409's `latest`: their saved body, or rev 0 with no recipe when they removed it.
    static func decodeConflict(_ data: Data) -> PuppetBodyReply? {
        (try? JSONDecoder().decode(ConflictWire.self, from: data))?.latest.map(make)
    }

    private static func make(_ wire: Wire) -> PuppetBodyReply {
        let recipe: PuppetJSON? = wire.recipe == PuppetJSON.null ? nil : wire.recipe
        let words = (wire.description ?? wire.scene?.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PuppetBodyReply(rev: wire.rev ?? 0, source: wire.source, recipe: recipe, description: words,
            sceneHash: wire.sceneHash, costUSD: wire.costUSD,
            renderer: wire.scene.flatMap(PuppetPreparedScene.init(scene:)).map(PuppetRenderer.init))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// The DEBUG gallery's offline editor: the catalog and one saved body exactly
/// as the server sends them (PuppetBuilderSample.json, written by the kit).
/// The file is excluded from Release builds in project.yml.
struct PuppetBuilderSample {
    let catalog: Data
    let body: Data

    static func load() -> PuppetBuilderSample? {
        guard let url = Bundle.main.url(forResource: "PuppetBuilderSample", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = object["catalog"], let body = object["body"],
              let catalogData = try? JSONSerialization.data(withJSONObject: catalog),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return PuppetBuilderSample(catalog: catalogData, body: bodyData)
    }
}
#endif
