import Foundation

/// Oct 29 2026 (Kade: "we need to also put a sighted switch on the
/// registration... when we ask people for phone and email and stuff").
/// The pure half of the in-app front door: what a new person's answers turn
/// into on the wire. Foundation only, so `run-ask-to-join-tests.sh` compiles
/// it with swiftc alone and checks it on CI.
///
/// The request goes to the same public doorbell the website's
/// /request-access page uses (POST /api/access-request). `sight` rides along
/// as "sighted", "nonvisual" or JSON null, the same three values the
/// account's own sight flag holds (GET/PUT /api/kade/sight). Nobody has to
/// answer it: no answer and "I'd rather not say" both send null, and null
/// keeps the free painted faces, exactly like an account that never said.

/// The one new question at the door: will this person be looking at the
/// screen? Order is the order the choices are read in.
enum AskToJoinSight: String, CaseIterable, Identifiable {
    case sighted
    case nonvisual
    case ratherNotSay

    var id: String { rawValue }

    /// What the person hears and reads. Plain words, first person, the way
    /// they would say it themselves.
    var label: String {
        switch self {
        case .sighted:      return "I'll look at the screen"
        case .nonvisual:    return "I'll listen, I use a screen reader"
        case .ratherNotSay: return "I'd rather not say"
        }
    }

    /// The value the server stores, or nil for JSON null.
    var serverValue: String? {
        switch self {
        case .sighted:      return "sighted"
        case .nonvisual:    return "nonvisual"
        case .ratherNotSay: return nil
        }
    }
}

/// One knock at the door, as typed. Field names match the website's form and
/// the server route exactly (name, contact, whoYouAre, whyHere, sight).
struct AskToJoinRequest: Equatable {
    var name: String = ""
    var contact: String = ""
    var whoYouAre: String = ""
    var whyHere: String = ""
    /// nil = not answered, which sends null like "I'd rather not say".
    var sight: AskToJoinSight? = nil

    /// The same limits the server trims to, so nothing typed is silently cut
    /// without the person knowing it would be.
    static let nameLimit = 80
    static let contactLimit = 160
    static let textLimit = 1200

    private static func clean(_ s: String, _ limit: Int) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    var cleanName: String { Self.clean(name, Self.nameLimit) }
    var cleanContact: String { Self.clean(contact, Self.contactLimit) }
    var cleanWho: String { Self.clean(whoYouAre, Self.textLimit) }
    var cleanWhy: String { Self.clean(whyHere, Self.textLimit) }

    /// The first thing still missing, said the way the person would fix it,
    /// or nil when the request can be sent. The sight question is never
    /// required.
    var missing: String? {
        if cleanName.isEmpty { return "Please say what people call you." }
        if cleanContact.isEmpty { return "Please give a phone number or an email, so Kade can reach you." }
        if cleanWho.isEmpty { return "Please tell Kade a little about yourself." }
        return nil
    }

    /// True when the way to reach them reads as a phone number rather than an
    /// email: no "@" and at least seven digits.
    var contactLooksLikePhone: Bool {
        let c = cleanContact
        guard !c.isEmpty, !c.contains("@") else { return false }
        return c.filter(\.isNumber).count >= 7
    }

    /// The JSON body for POST /api/access-request. `sight` is always present,
    /// as a string or as null, so the server never has to guess.
    func jsonBody() -> Data {
        let sightValue: Any = sight?.serverValue ?? NSNull()
        let body: [String: Any] = [
            "name": cleanName,
            "contact": cleanContact,
            "whoYouAre": cleanWho,
            "whyHere": cleanWhy,
            "sight": sightValue,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// What to tell the person after the server answers. `serverMessage` is
    /// the route's own `message` (success) or `error` (refusal) when it sent
    /// one; the fallbacks cover an answer with neither.
    static func outcome(status: Int, serverMessage: String?) -> (sent: Bool, text: String) {
        let said = serverMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (200..<300).contains(status) {
            return (true, said.isEmpty ? "Request sent. Kade will review it and get back to you." : said)
        }
        if !said.isEmpty { return (false, said) }
        if status == 429 { return (false, "That door was just knocked on. Try again in a bit.") }
        return (false, "The request did not go through. Check your connection and try again.")
    }
}
