import Foundation

// MARK: - Family history: the shared shapes (Sep 29 2026)
//
// The phone's half of the private Family History section
// (/api/kade/family-history on the website). Swift only decodes, draws and
// navigates: every word shown or spoken, the tree layout, the timeline lanes,
// the story blocks and the caption cues come from the server.
//
// Foundation only, on purpose: run-family-tests.sh builds this file on Linux
// with the fictional demo family (FamilyDemoData.swift), so a key typo fails
// the gate before a build.
//
// Every model is tolerant: a missing, null or wrongly shaped field becomes nil
// (or an empty list) instead of failing the whole answer, an array drops only
// its bad elements, and a kind the app does not know yet falls back to a
// plain one. Numbers arrive through Double and are checked before they become
// an Int. Signed picture URLs are URL?, and they never identify a picture in
// a cache (the id and size do).
//
// THIS REPOSITORY IS PUBLIC: no family data here, in tests or in the demo
// family. Everything is made up ("Ada Example").

// MARK: - Tolerant decoding

/// Any key: dictionaries keyed by person or place id.
struct FHAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Reads nothing, so one element of any shape can be stepped over.
private struct FHSkip: Decodable {
    init(from decoder: Decoder) throws {}
}

/// An array that keeps every element it can read and drops the rest.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(_ elements: [Element] = []) {
        self.elements = elements
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            // A null element is stepped over (decodeNil moves on only past a null).
            if (try? c.decodeNil()) == true { continue }
            if let value = try? c.decode(Element.self) {
                out.append(value)
            } else if (try? c.decode(FHSkip.self)) == nil {
                // Could not even step over it: keep what was read.
                break
            }
        }
        elements = out
    }
}

/// A JSON object keyed by id, keeping every value it can read.
struct LossyDictionary<Value: Decodable>: Decodable {
    var values: [String: Value]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FHAnyKey.self)
        var out: [String: Value] = [:]
        for key in c.allKeys {
            if let value = try? c.decode(Value.self, forKey: key) {
                out[key.stringValue] = value
            }
        }
        values = out
    }
}

/// A number, also when it arrives as text.
struct FHNumber: Decodable, Equatable {
    var value: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self), n.isFinite {
            value = n
        } else if let s = try? c.decode(String.self), let n = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), n.isFinite {
            value = n
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number")
        }
    }

    /// A checked Int: nil past about a thousand trillion.
    var int: Int? {
        guard abs(value) < 1e15 else { return nil }
        return Int(value.rounded())
    }
}

/// One row of cells (a record's field and value, a household row): text and
/// numbers kept as text, anything else an empty cell.
struct FHCells: Decodable, Equatable {
    var cells: [String]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [String] = []
        while !c.isAtEnd {
            if (try? c.decodeNil()) == true {
                out.append("")
            } else if let s = try? c.decode(String.self) {
                out.append(s)
            } else if let n = try? c.decode(FHNumber.self) {
                out.append(FHText.number(n.value))
            } else if (try? c.decode(FHSkip.self)) != nil {
                out.append("")
            } else {
                break
            }
        }
        cells = out
    }
}

enum FHText {
    /// 1880 stays "1880"; 2.5 stays "2.5".
    static func number(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }
}

