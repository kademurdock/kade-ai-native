import Foundation
import CryptoKit

// MARK: - THE ARCADE (Oct 18 2026, Milestone 1), the pure half
//
// Everything here is plain Foundation (plus CryptoKit for one hash), so
// run-arcade-tests.sh can compile it with swiftc and no simulator:
//   - the server's answers (catalog, manifest, signed pack links), read leniently
//   - the shelf rule: family games greyed, never hidden; outside the Family
//     feature pack every family game folds into ONE "Family shelf" row that
//     names no game (the App Review seat's null features reads as locked)
//   - packs: one pack.json index plus one blob.bin, files found by offset and
//     length, so the app needs no zip library
//   - the kadearcade:// scheme's routing, MIME types and byte ranges
//   - the touch recognizer, a port of the Revival kit's core/touch.js driven by
//     the same gesture tables (profile.input.touch), with the two halves of a
//     fight working side by side and holds that may carry their own time
//     (core/touch.js still runs one gesture for the whole pad)
//   - the game's own save file, kept between page starts (ArcadeSaveStore)
//   - the controller mapper, a port of core/input.js pollGamepad (profile.input.gamepad)
//   - the JavaScript the app sends to window.revivalKit, and the
//     window.revivalKitHost script injected at document start (core/host.js)
//   - telemetry counters and the "how the game ran" text
//
// Oct 19 2026, her decision: the Arcade is part of every build, the public
// App Store one included, and visible to every account. The family shelf
// stays visible but greyed outside the Family feature pack. No game, ROM,
// sample or clip is ever in the app or the repo: games arrive from her
// server as data, after the player says yes to the download.

// MARK: - Lenient reading

extension KeyedDecodingContainer {
    /// A trimmed, non-empty string; numbers are accepted and written out.
    func arcadeText(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let whole = try? decodeIfPresent(Int64.self, forKey: key) { return String(whole) }
        if let real = try? decodeIfPresent(Double.self, forKey: key), real.isFinite { return String(real) }
        return nil
    }

    /// A whole, non-negative number from a number or a numeric string.
    func arcadeNumber(_ key: Key) -> Int64? {
        if let whole = try? decodeIfPresent(Int64.self, forKey: key) { return whole >= 0 ? whole : nil }
        if let real = try? decodeIfPresent(Double.self, forKey: key), real.isFinite, real >= 0, real < 9.0e15 {
            return Int64(real.rounded())
        }
        if let text = try? decodeIfPresent(String.self, forKey: key),
           let whole = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)), whole >= 0 {
            return whole
        }
        return nil
    }

    func arcadeFlag(_ key: Key) -> Bool? {
        if let flag = try? decodeIfPresent(Bool.self, forKey: key) { return flag }
        if let whole = try? decodeIfPresent(Int.self, forKey: key) { return whole != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

/// One element of a list that is dropped, not fatal, when it cannot be read.
struct ArcadeLenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// A number from JSONSerialization output (NSNumber or a numeric string).
func arcadeJSONNumber(_ any: Any?) -> Double? {
    if let number = any as? NSNumber {
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
    if let text = any as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

// MARK: - Names and paths

enum ArcadePaths {
    private static let nameCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// A game id, pack id or version that is safe as one folder name.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 80, name != ".", name != "..", !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { nameCharacters.contains($0) }
    }

    /// A relative file path with no "..", no empty parts and no leading
    /// slash ("./a//b" -> "a/b"). Nil when it would escape or is empty.
    static func normalize(_ raw: String) -> String? {
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            if part.contains("\\") || part.contains(":") { return nil }
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// A relative folder, always ending in "/" (or "" for the root).
    static func normalizeFolder(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" || trimmed == "./" || trimmed == "." { return "" }
        guard let path = normalize(trimmed) else { return nil }
        return path + "/"
    }

    /// The folder a file sits in: "games/demo/play.html" -> "games/demo/".
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }
}

// MARK: - The catalog

enum ArcadeAccess: String, Equatable {
    case family
    case open = "public"
}

/// One game on the shelf, from GET /api/kade/arcade/config.
struct ArcadeCatalogEntry: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let console: String?
    let access: ArcadeAccess
    /// Download size in bytes, for the row (the manifest has the exact figure).
    let size: Int64?
    let version: String
    /// The server's own lock for this account (an age rule, a game not ready).
    let locked: Bool
    let note: String?
    let summary: String?
    /// Oct 19 2026 (App Store 4.7.5): the catalog marks this game for grown-ups
    /// only. A child account never gets the row (the server leaves it out);
    /// for everyone else the row says "Grown-ups only". Absent means false.
    let grownUpsOnly: Bool

    enum CodingKeys: String, CodingKey { case id, title, console, access, size, version, locked, note, summary, grownUpsOnly }

    init(id: String, title: String, console: String? = nil, access: ArcadeAccess, size: Int64? = nil,
         version: String, locked: Bool = false, note: String? = nil, summary: String? = nil,
         grownUpsOnly: Bool = false) {
        self.id = id
        self.title = title
        self.console = console
        self.access = access
        self.size = size
        self.version = version
        self.locked = locked
        self.note = note
        self.summary = summary
        self.grownUpsOnly = grownUpsOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.arcadeText(.id), ArcadePaths.isSafeName(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "A game needs a plain id")
        }
        self.id = id
        title = c.arcadeText(.title) ?? id
        console = c.arcadeText(.console)
        // Anything but an explicit "public" is treated as family: the safer shelf.
        access = c.arcadeText(.access)?.lowercased() == "public" ? .open : .family
        size = c.arcadeNumber(.size)
        version = c.arcadeText(.version) ?? ""
        locked = c.arcadeFlag(.locked) ?? false
        note = c.arcadeText(.note)
        summary = c.arcadeText(.summary)
        grownUpsOnly = c.arcadeFlag(.grownUpsOnly) ?? false
    }

    /// The version can name a folder on the phone.
    var hasUsableVersion: Bool { ArcadePaths.isSafeName(version) }
}

/// GET /api/kade/arcade/config. The `features` map rides beside it and is read
/// by the app as KadeFamilyFeatures (SoundBoothService.swift), not here.
struct ArcadeConfig: Decodable {
    let catalog: [ArcadeCatalogEntry]
    let message: String?
    /// Oct 19 2026: the kit's version (`kit.version`), for games added from
    /// Files: they need the kit (the player) but no shelf game's manifest.
    let kitVersion: String?

    enum CodingKeys: String, CodingKey { case catalog, games, message, kit }

    private struct KitRow: Decodable {
        let version: String?
        enum CodingKeys: String, CodingKey { case version }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.arcadeText(.version)
        }
    }

    init(catalog: [ArcadeCatalogEntry], message: String? = nil, kitVersion: String? = nil) {
        self.catalog = catalog
        self.message = message
        self.kitVersion = kitVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try? c.decodeIfPresent([ArcadeLenient<ArcadeCatalogEntry>].self, forKey: .catalog)
        let alternate = try? c.decodeIfPresent([ArcadeLenient<ArcadeCatalogEntry>].self, forKey: .games)
        let rows: [ArcadeLenient<ArcadeCatalogEntry>] = primary ?? alternate ?? []
        var seen = Set<String>()
        var entries: [ArcadeCatalogEntry] = []
        for row in rows {
            guard let entry = row.value, !seen.contains(entry.id) else { continue }
            seen.insert(entry.id)
            entries.append(entry)
        }
        catalog = entries
        message = c.arcadeText(.message)
        let kit = try? c.decodeIfPresent(KitRow.self, forKey: .kit)
        if let version = kit?.version, ArcadePaths.isSafeName(version) {
            kitVersion = version
        } else {
            kitVersion = nil
        }
    }
}

/// One row of the Arcade list.
enum ArcadeShelfRow: Equatable, Identifiable {
    /// A game this account may download and play.
    case playable(ArcadeCatalogEntry)
    /// A game shown greyed out, with the reason beside it.
    case locked(ArcadeCatalogEntry, reason: String)
    /// Every family game, folded into one greyed row that names no game.
    case familyShelf(reason: String)

    var id: String {
        switch self {
        case .playable(let entry): return "game-" + entry.id
        case .locked(let entry, _): return "locked-" + entry.id
        case .familyShelf: return "family-shelf"
        }
    }
}

enum ArcadeShelf {
    static let shelfTitle = "Family shelf"
    static let notReady = "This game is not ready to download yet."
    static let publicLocked = "Not open on this account yet."

    /// The rows, in catalog order. `familyOpen` is true only when the pack
    /// map says arcadeFamily is true; a missing or null map (the App Review
    /// seat) is locked. Outside the pack the family games become ONE greyed
    /// row at the first family game's place (or at the end), and the server's
    /// own per-game note is not used, so no title can leak through it.
    static func rows(_ catalog: [ArcadeCatalogEntry], familyOpen: Bool, familyNote: String) -> [ArcadeShelfRow] {
        var rows: [ArcadeShelfRow] = []
        var shelfPlaced = false
        for entry in catalog {
            switch entry.access {
            case .open:
                if entry.locked { rows.append(.locked(entry, reason: entry.note ?? publicLocked)) }
                else if !entry.hasUsableVersion { rows.append(.locked(entry, reason: notReady)) }
                else { rows.append(.playable(entry)) }
            case .family:
                if familyOpen {
                    if entry.locked { rows.append(.locked(entry, reason: entry.note ?? familyNote)) }
                    else if !entry.hasUsableVersion { rows.append(.locked(entry, reason: notReady)) }
                    else { rows.append(.playable(entry)) }
                } else if !shelfPlaced {
                    shelfPlaced = true
                    rows.append(.familyShelf(reason: familyNote))
                }
            }
        }
        if !familyOpen && !shelfPlaced { rows.append(.familyShelf(reason: familyNote)) }
        return rows
    }

    /// The one way into a download or a game: the catalog entry with this id,
    /// only while the shelf shows it as playable. A locked row (an age rule,
    /// a family game outside the pack, a game not ready) answers nil, so
    /// nothing about it can download or launch, even with its packs already
    /// on the phone.
    static func playable(_ id: String, in rows: [ArcadeShelfRow]) -> ArcadeCatalogEntry? {
        for row in rows {
            if case .playable(let entry) = row, entry.id == id, !entry.locked { return entry }
        }
        return nil
    }

    /// What VoiceOver says for a greyed row: the reason FIRST, then the name
    /// ("Part of the Family feature pack. Family shelf"), so the reason is
    /// heard even when she swipes on before the end, and with hints off.
    static func lockedLabel(title: String, reason: String) -> String {
        var said = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = said.last, last == "." || last == ":" || last == "," { said.removeLast() }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.isEmpty { return name }
        return name.isEmpty ? said : said + ". " + name
    }

