import Foundation

// MARK: - Approvals (Oct 16 2026)
//
// Kade's yes before her ops agent Forge ships: a merge, a commit, a deploy, a
// change to Railway's settings. ADMIN ONLY: the server answers 403 to anyone
// else, and the app shows the row only to the admin seat (never family, never
// the App Review seat). This file is the pure half: the wire shape and every
// sentence the screen speaks, tested by run-soul-tests.sh. Foundation only.

/// GET api/kade/approvals
struct KadeApprovalList: Decodable, Equatable {
    var approvals: [KadeApproval]

    private enum CodingKeys: String, CodingKey { case approvals }

    init(approvals: [KadeApproval]) { self.approvals = approvals }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([KadeSoulLenient<KadeApproval>].self, forKey: .approvals)) ?? []
        approvals = raw.compactMap(\.value).filter { !$0.approvalId.isEmpty }
    }
}

/// One request from Forge, and (POST .../decide) the same shape back.
struct KadeApproval: Decodable, Identifiable, Equatable {
    var approvalId: String
    /// github-merge, github-commit, github-commit-files, railway-deploy, railway-vars.
    var kind: String
    /// pending, running, done, denied, failed or expired.
    var status: String
    var summary: String
    /// How to undo it, in words, when there is a way.
    var revert: String
    var agentId: String
    var createdAt: String?
    var expiresAt: String?
    var decidedAt: String?
    /// "button" or "words".
    var decidedBy: String?
    var resultWords: String
    var deployWords: String
    var error: String
    var id: String { approvalId }

    init(approvalId: String, kind: String = "", status: String, summary: String = "", revert: String = "",
         agentId: String = "", createdAt: String? = nil, expiresAt: String? = nil, decidedAt: String? = nil,
         decidedBy: String? = nil, resultWords: String = "", deployWords: String = "", error: String = "") {
        self.approvalId = approvalId
        self.kind = kind
        self.status = status
        self.summary = summary
        self.revert = revert
        self.agentId = agentId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
        self.resultWords = resultWords
        self.deployWords = deployWords
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case approvalId, kind, status, summary, revert, agentId, createdAt, expiresAt
        case decidedAt, decidedBy, resultWords, deployWords, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func optional(_ key: CodingKeys) -> String? {
            let value = c.kadeText(key)
            return value.isEmpty ? nil : value
        }
        approvalId = c.kadeText(.approvalId)
        kind = c.kadeText(.kind)
        status = c.kadeText(.status)
        summary = c.kadeText(.summary)
        revert = c.kadeText(.revert)
        agentId = c.kadeText(.agentId)
        createdAt = optional(.createdAt)
        expiresAt = optional(.expiresAt)
        decidedAt = optional(.decidedAt)
        decidedBy = optional(.decidedBy)
        resultWords = c.kadeText(.resultWords)
        deployWords = c.kadeText(.deployWords)
        error = c.kadeText(.error)
    }

    var isPending: Bool { status == "pending" }
    var isRunning: Bool { status == "running" }
}

enum KadeApprovalWords {
    /// Status words come first in every row.
    static func statusWords(_ status: String) -> String {
        switch status {
        case "pending": return "Waiting on you"
        case "running": return "Running now"
        case "done": return "Done"
        case "denied": return "You said no"
        case "failed": return "Didn't go through"
        case "expired": return "Expired"
        default: return "Status unknown"
        }
    }

