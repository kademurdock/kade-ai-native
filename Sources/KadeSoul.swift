import Foundation

// MARK: - Synthetic souls, the iPhone half (Oct 16 2026)
//
// The server keeps, per person and character: how the character is coming in
// (a mood phrase written about "them", the person), when the two last talked,
// the moments worth keeping (a nickname, a running joke, a first...), and the
// character's own true journal days. This file is the pure half: the wire
// shapes and every sentence the screens speak, so the words can be tested
// without a simulator (run-soul-tests.sh). Foundation only, on purpose.
//
// What the server never sends, and this app must never invent: the
// character's private opinion of the person. That stays with the character
// (Kade's decision, Oct 16 2026).

/// GET api/kade/soul/{agentId}
struct KadeSoulSnapshot: Decodable, Equatable {
    var mood: KadeSoulMood?
    var lastTalkedAt: String?
    var moments: [KadeSoulMoment]
    var days: [KadeSoulDay]

    init(mood: KadeSoulMood? = nil, lastTalkedAt: String? = nil,
         moments: [KadeSoulMoment] = [], days: [KadeSoulDay] = []) {
        self.mood = mood
        self.lastTalkedAt = lastTalkedAt
        self.moments = moments
        self.days = days
    }

    private enum CodingKeys: String, CodingKey { case mood, lastTalkedAt, moments, days }

    /// Lenient: one odd moment or day is dropped, never the whole page.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let feeling = try? c.decodeIfPresent(KadeSoulMood.self, forKey: .mood)
        mood = (feeling?.words.isEmpty ?? true) ? nil : feeling
        let talked = c.kadeText(.lastTalkedAt)
        lastTalkedAt = talked.isEmpty ? nil : talked
        let rawMoments = (try? c.decodeIfPresent([KadeSoulLenient<KadeSoulMoment>].self, forKey: .moments)) ?? []
        moments = rawMoments.compactMap(\.value).filter { !$0.id.isEmpty && !$0.quote.isEmpty }
        let rawDays = (try? c.decodeIfPresent([KadeSoulLenient<KadeSoulDay>].self, forKey: .days)) ?? []
        days = rawDays.compactMap(\.value).filter { !$0.text.isEmpty }
    }
}

struct KadeSoulMood: Decodable, Equatable {
    var words: String
    var lastMostly: [String]

    init(words: String, lastMostly: [String] = []) {
        self.words = words
        self.lastMostly = lastMostly
    }

    private enum CodingKeys: String, CodingKey { case words, lastMostly }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = c.kadeText(.words)
        lastMostly = (try? c.decodeIfPresent([String].self, forKey: .lastMostly)) ?? []
    }
}

struct KadeSoulMoment: Decodable, Identifiable, Equatable {
    var id: String
    var quote: String
    /// "them" = the person said it; "me" = the character did.
    var speaker: String
    /// nickname, joke, first, milestone or line.
    var kind: String
    var why: String
    var createdAt: String?

    init(id: String, quote: String, speaker: String, kind: String, why: String = "", createdAt: String? = nil) {
        self.id = id
        self.quote = quote
        self.speaker = speaker
        self.kind = kind
        self.why = why
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, quote, speaker, kind, why, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.kadeText(.id)
        quote = c.kadeText(.quote)
        speaker = c.kadeText(.speaker)
        kind = c.kadeText(.kind)
        why = c.kadeText(.why)
        let created = c.kadeText(.createdAt)
        createdAt = created.isEmpty ? nil : created
    }
}

/// One of the character's own journal entries. The same for everyone it
/// talks to; nothing in it is about the person.
struct KadeSoulDay: Decodable, Identifiable, Equatable {
    var day: String
    var text: String
    var following: String
    var home: String
    var id: String { day }

    init(day: String, text: String, following: String = "", home: String = "") {
        self.day = day
        self.text = text
        self.following = following
        self.home = home
    }

    private enum CodingKeys: String, CodingKey { case day, text, following, home }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = c.kadeText(.day)
        text = c.kadeText(.text)
        following = c.kadeText(.following)
        home = c.kadeText(.home)
    }
}

/// GET api/kade/soul/tasks/list
struct KadeBackgroundTaskList: Decodable, Equatable {
    var tasks: [KadeBackgroundTask]

    private enum CodingKeys: String, CodingKey { case tasks }

