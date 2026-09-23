import Foundation
import Combine

/// Registers this device for push notifications with kade-ai-bridge --
/// Phase 6. Deliberately its OWN tiny client, not routed through
/// KadeAPIClient: `/push-register` lives on a different host (the bridge,
/// not kademurdock.com) and carries none of the fork's anti-abuse pacing
/// concerns (see KadeAPIClient's own doc comment for why THAT one is strict
/// about a shared clock) -- a device-token POST is a single fire-and-forget
/// call, not part of the account-paced request stream.
///
/// The device token and the signed-in userId can each arrive first (APNs
/// registration completes on its own OS schedule; sign-in is a separate
/// async flow) -- this service caches whichever lands first and (re-)POSTs
/// once it has a token, then again whenever EITHER value actually changes
/// (a fresh token on reinstall, signing into a different account on the
/// same device, or signing out).
///
/// Sending `userId` (not just the bare token, which is all the older
/// Capacitor shell app sends) is what LINKS this device to a person on the
/// bridge -- required for the per-user "outreach/check-in" feature
/// (kade_notify's schedule_checkin) to ever target anyone but the admin
/// account. That gate is a deliberate, separate decision (PRIVATE_kade-ai_
/// credentials.md: "OWNER-GATED for now... to open to all users: have the
/// iOS app send the logged-in user id on /push-register, then filter
/// runNotify targets by userId and drop the isAdmin gate") -- this service
/// only satisfies the technical prerequisite (the bridge now RECEIVES a
/// userId from this app); it does not itself flip that gate.
@MainActor
final class PushService: ObservableObject {
    private let bridgeURL = URL(string: "https://kade-ai-bridge-production.up.railway.app/push-register")!
    private var lastSentToken: String?
    private var lastSentUserId: String?
    private var lastSentRingtone: String?
    private var isSyncing = false
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(send: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.send = send
    }
    /// Part 75: the Settings agent-call ringtone pick, stored here so the
    /// bridge learns the user's DEFAULT ring on the same register call.
    static let ringtoneDefaultsKey = "kadeCallRingtone"
    private(set) var deviceTokenHex: String?
    private(set) var userId: String?

    /// Called from AppDelegate once iOS hands over a real APNs token.
    func setDeviceToken(_ data: Data) {
        deviceTokenHex = data.map { String(format: "%02x", $0) }.joined()
        Task { await syncIfNeeded() }
    }

    /// Part 75: Settings pokes this after a ringtone pick so the new
    /// default reaches the bridge without waiting for the next launch.
    func ringtoneChanged() {
        Task { await syncIfNeeded() }
    }

    /// Called whenever sign-in state changes (KadeAIApp watches AuthState).
    /// `nil` explicitly unregisters the device, including from broadcasts.
    func setUserId(_ id: String?) {
        userId = id
        Task { await syncIfNeeded() }
    }

    private func syncIfNeeded() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while let token = deviceTokenHex {
            let sendingUserId = userId
            let ringtone = UserDefaults.standard.string(forKey: Self.ringtoneDefaultsKey)
            if token == lastSentToken && sendingUserId == lastSentUserId && ringtone == lastSentRingtone { return }
            var req = URLRequest(url: bridgeURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["token": token, "platform": "ios"]
            if let sendingUserId { body["userId"] = sendingUserId }
            else { body["userId"] = NSNull() }
            if let ringtone { body["ringtone"] = ringtone }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (_, response) = try await send(req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    lastSentToken = token
                    lastSentUserId = sendingUserId
                    lastSentRingtone = ringtone
                } else {
                    return
                }
                // Any other status: fail-soft, next foreground/state-change retries.
            } catch {
                // Offline or bridge unreachable: fail-soft, retried on next change.
                return
            }
            // State may have changed during the request. Send its latest value
            // next; an older login response must never acknowledge a later logout.
        }
    }

    func refreshRegistration() {
        Task { await syncIfNeeded() }
    }
}
