import Foundation
import Combine

// MARK: - Make a described video (Sep 24 2026)
//
// The phone's door onto the website's describer (kademurdock.com/described-video):
// keep the actors, music and sound, and a narrator describes what happens on
// screen in the pauses. Every call is an ordinary user JWT against the fork's
// /api/kade/described-video/*; the fork owns the model, voice and storage keys.
//
// Adult beta and review accounts can use their own uploads. The
// app shows the feature (Create tile, search entry, Library button, Help) only
// after `GET config` has succeeded for this account (DescribedVideoAccess), so
// an account the server refuses never meets a screen that refuses it.

/// Where the screen opens: a Library video (book + track), a lock-screen card,
/// the "ready" push, or plainly.
struct DescribedVideoStart: Hashable {
    var book: String? = nil
    var track: Int? = nil
    /// A lock-screen card (every card has the same link, so it cannot say
    /// which video): the video being worked on, else the newest finished.
    var openLatest = false
    /// The "your described video is ready" push: the newest finished video,
    /// even while another is still being checked or described.
    var openFinished = false
}

/// Whether this account may use the describer. Decided once per sign-in by
/// asking for the config; a 403 hides everything silently.
@MainActor
final class DescribedVideoAccess: ObservableObject {
    static let shared = DescribedVideoAccess()

    @Published private(set) var allowed = false
    private var decided = false
    private var checking = false
    /// Moves on at every sign-out, so an answer asked for by the account
    /// that signed out is never kept for the next one.
    private var generation = 0

    /// Asks the server once. A network failure, a 401, a 5xx or a 200 that is
    /// not the describer's config (a proxy's page, or any other JSON) leaves
    /// it undecided, so the next foreground asks again; 403 and 404 decide
    /// "no".
    func check(client: KadeAPIClient) async {
        guard !decided, !checking else { return }
        let asked = generation
        checking = true
        defer {
            if asked == generation { checking = false }
        }
        let req = client.request(path: "api/kade/described-video/config", authorized: true, timeout: 30)
        guard let (data, http) = try? await client.send(req) else { return }
        // Signed out (and perhaps in as someone else) while it was asked.
        guard asked == generation else { return }
        if http.statusCode == 200 {
            // Every field is read leniently, so `{}` would decode: it counts
            // only with a field the describer's config always sends.
            guard let config = try? JSONDecoder().decode(DVConfig.self, from: data),
                  config.voices != nil || config.perMinuteUSD != nil || config.maxBytes != nil else { return }
            allowed = true
            decided = true
        } else if http.statusCode == 403 || http.statusCode == 404 {
            allowed = false
            decided = true
        }
    }

    /// The screen's own config load settles it too.
    func record(allowed: Bool) {
        self.allowed = allowed
        decided = true
    }

    /// Sign-out: the next account is asked afresh, and a check still out for
    /// the last account is ignored when it answers.
    func reset() {
        generation += 1
        checking = false
        allowed = false
        decided = false
    }
}

/// The one upload running, whichever describer screen started it. A screen is
/// easily replaced while an upload runs (the Create tab tapped again, the
/// Library's "Make a described copy", the upload's own lock-screen card), and
/// the new screen must still show the progress and the Stop button, must not
/// start a second upload, and opens the video when the upload ends. How it
/// ended is said once, by the screen she is on.
@MainActor
final class DescribedVideoUploads: ObservableObject {
    static let shared = DescribedVideoUploads()

    enum Ending {
        case uploaded(DVJob)
        case stopped
        case failed(Error)
    }

    @Published private(set) var isRunning = false
    /// 0 to 1 once the file itself is going up; nil while the phone checks it.
    @Published private(set) var progress: Double?
    /// Counts the endings, so each is said once.
    @Published private(set) var endingNumber = 0
    private var ending: Ending?
    private var task: Task<Void, Never>?
    private var card: String?
    private var cardStep = -1

    /// Runs one upload; false when one is already running.
    func run(_ work: @escaping @MainActor () async -> Ending?) -> Bool {
        guard task == nil else { return false }
        isRunning = true
        progress = nil
        task = Task {
            let result = await work()
            self.end(result)
        }
        return true
    }

    func stop() {
        task?.cancel()
    }

    /// The phone's checks passed and the file itself starts going up.
    func started(name: String) {
        progress = 0
        cardStep = 0
        card = KadeJobActivity.start(kind: "described-video", title: "Uploading: \(name)", status: "Uploading", progress: 0)
    }

    /// The bar moves with every chunk; the lock-screen card with every tenth.
    func moved(_ fraction: Double) {
        progress = fraction
        let step = Int(fraction * 10)
        guard step != cardStep else { return }
        cardStep = step
        KadeJobActivity.update(card, status: "Uploading", progress: fraction)
    }

    private func end(_ result: Ending?) {
        if case .some(.uploaded) = result {
            KadeJobActivity.finish(card, status: "Uploaded")
        } else {
            KadeJobActivity.finish(card, status: "Upload paused", failed: true)
        }
        card = nil
        task = nil
        isRunning = false
        progress = nil
        guard let result else { return }
        ending = result
        endingNumber += 1
    }

    /// The newest ending, when it came after `seen` and no screen has said
    /// it yet. The first screen to ask takes it.
    func take(after seen: Int) -> Ending? {
        guard endingNumber > seen, let ending else { return nil }
        self.ending = nil
        return ending
    }
}

// MARK: - Wire shapes (CONTRACT.md, HTTP API, plus the round-2 additions)
//
// EVERY field is read leniently: one the server leaves out, or sends in
// another shape (a count where a list was, a number as text), becomes nil
// instead of failing the whole answer. The one exception is a video's id,
// without which nothing can be done with it. Each `init(from:)` lives in an
// extension so the memberwise initialisers stay.

