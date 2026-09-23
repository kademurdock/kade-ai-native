import Foundation
import UIKit

/// Part 278 (Sep 23 2026), Kade: "Can you put a thing in the app to prompt
/// people to update if they're on an outdated version?"
///
/// There are two ways onto a phone, so there are two sources:
/// - An App Store copy asks Apple's public lookup (itunes.apple.com/lookup)
///   which version the store has and compares it with its own
///   CFBundleShortVersionString. Nothing to maintain.
/// - A TestFlight copy asks the platform (GET api/kade/app-version). Apple has
///   no lookup for TestFlight builds, so the server remembers the newest build
///   an admin seat has run. Kade installs every build first, and her own
///   launch, which is this same call, is what makes a build "the update" for
///   everyone else.
///
/// Debug builds (the simulator tour and the accessibility audit) never check.
///
/// What people see and hear: at most one alert per new version every three
/// days ("Update Kade-AI?", with Update and Not now), never while the data-use
/// notice or a call is on screen (ContentView gates that), plus an "Update
/// Kade-AI" row at the top of the More tab for as long as the copy is behind.
/// A TestFlight build below the server's KADE_IOS_MIN_BUILD is asked every
/// time, without "Not now".
@MainActor
final class KadeUpdateCheck: ObservableObject {
    static let shared = KadeUpdateCheck()

    enum Channel { case appStore, testFlight }

    struct Offer: Equatable {
        let channel: Channel
        /// "2.1.3" for the App Store, "build 315" for TestFlight.
        let newest: String
        /// Below the server's minimum: asked every time, no "Not now".
        let required: Bool

        var storeName: String { channel == .appStore ? "the App Store" : "TestFlight" }
    }

    enum Result {
        case behind(Offer)
        case upToDate
        /// Offline, or the lookup failed. Keeps whatever was known before.
        case unknown
        /// A Debug build, or a copy with no receipt: never checks.
        case notChecked
    }

    /// Drives the More tab row: set while this copy is behind.
    @Published private(set) var available: Offer?
    /// Drives the alert.
    @Published var prompt: Offer?

    static let appleID = "6791024001"
    private static let snoozeKey = "kade.update.snooze"
    private var lastCheck: Date?

    private init() {}

    var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var installedBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// "2.1.0, build 313": the More row's caption and the spoken result.
    var installedDescription: String { "\(installedVersion), build \(installedBuild)" }

    var channel: Channel? {
        #if DEBUG
        return nil
        #else
        guard let receipt = Bundle.main.appStoreReceiptURL else { return nil }
        return receipt.lastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
        #endif
    }

    /// At sign-in and each return to the app, at most every six hours, unless
    /// `force` (More, "Check for updates") or a required update is pending.
    @discardableResult
    func check(client: KadeAPIClient, force: Bool = false) async -> Result {
        guard let channel else { return .notChecked }
        let pendingRequired = available?.required == true
        if !force, !pendingRequired, let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 {
            return available.map { .behind($0) } ?? .upToDate
        }
        lastCheck = Date()
        let result: Result
        switch channel {
        case .appStore: result = await appStoreResult()
        case .testFlight: result = await testFlightResult(client: client)
        }
        switch result {
        case .behind(let offer):
            available = offer
            if force || offer.required || !isSnoozed(offer) {
                prompt = offer
            }
        case .upToDate:
            available = nil
            prompt = nil
        case .unknown, .notChecked:
            break
        }
        return result
    }

    /// Opens the App Store page, or this app's page in TestFlight.
    func openUpdate(_ offer: Offer) {
        prompt = nil
        let primary: URL?
        let fallback: URL?
        switch offer.channel {
        case .appStore:
            primary = URL(string: "itms-apps://apps.apple.com/app/id\(Self.appleID)")
            fallback = URL(string: "https://apps.apple.com/app/id\(Self.appleID)")
        case .testFlight:
            primary = URL(string: "itms-beta://beta.itunes.apple.com/v1/app/\(Self.appleID)")
            fallback = URL(string: "itms-beta://")
        }
        Task { @MainActor in
            if let primary, await UIApplication.shared.open(primary) { return }
            if let fallback { _ = await UIApplication.shared.open(fallback) }
        }
    }

    /// "Not now": this version doesn't interrupt again for three days. The
    /// More row stays.
    func notNow(_ offer: Offer) {
        prompt = nil
        let until = Date().addingTimeInterval(3 * 24 * 3600).timeIntervalSince1970
        UserDefaults.standard.set([offer.newest: until], forKey: Self.snoozeKey)
    }

    func title(for offer: Offer) -> String {
        offer.required ? "Please update Kade-AI" : "Update Kade-AI?"
    }

    func message(for offer: Offer) -> String {
        switch offer.channel {
        case .appStore:
            return "Version \(offer.newest) is ready in the App Store. You have version \(installedVersion)."
        case .testFlight:
            if offer.required {
                return "This test version is too old to keep working. The newest one, \(offer.newest), is ready in TestFlight. You have build \(installedBuild)."
            }
            return "A newer test version, \(offer.newest), is ready in TestFlight. You have build \(installedBuild)."
        }
    }

    // MARK: - Sources

    private func appStoreResult() async -> Result {
        guard var parts = URLComponents(string: "https://itunes.apple.com/lookup") else { return .unknown }
        parts.queryItems = [
            URLQueryItem(name: "id", value: Self.appleID),
            URLQueryItem(name: "country", value: "us"),
        ]
        guard let url = parts.url else { return .unknown }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let response = try? await URLSession.shared.data(for: request) else { return .unknown }
        let (data, http) = response
        guard (http as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return .unknown }
        // Not listed at all (between releases, or pulled): nothing to offer.
        guard let store = results.first?["version"] as? String else { return .upToDate }
        guard Self.isNewer(store, than: installedVersion) else { return .upToDate }
        return .behind(Offer(channel: .appStore, newest: store, required: false))
    }

    private func testFlightResult(client: KadeAPIClient) async -> Result {
        let request = client.request(
            path: "api/kade/app-version",
            authorized: true,
            queryItems: [
                URLQueryItem(name: "platform", value: "ios"),
                URLQueryItem(name: "channel", value: "testflight"),
                URLQueryItem(name: "build", value: String(installedBuild)),
            ],
            timeout: 15
        )
        guard let response = try? await client.send(request) else { return .unknown }
        let (data, http) = response
        guard http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        let latest = (root["latestBuild"] as? NSNumber)?.intValue ?? 0
        let minimum = (root["minimumBuild"] as? NSNumber)?.intValue ?? 0
        guard installedBuild > 0, latest > installedBuild else { return .upToDate }
        return .behind(Offer(channel: .testFlight, newest: "build \(latest)", required: installedBuild < minimum))
    }

    private func isSnoozed(_ offer: Offer) -> Bool {
        let all = UserDefaults.standard.dictionary(forKey: Self.snoozeKey) as? [String: Double] ?? [:]
        guard let until = all[offer.newest] else { return false }
        return Date().timeIntervalSince1970 < until
    }

    /// "2.1.10" is newer than "2.1.9": compared number by number.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
