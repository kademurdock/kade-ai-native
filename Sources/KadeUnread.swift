import Foundation
import SwiftUI

/// Sep 23 2026 redesign (B11, "little new badges"). Alerts, Announcements and
/// Agent work say "2 new" when something arrived since you last looked, and
/// VoiceOver hears it in the row's label ("Announcements, 2 new").
///
/// "Since you last looked" is a per-device timestamp per place, set whenever
/// the screen is opened (the root marks it in `go(_:)`, so a push that routes
/// straight there counts too). The first time a place is ever counted, the
/// clock starts NOW — an existing account must not open the new build to
/// "50 new announcements".
///
/// Polite by construction: three small GETs through the shared paced client,
/// at most once every ten minutes, only while signed in; Agent work stops
/// asking for the session the first time the server refuses it.
@MainActor
final class KadeUnread: ObservableObject {
    static let shared = KadeUnread()

    enum Place: String, CaseIterable {
        case alerts, announcements, agentWork
    }

    @Published private(set) var counts: [Place: Int] = [:]
    private var lastRefresh: Date?
    private var refreshing = false
    private var agentWorkRefused = false

    func count(_ place: Place) -> Int { counts[place] ?? 0 }
    var total: Int { Place.allCases.reduce(0) { $0 + count($1) } }

    /// "Announcements" or "Announcements, 2 new" — for accessibility labels.
    func spoken(_ base: String, _ place: Place) -> String {
        let n = count(place)
        return n > 0 ? "\(base), \(n) new" : base
    }

    func markSeen(_ place: Place) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key(place))
        counts[place] = 0
    }

    /// Sign-out: forget the counts (the timestamps stay with the device).
    func reset() {
        counts = [:]
        lastRefresh = nil
        agentWorkRefused = false
    }

    func refresh(client: KadeAPIClient, force: Bool = false) async {
        guard !refreshing else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 600 { return }
        refreshing = true
        defer { refreshing = false }
        lastRefresh = Date()

        if let dates = await fetchDates(client, path: "api/kade/announcements", listKey: "broadcasts", dateKey: "ts") {
            let seen = lastSeen(.announcements)
            counts[.announcements] = dates.filter { $0 > seen }.count
        }
        if let dates = await fetchDates(client, path: "api/kade/nudges/prefs", listKey: "recent", dateKey: "createdAt") {
            let seen = lastSeen(.alerts)
            counts[.alerts] = dates.filter { $0 > seen }.count
        }
        if !agentWorkRefused,
           let dates = await fetchDates(client, path: "api/agents/chat/tasks", listKey: "tasks", dateKey: "createdAt", onlyStatus: "completed") {
            let seen = lastSeen(.agentWork)
            counts[.agentWork] = dates.filter { $0 > seen }.count
        }
    }

    // MARK: - Private

    private func key(_ place: Place) -> String { "kade.unread.lastSeen.\(place.rawValue)" }

    private func lastSeen(_ place: Place) -> Date {
        let stamp = UserDefaults.standard.double(forKey: key(place))
        if stamp == 0 {
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key(place))
            return now
        }
        return Date(timeIntervalSince1970: stamp)
    }

    private func fetchDates(_ client: KadeAPIClient, path: String, listKey: String, dateKey: String, onlyStatus: String? = nil) async -> [Date]? {
        let req = client.request(path: path, authorized: true)
        guard let result = try? await client.send(req) else { return nil }
        let (data, http) = result
        if http.statusCode == 403, path.hasPrefix("api/agents") {
            agentWorkRefused = true
            return nil
        }
        guard http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root[listKey] as? [[String: Any]] else { return nil }
        return rows.compactMap { row -> Date? in
            if let onlyStatus, (row["status"] as? String) != onlyStatus { return nil }
            guard let stamp = row[dateKey] as? String else { return nil }
            return KadeDateFormatting.date(from: stamp)
        }
    }
}
