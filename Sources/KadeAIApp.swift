import SwiftUI
import UIKit
import UserNotifications

@main
struct KadeAIApp: App {
    // Phase 6: bridges the UIKit-only push-notification callbacks (no
    // SwiftUI App-lifecycle equivalent exists for
    // didRegisterForRemoteNotificationsWithDeviceToken or foreground
    // presentation) -- see AppDelegate.swift's doc comment.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var auth: AuthService
    @StateObject private var conversationsService: ConversationsService
    @StateObject private var messageSendingService: MessageSendingService
    @StateObject private var agentsService: AgentsService
    @StateObject private var voiceService: VoiceService
    // Phase 6: no KadeAPIClient dependency (a different host, see its own
    // doc comment), so a plain default-initialized StateObject is enough.
    @StateObject private var pushService = PushService()

    init() {
        // One shared client so auth calls and data calls (and, as of
        // Phase 3, the chat send/stream calls, Phase 4's agent list, and
        // Phase 5's speech endpoints) obey the same request-pacing
        // clock (see KadeAPIClient's doc comment).
        let client = KadeAPIClient()
        _auth = StateObject(wrappedValue: AuthService(client: client))
        _conversationsService = StateObject(wrappedValue: ConversationsService(client: client))
        _messageSendingService = StateObject(wrappedValue: MessageSendingService(client: client))
        _agentsService = StateObject(wrappedValue: AgentsService(client: client))
        _voiceService = StateObject(wrappedValue: VoiceService(client: client))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(conversationsService)
                .environmentObject(messageSendingService)
                .environmentObject(agentsService)
                .environmentObject(voiceService)
                .environmentObject(pushService)
                .task {
                    // Hand the delegate its PushService reference before
                    // anything can race a device token in (didFinishLaunching
                    // already ran by the time this .task body starts, but a
                    // real token from Apple can arrive at any point after).
                    appDelegate.pushService = pushService
                    await auth.restore()   // restore a saved session at launch
                    requestPushAuthorization()
                }
                .onChange(of: auth.state) { _, newState in
                    // Link the device to whoever is actually signed in right
                    // now -- lets the bridge target push by userId (Phase 6)
                    // instead of only broadcasting to every device. Signing
                    // out clears the link (nil) rather than leaving a stale
                    // userId attached to a device nobody's using anymore.
                    switch newState {
                    case .signedIn(let user):
                        pushService.setUserId(user.id)
                    case .signedOut:
                        pushService.setUserId(nil)
                    default:
                        break
                    }
                }
        }
    }

    /// Ask once at launch. iOS silently no-ops a repeat request if the user
    /// already answered (allow OR deny) -- safe to call unconditionally
    /// every launch rather than tracking "have we asked before" ourselves.
    private func requestPushAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            // registerForRemoteNotifications() must run on the main thread;
            // the authorization completion handler fires on an arbitrary
            // queue, so hop explicitly rather than assume.
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
}
