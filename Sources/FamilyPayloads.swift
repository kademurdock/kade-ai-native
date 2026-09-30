import Foundation

// MARK: - Family history: one answer per route (Sep 29 2026)
//
// The shapes of /home, /tree, /person/:id, /gallery, /media, /dna,
// /timeline, /places, /stories, /story/:slug, /findings, /play, /people,
// /search and /note. Foundation only, tolerant like FamilyModels.swift, and
// built on Linux by run-family-tests.sh with the made-up demo family.

// MARK: - GET /home

struct FHHero: Decodable, Equatable {
    var hello: String? = nil
    var headline: String? = nil
    var youAre: String? = nil
    var stats: String? = nil
    /// "This tree follows your mother's family." for a half-tree viewer.
    var follows: String? = nil
    var spoken: String? = nil
    var open: FHOpen? = nil

    enum CodingKeys: String, CodingKey { case hello, headline, youAre, stats, follows, spoken, open }
}

extension FHHero {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hello = c.fhString(.hello)
        headline = c.fhString(.headline)
        youAre = c.fhString(.youAre)
        stats = c.fhString(.stats)
        follows = c.fhString(.follows)
        spoken = c.fhString(.spoken)
        open = c.fh(.open)
    }
}

/// One large portrait with its caption (fewer than four photographed faces).
struct FHPortrait: Decodable, Equatable {
    var image: FHImage? = nil
    var caption: String? = nil

    enum CodingKeys: String, CodingKey { case image, caption }
}

extension FHPortrait {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = c.fh(.image)
        caption = c.fhString(.caption)
    }
}

struct FHFaces: Decodable, Equatable {
    /// "row" or "portrait".
    var layout: String? = nil
    var people: [FHPerson] = []
    var portrait: FHPortrait? = nil

    enum CodingKeys: String, CodingKey { case layout, people, portrait }
}

extension FHFaces {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = c.fhString(.layout)
        people = c.fhList(.people)
        portrait = c.fh(.portrait)
    }
}

/// One card of "Your family in 60 seconds".
struct FHReelCard: Decodable, Equatable, Identifiable {
    var key: String = ""
    var images: [FHImage] = []
    var people: [FHPerson] = []
    var text: String? = nil
    var spoken: String? = nil
    var open: FHOpen? = nil

    enum CodingKeys: String, CodingKey { case key, images, people, text, spoken, open }

    var id: String { key }
}

extension FHReelCard {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key) ?? ""
        images = c.fhList(.images)
        people = c.fhList(.people)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        open = c.fh(.open)
    }
}

struct FHReel: Decodable, Equatable {
    var title: String? = nil
    var detail: String? = nil
    var cover: FHImage? = nil
    var cards: [FHReelCard] = []

    enum CodingKeys: String, CodingKey { case title, detail, cover, cards }
}

extension FHReel {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.fhString(.title)
        detail = c.fhString(.detail)
        cover = c.fh(.cover)
        cards = c.fhList(.cards)
    }
}

/// On this day, the ancestor of the week, a new photo, a story.
struct FHFeatured: Decodable, Equatable {
    var kind: String? = nil
    var title: String? = nil
    var text: String? = nil
    var spoken: String? = nil
    var image: FHImage? = nil
    var open: FHOpen? = nil

    enum CodingKeys: String, CodingKey { case kind, title, text, spoken, image, open }
}

extension FHFeatured {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.fhString(.kind)
        title = c.fhString(.title)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        image = c.fh(.image)
        open = c.fh(.open)
    }
}

/// "3 new photos and 2 new people since your last visit".
struct FHNews: Decodable, Equatable {
    var text: String? = nil
    var spoken: String? = nil
    var images: [FHImage] = []
    var open: FHOpen? = nil

    enum CodingKeys: String, CodingKey { case text, spoken, images, open }
}

extension FHNews {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        images = c.fhList(.images)
        open = c.fh(.open)
    }
}

/// The owner's own counts: notes from the family, asks to be added.
struct FHOwnerCounts: Decodable, Equatable {
    var notes: Int? = nil
    var asks: Int? = nil

    enum CodingKeys: String, CodingKey { case notes, asks }
}

extension FHOwnerCounts {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = c.fhInt(.notes)
        asks = c.fhInt(.asks)
    }
}

struct FHHome: Decodable, Equatable {
    var version: String? = nil
    var mode: String? = nil
    var isOwner: Bool? = nil
    var hero: FHHero? = nil
    var faces: FHFaces? = nil
    var reel: FHReel? = nil
    var featured: [FHFeatured] = []
    var news: FHNews? = nil
    var tiles: [FHTile] = []
    var more: [FHTile] = []
    var comingSoon: String? = nil
    var footnote: String? = nil
    var owner: FHOwnerCounts? = nil

    enum CodingKeys: String, CodingKey {
        case version, mode, isOwner, hero, faces, reel, featured, news, tiles, more, comingSoon, footnote, owner
    }
}

extension FHHome {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.fhString(.version)
        mode = c.fhString(.mode)
        isOwner = c.fhBool(.isOwner)
        hero = c.fh(.hero)
        faces = c.fh(.faces)
        reel = c.fh(.reel)
        featured = c.fhList(.featured)
        news = c.fh(.news)
        tiles = c.fhList(.tiles)
        more = c.fhList(.more)
        comingSoon = c.fhString(.comingSoon)
        footnote = c.fhString(.footnote)
        owner = c.fh(.owner)
    }
}

// MARK: - GET /tree

/// One box, in box units. `key` is unique; `id` is not (a person drawn twice).
struct FHTreeBox: Decodable, Equatable, Identifiable {
    var key: String = ""
    var personId: String? = nil
    var gen: Int? = nil
    var row: Int? = nil
    var x: Double? = nil
    /// focus, ancestor, sibling, spouse, child.
    var role: String? = nil
    var repeated: Bool? = nil
    var you: Bool? = nil
    var person: FHPerson? = nil
    var moreAbove: Int? = nil
    var spoken: String? = nil

    enum CodingKeys: String, CodingKey {
        case key, personId = "id", gen, row, x, role, repeated = "repeat", you, person, moreAbove, spoken
    }

    var id: String { key }
}

