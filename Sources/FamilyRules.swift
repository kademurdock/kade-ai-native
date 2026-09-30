import Foundation

// MARK: - Family history: the rules the phone keeps itself (Sep 29 2026)
//
// Who may open the section (read from /me's answer), when to ask again, what
// a refusal means, the Library row's words when the server has none, cache
// names, trimming the picture cache, batching signed links and paging long
// lists. Foundation only, like FamilyModels.swift, so run-family-tests.sh
// checks every rule here on Linux; the app files (FamilyHistoryAccess,
// FamilyHistoryService, FamilyImages) only carry them out.
//
// THIS REPOSITORY IS PUBLIC: nothing here names a real family.

// MARK: - Access

/// What the Library row shows, and whether the family screens open.
enum FamilyAccessState: Equatable {
    /// Not answered yet this launch and nothing remembered: dimmed, "Checking".
    case unknown
    /// This account may open it.
    case open(FHMe)
    /// Refused, with the server's reason (and perhaps Ask to be added).
    case locked(FHLocked)
    /// The website has no family history this app can draw (no route yet,
    /// the first version only, or a page instead of an answer): greyed,
    /// "Not available yet".
    case unavailable

    var isOpen: Bool {
        if case .open = self { return true }
        return false
    }

    var me: FHMe? {
        if case .open(let me) = self { return me }
        return nil
    }

    var lock: FHLocked? {
        if case .locked(let locked) = self { return locked }
        return nil
    }
}

/// Ask to be added, under the greyed row: not offered, offered, or done.
enum FamilyAskState: Equatable {
    case hidden
    case ask
    /// "Asked on September 29, 2026".
    case asked(String)
}

/// The Library row (and the Search entry) for one access state.
struct FamilyRowWords: Equatable {
    var enabled: Bool
    var detail: String
    var hint: String
    var ask: FamilyAskState
}

/// The last decisive answer to GET /me, kept per account (UserDefaults), so
/// the family's row is live at launch.
struct FamilyAccessMemo: Codable, Equatable {
    var status: Int
    var body: Data
    /// Seconds since 1970.
    var at: Double
}

enum FamilyAccessRules {
    /// What an answer to GET /me decides, or nil when it decides nothing
    /// (401 after a refresh, 429, 503 while the family history updates, any
    /// other server trouble): then the remembered state stays.
    static func decide(status: Int, body: Data) -> FamilyAccessState? {
        switch status {
        case 200:
            // A page instead of an answer (a proxy, an older site) does not decode.
            guard let me = try? JSONDecoder().decode(FHMe.self, from: body) else { return .unavailable }
            if me.access == false { return .locked(lockedBody(body)) }
            // The first version (live before this app's screens) has no row
            // words and none of the routes these screens read.
            return me.isCurrent ? .open(me) : .unavailable
        case 403:
            return .locked(lockedBody(body))
        case 404:
            return .unavailable
        default:
            return nil
        }
    }

    /// A refusal's words; an unreadable one is still a refusal.
    static func lockedBody(_ body: Data) -> FHLocked {
        (try? JSONDecoder().decode(FHLocked.self, from: body)) ?? FHLocked()
    }

    /// Whether a 403 from a family route means this account lost the family
    /// history (wipe and grey the row), rather than one route being closed
    /// to it (the game answers `guest` to a guest).
    static func revokes(_ locked: FHLocked) -> Bool {
        locked.reasonKind != .guest
    }

