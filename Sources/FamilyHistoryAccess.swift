import Foundation
import Combine

// MARK: - Family history: who may open it (Sep 29 2026)
//
// The Library row after Collections is always there (her Sep 25 rule for
// features some accounts cannot use: greyed, never hidden). This decides its
// state from GET /me:
// - open: the account is matched to a person in the tree (or is the owner,
//   or a guest the owner added); the row opens the family's home;
// - locked: refused, greyed, with the server's reason ("Not linked to the
//   tree yet", "Private to one family"); an unmatched account also gets
//   Ask to be added (POST /ask), which then reads "Asked on {date}";
// - unavailable: the site has no family history this app can draw yet.
// The last decisive answer is kept per account, so the family's row is live
// the moment the app opens. It asks again when the Library appears, when
// the app becomes active and on a pull, never twice in half a minute.
// A 503 or a network failure keeps what it had. Losing access (a 403 on any
// family route) wipes the family caches and greys the row at once.

@MainActor
final class FamilyHistoryAccess: ObservableObject {
    static let shared = FamilyHistoryAccess()

    @Published private(set) var state: FamilyAccessState = .unknown
    @Published private(set) var asking = false
    /// The last check could not reach the site (so "Checking" can offer Try again).
    @Published private(set) var checkFailed = false
    @Published private(set) var archives: [FHArchive] = []
    @Published private(set) var selectedArchiveId: String? = nil
    @Published private(set) var switchingArchive = false

    private var lastCheck: Date?
    private var checking = false
    /// Moves on at every sign-out, so an answer asked for by the account that
    /// signed out is never kept for the next one.
    private var generation = 0
    /// The account whose remembered answer `state` came from.
    private var restoredFor: String?

    private init() {}

    var isOpen: Bool { state.isOpen }
    var words: FamilyRowWords { FamilyAccessRules.rowWords(state) }
    var archiveIdentity: String { FamilyArchiveRules.identity(selectedArchiveId) }
    var archiveTitle: String? { archives.first(where: { $0.id == archiveIdentity })?.title }

    // MARK: Accounts

    /// Sign-in (or a restored session): this account's remembered answer.
    func signedIn(userId: String) {
        useArchive(nil)
        archives = []
        FamilySession.shared.bind(userId)
        restore(userId: userId)
    }

    /// Sign-out: nothing is kept in memory for the next account (its
    /// remembered answer stays under its own id). ContentView ends the demo
    /// family when a signed-in account signs out (not at a cold launch that
    /// finds no session, which is how CI starts before its test sign-in).
    func reset() {
        generation += 1
        checking = false
        asking = false
        checkFailed = false
        lastCheck = nil
        restoredFor = nil
        state = .unknown
        archives = []
        switchingArchive = false
        useArchive(nil)
        FamilySession.shared.bind(nil)
    }

    private func restoreIfNeeded() {
        guard let userId = FamilySession.shared.userId,
              restoredFor != FamilyCacheNames.accessKey(userId: userId, archiveId: selectedArchiveId) else { return }
        restore(userId: userId)
    }

