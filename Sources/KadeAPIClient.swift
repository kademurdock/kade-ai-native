import Foundation
import Combine

/// Shared HTTP plumbing for every call this app makes to kademurdock.com.
///
/// Centralizing this (rather than letting each service own its own session)
/// matters for one concrete reason: the site's anti-abuse system paces by
/// ACCOUNT, not by endpoint. If AuthService and ConversationsService each
/// tracked "last request at" independently, an auth refresh firing at the
/// same moment as a conversation-list fetch would look like two unpaced
/// callers to the server even though each individually thought it was being
/// polite. One session, one clock, one pacing gate — this is the thing that
/// tripped the abuse system once before per the project notes, so it's
/// worth being strict about here.
@MainActor
final class KadeAPIClient: ObservableObject {
    let baseURL = URL(string: "https://kademurdock.com")!
    private let session: URLSession
    private let minGap: TimeInterval = 1.5
    private var lastRequestAt: Date = .distantPast
    #if DEBUG && targetEnvironment(simulator)
    private(set) static var hostAuditBlockedRequestCount = 0
    #endif

    /// The full-screen local layout fixture never talks to a live account,
    /// including incidental requests from ordinary screen observers.
    private func rejectOfflineHostRequest() throws {
        #if DEBUG && targetEnvironment(simulator)
        if CharacterDellaHostAudit.isEnabled || CharacterPuppetCompletionAudit.isEnabled {
            Self.hostAuditBlockedRequestCount += 1
            throw URLError(.cancelled)
        }
        #endif
    }

