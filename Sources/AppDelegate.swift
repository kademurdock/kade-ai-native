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
///
/// Session 16 also routes Home Screen Quick Actions (long-press the app
/// icon) through here — the standard place for them on an app built with
/// `@UIApplicationDelegateAdaptor` and no custom `UIWindowSceneDelegate`
/// (this app has neither a `UIApplicationSceneManifest` entry nor a scene
/// delegate class anywhere in the target, so UIKit delivers quick actions
/// to the plain app-delegate callbacks below rather than to a scene
/// delegate's `windowScene(_:performActionFor:)`, which this app doesn't
/// implement). Worth being honest about, the same way the calling feature's
/// own doc comment was: this specific delivery path is a real, common,
/// documented pattern for SwiftUI-lifecycle apps, but it is exactly the
/// class of "reads correct, only iOS actually knows" behavior this project
/// has been burned by before (`.searchFocused` needing iOS 18) — and there
/// is no device in this sandbox to confirm it fires. It is deliberately
/// FAIL-SOFT if it somehow doesn't: `route(for:)` just returns `false` and
/// the app opens normally, same as tapping the icon itself, rather than
/// anything crashing or breaking.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var pushService: PushService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Cold launch (app wasn't already running) FROM a quick action
        // hands the item over here instead of through
        // `performActionFor:completionHandler:` below, which is only for
        // a quick action tapped while already running. Both funnel into
        // the same `route(for:)`.
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            Self.route(for: shortcutItem)
        }
        return true
    }

    /// Quick action tapped while the app was already running or suspended
    /// in the background. `completionHandler` tells the system whether the
    /// action was actually handled — used honestly here (`false` for an
    /// unrecognized type) rather than always reporting success.
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(Self.route(for: shortcutItem))
    }

    /// Maps a quick action's type string (declared statically in
    /// `project.yml`'s `UIApplicationShortcutItems`) onto the exact same
    /// `IntentRouter` the Siri Shortcuts use — one piece of plumbing behind
    /// two discovery paths, both consumed by `ContentView` once it is
    /// signed in and ready.
    @discardableResult
    private static func route(for shortcutItem: UIApplicationShortcutItem) -> Bool {
        let destination: IntentRouter.Destination?
        switch shortcutItem.type {
        case "com.kademurdock.kadeai.callSpotter": destination = .spotterCall
        case "com.kademurdock.kadeai.transcribe": destination = .transcribe
        case "com.kademurdock.kadeai.conversations": destination = .conversations
        case "com.kademurdock.kadeai.describe": destination = .describe
        default: destination = nil
        }
        guard let destination else { return false }
        Task { @MainActor in IntentRouter.shared.request(destination) }
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