extension FHTreeBox {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key) ?? ""
        personId = c.fhString(.personId)
        gen = c.fhInt(.gen)
        row = c.fhInt(.row)
        x = c.fhDouble(.x)
        role = c.fhString(.role)
        repeated = c.fhBool(.repeated)
        you = c.fhBool(.you)
        person = c.fh(.person)
        moreAbove = c.fhInt(.moreAbove)
        spoken = c.fhString(.spoken)
    }
}

/// A line between two boxes: birth, step, adopted, probable, doubtful.
struct FHTreeEdge: Decodable, Equatable {
    var from: String = ""
    var to: String = ""
    var kind: String? = nil

    enum CodingKeys: String, CodingKey { case from, to, kind }
}

extension FHTreeEdge {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = c.fhString(.from) ?? ""
        to = c.fhString(.to) ?? ""
        kind = c.fhString(.kind)
    }
}

/// A step, adoptive or doubtful parent, listed under the child.
struct FHExtraParent: Decodable, Equatable {
    var childKey: String? = nil
    var person: FHPerson? = nil
    var kindText: String? = nil

    enum CodingKeys: String, CodingKey { case childKey, person, kindText }
}

extension FHExtraParent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        childKey = c.fhString(.childKey)
        person = c.fh(.person)
        kindText = c.fhString(.kindText)
    }
}

struct FHTreeLayout: Decodable, Equatable {
    var boxes: [FHTreeBox] = []
    var edges: [FHTreeEdge] = []
    var couples: [[String]] = []
    /// Box units.
    var width: Double? = nil
    var rows: Int? = nil
    /// Nearest first: the VoiceOver order and the order pictures load in.
    var order: [String] = []
    var extraParents: [FHExtraParent] = []

    enum CodingKeys: String, CodingKey { case boxes, edges, couples, width, rows, order, extraParents }
}

extension FHTreeLayout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boxes = c.fhList(.boxes)
        edges = c.fhList(.edges)
        couples = c.fhList(.couples)
        width = c.fhDouble(.width)
        rows = c.fhInt(.rows)
        order = c.fhList(.order)
        extraParents = c.fhList(.extraParents)
    }
}

/// One legend line: "Dashed line: step or adoptive parent".
struct FHLegendRow: Decodable, Equatable, Identifiable {
    var key: String = ""
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case key, text }

    var id: String { key }
}

extension FHLegendRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key) ?? ""
        text = c.fhString(.text)
    }
}

/// A person in a list: the server's sentence, and the person.
struct FHPersonRow: Decodable, Equatable {
    var personId: String? = nil
    var spoken: String? = nil
    var person: FHPerson? = nil

    enum CodingKeys: String, CodingKey { case personId = "id", spoken, person }
}

extension FHPersonRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personId = c.fhString(.personId)
        spoken = c.fhString(.spoken)
        person = c.fh(.person)
    }
}

/// "Grandparents" (h2) and its rows.
struct FHPeopleSection: Decodable, Equatable {
    var heading: String? = nil
    var level: Int? = nil
    var rows: [FHPersonRow] = []

    enum CodingKeys: String, CodingKey { case heading, level, rows }
}

extension FHPeopleSection {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heading = c.fhString(.heading)
        level = c.fhInt(.level)
        rows = c.fhList(.rows)
    }
}

struct FHTree: Decodable, Equatable {
    /// The focus person's id.
    var focus: String? = nil
    var layout: FHTreeLayout? = nil
    var summary: FHSaid? = nil
    var legend: [FHLegendRow] = []
    var list: [FHPeopleSection] = []

    enum CodingKeys: String, CodingKey { case focus, layout, summary, legend, list }
}

extension FHTree {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focus = c.fhString(.focus)
        layout = c.fh(.layout)
        summary = c.fh(.summary)
        legend = c.fhList(.legend)
        list = c.fhList(.list)
    }
}

// MARK: - GET /person/:id

struct FHRelationBlock: Decodable, Equatable {
    var term: String? = nil
    var chain: String? = nil
    /// You, Mom, Grandma, Her dad.
    var ladder: [String] = []
    var pathPeople: [FHPerson] = []
    var pathText: String? = nil
    var dnaLine: String? = nil
    /// For "Details for DNA fans".
    var details: String? = nil

    enum CodingKeys: String, CodingKey { case term, chain, ladder, pathPeople, pathText, dnaLine, details }
}

extension FHRelationBlock {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = c.fhString(.term)
        chain = c.fhString(.chain)
        ladder = c.fhList(.ladder)
        pathPeople = c.fhList(.pathPeople)
        pathText = c.fhString(.pathText)
        dnaLine = c.fhString(.dnaLine)
        details = c.fhString(.details)
    }
}

struct FHPictures: Decodable, Equatable {
    var total: Int? = nil
    var items: [FHImage] = []

    enum CodingKeys: String, CodingKey { case total, items }
}

extension FHPictures {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = c.fhInt(.total)
        items = c.fhList(.items)
    }
}

/// "1880: counted in the census in {place}, age 34".
struct FHLifeRow: Decodable, Equatable {
    var year: Int? = nil
    /// The fact's own date ("3 Oct 1891"), when it has one.
    var date: String? = nil
    var text: String? = nil
    var spoken: String? = nil
    var records: [String] = []
    /// "2 sources".
    var sources: String? = nil

    enum CodingKeys: String, CodingKey { case year, date, text, spoken, records, sources }
}

extension FHLifeRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = c.fhInt(.year)
        date = c.fhString(.date)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        records = c.fhList(.records)
        sources = c.fhString(.sources)
    }
}

struct FHFamily: Decodable, Equatable {
    var parents: [FHPerson] = []
    var spouses: [FHPerson] = []
    var siblings: [FHPerson] = []
    var children: [FHPerson] = []

    enum CodingKeys: String, CodingKey { case parents, spouses, siblings, children }
}

extension FHFamily {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parents = c.fhList(.parents)
        spouses = c.fhList(.spouses)
        siblings = c.fhList(.siblings)
        children = c.fhList(.children)
    }
}