    /// The plain description at the top of the Arcade screen: what it is, and
    /// who each shelf is for. No game is named.
    /// The player, the pad and the page's file server are part of the app;
    /// no game is.
    static let about = "Classic games you can play by ear. Family shelf games are private to Kade's family and greyed out for everyone else; public games are free for everyone. Games download from Kade's server when you ask, or you can add your own game files under My games, and no game is built into the app."
    /// Under the list when the shelf has no public game. A plain fact, no promise.
    static let noPublicGames = "There are no public games on the shelf right now."
    /// Said and shown for a game the catalog marks for grown-ups only (4.7.5).
    static let grownUpsOnly = "Grown-ups only"

    /// The small line under a game's name: grown-ups only first when it is,
    /// then the console and the download size.
    static func caption(_ entry: ArcadeCatalogEntry) -> String {
        var parts: [String] = []
        if entry.grownUpsOnly { parts.append(grownUpsOnly) }
        if let console = entry.console { parts.append(console) }
        if let size = entry.size { parts.append(ArcadeText.size(size)) }
        return parts.isEmpty ? "A classic game" : parts.joined(separator: ", ")
    }

    /// True when the shelf holds a public game, playable or not.
    static func hasPublicGame(_ rows: [ArcadeShelfRow]) -> Bool {
        rows.contains { row in
            switch row {
            case .playable(let entry), .locked(let entry, _): return entry.access == .open
            case .familyShelf: return false
            }
        }
    }
}

// MARK: - Report a problem with a game (App Store guideline 4.7.1)

/// What a report is about: a game (its id, its listed title and the version
/// on this iPhone, or the catalog's before any download), or the Arcade
/// itself when `gameId` is empty.
struct ArcadeReportTarget: Identifiable, Equatable {
    let gameId: String
    let title: String
    let version: String
    var id: String { gameId + "@" + version }

    /// The whole Arcade, no one game (the button at the foot of the screen).
    static let arcade = ArcadeReportTarget(gameId: "", title: "The Arcade", version: "")
}

/// The words of a game report. It travels the app's one feedback path
/// (FeedbackReportService, POST /api/kade/feedback, category "bug"), so it
/// lands on Kade's feedback board beside every other report.
enum ArcadeReport {
    static let actionName = "Report a problem with this game"
    static let arcadeActionName = "Report a problem with the Arcade"
    static let sentLine = "Report sent. Thank you, Kade will see it."
    static let minimumNote = 3
    static let maximumNote = 2000
    /// How the game ran (ArcadeTelemetry.report), when the report comes from
    /// a running game's Settings. The server keeps 8,000 characters in all.
    static let maximumRun = 4000

    static func canSend(_ note: String) -> Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumNote
    }

    /// The board's short title (the server keeps 200 characters).
    static func subject(_ target: ArcadeReportTarget) -> String {
        let title = target.gameId.isEmpty ? "Arcade report" : "Arcade game report: " + target.title
        return String(title.prefix(200))
    }

    /// Her words first, then the game's id and version and where it was sent
    /// from, then (from a running game) how the game ran, cut to size. That
    /// text holds no account details.
    static func detail(note: String, target: ArcadeReportTarget, from place: String, ran: String? = nil) -> String {
        let said = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNote))
        var lines = [said, ""]
        if target.gameId.isEmpty {
            lines.append("About: the Arcade itself, no one game")
        } else {
            lines.append("Game: " + target.title)
            lines.append("Game id: " + target.gameId)
            lines.append("Game version: " + (target.version.isEmpty ? "not known" : target.version))
        }
        lines.append("Sent from: " + place)
        let run = (ran ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !run.isEmpty {
            lines.append("")
            lines.append("How the game ran:")
            lines.append(String(run.prefix(maximumRun)))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The manifest and packs

/// One downloadable pack: the shared kit (EmulatorJS data plus the kit's own
/// JavaScript) or a game (its page, profile, ROM, sample bank and voice clips).
struct ArcadePackRef: Decodable, Equatable {
    let kind: String
    let id: String
    let version: String
    /// blob.bin's exact size in bytes.
    let size: Int64
    /// blob.bin's sha256, 64 lowercase hex characters.
    let sha256: String
    /// pack.json's sha256, when the server sends one.
    let indexSha256: String?
    /// The path (under kademurdock.com) that answers with a signed link.
    let signPath: String?
    /// pack.json's file list sent inline, instead of as its own file.
    let index: [ArcadePackFile]?

    enum CodingKeys: String, CodingKey { case kind, id, version, size, bytes, sha256, indexSha256, signPath, index, files }

    init(kind: String, id: String, version: String, size: Int64, sha256: String,
         indexSha256: String? = nil, signPath: String? = nil, index: [ArcadePackFile]? = nil) {
        self.kind = kind
        self.id = id
        self.version = version
        self.size = size
        self.sha256 = sha256
        self.indexSha256 = indexSha256
        self.signPath = signPath
        self.index = index
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.arcadeText(.id), ArcadePaths.isSafeName(id),
              let version = c.arcadeText(.version), ArcadePaths.isSafeName(version) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "A pack needs a plain id and version")
        }
        guard let size = c.arcadeNumber(.size) ?? c.arcadeNumber(.bytes), size > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .size, in: c, debugDescription: "A pack needs its size")
        }
        guard let sha = c.arcadeText(.sha256)?.lowercased(), ArcadeHash.isHex64(sha) else {
            throw DecodingError.dataCorruptedError(forKey: .sha256, in: c, debugDescription: "A pack needs its sha256")
        }
        self.id = id
        self.version = version
        self.size = size
        self.sha256 = sha
        kind = c.arcadeText(.kind)?.lowercased() ?? "game"
        let indexSha = c.arcadeText(.indexSha256)?.lowercased()
        indexSha256 = indexSha.flatMap { ArcadeHash.isHex64($0) ? $0 : nil }
        signPath = c.arcadeText(.signPath)
        let primary: [ArcadeLenient<ArcadePackFile>]? = try? c.decodeIfPresent([ArcadeLenient<ArcadePackFile>].self, forKey: .index)
        let alternate: [ArcadeLenient<ArcadePackFile>]? = try? c.decodeIfPresent([ArcadeLenient<ArcadePackFile>].self, forKey: .files)
        let files: [ArcadePackFile] = (primary ?? alternate ?? []).compactMap { $0.value }
        index = files.isEmpty ? nil : files
    }

    /// The pack's folder key: "<id>/<version>".
    var key: String { id + "/" + version }
}

/// GET /api/kade/arcade/games/:id/manifest: where the page is inside the
/// packs, and which packs the game needs.
struct ArcadeManifest: Decodable, Equatable {
    let id: String
    let version: String
    /// The game page, relative to the kadearcade://game/ root.
    let entry: String
    /// window.revivalKitHost.base: the folder the game's files sit under.
    let base: String
    /// window.revivalKitHost.emulatorData: EmulatorJS's data folder (kit pack).
    let emulatorData: String
    let packs: [ArcadePackRef]
    /// The server's `ready`: false while the game is listed but its packs are
    /// not uploaded yet. A manifest without it counts as ready.
    let ready: Bool
    /// Oct 19 2026, an accessibility pack's manifest (?version=<accessVersion>):
    /// where the pack's page expects the person's own ROM.
    let romPath: String?

    enum CodingKeys: String, CodingKey {
        case id, version, entry, page, base, emulatorData, packs, ready, size, bytes, sha256, indexSha256, signPath, index, files, romPath
    }

    init(id: String, version: String, entry: String, base: String, emulatorData: String, packs: [ArcadePackRef], ready: Bool = true,
         romPath: String? = nil) {
        self.id = id
        self.version = version
        self.entry = entry
        self.base = base
        self.emulatorData = emulatorData
        self.packs = packs
        self.ready = ready
        self.romPath = romPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.arcadeText(.id), ArcadePaths.isSafeName(id),
              let version = c.arcadeText(.version), ArcadePaths.isSafeName(version) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "A manifest needs a plain id and version")
        }
        self.id = id
        self.version = version
        let rawEntry = c.arcadeText(.entry) ?? c.arcadeText(.page) ?? "games/\(id)/play.html"
        guard let entry = ArcadePaths.normalize(rawEntry) else {
            throw DecodingError.dataCorruptedError(forKey: .entry, in: c, debugDescription: "The page path is not usable")
        }
        self.entry = entry
        guard let base = ArcadePaths.normalizeFolder(c.arcadeText(.base) ?? ArcadePaths.folder(of: entry)),
              let data = ArcadePaths.normalizeFolder(c.arcadeText(.emulatorData) ?? "emulatorjs/") else {
            throw DecodingError.dataCorruptedError(forKey: .base, in: c, debugDescription: "A folder path is not usable")
        }
        self.base = base
        emulatorData = data
        ready = c.arcadeFlag(.ready) ?? true
        romPath = c.arcadeText(.romPath).flatMap { ArcadePaths.normalize($0) }
        let listed: [ArcadeLenient<ArcadePackRef>]? = try? c.decodeIfPresent([ArcadeLenient<ArcadePackRef>].self, forKey: .packs)
        var packs: [ArcadePackRef] = listed?.compactMap { $0.value } ?? []
        if packs.isEmpty, let single = try? ArcadePackRef(from: decoder) {
            // A one-pack manifest: the game's own size and sha256 at the top.
            packs = [single]
        }
        var seen = Set<String>()
        self.packs = packs.filter { seen.insert($0.key).inserted }
    }

    var totalBytes: Int64 { packs.reduce(0) { $0 + $1.size } }

    /// Bytes still to fetch, given the pack keys already on the phone.
    func bytesMissing(installed: Set<String>) -> Int64 {
        packs.filter { !installed.contains($0.key) }.reduce(0) { $0 + $1.size }
    }

    /// Why this manifest cannot be installed, or nil.
    var problem: String? {
        if !ready { return ArcadeShelf.notReady }
        if packs.isEmpty { return "The game's download list is empty." }
        if !packs.contains(where: { $0.kind != "kit" }) { return "The game's own files are missing from its download list." }
        return nil
    }
}

/// The answer to GET .../pack?sign=1: a one-hour link to blob.bin, and to
/// pack.json unless the manifest carries the index inline.
struct ArcadeSignedLink: Decodable, Equatable {
    let blobURL: URL
    let indexURL: URL?

    enum CodingKeys: String, CodingKey { case url, blob, blobUrl, href, indexUrl, index, packJson, packJsonUrl }

    init(blobURL: URL, indexURL: URL?) {
        self.blobURL = blobURL
        self.indexURL = indexURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func link(_ keys: [CodingKeys]) -> URL? {
            for key in keys {
                if let text = c.arcadeText(key), let url = URL(string: text),
                   let scheme = url.scheme?.lowercased(), scheme == "https" { return url }
            }
            return nil
        }
        guard let blob = link([.url, .blobUrl, .blob, .href]) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "No https download link")
        }
        blobURL = blob
        indexURL = link([.indexUrl, .packJsonUrl, .packJson, .index])
    }
}