extension KeyedDecodingContainer {
    /// Any Decodable field: nil when missing or in another shape.
    func dvValue<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }

    /// A number, also when it arrives as text.
    func dvNumber(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// A whole number, also when it arrives as 12.0 or "12".
    func dvInt(_ key: Key) -> Int? {
        guard let number = dvNumber(key), number.isFinite, abs(number) < 1e15 else { return nil }
        return Int(number.rounded())
    }

    /// A yes or no, also when it arrives as 0 or 1 or as text.
    func dvBool(_ key: Key) -> Bool? {
        if let flag = try? decodeIfPresent(Bool.self, forKey: key) { return flag }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0", "": return false
            default: return nil
            }
        }
        return nil
    }

    /// Text, also when it arrives as a number.
    func dvString(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? decodeIfPresent(Double.self, forKey: key), number.isFinite {
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        }
        return nil
    }
}

/// A section list the server may send as a count or as the section numbers.
struct DVSectionList: Decodable, Equatable {
    let sections: [Int]
    let count: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([Int].self) {
            sections = list
            count = list.count
        } else if let number = try? c.decode(Int.self) {
            sections = []
            count = max(0, number)
        } else if let number = try? c.decode(Double.self), number.isFinite, abs(number) < 1e9 {
            sections = []
            count = max(0, Int(number))
        } else {
            sections = []
            count = 0
        }
    }
}

/// "Saved to the Library": the server sends the Library item id, or true.
struct DVFlag: Decodable, Equatable {
    let isOn: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flag = try? c.decode(Bool.self) {
            isOn = flag
        } else if let text = try? c.decode(String.self) {
            isOn = !text.isEmpty
        } else if let number = try? c.decode(Double.self) {
            isOn = number != 0
        } else {
            isOn = false
        }
    }
}

struct DVRange: Decodable, Equatable {
    let start: Double
    let end: Double

    enum CodingKeys: String, CodingKey { case start, end }
}

extension DVRange {
    /// A part without a readable start and end is no part at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let from = c.dvNumber(.start), let to = c.dvNumber(.end) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: "A part needs a start and an end."
            ))
        }
        start = from
        end = to
    }
}

struct DVSettings: Decodable, Equatable {
    let voice: String?
    let rate: Double?
    let maxRate: Double?
    let mode: String?
    let detail: String?
    let volume: String?
    let notes: String?
    let closeLook: Bool?
    let firstLook: Bool?
    let range: DVRange?

    enum CodingKeys: String, CodingKey {
        case voice, rate, maxRate, mode, detail, volume, notes, closeLook, firstLook, range
    }
}

extension DVSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voice = c.dvString(.voice)
        rate = c.dvNumber(.rate)
        maxRate = c.dvNumber(.maxRate)
        mode = c.dvString(.mode)
        detail = c.dvString(.detail)
        volume = c.dvString(.volume)
        notes = c.dvString(.notes)
        closeLook = c.dvBool(.closeLook)
        firstLook = c.dvBool(.firstLook)
        range = c.dvValue(.range)
    }
}

struct DVConfig: Decodable {
    struct Extras: Decodable {
        let closeLook: Double?
        let firstLook: Double?

        enum CodingKeys: String, CodingKey { case closeLook, firstLook }
    }

    struct SetAside: Decodable {
        let factor: Double?
        let extraUSD: Double?

        enum CodingKeys: String, CodingKey { case factor, extraUSD }
    }

    struct VoiceCategory: Decodable {
        let name: String
        let voices: [String]

        enum CodingKeys: String, CodingKey { case name, voices }
    }

    let enabled: Bool?
    let maxBytes: Int?
    let chunkBytes: Int?
    let maxMinutes: Double?
    let maxSourceMinutes: Double?
    let limitUSD: Double?
    let dailyUSD: Double?
    let billingMode: String?
    let remainingUSD: Double?
    let perMinuteUSD: [String: Double]?
    let extrasPerMinuteUSD: Extras?
    let setAside: SetAside?
    let previewSeconds: Double?
    let library: Bool?
    let defaultLibraryPath: String?
    let defaultVoice: String?
    let voicesAvailable: Bool?
    let voices: [String]?
    let describe: [String: String]?
    let categories: [VoiceCategory]?
    /// True when dialogue timing is included, like narration (the server's
    /// KADE_DESCRIPTION_FREE_DIALOGUE switch). Absent on older servers.
    let dialogueIncluded: Bool?
    /// Her narrator choices, kept on the server since Sep 25 2026 (all
    /// absent on older servers). `defaultVoice` above is the voice her new
    /// videos start with: hers when she chose one, else the house voice.
    let myDefaultVoice: String?
    let houseVoice: String?
    let favorites: [String]?
    let recent: [String]?
    let maxFavorites: Int?
    /// "Good for describing": Inworld voices only, curated by Kade on the website.
    let suggested: [String]?
    /// Voices that speak through Fish, which sound less natural sped up,
    /// and the gentle note the server words for them.
    let fish: [String]?
    let fishNote: String?
    /// True for the administrator, who curates Good for describing on the
    /// website. The phone offers no curating; it is read so the answer is whole.
    let curate: Bool?
    /// Her speeds, kept for her account (Sep 25 2026; absent on older servers).
    let speeds: DVSpeeds?

    enum CodingKeys: String, CodingKey {
        case enabled, maxBytes, chunkBytes, maxMinutes, maxSourceMinutes, limitUSD, dailyUSD, billingMode
        case remainingUSD, perMinuteUSD, extrasPerMinuteUSD, setAside, previewSeconds, library
        case defaultLibraryPath, defaultVoice, voicesAvailable, voices, describe, categories
        case dialogueIncluded
        case myDefaultVoice, houseVoice, favorites, recent, maxFavorites, suggested, fish, fishNote, curate
        case speeds
    }
}

extension DVConfig.Extras {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        closeLook = c.dvNumber(.closeLook)
        firstLook = c.dvNumber(.firstLook)
    }
}

extension DVConfig.SetAside {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        factor = c.dvNumber(.factor)
        extraUSD = c.dvNumber(.extraUSD)
    }
}

