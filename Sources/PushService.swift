import Foundation

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
    private(set) var deviceTokenHex: String?
    private(set) var userId: String?

    /// Called from AppDelegate once iOS hands over a real APNs token.
    func setDeviceToken(_ data: Data) {
        deviceTokenHex = data.map { String(format: "%02x", $0) }.joined()
        Task { await syncIfNeeded() }
    }

    /// Called whenever sign-in state changes (KadeAIApp watches AuthState).
    /// `nil` on sign-out -- the token stays registered but reverts to
    /// "unlinked" server-side on its next natural re-send, same as a device
    /// that never signed in (still reachable by admin/global broadcasts,
    /// just not per-user ones).
    func setUserId(_ id: String?) {
        userId = id
        Task { await syncIfNeeded() }
    }

    private func syncIfNeeded() async {
        guard let token = deviceTokenHex else { return }   // nothing to register yet
        if token == lastSentToken && userId == lastSentUserId { return }
        var req = URLRequest(url: bridgeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["token": token, "platform": "ios"]
        if let userId { body["userId"] = userId }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                lastSentToken = token
                lastSentUserId = userId
            }
            // Any other status: fail-soft, next foreground/state-change retries.
        } catch {
            // Offline or bridge unreachable: fail-soft, retried on next change.
        }
    }
}