/// One record: its transcription as rows of cells, and its scan.
struct FHRecord: Decodable, Equatable {
    var key: String? = nil
    var title: String? = nil
    var spoken: String? = nil
    var image: FHImage? = nil
    var fields: [[String]] = []
    var household: [[String]] = []
    var url: URL? = nil
    /// Why it was attached to this person by mistake.
    var wrong: String? = nil
    /// "Attached to this person by mistake: {why}", as the server words it.
    var wrongText: String? = nil
    /// Addresses and phone numbers were taken out of it.
    var scrubbed: Bool? = nil

    enum CodingKeys: String, CodingKey { case key, title, spoken, image, scan, fields, household, url, wrong, wrongText, scrubbed }

    /// The warning to show, in the server's words when it sent them.
    var wrongWords: String? {
        if let said = wrongText, !said.isEmpty { return said }
        guard let why = wrong, !why.isEmpty else { return nil }
        return "Attached to this person by mistake: " + why
    }
}

extension FHRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key)
        title = c.fhString(.title)
        spoken = c.fhString(.spoken)
        // The scan: "image" in the design, "scan" on the server.
        let named: FHImage? = c.fh(.image)
        let scanned: FHImage? = c.fh(.scan)
        image = named ?? scanned
        fields = c.fhRows(.fields)
        household = c.fhRows(.household)
        url = c.fhURL(.url)
        wrong = c.fhString(.wrong)
        wrongText = c.fhString(.wrongText)
        scrubbed = c.fhBool(.scrubbed)
    }
}

struct FHGrave: Decodable, Equatable {
    var cemetery: String? = nil
    var place: String? = nil
    var dates: String? = nil
    var inscription: String? = nil
    var bio: String? = nil
    var photos: [FHImage] = []
    var url: URL? = nil

    enum CodingKeys: String, CodingKey { case cemetery, place, dates, inscription, bio, photos, url }
}

extension FHGrave {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cemetery = c.fhString(.cemetery)
        place = c.fhString(.place)
        dates = c.fhString(.dates)
        inscription = c.fhString(.inscription)
        bio = c.fhString(.bio)
        photos = c.fhList(.photos)
        url = c.fhURL(.url)
    }
}

struct FHSourceRow: Decodable, Equatable {
    /// record, memorial, codex, tree.
    var kind: String? = nil
    var title: String? = nil
    var citation: String? = nil
    var url: URL? = nil

    enum CodingKeys: String, CodingKey { case kind, title, citation, url }
}

extension FHSourceRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.fhString(.kind)
        title = c.fhString(.title)
        citation = c.fhString(.citation)
        url = c.fhURL(.url)
    }
}

/// "1 source withheld: it names living relatives".
struct FHWithheld: Decodable, Equatable {
    var count: Int? = nil
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case count, text }
}

extension FHWithheld {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.fhInt(.count)
        text = c.fhString(.text)
    }
}

struct FHShare: Decodable, Equatable {
    var allowed: Bool? = nil
    /// Sent along with a shared picture ("From our family history").
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case allowed, text }
}

extension FHShare {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = c.fhBool(.allowed)
        text = c.fhString(.text)
    }
}

/// One research finding: a discovery, or a family mystery behind its heads-up.
struct FHFinding: Decodable, Equatable {
    var key: String? = nil
    var title: String? = nil
    var text: String? = nil
    /// records, dna, guess.
    var proof: String? = nil
    var proofText: String? = nil
    var people: [FHPerson] = []
    var evidence: String? = nil
    var storySlug: String? = nil
    var dna: Bool? = nil
    var spoken: String? = nil
    /// The first version's one line.
    var summary: String? = nil
    /// "Research finding, strong DNA evidence, ... not proven by records".
    var proofSpoken: String? = nil

    enum CodingKeys: String, CodingKey {
        case key, title, text, proof, proofText, people, evidence, storySlug, dna, spoken, summary, proofSpoken
    }
}

extension FHFinding {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key)
        title = c.fhString(.title)
        text = c.fhString(.text)
        proof = c.fhString(.proof)
        proofText = c.fhString(.proofText)
        people = c.fhList(.people)
        evidence = c.fhString(.evidence)
        storySlug = c.fhString(.storySlug)
        dna = c.fhBool(.dna)
        spoken = c.fhString(.spoken)
        summary = c.fhString(.summary)
        proofSpoken = c.fhString(.proofSpoken)
    }
}

struct FHPersonPage: Decodable, Equatable {
    var person: FHPerson? = nil
    var header: FHImage? = nil
    /// portrait, grave, record, none.
    var headerKind: String? = nil
    var nutshell: FHSaid? = nil
    var livedThrough: String? = nil
    var relation: FHRelationBlock? = nil
    var pictures: FHPictures? = nil
    var life: [FHLifeRow] = []
    var family: FHFamily? = nil
    var records: [FHRecord] = []
    var grave: FHGrave? = nil
    var findings: [FHFinding] = []
    var sources: [FHSourceRow] = []
    var withheld: FHWithheld? = nil
    var share: FHShare? = nil

    enum CodingKeys: String, CodingKey {
        case person, header, headerKind, nutshell, livedThrough, relation, pictures, life, family, records, grave, findings, sources, withheld, share
    }
}

extension FHPersonPage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        person = c.fh(.person)
        header = c.fh(.header)
        headerKind = c.fhString(.headerKind)
        nutshell = c.fh(.nutshell)
        livedThrough = c.fhString(.livedThrough)
        relation = c.fh(.relation)
        pictures = c.fh(.pictures)
        life = c.fhList(.life)
        family = c.fh(.family)
        records = c.fhList(.records)
        grave = c.fh(.grave)
        findings = c.fhList(.findings)
        sources = c.fhList(.sources)
        withheld = c.fh(.withheld)
        share = c.fh(.share)
    }
}

// MARK: - GET /gallery, /media

struct FHKindCount: Decodable, Equatable, Identifiable {
    var key: String = ""
    var title: String? = nil
    var count: Int? = nil

    enum CodingKeys: String, CodingKey { case key, title, count }

    var id: String { key }
}

extension FHKindCount {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key) ?? ""
        title = c.fhString(.title)
        count = c.fhInt(.count)
    }
}

