import SwiftUI
import UIKit

/// Build 193 — the FRONT DOOR's native half. The web/server half shipped
/// Aug 9 2026 (fork 86fd957): a public /request-access page rings her phone
/// ("Front door: someone is asking in"), and an admin review surface answers
/// the door. THIS screen is that review surface on the phone itself — the
/// doorbell push should land, and the decision should be three taps away
/// without ever opening Safari.
///
/// The shape mirrors the server contract exactly (routes/admin/
/// accessRequests.js): list by status, approve-as-adult / approve-as-kid /
/// deny. Approving hands back a READY-TO-SEND welcome text carrying the
/// right registration code — deliberately displayed with a Copy button and
/// NOT auto-sent anywhere: Kade texts the blessing herself, which keeps the
/// last step human and the codes out of email. (Same reasoning as the web
/// side; her registration codes are unchanged and this door is an addition.)
///
/// House rules inherited: information cards are ONE spoken element; every
/// control is a plain Button owning its own accessibility; buttons are
/// never disabled (the session-23 VoiceOver-cursor rule) — repeat taps
/// decline politely while a decision is in flight.
///
/// Oct 29 2026 (review of the sign-up sight question and the welcome call):
/// each card now reads the person's own answer about the screen, and Kade
/// can choose it herself before approving (it goes to the server only when
/// she changed it). A phone-only account cannot get mail, so the platform
/// calls them and reads the sign-in aloud; the card says how that call
/// went, offers "Call again with a new password" (asks first, because it
/// replaces their password) and "Already signed in". The default list shows
/// those phone sign-ins until they are settled, the way her web page does,
/// so a missed call never drops out of sight.

// MARK: - Server shapes

/// One request from GET /api/admin/access-requests. Lenient by hand — one
/// odd row must never fail the whole door out of loading.
struct AccessRequestItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let contact: String
    let whoYouAre: String
    let whyHere: String?
    var status: String
    var audience: String?
    let createdAt: String?
    /// "sighted", "nonvisual", or nil when they did not say.
    let sight: String?
    let hasAccount: Bool
    /// The account signs in with a phone number and has no real email.
    let usesPhoneLogin: Bool
    /// "", "placed", "voicemail", "failed", "off" or "not-needed".
    let welcomeCallStatus: String
    let welcomeCallAt: String?
    let welcomeCallCount: Int
    /// Why a call could not be placed, in plain words.
    let welcomeCallNote: String
    /// How the last call went, already a sentence ("Nobody answered...").
    let welcomeCallOutcome: String
    /// The server's own "nothing more to do about the call", when it sends one.
    let welcomeCallSettled: Bool?

    private enum Keys: String, CodingKey {
        case id, name, contact, whoYouAre, whyHere, status, audience, createdAt
        case sight, hasAccount, usesPhoneLogin
        case welcomeCallStatus, welcomeCallAt, welcomeCallCount, welcomeCallNote, welcomeCallOutcome, welcomeCallSettled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Unnamed"
        self.contact = (try? c.decode(String.self, forKey: .contact)) ?? ""
        self.whoYouAre = (try? c.decode(String.self, forKey: .whoYouAre)) ?? ""
        self.whyHere = try? c.decode(String.self, forKey: .whyHere)
        self.status = (try? c.decode(String.self, forKey: .status)) ?? "pending"
        self.audience = try? c.decode(String.self, forKey: .audience)
        self.createdAt = try? c.decode(String.self, forKey: .createdAt)
        let said = try? c.decode(String.self, forKey: .sight)
        self.sight = (said == "sighted" || said == "nonvisual") ? said : nil
        self.hasAccount = (try? c.decode(Bool.self, forKey: .hasAccount)) ?? false
        self.usesPhoneLogin = (try? c.decode(Bool.self, forKey: .usesPhoneLogin)) ?? false
        self.welcomeCallStatus = (try? c.decode(String.self, forKey: .welcomeCallStatus)) ?? ""
        self.welcomeCallAt = try? c.decode(String.self, forKey: .welcomeCallAt)
        self.welcomeCallCount = (try? c.decode(Int.self, forKey: .welcomeCallCount)) ?? 0
        self.welcomeCallNote = (try? c.decode(String.self, forKey: .welcomeCallNote)) ?? ""
        self.welcomeCallOutcome = (try? c.decode(String.self, forKey: .welcomeCallOutcome)) ?? ""
        self.welcomeCallSettled = try? c.decode(Bool.self, forKey: .welcomeCallSettled)
    }

    /// An approved phone-only account: the welcome call is how they get in.
    var isPhoneSignIn: Bool {
        status == "approved" && hasAccount && usesPhoneLogin
    }

    /// Nothing more for Kade to do about the call. The server's word when it
    /// gives one; otherwise "already signed in" or a call they picked up and
    /// stayed on.
    var callSettled: Bool {
        if let welcomeCallSettled { return welcomeCallSettled }
        if welcomeCallStatus == "not-needed" { return true }
        return welcomeCallStatus == "placed" && welcomeCallOutcome.hasPrefix("They answered and the call ran")
    }

    /// Shown in the default list: a phone sign-in still waiting on a call.
    var needsCallAttention: Bool {
        isPhoneSignIn && !callSettled
    }
}