extension KeyedDecodingContainer {
    /// Any field: nil when it is missing, null or in another shape.
    func fh<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }

    /// A list: the elements that could be read, empty when missing.
    func fhList<T: Decodable>(_ key: Key) -> [T] {
        (try? decodeIfPresent(LossyArray<T>.self, forKey: key))?.elements ?? []
    }

    /// An object keyed by id: the values that could be read.
    func fhMap<T: Decodable>(_ key: Key) -> [String: T] {
        (try? decodeIfPresent(LossyDictionary<T>.self, forKey: key))?.values ?? [:]
    }

    /// An object of numbers keyed by id (a decade's counts by place).
    func fhIntMap(_ key: Key) -> [String: Int] {
        let raw: [String: FHNumber] = fhMap(key)
        var out: [String: Int] = [:]
        for (k, v) in raw {
            if let n = v.int { out[k] = n }
        }
        return out
    }

    /// Text; a number becomes its digits.
    func fhString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? decodeIfPresent(Double.self, forKey: key), n.isFinite { return FHText.number(n) }
        return nil
    }

    /// A number, also when it arrives as text.
    func fhDouble(_ key: Key) -> Double? {
        (try? decodeIfPresent(FHNumber.self, forKey: key))?.value
    }

    /// A checked Int (through Double).
    func fhInt(_ key: Key) -> Int? {
        (try? decodeIfPresent(FHNumber.self, forKey: key))?.int
    }

    /// A yes or no, also as 0 or 1 or as text.
    func fhBool(_ key: Key) -> Bool? {
        if let flag = try? decodeIfPresent(Bool.self, forKey: key) { return flag }
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return n != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// A link; nil when empty or not a URL.
    func fhURL(_ key: Key) -> URL? {
        guard let s = fhString(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// Rows of cells ([["Relation to head", "Wife"]]).
    func fhRows(_ key: Key) -> [[String]] {
        let rows: [FHCells] = fhList(key)
        return rows.map { $0.cells }
    }
}

// MARK: - Kinds the server may add to (unknown values fall back)

enum FHSide: String {
    case father, mother, both, marriage, research, unknown

    init(raw: String?) {
        self = FHSide(rawValue: raw ?? "") ?? .unknown
    }
}

/// Picture sizes the bundle can hold: thumbnail, screen, large scan, face
/// crop, original (record and document scans only).
enum FHSize: String, CaseIterable {
    case t, s, l, f, o
}

enum FHImageCategory: String {
    case portrait, photo, record, grave, document, story, restored, other

    init(raw: String?) {
        self = FHImageCategory(rawValue: raw ?? "") ?? .other
    }
}

/// Why an account cannot open the family history (the 403's `reason`).
enum FHLockReason: String {
    case review, test, unmatched, declined, guest, unknown

    init(raw: String?) {
        self = FHLockReason(rawValue: raw ?? "") ?? .unknown
    }
}

// MARK: - Person and picture (every payload)

/// "Research finding" words for one person or finding.
struct FHResearch: Decodable, Equatable {
    /// "dna" or "guess".
    var level: String? = nil
    /// "Strong DNA evidence (about 90 to 95% sure)".
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case level, text }
}

extension FHResearch {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = c.fhString(.level)
        text = c.fhString(.text)
    }
}

/// "This is a second copy of {name} in the tree."
struct FHDuplicate: Decodable, Equatable {
    /// The main entry's id.
    var id: String? = nil
    var name: String? = nil
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case id, name, text }
}

extension FHDuplicate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.fhString(.id)
        name = c.fhString(.name)
        text = c.fhString(.text)
    }
}

/// One person, in the viewer's own words ("your 2nd great-grandmother").
struct FHPerson: Decodable, Equatable, Identifiable {
    var id: String = ""
    var name: String? = nil
    var first: String? = nil
    /// "1850–1921" for sight; `yearsSpoken` "1850 to 1921" for speech.
    var years: String? = nil
    var yearsSpoken: String? = nil
    var living: Bool? = nil
    var gen: Int? = nil
    var term: String? = nil
    /// "your mom's mom's dad", for up to three steps.
    var chain: String? = nil
    var side: String? = nil
    var sideText: String? = nil
    var research: FHResearch? = nil
    var face: FHImage? = nil
    var initials: String? = nil
    var spoken: String? = nil
    // The person page adds these.
    var otherNames: [String] = []
    var bornA: String? = nil
    var duplicate: FHDuplicate? = nil
    /// "stepfather", "adoptive mother", "probable father" beside a family member.
    var kindText: String? = nil
    // The first version's rows (kept so an older answer still reads).
    var label: String? = nil
    var lifespan: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, first, years, yearsSpoken, living, gen, term, chain, side, sideText, research, face, initials, spoken
        case otherNames, bornA, duplicate, kindText, label, lifespan
    }

    var sideKind: FHSide { FHSide(raw: side) }
    /// The name to show: the name, else the first version's label.
    var shownName: String { name ?? label ?? "" }
    /// What VoiceOver says for this person when the server gave no sentence.
    var spokenOrName: String { spoken ?? shownName }
}

