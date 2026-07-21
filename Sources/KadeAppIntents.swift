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

/// Where a Siri phrase (or anything else that arrives from outside the UI --
/// session 16 adds Home Screen Quick Actions, see `AppDelegate.route(for:)`)
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
        case describe
        case quickDictate
        // Session 18: the five screens shipped across sessions 17/18 gain
        // voice entry points too. Every switch over this enum is exhaustive
        // (no default) ON PURPOSE -- adding a case here must break the build
        // anywhere a handler forgot about it, not silently no-op.
        case matchmaker
        case gameRoom
        case debateRoom
        case agentBuilder
        case settings
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

struct QuickDictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick dictate"
    static var description = IntentDescription(
        "Starts listening right away and copies the clean text to your clipboard the moment you stop, ready to paste anywhere."
    )
    static var openAppWhenRun: Bool = true

    /// Nonisolated, hopping to the main actor explicitly inside -- see
    /// every other intent in this file for why `perform()` itself is never
    /// marked `@MainActor`.
    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.quickDictate) }
        return .result()
    }
}

struct DescribeIntent: AppIntent {
    static var title: LocalizedStringResource = "Describe a photo or document"
    static var description = IntentDescription(
        "Opens Describe so you can get a photo, video, or document read to you or described out loud."
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
        await MainActor.run { IntentRouter.shared.request(.describe) }
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
        AppShortcut(
            intent: DescribeIntent(),
            phrases: [
                "Describe something with \(.applicationName)",
                "Describe a photo with \(.applicationName)",
            ],
            shortTitle: "Describe",
            systemImageName: "plus.viewfinder"
        )
        // Session 16 ("an app keyboard like wispr flow?"): a real custom
        // keyboard needs a whole new extension target and, per iOS's own
        // hard block on microphone access inside keyboard extensions, an
        // app-hop-to-record dance no different from this -- so this IS
        // the fast path, not a placeholder for a bigger version later.
        // Being a plain AppShortcut is also what makes it selectable as an
        // iPhone 15 Pro+ Action Button target with zero extra code: the
        // Action Button picks from any Shortcut/App Intent already on the
        // phone, this one included, the moment it exists.
        AppShortcut(
            intent: QuickDictateIntent(),
            phrases: [
                "Quick dictate with \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Quick Dictate",
            systemImageName: "mic.badge.plus"
        )
        // Session 18: five more destinations. NOTE -- Apple caps
        // AppShortcutsProvider at 10 AppShortcuts per app, and this makes
        // exactly 10. The NEXT destination that wants a Siri phrase has to
        // evict one of these, not just append (an 11th is silently dropped).
        // Home Screen Quick Actions (project.yml) deliberately NOT extended:
        // iOS shows at most 4 on long-press and 5 are already declared.
        AppShortcut(
            intent: OpenMatchmakerIntent(),
            phrases: [
                "Find me a match with \(.applicationName)",
                "Open the \(.applicationName) Matchmaker",
            ],
            shortTitle: "Matchmaker",
            systemImageName: "person.2.fill"
        )
        AppShortcut(
            intent: OpenGameRoomIntent(),
            phrases: [
                "Open the \(.applicationName) Game Room",
                "Show the \(.applicationName) leaderboard",
            ],
            shortTitle: "Game Room",
            systemImageName: "gamecontroller"
        )
        AppShortcut(
            intent: OpenDebateRoomIntent(),
            phrases: [
                "Open the \(.applicationName) Debate Room",
                "Start a debate in \(.applicationName)",
            ],
            shortTitle: "Debate Room",
            systemImageName: "person.3.fill"
        )
        AppShortcut(
            intent: OpenAgentBuilderIntent(),
            phrases: [
                "Open the \(.applicationName) Agent Builder",
                "Build an agent in \(.applicationName)",
            ],
            shortTitle: "Agent Builder",
            systemImageName: "person.crop.circle.badge.plus"
        )
        AppShortcut(
            intent: OpenSettingsIntent(),
            phrases: [
                "Open my \(.applicationName) settings",
                "\(.applicationName) settings",
            ],
            shortTitle: "Settings",
            systemImageName: "gearshape"
        )
    }
}

// ── Session 18 intents ──────────────────────────────────────────────────────
// Same shape as every intent above: parameterless, openAppWhenRun, perform()
// deliberately NOT @MainActor (see CallSpotterIntent's doc comment for the
// isolation-mismatch lesson), routed through IntentRouter and consumed by
// ContentView once signed in and ready.

struct OpenMatchmakerIntent: AppIntent {
    static var title: LocalizedStringResource = "Matchmaker"
    static var description = IntentDescription(
        "Opens the Matchmaker: five quick questions, then three companions who might be a good fit."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.matchmaker) }
        return .result()
    }
}

struct OpenGameRoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Game Room"
    static var description = IntentDescription(
        "Opens the Game Room: family standings and recent results from games played in chat."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.gameRoom) }
        return .result()
    }
}

struct OpenDebateRoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Debate Room"
    static var description = IntentDescription(
        "Opens the Debate Room, where you set a topic and let your companions go back and forth."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.debateRoom) }
        return .result()
    }
}

struct OpenAgentBuilderIntent: AppIntent {
    static var title: LocalizedStringResource = "Agent Builder"
    static var description = IntentDescription(
        "Opens the Agent Builder so you can create or edit your own companions."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.agentBuilder) }
        return .result()
    }
}

struct OpenSettingsIntent: AppIntent {
    static var title: LocalizedStringResource = "Settings"
    static var description = IntentDescription(
        "Opens Kade-AI's speech and accessibility settings."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentRouter.shared.request(.settings) }
        return .result()
    }
}