private struct AccessRequestListResponse: Decodable {
    let requests: [AccessRequestItem]
}

/// What approve and the welcome-call route answer. Every field optional:
/// older servers send fewer of them.
struct AccessRequestDecision: Decodable {
    let readyMessage: String?
    let welcomeCallStatus: String?
    let usesPhoneLogin: Bool?
    let accountCreated: Bool?
    let needsEmail: Bool?
}

/// A refusal in the server's own words ("That number was called a minute
/// ago...") or a plain fallback.
struct AccessRequestFailure: Error {
    let message: String
}

/// Kade's choice about the screen for a person she is approving. Same three
/// answers the door offers, in her words about them.
enum AccessSightChoice: String, CaseIterable, Identifiable {
    case sighted
    case nonvisual
    case unsaid

    var id: String { rawValue }

    init(serverValue: String?) {
        switch serverValue ?? "" {
        case "sighted": self = .sighted
        case "nonvisual": self = .nonvisual
        default: self = .unsaid
        }
    }

    var label: String {
        switch self {
        case .sighted: return "Looks at the screen"
        case .nonvisual: return "Listens, uses a screen reader"
        case .unsaid: return "Not said"
        }
    }
}

// MARK: - Service

@MainActor
final class AccessRequestsService: ObservableObject {
    private let client: KadeAPIClient
    init(client: KadeAPIClient) { self.client = client }