    init(tasks: [KadeBackgroundTask]) { self.tasks = tasks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([KadeSoulLenient<KadeBackgroundTask>].self, forKey: .tasks)) ?? []
        tasks = raw.compactMap(\.value).filter { !$0.taskId.isEmpty }
    }
}

struct KadeBackgroundTask: Decodable, Identifiable, Equatable {
    var taskId: String
    var agentId: String
    var agentName: String
    var title: String
    var status: String
    var createdAt: String?
    var finishedAt: String?
    var conversationId: String?
    var preview: String
    var error: String
    var quotedMostUSD: Double?
    var chargedUSD: Double?
    var id: String { taskId }

    init(taskId: String, agentId: String = "", agentName: String = "", title: String = "",
         status: String, createdAt: String? = nil, finishedAt: String? = nil,
         conversationId: String? = nil, preview: String = "", error: String = "",
         quotedMostUSD: Double? = nil, chargedUSD: Double? = nil) {
        self.taskId = taskId
        self.agentId = agentId
        self.agentName = agentName
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.conversationId = conversationId
        self.preview = preview
        self.error = error
        self.quotedMostUSD = quotedMostUSD
        self.chargedUSD = chargedUSD
    }

    private enum CodingKeys: String, CodingKey {
        case taskId, agentId, agentName, title, status, createdAt, finishedAt
        case conversationId, preview, error, quotedMostUSD, chargedUSD
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { c.kadeText(key) }
        func number(_ key: CodingKeys) -> Double? {
            guard let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite else { return nil }
            return value
        }
        taskId = text(.taskId)
        agentId = text(.agentId)
        agentName = text(.agentName)
        title = text(.title)
        status = text(.status)
        let created = text(.createdAt)
        createdAt = created.isEmpty ? nil : created
        let finished = text(.finishedAt)
        finishedAt = finished.isEmpty ? nil : finished
        let conversation = text(.conversationId)
        conversationId = conversation.isEmpty ? nil : conversation
        preview = text(.preview)
        error = text(.error)
        quotedMostUSD = number(.quotedMostUSD)
        chargedUSD = number(.chargedUSD)
    }

    var isRunning: Bool { status == "running" }

    /// The conversation the character wrote into, only when it is a real id.
    var openableConversationId: String? {
        guard let conversationId, KadeConversationRoute.isConversationId(conversationId) else { return nil }
        return conversationId
    }
}