    private static func clause(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = out.last, ".;,".contains(last) { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = out.first else { return out }
        return first.uppercased() + out.dropFirst()
    }

    /// "Undo: git revert abc123", or nil when there is no way back to name.
    static func undoLine(_ revert: String) -> String? {
        // Not re-capitalized: the way back is often a command ("git revert").
        var way = revert.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = way.last, ".;,".contains(last) { way.removeLast() }
        way = way.trimmingCharacters(in: .whitespacesAndNewlines)
        return way.isEmpty ? nil : "Undo: " + way
    }

    /// The relative words with their first word lowered for mid-sentence use
    /// ("Asked yesterday evening"), leaving weekday names alone.
    private static func midSentence(_ words: String) -> String {
        let lowered: Set<String> = ["Just", "A", "An", "This", "Yesterday", "Last", "Early", "Tonight", "On"]
        let space = words.firstIndex(of: " ") ?? words.endIndex
        let first = String(words[..<space])
        guard lowered.contains(first) else { return words }
        return first.lowercased() + words[space...]
    }

    /// "Asked 20 minutes ago" while it waits; "Decided yesterday evening"
    /// once answered. Nil when the server sent no usable time.
    static func whenWords(_ approval: KadeApproval, now: Date = Date(), calendar: Calendar = .current) -> String? {
        if let decided = approval.decidedAt.flatMap(KadeSoulWords.parseDate) {
            return "Decided " + midSentence(KadeSoulWords.lastTalkedWords(decided, now: now, calendar: calendar))
        }
        if let asked = approval.createdAt.flatMap(KadeSoulWords.parseDate) {
            return "Asked " + midSentence(KadeSoulWords.lastTalkedWords(asked, now: now, calendar: calendar))
        }
        return nil
    }

    /// The row's one VoiceOver element: status first, then the summary, then
    /// what happened, then how to undo it, then when.
    static func spoken(_ approval: KadeApproval, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts = [statusWords(approval.status)]
        parts.append(approval.summary.isEmpty ? "A request from Forge" : approval.summary)
        parts.append(approval.resultWords)
        parts.append(approval.deployWords)
        parts.append(approval.error)
        if let undo = undoLine(approval.revert) { parts.append(undo) }
        if let when = whenWords(approval, now: now, calendar: calendar) { parts.append(when) }
        return parts.map(clause).filter { !$0.isEmpty }.joined(separator: ". ") + "."
    }

    /// The Approve alert's message: what it does, and the way back.
    static func confirmMessage(_ approval: KadeApproval) -> String {
        let what = approval.summary.isEmpty ? "Forge will go ahead." : clause(approval.summary) + "."
        guard let undo = undoLine(approval.revert) else { return what }
        return what + "\n\n" + undo + "."
    }

    /// The status line: "2 waiting on you." / "Nothing waiting on you."
    static func statusLine(_ approvals: [KadeApproval]) -> String {
        let waiting = approvals.filter(\.isPending).count
        let running = approvals.filter(\.isRunning).count
        var line = waiting == 0 ? "Nothing waiting on you" : "\(waiting) waiting on you"
        if running > 0 { line += ", \(running) running now" }
        return line + "."
    }

    /// The admin row's spoken name: "Approvals, 2 waiting".
    static func rowSpoken(waiting: Int?) -> String {
        guard let waiting else { return "Approvals" }
        return waiting == 0 ? "Approvals, nothing waiting" : "Approvals, \(waiting) waiting"
    }

    static func rowCaption(waiting: Int?) -> String {
        guard let waiting else { return "Your yes before Forge ships" }
        return waiting == 0 ? "Nothing waiting on you" : "\(waiting) waiting on you"
    }

    /// What to say after a yes, from the item the server sent back.
    static func approveOutcome(_ approval: KadeApproval) -> String {
        switch approval.status {
        case "done":
            let words = [approval.resultWords, approval.deployWords].map(clause).filter { !$0.isEmpty }
            return words.isEmpty ? "Done." : words.joined(separator: ". ") + "."
        case "failed":
            let why = clause(approval.error.isEmpty ? approval.resultWords : approval.error)
            return why.isEmpty ? "It didn't go through." : "It didn't go through. \(why)."
        case "running":
            return "Still running. Refresh in a minute to see how it went."
        case "expired":
            return "That one had expired. Nothing changed."
        case "denied":
            return "That one was already turned down. Nothing changed."
        default:
            let words = clause(approval.resultWords)
            return words.isEmpty ? "Sent." : words + "."
        }
    }

    /// 409: it was no longer waiting. The server says why.
    static func conflictWords(_ serverError: String?) -> String {
        let why = clause(serverError ?? "")
        return why.isEmpty ? "That one isn't waiting anymore. The list is refreshed." : "\(why). The list is refreshed."
    }
}
