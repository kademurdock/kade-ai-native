import Foundation

/// Decision 24 (Nov 12 2026, Kade: voice speed, delivery and fillers are
/// "Same on every device"). Pure Foundation, so run-voice-sync-tests.sh can
/// build it alone. The website's twin is client/src/utils/listenerVoiceSync.ts
/// and these rules copy its tests.
///
/// The rule, per field (pace, fillers, delivery):
/// 1. Speech always uses the value on the phone, at once; nothing here is
///    ever awaited by speech.
/// 2. The phone keeps the last server stamp it saw and a pending flag.
/// 3. Her change: saved locally first, marked pending, sent. A 200 answer
///    stores the returned stamp, and clears pending only if the phone still
///    holds the value that was sent.
/// 4. On a fetch: a pending field is sent again. Otherwise a stamp the phone
///    has not seen is applied and stored. Otherwise nothing.
/// 5. The server never had the field and the phone holds her own saved
///    choice: send it up. A phone with no saved choice sends nothing, so a
///    fresh install never overwrites her settings with defaults.
enum ListenerVoicePlan {
    static let deliveryModes: Set<String> = ["STABLE", "BALANCED", "CREATIVE"]

    /// The account's values, as GET /api/kade/voice-prefs `listener` sends them.
    struct Account: Equatable {
        /// nil inside .some = "Character's speed"; outer nil = never saved.
        var pace: Double??
        var paceAt: String?
        var fillers: Bool?
        var fillersAt: String?
        var delivery: [String: String]?
        var deliveryAt: String?

        init(pace: Double?? = nil, paceAt: String? = nil, fillers: Bool? = nil, fillersAt: String? = nil,
             delivery: [String: String]? = nil, deliveryAt: String? = nil) {
            self.pace = pace; self.paceAt = paceAt; self.fillers = fillers; self.fillersAt = fillersAt
            self.delivery = delivery; self.deliveryAt = deliveryAt
        }

        /// Reads the `listener` object leniently; anything odd is left out.
        init(json: [String: Any]) {
            if let raw = json["pace"] {
                if raw is NSNull { pace = .some(nil) } else if let n = raw as? NSNumber { pace = .some(n.doubleValue) }
            }
            paceAt = json["paceAt"] as? String
            fillers = json["fillers"] as? Bool
            fillersAt = json["fillersAt"] as? String
            if let map = json["delivery"] as? [String: Any] {
                var out: [String: String] = [:]
                for (key, value) in map { if let s = value as? String { out[key] = s } }
                delivery = out
            }
            deliveryAt = json["deliveryAt"] as? String
        }
    }

    /// What the phone holds right now.
    struct Local: Equatable {
        var pace: Double?          // nil = Character's speed
        var paceSaved: Bool        // she really chose it (see ListenerVoiceSync)
        var fillers: Bool
        var fillersSaved: Bool     // the fillers key exists
        var delivery: [String: String]   // her saved per-character entries
    }

    struct State: Codable, Equatable {
        var seenPace: String?
        var seenFillers: String?
        var seenDelivery: String?
        var pendingPace = false
        var pendingFillers = false
        /// Characters whose delivery she changed and the account has not taken yet.
        var pendingDelivery: [String] = []
    }

    struct Plan: Equatable {
        var applyPace: Double?? = nil            // .some(nil) = apply Character's speed
        var applyFillers: Bool? = nil
        var applyDelivery: [String: String]? = nil   // replaces every local entry
        var pushPace: Double?? = nil
        var pushFillers: Bool? = nil
        var pushDelivery: [String: String?]? = nil   // nil value = clear that character
        var state: State
        var pushesAnything: Bool { pushPace != nil || pushFillers != nil || pushDelivery != nil }
    }

    static func validPace(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0.5 && value <= 1.5
    }

    static func cleanDelivery(_ map: [String: String]?) -> [String: String] {
        var out: [String: String] = [:]
        for (agent, mode) in map ?? [:] where deliveryModes.contains(mode) && validAgentId(agent) {
            out[agent] = mode
        }
        return out
    }

    static func validAgentId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// What to do with the account's values. Pure.
    static func plan(account: Account?, local: Local, state: State) -> Plan {
        var plan = Plan(state: state)
        guard let account else { return plan }

        // Pace
        if state.pendingPace {
            plan.pushPace = .some(local.pace)
        } else if let stamp = account.paceAt, let value = account.pace, validPace(value) {
            if stamp != state.seenPace {
                if value != local.pace { plan.applyPace = .some(value) }
                plan.state.seenPace = stamp
            }
        } else if account.paceAt == nil, local.paceSaved, state.seenPace == nil, validPace(local.pace) {
            plan.pushPace = .some(local.pace)
        }

        // Fillers
        if state.pendingFillers {
            plan.pushFillers = local.fillers
        } else if let stamp = account.fillersAt, let value = account.fillers {
            if stamp != state.seenFillers {
                if value != local.fillers { plan.applyFillers = value }
                plan.state.seenFillers = stamp
            }
        } else if account.fillersAt == nil, local.fillersSaved, state.seenFillers == nil {
            plan.pushFillers = local.fillers
        }

        // Delivery
        if !state.pendingDelivery.isEmpty {
            var map: [String: String?] = [:]
            for agent in state.pendingDelivery where validAgentId(agent) {
                map[agent] = .some(local.delivery[agent])
            }
            if !map.isEmpty { plan.pushDelivery = map }
        } else if let stamp = account.deliveryAt {
            if stamp != state.seenDelivery {
                plan.applyDelivery = cleanDelivery(account.delivery)
                plan.state.seenDelivery = stamp
            }
        } else if state.seenDelivery == nil, !local.delivery.isEmpty {
            var map: [String: String?] = [:]
            for (agent, mode) in cleanDelivery(local.delivery) { map[agent] = .some(mode) }
            if !map.isEmpty { plan.pushDelivery = map }
        }
        return plan
    }

    /// After the account took a write: store its stamps, and clear pending
    /// only for what the phone still holds exactly as sent.
    static func afterPush(state: State, sentPace: Double??, sentFillers: Bool?, sentDelivery: [String: String?]?,
                          account: Account, local: Local) -> State {
        var next = state
        if let sent = sentPace, let stamp = account.paceAt {
            next.seenPace = stamp
            if local.pace == sent { next.pendingPace = false }
        }
        if let sent = sentFillers, let stamp = account.fillersAt {
            next.seenFillers = stamp
            if local.fillers == sent { next.pendingFillers = false }
        }
        if let sent = sentDelivery, let stamp = account.deliveryAt {
            next.seenDelivery = stamp
            next.pendingDelivery.removeAll { agent in
                guard let value = sent[agent] else { return false }
                return local.delivery[agent] == value
            }
        }
        return next
    }

    /// Pace words the iPhone saves (kade.voiceMessage.pace) and their numbers.
    static let paceWords: [(word: String, rate: Double?)] = [
        ("character", nil), ("unhurried", 0.75), ("relaxed", 0.8), ("easygoing", 0.9), ("natural", 1),
        ("upbeat", 1.1), ("brisk", 1.2), ("swift", 1.3), ("rapid", 1.4), ("quick", 1.5),
    ]
    /// nil for a word the list does not have.
    static func paceNumber(word: String) -> Double?? {
        guard let hit = paceWords.first(where: { $0.word == word }) else { return nil }
        return .some(hit.rate)
    }
    /// The word for a server number, or nil when no option is exact (keep local).
    static func paceWord(number: Double?) -> String? {
        guard let number else { return "character" }
        return paceWords.first { $0.rate.map { abs($0 - number) < 0.001 } ?? false }?.word
    }
}