extension FHPerson {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.fhString(.id) ?? ""
        name = c.fhString(.name)
        first = c.fhString(.first)
        years = c.fhString(.years)
        yearsSpoken = c.fhString(.yearsSpoken)
        living = c.fhBool(.living)
        gen = c.fhInt(.gen)
        term = c.fhString(.term)
        chain = c.fhString(.chain)
        side = c.fhString(.side)
        sideText = c.fhString(.sideText)
        research = c.fh(.research)
        face = c.fh(.face)
        initials = c.fhString(.initials)
        spoken = c.fhString(.spoken)
        otherNames = c.fhList(.otherNames)
        bornA = c.fhString(.bornA)
        duplicate = c.fh(.duplicate)
        kindText = c.fhString(.kindText)
        label = c.fhString(.label)
        lifespan = c.fhString(.lifespan)
    }
}

/// One picture reference. The URLs are signed and short-lived; the id and a
/// size name the picture in every cache.
struct FHImage: Decodable, Equatable, Identifiable {
    var id: String = ""
    /// portrait, photo, record, grave, document, story, restored.
    var category: String? = nil
    var w: Double? = nil
    var h: Double? = nil
    var year: Int? = nil
    var thumb: URL? = nil
    var face: URL? = nil
    /// The short label (a gallery cell).
    var short: String? = nil
    /// The full label (the viewer).
    var alt: String? = nil
    /// What the picture shows, written in advance ("Described automatically").
    var description: String? = nil
    var date: String? = nil
    var place: String? = nil
    /// "auto" when the description was written automatically.
    var described: String? = nil
    var hasText: Bool? = nil
    var textAuto: Bool? = nil
    var shareable: Bool? = nil
    /// The id of a copy restored with AI, when there is one.
    var restored: String? = nil
    /// "Restored with AI: colours and repairs may be guessed".
    var restoredLabel: String? = nil
    /// On a restored copy: the original's id.
    var restoredFrom: String? = nil
    // A gallery page adds these.
    var caption: String? = nil
    var people: [FHPerson] = []
    var index: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, category, w, h, year, thumb, face, short, alt, description, date, place, described, hasText, textAuto, shareable
        case restored, restoredLabel, restoredFrom, caption, people, index
    }

    var categoryKind: FHImageCategory { FHImageCategory(raw: category) }
    /// Never unlabelled: the full label, the short one, the caption, the kind.
    var label: String { alt ?? short ?? caption ?? "" }
    var isRestoredCopy: Bool { restoredFrom != nil || categoryKind == .restored }
    /// Width over height, when both are known.
    var aspect: Double? {
        guard let w, let h, w > 0, h > 0 else { return nil }
        return w / h
    }
}

extension FHImage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.fhString(.id) ?? ""
        category = c.fhString(.category)
        w = c.fhDouble(.w)
        h = c.fhDouble(.h)
        year = c.fhInt(.year)
        thumb = c.fhURL(.thumb)
        face = c.fhURL(.face)
        short = c.fhString(.short)
        alt = c.fhString(.alt)
        description = c.fhString(.description)
        date = c.fhString(.date)
        place = c.fhString(.place)
        described = c.fhString(.described)
        hasText = c.fhBool(.hasText)
        textAuto = c.fhBool(.textAuto)
        shareable = c.fhBool(.shareable)
        restored = c.fhString(.restored)
        restoredLabel = c.fhString(.restoredLabel)
        restoredFrom = c.fhString(.restoredFrom)
        caption = c.fhString(.caption)
        people = c.fhList(.people)
        index = c.fhInt(.index)
    }
}

/// Words the server wrote twice: once to show, once to say.
struct FHSaid: Decodable, Equatable {
    var text: String? = nil
    var spoken: String? = nil

    enum CodingKeys: String, CodingKey { case text, spoken }

    var spokenOrText: String { spoken ?? text ?? "" }
}

extension FHSaid {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
    }
}

// MARK: - Where a tile, card or row goes

/// The server's "open": `{to, id?, since?, filter?}`. Unknown `to` values are
/// ignored (the row simply does not open anything new).
struct FHOpen: Decodable, Equatable {
    var to: String? = nil
    var id: String? = nil
    var since: String? = nil
    var filter: String? = nil
    /// Said as the next screen's title until it loads.
    var name: String? = nil
    var title: String? = nil

    enum CodingKeys: String, CodingKey { case to, id, since, filter, name, title }

    /// Every `to` the app understands.
    static let knownKeys: [String] = [
        "home", "reel", "tree", "person", "gallery", "story", "stories", "dna",
        "whereWhen", "map", "discoveries", "mysteries", "people", "play", "note",
    ]

