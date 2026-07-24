import Foundation
import CoreLocation

/// Opt-in location ride-along (July 23 2026 — MAPS_GPS_WORKUP slice 1,
/// Kade-approved). While the Settings toggle is ON, a foreground
/// CoreLocation watch keeps one fresh fix; MessageSendingService attaches it
/// to chat requests as `userLocation` and the fork's kade_location tool
/// answers "where am I / what's around / walk me there" from it.
///
/// OFF (the default) = no location services touched at all: the manager
/// never starts, nothing is attached, and the tool tells the user about the
/// setting instead of guessing. Blind-first and fail-soft: permission
/// denied, airplane mode, or a stale fix simply mean nothing rides along —
/// never an error, never a guess.
final class KadeLocationShare: NSObject, CLLocationManagerDelegate, ObservableObject {
    static let shared = KadeLocationShare()
    private static let storageKey = "kadeShareLocation"

    private let manager = CLLocationManager()
    private var lastFix: CLLocation?

    /// Persisted toggle. Flipping it starts/stops the watch immediately
    /// (the system permission prompt appears on first enable).
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.storageKey)
            if enabled { start() } else { stop() }
        }
    }

    private override init() {
        enabled = UserDefaults.standard.bool(forKey: Self.storageKey)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 15 // meters; sidewalk-scale updates without battery burn
        if enabled { start() }
    }

    private func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    private func stop() {
        manager.stopUpdatingLocation()
        lastFix = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastFix = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Fail-soft: keep whatever fix we had; freshness gating handles decay.
    }

    /// The chat-body payload — only while ON, authorized, and fresh (10 min).
    /// Shape matches the web client exactly ({lat, lon, accuracy, at}).
    func freshPayload() -> [String: Any]? {
        guard enabled, let fix = lastFix else { return nil }
        guard Date().timeIntervalSince(fix.timestamp) < 600 else { return nil }
        return [
            "lat": fix.coordinate.latitude,
            "lon": fix.coordinate.longitude,
            "accuracy": fix.horizontalAccuracy,
            "at": ISO8601DateFormatter().string(from: fix.timestamp),
        ]
    }
}
