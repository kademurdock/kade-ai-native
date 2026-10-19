#if KADE_ARCADE
import Foundation
import CryptoKit
import UIKit

// MARK: - THE ARCADE SERVICE (Oct 18 2026, Milestone 1)
//
// Talks to her server's /api/kade/arcade router and keeps the downloaded
// packs. The rules it keeps:
//   - the list comes from GET /api/kade/arcade/config through KadeAPIClient
//     (the one paced client); its `features` map is read as KadeFamilyFeatures,
//     and only arcadeFamily == true opens the family shelf;
//   - a pack is ONE big file (blob.bin) plus a small index (pack.json). The big
//     file is fetched once, straight from the one-hour signed link, on an
//     auxiliary session (the account's 1.5 s pacing gate is taken once per
//     pack, never once per file), with HTTP Range so a dropped download picks
//     up where it stopped, even after the link expired and a fresh one was asked for;
//   - every pack is checked against the manifest's sha256 before it counts;
//   - packs live in Application Support/Arcade/<id>/<version>, excluded from
//     iCloud backup. Nothing from a pack is ever in the app bundle or the repo;
//   - an update removes the game's older version and the packs only it used,
//     never while that version is open;
//   - ONE service lives for the whole app session (ArcadeService.shared), so a
//     download keeps its progress, its Stop button and its spoken news when
//     she leaves the Arcade and comes back, and two downloads can never write
//     the same file. Sign-out clears it (ArcadeService.signedOut()).

struct ArcadeServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Everything the game cover needs to host one installed game.
struct ArcadeLaunch: Identifiable {
    let id = UUID()
    let entry: ArcadeCatalogEntry
    let record: ArcadeInstallRecord
    let game: [ArcadeMount]
    let kit: [ArcadeMount]
}

/// What the confirm question says before a download starts.
struct ArcadeDownloadOffer: Identifiable {
    let id = UUID()
    let entry: ArcadeCatalogEntry
    let manifest: ArcadeManifest
    let bytes: Int64
}

// MARK: - The packs on the phone

struct ArcadeStore {
    let root: URL

    init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        root = support.appendingPathComponent("Arcade", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    func folder(id: String, version: String) -> URL? {
        guard ArcadePaths.isSafeName(id), ArcadePaths.isSafeName(version) else { return nil }
        return root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(version, isDirectory: true)
    }

    private struct Verified: Codable {
        let sha256: String
        let size: Int64
    }

    /// The pack is on the phone, whole and checked.
    func hasPack(id: String, version: String, sha256: String) -> Bool {
        guard let folder = folder(id: id, version: version),
              let data = try? Data(contentsOf: folder.appendingPathComponent("verified.json")),
              let verified = try? JSONDecoder().decode(Verified.self, from: data), verified.sha256 == sha256,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("pack.json").path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("blob.bin").path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return false }
        return size == verified.size
    }

    func hasPack(_ ref: ArcadePackRef) -> Bool { hasPack(id: ref.id, version: ref.version, sha256: ref.sha256) }

    func installedKeys(for manifest: ArcadeManifest) -> Set<String> {
        Set(manifest.packs.filter { hasPack($0) }.map { $0.key })
    }

