import AppIntents
import Foundation

/// Sep 23 2026 redesign (C7): what the "Call your Spotter" control does. It
/// opens the app at kadeai://spotter, which the app routes to the Spotter
/// call the same way the Siri phrase and the Quick Action do.
///
/// Kept in a file of its own, importing nothing but AppIntents and
/// Foundation, so it can ALSO be compiled into the app target. Apple, on
/// controls: "The system requires the Target Membership of the app intent to
/// be set to both the app and the widget extension to open the app." It
/// spells its own URL for the same reason (KadeWidgetLinks is extension-only).
///
/// The untested half: Apple documents OpenURLIntent for universal links, and
/// this app has none, so a custom kadeai:// URL is the part to check on a
/// phone. If the control opens the app but not the Spotter, keep this type
/// and its name, and have perform() call IntentRouter the way
/// CallSpotterIntent does, behind a compilation condition set only on the
/// app target (the extension has no IntentRouter).
///
/// Not discoverable: the app's own `CallSpotterIntent` is the "Call your
/// Spotter" that Siri and Shortcuts list, and a second one with the same
/// name would only be a puzzle there.
@available(iOS 18.0, *)
struct OpenSpotterIntent: AppIntent {
    static var title: LocalizedStringResource = "Call your Spotter"
    static var description = IntentDescription("Opens Kade-AI and calls your Spotter, who looks through your camera and tells you what's around you.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    #if KADE_APP_TARGET
    /// Inside the app (openAppWhenRun, and the app compiles this file too),
    /// the call goes through IntentRouter exactly like CallSpotterIntent, so
    /// nothing depends on OpenURLIntent accepting a custom scheme.
    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.spotterCall) }
        return .result()
    }
    #else
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "kadeai://spotter")!))
    }
    #endif
}