    var target: FHOpenTarget? {
        let key = to ?? ""
        let someId: String? = (id?.isEmpty == false) ? id : nil
        switch key {
        case "home": return .route(.home)
        case "reel": return .route(.reel)
        case "tree": return .route(.tree(focus: someId, name: name ?? ""))
        case "person":
            guard let personId = someId else { return nil }
            return .route(.person(FamilyPersonRoute(id: personId, name: name ?? "")))
        case "gallery":
            return .route(.gallery(FamilyGalleryRoute(kind: filter ?? "photos", person: someId, since: since)))
        case "story":
            guard let slug = someId else { return .route(.stories) }
            return .route(.story(slug: slug, title: title ?? name ?? ""))
        case "stories": return .route(.stories)
        case "dna": return .route(.dna(forId: someId))
        case "whereWhen": return .route(.whereWhen(map: false))
        case "map": return .route(.whereWhen(map: true))
        case "discoveries": return .route(.discoveries)
        case "mysteries": return .route(.mysteries)
        case "people": return .route(.people)
        case "play": return .route(.play)
        case "note": return .note(personId: someId)
        default: return nil
        }
    }
}

extension FHOpen {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        to = c.fhString(.to)
        id = c.fhString(.id)
        since = c.fhString(.since)
        filter = c.fhString(.filter)
        name = c.fhString(.name)
        title = c.fhString(.title)
    }
}

/// What an `FHOpen` does: push a family screen, or open the note sheet.
enum FHOpenTarget: Equatable {
    case route(FamilyRoute)
    case note(personId: String?)
}

/// A tile or a plain row on the family home: `{key, title, detail, spoken,
/// hint, enabled, reason, open}`.
struct FHTile: Decodable, Equatable, Identifiable {
    var key: String = ""
    var title: String? = nil
    var detail: String? = nil
    var spoken: String? = nil
    var hint: String? = nil
    var enabled: Bool? = nil
    /// Why it is dimmed ("For family members in the tree").
    var reason: String? = nil
    var open: FHOpen? = nil

    enum CodingKeys: String, CodingKey { case key, title, detail, spoken, hint, enabled, reason, open }

    var id: String { key }
    var isEnabled: Bool { enabled ?? true }
}

extension FHTile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key) ?? ""
        title = c.fhString(.title)
        detail = c.fhString(.detail)
        spoken = c.fhString(.spoken)
        hint = c.fhString(.hint)
        enabled = c.fhBool(.enabled)
        reason = c.fhString(.reason)
        open = c.fh(.open)
    }
}

// MARK: - Routes (the Library stack; no new HomeRoute)

/// A person page; the name is said as the heading before the page loads.
struct FamilyPersonRoute: Hashable {
    let id: String
    var name: String = ""
}

/// Photos and records: a kind ("photos" first), perhaps one person's, perhaps
/// only what is new since a version.
struct FamilyGalleryRoute: Hashable {
    var kind: String = "photos"
    var person: String? = nil
    var since: String? = nil
}

/// A place inside Family history. Every push is
/// `HomeRoute.library(.family(...))`, so each tab still registers HomeRoute
/// exactly once.
enum FamilyRoute: Hashable {
    case home
    case reel
    /// nil focus = the viewer.
    case tree(focus: String?, name: String)
    case person(FamilyPersonRoute)
    case gallery(FamilyGalleryRoute)
    case whereWhen(map: Bool)
    case dna(forId: String?)
    case stories
    case story(slug: String, title: String)
    case discoveries
    case mysteries
    case people
    case play
    /// Why this account cannot open it, with Ask to be added.
    case locked

    var id: String {
        switch self {
        case .home: return "home"
        case .reel: return "reel"
        case .tree(let focus, _): return "tree-\(focus ?? "me")"
        case .person(let route): return "person-\(route.id)"
        case .gallery(let route): return "gallery-\(route.kind)-\(route.person ?? "")-\(route.since ?? "")"
        case .whereWhen(let map): return map ? "where-map" : "where-years"
        case .dna(let forId): return "dna-\(forId ?? "me")"
        case .stories: return "stories"
        case .story(let slug, _): return "story-\(slug)"
        case .discoveries: return "discoveries"
        case .mysteries: return "mysteries"
        case .people: return "people"
        case .play: return "play"
        case .locked: return "locked"
        }
    }
}

