import SwiftUI
import UIKit

/// Session 24, the leftovers list's "natural big rock": the native Admin
/// section. Everything here mirrors an admin-guarded fork surface that was
/// web-only until now -- the usage dashboard (per-person CARDS, the same
/// de-tabled shape Kade asked the web version into), the feedback reports
/// pile with triage, and the read-only activity logs drill-down (users ->
/// conversations -> messages, session 21h's "if someone says my chatbot did
/// this, I can pull up the log").
///
/// Access: every route this file calls is `requireAdminAccess` server-side;
/// the entry card on the home screen only shows for `role == "ADMIN"`, but
/// that's courtesy, not security -- the server is the gate.
///
/// VoiceOver rules inherited from the rest of the app: information cards
/// are ONE spoken element each; every interactive control is a plain
/// Button that owns its own accessibility (never `children: .ignore` on a
/// Button, never a control nested inside another's label -- the Amber
/// rule); each drill-down level pushes via `.navigationDestination(item:)`
/// keyed to its OWN dedicated type (the build-121 lesson: two
/// registrations for one type in one stack silently breaks row taps).

// MARK: - Server shapes

/// GET /api/kade/usage?days=30 -- shape read off the fork's kade.js and
/// verified against a live admin call. Every field optional-with-fallback:
/// an admin dashboard that dies on one null teaches nothing.
struct AdminUsageReport: Decodable {
    struct Pair: Decodable {
        var allTime: Double?
        var window: Double?
    }
    struct Totals: Decodable {
        var llmSpendUSD: Pair?
        var extraSpendUSD: Pair?
        var grandSpendUSD: Pair?
        var balanceUSD: Double?
    }
    struct ServiceStat: Decodable {
        var unit: String?
        var quantity: Pair?
        var costUSD: Pair?
    }
    struct Person: Decodable {
        var userId: String
        var name: String?
        var email: String?
        var role: String?
        var balanceUSD: Double?
        var llmSpendUSD: Pair?
        var services: [String: ServiceStat]?
    }
    struct Inworld: Decodable {
        var monthChars: Double?
        var includedChars: Double?
        var overagePerMillionUSD: Double?
    }
    var generatedAt: String?
    var windowDays: Int?
    var totals: Totals?
    var inworld: Inworld?
    var perService: [String: ServiceStat]?
    var perUser: [Person]?
}

/// GET /api/kade/usage-by-model -- `{ models: [{model, spendUSD, txns}] }`.
struct AdminModelSpend: Decodable, Identifiable {
    var model: String
    var spendUSD: Double
    var txns: Int
    var id: String { model }
}

/// One report from GET /api/kade/feedback. Lenient by hand: `user` is a
/// Mongo populate that can be a {name,email} object, null, or (if a
/// reporter's account was ever deleted) a bare id string -- one odd row
/// must never fail the whole pile out of loading.
struct AdminFeedbackItem: Decodable, Identifiable, Hashable {
    let rawId: String
    let category: String
    let subject: String?
    let detail: String
    let agent: String?
    let surface: String?
    var status: String
    let createdAt: String?
    let reporterName: String?
    let reporterEmail: String?

    var id: String { rawId }

    static func == (lhs: AdminFeedbackItem, rhs: AdminFeedbackItem) -> Bool {
        lhs.rawId == rhs.rawId && lhs.status == rhs.status
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(rawId)
        hasher.combine(status)
    }

    private enum Keys: String, CodingKey {
        case rawId = "_id"
        case category, subject, detail, agent, surface, status, createdAt, user
    }
    private enum UserKeys: String, CodingKey { case name, email }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.rawId = try c.decode(String.self, forKey: .rawId)
        self.category = (try? c.decode(String.self, forKey: .category)) ?? "feedback"
        self.subject = try? c.decode(String.self, forKey: .subject)
        self.detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        self.agent = try? c.decode(String.self, forKey: .agent)
        self.surface = try? c.decode(String.self, forKey: .surface)
        self.status = (try? c.decode(String.self, forKey: .status)) ?? "open"
        self.createdAt = try? c.decode(String.self, forKey: .createdAt)
        if let u = try? c.nestedContainer(keyedBy: UserKeys.self, forKey: .user) {
            self.reporterName = try? u.decode(String.self, forKey: .name)
            self.reporterEmail = try? u.decode(String.self, forKey: .email)
        } else {
            self.reporterName = nil
            self.reporterEmail = nil
        }
    }
}

/// GET /api/kade/admin/logs-users -> `{ users: [...] }`.
struct AdminLogUser: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
    let role: String
    let convoCount: Int
}