/// One page of pictures (48 at a time; pages are replaced, never appended).
struct FHGallery: Decodable, Equatable {
    var kind: String? = nil
    var title: String? = nil
    var total: Int? = nil
    var from: Int? = nil
    var count: Int? = nil
    var kinds: [FHKindCount] = []
    var items: [FHImage] = []
    var prev: Int? = nil
    var next: Int? = nil
    /// "Showing 1 to 48 of 250".
    var pageSpoken: String? = nil

    enum CodingKeys: String, CodingKey { case kind, title, total, from, count, kinds, items, prev, next, pageSpoken }
}

extension FHGallery {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.fhString(.kind)
        title = c.fhString(.title)
        total = c.fhInt(.total)
        from = c.fhInt(.from)
        count = c.fhInt(.count)
        kinds = c.fhList(.kinds)
        items = c.fhList(.items)
        prev = c.fhInt(.prev)
        next = c.fhInt(.next)
        pageSpoken = c.fhString(.pageSpoken)
    }
}

/// GET /media/:id?size= → one signed link.
struct FHMediaLink: Decodable, Equatable {
    var url: URL? = nil
    var w: Double? = nil
    var h: Double? = nil
    var expires: String? = nil

    enum CodingKeys: String, CodingKey { case url, w, h, expires }
}

extension FHMediaLink {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.fhURL(.url)
        w = c.fhDouble(.w)
        h = c.fhDouble(.h)
        expires = c.fhString(.expires)
    }
}

/// POST /media/sign → signed links by media id (unknown or hidden ids are
/// left out).
struct FHSigned: Decodable, Equatable {
    var urls: [String: URL] = [:]
    var expires: String? = nil

    enum CodingKeys: String, CodingKey { case urls, expires }
}

extension FHSigned {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw: [String: String] = c.fhMap(.urls)
        var out: [String: URL] = [:]
        for (id, text) in raw {
            if let url = URL(string: text) { out[id] = url }
        }
        urls = out
        expires = c.fhString(.expires)
    }
}

struct FHSourceLabel: Decodable, Equatable {
    var kind: String? = nil
    var title: String? = nil

    enum CodingKeys: String, CodingKey { case kind, title }
}

extension FHSourceLabel {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.fhString(.kind)
        title = c.fhString(.title)
    }
}

/// GET /media/:id/info: the picture, its description and any text in it.
struct FHMediaInfo: Decodable, Equatable {
    var image: FHImage? = nil
    var caption: String? = nil
    var description: String? = nil
    var described: String? = nil
    /// "Described automatically".
    var describedNote: String? = nil
    var text: String? = nil
    var textAuto: Bool? = nil
    /// "Read automatically".
    var textNote: String? = nil
    /// On a restored copy: what the restoring changed.
    var restoredNotes: String? = nil
    var people: [FHPerson] = []
    var source: FHSourceLabel? = nil
    /// Whether "Ask for this photo to be restored" makes sense here (an old
    /// photograph with no restored copy yet; never a record).
    var canAskRestore: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case image, caption, description, described, describedNote, text, textAuto, textNote, restoredNotes, people, source, canAskRestore
    }
}

extension FHMediaInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = c.fh(.image)
        caption = c.fhString(.caption)
        description = c.fhString(.description)
        described = c.fhString(.described)
        describedNote = c.fhString(.describedNote)
        text = c.fhString(.text)
        textAuto = c.fhBool(.textAuto)
        textNote = c.fhString(.textNote)
        restoredNotes = c.fhString(.restoredNotes)
        people = c.fhList(.people)
        source = c.fh(.source)
        canAskRestore = c.fhBool(.canAskRestore)
    }
}

// MARK: - GET /dna

/// One DNA match in a cluster, when the export sends them (the family sees
/// the research as the owner does): a name, the shared cM, the segments.
struct FHMatch: Decodable, Equatable {
    var name: String? = nil
    var cM: Double? = nil
    var segments: Int? = nil
    var note: String? = nil

    enum CodingKeys: String, CodingKey { case name, cM, cm, segments, note }
}

extension FHMatch {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.fhString(.name)
        cM = c.fhDouble(.cM) ?? c.fhDouble(.cm)
        segments = c.fhInt(.segments)
        note = c.fhString(.note)
    }
}

struct FHDNACard: Decodable, Equatable {
    var key: String? = nil
    var title: String? = nil
    var text: String? = nil
    var people: [FHPerson] = []
    var proof: String? = nil
    var proofText: String? = nil
    var storySlug: String? = nil
    var spoken: String? = nil
    /// "about 90 to 400 cM", for Details for DNA fans.
    var band: String? = nil
    /// How many DNA cousins are in the cluster.
    var members: Int? = nil
    var matches: [FHMatch] = []

    enum CodingKeys: String, CodingKey { case key, title, text, people, proof, proofText, storySlug, spoken, band, members, matches }

    /// The same card as a finding, so it draws with the finding card.
    var asFinding: FHFinding {
        FHFinding(key: key, title: title, text: text, proof: proof, proofText: proofText, people: people,
                  storySlug: storySlug, spoken: spoken)
    }
}

extension FHDNACard {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key)
        title = c.fhString(.title)
        text = c.fhString(.text)
        people = c.fhList(.people)
        proof = c.fhString(.proof)
        proofText = c.fhString(.proofText)
        storySlug = c.fhString(.storySlug)
        spoken = c.fhString(.spoken)
        band = c.fhString(.band)
        members = c.fhInt(.members)
        matches = c.fhList(.matches)
    }
}

/// A cluster of DNA cousins, for Details for DNA fans.
struct FHCluster: Decodable, Equatable {
    var key: String? = nil
    var title: String? = nil
    var band: String? = nil
    var members: Int? = nil
    var matches: [FHMatch] = []

    enum CodingKeys: String, CodingKey { case key, title, band, members, matches }
}

extension FHCluster {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key)
        title = c.fhString(.title)
        band = c.fhString(.band)
        members = c.fhInt(.members)
        matches = c.fhList(.matches)
    }
}

/// The sensitive conclusions, behind their heads-up and a Show button.
struct FHMysteries: Decodable, Equatable {
    var headsUp: String? = nil
    var cards: [FHDNACard] = []

    enum CodingKeys: String, CodingKey { case headsUp, cards }
}

extension FHMysteries {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headsUp = c.fhString(.headsUp)
        cards = c.fhList(.cards)
    }
}

