import Foundation

/// Alerts — the native home for the nudge half of the web's "Notifications &
/// Reminders" page (`/notifications`), the one genuinely missing piece of the
/// web's four-tab structure identified in the session-17/18 tabs writeup.
/// Server contract read straight off `api/server/routes/kade.js` (the
/// `/nudges/*` routes) at fork rev `6ab48f1`, session 18:
///
///   GET  /api/kade/nudges/prefs   JWT. -> 200 {
///                                   prefs: {reminders, birthday,
///                                     birthdayDate, phone} — the server
///                                     substitutes a default object when the
///                                     user has never saved any, so this is
///                                     never null in practice, but stays
///                                     Optional here anyway (fail-soft),
///                                   pushSubscriptions: Int — count of WEB
///                                     push subscriptions (browser),
///                                   recent: [KadePendingNudge] — newest
///                                     first, capped at 15 server-side:
///                                     {_id, text, type, channel, createdAt,
///                                     deliveredAt|null}. deliveredAt null
///                                     means it is still waiting to ride
///                                     into her next chat.
///                                 }
///   POST /api/kade/nudges/prefs   JWT {reminders?, birthday?, birthdayDate?,
///                                 phone?} -> {ok, prefs}. Channel values
///                                 outside off/chat/push/call are silently
///                                 IGNORED server-side (the CHANNELS gate),
///                                 birthdayDate must be "MM-DD" or "",
///                                 phone is digits-only (10) or cleared.
///   POST /api/kade/nudges/test    JWT {} -> {ok, channel} — fires a real
///                                 test nudge through the user's own prefs
///                                 and answers which channel delivered it.
///
/// Deliberately NOT ported: `/nudges/subscribe`/`unsubscribe` — that pair
/// manages BROWSER (web-push) subscriptions. This app's push is APNs via
/// `PushService`; wiring the browser mechanism in here would register a
/// second, competing push identity for the same account.
@MainActor
final class AlertsService: ObservableObject {
    /// The server's own channel vocabulary, in its own order.
    static let channels = ["off", "chat", "push", "call"]

    /// Spoken/visible labels for the channel keys — by ear, "push" means
    /// nothing; "Phone notification" is what it actually is.
    static func channelLabel(_ key: String) -> String {
        switch key {
        case "off": return "Off"
        case "chat": return "In chat"
        case "push": return "Phone notification"
        case "call": return "Phone call"
        default: return key
        }
    }

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct AlertsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable { let error: String? }

    private func errorMessage(from data: Data, fallback: String) -> String {
        (try? decoder.decode(ServerError.self, from: data))?.error ?? fallback
    }

    func load() async throws -> PrefsResponse {
        let req = client.request(path: "api/kade/nudges/prefs", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw AlertsError(message: errorMessage(from: data, fallback: "Couldn't load your alerts."))
        }
        return try decoder.decode(PrefsResponse.self, from: data)
    }

    func savePrefs(reminders: String, birthday: String, birthdayDate: String, phone: String) async throws {
        var req = client.request(path: "api/kade/nudges/prefs", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "reminders": reminders,
            "birthday": birthday,
            "birthdayDate": birthdayDate,
            "phone": phone,
        ])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw AlertsError(message: errorMessage(from: data, fallback: "Couldn't save your choices."))
        }
    }

    /// Returns the channel the test actually went out on.
    func sendTest() async throws -> String {
        var req = client.request(path: "api/kade/nudges/test", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw AlertsError(message: errorMessage(from: data, fallback: "Couldn't send a test alert."))
        }
        struct TestResponse: Decodable { let channel: String? }
        return (try? decoder.decode(TestResponse.self, from: data))?.channel ?? "chat"
    }
}

struct NudgePrefs: Decodable {
    let reminders: String?
    let birthday: String?
    let birthdayDate: String?
    let phone: String?
}

/// One entry of the server's `recent` list (a `KadePendingNudge` document).
struct RecentNudge: Decodable, Identifiable {
    let _id: String?
    let text: String
    let type: String?
    let channel: String?
    let createdAt: String?
    let deliveredAt: String?
    /// Mongo's `_id` serializes to a string through `res.json`; the fallback
    /// only exists so a hypothetical missing id can't crash Identifiable.
    var id: String { _id ?? text + (createdAt ?? "") }
}

struct PrefsResponse: Decodable {
    let prefs: NudgePrefs?
    let pushSubscriptions: Int?
    let recent: [RecentNudge]?
}
