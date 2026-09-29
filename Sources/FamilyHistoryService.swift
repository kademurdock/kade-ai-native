import Foundation

// MARK: - Family history: the service (Sep 29 2026)
//
// Every family screen reads through FamilyHistoryService.shared: one plain
// user JWT against /api/kade/family-history/*, the same one quiet refresh on
// a 401 as the describer (DescribedVideoService.exchange), and the app's one
// pacing gate (KadeAPIClient.send). Pictures never come through here; they
// load from their signed links in FamilyImages.swift.
//
// What stays on the phone, and only for the signed-in account:
// - in memory: the last /home, the last 30 person pages, a few tree slices,
//   gallery pages, the timeline, the places and the DNA answer;
// - on disk: /home at Caches/FamilyHistory/<account>/home.json (Caches, so
//   it is never backed up to iCloud), so Home draws at once next time.
// A new family-history version clears the memory; sign-out and a lost
// access clear everything (reset() here, FamilyImageLoader.wipe()).
//
// DEBUG builds with -KadeFamilyDemo (or KADE_FAMILY_DEMO=1) answer from the
// made-up family in FamilyDemoData.swift and never touch the network.

/// The signed-in account, for per-account caches.
@MainActor
final class FamilySession {
    static let shared = FamilySession()
    private var bound: String?

    /// Set at sign-in, cleared at sign-out; before sign-in lands (a restored
    /// session), the account kept in the Keychain.
    var userId: String? {
        if let bound { return bound }
        guard let data = Keychain.data(for: .user),
              let user = try? JSONDecoder().decode(KadeUser.self, from: data),
              !user.id.isEmpty else { return nil }
        bound = user.id
        return user.id
    }

    func bind(_ userId: String?) {
        bound = userId
    }
}

/// The made-up family switch. Always off in Release, where the demo family
/// is not even compiled (Kade, Sep 29: no made-up-family preview).
@MainActor
enum FamilyDemo {
#if DEBUG
    static var isOn: Bool = FamilyDemoSwitch.isOn(arguments: ProcessInfo.processInfo.arguments,
                                                  environment: ProcessInfo.processInfo.environment)
#else
    static var isOn: Bool { false }
#endif

    /// Sign-out ends it.
    static func end() {
#if DEBUG
        isOn = false
#endif
    }
}

