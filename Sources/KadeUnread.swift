import Foundation
import SwiftUI

/// Sep 23 2026 redesign (B11, "little new badges"). Alerts, Announcements and
/// Agent work say "2 new" when something arrived since you last looked, and
/// VoiceOver hears it in the row's label ("Announcements, 2 new").
///
/// Read cursors are account-scoped and synchronize with the platform. Local
/// timestamps provide an offline cache and a fallback for older servers.
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
    @Published private(set) var synchronizationNote = "Checking read state sync."
    private var lastRefresh: Date?
    private var refreshing = false
    private var agentWorkRefused = false
    private var accountId: String?
    private var generation = 0
    private var cachedDates: [Place: [Date]] = [:]
    private var establishedPlaces = Set<Place>()

    func count(_ place: Place) -> Int { counts[place] ?? 0 }
    var total: Int { Place.allCases.reduce(0) { $0 + count($1) } }

    /// "Announcements" or "Announcements, 2 new" — for accessibility labels.
    func spoken(_ base: String, _ place: Place) -> String {
        let n = count(place)
        return n > 0 ? "\(base), \(n) new" : base
    }

    func markSeen(_ place: Place, client: KadeAPIClient) {
        guard bindAccount() else { return }
        let stamp = Date().timeIntervalSince1970
        UserDefaults.standard.set(stamp, forKey: key(place))
        UserDefaults.standard.set(stamp, forKey: pendingKey(place))
        counts[place] = 0
        establishedPlaces.insert(place)
        let current = generation
        Task { await publishSeen(place, client: client, generation: current) }
    }

    /// Sign-out: forget the counts (the timestamps stay with the device).
    func reset() {
        counts = [:]
        lastRefresh = nil
        agentWorkRefused = false
        accountId = nil
        cachedDates = [:]
        establishedPlaces = []
        refreshing = false
        generation += 1
        synchronizationNote = "Checking read state sync."
    }

    func refresh(client: KadeAPIClient, force: Bool = false) async {
        guard bindAccount(), !refreshing else { return }
        let current = generation
        refreshing = true
        defer { if current == generation { refreshing = false } }
        // Foreground refresh always synchronizes read cursors. The content
        // lists remain paced at ten minutes, and cached counts are recalculated.
        await synchronize(client: client, generation: current)
        guard current == generation else { return }
        recount()
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 600 { return }
        lastRefresh = Date()

        if let dates = await fetchDates(client, path: "api/kade/announcements", listKey: "broadcasts", dateKey: "ts") {
            guard current == generation else { return }
            cachedDates[.announcements] = dates
        }
        if let dates = await fetchDates(client, path: "api/kade/nudges/prefs", listKey: "recent", dateKey: "createdAt") {
            guard current == generation else { return }
            cachedDates[.alerts] = dates
        }
        if !agentWorkRefused,
           let dates = await fetchDates(client, path: "api/agents/chat/tasks", listKey: "tasks", dateKey: "createdAt", onlyStatus: "completed") {
            guard current == generation else { return }
            cachedDates[.agentWork] = dates
        }
        recount()
    }

    // MARK: - Private

    private func key(_ place: Place) -> String { "kade.unread.\(accountId ?? "signed-out").lastSeen.\(place.rawValue)" }
    private func pendingKey(_ place: Place) -> String { key(place) + ".pending" }

    private func currentAccount() -> String? {
        guard let data = Keychain.data(for: .user),
              let user = try? JSONDecoder().decode(KadeUser.self, from: data) else { return nil }
        return user.id
    }

    private func bindAccount() -> Bool {
        guard let account = currentAccount() else { reset(); return false }
        if accountId != account {
            reset()
            accountId = account
        }
        return true
    }

    private func recount() {
        for (place, dates) in cachedDates {
            counts[place] = dates.filter { $0 > lastSeen(place) }.count
        }
    }

    private func synchronize(client: KadeAPIClient, generation current: Int) async {
        let request = client.request(path: "api/kade/workspaces/read-state", authorized: true)
        do {
            let (data, response) = try await client.send(request)
            guard current == generation, currentAccount() == accountId else { return }
            if response.statusCode == 404 {
                synchronizationNote = "Read state is saved on this phone. This server does not support syncing yet."
                return
            }
            guard response.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = root["readState"] as? [String: Any] else {
                synchronizationNote = "Read changes are saved on this phone and will sync when connected."
                return
            }
            synchronizationNote = "Read state syncs across your signed-in devices."
            for place in Place.allCases {
                let pending = UserDefaults.standard.double(forKey: pendingKey(place))
                let remote = (state[place.rawValue] as? String).flatMap { KadeDateFormatting.date(from: $0) }
                if pending > 0 {
                    if let remote, remote.timeIntervalSince1970 >= pending {
                        UserDefaults.standard.removeObject(forKey: pendingKey(place))
                        UserDefaults.standard.set(remote.timeIntervalSince1970, forKey: key(place))
                    } else { await publishSeen(place, client: client, generation: current) }
                } else if let remote {
                    // An older GET may land after a successful view-open POST.
                    // Once established in this account session, cursors only advance.
                    let accepted = establishedPlaces.contains(place) ? max(remote, lastSeen(place)) : remote
                    UserDefaults.standard.set(accepted.timeIntervalSince1970, forKey: key(place))
                    establishedPlaces.insert(place)
                } else {
                    // Establish a baseline without flooding an existing account
                    // with every historical record on its first synchronized build.
                    UserDefaults.standard.set(lastSeen(place).timeIntervalSince1970, forKey: pendingKey(place))
                    await publishSeen(place, client: client, generation: current)
                }
                guard current == generation else { return }
            }
        } catch {
            if current == generation { synchronizationNote = "Read changes are saved on this phone and will sync when connected." }
        }
    }

    private func publishSeen(_ place: Place, client: KadeAPIClient, generation current: Int) async {
        guard current == generation, currentAccount() == accountId else { return }
        let stamp = UserDefaults.standard.double(forKey: pendingKey(place))
        guard stamp > 0 else { return }
        var request = client.request(path: "api/kade/workspaces/read-state", method: "POST", authorized: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": place.rawValue,
            "seenThrough": formatter.string(from: Date(timeIntervalSince1970: stamp))])
        do {
            let (data, response) = try await client.send(request)
            guard current == generation, currentAccount() == accountId else { return }
            guard response.statusCode == 200 else {
                synchronizationNote = response.statusCode == 404
                    ? "Read state is saved on this phone. This server does not support syncing yet."
                    : "Read changes are saved on this phone and will sync when connected."
                return
            }
            // Keep a newer view-open cursor if another mark happened in flight.
            if UserDefaults.standard.double(forKey: pendingKey(place)) <= stamp {
                UserDefaults.standard.removeObject(forKey: pendingKey(place))
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let state = root["readState"] as? [String: Any],
                   let text = state[place.rawValue] as? String,
                   let accepted = KadeDateFormatting.date(from: text) {
                    UserDefaults.standard.set(accepted.timeIntervalSince1970, forKey: key(place))
                }
            }
            synchronizationNote = "Read state syncs across your signed-in devices."
            establishedPlaces.insert(place)
            recount()
        } catch {
            if current == generation { synchronizationNote = "Read changes are saved on this phone and will sync when connected." }
        }
    }

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
        let current = generation
        let req = client.request(path: path, authorized: true)
        guard let result = try? await client.send(req) else { return nil }
        guard current == generation, currentAccount() == accountId else { return nil }
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
