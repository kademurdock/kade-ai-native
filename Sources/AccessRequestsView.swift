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

    private enum Keys: String, CodingKey {
        case id, name, contact, whoYouAre, whyHere, status, audience, createdAt
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
    }
}

private struct AccessRequestListResponse: Decodable {
    let requests: [AccessRequestItem]
}

private struct ApproveResponse: Decodable {
    let ok: Bool?
    let readyMessage: String?
    let contact: String?
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

    /// Returns the ready-to-send welcome text (with the right reg code baked
    /// in server-side) so the UI can hand it to the clipboard.
    func approve(id: String, audience: String) async throws -> String? {
        var req = client.request(path: "api/admin/access-requests/\(id)/approve", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["audience": audience])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try? JSONDecoder().decode(ApproveResponse.self, from: data).readyMessage
    }

    func deny(id: String) async throws {
        var req = client.request(path: "api/admin/access-requests/\(id)/deny", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (_, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
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
    @State private var copiedConfirm = false
    @State private var statusLine: String?

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
                    .accessibilityHint("Puts the whole welcome message, code included, on your clipboard. You send it yourself — the code never rides an email.")
                    Button {
                        self.blessingText = nil
                        self.blessingFor = nil
                        self.copiedConfirm = false
                    } label: {
                        Label("Done with this one", systemImage: "checkmark")
                    }
                } header: {
                    Text("Approved — send them the welcome")
                } footer: {
                    Text("You deliver this personally, by text or however you reach them. That last step staying human is the point.")
                }
            }

            Section {
                if isLoading {
                    Text("Checking the front door…")
                        .foregroundStyle(.secondary)
                } else if let loadError {
                    Text(loadError)
                    Button("Try again") { Task { await load() } }
                } else if items.isEmpty {
                    Text(showAll ? "No requests yet — the door hasn't been knocked on." : "Nobody's waiting at the door right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        requestCard(item)
                    }
                }
            } header: {
                Text(showAll ? "All requests" : "Waiting at the door")
            } footer: {
                Text("People who found the login page and asked to join. Approve as an adult or a kid — the right registration code rides the welcome message either way.")
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
            if showAll {
                Text(statusSpoken(item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)

        if item.status == "pending" {
            Button {
                Task { await decide(item, audience: "adult") }
            } label: {
                Label(deciding.contains(item.id) ? "Working…" : "Approve as an adult", systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityHint("Marks \(item.name) approved and hands you the adult welcome message to send.")
            Button {
                Task { await decide(item, audience: "child") }
            } label: {
                Label(deciding.contains(item.id) ? "Working…" : "Approve as a kid", systemImage: "figure.and.child.holdinghands")
            }
            .accessibilityHint("Approves \(item.name) with the kid registration code — their account gets the child protections.")
            Button(role: .destructive) {
                Task { await decide(item, audience: nil) }
            } label: {
                Label(deciding.contains(item.id) ? "Working…" : "Not this one", systemImage: "hand.raised")
            }
            .accessibilityHint("Denies the request. Nothing is sent to them — the ask just leaves the waiting list.")
        }
    }

    private func statusSpoken(_ item: AccessRequestItem) -> String {
        switch item.status {
        case "approved": return "Approved\(item.audience == "child" ? " as a kid" : " as an adult")."
        case "denied": return "Denied."
        default: return "Waiting."
        }
    }

    private func decide(_ item: AccessRequestItem, audience: String?) async {
        guard !deciding.contains(item.id) else { return } // politely decline the double-tap
        deciding.insert(item.id)
        defer { deciding.remove(item.id) }
        do {
            if let audience {
                let message = try await serviceBox.service.approve(id: item.id, audience: audience)
                blessingText = message
                blessingFor = item.name
                copiedConfirm = false
                statusLine = "\(item.name) approved."
                UIAccessibility.post(notification: .announcement, argument: "\(item.name) approved. The welcome message is at the top — copy it and send it yourself.")
            } else {
                try await serviceBox.service.deny(id: item.id)
                statusLine = "\(item.name)'s request denied."
                UIAccessibility.post(notification: .announcement, argument: "Denied.")
            }
            await load()
        } catch {
            statusLine = "That didn't go through — try again in a moment."
            UIAccessibility.post(notification: .announcement, argument: "That didn't go through.")
        }
    }

    private func load() async {
        isLoading = items.isEmpty
        loadError = nil
        do {
            items = try await serviceBox.service.list(status: showAll ? "all" : "pending")
        } catch {
            loadError = "Couldn't reach the door list. Check the connection and try again."
        }
        isLoading = false
    }
}