extension DVConfig.VoiceCategory {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.dvString(.name) ?? "Voices"
        voices = c.dvValue(.voices) ?? []
    }
}

extension DVConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.dvBool(.enabled)
        maxBytes = c.dvInt(.maxBytes)
        chunkBytes = c.dvInt(.chunkBytes)
        maxMinutes = c.dvNumber(.maxMinutes)
        maxSourceMinutes = c.dvNumber(.maxSourceMinutes)
        limitUSD = c.dvNumber(.limitUSD)
        dailyUSD = c.dvNumber(.dailyUSD)
        billingMode = c.dvString(.billingMode)
        remainingUSD = c.dvNumber(.remainingUSD)
        perMinuteUSD = c.dvValue(.perMinuteUSD)
        extrasPerMinuteUSD = c.dvValue(.extrasPerMinuteUSD)
        setAside = c.dvValue(.setAside)
        previewSeconds = c.dvNumber(.previewSeconds)
        library = c.dvBool(.library)
        defaultLibraryPath = c.dvString(.defaultLibraryPath)
        defaultVoice = c.dvString(.defaultVoice)
        voicesAvailable = c.dvBool(.voicesAvailable)
        voices = c.dvValue(.voices)
        describe = c.dvValue(.describe)
        categories = c.dvValue(.categories)
        dialogueIncluded = c.dvBool(.dialogueIncluded)
        myDefaultVoice = c.dvString(.myDefaultVoice)
        houseVoice = c.dvString(.houseVoice)
        favorites = c.dvValue(.favorites)
        recent = c.dvValue(.recent)
        maxFavorites = c.dvInt(.maxFavorites)
        suggested = c.dvValue(.suggested)
        fish = c.dvValue(.fish)
        fishNote = c.dvString(.fishNote)
        curate = c.dvBool(.curate)
        speeds = c.dvValue(.speeds)
    }
}

/// Sep 25 2026, Kade: "people should be able to have it remember the speeds
/// they like." Her usual narration speed, the fastest it may go to fit a gap,
/// and how fast finished videos play, kept for her account so the website
/// and every phone agree. Each is nil until she chooses.
struct DVSpeeds: Decodable, Equatable {
    var rate: Double?
    var maxRate: Double?
    var playbackRate: Double?

    enum CodingKeys: String, CodingKey { case rate, maxRate, playbackRate }
}

extension DVSpeeds {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rate = c.dvNumber(.rate)
        maxRate = c.dvNumber(.maxRate)
        playbackRate = c.dvNumber(.playbackRate)
    }
}

/// Her narrator choices as the server keeps them (Sep 25 2026): the voice
/// her new videos start with, her favourites (up to 12) and the voices her
/// last runs used. The answer to every change, and part of the config.
struct DVPrefs: Decodable {
    /// The voice her new videos start with: hers, else the house voice.
    var defaultVoice: String?
    /// The one she chose; nil until she chooses.
    var myDefaultVoice: String?
    /// The describer's own narrator, used until she chooses.
    var houseVoice: String?
    var favorites: [String] = []
    var recent: [String] = []
    /// Her speeds as saved for her account; nil on servers before Sep 25 2026.
    var speeds: DVSpeeds?

    enum CodingKeys: String, CodingKey { case defaultVoice, myDefaultVoice, houseVoice, favorites, recent, speeds }
}

extension DVPrefs {
    init(config: DVConfig) {
        defaultVoice = config.defaultVoice
        myDefaultVoice = config.myDefaultVoice
        houseVoice = config.houseVoice
        favorites = config.favorites ?? []
        recent = config.recent ?? []
        speeds = config.speeds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultVoice = c.dvString(.defaultVoice)
        myDefaultVoice = c.dvString(.myDefaultVoice)
        houseVoice = c.dvString(.houseVoice)
        favorites = c.dvValue(.favorites) ?? []
        recent = c.dvValue(.recent) ?? []
        speeds = c.dvValue(.speeds)
    }

    /// A run just started with this voice: it leads Recently used, as the
    /// server records it too (eight at most, like the server).
    mutating func noteRecent(_ voice: String) {
        guard !voice.isEmpty else { return }
        recent = Array(([voice] + recent.filter { $0 != voice }).prefix(8))
    }
}

struct DVCopy: Decodable, Identifiable {
    let version: Int?
    let preview: Bool?
    let settings: DVSettings?
    let outputSeconds: Double?
    let count: Int?
    let skipped: Int?
    let failedSections: Int?
    let savedToLibrary: DVFlag?
    let finishedAt: String?
    let range: DVRange?
    /// A website-only free rehearsal (a test tone, no paid services).
    let rehearsal: Bool?

    enum CodingKeys: String, CodingKey {
        case version, preview, settings, outputSeconds, count, skipped, failedSections
        case savedToLibrary, finishedAt, range, rehearsal
    }

    var id: Int { version ?? 1 }
    var number: Int { version ?? 1 }
    var isSaved: Bool { savedToLibrary?.isOn ?? false }
}

extension DVCopy {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.dvInt(.version)
        preview = c.dvBool(.preview)
        settings = c.dvValue(.settings)
        outputSeconds = c.dvNumber(.outputSeconds)
        count = c.dvInt(.count)
        skipped = c.dvInt(.skipped)
        failedSections = c.dvInt(.failedSections)
        savedToLibrary = c.dvValue(.savedToLibrary)
        finishedAt = c.dvString(.finishedAt)
        range = c.dvValue(.range)
        rehearsal = c.dvBool(.rehearsal)
    }
}

