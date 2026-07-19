import Foundation

/// The signed-in user, decoded from LibreChat's /api/auth/login response.
/// The server sends both `_id` and `id` (same value) plus many extra fields;
/// we decode the handful we actually show and let Codable ignore the rest.
struct KadeUser: Codable, Equatable {
    let id: String
    let email: String
    let name: String?
    let username: String?
    let role: String?

    /// What the UI (and VoiceOver) says after "Signed in as …".
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let u = username, !u.isEmpty { return u }
        return email
    }
}

/// Auth state machine the UI observes. Kept deliberately small.
enum AuthState: Equatable {
    case loading            // restoring a saved session at launch
    case signedOut
    case signingIn
    case signedIn(KadeUser)
    case failed(String)     // human-readable, VoiceOver-announced
}

/// Talks to kademurdock.com (a LibreChat fork) for auth only.
///
/// Design notes:
/// - Sends a real iPhone-Safari User-Agent and paces requests, because the
///   site has an anti-abuse system that temporarily bans callers who hit it
///   fast with a non-browser UA (documented in the project creds file).
/// - The access token + cached user are persisted in the Keychain. The refresh
///   token is an httpOnly cookie the server sets; URLSession's shared cookie
///   storage persists it across launches, so we never touch it by hand.
/// - Fail-soft on launch: if we have a cached user we show "signed in"
///   immediately and refresh the token in the background; a network hiccup
///   never logs the user out, only a real 401 does.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var state: AuthState = .loading

    private let baseURL = URL(string: "https://kademurdock.com")!
    private let session: URLSession
    private let decoder = JSONDecoder()

    // Anti-abuse pacing: never fire two auth requests closer than this.
    private let minGap: TimeInterval = 1.5
    private var lastRequestAt: Date = .distantPast

    private static let browserUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared   // persists the refresh cookie
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = ["User-Agent": AuthService.browserUA]
        self.session = URLSession(configuration: config)
    }

    /// The current access token, for later phases (conversations, streaming).
    var accessToken: String? { Keychain.string(for: .accessToken) }

    // MARK: - Lifecycle

    /// Called once at launch. Restores a cached session, then silently refreshes.
    func restore() async {
        if let data = Keychain.data(for: .user),
           let user = try? decoder.decode(KadeUser.self, from: data) {
            state = .signedIn(user)          // optimistic, offline-tolerant
            await silentRefresh()
        } else {
            state = .signedOut
        }
    }

    // MARK: - Actions

    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            state = .failed("Enter your email and password.")
            return
        }
        state = .signingIn
        do {
            let user = try await postLogin(email: email, password: password)
            state = .signedIn(user)
        } catch let e as AuthError {
            state = .failed(e.message)
        } catch {
            state = .failed("Couldn't reach kademurdock.com. Check your connection and try again.")
        }
    }

    func signOut() {
        Keychain.remove(.accessToken)
        Keychain.remove(.user)
        // Clear the site's cookies so the next sign-in is a clean session.
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: baseURL) {
            for c in cookies { session.configuration.httpCookieStorage?.deleteCookie(c) }
        }
        state = .signedOut
    }

    // MARK: - Network

    private func postLogin(email: String, password: String) async throws -> KadeUser {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/auth/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["email": email, "password": password]
        )
        let (data, response) = try await send(req)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 200:
            let decoded = try decoder.decode(LoginResponse.self, from: data)
            persist(token: decoded.token, user: decoded.user)
            return decoded.user
        case 401, 403, 422:
            throw AuthError.badCredentials
        case 429:
            throw AuthError.rateLimited
        default:
            throw AuthError.server(http?.statusCode ?? -1)
        }
    }

    /// Best-effort token refresh via the httpOnly refresh cookie. Never throws
    /// up to the UI — a failure here only signs the user out on a real 401.
    private func silentRefresh() async {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/auth/refresh"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        guard let (data, response) = try? await send(req),
              let http = response as? HTTPURLResponse else { return }  // offline: stay signed in
        if http.statusCode == 200,
           let decoded = try? decoder.decode(LoginResponse.self, from: data) {
            persist(token: decoded.token, user: decoded.user)
            state = .signedIn(decoded.user)
        } else if http.statusCode == 401 {
            signOut()  // the refresh token is truly gone/expired
        }
        // any other status: leave the optimistic signed-in state alone
    }

    /// One choke point for pacing + UA (UA is also set on the session).
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let since = Date().timeIntervalSince(lastRequestAt)
        if since < minGap {
            try? await Task.sleep(nanoseconds: UInt64((minGap - since) * 1_000_000_000))
        }
        lastRequestAt = Date()
        return try await session.data(for: request)
    }

    private func persist(token: String, user: KadeUser) {
        Keychain.set(token, for: .accessToken)
        // Re-encode the decoded user so the stored blob is exactly what we read back.
        if let encoded = try? JSONEncoder().encode(user) {
            Keychain.set(encoded, for: .user)
        }
    }

    private struct LoginResponse: Codable {
        let token: String
        let user: KadeUser
    }
}

enum AuthError: Error {
    case badCredentials
    case rateLimited
    case server(Int)

    var message: String {
        switch self {
        case .badCredentials:
            return "That email or password didn't work. Double-check and try again."
        case .rateLimited:
            return "Too many attempts right now. Wait a couple of minutes, then try again."
        case .server(let code):
            return "The server returned an error (\(code)). Try again in a moment."
        }
    }
}