/// GET /api/kade/admin/logs-convos?userId= -> `{ convos: [...] }`.
struct AdminLogConvo: Decodable, Identifiable, Hashable {
    let conversationId: String
    let title: String
    let updatedAt: String?
    let endpoint: String?
    var id: String { conversationId }
}

/// GET /api/kade/admin/logs-messages?conversationId= -> `{ messages: [...] }`.
/// No per-message id in the payload -- rendered by position, read-only.
struct AdminLogMessage: Decodable {
    let sender: String
    let isUser: Bool
    let text: String
    let createdAt: String?
}

// MARK: - Service

enum AdminError: Error {
    case server(Int)
}

/// Thin fetch layer over the admin routes. Owned per-screen (each view
/// creates its own around the shared `KadeAPIClient`), matching how
/// Matchmaker/GameRoom/Creations already work -- no global cache: admin
/// data should be FRESH every visit, that's the point of checking it.
@MainActor
final class AdminService: ObservableObject {
    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    func usage(days: Int = 30) async throws -> AdminUsageReport {
        let req = client.request(
            path: "api/kade/usage",
            authorized: true,
            queryItems: [URLQueryItem(name: "days", value: String(days))]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw AdminError.server(http.statusCode) }
        return try decoder.decode(AdminUsageReport.self, from: data)
    }

    func usageByModel() async throws -> [AdminModelSpend] {
        struct Wrapper: Decodable { let models: [AdminModelSpend] }
        let req = client.request(path: "api/kade/usage-by-model", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw AdminError.server(http.statusCode) }
        return try decoder.decode(Wrapper.self, from: data).models
    }

    func feedback(openOnly: Bool) async throws -> [AdminFeedbackItem] {
        let req = client.request(
            path: "api/kade/feedback",
            authorized: true,
            queryItems: [URLQueryItem(name: "status", value: openOnly ? "open" : "all")]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw AdminError.server(http.statusCode) }
        return try decoder.decode([AdminFeedbackItem].self, from: data)
    }

    /// POST /api/kade/feedback/:id/status. Returns the server-confirmed
    /// status string, or nil on failure.
    func setFeedbackStatus(id: String, status: String) async -> String? {
        var req = client.request(path: "api/kade/feedback/\(id)/status", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["status": status])
        guard let (data, http) = try? await client.send(req), http.statusCode == 200 else { return nil }
        struct Confirm: Decodable { let status: String? }
        return (try? decoder.decode(Confirm.self, from: data))?.status ?? status
    }

    func logsUsers() async throws -> [AdminLogUser] {
        struct Wrapper: Decodable { let users: [AdminLogUser] }
        let req = client.request(path: "api/kade/admin/logs-users", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw AdminError.server(http.statusCode) }
        return try decoder.decode(Wrapper.self, from: data).users
    }

    func logsConvos(userId: String) async throws -> [AdminLogConvo] {
        struct Wrapper: Decodable { let convos: [AdminLogConvo] }
        let req = client.request(
            path: "api/kade/admin/logs-convos",
            authorized: true,
            queryItems: [URLQueryItem(name: "userId", value: userId)]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw AdminError.server(http.statusCode) }
        return try decoder.decode(Wrapper.self, from: data).convos
    }

    func logsMessages(conversationId: String) async throws -> [AdminLogMessage] {
        struct Wrapper: Decodable { let messages: [AdminLogMessage] }
        let req = client.request(
            path: "api/kade/admin/logs-messages",
            authorized: true,
            queryItems: [URLQueryItem(name: "conversationId", value: conversationId)]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw AdminError.server(http.statusCode) }
        return try decoder.decode(Wrapper.self, from: data).messages
    }
}

// MARK: - Formatting helpers (file-scoped)

func adminUSD(_ value: Double?) -> String {
    let v = value ?? 0
    if v != 0 && abs(v) < 0.01 { return String(format: "$%.4f", v) }
    return String(format: "$%.2f", v)
}

func adminCount(_ value: Double?) -> String {
    let v = Int((value ?? 0).rounded())
    return NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
}

// MARK: - Root

struct AdminView: View {
    let apiClient: KadeAPIClient

    private enum Route: String, Identifiable, Hashable {
        case usage, feedback, logs
        var id: String { rawValue }
    }
    @State private var route: Route?