    /// The remembered 403 with `askedAt` filled in, after Ask to be added.
    static func withAskedAt(_ body: Data, askedAt: String) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              var dict = object as? [String: Any] else {
            let fallback: [String: Any] = ["access": false, "askedAt": askedAt, "canAsk": true]
            return (try? JSONSerialization.data(withJSONObject: fallback)) ?? body
        }
        dict["askedAt"] = askedAt
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? body
    }

    /// The row's words. The server's words come first; these fallbacks are
    /// generic and public-safe.
    static func rowWords(_ state: FamilyAccessState) -> FamilyRowWords {
        switch state {
        case .unknown:
            return FamilyRowWords(enabled: false, detail: "Checking", hint: "", ask: .hidden)
        case .open(let me):
            return FamilyRowWords(enabled: true,
                                  detail: nonEmpty(me.row?.detail) ?? "Photos, records and stories",
                                  hint: nonEmpty(me.row?.hint) ?? "Your place in the family tree, with photos, records and stories.",
                                  ask: .hidden)
        case .locked(let locked):
            let ask: FamilyAskState
            if locked.canAsk != true {
                ask = .hidden
            } else if locked.mayAsk {
                ask = .ask
            } else {
                ask = .asked(FamilyDates.askedOn(locked.askedAt) ?? "Asked")
            }
            return FamilyRowWords(enabled: false,
                                  detail: nonEmpty(locked.detail) ?? "Private to one family",
                                  hint: nonEmpty(locked.hint) ?? nonEmpty(locked.error) ?? "",
                                  ask: ask)
        case .unavailable:
            return FamilyRowWords(enabled: false, detail: "Not available yet", hint: "", ask: .hidden)
        }
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// When to ask /me again: when the Library appears, when the app becomes
/// active, on a pull; never twice in half a minute unless asked outright.
enum FamilyRecheck {
    static let every: TimeInterval = 30

    static func due(last: Date?, now: Date, force: Bool, every: TimeInterval = FamilyRecheck.every) -> Bool {
        if force { return true }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= every
    }
}

/// The made-up demo family (DEBUG builds only): the `-KadeFamilyDemo` launch
/// argument or KADE_FAMILY_DEMO=1.
enum FamilyDemoSwitch {
    static let argument = "-KadeFamilyDemo"
    static let environmentKey = "KADE_FAMILY_DEMO"

    static func isOn(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains(argument) || environment[environmentKey] == "1"
    }
}

extension FamilyRoute {
    /// Every family screen but the locked one needs an open family history.
    var needsAccess: Bool { self != .locked }

    /// Said as the title until the screen's own words arrive.
    var fallbackTitle: String {
        switch self {
        case .tree(_, let name): return name.isEmpty ? "Family history" : name
        case .person(let route): return route.name.isEmpty ? "Family history" : route.name
        case .story(_, let title): return title.isEmpty ? "Family history" : title
        case .home, .reel, .gallery, .whereWhen, .dna, .stories, .discoveries, .mysteries, .people, .play, .locked:
            return "Family history"
        }
    }
}

// MARK: - Failures

/// Why a family route did not answer. The server's own words come first.
enum FamilyFailure: Error, Equatable {
    /// 403: refused (lost access, or closed to this account, like the game for a guest).
    case locked(FHLocked)
    /// 404: an unknown id, or a part not built yet (`missing`, like "places").
    case missing(String?)
    /// 503: the family history is being updated.
    case updating(String?)
    /// 401 even after a quiet refresh.
    case signedOut
    /// 429.
    case throttled(String?)
    /// Anything else the server said no with.
    case server(Int, String?)
    /// An answer this app could not read.
    case unreadable
    /// The phone could not reach the site.
    case offline

    /// nil for a 2xx answer.
    static func from(status: Int, body: Data) -> FamilyFailure? {
        guard !(200..<300).contains(status) else { return nil }
        let said = try? JSONDecoder().decode(FHErrorBody.self, from: body)
        switch status {
        case 401: return .signedOut
        case 403: return .locked(FamilyAccessRules.lockedBody(body))
        case 404: return .missing(said?.missing)
        case 429: return .throttled(said?.error)
        case 503: return .updating(said?.error)
        default: return .server(status, said?.error)
        }
    }

    var message: String {
        switch self {
        case .locked(let locked):
            return FamilyAccessRules.nonEmpty(locked.error) ?? FamilyAccessRules.nonEmpty(locked.detail) ?? "The family history is private to the family."
        case .missing(let part):
            return part == nil ? "That is not in the family history." : "This part of the family history is not ready yet."
        case .updating(let said):
            return FamilyAccessRules.nonEmpty(said) ?? "The family history is being updated. Try again in a minute."
        case .signedOut:
            return "Please sign in to Kade-AI again."
        case .throttled(let said):
            return FamilyAccessRules.nonEmpty(said) ?? "That was asked for too often. Try again in a little while."
        case .server(_, let said):
            return FamilyAccessRules.nonEmpty(said) ?? "The family history did not answer. Try again in a moment."
        case .unreadable:
            return "The family history sent an answer this app could not read. Try again, or use the website."
        case .offline:
            return "Couldn't reach kademurdock.com. Check your connection and try again."
        }
    }
}

extension FamilyFailure: LocalizedError {
    var errorDescription: String? { message }
}

// MARK: - Dates

enum FamilyDates {
    /// An ISO date from the server ("2026-09-29T12:00:00.000Z").
    static func parse(_ iso: String?) -> Date? {
        guard let iso = iso?.trimmingCharacters(in: .whitespacesAndNewlines), !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// Now, the way the server writes it.
    static func isoNow(_ now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now)
    }

    /// "September 29, 2026".
    static func long(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "Asked on September 29, 2026", or nil when there is no date.
    static func askedOn(_ iso: String?) -> String? {
        guard let date = parse(iso) else { return nil }
        return "Asked on " + long(date)
    }
}

// MARK: - Caches on the phone

enum FamilyArchiveRules {
    static let defaultId = "default"

    /// The API's slug contract, never a tree person ID or a display name.
    static func validId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 48, let first = id.first,
              Set("abcdefghijklmnopqrstuvwxyz").contains(first) else { return false }
        return id.allSatisfy { Set("abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
    }

    static func identity(_ id: String?) -> String { id ?? defaultId }

    /// Default requests remain byte-for-byte compatible in their query.
    /// A caller cannot override the selected archive with another query item.
    static func query(_ items: [URLQueryItem]?, archiveId: String?) -> [URLQueryItem] {
        var scoped = (items ?? []).filter { $0.name != "archive" }
        if let archiveId, archiveId != defaultId, validId(archiveId) {
            scoped.append(URLQueryItem(name: "archive", value: archiveId))
        }
        return scoped
    }
}

/// Names inside Caches/FamilyHistory. The identity of a picture is the
/// account, the media id and the size, never its signed link.
enum FamilyCacheNames {
    static let folder = "FamilyHistory"
    static let homeFile = "home.json"
    /// Kept alongside pictures so archive updates can invalidate them even
    /// when no home screen has been loaded during this launch.
    static let versionFile = "version.txt"
    /// Pictures on disk, all accounts together: 250 MB, least recently used out first.
    static let diskLimit = 250 * 1024 * 1024

    /// Letters, digits, "-" and "_" only, so an id can never leave its folder.
    static func safe(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = String(raw.map { allowed.contains($0) ? $0 : "_" })
        let trimmed = String(mapped.prefix(120))
        return trimmed.isEmpty ? "_" : trimmed
    }

    static func memoryKey(userId: String, mediaId: String, size: FHSize, pixels: Int, archiveId: String? = nil) -> String {
        "\(safe(userId))\(archiveSuffix(archiveId))/\(safe(mediaId)).\(size.rawValue).\(pixels)"
    }

    static func imageFile(mediaId: String, size: FHSize) -> String {
        "\(safe(mediaId)).\(size.rawValue).jpg"
    }

    /// UserDefaults key for one account's remembered /me answer.
    static func accessKey(userId: String, archiveId: String? = nil) -> String {
        "kade.family.access.\(safe(userId))\(archiveSuffix(archiveId))"
    }

    static func archiveSuffix(_ archiveId: String?) -> String {
        guard let archiveId, archiveId != FamilyArchiveRules.defaultId, FamilyArchiveRules.validId(archiveId) else { return "" }
        return ".archive." + archiveId
    }
}

/// One picture file in the disk cache.
struct FamilyCachedFile: Equatable {
    var name: String
    var bytes: Int
    /// Last drawn (the file's modification date, touched on every use).
    var used: Date
}

enum FamilyDiskTrim {
    /// The files to delete, least recently used first, until the rest fit.
    static func victims(_ files: [FamilyCachedFile], limit: Int) -> [String] {
        var total = files.reduce(0) { $0 + max(0, $1.bytes) }
        guard total > limit else { return [] }
        let oldestFirst = files.sorted { ($0.used, $0.name) < ($1.used, $1.name) }
        var out: [String] = []
        for file in oldestFirst {
            if total <= limit { break }
            out.append(file.name)
            total -= max(0, file.bytes)
        }
        return out
    }
}

enum FamilyBatches {
    /// Ids in their first order, each once, in groups of at most `size`
    /// (POST /media/sign takes 100 at a time).
    static func chunks(_ ids: [String], size: Int) -> [[String]] {
        var seen = Set<String>()
        var unique: [String] = []
        for id in ids where !id.isEmpty && !seen.contains(id) {
            seen.insert(id)
            unique.append(id)
        }
        let step = max(1, size)
        return stride(from: 0, to: unique.count, by: step).map { (start: Int) -> [String] in
            Array(unique[start..<min(start + step, unique.count)])
        }
    }
}

/// A small least-recently-used store (the last 30 person pages, a few
/// gallery pages and tree slices).
struct FamilyLRU<Value> {
    let capacity: Int
    /// Oldest first.
    private(set) var keys: [String] = []
    private var values: [String: Value] = [:]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }

    mutating func get(_ key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func set(_ key: String, _ value: Value) {
        values[key] = value
        touch(key)
        while keys.count > capacity {
            let oldest = keys.removeFirst()
            values[oldest] = nil
        }
    }

    mutating func removeAll() {
        keys = []
        values = [:]
    }

    private mutating func touch(_ key: String) {
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) }
        keys.append(key)
    }
}

// MARK: - Long lists, a window at a time (never lazy stacks)

enum FamilyPaging {
    /// How many pages `total` items make.
    static func pages(total: Int, size: Int) -> Int {
        let step = max(1, size)
        let count = max(0, total)
        return count == 0 ? 1 : (count + step - 1) / step
    }

    /// The items on page `page` (from 0, clamped to the pages there are).
    static func window(total: Int, page: Int, size: Int) -> Range<Int> {
        let step = max(1, size)
        let count = max(0, total)
        let last = pages(total: count, size: step) - 1
        let p = min(max(0, page), last)
        let start = p * step
        return start..<min(count, start + step)
    }

    /// "Showing 49 to 96 of 250".
    static func spoken(_ window: Range<Int>, total: Int) -> String {
        guard !window.isEmpty else { return "Nothing to show" }
        return "Showing \(window.lowerBound + 1) to \(window.upperBound) of \(total)"
    }
}
