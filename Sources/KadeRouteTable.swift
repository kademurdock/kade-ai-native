import Foundation

// MARK: - KadeRouteTable
//
// Part 87 (Aug 22 2026). ONE table, and the compiler keeps it honest.
//
// THE BUG CLASS THIS CLOSES, in her own words from Part 83: she tapped a
// bug-report push and it "took me to a new conversation with Kiana" — the app's
// launch default — "it should have taken me to the bug window." That was fixed
// by teaching AppDelegate two route strings, in a switch that ended:
//
//     default: dest = nil
//
// A `default` in a routing switch is a silent drop. The bridge can stamp any
// `kadeRoute` it likes; anything the app has not been told about lands nowhere
// and says nothing, which by ear is indistinguishable from a push that simply
// opened the app. The same failure would come back the next time a service
// learned to send a route the app had not.
//
// So the string↔destination mapping now lives HERE, once, as an exhaustive
// switch with no default. Add a case to `IntentRouter.Destination` and this
// file stops compiling until somebody decides what that destination is called
// from outside — including deciding, out loud, that it has no outside name.
//
// This is the same doctrine as the no-default switch in `HomeRoute.id` and the
// tier table in the harness guard: unrecognized input never gets a quiet
// fallback. It gets refused, or it gets a decision.

extension IntentRouter.Destination {

    /// The name a push, deep link, or hub tap uses to ask for this screen.
    /// `nil` means "this destination is not reachable from outside the app" —
    /// a real answer, not an oversight, and the reason each nil carries a why.
    ///
    /// EXHAUSTIVE ON PURPOSE. No `default`.
    var routeName: String? {
        switch self {
        case .spotterCall:     return "spotter"
        case .transcribe:      return "transcribe"
        case .conversations:   return "conversations"
        case .describe:        return "describe"
        case .quickDictate:    return "dictate"
        case .matchmaker:      return "matchmaker"
        case .gameRoom:        return "games"
        case .debateRoom:      return "debate"
        case .agentBuilder:    return "builder"
        case .settings:        return "settings"
        case .brief:           return "brief"
        case .briefListen:     return "brief-listen"
        case .accessRequests:  return "access-requests"
        case .feedbackReports: return "feedback"
        case .adminHub:        return "admin"
        // No outside name, and that is the decision: an agent call cannot be
        // asked for by name because it needs a payload (who is calling, why,
        // which plan). It arrives as its own push category with that payload
        // attached — see AppDelegate's KADE_CALL branch and `pendingAgentCall`.
        case .agentCall:       return nil
        }
    }

    /// Turn a push's `kadeRoute` string into a destination, or nothing.
    ///
    /// Unknown strings still return nil — an older build cannot be taught new
    /// screens, and forward-safety is the whole reason the bridge stamps a
    /// route rather than a screen id. The difference from the old `default:`
    /// is that nil is now the answer to ONE question ("do I have this screen?")
    /// instead of the answer to every question nobody thought to ask.
    init?(routeName: String) {
        let wanted = routeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        guard let match = IntentRouter.Destination.allCases.first(where: { $0.routeName == wanted }) else {
            return nil
        }
        self = match
    }

    /// Every name the app answers to, for the bridge's own reference and for
    /// the diagnostics screen. Sorted so the list reads the same way twice.
    static var everyRouteName: [String] {
        allCases.compactMap { $0.routeName }.sorted()
    }
}

// MARK: - Arrival kinds
//
// Part 87 §2.5, "identity reaches the hand before VoiceOver speaks."
//
// A push arriving is a moment with a TYPE, and until now every type felt
// identical. This maps the notification categories the bridge already sends to
// the felt patterns in `KadeHaptics.arrival`. Kept next to the route table
// because they answer the same question from two directions: a push says what
// it IS (this enum) and where it GOES (the table above).

enum KadeArrivalKind {
    /// Something a character said to you.
    case message
    /// A character is calling. The one that has to be unmistakable.
    case call
    /// A reminder, check-in, or the morning brief.
    case reminder
    /// Something needing your attention as the owner: a crash, a canary, a
    /// balance floor, a bug report, somebody at the front door.
    case alert

    /// Read from the notification's category identifier. Anything unrecognized
    /// reads as a message — the gentlest pattern, never the call rumble. A
    /// wrong big blast is worse than a wrong small one.
    init(categoryIdentifier: String) {
        switch categoryIdentifier {
        case "KADE_CALL":
            self = .call
        case "KADE_BRIEF", "KADE_REMINDER", "KADE_CHECKIN":
            self = .reminder
        case "KADE_ROUTE", "KADE_DOORBELL", "KADE_ADMIN":
            self = .alert
        default:
            self = .message
        }
    }
}
