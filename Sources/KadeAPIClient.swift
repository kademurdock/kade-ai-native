import Foundation

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
final class KadeAPIClient {
    let baseURL = URL(string: "https://kademurdock.com")!
    private let session: URLSession
    private let minGap: TimeInterval = 1.5
    private var lastRequestAt: Date = .distantPast

    private static let browserUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared   // persists the refresh cookie
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = ["User-Agent": Self.browserUA]
        self.session = URLSession(configuration: config)
    }

    /// The one choke point every request goes through: enforce the pacing
    /// gate, then send. Auth calls and data calls share the same clock.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let since = Date().timeIntervalSince(lastRequestAt)
        if since < minGap {
            try? await Task.sleep(nanoseconds: UInt64((minGap - since) * 1_000_000_000))
        }
        lastRequestAt = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
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
        queryItems: [URLQueryItem]? = nil
    ) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if let queryItems, !queryItems.isEmpty,
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = queryItems
            url = comps.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if authorized, let token = Keychain.string(for: .accessToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Clears this host's cookies (used on sign-out so the next sign-in is clean).
    func clearCookies() {
        guard let storage = session.configuration.httpCookieStorage,
              let cookies = storage.cookies(for: baseURL) else { return }
        for c in cookies { storage.deleteCookie(c) }
    }
}