/// One file inside blob.bin.
struct ArcadePackFile: Decodable, Equatable {
    let path: String
    let offset: Int64
    let length: Int64
    let mime: String?

    enum CodingKeys: String, CodingKey { case path, name, offset, length, size, mime, type }

    init(path: String, offset: Int64, length: Int64, mime: String? = nil) {
        self.path = path
        self.offset = offset
        self.length = length
        self.mime = mime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = c.arcadeText(.path) ?? c.arcadeText(.name), let path = ArcadePaths.normalize(raw),
              let offset = c.arcadeNumber(.offset), let length = c.arcadeNumber(.length) ?? c.arcadeNumber(.size) else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "A pack file needs path, offset and length")
        }
        self.path = path
        self.offset = offset
        self.length = length
        mime = c.arcadeText(.mime) ?? c.arcadeText(.type)
    }

    /// From pack.json read with JSONSerialization.
    init?(json: [String: Any], path given: String? = nil) {
        guard let raw = given ?? (json["path"] as? String) ?? (json["name"] as? String),
              let path = ArcadePaths.normalize(raw),
              let offset = arcadeJSONNumber(json["offset"]), offset >= 0,
              let length = arcadeJSONNumber(json["length"] ?? json["size"]), length >= 0 else { return nil }
        self.path = path
        self.offset = Int64(offset)
        self.length = Int64(length)
        mime = (json["mime"] as? String) ?? (json["type"] as? String)
    }
}

/// pack.json, checked against blob.bin's size so no read can leave the blob.
struct ArcadePackIndex: Equatable {
    enum Problem: Error, Equatable {
        case unreadable
        case empty
        case outOfRange(String)
    }

    let files: [String: ArcadePackFile]

    init(files list: [ArcadePackFile], blobSize: Int64) throws {
        var files: [String: ArcadePackFile] = [:]
        for file in list {
            guard file.offset >= 0, file.length >= 0, file.offset <= blobSize,
                  file.length <= blobSize - file.offset else { throw Problem.outOfRange(file.path) }
            files[file.path] = file
        }
        guard !files.isEmpty else { throw Problem.empty }
        self.files = files
    }

    /// Accepts {"files": [{path, offset, length, mime?}]}, {"files": {path: {offset, length}}}
    /// or {"files": {path: [offset, length]}}.
    init(data: Data, blobSize: Int64) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Problem.unreadable }
        var list: [ArcadePackFile] = []
        if let rows = root["files"] as? [[String: Any]] {
            for row in rows { if let file = ArcadePackFile(json: row) { list.append(file) } }
        } else if let map = root["files"] as? [String: Any] {
            for (path, value) in map {
                if let row = value as? [String: Any], let file = ArcadePackFile(json: row, path: path) {
                    list.append(file)
                } else if let pair = value as? [Any], pair.count >= 2,
                          let offset = arcadeJSONNumber(pair[0]), let length = arcadeJSONNumber(pair[1]),
                          offset >= 0, length >= 0, let clean = ArcadePaths.normalize(path) {
                    list.append(ArcadePackFile(path: clean, offset: Int64(offset), length: Int64(length)))
                }
            }
        } else {
            throw Problem.unreadable
        }
        try self.init(files: list, blobSize: blobSize)
    }

    func file(at path: String) -> ArcadePackFile? { files[path] }

    /// pack.json as the phone keeps it (sorted, so the same index is the same bytes).
    func jsonData() -> Data {
        var rows: [[String: Any]] = []
        for key in files.keys.sorted() {
            guard let file = files[key] else { continue }
            var row: [String: Any] = ["path": file.path, "offset": NSNumber(value: file.offset), "length": NSNumber(value: file.length)]
            if let mime = file.mime { row["mime"] = mime }
            rows.append(row)
        }
        let root: [String: Any] = ["format": 1, "files": rows]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }
}

/// A pack on the phone: its index and where blob.bin is.
struct ArcadeMount: Equatable {
    let id: String
    let version: String
    let index: ArcadePackIndex
    let blob: URL

    /// The first mount holding `path`.
    static func locate(_ path: String, in mounts: [ArcadeMount]) -> (mount: ArcadeMount, file: ArcadePackFile)? {
        for mount in mounts {
            if let file = mount.index.file(at: path) { return (mount, file) }
        }
        return nil
    }
}

/// What the phone writes beside an installed game (Arcade/<id>/<version>/install.json).
struct ArcadeInstallRecord: Codable, Equatable {
    struct Pack: Codable, Equatable {
        let kind: String
        let id: String
        let version: String
        let sha256: String
    }
    let gameId: String
    let version: String
    let title: String
    let entry: String
    let base: String
    let emulatorData: String
    let packs: [Pack]

    init(gameId: String, version: String, title: String, entry: String, base: String,
         emulatorData: String, packs: [Pack]) {
        self.gameId = gameId
        self.version = version
        self.title = title
        self.entry = entry
        self.base = base
        self.emulatorData = emulatorData
        self.packs = packs
    }

    init(manifest: ArcadeManifest, title: String) {
        gameId = manifest.id
        version = manifest.version
        self.title = title
        entry = manifest.entry
        base = manifest.base
        emulatorData = manifest.emulatorData
        packs = manifest.packs.map { Pack(kind: $0.kind, id: $0.id, version: $0.version, sha256: $0.sha256) }
    }
}

// MARK: - The kadearcade:// scheme

enum ArcadeRoute {
    static let scheme = "kadearcade"

    enum Host: String {
        /// The kit pack only.
        case kit
        /// The page's origin: the game pack first, then the kit pack, so the
        /// page's own "../../core/app.js" imports stay same-origin.
        case game
    }

    static func resolve(_ url: URL) -> (host: Host, path: String)? {
        guard url.scheme?.lowercased() == scheme,
              let name = url.host?.lowercased(), let host = Host(rawValue: name),
              let path = ArcadePaths.normalize(url.path) else { return nil }
        return (host, path)
    }

    static func root(_ host: Host) -> String { scheme + "://" + host.rawValue + "/" }
}

enum ArcadeMime {
    static func type(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "wasm": return "application/wasm"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "ogg", "oga", "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/mp4"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "zip": return "application/zip"
        case "7z": return "application/x-7z-compressed"
        default: return "application/octet-stream"   // .data, .pack, .z64, .bin and anything new
        }
    }
}

enum ArcadeByteRange: Equatable {
    case whole
    /// Inclusive byte positions.
    case part(start: Int64, end: Int64)
    case unsatisfiable

    /// One "bytes=" range, as media elements and fetch send it. Several
    /// ranges, or a header that is not about bytes, get the whole file.
    static func parse(_ header: String?, total: Int64) -> ArcadeByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty,
              header.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = header.dropFirst(6)
        if spec.contains(",") { return .whole }
        let bits = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bits.count == 2 else { return .whole }
        let first = bits[0].trimmingCharacters(in: .whitespaces)
        let last = bits[1].trimmingCharacters(in: .whitespaces)
        guard total > 0 else { return .unsatisfiable }
        if first.isEmpty {
            guard let suffix = Int64(last), suffix > 0 else { return .unsatisfiable }
            let length = min(suffix, total)
            return .part(start: total - length, end: total - 1)
        }
        guard let start = Int64(first), start >= 0 else { return .whole }
        if start >= total { return .unsatisfiable }
        if last.isEmpty { return .part(start: start, end: total - 1) }
        guard let end = Int64(last), end >= start else { return .whole }
        return .part(start: start, end: min(end, total - 1))
    }
}

/// What the scheme handler answers for one request, worked out without WebKit.
enum ArcadeServePlan: Equatable {
    case notFound(String)
    case unsatisfiable(total: Int64)
    case serve(blob: URL, offset: Int64, length: Int64, status: Int, headers: [String: String])