/// Files under Caches/FamilyHistory: one folder per account.
enum FamilyDiskStore {
    static func root() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(FamilyCacheNames.folder, isDirectory: true)
    }

    static func folder(userId: String?) -> URL? {
        guard let userId, !userId.isEmpty, let root = root() else { return nil }
        return root.appendingPathComponent(FamilyCacheNames.safe(userId), isDirectory: true)
    }

    static func file(_ name: String, userId: String?) -> URL? {
        folder(userId: userId)?.appendingPathComponent(name, isDirectory: false)
    }

    /// Written whole (atomic), readable only after the phone's first unlock.
    static func save(_ data: Data, to file: URL) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load(_ file: URL) -> Data? {
        try? Data(contentsOf: file)
    }

    /// Marks a file as just used, for the least-recently-used trim.
    static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Deletes the least recently used pictures in one account's folder
    /// until the folder fits (FamilyDiskTrim decides which).
    static func trim(folder: URL, limit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var files: [FamilyCachedFile] = []
        for url in urls where url.pathExtension == "jpg" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            files.append(FamilyCachedFile(name: url.lastPathComponent,
                                          bytes: values?.fileSize ?? 0,
                                          used: values?.contentModificationDate ?? .distantPast))
        }
        for name in FamilyDiskTrim.victims(files, limit: limit) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: false))
        }
    }

    /// Sign-out and a lost access: every account's family files go.
    static func wipeAll() {
        guard let root = root() else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// POST api/auth/refresh.
private struct FamilyRefreshed: Decodable {
    let token: String
}

@MainActor
final class FamilyHistoryService {
    static let shared = FamilyHistoryService()

    private static let base = "api/kade/family-history/"
    private var client: KadeAPIClient?
    /// Moves on at every reset, so an answer asked for before a sign-out (or
    /// before access was lost) is dropped when it arrives.
    private(set) var generation = 0
    /// The family-history version the caches came from.
    private(set) var version: String?

    private var home: FHHome?
    private var trees = FamilyLRU<FHTree>(capacity: 12)
    private var people = FamilyLRU<FHPersonPage>(capacity: 30)
    private var galleries = FamilyLRU<FHGallery>(capacity: 12)
    private var timelines = FamilyLRU<FHTimeline>(capacity: 2)
    private var placeSets = FamilyLRU<FHPlaces>(capacity: 2)
    private var dnaAnswers = FamilyLRU<FHDNA>(capacity: 4)

    private init() {}

    func bind(client: KadeAPIClient) {
        self.client = client
    }

    /// Sign-out, or access lost: nothing from before is kept or delivered.
    func reset() {
        generation += 1
        version = nil
        clearMemory()
    }

    /// A new version of the family history: everything cached is from the old one.
    func noteVersion(_ newVersion: String?) {
        guard let newVersion, !newVersion.isEmpty else { return }
        if let version, version != newVersion { clearMemory() }
        version = newVersion
    }

    private func clearMemory() {
        home = nil
        trees.removeAll()
        people.removeAll()
        galleries.removeAll()
        timelines.removeAll()
        placeSets.removeAll()
        dnaAnswers.removeAll()
    }

    // MARK: Plumbing

    /// One refresh in flight for every caller, and none again for a minute
    /// after one failed (the describer's rule).
    private static var refreshing: Task<Bool, Never>?
    private static var refreshFailedAt = Date.distantPast

    private static func refreshToken(_ client: KadeAPIClient) async -> Bool {
        if let running = refreshing { return await running.value }
        guard Date().timeIntervalSince(refreshFailedAt) > 60 else { return false }
        let task = Task<Bool, Never> {
            let req = client.request(path: "api/auth/refresh", method: "POST")
            guard let (data, http) = try? await client.send(req), http.statusCode == 200,
                  let fresh = try? JSONDecoder().decode(FamilyRefreshed.self, from: data),
                  !fresh.token.isEmpty else { return false }
            Keychain.set(fresh.token, for: .accessToken)
            return true
        }
        refreshing = task
        let ok = await task.value
        refreshing = nil
        if !ok { refreshFailedAt = Date() }
        return ok
    }

    private func makeRequest(_ client: KadeAPIClient, _ path: String, method: String, body: [String: Any]?,
                             query: [URLQueryItem]?, timeout: TimeInterval) throws -> URLRequest {
        var req = client.request(path: Self.base + path, method: method, authorized: true, queryItems: query, timeout: timeout)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// One request, refreshed once on a 401. Answers the body and the
    /// status whatever the status; throws only when the site could not be
    /// reached or the load was cancelled.
    func raw(_ path: String, method: String = "GET", body: [String: Any]? = nil,
             query: [URLQueryItem]? = nil, timeout: TimeInterval = 45) async throws -> (Data, Int) {
#if DEBUG
        if FamilyDemo.isOn { return demoAnswer(path, query: query) }
#endif
        guard let client else { throw FamilyFailure.offline }
        let first = try makeRequest(client, path, method: method, body: body, query: query, timeout: timeout)
        var (data, http) = try await client.send(first)
        if http.statusCode == 401, await Self.refreshToken(client) {
            let again = try makeRequest(client, path, method: method, body: body, query: query, timeout: timeout)
            (data, http) = try await client.send(again)
        }
        return (data, http.statusCode)
    }

    /// A family answer, decoded. A 403 that means the account lost the
    /// family history wipes and greys the row before it is thrown.
    private func fetch<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                     query: [URLQueryItem]? = nil) async throws -> (T, Data) {
        let asked = generation
        let answer: (Data, Int)
        do {
            answer = try await raw(path, method: method, body: body, query: query)
        } catch {
            if LibraryLoad.cancelled(error) { throw error }
            throw FamilyFailure.offline
        }
        // Signed out (or locked out) while it was asked.
        guard asked == generation else { throw CancellationError() }
        let data = answer.0
        let status = answer.1
        if let failure = FamilyFailure.from(status: status, body: data) {
            if case .locked(let locked) = failure, FamilyAccessRules.revokes(locked) {
                FamilyHistoryAccess.shared.lost(status: status, body: data)
            }
            throw failure
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw FamilyFailure.unreadable }
        return (value, data)
    }

    private static func item(_ name: String, _ value: String?) -> URLQueryItem? {
        guard let value, !value.isEmpty else { return nil }
        return URLQueryItem(name: name, value: value)
    }

    /// An id as one path segment: nothing that could reach another route.
    private static func segment(_ id: String) throws -> String {
        let bad = id.isEmpty || id.contains("/") || id.contains("?") || id.contains("#") || id.contains("..")
        if bad { throw FamilyFailure.missing(nil) }
        return id
    }

    // MARK: Home

    /// The last /home, from memory or this account's disk, to draw at once.
    func cachedHome() -> FHHome? {
        if let home { return home }
        guard let file = FamilyDiskStore.file(FamilyCacheNames.homeFile, userId: FamilySession.shared.userId),
              let data = FamilyDiskStore.load(file),
              let value = try? JSONDecoder().decode(FHHome.self, from: data) else { return nil }
        home = value
        return value
    }

    /// GET /home. `since` is the version this account last saw ("New since
    /// your last visit").
    func home(since: String?) async throws -> FHHome {
        let query: [URLQueryItem] = [Self.item("since", since)].compactMap { $0 }
        let (value, data): (FHHome, Data) = try await fetch("home", query: query)
        noteVersion(value.version)
        home = value
        if let file = FamilyDiskStore.file(FamilyCacheNames.homeFile, userId: FamilySession.shared.userId) {
            FamilyDiskStore.save(data, to: file)
        }
        return value
    }

    // MARK: Tree and people

    func cachedTree(focus: String?, up: Int?, down: Int?) -> FHTree? {
        trees.get(Self.treeKey(focus, up, down))
    }

    /// GET /tree: a slice centred on `focus` (nil = the viewer).
    func tree(focus: String?, up: Int? = nil, down: Int? = nil) async throws -> FHTree {
        var query: [URLQueryItem] = [Self.item("focus", focus)].compactMap { $0 }
        if let up { query.append(URLQueryItem(name: "up", value: String(up))) }
        if let down { query.append(URLQueryItem(name: "down", value: String(down))) }
        let (value, _): (FHTree, Data) = try await fetch("tree", query: query)
        trees.set(Self.treeKey(focus, up, down), value)
        return value
    }

    private static func treeKey(_ focus: String?, _ up: Int?, _ down: Int?) -> String {
        "\(focus ?? "")|\(up ?? -1)|\(down ?? -1)"
    }

    func cachedPerson(_ id: String) -> FHPersonPage? {
        people.get(id)
    }

    /// GET /person/:id.
    func person(_ id: String) async throws -> FHPersonPage {
        let (value, _): (FHPersonPage, Data) = try await fetch("person/" + Self.segment(id))
        people.set(id, value)
        return value
    }

    /// GET /people: everyone in the tree, a page of 60 at a time.
    func people(group: String?, from: Int = 0) async throws -> FHPeople {
        var query: [URLQueryItem] = [Self.item("group", group)].compactMap { $0 }
        if from > 0 { query.append(URLQueryItem(name: "from", value: String(from))) }
        let (value, _): (FHPeople, Data) = try await fetch("people", query: query)
        return value
    }

    /// GET /search?q=.
    func search(_ text: String) async throws -> FHPeople {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (value, _): (FHPeople, Data) = try await fetch("search", query: [URLQueryItem(name: "q", value: q)])
        return value
    }

    // MARK: Pictures

    func cachedGallery(_ route: FamilyGalleryRoute, sort: String?, from: Int) -> FHGallery? {
        galleries.get(Self.galleryKey(route, sort, from))
    }

    /// GET /gallery: one page of 48 (pages are replaced, never appended).
    func gallery(_ route: FamilyGalleryRoute, sort: String? = nil, from: Int = 0) async throws -> FHGallery {
        var query: [URLQueryItem] = [
            Self.item("kind", route.kind),
            Self.item("person", route.person),
            Self.item("since", route.since),
            Self.item("sort", sort),
        ].compactMap { $0 }
        if from > 0 { query.append(URLQueryItem(name: "from", value: String(from))) }
        let (value, _): (FHGallery, Data) = try await fetch("gallery", query: query)
        galleries.set(Self.galleryKey(route, sort, from), value)
        return value
    }

    private static func galleryKey(_ route: FamilyGalleryRoute, _ sort: String?, _ from: Int) -> String {
        "\(route.kind)|\(route.person ?? "")|\(route.since ?? "")|\(sort ?? "")|\(from)"
    }

    /// GET /media/:id/info: the description and any words in the picture.
    func mediaInfo(_ id: String) async throws -> FHMediaInfo {
        let (value, _): (FHMediaInfo, Data) = try await fetch("media/" + Self.segment(id) + "/info")
        return value
    }

    /// GET /media/:id?size=: one signed link.
    func mediaLink(_ id: String, size: FHSize) async throws -> FHMediaLink {
        let (value, _): (FHMediaLink, Data) = try await fetch("media/" + Self.segment(id),
                                                               query: [URLQueryItem(name: "size", value: size.rawValue)])
        return value
    }

    /// POST /media/sign: signed links for up to 100 pictures at once
    /// (FamilyImageLoader batches a screenful).
    func sign(ids: [String], size: FHSize) async throws -> FHSigned {
        let body: [String: Any] = ["ids": ids, "size": size.rawValue]
        let (value, _): (FHSigned, Data) = try await fetch("media/sign", method: "POST", body: body)
        return value
    }

    // MARK: DNA, where and when

    func cachedDNA(forId: String?) -> FHDNA? {
        dnaAnswers.get(forId ?? "")
    }

    /// GET /dna (`for` changes only the on-paper parts).
    func dna(forId: String?) async throws -> FHDNA {
        let query: [URLQueryItem] = [Self.item("for", forId)].compactMap { $0 }
        let (value, _): (FHDNA, Data) = try await fetch("dna", query: query)
        dnaAnswers.set(forId ?? "", value)
        return value
    }

    func cachedTimeline(scope: String) -> FHTimeline? {
        timelines.get(scope)
    }

    /// GET /timeline?scope=ancestors|all.
    func timeline(scope: String) async throws -> FHTimeline {
        let (value, _): (FHTimeline, Data) = try await fetch("timeline", query: [URLQueryItem(name: "scope", value: scope)])
        timelines.set(scope, value)
        return value
    }

    func cachedPlaces(scope: String) -> FHPlaces? {
        placeSets.get(scope)
    }

    /// GET /places (404 with `missing: "places"` until the places are found).
    func places(scope: String) async throws -> FHPlaces {
        let (value, _): (FHPlaces, Data) = try await fetch("places", query: [URLQueryItem(name: "scope", value: scope)])
        placeSets.set(scope, value)
        return value
    }

    // MARK: Stories, findings, the game

    func stories() async throws -> FHStories {
        let (value, _): (FHStories, Data) = try await fetch("stories")
        return value
    }

    func story(_ slug: String) async throws -> FHStory {
        let (value, _): (FHStory, Data) = try await fetch("story/" + Self.segment(slug))
        return value
    }

    /// GET /findings (discoveries), or `group: "mysteries"`.
    func findings(group: String? = nil) async throws -> FHFindings {
        let query: [URLQueryItem] = [Self.item("group", group)].compactMap { $0 }
        let (value, _): (FHFindings, Data) = try await fetch("findings", query: query)
        return value
    }

    /// GET /play (a guest gets 403 with reason "guest", which keeps access).
    func play(count: Int = 5) async throws -> FHPlay {
        let (value, _): (FHPlay, Data) = try await fetch("play", query: [URLQueryItem(name: "count", value: String(count))])
        return value
    }

    // MARK: Notes to the tree's owner

    /// POST /note: a memory, "Do you know who this is?", or a restore request
    /// (kind "memory", "who" or "restore-request").
    func note(personId: String? = nil, mediaId: String? = nil, kind: String, text: String) async throws -> FHNoteSent {
        var about: Any = NSNull()
        if let personId, !personId.isEmpty {
            about = ["personId": personId]
        } else if let mediaId, !mediaId.isEmpty {
            about = ["mediaId": mediaId]
        }
        let body: [String: Any] = ["about": about, "kind": kind, "text": text]
        let (value, _): (FHNoteSent, Data) = try await fetch("note", method: "POST", body: body)
        return value
    }

    // MARK: The made-up family (DEBUG only)

#if DEBUG
    private func demoAnswer(_ path: String, query: [URLQueryItem]?) -> (Data, Int) {
        var asked: [String: String] = [:]
        for item in query ?? [] { asked[item.name] = item.value ?? "" }
        if path == "ask" {
            return (Data(#"{"ok":true,"askedAt":"2026-09-29T12:00:00.000Z","text":"Asked. The tree's owner will see your request."}"#.utf8), 200)
        }
        if let json = FamilyDemoData.payload(path: path, query: asked) {
            return (Data(json.utf8), 200)
        }
        return (Data(#"{"error":"That is not in the made-up family."}"#.utf8), 404)
    }
#endif
}