struct DVJob: Decodable, Identifiable {
    let id: String
    let name: String?
    let bytes: Int?
    let state: String
    let source: String?
    let seconds: Double?
    let stage: String?
    let progress: Double?
    let etaSeconds: Double?
    let error: String?
    let settings: DVSettings?
    let costUSD: Double?
    let runCostUSD: Double?
    let setAsideUSD: Double?
    let estimatedUSD: Double?
    let outputSeconds: Double?
    let descriptions: Int?
    let skipped: Int?
    let failedSections: Int?
    let sections: Int?
    let done: Int?
    let resumable: Bool?
    let abandonable: Bool?
    let finishable: Bool?
    let retryableSections: DVSectionList?
    let copies: [DVCopy]?
    let version: Int?
    let kind: String?
    let savedToLibrary: DVFlag?
    let createdAt: String?
    let finishedAt: String?
    let expiresAt: String?
    let cancelRequested: Bool?
    let cancelStuck: Bool?
    let uploadedBytes: Int?
    let queuePosition: Double?
    let sourcePrivate: Bool?
    let sourceGrownUps: Bool?
    let sourceOwner: String?
    let range: DVRange?
    let preview: Bool?
    // Round 2 (ROUND2.md): each only when the server says so.
    /// A finished copy whose end date can move on by 7 days.
    let keepable: Bool?
    /// A check that was interrupted and can be run again for free.
    let recheckable: Bool?
    /// Stopped because it was costing more than quoted.
    let overQuote: Bool?
    /// The most this run was allowed to spend (the quote she was shown).
    let approvedUSD: Double?
    /// The suggested Library folder (the Audio mirror of the original's shelf).
    let libraryPath: String?
    /// A Library import that found a video she already has.
    let existing: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, bytes, state, source, seconds, stage, progress, etaSeconds, error
        case settings, costUSD, runCostUSD, setAsideUSD, estimatedUSD, outputSeconds
        case descriptions, skipped, failedSections, sections, done, resumable, abandonable
        case finishable, retryableSections, copies, version, kind, savedToLibrary, createdAt
        case finishedAt, expiresAt, cancelRequested, cancelStuck, uploadedBytes, queuePosition
        case sourcePrivate, sourceGrownUps, sourceOwner, range, preview
        case keepable, recheckable, overQuote, approvedUSD, libraryPath, existing
    }

    var title: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Untitled video" : n
    }

    /// Checking, importing or describing: the server is busy with it.
    var isWorking: Bool { ["checking", "importing", "reserving", "queued", "running"].contains(state) }
    /// Worth asking about again soon.
    var needsWatching: Bool { isWorking || state == "deleting" }
    /// Stopped for going over the price she agreed to, and can carry on.
    var stoppedOverQuote: Bool { state == "failed" && overQuote == true && resumable == true }
    /// A check that was cut short, which can be run again for free.
    var canRecheck: Bool { state == "failed" && recheckable == true }

    /// The finished copies, oldest first. An older server that kept one copy
    /// on the job itself still gets a version to play.
    var finishedCopies: [DVCopy] {
        if let copies, !copies.isEmpty { return copies }
        guard state == "done" else { return [] }
        return [DVCopy(
            version: version ?? 1,
            preview: preview,
            settings: settings,
            outputSeconds: outputSeconds,
            count: descriptions,
            skipped: skipped,
            failedSections: failedSections,
            savedToLibrary: savedToLibrary,
            finishedAt: finishedAt,
            range: range,
            rehearsal: nil
        )]
    }

    /// How many parts could not be described and can be tried again.
    var retryableCount: Int { retryableSections?.count ?? 0 }

    /// The list's words for its state (the website's own).
    var stateWord: String {
        switch state {
        case "uploading": return "upload not finished"
        case "checking": return "checking the video"
        case "importing": return "importing"
        case "ready": return "ready to describe"
        case "reserving", "queued":
            return stage == "Continuing after a server restart" ? "continuing after a server restart" : "waiting for its turn"
        case "running": return "describing, \(Int((progress ?? 0).rounded())) percent"
        case "done": return preview == true ? "preview finished" : "finished"
        case "failed":
            if overQuote == true { return "stopped, costing more than quoted" }
            if recheckable == true { return "check interrupted" }
            return "stopped"
        case "cancelled": return "cancelled"
        case "deleting": return "being deleted"
        case "": return "state not known"
        default: return state
        }
    }
}

extension DVJob {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.dvString(.id), !key.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: "A video without an id."
            ))
        }
        id = key
        name = c.dvString(.name)
        bytes = c.dvInt(.bytes)
        state = c.dvString(.state) ?? ""
        source = c.dvString(.source)
        seconds = c.dvNumber(.seconds)
        stage = c.dvString(.stage)
        progress = c.dvNumber(.progress).map { $0.isFinite ? min(100, max(0, $0)) : 0 }
        etaSeconds = c.dvNumber(.etaSeconds)
        error = c.dvString(.error)
        settings = c.dvValue(.settings)
        costUSD = c.dvNumber(.costUSD)
        runCostUSD = c.dvNumber(.runCostUSD)
        setAsideUSD = c.dvNumber(.setAsideUSD)
        estimatedUSD = c.dvNumber(.estimatedUSD)
        outputSeconds = c.dvNumber(.outputSeconds)
        descriptions = c.dvInt(.descriptions)
        skipped = c.dvInt(.skipped)
        failedSections = c.dvInt(.failedSections)
        sections = c.dvInt(.sections)
        done = c.dvInt(.done)
        resumable = c.dvBool(.resumable)
        abandonable = c.dvBool(.abandonable)
        finishable = c.dvBool(.finishable)
        retryableSections = c.dvValue(.retryableSections)
        copies = c.dvValue(.copies)
        version = c.dvInt(.version)
        kind = c.dvString(.kind)
        savedToLibrary = c.dvValue(.savedToLibrary)
        createdAt = c.dvString(.createdAt)
        finishedAt = c.dvString(.finishedAt)
        expiresAt = c.dvString(.expiresAt)
        cancelRequested = c.dvBool(.cancelRequested)
        cancelStuck = c.dvBool(.cancelStuck)
        uploadedBytes = c.dvInt(.uploadedBytes)
        queuePosition = c.dvNumber(.queuePosition)
        sourcePrivate = c.dvBool(.sourcePrivate)
        sourceGrownUps = c.dvBool(.sourceGrownUps)
        sourceOwner = c.dvString(.sourceOwner)
        range = c.dvValue(.range)
        preview = c.dvBool(.preview)
        keepable = c.dvBool(.keepable)
        recheckable = c.dvBool(.recheckable)
        overQuote = c.dvBool(.overQuote)
        approvedUSD = c.dvNumber(.approvedUSD)
        libraryPath = c.dvString(.libraryPath)
        existing = c.dvBool(.existing)
    }
}