    /// `overlays` (Oct 19 2026): a game added from Files, served at the path
    /// its page expects, on either host, before anything in the packs.
    static func make(url: URL, rangeHeader: String?, game: [ArcadeMount], kit: [ArcadeMount],
                     overlays: [ArcadeOverlay] = []) -> ArcadeServePlan {
        guard let route = ArcadeRoute.resolve(url) else { return .notFound(url.absoluteString) }
        let blob: URL
        let start: Int64
        let total: Int64
        let mime: String
        if let overlay = overlays.first(where: { $0.path == route.path }) {
            blob = overlay.file
            start = 0
            total = overlay.length
            mime = overlay.mime ?? ArcadeMime.type(for: route.path)
        } else {
            let mounts = route.host == .kit ? kit : game + kit
            guard let found = ArcadeMount.locate(route.path, in: mounts) else { return .notFound(route.path) }
            blob = found.mount.blob
            start = found.file.offset
            total = found.file.length
            mime = found.file.mime ?? ArcadeMime.type(for: route.path)
        }
        var headers: [String: String] = [
            "Content-Type": mime,
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        switch ArcadeByteRange.parse(rangeHeader, total: total) {
        case .whole:
            headers["Content-Length"] = String(total)
            return .serve(blob: blob, offset: start, length: total, status: 200, headers: headers)
        case .part(let first, let last):
            let length = last - first + 1
            headers["Content-Length"] = String(length)
            headers["Content-Range"] = "bytes \(first)-\(last)/\(total)"
            return .serve(blob: blob, offset: start + first, length: length, status: 206, headers: headers)
        case .unsatisfiable:
            return .unsatisfiable(total: total)
        }
    }
}

/// Reads one slice of blob.bin. Opens its own handle, so any thread may call it.
enum ArcadeBlobReader {
    static func read(_ url: URL, offset: Int64, length: Int64) throws -> Data {
        guard offset >= 0, length >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        if length == 0 { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard data.count == Int(length) else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

enum ArcadeHash {
    static func isHex64(_ text: String) -> Bool {
        text.count == 64 && text.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file through in 1 MB pieces; a 50 MB pack never sits in memory.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data = try autoreleasepool { try handle.read(upToCount: 1 << 20) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The game's own saves

/// The game's save file (N64: EEPROM, four Controller Paks, SRAM and FlashRAM
/// in one .srm), kept by the app so it outlives the page: the kit sends it as
/// the 'saved' event (base64) at pause and menu moments and takes it back as
/// revivalKitHost.saveData at boot (core/saves.js). One file per game, outside
/// the downloaded packs, so Delete download and updates never touch it. It
/// stays in iCloud backups: it is her progress, and holds nothing of the game.
struct ArcadeSaveStore {
    let root: URL
    /// A whole N64 save is 0x48800 bytes; anything far bigger is not a save.
    static let maxBytes = 4 * 1024 * 1024

    init(root: URL) { self.root = root }

    /// Application Support/ArcadeSaves.
    static func standard() throws -> ArcadeSaveStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return ArcadeSaveStore(root: support.appendingPathComponent("ArcadeSaves", isDirectory: true))
    }

    func file(gameId: String) -> URL? {
        guard ArcadePaths.isSafeName(gameId) else { return nil }
        return root.appendingPathComponent(gameId + ".srm")
    }

    /// Keeps a save the page sent (base64). False when it is not one.
    @discardableResult
    func keep(base64 text: String, gameId: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= Self.maxBytes * 2, let file = file(gameId: gameId),
              let bytes = Data(base64Encoded: text), !bytes.isEmpty, bytes.count <= Self.maxBytes else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The kept save as base64, for revivalKitHost.saveData; nil when there is none.
    func base64(gameId: String) -> String? {
        guard let file = file(gameId: gameId), let bytes = try? Data(contentsOf: file),
              !bytes.isEmpty, bytes.count <= Self.maxBytes else { return nil }
        return bytes.base64EncodedString()
    }
}

// MARK: - The pad: state, actions and gesture tables (profile.input.touch)

/// One input source's whole controller, as the kit's revivalKit.pad takes it:
/// stick -1...1 (+x right, +y down), pad button names ('A', 'CL', 'START') or
/// the virtual 'block', and info keys fired on press.
struct ArcadePadState: Equatable {
    var sx: Double = 0
    var sy: Double = 0
    var buttons: [String] = []
    var info: [String] = []

    var isEmpty: Bool { sx == 0 && sy == 0 && buttons.isEmpty && info.isEmpty }
}

extension ArcadePadState {
    init(json: [String: Any]) {
        sx = arcadeJSONNumber(json["sx"]) ?? 0
        sy = arcadeJSONNumber(json["sy"]) ?? 0
        buttons = (json["buttons"] as? [Any])?.compactMap { $0 as? String } ?? []
        info = (json["info"] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

enum ArcadePadAction: Equatable {
    /// Pressed for the table's pulseMs, then let go.
    case pulse(ArcadePadState)
    /// Held while the fingers stay down.
    case hold(ArcadePadState)
    /// An info key by name ('health', 'where', 'facing', 'time', 'repeat').
    case info(String)

    init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        if let pulse = row["pulse"] as? [String: Any] { self = .pulse(ArcadePadState(json: pulse)) }
        else if let hold = row["hold"] as? [String: Any] { self = .hold(ArcadePadState(json: hold)) }
        else if let info = row["info"] as? String, !info.isEmpty { self = .info(info) }
        else { return nil }
    }
}

enum ArcadeDirection: String, CaseIterable {
    case up, down, left, right

    /// The bigger of the two travels wins (core/touch.js).
    static func of(dx: Double, dy: Double) -> ArcadeDirection {
        abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
    }
}

struct ArcadeFlick: Equatable {
    var actions: [ArcadeDirection: ArcadePadAction] = [:]
    /// A finger kept down after a menu flick steps again (repeatAfterMs, then every repeatEveryMs).
    var repeats = false

    init(json: [String: Any]) {
        for direction in ArcadeDirection.allCases {
            if let action = ArcadePadAction(json: json[direction.rawValue]) { actions[direction] = action }
        }
        repeats = (json["repeat"] as? Bool) ?? false
    }
}

/// One table of gestures: tapN, doubleTapN, holdN, flickN, stick1, pressN (N = fingers).
/// A hold may carry its own time, `{"hold1": {"info": "repeat", "ms": 1000}}`;
/// without one it takes the table's holdMs. A press (Oct 19 2026, the kit's
/// plain player) is a pad state held from the moment the first finger lands
/// until the last one lifts: `{"press1": {"buttons": ["A"]}}`.
struct ArcadeGestureSet: Equatable {
    var taps: [Int: ArcadePadAction] = [:]
    var doubleTaps: [Int: ArcadePadAction] = [:]
    var holds: [Int: ArcadePadAction] = [:]
    /// A hold's own time in milliseconds, by finger count, when it has one.
    var holdTimes: [Int: Double] = [:]
    var flicks: [Int: ArcadeFlick] = [:]
    /// Present when one finger is a floating stick; 0 means the table's stickRadiusPx.
    var stickRadius: Double?
    /// Pad states held while the fingers stay down, by finger count (core/touch.js
    /// acts only on press1: it fires as the first finger lands).
    var presses: [Int: ArcadePadState] = [:]

    init() {}

    init(json: [String: Any]?) {
        guard let json else { return }
        for (key, value) in json {
            if key.hasPrefix("press"), let n = Int(key.dropFirst(5)), let row = value as? [String: Any] {
                presses[n] = ArcadePadState(json: row)
            } else if key.hasPrefix("doubleTap"), let n = Int(key.dropFirst(9)) {
                if let action = ArcadePadAction(json: value) { doubleTaps[n] = action }
            } else if key.hasPrefix("tap"), let n = Int(key.dropFirst(3)) {
                if let action = ArcadePadAction(json: value) { taps[n] = action }
            } else if key.hasPrefix("hold"), let n = Int(key.dropFirst(4)) {
                if let action = ArcadePadAction(json: value) {
                    holds[n] = action
                    if let row = value as? [String: Any], let ms = arcadeJSONNumber(row["ms"]), ms >= 0 { holdTimes[n] = ms }
                }
            } else if key.hasPrefix("flick"), let n = Int(key.dropFirst(5)), let row = value as? [String: Any] {
                flicks[n] = ArcadeFlick(json: row)
            } else if key == "stick1" {
                stickRadius = arcadeJSONNumber((value as? [String: Any])?["radiusPx"]) ?? 0
            }
        }
    }

    /// `{...anywhere, ...zone}`: the zone's own gestures win, key by key (a
    /// zone's hold brings its own time, or none, with it).
    func overlaid(by zone: ArcadeGestureSet) -> ArcadeGestureSet {
        var merged = self
        merged.taps.merge(zone.taps) { _, mine in mine }
        merged.doubleTaps.merge(zone.doubleTaps) { _, mine in mine }
        for fingers in zone.holds.keys { merged.holdTimes[fingers] = zone.holdTimes[fingers] }
        merged.holds.merge(zone.holds) { _, mine in mine }
        merged.flicks.merge(zone.flicks) { _, mine in mine }
        if zone.stickRadius != nil { merged.stickRadius = zone.stickRadius }
        merged.presses.merge(zone.presses) { _, mine in mine }
        return merged
    }
}

/// Where a fight gesture is: the left or right half, or (Oct 19 2026) a zone
/// the table names in `fight.zones` ("a", "b", "l", "r" in the plain player).
struct ArcadeZone: Hashable {
    let rawValue: String

    init(_ name: String) { rawValue = name }

    static let left = ArcadeZone("left")
    static let right = ArcadeZone("right")
}

/// One of `fight.zones`: a rectangle in fractions of the pad, [from, to) on
/// each axis (core/touch.js zoneOf: the first that holds the finger wins).
struct ArcadeTouchZoneRect: Equatable {
    let name: String
    let x0: Double
    let x1: Double
    let y0: Double
    let y1: Double

    init(name: String, x0: Double = 0, x1: Double = 1, y0: Double = 0, y1: Double = 1) {
        self.name = name
        self.x0 = x0
        self.x1 = x1
        self.y0 = y0
        self.y1 = y1
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        func span(_ key: String) -> (Double, Double) {
            guard let pair = json[key] as? [Any], pair.count >= 2,
                  let from = arcadeJSONNumber(pair[0]), let to = arcadeJSONNumber(pair[1]) else { return (0, 1) }
            return (from, to)
        }
        let x = span("x")
        let y = span("y")
        self.init(name: name, x0: x.0, x1: x.1, y0: y.0, y1: y.1)
    }

    func holds(fx: Double, fy: Double) -> Bool { fx >= x0 && fx < x1 && fy >= y0 && fy < y1 }
}

/// profile.input.touch: the numbers and the menu and fight tables.
struct ArcadeTouchTable: Equatable {
    var flickPx = 20.0
    var tapMs = 250.0
    var tapSlopPx = 12.0
    var doubleMs = 300.0
    var pulseMs = 100.0
    var holdMs = 250.0
    var repeatAfterMs = 1000.0
    var repeatEveryMs = 250.0
    var stickRadiusPx = 60.0
    var menu = ArcadeGestureSet()
    var anywhere = ArcadeGestureSet()
    var left = ArcadeGestureSet()
    var right = ArcadeGestureSet()
    /// Oct 19 2026: `fight.zones`, checked in order before the two halves, and
    /// each named zone's own gestures (`fight.<name>`).
    var zones: [ArcadeTouchZoneRect] = []
    var named: [String: ArcadeGestureSet] = [:]

    init() {}

    init(json: [String: Any]?) {
        guard let json else { return }
        func number(_ key: String, _ fallback: Double) -> Double {
            guard let value = arcadeJSONNumber(json[key]), value >= 0 else { return fallback }
            return value
        }
        flickPx = number("flickPx", flickPx)
        tapMs = number("tapMs", tapMs)
        tapSlopPx = number("tapSlopPx", tapSlopPx)
        doubleMs = number("doubleMs", doubleMs)
        pulseMs = number("pulseMs", pulseMs)
        holdMs = number("holdMs", holdMs)
        repeatAfterMs = number("repeatAfterMs", repeatAfterMs)
        repeatEveryMs = max(50, number("repeatEveryMs", repeatEveryMs))
        stickRadiusPx = max(1, number("stickRadiusPx", stickRadiusPx))
        menu = ArcadeGestureSet(json: json["menu"] as? [String: Any])
        let fight = json["fight"] as? [String: Any]
        anywhere = ArcadeGestureSet(json: fight?["anywhere"] as? [String: Any])
        left = ArcadeGestureSet(json: fight?["left"] as? [String: Any])
        right = ArcadeGestureSet(json: fight?["right"] as? [String: Any])
        for row in (fight?["zones"] as? [Any]) ?? [] {
            guard let json = row as? [String: Any], let zone = ArcadeTouchZoneRect(json: json) else { continue }
            zones.append(zone)
            if zone.name != "left" && zone.name != "right" {
                named[zone.name] = ArcadeGestureSet(json: fight?[zone.name] as? [String: Any])
            }
        }
    }

    func gestures(mode: String, zone: ArcadeZone?) -> ArcadeGestureSet {
        guard mode == "fight" else { return menu }
        guard let zone else { return anywhere }
        if zone == .left { return anywhere.overlaid(by: left) }
        if zone == .right { return anywhere.overlaid(by: right) }
        return anywhere.overlaid(by: named[zone.rawValue] ?? ArcadeGestureSet())
    }

    /// The fight zone a finger landing at (x, y) belongs to: the first of
    /// `zones` that holds it, else the left or right half (core/touch.js zoneOf).
    func zone(x: Double, y: Double, width: Double, height: Double) -> ArcadeZone {
        if !zones.isEmpty, width > 0, height > 0 {
            let fx = x / width
            let fy = y / height
            if let found = zones.first(where: { $0.holds(fx: fx, fy: fy) }) { return ArcadeZone(found.name) }
        }
        return x < width / 2 ? .left : .right
    }

    /// The default fighting-game tables, as the Revival kit's first game
    /// profile had them on Oct 18 2026, plus the plan's two repeat holds
    /// (menus: touch and hold one second; fights: a still two-finger hold on
    /// the left), which the kit's profile does not have yet. Used only when a
    /// game's pack has no input.touch of its own.
    static let standardJSON = """
    {"flickPx":20,"tapMs":250,"tapSlopPx":12,"doubleMs":300,"pulseMs":100,"holdMs":250,
     "repeatAfterMs":1000,"repeatEveryMs":250,"stickRadiusPx":60,
     "menu":{"flick1":{"up":{"pulse":{"sy":-1}},"down":{"pulse":{"sy":1}},"left":{"pulse":{"sx":-1}},"right":{"pulse":{"sx":1}},"repeat":true},
             "doubleTap1":{"pulse":{"buttons":["A"]}},"tap2":{"pulse":{"buttons":["B"]}},"doubleTap2":{"pulse":{"buttons":["START"]}},
             "flick3":{"up":{"pulse":{"buttons":["CU"]}},"down":{"pulse":{"buttons":["CD"]}},"left":{"pulse":{"buttons":["CL"]}},"right":{"pulse":{"buttons":["CR"]}}},
             "tap3":{"pulse":{"buttons":["START"]}},"hold1":{"info":"repeat","ms":1000}},
     "fight":{"anywhere":{"tap3":{"pulse":{"buttons":["START"]}}},
              "left":{"stick1":{"radiusPx":60},"tap1":{"pulse":{"buttons":["A"]}},
                      "flick2":{"up":{"info":"health"},"down":{"info":"where"},"left":{"info":"facing"},"right":{"info":"time"}},
                      "hold2":{"info":"repeat","ms":1000}},
              "right":{"flick1":{"left":{"pulse":{"buttons":["CL"]}},"up":{"pulse":{"buttons":["CU"]}},"down":{"pulse":{"buttons":["CD"]}},"right":{"pulse":{"buttons":["CR"]}}},
                       "tap1":{"pulse":{"buttons":["R"]}},"hold1":{"hold":{"buttons":["block"]}},
                       "tap2":{"pulse":{"buttons":["B"]}},"hold2":{"hold":{"buttons":["Z"]}}}}}
    """

    static let standard = ArcadeTouchTable(json: (try? JSONSerialization.jsonObject(with: Data(standardJSON.utf8))) as? [String: Any])
}

// MARK: - The touch recognizer (a port of core/touch.js)

enum ArcadeHapticCue: Equatable {
    /// The floating stick entered a new one of its eight directions.
    case direction
    /// The stick reached full push.
    case fullPush
    /// A held gesture (block, crouch) took hold.
    case hold
}

enum ArcadeTouchOutput: Equatable {
    /// revivalKit.pad(state, source); nil lets that source go.
    case pad(source: String, state: ArcadePadState?)
    case info(String)
    case haptic(ArcadeHapticCue)
}

/// The kit's core/touch.js recognizer, step for step in menus, with the
/// clock passed in (milliseconds) so it can be tested without a screen:
/// call start/move/end for each finger and advance(to:) from a display link
/// while `nextDue` is set. The mode is read when the first finger lands and
/// holds until the last one lifts.
///
/// Fights split the pad into two halves that work side by side (the plan's
/// "stick under your left thumb, attack flicks under your right"): each half
/// has its own gesture, with its own fingers, flicks, taps, holds, stick and
/// timers, so the left thumb can walk while the right one attacks or blocks.
/// A finger belongs to the half it landed in. The 'anywhere' gestures still
/// work across the halves for taps: when fingers on both halves together make
/// a tap the 'anywhere' table has (the default table: three fingers, pause), all of them
/// landed and lifted within tapMs and none moved, that tap is what happens,
/// and a half's own tap waits (at most tapMs from the first finger) until that
/// is settled. In one half, 'anywhere' gestures apply as before.
///
/// Native additions: haptic cues for the stick's eight directions (with a
/// little give at each edge, so a resting thumb does not buzz) and full
/// push, and one when a hold takes effect; and a hold may carry its own time.
struct ArcadeTouchRecognizer {
    var table: ArcadeTouchTable
    /// 'fight' uses the fight tables; anything else ('menu', 'pause') the menu table.
    var mode = "menu"

    private struct Finger {
        var x0: Double
        var y0: Double
        var x: Double
        var y: Double
        var ended = false

        var distance: Double { ((x - x0) * (x - x0) + (y - y0) * (y - y0)).squareRoot() }
    }

    /// One gesture: in menus every finger on the pad; in fights the fingers of one half.
    private struct Gesture {
        let serial: Int
        let t0: Double
        let mode: String
        let zone: ArcadeZone?
        var touches: [Int: Finger] = [:]
        var fingers = 0
        var fired = false
        var stick = false
        var holding = false
        /// A press (pressN) is held while this gesture's fingers stay down.
        var pressing = false
        /// The pad source a held action presses (nil for an info hold).
        var heldSource: String?
        var sector: Int?
        var fullPush = false

        /// Each half has its own stick and hold sources, so letting go of one never lets go of the other.
        var stickSource: String { zone.map { "touch-stick-" + $0.rawValue } ?? "touch-stick" }
        var holdSource: String { zone.map { "touch-hold-" + $0.rawValue } ?? "touch-hold" }
        var pressSource: String { zone.map { "touch-press-" + $0.rawValue } ?? "touch-press-all" }
    }

    /// Every finger from the first one down to the last one up, across both halves.
    private struct Family {
        let serial: Int
        let t0: Double
        let fight: Bool
        /// Every finger that touched, as a gesture counts them.
        var fingers = 0
        var zones: Set<ArcadeZone> = []
        /// Something fired, a finger moved or time ran out: no 'anywhere' tap across the halves.
        var spoiled = false
        /// A half's taps held back while the fingers might still be one 'anywhere' tap.
        var deferred: [Gesture] = []
    }

    private struct Pending {
        let serial: Int
        let fingers: Int
        let mode: String
        let zone: ArcadeZone?
        let at: Double
        let single: ArcadePadAction?
    }

    private enum Job: Equatable {
        case hold(Int)
        case repeatFlick(Int, ArcadePadAction)
        case release(String)
        case single(Int)
        case flush(Int)
    }

    private struct Scheduled {
        let due: Double
        let job: Job
    }

    /// In progress, by name: "all" in menus, "left" and "right" in fights.
    private var gestures: [String: Gesture] = [:]
    /// Which gesture each finger down belongs to.
    private var owners: [Int: String] = [:]
    private var family: Family?
    private var pending: Pending?
    private var jobs: [Scheduled] = []
    private var serial = 0
    private var pulses = 0

    init(table: ArcadeTouchTable = .standard) { self.table = table }

    /// When advance(to:) next has work, or nil when the pad is at rest.
    var nextDue: Double? { jobs.map { $0.due }.min() }
    var isIdle: Bool { gestures.isEmpty && family == nil && jobs.isEmpty }
    var fingersDown: Int { owners.count }

    // MARK: Fingers

    /// `height` places the finger in the table's named fight zones (0: the two halves only).
    mutating func start(id: Int, x: Double, y: Double, width: Double, height: Double = 0, now: Double) -> [ArcadeTouchOutput] {
        var group: Family
        if let existing = family {
            group = existing
        } else {
            serial += 1
            group = Family(serial: serial, t0: now, fight: mode == "fight")
        }
        let zone: ArcadeZone? = group.fight ? table.zone(x: x, y: y, width: width, height: height) : nil
        let name = zone?.rawValue ?? "all"
        var current: Gesture
        if let existing = gestures[name] {
            current = existing
        } else {
            serial += 1
            current = Gesture(serial: serial, t0: now, mode: group.fight ? "fight" : "menu", zone: zone)
        }
        current.touches[id] = Finger(x0: x, y0: y, x: x, y: y)
        current.fingers = max(current.fingers, current.touches.count)
        var out: [ArcadeTouchOutput] = []
        // A press is held from the moment the first finger lands (core/touch.js: press1 only).
        if current.touches.count == 1, let press = table.gestures(mode: current.mode, zone: current.zone).presses[1] {
            current.pressing = true
            current.fired = true
            out.append(.pad(source: current.pressSource, state: press))
        }
        gestures[name] = current
        owners[id] = name
        group.fingers += 1
        if let zone { group.zones.insert(zone) }
        family = group
        scheduleHold(for: current, now: now)
        return out
    }

    mutating func move(id: Int, x: Double, y: Double, now: Double) -> [ArcadeTouchOutput] {
        guard let name = owners[id], var current = gestures[name], current.touches[id] != nil else { return [] }
        current.touches[id]?.x = x
        current.touches[id]?.y = y
        var out: [ArcadeTouchOutput] = []
        let wandered = (current.touches[id]?.distance ?? 0) > table.tapSlopPx
        if current.holding || current.pressing {
            gestures[name] = current
            if wandered { spoil(now: now, into: &out) }
            return out
        }
        let set = table.gestures(mode: current.mode, zone: current.zone)
        let n = current.fingers
        let travel = Self.travel(current)
        if n == 1, let radius = set.stickRadius, current.stick || travel.distance > table.tapSlopPx {
            current.stick = true
            current.fired = true
            let r = radius > 0 ? radius : table.stickRadiusPx
            var sx = travel.dx / r
            var sy = travel.dy / r
            let length = (sx * sx + sy * sy).squareRoot()
            if length > 1 { sx /= length; sy /= length }
            out.append(.pad(source: current.stickSource, state: ArcadePadState(sx: Self.quantize(sx), sy: Self.quantize(sy))))
            // A direction is entered at 0.3 of full push and left below 0.25,
            // and a neighbour takes over only past the edge's give.
            if let held = current.sector {
                if length < 0.25 {
                    current.sector = nil
                } else {
                    let next = Self.nextSector(current: held, dx: sx, dy: sy)
                    if next != held {
                        current.sector = next
                        out.append(.haptic(.direction))
                    }
                }
            } else if length >= 0.3 {
                current.sector = Self.sector(dx: sx, dy: sy)
                out.append(.haptic(.direction))
            }
            if length >= 1 {
                if !current.fullPush {
                    current.fullPush = true
                    out.append(.haptic(.fullPush))
                }
            } else if length < 0.9 {
                current.fullPush = false
            }
            gestures[name] = current
            spoil(now: now, into: &out)
            return out
        }
        if !current.fired, let flick = set.flicks[n], travel.distance >= table.flickPx {
            let direction = ArcadeDirection.of(dx: travel.dx, dy: travel.dy)
            current.fired = true
            if let action = flick.actions[direction] {
                act(action, now: now, holdSource: current.holdSource, into: &out)
                if flick.repeats { schedule(now + table.repeatAfterMs, .repeatFlick(current.serial, action)) }
            }
        }
        gestures[name] = current
        if current.fired || wandered { spoil(now: now, into: &out) }
        return out
    }

    mutating func end(id: Int, now: Double) -> [ArcadeTouchOutput] {
        guard let name = owners[id], var current = gestures[name], current.touches[id] != nil else { return [] }
        owners[id] = nil
        current.touches[id]?.ended = true
        var out: [ArcadeTouchOutput] = []
        if current.touches.values.contains(where: { !$0.ended }) {   // wait for every finger of this gesture
            gestures[name] = current
            return out
        }
        gestures[name] = nil
        let owner = current.serial
        jobs.removeAll {
            switch $0.job {
            case .hold(let serial), .repeatFlick(let serial, _): return serial == owner
            case .release, .single, .flush: return false
            }
        }
        if current.stick { out.append(.pad(source: current.stickSource, state: nil)) }
        if let held = current.heldSource { out.append(.pad(source: held, state: nil)) }
        if current.pressing { out.append(.pad(source: current.pressSource, state: nil)) }
        let far = current.touches.values.map { $0.distance }.max() ?? 0
        let still = now - current.t0 <= table.tapMs && far <= table.tapSlopPx
        let isTap = !current.fired && still
        // A quick still press still counts toward a tap across the zones (three
        // fingers, Start): it only held its own button while it was down.
        let partOfTap = (!current.fired || current.pressing) && still
        guard var group = family else {
            if isTap { tap(current, now: now, into: &out) }
            return out
        }
        if !owners.isEmpty {
            // Fingers are still down on the other half.
            if isTap {
                let fingersSoFar = group.fingers
                let couldBeAnywhere = group.fight && !group.spoiled && now - group.t0 <= table.tapMs
                    && table.anywhere.taps.keys.contains { $0 >= 2 && $0 >= fingersSoFar }
                if couldBeAnywhere {
                    group.deferred.append(current)
                    family = group
                    if !jobs.contains(where: { $0.job == .flush(group.serial) }) {
                        schedule(group.t0 + table.tapMs, .flush(group.serial))
                    }
                } else {
                    tap(current, now: now, into: &out)
                }
            }
            return out
        }
        // The last finger is up.
        family = nil
        jobs.removeAll { $0.job == .flush(group.serial) }
        if group.fight, group.zones.count >= 2, !group.spoiled, partOfTap, now - group.t0 <= table.tapMs,
           let anywhere = table.anywhere.taps[group.fingers] {
            act(anywhere, now: now, holdSource: current.holdSource, into: &out)
            return out
        }
        for waiting in group.deferred { tap(waiting, now: now, into: &out) }
        if isTap { tap(current, now: now, into: &out) }
        return out
    }

    /// Runs whatever came due: holds, flick repeats, pulse releases, single taps, held-back taps.
    mutating func advance(to now: Double) -> [ArcadeTouchOutput] {
        var out: [ArcadeTouchOutput] = []
        while let index = jobs.indices.filter({ jobs[$0].due <= now }).min(by: { jobs[$0].due < jobs[$1].due }) {
            let item = jobs.remove(at: index)
            switch item.job {
            case .hold(let owner):
                checkHold(owner, now: now, into: &out)
            case .repeatFlick(let owner, let action):
                if let current = gestures.values.first(where: { $0.serial == owner }) {
                    act(action, now: now, holdSource: current.holdSource, into: &out)
                    schedule(now + table.repeatEveryMs, .repeatFlick(owner, action))
                }
            case .release(let source):
                out.append(.pad(source: source, state: nil))
            case .single(let owner):
                if let waiting = pending, waiting.serial == owner {
                    pending = nil
                    if let single = waiting.single { act(single, now: now, holdSource: "touch-hold", into: &out) }
                }
            case .flush(let owner):
                // Too late now for a tap across the halves: the held-back taps go out.
                if let group = family, group.serial == owner { spoil(now: now, into: &out) }
            }
        }
        return out
    }

    /// Lets go of everything at once (the game paused, the pad lost focus, Leave).
    mutating func releaseAll() -> [ArcadeTouchOutput] {
        var out: [ArcadeTouchOutput] = []
        for name in gestures.keys.sorted() {
            guard let current = gestures[name] else { continue }
            if current.stick { out.append(.pad(source: current.stickSource, state: nil)) }
            if let held = current.heldSource { out.append(.pad(source: held, state: nil)) }
            if current.pressing { out.append(.pad(source: current.pressSource, state: nil)) }
        }
        for item in jobs {
            if case .release(let source) = item.job { out.append(.pad(source: source, state: nil)) }
        }
        jobs.removeAll()
        pending = nil
        gestures.removeAll()
        owners.removeAll()
        family = nil
        return out
    }

    // MARK: Inside

    private mutating func schedule(_ due: Double, _ job: Job) {
        jobs.append(Scheduled(due: due, job: job))
    }

    /// The hold clock restarts whenever a finger joins the gesture, at that
    /// hold's own time (or the table's holdMs).
    private mutating func scheduleHold(for current: Gesture, now: Double) {
        let owner = current.serial
        jobs.removeAll { $0.job == .hold(owner) }
        let set = table.gestures(mode: current.mode, zone: current.zone)
        guard set.holds[current.fingers] != nil else { return }
        schedule(now + (set.holdTimes[current.fingers] ?? table.holdMs), .hold(owner))
    }

    private mutating func act(_ action: ArcadePadAction, now: Double, holdSource: String, into out: inout [ArcadeTouchOutput]) {
        switch action {
        case .pulse(let state):
            pulses += 1
            let source = "touch-p\(pulses)"
            out.append(.pad(source: source, state: state))
            schedule(now + table.pulseMs, .release(source))
        case .hold(let state):
            out.append(.pad(source: holdSource, state: state))
        case .info(let what):
            out.append(.info(what))
        }
    }

    /// No 'anywhere' tap across the halves any more: any held-back taps go out now.
    private mutating func spoil(now: Double, into out: inout [ArcadeTouchOutput]) {
        guard var group = family, !(group.spoiled && group.deferred.isEmpty) else { return }
        let waiting = group.deferred
        group.spoiled = true
        group.deferred = []
        family = group
        jobs.removeAll { $0.job == .flush(group.serial) }
        for held in waiting { tap(held, now: now, into: &out) }
    }

    private mutating func checkHold(_ owner: Int, now: Double, into out: inout [ArcadeTouchOutput]) {
        guard let name = gestures.first(where: { $0.value.serial == owner })?.key, var current = gestures[name],
              !current.fired, !current.stick else { return }
        let set = table.gestures(mode: current.mode, zone: current.zone)
        guard let hold = set.holds[current.fingers], Self.travel(current).distance <= table.tapSlopPx else { return }
        current.holding = true
        current.fired = true
        if case .hold = hold { current.heldSource = current.holdSource }
        gestures[name] = current
        act(hold, now: now, holdSource: current.holdSource, into: &out)
        out.append(.haptic(.hold))
        spoil(now: now, into: &out)
    }

    private mutating func tap(_ current: Gesture, now: Double, into out: inout [ArcadeTouchOutput]) {
        let set = table.gestures(mode: current.mode, zone: current.zone)
        let n = current.fingers
        let single = set.taps[n]
        guard let twice = set.doubleTaps[n] else {
            if let single { act(single, now: now, holdSource: current.holdSource, into: &out) }
            return
        }
        if let waiting = pending, waiting.fingers == n, waiting.mode == current.mode, waiting.zone == current.zone,
           now - waiting.at <= table.doubleMs {
            dropPending()
            act(twice, now: now, holdSource: current.holdSource, into: &out)
            return
        }
        // A different tap was waiting: core/touch.js drops it without acting.
        if pending != nil { dropPending() }
        serial += 1
        pending = Pending(serial: serial, fingers: n, mode: current.mode, zone: current.zone, at: now, single: single)
        schedule(now + table.doubleMs, .single(serial))
    }

    private mutating func dropPending() {
        if let waiting = pending {
            jobs.removeAll { $0.job == .single(waiting.serial) }
        }
        pending = nil
    }

    private static func travel(_ g: Gesture) -> (dx: Double, dy: Double, distance: Double) {
        guard !g.touches.isEmpty else { return (0, 0, 0) }
        var dx = 0.0
        var dy = 0.0
        for finger in g.touches.values {
            dx += finger.x - finger.x0
            dy += finger.y - finger.y0
        }
        let count = Double(g.touches.count)
        dx /= count
        dy /= count
        return (dx, dy, (dx * dx + dy * dy).squareRoot())
    }

    /// 0...7, counter-clockwise from right, in screen space (+y down).
    static func sector(dx: Double, dy: Double) -> Int {
        let angle = atan2(-dy, dx)
        let step = Double.pi / 4
        var index = Int(((angle + step / 2) / step).rounded(.down))
        index %= 8
        if index < 0 { index += 8 }
        return index
    }

    /// The stick's direction with some give: from `current`, a neighbour takes
    /// over only once the thumb is more than 8 degrees past their shared edge
    /// (30.5 degrees from the current direction's centre), so a thumb resting
    /// on an edge does not tick back and forth.
    static func nextSector(current: Int, dx: Double, dy: Double) -> Int {
        let raw = sector(dx: dx, dy: dy)
        guard raw != current else { return current }
        let angle = atan2(-dy, dx)
        let centre = Double(current) * Double.pi / 4
        var gap = abs(angle - centre).truncatingRemainder(dividingBy: 2 * Double.pi)
        if gap > Double.pi { gap = 2 * Double.pi - gap }
        return gap <= (22.5 + 8) * Double.pi / 180 ? current : raw
    }

    /// Steps of 0.02, so a slow slide does not send a new pad on every point.
    static func quantize(_ value: Double) -> Double {
        let stepped = (value * 50).rounded() / 50
        return stepped == 0 ? 0 : stepped
    }
}

// MARK: - Controllers (a port of core/input.js pollGamepad)

struct ArcadeButtonBinding: Equatable {
    let index: Int
    let name: String
}

/// profile.input.gamepad, in standard-gamepad button numbers:
/// 0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 LT, 7 RT, 8 Back, 9 Start/Menu,
/// 10 L3, 11 R3, 12 up, 13 down, 14 left, 15 right, 16 Home.
struct ArcadeGamepadMap: Equatable {
    var fight: [ArcadeButtonBinding] = []
    var menu: [ArcadeButtonBinding] = []
    var always: [ArcadeButtonBinding] = []
    var dpadMovesInMenus = false
    var rightStick: [ArcadeDirection: String] = [:]
    var info: [Int: String] = [:]
    var infoOutsideFights: Set<Int> = []

    init() {}

    init(json: [String: Any]?) {
        guard let json else { return }
        func bindings(_ key: String) -> [ArcadeButtonBinding] {
            guard let rows = json[key] as? [Any] else { return [] }
            var out: [ArcadeButtonBinding] = []
            for row in rows {
                guard let pair = row as? [Any], pair.count >= 2, let index = arcadeJSONNumber(pair[0]),
                      let name = pair[1] as? String else { continue }
                out.append(ArcadeButtonBinding(index: Int(index), name: name))
            }
            return out
        }
        fight = bindings("fight")
        menu = bindings("menu")
        always = bindings("always")
        dpadMovesInMenus = (json["dpadMovesInMenus"] as? Bool) ?? false
        if let stick = json["rightStick"] as? [String: Any] {
            for direction in ArcadeDirection.allCases {
                if let name = stick[direction.rawValue] as? String { rightStick[direction] = name }
            }
        }
        if let keys = json["info"] as? [String: Any] {
            for (key, value) in keys {
                if let index = Int(key), let what = value as? String { info[index] = what }
            }
        }
        if let outside = json["infoOutsideFights"] as? [Any] {
            infoOutsideFights = Set(outside.compactMap { arcadeJSONNumber($0).map { Int($0) } })
        }
    }

    /// The default fighting-game map, as the Revival kit's first game profile
    /// had it on Oct 18 2026: the left stick moves; X, Y, A and B are the four
    /// attacks; RB jumps, LB changes target, RT blocks, LT crouches; Start
    /// pauses; the d-pad gives information in fights and moves in menus.
    static let standardJSON = """
    {"fight":[[2,"CL"],[3,"CU"],[0,"CD"],[1,"CR"],[5,"R"],[4,"A"],[7,"block"],[6,"Z"],[8,"B"]],
     "menu":[[0,"A"],[1,"B"],[2,"CL"],[3,"CU"]],
     "always":[[9,"START"]],
     "dpadMovesInMenus":true,
     "rightStick":{"right":"CR","left":"CL","down":"CD","up":"CU"},
     "info":{"10":"repeat","12":"where","13":"health","14":"facing","15":"time"},
     "infoOutsideFights":[10]}
    """

    static let standard = ArcadeGamepadMap(json: (try? JSONSerialization.jsonObject(with: Data(standardJSON.utf8))) as? [String: Any])
}

/// One reading of a controller in the standard layout. Axes: left x, left y,
/// right x, right y, with +y DOWN (the browser's way, not GameController's).
struct ArcadeGamepadSnapshot: Equatable {
    var pressed: [Bool] = Array(repeating: false, count: 17)
    var axes: [Double] = [0, 0, 0, 0]

    func isPressed(_ index: Int) -> Bool { index >= 0 && index < pressed.count && pressed[index] }
    func axis(_ index: Int) -> Double { index >= 0 && index < axes.count ? axes[index] : 0 }
}

struct ArcadeGamepadMapper {
    var map: ArcadeGamepadMap
    private var infoHeld: [Int: Bool] = [:]

    init(map: ArcadeGamepadMap = .standard) { self.map = map }

    /// The pad state for source 'controller', and the info keys pressed just now.
    mutating func apply(_ snapshot: ArcadeGamepadSnapshot, mode: String) -> (state: ArcadePadState, info: [String]) {
        let fight = mode == "fight"
        var buttons: [String] = []
        let bindings: [ArcadeButtonBinding] = fight ? map.fight : map.menu
        for binding in bindings where snapshot.isPressed(binding.index) { buttons.append(binding.name) }
        for binding in map.always where snapshot.isPressed(binding.index) { buttons.append(binding.name) }
        func deadZone(_ value: Double) -> Double { abs(value) < 0.2 ? 0 : value }
        var sx = deadZone(snapshot.axis(0))
        var sy = deadZone(snapshot.axis(1))
        if !fight && map.dpadMovesInMenus {
            if snapshot.isPressed(14) { sx -= 1 }
            if snapshot.isPressed(15) { sx += 1 }
            if snapshot.isPressed(12) { sy -= 1 }
            if snapshot.isPressed(13) { sy += 1 }
        }
        if !map.rightStick.isEmpty {
            let rx = deadZone(snapshot.axis(2))
            let ry = deadZone(snapshot.axis(3))
            if rx > 0.5, let name = map.rightStick[.right] { buttons.append(name) }
            if rx < -0.5, let name = map.rightStick[.left] { buttons.append(name) }
            if ry > 0.5, let name = map.rightStick[.down] { buttons.append(name) }
            if ry < -0.5, let name = map.rightStick[.up] { buttons.append(name) }
        }
        var info: [String] = []
        for index in map.info.keys.sorted() {
            guard let what = map.info[index] else { continue }
            let down = snapshot.isPressed(index)
            if down && !(infoHeld[index] ?? false) && (fight || map.infoOutsideFights.contains(index)) { info.append(what) }
            infoHeld[index] = down
        }
        let state = ArcadePadState(sx: ArcadeTouchRecognizer.quantize(sx), sy: ArcadeTouchRecognizer.quantize(sy), buttons: buttons)
        return (state, info)
    }
}

// MARK: - Keyboards

enum ArcadeKeys {
    /// Escape never reaches the game: it asks "Leave game?".
    static let escapeUsage = 0x29

    /// A hardware key (its HID usage, as GCKeyCode carries it) as the browser
    /// names it, the names the kit's profile keys use. Nil for keys the game
    /// has no use for; modifiers are left to VoiceOver.
    static func browserKey(hidUsage: Int) -> String? {
        switch hidUsage {
        case 0x04...0x1D:
            guard let scalar = Unicode.Scalar(UInt32(0x61 + hidUsage - 0x04)) else { return nil }
            return String(Character(scalar))
        case 0x1E...0x26:
            return String(hidUsage - 0x1E + 1)
        case 0x27: return "0"
        case 0x28, 0x58: return "Enter"
        case 0x2A: return "Backspace"
        case 0x2C: return " "
        case 0x3A: return "F1"
        case 0x4F: return "ArrowRight"
        case 0x50: return "ArrowLeft"
        case 0x51: return "ArrowDown"
        case 0x52: return "ArrowUp"
        default: return nil
        }
    }

    /// Control, Option or Command held: the press belongs to VoiceOver or iOS.
    static func isBlockingModifier(hidUsage: Int) -> Bool {
        [0xE0, 0xE2, 0xE3, 0xE4, 0xE6, 0xE7].contains(hidUsage)
    }
}

// MARK: - What the app says to the page

enum ArcadeJS {
    /// A JavaScript string literal.
    static func literal(_ text: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
           let array = String(data: data, encoding: .utf8), array.count >= 2 {
            return String(array.dropFirst().dropLast())
        }
        return "\"\""
    }

    /// Up to three decimals, never "-0" or an exponent.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 1000).rounded() / 1000
        if rounded == 0 { return "0" }
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func padObject(_ state: ArcadePadState) -> String {
        var parts = ["\"sx\":" + number(state.sx), "\"sy\":" + number(state.sy)]
        parts.append("\"buttons\":[" + state.buttons.map(literal).joined(separator: ",") + "]")
        if !state.info.isEmpty { parts.append("\"info\":[" + state.info.map(literal).joined(separator: ",") + "]") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// revivalKit.pad(state, source), or pad(null, source) to let the source go.
    static func pad(source: String, state: ArcadePadState?) -> String {
        let argument = state.map(padObject) ?? "null"
        return "window.revivalKit&&window.revivalKit.pad(\(argument),\(literal(source)));void 0"
    }

    static func info(_ what: String) -> String {
        "window.revivalKit&&window.revivalKit.info(\(literal(what)));void 0"
    }

    static func press(key: String, down: Bool) -> String {
        "window.revivalKit&&window.revivalKit.press(\(literal(key)),\(down ? "true" : "false"));void 0"
    }

    static func setMode(_ speechMode: String) -> String {
        "window.revivalKit&&window.revivalKit.setMode(\(literal(speechMode)));void 0"
    }

    static let suspend = "window.revivalKit&&window.revivalKit.suspend();void 0"
    static let resume = "window.revivalKit&&window.revivalKit.resume();void 0"
    /// Take the game's save now if it is paused or in its menus (it comes back as the 'saved' event).
    static let saveNow = "window.revivalKit&&window.revivalKit.saveNow&&window.revivalKit.saveNow();void 0"
    /// The same, for leaving: the save itself (base64) is the result, or null
    /// when there is none to take (mid-fight, or the game not started).
    static let saveNowForLeaving = """
    (function () { var k = window.revivalKit; if (!k || !k.saveNow) { return null; } \
    var r = k.saveNow(); return (r && r.state === 'saved' && typeof r.data === 'string') ? r.data : null; })()
    """

    /// The page's 'error' events that mean the game never started (the
    /// emulator's script, its start, or a system the plain player does not
    /// have): the app says so, as nothing else will.
    static func cannotStart(_ what: String) -> Bool {
        what == "emulator" || what == "start" || what == "system"
    }

    /// 'touch', 'gamepad' or 'keyboard': which words the page uses for buttons.
    static func setInputType(_ type: String) -> String {
        "window.revivalKit&&window.revivalKit.setInputType&&window.revivalKit.setInputType(\(literal(type)));void 0"
    }

    /// The document-start script: window.revivalKitHost exactly as the kit's
    /// core/host.js reads it. Every line with no cloned clip comes back
    /// through the 'native' speech route; every kit event comes back too
    /// ('say' without its text, to keep the bridge quiet). Message handler: 'arcade'.
    /// `touch: false`: the app recognizes gestures itself and sends pads.
    /// `layout: 'full'`: the game area covers the whole view (body.kit-full),
    /// not a 4:3 box under the page's heading and keys list.
    /// `inputType` names the buttons for the input at hand from the first
    /// line on; `saveData` is the save the app kept (base64), put in place at boot.
    /// `romPath` (a game added from Files, played with its accessibility
    /// pack): the URL the app serves her own ROM at, which the kit takes over
    /// the profile's ROM path. The plain player gets none (its rom= is in the URL).
    static func hostScript(base: String, emulatorData: String, settings: [String: String],
                           inputType: String? = nil, saveData: String? = nil, romPath: String? = nil) -> String {
        var settingParts: [String] = []
        for key in settings.keys.sorted() {
            if let value = settings[key] { settingParts.append(literal(key) + ":" + literal(value)) }
        }
        let settingsObject = "{" + settingParts.joined(separator: ",") + "}"
        var optional = ""
        if let inputType, !inputType.isEmpty { optional += "\n    inputType: \(literal(inputType)),"}
        if let saveData, !saveData.isEmpty { optional += "\n    saveData: \(literal(saveData)),"}
        if let romPath, !romPath.isEmpty { optional += "\n    romPath: \(literal(romPath)),"}
        return """
        (function () {
          if (window.revivalKitHost) { return; }
          var post = function (m) { try { window.webkit.messageHandlers.arcade.postMessage(m); } catch (e) {} };
          var plain = function (v) { try { return v === undefined ? null : JSON.parse(JSON.stringify(v)); } catch (e) { return null; } };
          window.revivalKitHost = {
            base: \(literal(base)),
            emulatorData: \(literal(emulatorData)),
            autoStart: true,
            storage: false,
            touch: false,
            layout: 'full',\(optional)
            settings: \(settingsObject),
            speechFallback: 'native',
            speechRoutes: {
              native: function (text, o) {
                post({ t: 'say', text: String(text == null ? '' : text), urgent: !!(o && o.urgent), flush: !!(o && o.flush === true) });
              }
            },
            onEvent: function (name, detail) {
              post({ t: 'event', name: String(name), detail: name === 'say' ? null : plain(detail) });
            }
          };
          window.addEventListener('error', function (e) {
            post({ t: 'pageError', message: String((e && e.message) || 'error'), where: String((e && e.filename) || '') + ':' + String((e && e.lineno) || 0) });
          });
          window.addEventListener('unhandledrejection', function (e) {
            var r = e && e.reason;
            post({ t: 'pageError', message: String((r && r.message) || r || 'unhandled rejection'), where: 'promise' });
          });
        })();
        """
    }
}

// MARK: - A start that never finishes

/// Oct 19 2026: build 340 sat at "Starting the emulator" for good. Under
/// kadearcade:// EmulatorJS asked for a core file the packs lack, took the
/// 404's text for the core, and stopped inside its own hidden page; the page
/// only sent window errors, no kit 'error' event came, and nothing was said.
/// So the app watches every start itself, whatever the kit does:
///   - a countdown from the page load, started over at the kit's 'started',
///     that says the game did not start when 'ready' has not come in time.
///     Away (another app, a call, an interruption) it stops, and it starts
///     over on her return;
///   - a page error or a missing EmulatorJS file before 'ready' that means it
///     can never start is said at once, like the kit's own 'error' {what: 'emulator'}.
/// One start failure is said per page load, however many signs there are.
struct ArcadeStartWatch {
    /// How long a start may take before the app says it did not start.
    static let limit: TimeInterval = 90
    static let status = "The game did not start"
    static let line = "The game did not start. Open Settings and choose Report a problem with this game, or leave and try again."
    /// The line for the kit's 'error' about a game that never started
    /// (ArcadeJS.cannotStart), and for the same failure seen by the app.
    static let couldNotStartLine = "The game could not start. Open Settings and choose Report a problem with this game."

    /// When the countdown runs out; nil while it is not running.
    private(set) var deadline: Date?
    /// 'ready' came for this page load.
    private(set) var ready = false
    /// A start failure was said for this page load.
    private(set) var said = false
    /// She is away: no countdown runs until she is back.
    private(set) var isAway = false

    /// Still starting, and nothing said about it yet.
    var starting: Bool { !ready && !said }

    /// A page load (the first, or a restart): everything starts over.
    mutating func load(now: Date) {
        ready = false
        said = false
        deadline = isAway ? nil : now.addingTimeInterval(Self.limit)
    }

    /// The kit's 'started': the countdown starts over from here.
    mutating func started(now: Date) {
        guard starting, !isAway else { return }
        deadline = now.addingTimeInterval(Self.limit)
    }

    mutating func becameReady() {
        ready = true
        deadline = nil
    }

    mutating func away() {
        isAway = true
        deadline = nil
    }

    /// Back in front: a fresh countdown when the game is still starting.
    mutating func back(now: Date) {
        isAway = false
        deadline = starting ? now.addingTimeInterval(Self.limit) : nil
    }

    /// Whether the countdown has run out.
    func due(now: Date) -> Bool {
        guard starting, !isAway, let deadline else { return false }
        return now >= deadline
    }

    /// Takes this load's one start failure: true the first time, and the
    /// countdown stops. Also taken when the page could not load or was
    /// stopped for good, as those say their own lines.
    mutating func claim() -> Bool {
        guard !said else { return false }
        said = true
        deadline = nil
        return true
    }

    /// The kit's 'error' kinds that end a start with the kit's own spoken line
    /// and no 'ready' after it: 'ram', its RAM finder gave up (it says the
    /// profile's page.noRam first). The app takes the load's one line then,
    /// so the countdown does not say a second, different failure a minute later.
    static func kitEndedStart(_ what: String) -> Bool {
        what == "ram"
    }

    /// A page error before 'ready' that means EmulatorJS will never start: its
    /// runtime is missing (the core it loaded was not a core), or a file or the
    /// network failed it. Matched without regard to case.
    static func isStartError(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["ejs_runtime", "error loading", "failed to download", "network error", "could not"]
            .contains { text.contains($0) }
    }

    /// A file missing from the packs whose absence stops EmulatorJS: a script
    /// or a core in its folder (the kit's `emulatorData`, `emulatorjs/` by
    /// default). Not a translation (a phone in another language asks for its
    /// own and EmulatorJS goes on in English), a core's report (EmulatorJS
    /// goes on without it, and a core it then lacks is caught on its own), a
    /// stylesheet or a source map: the game can start without those.
    static func isMissingEmulatorFile(_ path: String, emulatorData: String) -> Bool {
        let folders = [emulatorData, "emulatorjs/"]
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            .filter { $0.count > 1 }
        guard let folder = folders.first(where: { path.hasPrefix($0) }) else { return false }
        let inside = String(path.dropFirst(folder.count)).lowercased()
        if inside.hasPrefix("localization/") || inside.hasPrefix("cores/reports/") { return false }
        return inside.hasSuffix(".js") || (inside.hasPrefix("cores/") && !inside.hasSuffix("/"))
    }
}

// MARK: - Words

enum ArcadeText {
    /// "45 MB", decimal megabytes like iOS Settings.
    static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "size not known yet" }
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 1 { return "under 1 MB" }
        if megabytes < 10 { return String(format: "%.1f MB", megabytes) }
        return "\(Int(megabytes.rounded())) MB"
    }
}

/// Download progress is spoken at 25, 50 and 75 percent; the end has its own line.
struct ArcadeProgressSpeaker {
    private(set) var lastSpoken = 0
    let step = 25

    mutating func next(fraction: Double) -> Int? {
        let clamped = max(0, min(1, fraction.isFinite ? fraction : 0))
        let percent = Int(clamped * 100)
        let bucket = percent / step * step
        guard bucket > lastSpoken, bucket < 100 else { return nil }
        lastSpoken = bucket
        return bucket
    }

    mutating func reset() { lastSpoken = 0 }
}

// MARK: - Telemetry

/// Counters for one game session, and the "how the game ran" text: copied
/// with Copy how the game ran, and sent with Report a problem with this game
/// from the game's Settings. No account data, no file paths, no links.
struct ArcadeTelemetry {
    var title = ""
    var gameId = ""
    var version = ""
    var openedAt = Date()
    var pageLoads = 0
    var terminations = 0
    var recoveries = 0
    var touchSends = 0
    var infoSends = 0
    var keySends = 0
    var controllerSends = 0
    var eventCounts: [String: Int] = [:]
    var errors: [String] = []
    var kit: [String: String] = [:]
    var mode = ""
    var screen = ""
    var audio = ""
    /// device, iOS, app, Low Power Mode, thermal state, Lockdown Mode, VoiceOver, audio route.
    var environment: [String: String] = [:]

    mutating func note(event name: String, detail: [String: Any]?) {
        eventCounts[name, default: 0] += 1
        switch name {
        case "mode": if let value = detail?["mode"] as? String { mode = value }
        case "screen": if let value = detail?["screen"] as? String { screen = value }
        case "audio": if let value = detail?["state"] as? String { audio = value }
        case "telemetry":
            var flat: [String: String] = [:]
            Self.flatten(detail, prefix: "", into: &flat, depth: 0)
            kit = flat
        case "error":
            var flat: [String: String] = [:]
            Self.flatten(detail, prefix: "", into: &flat, depth: 0)
            note(error: "kit " + flat.keys.sorted().compactMap { key in flat[key].map { key + "=" + $0 } }.joined(separator: " "))
        default: break
        }
    }

    mutating func note(error text: String) {
        let clean = String(text.prefix(240))
        errors.append(clean)
        if errors.count > 8 { errors.removeFirst(errors.count - 8) }
    }

    /// Nested JSON as "a.b=value" pairs, capped so a huge event cannot bloat the report.
    static func flatten(_ value: Any?, prefix: String, into out: inout [String: String], depth: Int) {
        guard out.count < 40, let value else { return }
        if let map = value as? [String: Any] {
            guard depth < 3 else { return }
            for key in map.keys.sorted() {
                flatten(map[key], prefix: prefix.isEmpty ? key : prefix + "." + key, into: &out, depth: depth + 1)
            }
        } else if let list = value as? [Any] {
            out[prefix.isEmpty ? "list" : prefix] = "\(list.count) items"
        } else if let number = value as? NSNumber {
            out[prefix.isEmpty ? "value" : prefix] = number.stringValue
        } else if let text = value as? String {
            out[prefix.isEmpty ? "value" : prefix] = String(text.prefix(80))
        }
    }

    func report(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(openedAt)))
        var lines: [String] = []
        lines.append("Kade AI Arcade: how the game ran")
        lines.append("Game: \(title) (\(gameId) \(version))")
        lines.append("Open for \(seconds / 60) min \(seconds % 60) s")
        lines.append("Page loads: \(pageLoads). Web content stopped: \(terminations). Restarted: \(recoveries).")
        lines.append("Mode: \(mode.isEmpty ? "none yet" : mode). Screen: \(screen.isEmpty ? "none yet" : screen). Game audio: \(audio.isEmpty ? "not started" : audio).")
        lines.append("Inputs sent: touch \(touchSends), info \(infoSends), keyboard \(keySends), controller \(controllerSends).")
        let events = eventCounts.keys.sorted().compactMap { key in eventCounts[key].map { "\(key) \($0)" } }
        lines.append("Kit events: " + (events.isEmpty ? "none" : events.joined(separator: ", ")) + ".")
        if !kit.isEmpty {
            lines.append("Kit telemetry: " + kit.keys.sorted().compactMap { key in kit[key].map { key + "=" + $0 } }.joined(separator: ", "))
        }
        if !environment.isEmpty {
            lines.append("Phone: " + environment.keys.sorted().compactMap { key in environment[key].map { key + ": " + $0 } }.joined(separator: ". ") + ".")
        }
        if errors.isEmpty {
            lines.append("Errors: none.")
        } else {
            lines.append("Last errors:")
            for error in errors { lines.append("- " + error) }
        }
        return lines.joined(separator: "\n")
    }
}