    func list(status: String) async throws -> [AccessRequestItem] {
        let req = client.request(
            path: "api/admin/access-requests",
            authorized: true,
            queryItems: [URLQueryItem(name: "status", value: status)]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(AccessRequestListResponse.self, from: data).requests
    }

    /// Approves, which makes the account and (for a phone-only account)
    /// places the welcome call. `sight` is sent only when Kade changed the
    /// person's own answer; nil leaves their answer standing.
    func approve(id: String, audience: String, sight: AccessSightChoice?) async throws -> AccessRequestDecision {
        var body: [String: Any] = ["audience": audience]
        if let sight {
            body["sight"] = sight == .unsaid ? NSNull() : sight.rawValue
        }
        return try await post(path: "api/admin/access-requests/\(id)/approve", body: body,
                              fallback: "That didn't go through. Try again in a moment.")
    }

    /// A NEW temporary password and a call that reads it (the old password
    /// stops working), or with `skip` just "they're already signed in".
    func welcomeCall(id: String, skip: Bool) async throws -> AccessRequestDecision {
        let body: [String: Any] = skip ? ["skip": true] : [:]
        return try await post(path: "api/admin/access-requests/\(id)/welcome-call", body: body,
                              fallback: "Calling them again did not work. Try again in a minute.")
    }

    func deny(id: String) async throws {
        var req = client.request(path: "api/admin/access-requests/\(id)/deny", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (_, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    private func post(path: String, body: [String: Any], fallback: String) async throws -> AccessRequestDecision {
        var req = client.request(path: path, method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let said = ((json?["error"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw AccessRequestFailure(message: said.isEmpty ? fallback : said)
        }
        return (try? JSONDecoder().decode(AccessRequestDecision.self, from: data))
            ?? AccessRequestDecision(readyMessage: nil, welcomeCallStatus: nil, usesPhoneLogin: nil,
                                     accountCreated: nil, needsEmail: nil)
    }
}

// MARK: - Screen

struct AccessRequestsView: View {
    let apiClient: KadeAPIClient

    @StateObject private var serviceBox: ServiceBox
    @State private var items: [AccessRequestItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showAll = false
    /// Request ids with a decision in flight — repeat taps decline politely.
    @State private var deciding: Set<String> = []
    /// The approve payoff: the blessing text, held on screen with a Copy
    /// button until she dismisses it. One at a time is plenty — approvals
    /// are rare, deliberate events.
    @State private var blessingText: String?
    @State private var blessingFor: String?
    /// "placed" when the platform is calling them to read it.
    @State private var blessingCall: String?
    @State private var copiedConfirm = false
    @State private var statusLine: String?
    /// Kade's screen choice per pending request, only when she changed it.
    @State private var sightPicks: [String: AccessSightChoice] = [:]
    /// The card whose "Call again with a new password" is waiting on her yes.
    @State private var callAgainFor: AccessRequestItem?

    /// StateObject wants its wrapped value at init; the client arrives as a
    /// plain parameter — the standard box dance, same as AdminService use.
    @MainActor
    private final class ServiceBox: ObservableObject {
        let service: AccessRequestsService
        init(client: KadeAPIClient) { self.service = AccessRequestsService(client: client) }
    }

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _serviceBox = StateObject(wrappedValue: ServiceBox(client: apiClient))
    }

    private var waitingItems: [AccessRequestItem] {
        items.filter { $0.status == "pending" }
    }

    private var callItems: [AccessRequestItem] {
        items.filter { $0.needsCallAttention }
    }

    var body: some View {
        List {
            if let blessingText {
                Section {
                    Text(blessingText)
                        .font(.body)
                        .accessibilityLabel("Welcome message for \(blessingFor ?? "the new member"): \(blessingText)")
                    Button {
                        UIPasteboard.general.string = blessingText
                        copiedConfirm = true
                        UIAccessibility.post(notification: .announcement, argument: "Copied. Paste it into a text to \(blessingFor ?? "them").")
                    } label: {
                        Label(copiedConfirm ? "Copied — paste it into a text" : "Copy the welcome message", systemImage: "doc.on.doc")
                    }
                    .accessibilityHint("Puts the whole welcome message, sign-in and password included, on your clipboard.")
                    Button {
                        self.blessingText = nil
                        self.blessingFor = nil
                        self.blessingCall = nil
                        self.copiedConfirm = false
                    } label: {
                        Label("Done with this one", systemImage: "checkmark")
                    }
                } header: {
                    Text(blessingCall == "placed" ? "Approved — Kade AI is calling them" : "Approved — send them the welcome")
                } footer: {
                    Text(blessingCall == "placed"
                         ? "The call reads their sign-in and password slowly, twice. If they miss it, read this to them yourself, or choose Call again with a new password on their card."
                         : "You deliver this personally, by text or however you reach them. That last step staying human is the point.")
                }
            }

            if showAll {
                Section {
                    listBody(items, empty: "No requests yet — the door hasn't been knocked on.")
                } header: {
                    Text("All requests")
                }
            } else {
                Section {
                    listBody(waitingItems, empty: "Nobody's waiting at the door right now.")
                } header: {
                    Text("Waiting at the door")
                } footer: {
                    Text("People who found the login page and asked to join. Approving makes their account; someone who gave only a phone number gets a call that reads their sign-in.")
                }
                if !isLoading, loadError == nil, !callItems.isEmpty {
                    Section {
                        ForEach(callItems) { item in
                            requestCard(item)
                        }
                    } header: {
                        Text("Phone sign-ins to check")
                    } footer: {
                        Text("Approved people who sign in with a phone number, whose welcome call is not settled yet. Each stays here until they answered it, or you mark them already signed in.")
                    }
                }
            }

            Section {
                Button {
                    showAll.toggle()
                    Task { await load() }
                } label: {
                    Label(showAll ? "Show only who's waiting" : "Show everyone, decided too", systemImage: "line.3.horizontal.decrease.circle")
                }
            }

            if let statusLine {
                Section { Text(statusLine).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Access Requests")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Make a new password and call?",
            isPresented: Binding(
                get: { callAgainFor != nil },
                set: { showing in if !showing { callAgainFor = nil } }
            ),
            titleVisibility: .visible,
            presenting: callAgainFor
        ) { item in
            Button("Make a new password and call \(item.name)", role: .destructive) {
                callAgainFor = nil
                Task { await callAgain(item) }
            }
            Button("Cancel", role: .cancel) { callAgainFor = nil }
        } message: { item in
            Text("This replaces \(item.name)'s current password and signs them out everywhere, then calls \(item.contact) and reads the new one. If they already got in, choose Already signed in instead.")
        }
    }

    @ViewBuilder
    private func listBody(_ shown: [AccessRequestItem], empty: String) -> some View {
        if isLoading {
            Text("Checking the front door…")
                .foregroundStyle(.secondary)
        } else if let loadError {
            Text(loadError)
            Button("Try again") { Task { await load() } }
        } else if shown.isEmpty {
            Text(empty)
                .foregroundStyle(.secondary)
        } else {
            ForEach(shown) { item in
                requestCard(item)
            }
        }
    }

    @ViewBuilder
    private func requestCard(_ item: AccessRequestItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(.headline)
            if !item.contact.isEmpty {
                Text("Reach them: \(item.contact)").font(.subheadline)
            }
            if !item.whoYouAre.isEmpty {
                Text(item.whoYouAre).font(.body)
            }
            if let why = item.whyHere, !why.isEmpty {
                Text(why).font(.body).foregroundStyle(.secondary)
            }
            Text(sightSpoken(item))
                .font(.subheadline)
            if item.status != "pending" {
                Text(statusSpoken(item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let call = callSpoken(item) {
                Text(call)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)

        if item.status == "pending" {
            Picker(selection: sightBinding(item)) {
                ForEach(AccessSightChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            } label: {
                Text("Screen for \(item.name)")
            }
            .pickerStyle(.menu)
            .accessibilityHint("Starts on their own answer. Change it only if you know better; it goes on their account when you approve.")
            Button {
                Task { await decide(item, audience: "adult") }
            } label: {
                Label(deciding.contains(item.id) ? "Working…" : "Approve as an adult", systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityHint("Approves \(item.name) and makes their account.")
            Button {
                Task { await decide(item, audience: "child") }
            } label: {
                Label(deciding.contains(item.id) ? "Working…" : "Approve as a kid", systemImage: "figure.and.child.holdinghands")
            }
            .accessibilityHint("Approves \(item.name) as a kid — their account gets the child protections.")
            Button(role: .destructive) {
                Task { await decide(item, audience: nil) }
            } label: {
                Label(deciding.contains(item.id) ? "Working…" : "Not this one", systemImage: "hand.raised")
            }
            .accessibilityHint("Denies the request. Nothing is sent to them — the ask just leaves the waiting list.")
        } else if item.isPhoneSignIn {
            Button {
                guard !deciding.contains(item.id) else { return }
                callAgainFor = item
            } label: {
                Label(deciding.contains(item.id) ? "Working…" : "Call again with a new password", systemImage: "phone.arrow.up.right")
            }
            .accessibilityHint("Asks first. Makes \(item.name) a new password, then Kade AI calls them and reads it.")
            if item.welcomeCallStatus != "not-needed" {
                Button {
                    Task { await markSignedIn(item) }
                } label: {
                    Label(deciding.contains(item.id) ? "Working…" : "Already signed in", systemImage: "checkmark.circle")
                }
                .accessibilityHint("Nothing is reset and nobody is called. \(item.name) just stops showing here.")
            }
        }
    }

    private func sightBinding(_ item: AccessRequestItem) -> Binding<AccessSightChoice> {
        Binding(
            get: { sightPicks[item.id] ?? AccessSightChoice(serverValue: item.sight) },
            set: { picked in
                if picked == AccessSightChoice(serverValue: item.sight) {
                    sightPicks[item.id] = nil
                } else {
                    sightPicks[item.id] = picked
                }
            }
        )
    }

    private func sightSpoken(_ item: AccessRequestItem) -> String {
        let when = item.status == "pending" ? "They said" : "When approved, the screen answer was"
        switch item.sight ?? "" {
        case "sighted": return item.status == "pending" ? "\(when): I'll look at the screen." : "\(when): looks at the screen."
        case "nonvisual": return item.status == "pending" ? "\(when): I'll listen, I use a screen reader." : "\(when): listens, uses a screen reader."
        default: return item.status == "pending" ? "They didn't say whether they'll look at the screen." : "\(when): not said."
        }
    }

    private func statusSpoken(_ item: AccessRequestItem) -> String {
        switch item.status {
        case "approved":
            let who = "Approved\(item.audience == "child" ? " as a kid" : " as an adult")."
            if item.hasAccount && item.usesPhoneLogin { return who + " Signs in with their phone number." }
            return who
        case "denied": return "Denied."
        default: return "Waiting."
        }
    }

    /// One plain sentence about the welcome call, or nil when there is none
    /// to talk about.
    private func callSpoken(_ item: AccessRequestItem) -> String? {
        guard item.isPhoneSignIn else { return nil }
        var parts: [String] = []
        switch item.welcomeCallStatus {
        case "":
            parts.append("No welcome call yet, so they may never have heard their password.")
        case "placed":
            parts.append("Welcome call placed\(whenSpoken(item.welcomeCallAt)).")
        case "voicemail":
            parts.append("The welcome call reached voicemail\(whenSpoken(item.welcomeCallAt)), so no password was left. Call again.")
        case "failed":
            let why = item.welcomeCallNote.isEmpty ? "" : ": \(item.welcomeCallNote)"
            parts.append("The welcome call couldn't be placed\(why).")
        case "off":
            parts.append("Welcome calls are switched off; read them the password yourself.")
        case "not-needed":
            parts.append("Marked already signed in.")
        default:
            parts.append("Welcome call: \(item.welcomeCallStatus).")
        }
        if !item.welcomeCallOutcome.isEmpty, item.welcomeCallStatus != "not-needed" {
            parts.append(item.welcomeCallOutcome)
        }
        if item.welcomeCallCount > 1 {
            parts.append("Called \(item.welcomeCallCount) times.")
        }
        return parts.joined(separator: " ")
    }

    /// " 2 hours ago", or "" when the time is missing or unreadable.
    private func whenSpoken(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return "" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return " " + relative.localizedString(for: date, relativeTo: Date())
    }

    private func decide(_ item: AccessRequestItem, audience: String?) async {
        guard !deciding.contains(item.id) else { return } // politely decline the double-tap
        deciding.insert(item.id)
        defer { deciding.remove(item.id) }
        do {
            if let audience {
                let picked = sightPicks[item.id]
                let decision = try await serviceBox.service.approve(id: item.id, audience: audience, sight: picked)
                sightPicks[item.id] = nil
                showBlessing(decision, for: item)
                statusLine = "\(item.name) approved."
                UIAccessibility.post(notification: .announcement, argument: approvedSpoken(decision, name: item.name))
            } else {
                try await serviceBox.service.deny(id: item.id)
                statusLine = "\(item.name)'s request denied."
                UIAccessibility.post(notification: .announcement, argument: "Denied.")
            }
            await load()
        } catch {
            failed(error)
        }
    }

    /// The post-approve announcement, matching what actually happened.
    private func approvedSpoken(_ decision: AccessRequestDecision, name: String) -> String {
        if decision.needsEmail == true {
            return "\(name) approved, but no account could be made. The message at the top says why."
        }
        switch decision.welcomeCallStatus ?? "" {
        case "placed":
            return "\(name) approved. Kade AI is calling them now to read their sign-in and password. The same message is at the top if you need to read it to them."
        case "off", "failed":
            return "\(name) approved, but the welcome call didn't go out. Their password is in the message at the top; read it to them yourself."
        default:
            return "\(name) approved. The welcome message is at the top — copy it and send it yourself."
        }
    }

    private func callAgain(_ item: AccessRequestItem) async {
        guard !deciding.contains(item.id) else { return }
        deciding.insert(item.id)
        defer { deciding.remove(item.id) }
        do {
            let decision = try await serviceBox.service.welcomeCall(id: item.id, skip: false)
            showBlessing(decision, for: item)
            let spoken: String
            switch decision.welcomeCallStatus ?? "" {
            case "placed":
                spoken = "New password made. Kade AI is calling \(item.name) now to read it."
            default:
                spoken = "New password made, but the call didn't go out. The new password is in the message at the top; read it to \(item.name) yourself."
            }
            statusLine = spoken
            UIAccessibility.post(notification: .announcement, argument: spoken)
            await load()
        } catch {
            failed(error)
        }
    }

    private func markSignedIn(_ item: AccessRequestItem) async {
        guard !deciding.contains(item.id) else { return }
        deciding.insert(item.id)
        defer { deciding.remove(item.id) }
        do {
            _ = try await serviceBox.service.welcomeCall(id: item.id, skip: true)
            statusLine = "\(item.name) marked already signed in."
            UIAccessibility.post(notification: .announcement, argument: "Marked. \(item.name) won't show here any more.")
            await load()
        } catch {
            failed(error)
        }
    }

    private func showBlessing(_ decision: AccessRequestDecision, for item: AccessRequestItem) {
        blessingText = decision.readyMessage
        blessingFor = item.name
        blessingCall = decision.welcomeCallStatus
        copiedConfirm = false
    }

    private func failed(_ error: Error) {
        if let refusal = error as? AccessRequestFailure {
            statusLine = refusal.message
            UIAccessibility.post(notification: .announcement, argument: refusal.message)
        } else {
            statusLine = "That didn't go through — try again in a moment."
            UIAccessibility.post(notification: .announcement, argument: "That didn't go through.")
        }
    }

    /// Always reads everything, the way her web page does, and sorts it
    /// here: the default view needs the approved phone sign-ins too.
    private func load() async {
        isLoading = items.isEmpty
        loadError = nil
        do {
            items = try await serviceBox.service.list(status: "all")
        } catch {
            loadError = "Couldn't reach the door list. Check the connection and try again."
        }
        isLoading = false
    }
}