struct DVJobList: Decodable {
    let jobs: [DVJob]
    let remainingUSD: Double?

    private enum CodingKeys: String, CodingKey { case jobs, remainingUSD }
    /// One unreadable row must not hide every other video.
    private struct Maybe: Decodable {
        let job: DVJob?
        init(from decoder: Decoder) throws { job = try? DVJob(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows: [Maybe] = c.dvValue(.jobs) ?? []
        jobs = rows.compactMap { $0.job }
        remainingUSD = c.dvNumber(.remainingUSD)
    }
}

struct DVEstimate: Decodable, Equatable {
    struct Breakdown: Decodable, Equatable {
        let vision: Double?
        let speech: Double?
        let dialogue: Double?
        let closeLook: Double?
        let firstLook: Double?

        enum CodingKeys: String, CodingKey { case vision, speech, dialogue, closeLook, firstLook }
    }
    let estimateUSD: Double?
    let setAsideUSD: Double?
    let remainingUSD: Double?
    let dailyUSD: Double?
    let billingMode: String?
    let limitUSD: Double?
    let allowed: Bool?
    let reason: String?
    let seconds: Double?
    let breakdown: Breakdown?
    /// Round 2, action resume after an over-quote stop: the new approval it
    /// would ask for (the website reads either name).
    let allowUpToUSD: Double?
    let approvedUSD: Double?
    /// True when dialogue timing is included, like narration. Absent on
    /// older servers.
    let dialogueIncluded: Bool?

    enum CodingKeys: String, CodingKey {
        case estimateUSD, setAsideUSD, remainingUSD, dailyUSD, limitUSD, allowed, reason, billingMode
        case seconds, breakdown, allowUpToUSD, approvedUSD, dialogueIncluded
    }

    var isAllowed: Bool { allowed ?? true }
}

extension DVEstimate.Breakdown {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vision = c.dvNumber(.vision)
        speech = c.dvNumber(.speech)
        dialogue = c.dvNumber(.dialogue)
        closeLook = c.dvNumber(.closeLook)
        firstLook = c.dvNumber(.firstLook)
    }
}

extension DVEstimate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        estimateUSD = c.dvNumber(.estimateUSD)
        setAsideUSD = c.dvNumber(.setAsideUSD)
        remainingUSD = c.dvNumber(.remainingUSD)
        dailyUSD = c.dvNumber(.dailyUSD)
        billingMode = c.dvString(.billingMode)
        limitUSD = c.dvNumber(.limitUSD)
        allowed = c.dvBool(.allowed)
        reason = c.dvString(.reason)
        seconds = c.dvNumber(.seconds)
        breakdown = c.dvValue(.breakdown)
        allowUpToUSD = c.dvNumber(.allowUpToUSD)
        approvedUSD = c.dvNumber(.approvedUSD)
        dialogueIncluded = c.dvBool(.dialogueIncluded)
    }
}

struct DVFiles: Decodable {
    let video: String?
    let videoDownload: String?
    let audio: String?
    let audioDownload: String?
    let transcript: String?
    let transcriptDownload: String?
    let captions: String?
    let captionsDownload: String?
    let descriptions: String?
    let descriptionsDownload: String?
    let script: String?
    let scriptDownload: String?

    enum CodingKeys: String, CodingKey {
        case video, videoDownload, audio, audioDownload, transcript, transcriptDownload
        case captions, captionsDownload, descriptions, descriptionsDownload, script, scriptDownload
    }
}

extension DVFiles {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        video = c.dvString(.video)
        videoDownload = c.dvString(.videoDownload)
        audio = c.dvString(.audio)
        audioDownload = c.dvString(.audioDownload)
        transcript = c.dvString(.transcript)
        transcriptDownload = c.dvString(.transcriptDownload)
        captions = c.dvString(.captions)
        captionsDownload = c.dvString(.captionsDownload)
        descriptions = c.dvString(.descriptions)
        descriptionsDownload = c.dvString(.descriptionsDownload)
        script = c.dvString(.script)
        scriptDownload = c.dvString(.scriptDownload)
    }
}

struct DVLibrarySaved: Decodable {
    let savedToLibrary: DVFlag?
    let path: String?

    enum CodingKeys: String, CodingKey { case savedToLibrary, path }
}

extension DVLibrarySaved {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedToLibrary = c.dvValue(.savedToLibrary)
        path = c.dvString(.path)
    }
}

/// POST uploads: the video (new, or the same one again with where its upload
/// had got to) and the chunk size.
struct DVUploadStart: Decodable {
    let job: DVJob
    let chunkBytes: Int?

    enum CodingKeys: String, CodingKey { case job, chunkBytes }
}

extension DVUploadStart {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = try c.decode(DVJob.self, forKey: .job)
        chunkBytes = c.dvInt(.chunkBytes)
    }
}

/// POST api/auth/refresh.
private struct DVRefreshed: Decodable {
    let token: String
}

// MARK: - The service

@MainActor
final class DescribedVideoService: ObservableObject {
    struct DescribedVideoError: LocalizedError {
        let message: String
        var status: Int = 0
        var errorDescription: String? { message }
    }

    private static let base = "api/kade/described-video/"
    private let client: KadeAPIClient
    /// YouTube import ids by link, so pressing Import twice on one link
    /// recovers the first import instead of starting a second.
    private var importIds: [String: String] = [:]