    private func restore(userId: String) {
        restoredFor = FamilyCacheNames.accessKey(userId: userId, archiveId: selectedArchiveId)
#if DEBUG
        if FamilyDemo.isOn {
            state = demoState()
            return
        }
#endif
        let key = FamilyCacheNames.accessKey(userId: userId, archiveId: selectedArchiveId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let memo = try? JSONDecoder().decode(FamilyAccessMemo.self, from: data),
              let remembered = FamilyAccessRules.decide(status: memo.status, body: memo.body) else {
            state = .unknown
            return
        }
        state = remembered
    }

    private func remember(status: Int, body: Data) {
        guard let userId = FamilySession.shared.userId else { return }
        let memo = FamilyAccessMemo(status: status, body: body, at: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(memo) else { return }
        UserDefaults.standard.set(data, forKey: FamilyCacheNames.accessKey(userId: userId, archiveId: selectedArchiveId))
    }

    // MARK: Checking

    /// Asks GET /me, unless it was asked less than half a minute ago
    /// (`force` asks anyway: a pull, or Try again).
    func check(client: KadeAPIClient, force: Bool = false) async {
        FamilyHistoryService.shared.bind(client: client)
        if !switchingArchive { restoreIfNeeded() }
#if DEBUG
        if FamilyDemo.isOn {
            state = demoState()
            return
        }
#endif
        guard !checking, FamilyRecheck.due(last: lastCheck, now: Date(), force: force) else { return }
        let asked = generation
        checking = true
        defer {
            if asked == generation { checking = false }
        }
        // The catalog is unscoped and grants no inferred family relationship.
        // A server without this additive endpoint keeps the default behavior.
        if let (catalogData, catalogStatus) = try? await FamilyHistoryService.shared.raw("archives", timeout: 30) {
            guard asked == generation else { return }
            if catalogStatus == 200, let catalog = try? JSONDecoder().decode(FHArchiveCatalog.self, from: catalogData) {
                archives = catalog.archives
                if !archives.contains(where: { $0.id == archiveIdentity }) {
                    useArchive(catalog.defaultArchive ?? archives.first?.id)
                }
            } else if catalogStatus == 404 {
                archives = []
                useArchive(nil)
            }
        }
        guard asked == generation else { return }
        let answer: (Data, Int)
        do {
            answer = try await FamilyHistoryService.shared.raw("me", timeout: 30)
        } catch {
            // A load cut short (a push on top, another tab) is not a failure.
            if asked == generation && !LibraryLoad.cancelled(error) { checkFailed = true }
            return
        }
        // Signed out (and perhaps in as someone else) while it was asked.
        guard asked == generation else { return }
        let data = answer.0
        let status = answer.1
        lastCheck = Date()
        guard let decided = FamilyAccessRules.decide(status: status, body: data) else {
            // 503 while the family history updates, 401, 429, 5xx: keep what we had.
            checkFailed = state == .unknown
            return
        }
        checkFailed = false
        apply(decided, status: status, body: data)
    }

    /// Only an archive returned by the server may be selected. Recheck /me
    /// before displaying any person or source from that archive.
    func selectArchive(_ id: String, client: KadeAPIClient) async {
        guard !switchingArchive, archives.contains(where: { $0.id == id }), id != archiveIdentity else { return }
        generation += 1
        checking = false
        lastCheck = nil
        checkFailed = false
        asking = false
        switchingArchive = true
        useArchive(id)
        let asked = generation
        await check(client: client, force: true)
        if asked == generation { switchingArchive = false }
    }

    private func useArchive(_ id: String?) {
        let wanted = id == FamilyArchiveRules.defaultId ? nil : id
        guard wanted != selectedArchiveId else { return }
        state = .unknown
        selectedArchiveId = wanted
        restoredFor = nil
        FamilyHistoryService.shared.selectArchive(wanted)
    }

    /// A family route answered 403 for a reason that means this account
    /// lost the family history.
    func lost(status: Int, body: Data) {
        guard let decided = FamilyAccessRules.decide(status: status, body: body) else { return }
        lastCheck = Date()
        apply(decided, status: status, body: body)
    }

    private func apply(_ decided: FamilyAccessState, status: Int, body: Data) {
        let wasOpen = state.isOpen
        state = decided
        remember(status: status, body: body)
        if let me = decided.me {
            FamilyHistoryService.shared.noteVersion(me.version)
        } else if wasOpen {
            // Access lost: nothing of the family stays on the phone.
            FamilyHistoryService.shared.reset()
            FamilyImageLoader.shared.wipe()
        }
    }

    // MARK: Ask to be added

    /// POST /ask. Answers the words to say (the server's, else plain ones).
    func ask() async -> String {
        guard case .locked(let locked) = state, locked.mayAsk, !asking else { return "" }
        let asked = generation
        asking = true
        defer {
            if asked == generation { asking = false }
        }
        guard let (data, status) = try? await FamilyHistoryService.shared.raw("ask", method: "POST", body: [:], timeout: 30) else {
            return FamilyFailure.offline.message
        }
        guard asked == generation else { return "" }
        let answer = try? JSONDecoder().decode(FHAsked.self, from: data)
        if (200..<300).contains(status), answer?.ok != false {
            let when = FamilyAccessRules.nonEmpty(answer?.askedAt) ?? FamilyDates.isoNow()
            var updated = locked
            updated.askedAt = when
            state = .locked(updated)
            rememberAsked(when)
            return FamilyAccessRules.nonEmpty(answer?.text) ?? "Asked. The tree's owner will see your request."
        }
        if status == 403 {
            // No longer an account that may ask (matched meanwhile, or declined): look again.
            lastCheck = nil
        }
        return FamilyAccessRules.nonEmpty(answer?.error)
            ?? FamilyFailure.from(status: status, body: data)?.message
            ?? "Could not ask right now. Try again in a little while."
    }

    /// The remembered refusal gains its "asked on" date, so the row still
    /// says so at the next launch.
    private func rememberAsked(_ when: String) {
        guard let userId = FamilySession.shared.userId else { return }
        let key = FamilyCacheNames.accessKey(userId: userId, archiveId: selectedArchiveId)
        guard let data = UserDefaults.standard.data(forKey: key),
              var memo = try? JSONDecoder().decode(FamilyAccessMemo.self, from: data),
              memo.status == 403 else { return }
        memo.body = FamilyAccessRules.withAskedAt(memo.body, askedAt: when)
        if let encoded = try? JSONEncoder().encode(memo) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    // MARK: The made-up family (DEBUG only)

#if DEBUG
    private func demoState() -> FamilyAccessState {
        FamilyAccessRules.decide(status: 200, body: Data(FamilyDemoData.me.utf8)) ?? .unavailable
    }
#endif
}
