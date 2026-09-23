import SwiftUI
import UIKit
import UserNotifications

/// Sep 23 2026 redesign (B13, "first-run manners"). Until build 311 the app
/// asked for notification permission at LAUNCH, on the sign-in screen, before
/// a new person knew what the app was (the newcomer audit's finding). A cold
/// "Kade-AI would like to send you notifications" with no reason is the
/// easiest No in iOS, and a No here quietly costs them agent calls, slow-reply
/// pings and the morning brief.
///
/// Now: launch only REGISTERS (categories every launch, and the device token
/// when permission already exists — every current family phone already
/// answered, so nothing changes for them). The ASK waits until the person has
/// had a first reply, and comes with its reason, as a card in the chat
/// (ConversationDetailView) and a row in Settings.
enum KadePushPermission {
    private static let dismissedKey = "kade.pushAsk.dismissed"

    /// Every launch. Never shows a prompt.
    static func registerAtLaunch() {
        #if DEBUG
        // The CI screenshot tour has no finger to answer anything.
        if ProcessInfo.processInfo.environment["KADE_TOUR"] == "1" { return }
        #endif
        setCategories()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            default:
                break
            }
        }
    }

    /// True only while this device has never been asked.
    static func notYetAsked() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .notDetermined)
            }
        }
    }

    /// Whether to offer the in-chat card: never asked on this device, and the
    /// person has not said "Not now" to the card before.
    static func shouldOfferCard() async -> Bool {
        if UserDefaults.standard.bool(forKey: dismissedKey) { return false }
        return await notYetAsked()
    }

    /// "Not now" on the card. Settings still has the switch.
    static func dismissCard() {
        UserDefaults.standard.set(true, forKey: dismissedKey)
    }

    /// The system prompt itself — only ever after the person chose to turn
    /// notifications on. `completion` runs on the main queue with the answer.
    static func request(completion: ((Bool) -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: dismissedKey)
        setCategories()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted { UIApplication.shared.registerForRemoteNotifications() }
                completion?(granted)
            }
        }
    }

    /// For a Settings row: the current state in words.
    static func currentStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Opens this app's page in the iPhone Settings app (for a person who said
    /// No once and has changed their mind — iOS will not ask twice).
    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Moved here unchanged from KadeAIApp.requestPushAuthorization (build 193
    /// brief, build 195 doorbell, Part 75 agent call). iOS honours only the most
    /// recent setNotificationCategories call, so every category is set together.
    static func setCategories() {
        let listen = UNNotificationAction(
            identifier: "KADE_BRIEF_LISTEN", title: "Listen", options: [.foreground]
        )
        let read = UNNotificationAction(
            identifier: "KADE_BRIEF_READ", title: "Read", options: [.foreground]
        )
        let briefCategory = UNNotificationCategory(
            identifier: "KADE_BRIEF", actions: [listen, read], intentIdentifiers: [], options: []
        )
        let doorbellCategory = UNNotificationCategory(
            identifier: "KADE_DOORBELL", actions: [], intentIdentifiers: [], options: []
        )
        let answer = UNNotificationAction(
            identifier: "KADE_CALL_ANSWER", title: "Answer", options: [.foreground]
        )
        let later = UNNotificationAction(
            identifier: "KADE_CALL_LATER", title: "Not now", options: []
        )
        let callCategory = UNNotificationCategory(
            identifier: "KADE_CALL", actions: [answer, later], intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([briefCategory, doorbellCategory, callCategory])
    }
}
