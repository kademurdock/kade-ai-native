import UIKit
import UserNotifications

/// Bridges UIKit's push-notification callbacks into the SwiftUI app -- Phase
/// 6. SwiftUI's `App` protocol has no direct hook for
/// `didRegisterForRemoteNotificationsWithDeviceToken` or for controlling how
/// a notification is shown while the app is already open; both are
/// UIApplicationDelegate / UNUserNotificationCenterDelegate callbacks, so
/// this thin adaptor exists purely to receive them (wired in via
/// `@UIApplicationDelegateAdaptor` in KadeAIApp). Holds a reference to the
/// shared PushService (handed over once, right after launch) so a real
/// device token lands there the moment iOS provides one.
///
/// Per the house style for `@objc`-dispatched delegate callbacks on
/// otherwise-@MainActor code (no compiler in this sandbox to verify
/// implicit-isolation assumptions): this class is intentionally NOT marked
/// `@MainActor` itself, and the one call that touches a `@MainActor` object
/// (`pushService.setDeviceToken`) is dispatched explicitly via
/// `Task { @MainActor in ... }` rather than assumed safe.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var pushService: PushService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            self.pushService?.setDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Fail-soft: no device token this launch (simulator, permission
        // denied, offline first-run, etc.) -- every other screen works fine
        // without push; the mic/voice/chat/agent-picker features Phases 1-5
        // shipped don't depend on it.
    }

    /// Foreground presentation: without this, iOS shows NOTHING while the
    /// app is open (banner-and-sound only fires by default when the app is
    /// backgrounded/killed). Matches the Capacitor shell app's own earlier
    /// fix for the identical gap (build 5, see PRIVATE_kade-ai_credentials.md
    /// push-notifications section) -- a blind caller relying on VoiceOver
    /// needs the SAME lock-screen-style announcement whether or not the app
    /// happens to be open at the moment a character/reminder/check-in fires.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
