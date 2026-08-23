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

    // Held directly (not just captured into each service's init) so
    // Phase 9's StreamingCallService -- constructed fresh per call, inside
    // CallView rather than as a persistent app-level StateObject -- can
    // reach the SAME shared client every other service uses, instead of
    // standing up a second one and splitting the request-pacing clock this
    // class's own doc comment specifically warns against.
    private let client: KadeAPIClient

    @StateObject private var auth: AuthService
    @StateObject private var conversationsService: ConversationsService
    @StateObject private var messageSendingService: MessageSendingService
    @StateObject private var agentsService: AgentsService
    @StateObject private var voiceService: VoiceService
    // Phase 6: no KadeAPIClient dependency (a different host, see its own
    // doc comment), so a plain default-initialized StateObject is enough.
    @StateObject private var pushService = PushService()
    // Session 17 (Kade: "a native way to access settings like speech and
    // whatnot. Accessability low vision stuff like that.") -- on-device
    // only, no server dependency either, same reasoning as pushService.
    @StateObject private var appearance = AppearancePreferences()

    init() {
        // Session 20: register feedback defaults (sound/haptics on) BEFORE
        // anything reads FeedbackPrefs.shared, so first run is opt-out.
        FeedbackPrefs.registerDefaults()
        // One shared client so auth calls and data calls (and, as of
        // Phase 3, the chat send/stream calls, Phase 4's agent list, and
        // Phase 5's speech endpoints) obey the same request-pacing
        // clock (see KadeAPIClient's doc comment).
        let client = KadeAPIClient()
        self.client = client
        _auth = StateObject(wrappedValue: AuthService(client: client))
        _conversationsService = StateObject(wrappedValue: ConversationsService(client: client))
        _messageSendingService = StateObject(wrappedValue: MessageSendingService(client: client))
        _agentsService = StateObject(wrappedValue: AgentsService(client: client))
        _voiceService = StateObject(wrappedValue: VoiceService(client: client))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(auth)
                .environmentObject(conversationsService)
                .environmentObject(messageSendingService)
                .environmentObject(agentsService)
                .environmentObject(voiceService)
                .environmentObject(pushService)
                .environmentObject(appearance)
                .environmentObject(FeedbackPrefs.shared)
                // High contrast forces dark mode app-wide -- colorScheme is
                // an environment value the system (and this app's own
                // semantic-color-only styling, never a hardcoded Color())
                // already respects everywhere, unlike a font family. `nil`
                // (not `.light`) when off, so it defers to whatever the
                // SYSTEM appearance setting already is rather than pinning
                // light mode on someone who has their phone set to dark.
                .preferredColorScheme(appearance.highContrast ? .dark : nil)
                .task {
                    // Hand the delegate its PushService reference before
                    // anything can race a device token in (didFinishLaunching
                    // already ran by the time this .task body starts, but a
                    // real token from Apple can arrive at any point after).
                    appDelegate.pushService = pushService
                    // Synthesize the earcons once up front so the first real
                    // one (a message send) is never a synthesis hitch.
                    // Build 216: and the haptic engine, for the same reason --
                    // its lazy first start() was landing on her send turn.
                    //
                    // ⚠️ BOTH ARE SKIPPED UNDER THE ACCESSIBILITY AUDIT (Part 90,
                    // DEBUG-only, CI-only). A prewarmed CHHapticEngine and a set
                    // of prepared AVAudioPlayers keep the run loop and the audio
                    // session alive, and XCUITest waits for the app to go IDLE
                    // before every query -- so on the Codemagic simulator the app
                    // never idled, every accessibility snapshot timed out after
                    // sixty seconds, and Apple's audit could not read a single
                    // screen. Twice, at six and a half minutes of Mac time each.
                    // A simulator has no haptics and nobody is listening to the
                    // earcons, so skipping them costs the audit nothing and buys
                    // it the only thing it needs: an app that stops moving.
                    // Release builds never contain this branch.
                    if !KadeUITestMode.isAuditing {
                        Earcons.shared.prewarm()
                        KadeHapticEngine.shared.prewarm()
                    }
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
        // August 1 2026 (the App Store sprint, part 2): every tour frame
        // from build 174 came back photobombed by this exact permission
        // alert -- CI has no finger to tap it away, and Apple rejects
        // store screenshots that show permission dialogs. In tour mode
        // (debug simulator runs only; Release never sets KADE_TOUR), skip
        // the ask entirely -- the tour seat has no use for push anyway.
        #if DEBUG
        if ProcessInfo.processInfo.environment["KADE_TOUR"] == "1" { return }
        #endif
        // Build 193: declare the KADE_BRIEF category BEFORE asking for
        // authorization — iOS matches a push's category string against
        // whatever was registered most recently, and registering every
        // launch is the documented pattern (idempotent, cheap). LISTEN and
        // READ both open the app (.foreground): the brief speaks through
        // the app's own voice pipeline, not a sound file in the push, so
        // there is nothing useful a background action could do. A brief
        // push on a build that predates this registration just shows no
        // buttons — nothing breaks.
        let listen = UNNotificationAction(
            identifier: "KADE_BRIEF_LISTEN", title: "Listen", options: [.foreground]
        )
        let read = UNNotificationAction(
            identifier: "KADE_BRIEF_READ", title: "Read", options: [.foreground]
        )
        let briefCategory = UNNotificationCategory(
            identifier: "KADE_BRIEF", actions: [listen, read], intentIdentifiers: [], options: []
        )
        // Build 195: the doorbell category — no action buttons, a plain tap
        // routes to Access Requests via AppDelegate.didReceive. Registered
        // here because iOS only honors categories from the most recent
        // setNotificationCategories call (it replaces, never merges).
        let doorbellCategory = UNNotificationCategory(
            identifier: "KADE_DOORBELL", actions: [], intentIdentifiers: [], options: []
        )
        /* Part 75 (Aug 21 2026): the agent-call ring. Answer opens the app
         * straight into the call (.foreground); "Not now" quietly declines
         * (no .foreground -- iOS dismisses, and the bridge's missed-call
         * sweep sends the follow-up note on its own). The ringtone is the
         * push's sound: bundled KadeRing*.caf files, and a build that
         * predates them falls back to the default sound by Apple's rule. */
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