/// "Details for DNA fans".
struct FHDetails: Decodable, Equatable {
    var title: String? = nil
    var rows: [String] = []
    var caveats: [String] = []
    var clusters: [FHCluster] = []

    enum CodingKeys: String, CodingKey { case title, rows, caveats, clusters }
}

extension FHDetails {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.fhString(.title)
        rows = c.fhList(.rows)
        caveats = c.fhList(.caveats)
        clusters = c.fhList(.clusters)
    }
}

/// The owner's DNA test, as it applies to this viewer (null for guests and
/// relatives by marriage).
struct FHDNATest: Decodable, Equatable {
    /// self, fullSibling, halfSibling, sharedLine.
    var applies: String? = nil
    /// "Ada's DNA test counts for you too".
    var title: String? = nil
    var intro: String? = nil
    var cards: [FHDNACard] = []
    var mysteries: FHMysteries? = nil
    var details: FHDetails? = nil
    /// "Full siblings share about half their DNA, but not the same half. ..."
    var footnote: String? = nil

    enum CodingKeys: String, CodingKey { case applies, title, intro, cards, mysteries, details, footnote }
}

extension FHDNATest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applies = c.fhString(.applies)
        title = c.fhString(.title)
        intro = c.fhString(.intro)
        cards = c.fhList(.cards)
        mysteries = c.fh(.mysteries)
        details = c.fh(.details)
        footnote = c.fhString(.footnote)
    }
}

/// One slot of the paper fan: an ancestor's place in one generation.
struct FHWedge: Decodable, Equatable {
    var ahnen: Int? = nil
    /// known, unknown, research (unknown values draw as unknown).
    var state: String? = nil
    var side: String? = nil
    /// A living relative (drawn as known: a name is a name).
    var living: Bool? = nil
    var person: FHPerson? = nil
    /// "1 in 4".
    var share: String? = nil

    enum CodingKeys: String, CodingKey { case ahnen, state, side, living, person, share }

    var isResearch: Bool { state == "research" }
    /// A slot with somebody in it (known, living or research).
    var isNamed: Bool { person != nil && state != "unknown" }
}

extension FHWedge {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ahnen = c.fhInt(.ahnen)
        state = c.fhString(.state)
        side = c.fhString(.side)
        living = c.fhBool(.living)
        person = c.fh(.person)
        share = c.fhString(.share)
    }
}

struct FHGeneration: Decodable, Equatable {
    var gen: Int? = nil
    var name: String? = nil
    var slots: Int? = nil
    var named: Int? = nil
    var text: String? = nil
    var spoken: String? = nil
    var wedges: [FHWedge] = []

    enum CodingKeys: String, CodingKey { case gen, name, slots, named, text, spoken, wedges }
}

extension FHGeneration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gen = c.fhInt(.gen)
        name = c.fhString(.name)
        slots = c.fhInt(.slots)
        named = c.fhInt(.named)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        wedges = c.fhList(.wedges)
    }
}

/// "Where your DNA comes from, on paper".
struct FHPaper: Decodable, Equatable {
    /// "Where your DNA comes from, on paper".
    var title: String? = nil
    var startGen: Int? = nil
    /// One side only (a half fan): the tree follows one parent's family.
    var half: Bool? = nil
    var note: String? = nil
    var generations: [FHGeneration] = []

    enum CodingKeys: String, CodingKey { case title, startGen, half, note, generations }
}

extension FHPaper {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.fhString(.title)
        startGen = c.fhInt(.startGen)
        half = c.fhBool(.half)
        note = c.fhString(.note)
        generations = c.fhList(.generations)
    }
}

struct FHBirthplaceRow: Decodable, Equatable {
    var place: String? = nil
    /// "state" or "country".
    var kind: String? = nil
    var count: Int? = nil
    var people: [String] = []

    enum CodingKeys: String, CodingKey { case place, kind, count, people }
}

extension FHBirthplaceRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        place = c.fhString(.place)
        kind = c.fhString(.kind)
        count = c.fhInt(.count)
        people = c.fhList(.people)
    }
}

/// Birthplaces in counts, never percentages: the server's chosen generation,
/// and every generation that has any (`byGen`, the same shape).
struct FHBirthplaces: Decodable, Equatable {
    var gen: Int? = nil
    var title: String? = nil
    var rows: [FHBirthplaceRow] = []
    var unknown: Int? = nil
    /// "9 in {state}, 7 in {state}. 14 not known yet."
    var text: String? = nil
    var spoken: String? = nil
    var note: String? = nil
    var byGen: [FHBirthplaces] = []

    enum CodingKeys: String, CodingKey { case gen, title, rows, unknown, text, spoken, note, byGen }
}

extension FHBirthplaces {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gen = c.fhInt(.gen)
        title = c.fhString(.title)
        rows = c.fhList(.rows)
        unknown = c.fhInt(.unknown)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        note = c.fhString(.note)
        byGen = c.fhList(.byGen)
    }
}

struct FHAbroadRow: Decodable, Equatable {
    var person: FHPerson? = nil
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case person, text }
}

extension FHAbroadRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        person = c.fh(.person)
        text = c.fhString(.text)
    }
}

struct FHAbroad: Decodable, Equatable {
    var text: String? = nil
    var spoken: String? = nil
    var rows: [FHAbroadRow] = []

    enum CodingKeys: String, CodingKey { case text, spoken, rows }
}

extension FHAbroad {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        rows = c.fhList(.rows)
    }
}

/// "About 12.5% on average" for one kind of relative.
struct FHAverage: Decodable, Equatable {
    var key: String? = nil
    var relationClass: String? = nil
    var percent: String? = nil
    /// "With a first cousin: about 12.5% on average."
    var text: String? = nil
    var details: String? = nil

    enum CodingKeys: String, CodingKey { case key, relationClass = "class", percent, text, details }

    /// The row's words: the server's sentence, else the kind and the share.
    var shownText: String {
        if let text, !text.isEmpty { return text }
        let parts: [String] = [relationClass, percent].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: ": ")
    }
}

extension FHAverage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.fhString(.key)
        relationClass = c.fhString(.relationClass)
        percent = c.fhString(.percent)
        text = c.fhString(.text)
        details = c.fhString(.details)
    }
}

