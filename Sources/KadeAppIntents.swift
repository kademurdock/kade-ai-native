import AppIntents
import SwiftUI

/// Siri Shortcuts. Session 15, Kade's pick.
///
/// Why this is worth more here than in most apps: every other way into a
/// Spotter call starts with finding the phone, unlocking it, finding the
/// app, and finding a button. "Hey Siri, call my Spotter with Kade-AI" is
/// none of those steps, and "I need eyes right now" is exactly the kind of
/// thing that happens while both hands are already busy.
///
/// Deliberate design decisions, so nobody undoes them by accident:
///
/// - **Every intent is `openAppWhenRun`.** None of these can meaningfully
///   happen in the background: a call needs the mic, the speaker, the call
///   screen and a way to hang up. An intent that "succeeded" while the app
///   stayed closed would be a call nobody could end.
/// - **No parameters, on purpose.** A parameterized "call <companion>"
///   intent needs an `AppEntity` and an `EntityQuery` backed by the agent
///   list, which means a network fetch inside Siri's own resolution
///   timeout, before sign-in state is even known. Three reliable phrases
///   beat one clever one that fails while you're standing in a car park.
/// - **They route through `IntentRouter` rather than doing anything
///   themselves.** An intent runs before SwiftUI necessarily has a view
///   hierarchy to work with; parking a request that `ContentView` picks up
///   when it is genuinely ready is the shape that doesn't race the launch.
/// - **All of this is App Intents, not SiriKit, and it lives in the MAIN
///   app target.** No extension, no new target, no signing changes — which
///   is exactly why it could ship in this batch at all. (Live Activities,
///   by contrast, DO need a widget extension target, which is why lock
///   screen call controls went the `MPNowPlayingInfoCenter` route instead.)
///
/// `AppShortcutsProvider` is what makes these available by voice with no
/// setup at all. The phrases MUST contain `\(.applicationName)` — Apple
/// requires the app name in every phrase, and a phrase without it is
/// silently dropped rather than rejected loudly.

/// Where a Siri phrase (or anything else that arrives from outside the UI)
/// parks what it wants done. `ContentView` observes this and acts on it
/// once it actually has a hierarchy and a known sign-in state.
///
/// Deliberately NOT `@MainActor`-annotated as a type, even though every
/// real caller is already on the main actor: a SwiftUI `View` is not itself
/// main-actor-isolated, so a global-actor-isolated singleton can't be read
/// from a plain stored-property initializer like
/// `@ObservedObject private var router = IntentRouter.shared` without a
/// concurrency error. The isolation that actually matters is on the
/// `perform()` methods below, which are the only things that ever mutate
/// it from outside the UI.
final class IntentRouter: ObservableObject {
    static let shared = IntentRouter()

    enum Destination: String {
        case spotterCall
        case transcribe
        case conversations
    }

    /// Consumed and cleared by whoever handles it. Optional rather than a
    /// flag per destination so two phrases in quick succession can't leave
    /// the app trying to do both at once.
    @Published var pending: Destination?

    private init() {}

    func request(_ destination: Destination) {
        pending = destination
    }

    func consume() -> Destination? {
        let value = pending
        pending = nil
        return value
    }
}

struct CallSpotterIntent: AppIntent {
    static var title: LocalizedStringResource = "Call your Spotter"
    static var description = IntentDescription(
        "Starts a live call with your visual companion, who can see through your camera and describe what's around you."
    )
    static var openAppWhenRun: Bool = true

    /// Nonisolated, hopping to the main actor explicitly inside. Marking
    /// `perform()` itself `@MainActor` would be an actor-isolation mismatch
    /// against `AppIntent`'s own nonisolated requirement -- exactly the
    /// class of "reads perfectly, only the compiler knows" problem that
    /// cost a whole build cycle when `.searchFocused` turned out to be
    /// iOS 18-only. Nothing crosses the boundary here but the enum case;
    /// the singleton is reached from inside the hop.
    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.spotterCall) }
        return .result()
    }
}

struct TranscribeIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe a voice memo"
    static var description = IntentDescription(
        "Opens the transcriber so you can record a thought and get it back as text."
    )
    static var openAppWhenRun: Bool = true

    /// Nonisolated, hopping to the main actor explicitly inside. Marking
    /// `perform()` itself `@MainActor` would be an actor-isolation mismatch
    /// against `AppIntent`'s own nonisolated requirement -- exactly the
    /// class of "reads perfectly, only the compiler knows" problem that
    /// cost a whole build cycle when `.searchFocused` turned out to be
    /// iOS 18-only. Nothing crosses the boundary here but the enum case;
    /// the singleton is reached from inside the hop.
    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.transcribe) }
        return .result()
    }
}

struct OpenConversationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open your conversations"
    static var description = IntentDescription(
        "Opens your Kade-AI conversation list."
    )
    static var openAppWhenRun: Bool = true

    /// Nonisolated, hopping to the main actor explicitly inside. Marking
    /// `perform()` itself `@MainActor` would be an actor-isolation mismatch
    /// against `AppIntent`'s own nonisolated requirement -- exactly the
    /// class of "reads perfectly, only the compiler knows" problem that
    /// cost a whole build cycle when `.searchFocused` turned out to be
    /// iOS 18-only. Nothing crosses the boundary here but the enum case;
    /// the singleton is reached from inside the hop.
    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.conversations) }
        return .result()
    }
}

struct KadeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallSpotterIntent(),
            phrases: [
                "Call my Spotter with \(.applicationName)",
                "Call my Spotter in \(.applicationName)",
                "\(.applicationName) Spotter",
                "Start a Spotter call with \(.applicationName)",
            ],
            shortTitle: "Call your Spotter",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: TranscribeIntent(),
            phrases: [
                "Transcribe with \(.applicationName)",
                "Take a voice memo with \(.applicationName)",
                "Start transcribing in \(.applicationName)",
            ],
            shortTitle: "Transcribe",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: OpenConversationsIntent(),
            phrases: [
                "Open my \(.applicationName) conversations",
                "Show my \(.applicationName) chats",
            ],
            shortTitle: "Your conversations",
            systemImageName: "bubble.left.and.bubble.right"
        )
    }
}