    /// Moves a checked blob into place and writes its index and receipt.
    func commit(_ ref: ArcadePackRef, part: URL, index: ArcadePackIndex) throws {
        guard let folder = folder(id: ref.id, version: ref.version) else {
            throw ArcadeServiceError(message: "The game's file names are not usable.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blob = folder.appendingPathComponent("blob.bin")
        try? FileManager.default.removeItem(at: blob)
        try FileManager.default.moveItem(at: part, to: blob)
        try index.jsonData().write(to: folder.appendingPathComponent("pack.json"), options: .atomic)
        let receipt = try JSONEncoder().encode(Verified(sha256: ref.sha256, size: ref.size))
        try receipt.write(to: folder.appendingPathComponent("verified.json"), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("blob.part.json"))
        Self.excludeFromBackup(folder)
    }

    func mount(id: String, version: String) -> ArcadeMount? {
        guard let folder = folder(id: id, version: version),
              let data = try? Data(contentsOf: folder.appendingPathComponent("pack.json")) else { return nil }
        let blob = folder.appendingPathComponent("blob.bin")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: blob.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let index = try? ArcadePackIndex(data: data, blobSize: size) else { return nil }
        return ArcadeMount(id: id, version: version, index: index, blob: blob)
    }

    func writeRecord(_ record: ArcadeInstallRecord) throws {
        guard let folder = folder(id: record.gameId, version: record.version) else {
            throw ArcadeServiceError(message: "The game's file names are not usable.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("install.json"), options: .atomic)
        Self.excludeFromBackup(folder)
    }

    /// The installed versions of a game whose every pack is still whole,
    /// newest first.
    func records(gameId: String) -> [ArcadeInstallRecord] {
        guard ArcadePaths.isSafeName(gameId) else { return [] }
        let gameFolder = root.appendingPathComponent(gameId, isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: gameFolder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [(Date, ArcadeInstallRecord)] = []
        for folder in versions {
            let file = folder.appendingPathComponent("install.json")
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(ArcadeInstallRecord.self, from: data),
                  record.gameId == gameId,
                  record.packs.allSatisfy({ hasPack(id: $0.id, version: $0.version, sha256: $0.sha256) }) else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append((date, record))
        }
        return found.sorted { $0.0 > $1.0 }.map { $0.1 }
    }

    /// After an update: the game's other versions go, and so do the packs only
    /// they used (a kit version included, once no install on the phone still
    /// uses it). A version whose folders are in `protecting` (the game open
    /// right now) is left alone; the answer is false when that happened, so
    /// the caller can try again once the game closes.
    @discardableResult
    func prune(gameId: String, keep: ArcadeInstallRecord, protecting: Set<String>) -> Bool {
        guard ArcadePaths.isSafeName(gameId), keep.gameId == gameId else { return true }
        let manager = FileManager.default
        let gameFolder = root.appendingPathComponent(gameId, isDirectory: true)
        let versions = (try? manager.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
        var complete = true
        var candidates: [String] = []
        for folder in versions {
            let version = folder.lastPathComponent
            guard version != keep.version, ArcadePaths.isSafeName(version) else { continue }
            let own = gameId + "/" + version
            let file = folder.appendingPathComponent("install.json")
            var uses: [String] = []
            if let data = try? Data(contentsOf: file),
               let old = try? JSONDecoder().decode(ArcadeInstallRecord.self, from: data) {
                uses = old.packs.map { $0.id + "/" + $0.version }
            }
            if protecting.contains(own) || uses.contains(where: { protecting.contains($0) }) {
                complete = false
                continue
            }
            try? manager.removeItem(at: file)
            candidates.append(own)
            candidates += uses
        }
        // Whatever an install still on the phone uses (this game's new one, or
        // another game's) stays.
        let used = recordKeys().union(protecting)
        for key in Set(candidates) where !used.contains(key) {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let folder = folder(id: parts[0], version: parts[1]) else { continue }
            try? manager.removeItem(at: folder)
        }
        return complete
    }

    /// Every pack folder ("<id>/<version>") an install record on the phone
    /// uses, and each record's own folder.
    func recordKeys() -> Set<String> {
        let manager = FileManager.default
        var keys = Set<String>()
        let games = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for game in games {
            let versions = (try? manager.contentsOfDirectory(at: game, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for version in versions {
                guard let data = try? Data(contentsOf: version.appendingPathComponent("install.json")),
                      let record = try? JSONDecoder().decode(ArcadeInstallRecord.self, from: data) else { continue }
                keys.insert(record.gameId + "/" + record.version)
                for pack in record.packs { keys.insert(pack.id + "/" + pack.version) }
            }
        }
        return keys
    }

    /// Removes a game and its own packs. The shared kit pack stays (it is small
    /// and every game uses it).
    func delete(gameId: String) {
        guard ArcadePaths.isSafeName(gameId) else { return }
        for record in records(gameId: gameId) {
            for pack in record.packs where pack.kind != "kit" && pack.id != gameId {
                if let folder = folder(id: pack.id, version: pack.version) { try? FileManager.default.removeItem(at: folder) }
            }
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(gameId, isDirectory: true))
    }
}

// MARK: - The service

@MainActor
final class ArcadeService: ObservableObject {
    struct Shelf {
        let rows: [ArcadeShelfRow]
        let familyOpen: Bool
        let message: String?
    }

    @Published private(set) var shelf: Shelf?
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    /// The game id being downloaded (one download at a time).
    @Published private(set) var downloading: String?
    /// 0...1 across every pack the download needs.
    @Published private(set) var progress: Double = 0
    @Published private(set) var verifying = false
    /// The last download's problem, per game id.
    @Published private(set) var downloadErrors: [String: String] = [:]
    /// Installed version per game id (refreshed after load, download and delete).
    @Published private(set) var installed: [String: String] = [:]

    private let client: KadeAPIClient
    private var downloadTask: Task<Void, Never>?
    /// Moves on at every sign-out, so nothing asked for by the last account
    /// lands in the next one's Arcade.
    private var generation = 0
    /// Pack folders ("<id>/<version>") the open game reads from: an update
    /// never deletes them under it.
    private var inUse: Set<String> = []
    /// Updates whose old versions wait for the open game to close: game id -> version kept.
    private var prunePending: [String: String] = [:]
    /// Packs being written right now, across every service: two downloads
    /// never append to the same blob.part.
    private static var packsInFlight: Set<String> = []

    private static var current: ArcadeService?

    /// The one service for the app session (the first client wins; the app has one).
    static func shared(apiClient: KadeAPIClient) -> ArcadeService {
        if let current { return current }
        let made = ArcadeService(apiClient: apiClient)
        current = made
        return made
    }

    /// Sign-out: the shelf, the download and its news belong to the account
    /// that signed out. The packs on the phone stay; the next account's own
    /// shelf decides what it may play.
    static func signedOut() {
        current?.reset()
    }

    init(apiClient: KadeAPIClient) { client = apiClient }

    private func reset() {
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        shelf = nil
        loading = false
        loadError = nil
        downloading = nil
        progress = 0
        verifying = false
        downloadErrors = [:]
        installed = [:]
    }

    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private struct FeaturesEnvelope: Decodable { let features: KadeFamilyFeatures? }
    private struct ServerMessage: Decodable { let error: String?; let message: String? }

    private func readable(_ data: Data) -> String? {
        guard let said = try? JSONDecoder().decode(ServerMessage.self, from: data) else { return nil }
        let text = (said.error ?? said.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > 300 ? nil : text
    }

    // MARK: The list

    func load() async {
        let asked = generation
        loading = true
        defer { if asked == generation { loading = false } }
        do {
            let request = client.request(path: "api/kade/arcade/config", authorized: true)
            let (data, http) = try await client.send(request)
            // Signed out (perhaps in as someone else) while it was asked.
            guard asked == generation else { return }
            guard http.statusCode == 200 else {
                throw ArcadeServiceError(message: readable(data) ?? "The Arcade could not be opened. Try again in a moment.")
            }
            let config = try JSONDecoder().decode(ArcadeConfig.self, from: data)
            // The App Review seat gets null features: that, a missing map and
            // a false flag all read as locked.
            let features = (try? JSONDecoder().decode(FeaturesEnvelope.self, from: data))?.features
            let open = features?.arcadeFamily == true
            shelf = Shelf(rows: ArcadeShelf.rows(config.catalog, familyOpen: open, familyNote: KadeFamilyFeatures.note),
                          familyOpen: open, message: config.message)
            loadError = nil
            refreshInstalled()
        } catch is CancellationError {
            return
        } catch {
            guard asked == generation else { return }
            loadError = (error as? ArcadeServiceError)?.message ?? "The Arcade could not be opened. Check the connection and try again."
        }
    }

    func refreshInstalled() {
        guard let store = try? ArcadeStore(), let rows = shelf?.rows else { return }
        var found: [String: String] = [:]
        for row in rows {
            if case .playable(let entry) = row, let record = preferredRecord(for: entry, store: store) {
                found[entry.id] = record.version
            }
        }
        installed = found
    }

    private func preferredRecord(for entry: ArcadeCatalogEntry, store: ArcadeStore) -> ArcadeInstallRecord? {
        let records = store.records(gameId: entry.id)
        return records.first { $0.version == entry.version } ?? records.first
    }

    // MARK: Before a download

    /// The manifest and the bytes still to fetch, for the confirm question.
    func offer(for entry: ArcadeCatalogEntry) async throws -> ArcadeDownloadOffer {
        let manifest = try await fetchManifest(entry)
        let store = try ArcadeStore()
        return ArcadeDownloadOffer(entry: entry, manifest: manifest,
                                   bytes: manifest.bytesMissing(installed: store.installedKeys(for: manifest)))
    }

    private func fetchManifest(_ entry: ArcadeCatalogEntry) async throws -> ArcadeManifest {
        let request = client.request(path: "api/kade/arcade/games/\(entry.id)/manifest", authorized: true)
        let (data, http) = try await client.send(request)
        if http.statusCode == 403 {
            throw ArcadeServiceError(message: readable(data) ?? KadeFamilyFeatures.note)
        }
        guard http.statusCode == 200 else {
            throw ArcadeServiceError(message: readable(data) ?? "The game's details could not be fetched. Try again.")
        }
        guard let manifest = try? JSONDecoder().decode(ArcadeManifest.self, from: data), manifest.id == entry.id else {
            throw ArcadeServiceError(message: "The game's download list could not be read. Try again later.")
        }
        if let problem = manifest.problem { throw ArcadeServiceError(message: problem) }
        return manifest
    }

    // MARK: The download

    /// The news is spoken here, not by the list, so it is heard wherever she
    /// is in the app when the download ends.
    func startDownload(_ offer: ArcadeDownloadOffer) {
        guard downloading == nil else { return }
        let asked = generation
        downloading = offer.entry.id
        progress = 0
        verifying = false
        downloadErrors[offer.entry.id] = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            var problem: String?
            do {
                try await self.install(offer)
            } catch is CancellationError {
                problem = "Download stopped. What arrived is kept, so the next try picks up from there."
            } catch let error as URLError where error.code == .cancelled {
                problem = "Download stopped. What arrived is kept, so the next try picks up from there."
            } catch {
                problem = (error as? ArcadeServiceError)?.message
                    ?? "The download stopped: \(error.localizedDescription) Try again; it picks up where it stopped."
            }
            // Signed out meanwhile: none of this belongs to the next account.
            guard asked == self.generation else { return }
            self.downloadErrors[offer.entry.id] = problem
            self.downloading = nil
            self.verifying = false
            self.downloadTask = nil
            self.refreshInstalled()
            self.announce(problem ?? "\(offer.entry.title) is downloaded and ready to play.")
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func install(_ offer: ArcadeDownloadOffer) async throws {
        let store = try ArcadeStore()
        let manifest = offer.manifest
        let needed = manifest.packs.filter { !store.hasPack($0) }
        let total = max(1, needed.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        for pack in needed {
            try Task.checkCancellation()
            try await fetchPack(pack, gameId: manifest.id, store: store, before: done, total: total)
            done += pack.size
            progress = Double(done) / Double(total)
        }
        try store.writeRecord(ArcadeInstallRecord(manifest: manifest, title: offer.entry.title))
        progress = 1
        pruneOldVersions(gameId: manifest.id, keepVersion: manifest.version)
    }

    /// An update leaves one version on the phone: the old one and the packs
    /// only it used go now, or once the game open on it closes.
    private func pruneOldVersions(gameId: String, keepVersion: String) {
        guard let store = try? ArcadeStore(),
              let keep = store.records(gameId: gameId).first(where: { $0.version == keepVersion }) else { return }
        if store.prune(gameId: gameId, keep: keep, protecting: inUse) {
            prunePending[gameId] = nil
        } else {
            prunePending[gameId] = keepVersion
        }
    }

    /// The game cover opens on this launch: its folders are not to be touched.
    func willPlay(_ launch: ArcadeLaunch) {
        var keys = Set(launch.record.packs.map { $0.id + "/" + $0.version })
        keys.insert(launch.record.gameId + "/" + launch.record.version)
        inUse = keys
    }

    /// The game cover closed: anything an update had to leave can go now.
    func stoppedPlaying() {
        inUse = []
        for (gameId, version) in prunePending { pruneOldVersions(gameId: gameId, keepVersion: version) }
        refreshInstalled()
    }

    private func signPath(for pack: ArcadePackRef, gameId: String) -> (String, [URLQueryItem]) {
        var query = [URLQueryItem(name: "sign", value: "1")]
        if let path = pack.signPath, let clean = ArcadePaths.normalize(path), clean.hasPrefix("api/kade/arcade/") {
            return (clean, query)
        }
        if pack.kind == "kit" { return ("api/kade/arcade/kit/\(pack.version)/pack", query) }
        if pack.id != gameId { query.append(URLQueryItem(name: "pack", value: pack.id)) }
        return ("api/kade/arcade/games/\(gameId)/\(pack.version)/pack", query)
    }

    private func signedLink(for pack: ArcadePackRef, gameId: String) async throws -> ArcadeSignedLink {
        let (path, query) = signPath(for: pack, gameId: gameId)
        let request = client.request(path: path, authorized: true, queryItems: query)
        let (data, http) = try await client.send(request)
        if http.statusCode == 403 { throw ArcadeServiceError(message: readable(data) ?? KadeFamilyFeatures.note) }
        guard http.statusCode == 200, let link = try? JSONDecoder().decode(ArcadeSignedLink.self, from: data) else {
            throw ArcadeServiceError(message: readable(data) ?? "The download link could not be fetched. Try again.")
        }
        return link
    }

    private func fetchPack(_ pack: ArcadePackRef, gameId: String, store: ArcadeStore, before: Int64, total: Int64) async throws {
        guard let folder = store.folder(id: pack.id, version: pack.version) else {
            throw ArcadeServiceError(message: "The game's file names are not usable.")
        }
        // One writer per pack folder, ever.
        let flight = pack.key
        guard !Self.packsInFlight.contains(flight) else {
            throw ArcadeServiceError(message: "This game is already downloading. Wait for it to finish, then try again.")
        }
        Self.packsInFlight.insert(flight)
        defer { Self.packsInFlight.remove(flight) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ArcadeStore.excludeFromBackup(folder)
        let part = folder.appendingPathComponent("blob.part")
        let partNote = folder.appendingPathComponent("blob.part.json")
        // A partial file only counts toward the same blob (same sha256).
        let noted = (try? String(contentsOf: partNote, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if noted != pack.sha256 {
            try? FileManager.default.removeItem(at: part)
            try pack.sha256.write(to: partNote, atomically: true, encoding: .utf8)
        }

        let link = try await signedLink(for: pack, gameId: gameId)
        let indexData: Data
        if let inline = pack.index {
            // The phone's own copy of an inline list: indexSha256 is the
            // server's hash of its pack.json bytes, so it cannot apply here.
            indexData = try ArcadePackIndex(files: inline, blobSize: pack.size).jsonData()
        } else if let indexURL = link.indexURL {
            indexData = try await fetchSmall(indexURL)
            // Checked only on the bytes the server sent.
            if let want = pack.indexSha256, ArcadeHash.sha256Hex(of: indexData) != want {
                throw ArcadeServiceError(message: "The game's file list did not match. Try again later.")
            }
        } else {
            throw ArcadeServiceError(message: "The game's file list is missing from the server's answer.")
        }
        let index: ArcadePackIndex
        do { index = try ArcadePackIndex(data: indexData, blobSize: pack.size) }
        catch { throw ArcadeServiceError(message: "The game's file list could not be read. Try again later.") }

        // Twice at most: a link that expired mid-way is asked for again, and
        // the download carries on from the bytes already on the phone.
        var currentLink = link
        for attempt in 0..<2 {
            let have = Self.fileSize(part)
            if have >= pack.size { break }
            do {
                try await rangeDownload(currentLink.blobURL, to: part, from: have, expected: pack.size, before: before, total: total)
                break
            } catch let error as ArcadeRangeDownload.Refused where attempt == 0 && error.mayRetryWithFreshLink {
                currentLink = try await signedLink(for: pack, gameId: gameId)
            }
        }
        guard Self.fileSize(part) == pack.size else {
            throw ArcadeServiceError(message: "The download did not finish. Try again; it picks up where it stopped.")
        }
        verifying = true
        let hex = try await Task.detached(priority: .utility) { try ArcadeHash.sha256Hex(of: part) }.value
        verifying = false
        guard hex == pack.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw ArcadeServiceError(message: "The download arrived damaged, so it was thrown away. Try again.")
        }
        try store.commit(pack, part: part, index: index)
    }

    private func rangeDownload(_ url: URL, to part: URL, from have: Int64, expected: Int64, before: Int64, total: Int64) async throws {
        let delegate = ArcadeRangeDownload(target: part, startOffset: have, expected: expected) { @Sendable [weak self] written in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progress = min(1, Double(before + written) / Double(total))
            }
        }
        let session = client.makeAuxiliarySession(delegate: delegate, timeout: 60)
        defer { session.finishTasksAndInvalidate() }
        // One pacing wait per pack, not per file (KadeAPIClient's note).
        await client.awaitPacingGate()
        try await delegate.run(session: session, url: url)
    }

    /// pack.json: small, fetched whole from its signed link.
    private func fetchSmall(_ url: URL) async throws -> Data {
        let delegate = ArcadeQuietDelegate()
        let session = client.makeAuxiliarySession(delegate: delegate, timeout: 60)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 8 * 1024 * 1024 else {
            throw ArcadeServiceError(message: "The game's file list could not be fetched. Try again.")
        }
        return data
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return 0 }
        return size
    }

    // MARK: Playing and deleting

    func launch(for entry: ArcadeCatalogEntry) -> ArcadeLaunch? {
        guard let store = try? ArcadeStore(), let record = preferredRecord(for: entry, store: store) else { return nil }
        var game: [ArcadeMount] = []
        var kit: [ArcadeMount] = []
        for pack in record.packs {
            guard let mount = store.mount(id: pack.id, version: pack.version) else { return nil }
            if pack.kind == "kit" { kit.append(mount) } else { game.append(mount) }
        }
        guard !game.isEmpty else { return nil }
        return ArcadeLaunch(entry: entry, record: record, game: game, kit: kit)
    }

    func delete(_ entry: ArcadeCatalogEntry) {
        guard downloading != entry.id, let store = try? ArcadeStore() else { return }
        store.delete(gameId: entry.id)
        downloadErrors[entry.id] = nil
        prunePending[entry.id] = nil
        refreshInstalled()
    }
}

/// A delegate with nothing to add (the auxiliary session wants one).
final class ArcadeQuietDelegate: NSObject, URLSessionDelegate {}

// MARK: - One resumable download into blob.part

/// Streams one signed link into a file with HTTP Range, starting at the bytes
/// already there. Delegate callbacks arrive on the session's own queue; the
/// file handle and counters are only touched there, and the one continuation
/// is guarded by a lock.
final class ArcadeRangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Refused: LocalizedError {
        let status: Int
        var errorDescription: String? { "The download server refused (status \(status)). Try again later." }
        /// 401/403 from the storage host: the one-hour link ran out.
        var mayRetryWithFreshLink: Bool { status == 401 || status == 403 }
    }

    private let target: URL
    private let startOffset: Int64
    private let expected: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var written: Int64
    private var lastReported: Int64 = 0
    private var failure: Error?
    private var alreadyWhole = false

    init(target: URL, startOffset: Int64, expected: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.target = target
        self.startOffset = startOffset
        self.expected = expected
        self.progress = progress
        written = startOffset
    }

    func run(session: URLSession, url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if startOffset > 0 { request.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        guard let waiting else { return }
        if let error { waiting.resume(throwing: error) } else { waiting.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = ArcadeServiceError(message: "The download server answered strangely. Try again.")
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206:
                // Content-Range must start where the file on the phone ends.
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(startOffset)-") else {
                    failure = ArcadeServiceError(message: "The download server sent the wrong part of the file. Try again.")
                    completionHandler(.cancel)
                    return
                }
                try openHandle(truncate: false)
            case 200:
                // The whole file again (the server ignored Range): start over.
                written = 0
                try openHandle(truncate: true)
            case 416 where startOffset >= expected:
                alreadyWhole = true
                completionHandler(.cancel)
                return
            default:
                failure = Refused(status: http.statusCode)
                completionHandler(.cancel)
                return
            }
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    private func openHandle(truncate: Bool) throws {
        if !FileManager.default.fileExists(atPath: target.path) {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: target)
        if truncate { try file.truncate(atOffset: 0) }
        try file.seekToEnd()
        handle = file
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        do {
            if written + Int64(data.count) > expected {
                throw ArcadeServiceError(message: "The download was bigger than the game's list says. Try again later.")
            }
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            if written - lastReported >= 512 * 1024 || written == expected {
                lastReported = written
                progress(written)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if alreadyWhole { finish(nil); return }
        if let failure { finish(failure); return }
        if let error { finish(error); return }
        finish(written == expected ? nil : ArcadeServiceError(message: "The download ended early. Try again; it picks up where it stopped."))
    }
}
#endif