struct FHCompare: Decodable, Equatable {
    var title: String? = nil
    var averages: [FHAverage] = []
    var note: String? = nil

    enum CodingKeys: String, CodingKey { case title, averages, note }
}

extension FHCompare {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.fhString(.title)
        averages = c.fhList(.averages)
        note = c.fhString(.note)
    }
}

struct FHDNA: Decodable, Equatable {
    var title: String? = nil
    /// Whose paper this is (the viewer, a spouse or a child), and their name
    /// when it is not the viewer.
    var forId: String? = nil
    var forName: String? = nil
    var follows: String? = nil
    var test: FHDNATest? = nil
    var paper: FHPaper? = nil
    var birthplaces: FHBirthplaces? = nil
    var abroad: FHAbroad? = nil
    var compare: FHCompare? = nil

    enum CodingKeys: String, CodingKey {
        case title, forId = "for", forName, follows, test, paper, birthplaces, abroad, compare
    }
}

extension FHDNA {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.fhString(.title)
        forId = c.fhString(.forId)
        forName = c.fhString(.forName)
        follows = c.fhString(.follows)
        test = c.fh(.test)
        paper = c.fh(.paper)
        birthplaces = c.fh(.birthplaces)
        abroad = c.fh(.abroad)
        compare = c.fh(.compare)
    }
}

// MARK: - GET /timeline

/// One lifeline in a decade's band.
struct FHBar: Decodable, Equatable {
    var personId: String? = nil
    var lane: Int? = nil
    var from: Int? = nil
    var to: Int? = nil
    var side: String? = nil
    var research: Bool? = nil

    enum CodingKeys: String, CodingKey { case personId = "id", lane, from, to, side, research }
}

extension FHBar {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personId = c.fhString(.personId)
        lane = c.fhInt(.lane)
        from = c.fhInt(.from)
        to = c.fhInt(.to)
        side = c.fhString(.side)
        research = c.fhBool(.research)
    }
}

/// "12 of your ancestors were adults during the Civil War."
struct FHContextLine: Decodable, Equatable {
    var title: String? = nil
    var text: String? = nil
    var spoken: String? = nil

    enum CodingKeys: String, CodingKey { case title, text, spoken }
}

extension FHContextLine {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.fhString(.title)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
    }
}

struct FHEvent: Decodable, Equatable {
    var year: Int? = nil
    var text: String? = nil
    var spoken: String? = nil
    var personId: String? = nil
    var research: Bool? = nil

    enum CodingKeys: String, CodingKey { case year, text, spoken, personId, research }
}

extension FHEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = c.fhInt(.year)
        text = c.fhString(.text)
        spoken = c.fhString(.spoken)
        personId = c.fhString(.personId)
        research = c.fhBool(.research)
    }
}

struct FHDecade: Decodable, Equatable {
    var decade: Int? = nil
    var title: String? = nil
    var summary: String? = nil
    var spoken: String? = nil
    var photo: FHImage? = nil
    var bars: [FHBar] = []
    var context: [FHContextLine] = []
    var events: [FHEvent] = []

    enum CodingKeys: String, CodingKey { case decade, title, summary, spoken, photo, bars, context, events }
}

extension FHDecade {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decade = c.fhInt(.decade)
        title = c.fhString(.title)
        summary = c.fhString(.summary)
        spoken = c.fhString(.spoken)
        photo = c.fh(.photo)
        bars = c.fhList(.bars)
        context = c.fhList(.context)
        events = c.fhList(.events)
    }
}

/// Through the years: newest decade first.
struct FHTimeline: Decodable, Equatable {
    var scope: String? = nil
    var follows: String? = nil
    var lanes: Int? = nil
    var mapReady: Bool? = nil
    var people: [String: FHPerson] = [:]
    var decades: [FHDecade] = []

    enum CodingKeys: String, CodingKey { case scope, follows, lanes, mapReady, people, decades }
}

extension FHTimeline {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = c.fhString(.scope)
        follows = c.fhString(.follows)
        lanes = c.fhInt(.lanes)
        mapReady = c.fhBool(.mapReady)
        people = c.fhMap(.people)
        decades = c.fhList(.decades)
    }
}

// MARK: - GET /places

/// One of the fixed map places (at most 80, merged by county).
struct FHPlace: Decodable, Equatable, Identifiable {
    var id: String = ""
    var short: String? = nil
    var lat: Double? = nil
    var lon: Double? = nil
    /// town, county, state, country.
    var precision: String? = nil

    enum CodingKeys: String, CodingKey { case id, short, lat, lon, precision }
}

extension FHPlace {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.fhString(.id) ?? ""
        short = c.fhString(.short)
        lat = c.fhDouble(.lat)
        lon = c.fhDouble(.lon)
        precision = c.fhString(.precision)
    }
}

struct FHMove: Decodable, Equatable {
    var personId: String? = nil
    var from: String? = nil
    var to: String? = nil
    var year: Int? = nil

    enum CodingKeys: String, CodingKey { case personId, from, to, year }
}

extension FHMove {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personId = c.fhString(.personId)
        from = c.fhString(.from)
        to = c.fhString(.to)
        year = c.fhInt(.year)
    }
}

struct FHPlaceRow: Decodable, Equatable {
    var placeId: String? = nil
    var text: String? = nil
    var people: [String] = []

    enum CodingKeys: String, CodingKey { case placeId, text, people }
}

extension FHPlaceRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        placeId = c.fhString(.placeId)
        text = c.fhString(.text)
        people = c.fhList(.people)
    }
}

/// "In the 1880s", grouped by state or country.
struct FHPlaceGroup: Decodable, Equatable {
    var heading: String? = nil
    var rows: [FHPlaceRow] = []

    enum CodingKeys: String, CodingKey { case heading, rows }
}

extension FHPlaceGroup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heading = c.fhString(.heading)
        rows = c.fhList(.rows)
    }
}

struct FHPlaceDecade: Decodable, Equatable {
    var decade: Int? = nil
    var title: String? = nil
    var summary: String? = nil
    var spoken: String? = nil
    /// People per place id.
    var counts: [String: Int] = [:]
    /// The top five places, labelled on the map.
    var labels: [String] = []
    var moves: [FHMove] = []
    var list: [FHPlaceGroup] = []