    var body: some View {
        List {
            Section {
                Button { route = .usage } label: {
                    Label("Usage dashboard", systemImage: "chart.bar")
                }
                .accessibilityHint("Spending, balances, the voice pool, and a card for every person.")

                Button { route = .feedback } label: {
                    Label("Feedback reports", systemImage: "exclamationmark.bubble")
                }
                .accessibilityHint("Bug reports, ideas, and feedback people have filed. You can mark each one handled.")

                Button { route = .logs } label: {
                    Label("Activity logs", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityHint("Read-only: everyone on the instance, their conversations, and what was said.")
            } footer: {
                Text("Admin only. Everything here is also on the web dashboards; this is the native, screen-reader-first version.")
            }
        }
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { destination in
            switch destination {
            case .usage: AdminUsageView(service: AdminService(client: apiClient))
            case .feedback: AdminFeedbackView(service: AdminService(client: apiClient))
            case .logs: AdminLogsUsersView(service: AdminService(client: apiClient))
            }
        }
    }
}

// MARK: - Usage dashboard

struct AdminUsageView: View {
    @ObservedObject var service: AdminService

    @State private var report: AdminUsageReport?
    @State private var models: [AdminModelSpend] = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading the usage dashboard…")
                    .accessibilityLabel("Loading the usage dashboard")
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError).multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if let report {
                dashboard(report)
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            report = try await service.usage()
            // Second, separate admin call; a failure here shouldn't sink
            // the whole dashboard -- the models section just stays empty.
            models = (try? await service.usageByModel()) ?? []
        } catch {
            loadError = "Couldn't load the usage dashboard. Check your connection and try again."
        }
        isLoading = false
    }

