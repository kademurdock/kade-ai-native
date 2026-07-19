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

/// Talks to kademurdock.com (a LibreChat fork) for auth only. All networking
/// goes through the shared `KadeAPIClient` so auth calls and data calls
/// (conversations, messages, …) share one pacing clock — see KadeAPIClient's
/// doc comment for why that's not optional.
///
/// - The access token + cached user are persisted in the Keychain. The refresh
///   token is an httpOnly cookie the server sets; URLSession's shared cookie
///   storage (owned by KadeAPIClient) persists it across launches.
/// - Fail-soft on launch: if we have a cached user we show "signed in"
///   immediately and refresh the token in the background; a network hiccup
///   never logs the user out, only a real 401 does.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var state: AuthState = .loading

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    /// The current access token, for other services (conversations, streaming).
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
        client.clearCookies()
        state = .signedOut
    }

    // MARK: - Network

    private func postLogin(email: String, password: String) async throws -> KadeUser {
        var req = client.request(path: "api/auth/login", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["email": email, "password": password]
        )
        let (data, http) = try await client.send(req)
        switch http.statusCode {
        case 200:
            let decoded = try decoder.decode(LoginResponse.self, from: data)
            persist(token: decoded.token, user: decoded.user)
            return decoded.user
        // 404 belongs here, not in the generic `default` branch below --
        // confirmed against the fork's own source, not guessed: this route
        // runs through Passport's local strategy (`requireLocalAuth.js`),
        // which replies `res.status(404).send(info)` specifically when the
        // email/password didn't match anything, and 422 for a couple of
        // other rejection messages. Caught live 2026-07-19 (Kade's first
        // real-device sign-in attempt, TestFlight build 105): a failed
        // login surfaced as "The server returned an error (404). Try again
        // in a moment" -- technically true but actively misleading, since
        // it reads like an outage when it's really just a credentials
        // mismatch. Whatever caused THAT particular attempt to fail
        // (typo, autofill, a dropped special character) is unconfirmed --
        // this fix is about the message being wrong regardless of cause.
        case 401, 403, 404, 422:
            throw AuthError.badCredentials
        case 429:
            throw AuthError.rateLimited
        default:
            throw AuthError.server(http.statusCode)
        }
    }

    /// Best-effort token refresh via the httpOnly refresh cookie. Never throws
    /// up to the UI — a failure here only signs the user out on a real 401.
    private func silentRefresh() async {
        let req = client.request(path: "api/auth/refresh", method: "POST")
        guard let (data, http) = try? await client.send(req) else { return }  // offline: stay signed in
        if http.statusCode == 200,
           let decoded = try? decoder.decode(LoginResponse.self, from: data) {
            persist(token: decoded.token, user: decoded.user)
            state = .signedIn(decoded.user)
        } else if http.statusCode == 401 {
            signOut()  // the refresh token is truly gone/expired
        }
        // any other status: leave the optimistic signed-in state alone
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