    enum CodingKeys: String, CodingKey { case decade, title, summary, spoken, counts, labels, moves, list }
}

extension FHPlaceDecade {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decade = c.fhInt(.decade)
        title = c.fhString(.title)
        summary = c.fhString(.summary)
        spoken = c.fhString(.spoken)
        counts = c.fhIntMap(.counts)
        labels = c.fhList(.labels)
        moves = c.fhList(.moves)
        list = c.fhList(.list)
    }
}

struct FHGeoPoint: Decodable, Equatable {
    var lat: Double? = nil
    var lon: Double? = nil
    var name: String? = nil

    enum CodingKeys: String, CodingKey { case lat, lon, name }
}

extension FHGeoPoint {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lat = c.fhDouble(.lat)
        lon = c.fhDouble(.lon)
        name = c.fhString(.name)
    }
}

/// "Across the ocean": one ancestor born abroad.
struct FHOceanCrossing: Decodable, Equatable {
    var personId: String? = nil
    var text: String? = nil
    var from: FHGeoPoint? = nil
    var to: FHGeoPoint? = nil

    enum CodingKeys: String, CodingKey { case personId, text, from, to }
}

extension FHOceanCrossing {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personId = c.fhString(.personId)
        text = c.fhString(.text)
        from = c.fh(.from)
        to = c.fh(.to)
    }
}

struct FHJourney: Decodable, Equatable {
    var personId: String? = nil
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case personId, text }
}

extension FHJourney {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personId = c.fhString(.personId)
        text = c.fhString(.text)
    }
}

struct FHPlaces: Decodable, Equatable {
    var places: [FHPlace] = []
    var people: [String: FHPerson] = [:]
    /// The richest decade, where the map opens.
    var start: Int? = nil
    var decades: [FHPlaceDecade] = []
    var ocean: [FHOceanCrossing] = []
    var journeys: [FHJourney] = []
    var unplaced: String? = nil

    enum CodingKeys: String, CodingKey { case places, people, start, decades, ocean, journeys, unplaced }
}

extension FHPlaces {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = c.fhList(.places)
        people = c.fhMap(.people)
        start = c.fhInt(.start)
        decades = c.fhList(.decades)
        ocean = c.fhList(.ocean)
        journeys = c.fhList(.journeys)
        unplaced = c.fhString(.unplaced)
    }
}

// MARK: - GET /stories, /story/:slug

struct FHStoryRow: Decodable, Equatable {
    var slug: String = ""
    var title: String? = nil
    /// "About 18 minutes".
    var detail: String? = nil
    var research: Bool? = nil
    /// The first version's length.
    var words: Int? = nil

    enum CodingKeys: String, CodingKey { case slug, title, detail, research, words }
}

extension FHStoryRow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = c.fhString(.slug) ?? ""
        title = c.fhString(.title)
        detail = c.fhString(.detail)
        research = c.fhBool(.research)
        words = c.fhInt(.words)
    }
}

/// A clipping or write-up from the tree that has text.
struct FHClipping: Decodable, Equatable {
    var mediaId: String? = nil
    var title: String? = nil
    var people: [FHPerson] = []

    enum CodingKeys: String, CodingKey { case mediaId = "id", title, people }
}

extension FHClipping {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = c.fhString(.mediaId)
        title = c.fhString(.title)
        people = c.fhList(.people)
    }
}

struct FHStories: Decodable, Equatable {
    var stories: [FHStoryRow] = []
    var clippings: [FHClipping] = []

    enum CodingKeys: String, CodingKey { case stories, clippings }
}

extension FHStories {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            stories = c.fhList(.stories)
            clippings = c.fhList(.clippings)
        } else {
            // The first version answered with a bare list of stories.
            stories = (try? LossyArray<FHStoryRow>(from: decoder))?.elements ?? []
            clippings = []
        }
    }
}

struct FHBanner: Decodable, Equatable {
    var banner: String? = nil

    enum CodingKeys: String, CodingKey { case banner }
}

extension FHBanner {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        banner = c.fhString(.banner)
    }
}

/// A run of text inside a block: emphasis, a link, a source number.
struct FHRun: Decodable, Equatable {
    var text: String = ""
    var em: Bool? = nil
    var strong: Bool? = nil
    var link: URL? = nil
    var source: Int? = nil

    enum CodingKeys: String, CodingKey { case text, em, strong, link, source }
}

extension FHRun {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.fhString(.text) ?? ""
        em = c.fhBool(.em)
        strong = c.fhBool(.strong)
        link = c.fhURL(.link)
        source = c.fhInt(.source)
    }
}

/// h2, h3, p, li, quote.
struct FHBlock: Decodable, Equatable {
    var type: String? = nil
    var runs: [FHRun] = []

    enum CodingKeys: String, CodingKey { case type, runs }

    var plainText: String { runs.map { $0.text }.joined() }
}

extension FHBlock {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.fhString(.type)
        runs = c.fhList(.runs)
    }
}

struct FHSourceNote: Decodable, Equatable {
    var n: Int? = nil
    var title: String? = nil

    enum CodingKeys: String, CodingKey { case n, title }
}

extension FHSourceNote {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = c.fhInt(.n)
        title = c.fhString(.title)
    }
}

/// One sentence of a part, timed as fractions of the part (0 to 1).
struct FHCue: Decodable, Equatable {
    var text: String = ""
    var start: Double = 0
    var end: Double = 0

    enum CodingKeys: String, CodingKey { case text, start, end }
}

extension FHCue {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.fhString(.text) ?? ""
        start = c.fhDouble(.start) ?? 0
        end = c.fhDouble(.end) ?? 0
    }
}

/// One part read aloud (about 450 characters), with its sentence cues.
struct FHChunk: Decodable, Equatable {
    var i: Int? = nil
    var text: String = ""
    var cues: [FHCue] = []
    /// A signed link to the part's audio, when the server has made it.
    var audio: URL? = nil

    enum CodingKeys: String, CodingKey { case i, text, cues, audio }
}