/// Decodes one array element, or nothing, so one malformed row never costs
/// the whole list.
struct KadeSoulLenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// A trimmed string, or "" when the field is missing, null or not text.
    func kadeText(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - The push route that opens one exact conversation

/// The bridge's `kadeRoute: "conversation"` push (a character wrote into a
/// conversation: a friend's text, a finished background task, a research
/// result) carries `kadeConversationId`. Only a real LibreChat id (a UUID)
/// may select a conversation; anything else is a fallback to the list, said
/// out loud, never a silent drop.
enum KadeConversationRoute {
    static let routeName = "conversation"

    static func isConversationId(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        return value.range(
            of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
            options: .regularExpression
        ) != nil
    }

    /// The push's custom field, checked. Numbers, arrays, padding and other
    /// shapes are refused rather than repaired.
    static func conversationId(from value: Any?) -> String? {
        guard let id = value as? String, isConversationId(id) else { return nil }
        return id
    }
}

// MARK: - Words

enum KadeSoulWords {
    /// The server's own rule for a character id (routes/kadeSoul.js).
    static func isCharacterId(_ value: String) -> Bool {
        value.range(of: "^agent_[A-Za-z0-9_-]{6,64}$", options: .regularExpression) != nil
    }

    private static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "This character" : trimmed
    }

    private static func withoutEndPunctuation(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = out.last, ".;,".contains(last) { out.removeLast() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "still a little heavy from last time with them" becomes
    /// "Kiana is still a little heavy from last time with you."
    /// No mood at all: "Kiana is coming in settled."
    static func moodSentence(name: String, words: String?) -> String {
        let who = displayName(name)
        var phrase = withoutEndPunctuation(words ?? "")
        guard !phrase.isEmpty else { return "\(who) is coming in settled." }
        phrase = phrase.replacingOccurrences(
            of: "\\bwith them\\b", with: "with you", options: [.regularExpression, .caseInsensitive])
        if phrase.lowercased().hasPrefix("is ") { phrase = String(phrase.dropFirst(3)) }
        return "\(who) is \(phrase)."
    }

    static func momentKindWords(_ kind: String) -> String {
        switch kind.lowercased() {
        case "nickname": return "A nickname"
        case "joke": return "A running joke"
        case "first": return "A first"
        case "milestone": return "A milestone"
        case "line": return "A line that stuck"
        default: return "A moment"
        }
    }

    static func momentSpeakerWords(_ speaker: String, name: String) -> String {
        switch speaker.lowercased() {
        case "them": return "You said"
        case "me": return "\(displayName(name)) said"
        default: return "Said"
        }
    }

    /// The kind line under a quote: "A nickname: what you call me."
    static func momentKindLine(kind: String, why: String) -> String {
        let reason = withoutEndPunctuation(why)
        return reason.isEmpty ? "\(momentKindWords(kind))." : "\(momentKindWords(kind)): \(reason)."
    }

    /// One VoiceOver element per moment:
    /// You said: "goblin of chaos". A nickname: what you call me. October 3.
    static func momentSpoken(_ moment: KadeSoulMoment, name: String, now: Date = Date(),
                             calendar: Calendar = .current) -> String {
        var parts = ["\(momentSpeakerWords(moment.speaker, name: name)): \"\(moment.quote)\".",
                     momentKindLine(kind: moment.kind, why: moment.why)]
        if let when = moment.createdAt.flatMap(parseDate) {
            parts.append("\(shortDate(when, now: now, calendar: calendar)).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Background tasks

    static func taskStatusWords(_ status: String) -> String {
        switch status {
        case "running": return "Working on it"
        case "done": return "Done"
        case "failed": return "Couldn't finish"
        case "cancelled", "cancelled-late": return "Stopped"
        case "cancel-requested": return "Stopping"
        case "interrupted": return "Interrupted by a restart"
        default: return "Status unknown"
        }
    }

    /// "under a cent", "about 3 cents", "about 1 dollar", "about $1.25".
    static func amountWords(_ usd: Double) -> String {
        guard usd.isFinite, usd >= 0.01 else { return "under a cent" }
        let cents = Int((usd * 100).rounded())
        if cents < 100 { return cents == 1 ? "about 1 cent" : "about \(cents) cents" }
        let dollars = cents / 100
        let rest = cents % 100
        if rest == 0 { return dollars == 1 ? "about 1 dollar" : "about \(dollars) dollars" }
        return "about $\(dollars).\(rest < 10 ? "0" : "")\(rest)"
    }

    /// What it cost when that is known, otherwise the most it could cost.
    static func costWords(chargedUSD: Double?, quotedMostUSD: Double?) -> String? {
        if let charged = chargedUSD, charged.isFinite, charged >= 0 {
            return charged == 0 ? "Cost nothing" : "Cost \(amountWords(charged))"
        }
        if let most = quotedMostUSD, most.isFinite, most > 0 {
            return most < 0.01 ? "Under a cent at most" : "Up to \(amountWords(most))"
        }
        return nil
    }

    /// Everything one task row says, as one VoiceOver element.
    static func taskSpoken(_ task: KadeBackgroundTask) -> String {
        var parts: [String] = []
        parts.append(task.title.isEmpty ? "A background task" : task.title)
        if !task.agentName.isEmpty { parts.append(task.agentName) }
        parts.append(taskStatusWords(task.status))
        if task.status == "done", !task.preview.isEmpty { parts.append(task.preview) }
        if task.status == "failed", !task.error.isEmpty { parts.append(task.error) }
        if let cost = costWords(chargedUSD: task.chargedUSD, quotedMostUSD: task.quotedMostUSD) { parts.append(cost) }
        return parts.map { sentenceStart(withoutEndPunctuation($0)) }.filter { !$0.isEmpty }
            .joined(separator: ". ") + "."
    }

    /// The server's own words ("the weather service was down") begin a
    /// sentence here, so their first letter is raised.
    private static func sentenceStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The screen's status line: "3 tasks shown, 1 running."
    static func taskListSummary(_ tasks: [KadeBackgroundTask]) -> String {
        guard !tasks.isEmpty else { return "No background tasks yet." }
        let running = tasks.filter(\.isRunning).count
        let shown = tasks.count == 1 ? "1 task shown" : "\(tasks.count) tasks shown"
        return running == 0 ? "\(shown), none running." : "\(shown), \(running) running."
    }

    /// The row on Agent work that leads to the list.
    static func taskLinkLabel(running: Int?) -> String {
        guard let running else { return "Background tasks" }
        return running == 0 ? "Background tasks, none running" : "Background tasks, \(running) running"
    }

    /// The server's 409 says "it is already done"; this says it plainly.
    static func stopRefusedWords(_ serverError: String?) -> String {
        let reason = withoutEndPunctuation(serverError ?? "")
        guard !reason.isEmpty else { return "Couldn't stop it. Try Refresh to see where it is." }
        return "Couldn't stop it: \(reason)."
    }

    // MARK: Dates

    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    private static func monthName(_ month: Int, calendar: Calendar) -> String {
        let names = calendar.monthSymbols
        return month >= 1 && month <= names.count ? names[month - 1] : "Month \(month)"
    }

    private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let names = calendar.weekdaySymbols
        return weekday >= 1 && weekday <= names.count ? names[weekday - 1] : ""
    }

    /// "October 3", or "October 3, 2025" when it is not this year.
    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let thisYear = calendar.component(.year, from: now)
        let base = "\(monthName(parts.month ?? 1, calendar: calendar)) \(parts.day ?? 1)"
        return parts.year == thisYear ? base : "\(base), \(parts.year ?? thisYear)"
    }

    /// A journal day "2026-10-16" as "Friday, October 16" (year added when it
    /// is not this year). Nil when the server's day is not a real date.
    static func dayHeading(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, day.count == 10 else { return nil }
        var wanted = DateComponents()
        wanted.year = pieces[0]
        wanted.month = pieces[1]
        wanted.day = pieces[2]
        wanted.hour = 12
        guard let date = calendar.date(from: wanted) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == pieces[0], back.month == pieces[1], back.day == pieces[2] else { return nil }
        let weekday = weekdayName(calendar.component(.weekday, from: date), calendar: calendar)
        let dated = shortDate(date, now: now, calendar: calendar)
        return weekday.isEmpty ? dated : "\(weekday), \(dated)"
    }

    private enum PartOfDay { case morning, afternoon, evening, night, smallHours }

    private static func partOfDay(_ date: Date, calendar: Calendar) -> PartOfDay {
        switch calendar.component(.hour, from: date) {
        case 0..<5: return .smallHours
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<21: return .evening
        default: return .night
        }
    }

    /// "Just now", "20 minutes ago", "3 hours ago", "This evening",
    /// "Yesterday evening", "Last night", "Tuesday afternoon", "9 days ago",
    /// "On October 3". Spoken words, not numbers and abbreviations.
    static func lastTalkedWords(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? "A minute ago" : "\(minutes) minutes ago" }
        let hours = Int(seconds / 3600)
        if hours < 6 { return hours == 1 ? "An hour ago" : "\(hours) hours ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let part = partOfDay(date, calendar: calendar)
        switch days {
        case ...0:
            switch part {
            case .smallHours: return "Early this morning"
            case .morning: return "This morning"
            case .afternoon: return "This afternoon"
            case .evening: return "This evening"
            case .night: return "Tonight"
            }
        case 1:
            switch part {
            case .smallHours: return "Early yesterday morning"
            case .morning: return "Yesterday morning"
            case .afternoon: return "Yesterday afternoon"
            case .evening: return "Yesterday evening"
            case .night: return "Last night"
            }
        case 2...6:
            let weekday = weekdayName(calendar.component(.weekday, from: date), calendar: calendar)
            switch part {
            case .smallHours: return "Early \(weekday) morning"
            case .morning: return "\(weekday) morning"
            case .afternoon: return "\(weekday) afternoon"
            case .evening: return "\(weekday) evening"
            case .night: return "\(weekday) night"
            }
        case 7...30:
            return "\(days) days ago"
        default:
            return "On \(shortDate(date, now: now, calendar: calendar))"
        }
    }

    /// The "Last time you talked" line, with nothing yet said plainly.
    static func lastTalkedSentence(_ iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let iso, let date = parseDate(iso) else { return "You haven't talked yet." }
        return "\(lastTalkedWords(date, now: now, calendar: calendar))."
    }
}
