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
        if let problem = contactProblem { return problem }
        if cleanWho.isEmpty { return "Please tell Kade a little about yourself." }
        return nil
    }

    /// Oct 29 2026 (review): an approval can only make an account from an
    /// email address or a US phone number the server can read. Anything
    /// else is caught here, before sending, in words that say how to fix it,
    /// instead of Kade finding out at approval time that no account could
    /// be made. nil when the contact is fine (or still empty).
    var contactProblem: String? {
        let c = cleanContact
        if c.isEmpty || Self.findEmail(c) != nil { return nil }
        if c.contains("@") {
            return "That email address looks unfinished. Please check it, like name@example.com, or give a phone number with its area code."
        }
        if Self.usPhoneDigits(c) != nil { return nil }
        let count = Self.asciiDigits(c).count
        if count == 0 {
            return "Please give a phone number with its area code, like 417-555-0123, or an email address."
        }
        if count < 10 {
            return "Please include the area code, like 417-555-0123."
        }
        return "That doesn't read as a US phone number. Please give one with its area code, like 417-555-0123, or an email address instead."
    }

    /// True when the account would be filed under a phone number: no email
    /// address anywhere in the contact (the server prefers an email when
    /// there is one) and a phone number the server can read.
    var contactLooksLikePhone: Bool {
        let c = cleanContact
        guard !c.isEmpty, Self.findEmail(c) == nil else { return false }
        return Self.usPhoneDigits(c) != nil
    }

    /// The server's own phone rule (kadeLoginId.js normalizePhone): strip
    /// everything but the digits 0-9, then accept ten digits, or eleven that
    /// start with a 1. Returns the ten digits, or nil.
    static func usPhoneDigits(_ s: String) -> String? {
        let digits = asciiDigits(s)
        if digits.count == 10 { return digits }
        if digits.count == 11, digits.hasPrefix("1") { return String(digits.dropFirst()) }
        return nil
    }

    /// Only 0-9, the way JavaScript's \D sees digits (not other scripts' numerals).
    static func asciiDigits(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars where scalar.value >= 48 && scalar.value <= 57 {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// The server's "an email somewhere in the contact line" rule
    /// (kadeLoginId.js EMAIL_ANYWHERE_RE), or nil.
    static func findEmail(_ s: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r]).lowercased()
    }

    /// Something typed that would be lost if the form were thrown away.
    var hasTypedSomething: Bool {
        [name, contact, whoYouAre, whyHere].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