extension FHChunk {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        i = c.fhInt(.i)
        text = c.fhString(.text) ?? ""
        cues = c.fhList(.cues)
        audio = c.fhURL(.audio)
    }
}

struct FHStory: Decodable, Equatable {
    var slug: String? = nil
    var title: String? = nil
    var detail: String? = nil
    var research: FHBanner? = nil
    /// "The short version": three lines.
    var short: [String] = []
    /// "Who's who for you".
    var whoswho: [FHPerson] = []
    var blocks: [FHBlock] = []
    var sources: [FHSourceNote] = []
    var chunks: [FHChunk] = []
    var listen: Bool? = nil
    /// The first version sent the story as markdown.
    var markdown: String? = nil

    enum CodingKeys: String, CodingKey { case slug, title, detail, research, short, whoswho, blocks, sources, chunks, listen, markdown }
}

extension FHStory {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = c.fhString(.slug)
        title = c.fhString(.title)
        detail = c.fhString(.detail)
        research = c.fh(.research)
        short = c.fhList(.short)
        whoswho = c.fhList(.whoswho)
        blocks = c.fhList(.blocks)
        sources = c.fhList(.sources)
        chunks = c.fhList(.chunks)
        listen = c.fhBool(.listen)
        markdown = c.fhString(.markdown)
    }
}

// MARK: - GET /findings

/// The Family mysteries row: its title, heads-up and count.
struct FHMysteriesLink: Decodable, Equatable {
    var title: String? = nil
    var headsUp: String? = nil
    var count: Int? = nil

    enum CodingKeys: String, CodingKey { case title, headsUp, count }
}

extension FHMysteriesLink {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.fhString(.title)
        headsUp = c.fhString(.headsUp)
        count = c.fhInt(.count)
    }
}

/// GET /findings (discoveries plus the mysteries row) and
/// GET /findings?group=mysteries (its title, the heads-up, whether this
/// account may see them, and the mysteries).
struct FHFindings: Decodable, Equatable {
    var discoveries: [FHFinding] = []
    var mysteries: FHMysteriesLink? = nil
    var title: String? = nil
    var headsUp: String? = nil
    /// False when the family mysteries are switched off for this account.
    var available: Bool? = nil
    var findings: [FHFinding] = []

    enum CodingKeys: String, CodingKey { case discoveries, mysteries, title, headsUp, available, findings }
}

extension FHFindings {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            discoveries = c.fhList(.discoveries)
            mysteries = c.fh(.mysteries)
            title = c.fhString(.title)
            headsUp = c.fhString(.headsUp)
            available = c.fhBool(.available)
            findings = c.fhList(.findings)
        } else {
            // The first version answered with a bare list.
            discoveries = []
            mysteries = nil
            title = nil
            headsUp = nil
            available = nil
            findings = (try? LossyArray<FHFinding>(from: decoder))?.elements ?? []
        }
    }
}

// MARK: - GET /play

struct FHChoice: Decodable, Equatable {
    var text: String = ""
    var spoken: String? = nil

    enum CodingKeys: String, CodingKey { case text, spoken }
}

extension FHChoice {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.fhString(.text) ?? ""
        spoken = c.fhString(.spoken)
    }
}

struct FHRound: Decodable, Equatable {
    /// relation, side, older, year, birthplace.
    var kind: String? = nil
    var prompt: String? = nil
    var spoken: String? = nil
    var people: [FHPerson] = []
    var image: FHImage? = nil
    var choices: [FHChoice] = []
    /// The right choice's index.
    var answer: Int? = nil
    var explain: String? = nil
    var spokenExplain: String? = nil

    enum CodingKeys: String, CodingKey { case kind, prompt, spoken, people, image, choices, answer, explain, spokenExplain }

    /// A round the app can play: a question, two or more choices, an answer among them.
    var playable: Bool {
        guard let answer, choices.count >= 2 else { return false }
        return answer >= 0 && answer < choices.count
    }
}

extension FHRound {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.fhString(.kind)
        prompt = c.fhString(.prompt)
        spoken = c.fhString(.spoken)
        people = c.fhList(.people)
        image = c.fh(.image)
        choices = c.fhList(.choices)
        answer = c.fhInt(.answer)
        explain = c.fhString(.explain)
        spokenExplain = c.fhString(.spokenExplain)
    }
}

struct FHPlay: Decodable, Equatable {
    var rounds: [FHRound] = []

    enum CodingKeys: String, CodingKey { case rounds }
}

extension FHPlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rounds = c.fhList(.rounds)
    }
}

// MARK: - GET /people, /search

/// Everyone in the tree (pages of 60) and search results.
struct FHPeople: Decodable, Equatable {
    var group: String? = nil
    var title: String? = nil
    var total: Int? = nil
    var from: Int? = nil
    var count: Int? = nil
    var prev: Int? = nil
    var next: Int? = nil
    var pageSpoken: String? = nil
    /// Search: "12 people found", to show and to say.
    var text: String? = nil
    var spoken: String? = nil
    /// Search: what was asked.
    var query: String? = nil
    var sections: [FHPeopleSection] = []
    var people: [FHPerson] = []

    enum CodingKeys: String, CodingKey {
        case group, title, total, from, count, prev, next, pageSpoken, text, spoken, query, sections, people
    }
}

extension FHPeople {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            group = c.fhString(.group)
            title = c.fhString(.title)
            total = c.fhInt(.total)
            from = c.fhInt(.from)
            count = c.fhInt(.count)
            prev = c.fhInt(.prev)
            next = c.fhInt(.next)
            pageSpoken = c.fhString(.pageSpoken)
            text = c.fhString(.text)
            spoken = c.fhString(.spoken)
            query = c.fhString(.query)
            sections = c.fhList(.sections)
            people = c.fhList(.people)
        } else {
            // The first version answered with a bare list of people.
            people = (try? LossyArray<FHPerson>(from: decoder))?.elements ?? []
        }
    }
}

// MARK: - POST /note

struct FHNoteSent: Decodable, Equatable {
    var ok: Bool? = nil
    /// "Sent to {ownerFirst}. Thank you."
    var text: String? = nil

    enum CodingKeys: String, CodingKey { case ok, text }
}

extension FHNoteSent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.fhBool(.ok)
        text = c.fhString(.text)
    }
}