// MARK: - Access: GET /me, its 403, POST /ask

struct FHViewer: Decodable, Equatable {
    var personId: String? = nil
    var first: String? = nil
    var name: String? = nil
    var label: String? = nil

    enum CodingKeys: String, CodingKey { case personId, first, name, label }
}

extension FHViewer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personId = c.fhString(.personId)
        first = c.fhString(.first)
        name = c.fhString(.name)
        label = c.fhString(.label)
    }
}

/// The Library row's words: "{ownerFirst}'s sister", and its hint.
struct FHRow: Decodable, Equatable {
    var detail: String? = nil
    var hint: String? = nil

    enum CodingKeys: String, CodingKey { case detail, hint }
}

extension FHRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detail = c.fhString(.detail)
        hint = c.fhString(.hint)
    }
}

struct FHOwnerName: Decodable, Equatable {
    var first: String? = nil

    enum CodingKeys: String, CodingKey { case first }
}

extension FHOwnerName {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        first = c.fhString(.first)
    }
}

/// GET /me, when the account may open it.
struct FHMe: Decodable, Equatable {
    var access: Bool? = nil
    /// "family", "owner" or "guest".
    var mode: String? = nil
    var isOwner: Bool? = nil
    var version: String? = nil
    var viewer: FHViewer? = nil
    var owner: FHOwnerName? = nil
    var row: FHRow? = nil
    /// "Your own view is not ready yet, so this is {ownerFirst}'s."
    var viewNote: String? = nil

    enum CodingKeys: String, CodingKey { case access, mode, isOwner, version, viewer, owner, row, viewNote }

    /// The second version of the section (the one this app draws) always
    /// sends the row's words; the first version's /me does not.
    var isCurrent: Bool { row != nil }
}

extension FHMe {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access = c.fhBool(.access)
        mode = c.fhString(.mode)
        isOwner = c.fhBool(.isOwner)
        version = c.fhString(.version)
        viewer = c.fh(.viewer)
        owner = c.fh(.owner)
        row = c.fh(.row)
        viewNote = c.fhString(.viewNote)
    }
}

/// GET /me's 403: why not, and whether this account may ask.
struct FHLocked: Decodable, Equatable {
    var access: Bool? = nil
    /// review, test, unmatched, declined (guest on the game).
    var reason: String? = nil
    var error: String? = nil
    /// "Not linked to the tree yet".
    var detail: String? = nil
    var hint: String? = nil
    var canAsk: Bool? = nil
    /// When this account asked to be added (ISO date).
    var askedAt: String? = nil

    enum CodingKeys: String, CodingKey { case access, reason, error, detail, hint, canAsk, askedAt }

    var reasonKind: FHLockReason { FHLockReason(raw: reason) }
    /// Ask to be added shows only for an account that may ask and has not.
    var mayAsk: Bool { canAsk == true && (askedAt ?? "").isEmpty }
}

extension FHLocked {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access = c.fhBool(.access)
        reason = c.fhString(.reason)
        error = c.fhString(.error)
        detail = c.fhString(.detail)
        hint = c.fhString(.hint)
        canAsk = c.fhBool(.canAsk)
        askedAt = c.fhString(.askedAt)
    }
}

/// POST /ask → `{ok, askedAt, text}`; an error answer has `error`.
struct FHAsked: Decodable, Equatable {
    var ok: Bool? = nil
    var askedAt: String? = nil
    var text: String? = nil
    var error: String? = nil

    enum CodingKeys: String, CodingKey { case ok, askedAt, text, error }
}

extension FHAsked {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.fhBool(.ok)
        askedAt = c.fhString(.askedAt)
        text = c.fhString(.text)
        error = c.fhString(.error)
    }
}

/// Any error answer: `{error, missing}` (missing: a part not built yet, like
/// "places").
struct FHErrorBody: Decodable, Equatable {
    var error: String? = nil
    var missing: String? = nil
    var reason: String? = nil

    enum CodingKeys: String, CodingKey { case error, missing, reason }
}

extension FHErrorBody {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = c.fhString(.error)
        missing = c.fhString(.missing)
        reason = c.fhString(.reason)
    }
}