    private func dashboard(_ r: AdminUsageReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                totalsCard(r)
                if let inworld = r.inworld { inworldCard(inworld) }

                if let perService = r.perService, !perService.isEmpty {
                    Text("By service")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(perService.keys.sorted(), id: \.self) { name in
                        if let s = perService[name] { serviceCard(name: name, s) }
                    }
                }

                if !models.isEmpty {
                    Text("By model")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(models) { m in
                        card("\(m.model): \(adminUSD(m.spendUSD)) across \(m.txns) turns, all time.")
                    }
                }

                if let people = r.perUser, !people.isEmpty {
                    Text("People")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(people, id: \.userId) { person in
                        personCard(person, windowDays: r.windowDays ?? 30)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await load()
            KadeHaptics.tap()
        }
    }

    private func totalsCard(_ r: AdminUsageReport) -> some View {
        let days = r.windowDays ?? 30
        let t = r.totals
        let text = "All spending: \(adminUSD(t?.grandSpendUSD?.allTime)) all time, "
            + "\(adminUSD(t?.grandSpendUSD?.window)) in the last \(days) days. "
            + "Chat models \(adminUSD(t?.llmSpendUSD?.allTime)) all time; "
            + "other services \(adminUSD(t?.extraSpendUSD?.allTime)). "
            + "Balances held across everyone: \(adminUSD(t?.balanceUSD))."
        return card(text, prominent: true)
    }

    private func inworldCard(_ p: AdminUsageReport.Inworld) -> some View {
        let used = p.monthChars ?? 0
        let included = p.includedChars ?? 25_000_000
        let percent = included > 0 ? Int((used / included * 100).rounded()) : 0
        let text = "Voice pool this month: \(adminCount(used)) of \(adminCount(included)) characters — \(percent) percent. "
            + "Site and app voice only; phone-call voice isn't metered here."
        return card(text)
    }

    private func serviceCard(name: String, _ s: AdminUsageReport.ServiceStat) -> some View {
        let unit = s.unit.map { $0 + "s" } ?? "uses"
        let text = "\(name): \(adminCount(s.quantity?.allTime)) \(unit), "
            + "costing \(adminUSD(s.costUSD?.allTime)) all time."
        return card(text)
    }

    private func personCard(_ person: AdminUsageReport.Person, windowDays: Int) -> some View {
        var lines: [String] = []
        let who = person.name ?? person.email ?? person.userId
        var headline = who
        if let role = person.role, role == "ADMIN" { headline += " (admin)" }
        lines.append(headline + ".")
        lines.append("Balance \(adminUSD(person.balanceUSD)).")
        lines.append("Chat spend \(adminUSD(person.llmSpendUSD?.window)) in the last \(windowDays) days, \(adminUSD(person.llmSpendUSD?.allTime)) all time.")
        if let services = person.services, !services.isEmpty {
            for name in services.keys.sorted() {
                guard let s = services[name] else { continue }
                lines.append("\(name): \(adminCount(s.quantity?.allTime)) \(s.unit.map { $0 + "s" } ?? "uses"), \(adminUSD(s.costUSD?.allTime)).")
            }
        }
        return card(lines.joined(separator: " "))
    }

    /// One information card = ONE VoiceOver element. Static text only --
    /// no interactive children, so combining is safe (the Amber rule is
    /// about Buttons, not plain cards).
    private func card(_ text: String, prominent: Bool = false) -> some View {
        Text(text)
            .font(prominent ? .body.weight(.semibold) : .body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

// MARK: - Feedback triage

struct AdminFeedbackView: View {
    @ObservedObject var service: AdminService

    @State private var items: [AdminFeedbackItem] = []
    @State private var openOnly = true
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selected: AdminFeedbackItem?
    @AccessibilityFocusState private var focusedReportID: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading feedback reports…")
                    .accessibilityLabel("Loading feedback reports")
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError).multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                list
            }
        }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: openOnly) { _, _ in
            Task { await load() }
        }
    }

    private var list: some View {
        List {
            Section {
                Picker("Which reports", selection: $openOnly) {
                    Text("Open").tag(true)
                    Text("Everything").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Open shows reports nobody has handled yet. Everything includes handled ones too.")
            }
            if items.isEmpty {
                Text(openOnly
                     ? "No open reports. Everything filed has been handled."
                     : "No reports at all yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(items) { item in
                        Button {
                            selected = item
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rowTitle(item))
                                    .font(.body)
                                Text(rowSubtitle(item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityFocused($focusedReportID, equals: item.id)
                                .accessibilityLabel("\(rowTitle(item)). \(rowSubtitle(item))")
                        .accessibilityHint("Opens the full report, where you can mark it handled.")
                    }
                } footer: {
                    Text("\(items.count) report\(items.count == 1 ? "" : "s"). Newest first.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await load()
            KadeHaptics.tap()
        }
        .navigationDestination(item: $selected) { item in
            AdminFeedbackDetailView(service: service, item: item) { newStatus in
                applyStatus(newStatus, to: item.id)
            }
        }
    }

    private func rowTitle(_ item: AdminFeedbackItem) -> String {
        let kind = item.category.capitalized
        if let subject = item.subject, !subject.isEmpty { return "\(kind): \(subject)" }
        let trimmed = item.detail.prefix(60)
        return "\(kind): \(trimmed)\(item.detail.count > 60 ? "…" : "")"
    }

    private func rowSubtitle(_ item: AdminFeedbackItem) -> String {
        var parts: [String] = []
        if let name = item.reporterName ?? item.reporterEmail { parts.append("From \(name)") }
        if let surface = item.surface { parts.append("via \(surface)") }
        if let relative = KadeDateFormatting.relative(from: item.createdAt ?? "") { parts.append(relative) }
        parts.append("Status: \(item.status)")
        return parts.joined(separator: ". ")
    }

    private func applyStatus(_ newStatus: String, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if openOnly && newStatus != "open" {
            items.remove(at: index)
            focusedReportID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        } else {
            items[index].status = newStatus
        }
    }

    private func load() async {
        isLoading = items.isEmpty
        loadError = nil
        do {
            items = try await service.feedback(openOnly: openOnly)
        } catch {
            loadError = "Couldn't load the feedback reports. Check your connection and try again."
        }
        isLoading = false
    }
}

struct AdminFeedbackDetailView: View {
    @ObservedObject var service: AdminService
    let item: AdminFeedbackItem
    /// Tells the list behind this screen what the new status is, so the
    /// row updates (or leaves the Open filter) without a refetch.
    let onStatusChange: (String) -> Void

    @State private var currentStatus: String
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(service: AdminService, item: AdminFeedbackItem, onStatusChange: @escaping (String) -> Void) {
        self.service = service
        self.item = item
        self.onStatusChange = onStatusChange
        self._currentStatus = State(initialValue: item.status)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                Text(item.detail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Text("Mark it")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                statusButton("acknowledged", label: "Acknowledged", detail: "Seen it; work still to do.")
                statusButton("resolved", label: "Resolved", detail: "Handled and done.")
                statusButton("wontfix", label: "Won't fix", detail: "A considered no.")
                if currentStatus != "open" {
                    statusButton("open", label: "Reopen", detail: "Put it back in the open pile.")
                }
            }
            .padding()
        }
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        var lines: [String] = []
        lines.append("\(item.category.capitalized)\(item.subject.map { ": " + $0 } ?? "").")
        if let name = item.reporterName ?? item.reporterEmail { lines.append("From \(name).") }
        if let agent = item.agent, !agent.isEmpty { lines.append("Filed through \(agent).") }
        if let surface = item.surface { lines.append("Came in via \(surface).") }
        if let relative = KadeDateFormatting.relative(from: item.createdAt ?? "") { lines.append(relative + ".") }
        lines.append("Status: \(currentStatus).")
        let text = lines.joined(separator: " ")
        return Text(text)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private func statusButton(_ status: String, label: String, detail: String) -> some View {
        Button {
            guard !isSaving else { return }
            isSaving = true
            Task {
                if let confirmed = await service.setFeedbackStatus(id: item.rawId, status: status) {
                    currentStatus = confirmed
                    onStatusChange(confirmed)
                    KadeHaptics.success()
                    UIAccessibility.post(notification: .announcement, argument: "Marked \(label).")
                } else {
                    KadeHaptics.error()
                    UIAccessibility.post(notification: .announcement, argument: "Couldn't update that report. Try again.")
                }
                isSaving = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .disabled(isSaving || currentStatus == status)
        .accessibilityLabel(currentStatus == status ? "\(label). Current status." : label)
        .accessibilityHint(detail)
    }
}

// MARK: - Logs drill-down

struct AdminLogsUsersView: View {
    @ObservedObject var service: AdminService

    @State private var users: [AdminLogUser] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selected: AdminLogUser?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading everyone…")
                    .accessibilityLabel("Loading everyone")
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError).multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                List {
                    ForEach(users) { user in
                        Button { selected = user } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.name).font(.body)
                                Text(subtitle(user))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                                .accessibilityLabel("\(user.name). \(subtitle(user))")
                        .accessibilityHint("Opens this person's conversation list.")
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await load()
                    KadeHaptics.tap()
                }
                .navigationDestination(item: $selected) { user in
                    AdminLogsConvosView(service: service, user: user)
                }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if users.isEmpty { await load() }
        }
    }

    private func subtitle(_ user: AdminLogUser) -> String {
        var parts: [String] = []
        if !user.email.isEmpty { parts.append(user.email) }
        if user.role == "ADMIN" { parts.append("admin") }
        parts.append("\(user.convoCount) conversation\(user.convoCount == 1 ? "" : "s")")
        return parts.joined(separator: ". ")
    }

    private func load() async {
        isLoading = users.isEmpty
        loadError = nil
        do {
            users = try await service.logsUsers()
        } catch {
            loadError = "Couldn't load the user list. Check your connection and try again."
        }
        isLoading = false
    }
}

struct AdminLogsConvosView: View {
    @ObservedObject var service: AdminService
    let user: AdminLogUser

    @State private var convos: [AdminLogConvo] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selected: AdminLogConvo?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading conversations…")
                    .accessibilityLabel("Loading conversations")
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError).multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if convos.isEmpty {
                Text("\(user.name) has no conversations.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(convos) { convo in
                        Button { selected = convo } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(convo.title).font(.body)
                                if let relative = KadeDateFormatting.relative(from: convo.updatedAt ?? "") {
                                    Text(relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                                .accessibilityLabel(rowLabel(convo))
                        .accessibilityHint("Opens this conversation's log, read-only.")
                    }
                }
                .listStyle(.plain)
                .navigationDestination(item: $selected) { convo in
                    AdminLogsMessagesView(service: service, convo: convo, ownerName: user.name)
                }
            }
        }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if convos.isEmpty { await load() }
        }
    }

    private func rowLabel(_ convo: AdminLogConvo) -> String {
        if let relative = KadeDateFormatting.relative(from: convo.updatedAt ?? "") {
            return "\(convo.title). \(relative)"
        }
        return convo.title
    }

    private func load() async {
        isLoading = convos.isEmpty
        loadError = nil
        do {
            convos = try await service.logsConvos(userId: user.id)
        } catch {
            loadError = "Couldn't load \(user.name)'s conversations. Check your connection and try again."
        }
        isLoading = false
    }
}

struct AdminLogsMessagesView: View {
    @ObservedObject var service: AdminService
    let convo: AdminLogConvo
    let ownerName: String

    @State private var messages: [AdminLogMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading the log…")
                    .accessibilityLabel("Loading the log")
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError).multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if messages.isEmpty {
                Text("Nothing in this conversation.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("Read-only log of \(ownerName)'s conversation, oldest first. The text shown is what they actually saw — voice tags and tool markup are already stripped by the server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                            messageCard(message)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(convo.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if messages.isEmpty { await load() }
        }
    }

    private func messageCard(_ message: AdminLogMessage) -> some View {
        let shown = message.text.isEmpty ? "(nothing shown — tool activity only)" : message.text
        let spoken = "\(message.sender): \(shown)"
        return VStack(alignment: .leading, spacing: 4) {
            Text(message.sender)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(shown)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            (message.isUser ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func load() async {
        isLoading = messages.isEmpty
        loadError = nil
        do {
            messages = try await service.logsMessages(conversationId: convo.conversationId)
        } catch {
            loadError = "Couldn't load this conversation's log. Check your connection and try again."
        }
        isLoading = false
    }
}