    private static let browserUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// The one configuration. Everything that talks to kademurdock.com is
    /// built from this, so the browser UA and the shared cookie jar can never
    /// be half-applied by a caller that rolled its own.
    private static func baseConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared   // persists the refresh cookie
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = ["User-Agent": Self.browserUA]
        return config
    }

    init() {
        self.session = URLSession(configuration: Self.baseConfiguration())
    }

    /* ⭐ PART 98.4 — WHY A SECOND SESSION EXISTS AT ALL, AND WHY IT IS BUILT
     * HERE INSTEAD OF WHEREVER IT IS NEEDED.
     *
     * The streamed voice lane needs DELEGATE-driven delivery: it wants each
     * chunk of audio the moment it lands, and `URLSession.AsyncBytes` (what
     * streamBytes hands back) yields ONE BYTE at a time — the wrong shape for
     * a quarter-megabyte of PCM on the main actor.
     *
     * Part 98 built that session inline in StreamingClipPlayer with a bare
     * `URLSessionConfiguration.default`, which meant no browser UA — and the
     * comment at the top of this file already said what happens then: the
     * abuse system refuses the request. It did. EVERY streamed synthesis her
     * phone attempted was rejected before it reached the fork (the proxy
     * logged zero of them across two builds), fell back to the buffered path,
     * and cost her a failed round trip on every piece — heard as "3 or 4
     * seconds between every couple sentences."
     *
     * So the config comes from here now, and the caller also takes the pacing
     * gate below. One session's worth of manners, however many sessions exist. */
    func makeAuxiliarySession(delegate: URLSessionDelegate, timeout: TimeInterval = 30) -> URLSession {
        let config = Self.baseConfiguration()
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// The pacing clock, for a caller that sends on its own session. Auth
    /// calls, data calls and the streamed voice lane all wait on the same one
    /// — that is the whole point of the note at the top of this file.
    func awaitPacingGate() async {
        await waitForPacingGate()
    }

    /// How long a send started right now would wait at the pacing gate.
    /// Read-only. The Clubhouse library player (Sep 29 2026) starts its
    /// round-trip clock after this wait, so the gate is not mistaken for
    /// network delay when it lines the room's timeline up.
    var pacingWaitRemaining: TimeInterval {
        max(0, minGap - Date().timeIntervalSince(lastRequestAt))
    }

    /// The one choke point every buffered request goes through: enforce the
    /// pacing gate, then send. Auth calls and data calls share the same
    /// clock. See `streamBytes(_:)` for the long-lived-connection variant
    /// that shares this same gate and session.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try rejectOfflineHostRequest()
        await waitForPacingGate()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // IOS-15: an access token that expired mid-session gets one shared
        // refresh and one retry, instead of "Didn't get a reply".
        guard http.statusCode == 401,
              let retry = await requestWithFreshToken(request) else { return (data, http) }
        try Task.checkCancellation()
        await waitForPacingGate()
        let (data2, response2) = try await session.data(for: retry)
        guard let http2 = response2 as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data2, http2)
    }

    /// Only attachment uploads get a total-transfer deadline. Keep the same
    /// account pacing, cookies and browser UA without shortening chat streams
    /// or the other tools' legitimate long-running requests.
    func sendUpload(_ request: URLRequest, resourceTimeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try rejectOfflineHostRequest()
        try Task.checkCancellation()
        await waitForPacingGate()
        try Task.checkCancellation()
        let config = Self.baseConfiguration()
        config.timeoutIntervalForResource = resourceTimeout
        let uploadSession = URLSession(configuration: config)
        defer { uploadSession.invalidateAndCancel() }
        let (data, response) = try await uploadSession.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // IOS-15: one shared refresh and one retry after a 401.
        guard http.statusCode == 401,
              let retry = await requestWithFreshToken(request) else { return (data, http) }
        try Task.checkCancellation()
        await waitForPacingGate()
        let (data2, response2) = try await uploadSession.data(for: retry)
        try Task.checkCancellation()
        guard let http2 = response2 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data2, http2)
    }

    /// Same pacing gate and session as `send(_:)`, but for a long-lived
    /// Server-Sent-Events connection where buffering the full body first
    /// isn't an option — hands back the raw byte stream instead. Added for
    /// Phase 3 (chat send + stream); every other call still goes through
    /// `send(_:)`.
    func streamBytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try rejectOfflineHostRequest()
        await waitForPacingGate()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        // IOS-15: one shared refresh and one retry after a 401.
        guard http.statusCode == 401,
              let retry = await requestWithFreshToken(request) else { return (bytes, http) }
        bytes.task.cancel()               // the 401 connection is no use to anyone
        try Task.checkCancellation()
        await waitForPacingGate()
        let (bytes2, response2) = try await session.bytes(for: retry)
        guard let http2 = response2 as? HTTPURLResponse else {
            bytes2.task.cancel()
            throw URLError(.badServerResponse)
        }
        return (bytes2, http2)
    }

    // MARK: - One refresh for the whole app (IOS-15, Nov 12 2026 audit)

    /// What a refresh came to. `refreshed` carries the response body so
    /// AuthService can read the user out of it.
    enum RefreshOutcome {
        case refreshed(Data)
        case rejected(status: Int)   // the server answered and said no
        case unreachable             // no answer, a transient status, or signed out meanwhile
    }

    private var refreshing: Task<RefreshOutcome, Never>?
    private var refreshBlockedUntil = Date.distantPast
    /// Bumped on sign-out, so a refresh that was in flight cannot put the
    /// session back.
    private var authEpoch = 0
    private struct RefreshBody: Decodable { let token: String }

    /// The ONLY place the app posts api/auth/refresh. The server rotates the
    /// refresh cookie on every call (AuthController.js refreshController), so
    /// two refreshes at once make one of them fail with 401; every caller,
    /// the launch refresh included, shares this one task.
    /// `force` skips the back-off (launch and explicit user actions).
    func refreshSession(force: Bool = false) async -> RefreshOutcome {
        if let running = refreshing { return await running.value }
        if !force, Date() < refreshBlockedUntil { return .unreachable }
        let epoch = authEpoch
        let task = Task<RefreshOutcome, Never> { @MainActor in
            var req = self.request(path: "api/auth/refresh", method: "POST")
            req.timeoutInterval = 15
            await self.waitForPacingGate()
            guard let (data, response) = try? await self.session.data(for: req),
                  let http = response as? HTTPURLResponse else {
                self.refreshBlockedUntil = Date().addingTimeInterval(5)
                return .unreachable
            }
            guard epoch == self.authEpoch else {
                // Signed out while this was in flight: drop what it brought back.
                self.deleteCookies()
                return .unreachable
            }
            if http.statusCode == 200,
               let body = try? JSONDecoder().decode(RefreshBody.self, from: data),
               !body.token.isEmpty {
                Keychain.set(body.token, for: .accessToken)
                self.refreshBlockedUntil = .distantPast
                return .refreshed(data)
            }
            // 200 with a plain string means "no refresh cookie"; 401/403 mean
            // the session is gone. Anything else (429, 5xx) is worth another
            // try soon.
            if http.statusCode == 200 || http.statusCode == 401 || http.statusCode == 403 {
                self.refreshBlockedUntil = Date().addingTimeInterval(60)
                return .rejected(status: http.statusCode)
            }
            self.refreshBlockedUntil = Date().addingTimeInterval(5)
            return .unreachable
        }
        refreshing = task
        let outcome = await task.value
        refreshing = nil
        return outcome
    }

    /// For callers on their own session (the auxiliary sessions) and the
    /// older per-service retry code.
    func refreshAccessToken() async -> Bool {
        if case .refreshed = await refreshSession() { return true }
        return false
    }

    /// After a 401: the same request with a bearer worth trying, or nil when
    /// a retry cannot help. Never for /api/auth/ calls or requests that
    /// carried no bearer.
    private func requestWithFreshToken(_ request: URLRequest) async -> URLRequest? {
        guard let sent = request.value(forHTTPHeaderField: "Authorization"),
              sent.hasPrefix("Bearer "),
              let url = request.url, url.host == baseURL.host,
              !url.path.hasPrefix("/api/auth/") else { return nil }
        if let current = Keychain.string(for: .accessToken), "Bearer \(current)" != sent {
            // Someone refreshed while this request was waiting or in flight:
            // use their token, do not rotate again.
        } else {
            guard case .refreshed = await refreshSession() else { return nil }
        }
        guard let token = Keychain.string(for: .accessToken) else { return nil }
        var retry = request
        retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return retry
    }

    private func waitForPacingGate() async {
        let since = Date().timeIntervalSince(lastRequestAt)
        if since < minGap {
            try? await Task.sleep(nanoseconds: UInt64((minGap - since) * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    /// Builds a request against kademurdock.com with the common headers set.
    /// Pass `authorized: true` to attach the cached Bearer token. `queryItems`
    /// go through URLComponents (NOT string-concatenated onto `path`) —
    /// `appendingPathComponent` percent-encodes `?`/`=`/`&`, so a hand-built
    /// "path?cursor=xyz" string would silently turn into a broken URL.
    func request(
        path: String,
        method: String = "GET",
        authorized: Bool = false,
        queryItems: [URLQueryItem]? = nil,
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if let queryItems, !queryItems.isEmpty,
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = queryItems
            url = comps.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // Session 35 part 5 (build 169's first field report — "failing on a
        // turn"): a per-request timeout for the few calls whose SERVER work
        // legitimately outlives URLSession's 60-second default. Receipts: a
        // six-seat Debate turn under the new room constitution ran 69–93s
        // server-side and LANDED every time — the app just hung up at 60
        // and called it a failure, which also knocked Keep-it-going off.
        // An explicit URLRequest.timeoutInterval overrides the session
        // default for that request only; everything else stays at 60.
        if let timeout {
            req.timeoutInterval = timeout
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if authorized, let token = Keychain.string(for: .accessToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Builds a `multipart/form-data` request — needed for Phase 5's speech
    /// endpoints (`/api/files/speech/stt` takes an uploaded audio file;
    /// `/api/files/speech/tts/manual` takes plain text fields but the fork's
    /// route still parses it with multer's `upload.none()`, which requires
    /// real multipart encoding even with zero file parts, not
    /// `application/x-www-form-urlencoded`). `fields` are sent as plain text
    /// parts in insertion order; pass `fileField`/`fileData`/`fileName`/
    /// `fileMimeType` together to also attach one file part (used for STT's
    /// `audio` field only — nothing here needs more than one file at once).
    func multipartRequest(
        path: String,
        authorized: Bool,
        fields: [(String, String)],
        fileField: String? = nil,
        fileData: Data? = nil,
        fileName: String? = nil,
        fileMimeType: String? = nil
    ) -> URLRequest {
        var req = request(path: path, method: "POST", authorized: authorized)
        let boundary = "KadeAI-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let crlf = "\r\n"

        for (name, value) in fields {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        if let fileField, let fileData, let fileName {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\(crlf)"
                    .data(using: .utf8)!
            )
            body.append("Content-Type: \(fileMimeType ?? "application/octet-stream")\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(fileData)
            body.append(crlf.data(using: .utf8)!)
        }

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        req.httpBody = body
        return req
    }

    /// Clears this host's cookies (used on sign-out so the next sign-in is clean).
    func clearCookies() {
        authEpoch += 1                    // IOS-15: an in-flight refresh must not restore the session
        refreshBlockedUntil = .distantPast
        deleteCookies()
    }

    private func deleteCookies() {
        guard let storage = session.configuration.httpCookieStorage,
              let cookies = storage.cookies(for: baseURL) else { return }
        for c in cookies { storage.deleteCookie(c) }
    }
}