    init(client: KadeAPIClient) {
        self.client = client
    }

    static func newRequestId() -> String {
        UUID().uuidString
    }

    // MARK: Plumbing

    private func decodeError(_ data: Data, status: Int, fallback: String) -> DescribedVideoError {
        struct E: Decodable { let error: String? }
        let text = (try? JSONDecoder().decode(E.self, from: data))?.error ?? ""
        return DescribedVideoError(message: text.isEmpty ? fallback : text, status: status)
    }

    private func makeRequest(_ path: String, method: String, body: [String: Any]?, query: [URLQueryItem]?, timeout: TimeInterval) throws -> URLRequest {
        var req = client.request(path: Self.base + path, method: method, authorized: true, queryItems: query, timeout: timeout)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// One refresh in flight for every caller (a poll, a price and an upload
    /// chunk can all meet an expired token at once), and none again for a
    /// minute after one failed: a signed-out phone must not ask twice every
    /// five seconds while it polls.
    private static var refreshing: Task<Bool, Never>?
    private static var refreshFailedAt = Date.distantPast

    /// A long upload can outlive the access token. One quiet refresh through
    /// the httpOnly cookie (the same call AuthService makes at launch), then
    /// the request is built again with the new token.
    private func refreshToken() async -> Bool {
        if let running = Self.refreshing { return await running.value }
        guard Date().timeIntervalSince(Self.refreshFailedAt) > 60 else { return false }
        let client = self.client
        let task = Task<Bool, Never> {
            let req = client.request(path: "api/auth/refresh", method: "POST")
            guard let (data, http) = try? await client.send(req), http.statusCode == 200,
                  let fresh = try? JSONDecoder().decode(DVRefreshed.self, from: data),
                  !fresh.token.isEmpty else { return false }
            Keychain.set(fresh.token, for: .accessToken)
            return true
        }
        Self.refreshing = task
        let ok = await task.value
        Self.refreshing = nil
        if !ok { Self.refreshFailedAt = Date() }
        return ok
    }

    private func exchange(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        query: [URLQueryItem]? = nil,
        timeout: TimeInterval = 60,
        fallback: String
    ) async throws -> Data {
        let first = try makeRequest(path, method: method, body: body, query: query, timeout: timeout)
        var (data, http) = try await client.send(first)
        if http.statusCode == 401, await refreshToken() {
            let again = try makeRequest(path, method: method, body: body, query: query, timeout: timeout)
            (data, http) = try await client.send(again)
        }
        if http.statusCode == 401 {
            throw DescribedVideoError(message: "Please sign in to Kade-AI again. Anything already running keeps going on the server.", status: 401)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw decodeError(data, status: http.statusCode, fallback: fallback)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DescribedVideoError(message: "The describer sent an answer this app could not read. Try again, or use the website.")
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil, fallback: String) async throws -> T {
        let data = try await exchange(path, query: query, fallback: fallback)
        return try decode(data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any] = [:], timeout: TimeInterval = 60, fallback: String) async throws -> T {
        let data = try await exchange(path, method: "POST", body: body, timeout: timeout, fallback: fallback)
        return try decode(data)
    }

    // MARK: Reading

    func config() async throws -> DVConfig {
        try await get("config", fallback: "Couldn't open the video describer.")
    }

    // MARK: Narrator choices

    /// The voice her new videos start with. Answers her choices as saved.
    func setDefaultVoice(_ voice: String) async throws -> DVPrefs {
        try await post("prefs/default", body: ["voice": voice], fallback: "Couldn't save your default narrator. Try again.")
    }

    /// Adds a voice to My favourites, or takes it off. A full list answers
    /// with the server's own words ("Remove one first").
    func setFavorite(_ voice: String, on: Bool) async throws -> DVPrefs {
        try await post("prefs/favorites", body: ["voice": voice, "favorite": on], fallback: "Couldn't change your favourite narrators. Try again.")
    }

    /// Her speeds, saved for her account. Only the ones passed change.
    func setSpeeds(rate: Double? = nil, maxRate: Double? = nil, playbackRate: Double? = nil) async throws -> DVPrefs {
        var body: [String: Any] = [:]
        if let rate { body["rate"] = rate }
        if let maxRate { body["maxRate"] = maxRate }
        if let playbackRate { body["playbackRate"] = playbackRate }
        return try await post("prefs/speeds", body: body, fallback: "Couldn't save your speeds. Try again.")
    }

    func libraryFolders() async throws -> [String] {
        struct Folders: Decodable { let folders: [String]? }
        let answer: Folders = try await get("library-folders", fallback: "Couldn't read your Library folders.")
        return answer.folders ?? []
    }

    func jobs() async throws -> DVJobList {
        try await get("jobs", fallback: "Couldn't load your videos.")
    }

    func job(_ id: String) async throws -> DVJob {
        try await get("jobs/\(id)", fallback: "Couldn't read that video.")
    }

    func files(jobId: String, version: Int) async throws -> DVFiles {
        try await get("jobs/\(jobId)/files", query: [URLQueryItem(name: "version", value: String(version))], fallback: "Couldn't get the playback links. Try again.")
    }

    /// transcript, captions, descriptions or script, as plain text.
    func text(jobId: String, kind: String, version: Int) async throws -> String {
        let data = try await exchange(
            "jobs/\(jobId)/text/\(kind)",
            query: [URLQueryItem(name: "version", value: String(version))],
            timeout: 60,
            fallback: "That text is not available for this copy."
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Choosing a video

    /// The recovery keys of the files uploading now, for every screen.
    private static var uploadingKeys: Set<String> = []

    /// Upload one file in the server's chunk size, straight from disk (one
    /// chunk in memory at a time), then ask the server to check it.
    ///
    /// `recoveryKey` names the file (name, size, date). The request id saved
    /// under it makes the server hand back the SAME job when the same file is
    /// picked again, with `uploadedBytes` saying where to carry on.
    func upload(
        fileURL: URL,
        name: String,
        recoveryKey: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> DVJob {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else { throw DescribedVideoError(message: "That video could not be read. Try choosing it again.") }
        let defaults = UserDefaults.standard
        let key = "kade.describedVideo.upload." + recoveryKey
        // One file never uploads twice at once: the saved request id would
        // send two loops of chunks to the same video.
        guard !Self.uploadingKeys.contains(key) else {
            throw DescribedVideoError(message: "That video is already uploading.")
        }
        Self.uploadingKeys.insert(key)
        defer { Self.uploadingKeys.remove(key) }
        var requestId = defaults.string(forKey: key) ?? Self.newRequestId()
        defaults.set(requestId, forKey: key)
        let cleanName = String(name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(240))

        var started: DVUploadStart = try await post(
            "uploads",
            body: ["requestId": requestId, "name": cleanName, "bytes": size],
            fallback: "The upload could not start. Try again."
        )
        if ["failed", "cancelled", "done"].contains(started.job.state) {
            requestId = Self.newRequestId()
            defaults.set(requestId, forKey: key)
            started = try await post(
                "uploads",
                body: ["requestId": requestId, "name": cleanName, "bytes": size],
                fallback: "The upload could not start. Try again."
            )
        }
        var job = started.job
        if job.state == "uploading" {
            let chunk = max(1024 * 1024, started.chunkBytes ?? 8 * 1024 * 1024)
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let arrived = min(max(0, job.uploadedBytes ?? 0), size)
            var offset = (arrived / chunk) * chunk
            onProgress(Double(offset) / Double(size))
            while offset < size {
                try Task.checkCancellation()
                let length = min(chunk, size - offset)
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: length) ?? Data()
                guard data.count == length else {
                    throw DescribedVideoError(message: "The video changed while it was uploading. Choose it again to start over.")
                }
                job = try await sendChunk(jobId: job.id, part: offset / chunk + 1, data: data, done: offset, total: size, onProgress: onProgress)
                offset += length
            }
        }
        onProgress(1)
        job = try await post("jobs/\(job.id)/prepare", fallback: "The upload is incomplete. Choose the same video again to carry on.")
        defaults.removeObject(forKey: key)
        return job
    }

    /// One chunk, three tries with a short wait between them. Only a dropped
    /// connection, a timeout or a busy server is tried again; a refusal (the
    /// wrong file, an upload that is no longer open) stops at once. An expired
    /// token is refreshed once per chunk, never in a loop.
    private func sendChunk(
        jobId: String,
        part: Int,
        data: Data,
        done: Int,
        total: Int,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> DVJob {
        let length = data.count
        var lastError = DescribedVideoError(message: "The upload connection keeps dropping. Choose the same video again to carry on from where it stopped.")
        var refreshed = false
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
            }
            var req = client.request(path: Self.base + "jobs/\(jobId)/chunks", method: "POST", authorized: true, timeout: 180)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(part), forHTTPHeaderField: "X-Part-Number")
            let delegate = UploadProgressDelegate { fraction in
                onProgress((Double(done) + fraction * Double(length)) / Double(total))
            }
            let session = client.makeAuxiliarySession(delegate: delegate, timeout: 180)
            await client.awaitPacingGate()
            let answer: (Data, URLResponse)
            do {
                answer = try await session.upload(for: req, from: data)
                session.finishTasksAndInvalidate()
            } catch {
                session.invalidateAndCancel()
                if Task.isCancelled { throw CancellationError() }
                continue
            }
            let body = answer.0
            guard let http = answer.1 as? HTTPURLResponse else { continue }
            if http.statusCode == 401 {
                if !refreshed, await refreshToken() {
                    refreshed = true
                    continue
                }
                throw DescribedVideoError(message: "Please sign in again, then choose the same video to carry on.", status: 401)
            }
            if (200..<300).contains(http.statusCode) {
                return try decode(body)
            }
            let refusal = decodeError(body, status: http.statusCode, fallback: "The upload did not complete. Choose the same video again to carry on.")
            if [408, 429, 500, 502, 503, 504].contains(http.statusCode) {
                lastError = refusal
                continue
            }
            throw refusal
        }
        throw lastError
    }

    func importYouTube(url: String) async throws -> DVJob {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var requestId = importIds[link] ?? Self.newRequestId()
        importIds[link] = requestId
        var job: DVJob = try await post("imports", body: ["url": link, "requestId": requestId], fallback: "That YouTube video could not be imported.")
        if ["failed", "cancelled", "done"].contains(job.state) {
            requestId = Self.newRequestId()
            importIds[link] = requestId
            job = try await post("imports", body: ["url": link, "requestId": requestId], fallback: "That YouTube video could not be imported.")
        }
        return job
    }

    /// A Library video she already has comes back as that video, with
    /// `existing` true, instead of a second copy.
    func importLibrary(book: String, track: Int) async throws -> DVJob {
        try await post(
            "library-imports",
            body: ["book": book, "track": track, "requestId": Self.newRequestId()],
            fallback: "That Library video could not be checked."
        )
    }

    /// Check a video again after its check was interrupted. Free.
    func recheck(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/recheck", fallback: "Couldn't check it again. Try again.")
    }

    // MARK: Spending

    /// action: start, preview, resume, finish or redo. The price is the
    /// server's, never a formula on the phone.
    func estimate(jobId: String, action: String, settings: [String: Any]?, sections: [Int]? = nil) async throws -> DVEstimate {
        var body: [String: Any] = ["action": action]
        if let settings { body["settings"] = settings }
        if let sections, !sections.isEmpty { body["sections"] = sections }
        return try await post("jobs/\(jobId)/estimate", body: body, fallback: "Couldn't work out the price. Try again.")
    }

    func start(jobId: String, settings: [String: Any], preview: Bool) async throws -> DVJob {
        var body = settings
        if preview { body["preview"] = true }
        return try await post("jobs/\(jobId)/start", body: body, fallback: "That could not start. Nothing was spent.")
    }

    /// Continue a preview to the whole part.
    func finish(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/finish", fallback: "That could not start. Nothing was spent.")
    }

    /// Carry on from where it stopped. The voice fields may change. After an
    /// over-quote stop, `allowUpToUSD` raises what this run may spend, once.
    func resume(jobId: String, voiceFields: [String: Any], allowUpToUSD: Double? = nil) async throws -> DVJob {
        var body = voiceFields
        if let allowUpToUSD { body["allowUpToUSD"] = allowUpToUSD }
        return try await post("jobs/\(jobId)/resume", body: body, fallback: "That could not carry on. Try again.")
    }

    /// Back to the last finished version after a stopped remake.
    func abandon(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/abandon", fallback: "Couldn't go back to the earlier version.")
    }

    /// Describe again only the parts that could not be described.
    func redo(jobId: String, expectedVersion: Int) async throws -> DVJob {
        try await post("jobs/\(jobId)/redo", body: ["expectedVersion": expectedVersion], fallback: "Couldn't try those parts again.")
    }

    func cancel(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/cancel", fallback: "Couldn't cancel. Try again.")
    }

    func rename(jobId: String, name: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/rename", body: ["name": name], fallback: "Couldn't rename it.")
    }

    /// A finished video kept 7 more days (at most 30 from today). Free.
    func keep(jobId: String) async throws -> DVJob {
        try await post("jobs/\(jobId)/keep", fallback: "Couldn't keep it longer. Try again.")
    }

    func delete(jobId: String) async throws {
        _ = try await exchange("jobs/\(jobId)", method: "DELETE", fallback: "Couldn't delete it. Try again.")
    }

    func saveToLibrary(jobId: String, version: Int, path: String, share: Bool) async throws -> DVLibrarySaved {
        try await post(
            "jobs/\(jobId)/library",
            body: ["version": version, "path": path, "share": share],
            timeout: 180,
            fallback: "Couldn't save it to your Library. Try again."
        )
    }

    /// A few seconds of the narrator, as WAV bytes. Included with narration.
    func sample(voice: String, rate: Double, text: String? = nil) async throws -> Data {
        var body: [String: Any] = ["voice": voice, "rate": rate]
        if let text, !text.isEmpty { body["text"] = String(text.prefix(200)) }
        let data = try await exchange("sample", method: "POST", body: body, timeout: 90, fallback: "The sample could not be made. Try again.")
        guard !data.isEmpty else { throw DescribedVideoError(message: "The sample came back empty. Try again.") }
        return data
    }

    // MARK: Saving files

    /// A finished file (a signed storage link) saved to a temp file named for
    /// the video, for the share sheet. Streams to disk, so a long film never
    /// sits in memory.
    func download(from link: String, fileName: String) async throws -> URL {
        guard let url = URL(string: link) else { throw DescribedVideoError(message: "That download link is not valid. Try again.") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let session = client.makeAuxiliarySession(delegate: DescribedVideoSessionDelegate(), timeout: 120)
        defer { session.finishTasksAndInvalidate() }
        await client.awaitPacingGate()
        let (temporary, response) = try await session.download(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw DescribedVideoError(message: "The file could not be fetched. Refresh the links and try again.")
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    /// Text already in hand, as a file for the share sheet.
    func textFile(_ text: String, fileName: String) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: target)
        try Data(text.utf8).write(to: target, options: .atomic)
        return target
    }

    /// A name a person would recognise in Files: the video's own name.
    static func fileName(_ title: String, label: String, ext: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty ? "Described video" : String(cleaned.prefix(60))
        return "\(stem) (\(label)).\(ext)"
    }

    // MARK: Lock-screen cards
    //
    // A job outlives the screen: she can leave while it describes, the server
    // keeps going, and the screen picks it back up next time. The card ids live
    // on the TYPE, filed under the job, so a later visit moves the same card on
    // instead of starting a second beside it (the Sound Booth's rule).

    private struct Card { let id: String; var status: String; var progress: Double? }
    private static var cards: [String: Card] = [:]

    /// Starts the job's card, or moves it on when the words change or known
    /// progress moves a tenth or more.
    func showCard(jobId: String, title: String, status: String, progress: Double?) {
        if var card = Self.cards[jobId] {
            let moved = progress.map { abs($0 - (card.progress ?? 0)) >= 0.1 } ?? false
            guard status != card.status || moved else { return }
            card.status = status
            card.progress = progress
            Self.cards[jobId] = card
            KadeJobActivity.update(card.id, status: status, progress: progress)
            return
        }
        guard let id = KadeJobActivity.start(kind: "described-video", title: title, status: status, progress: progress) else { return }
        Self.cards[jobId] = Card(id: id, status: status, progress: progress)
    }

    func endCard(jobId: String, status: String, failed: Bool = false) {
        guard let card = Self.cards.removeValue(forKey: jobId) else { return }
        KadeJobActivity.finish(card.id, status: status, failed: failed)
    }

    /// A job that ended while the screen was closed still has its card up;
    /// the list says how it ended.
    func settleCards(with jobs: [DVJob]) {
        for key in Array(Self.cards.keys) {
            guard let job = jobs.first(where: { $0.id == key }) else { continue }
            if job.isWorking { continue }
            switch job.state {
            case "done": endCard(jobId: key, status: "Ready to watch")
            case "ready": endCard(jobId: key, status: "Checked and ready")
            case "cancelled": endCard(jobId: key, status: "Stopped", failed: true)
            case "uploading": endCard(jobId: key, status: "Upload paused", failed: true)
            default: endCard(jobId: key, status: job.overQuote == true ? "Stopped: costing more than quoted" : "Didn't finish", failed: true)
            }
        }
    }
}

/// The download session needs a delegate object; it has nothing to say.
final class DescribedVideoSessionDelegate: NSObject, URLSessionDelegate {}
