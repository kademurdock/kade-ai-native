import SwiftUI
import UIKit

/// Sep 25 2026 (Part 292): Funding, the native twin of the website's Funding
/// card (usage dashboard, Part 291). Her words: "the difference between the
/// record of them paying me back and what it cost me to actually fund them."
///
/// What each person's use REALLY cost Kade (the provider's price, never the
/// doubled price people are charged), what they have paid her back, and the
/// difference; a person's repayments on record, newest first; recording a
/// new one; removing one (a void: it stays on record and leaves the sums)
/// and putting it back.
///
/// Admin only, three times over: AdminView draws the Funding row only for an
/// ADMIN seat; these screens check the seat again before they draw or fetch
/// anything; and every /api/kade/funding route is admin-gated on the server
/// (403 otherwise). App Review's demo seat sees none of it.
///
/// Words follow the website the family already knows: "really cost", "paid
/// back", "Record a repayment", "Remove" and "Put it back". VoiceOver rules
/// are AdminView's: one spoken stop per row, actions on the Actions rotor,
/// and the on-screen Remove / Put it back buttons leave the swipe order only
/// while VoiceOver is on (they stay for sight, Voice Control and Switch
/// Control).

// MARK: - Server shapes (routes/kadeFunding.js, services/kadeFunding.js compose())

/// One line of a person's cost: { feature, label, realUSD, chargedUSD, ... }.
struct FundingFeature: Decodable, Hashable {
    var feature: String?
    var label: String?
    var realUSD: Double?
}

/// One person's figures, all time. differenceUSD = realCostUSD - paidBackUSD:
/// above zero, Kade has covered more than they paid back ("behind"); below
/// zero, they are ahead.
struct FundingPerson: Decodable, Hashable, Identifiable {
    var userId: String
    var name: String?
    var admin: Bool?
    var child: Bool?
    var realCostUSD: Double?
    var paidBackUSD: Double?
    var differenceUSD: Double?
    var breakdown: [FundingFeature]?

    var id: String { userId }
}

/// GET /api/kade/funding/people?period=all_time ->
/// { generatedAt, window, totals, spoken, people, notes }.
struct FundingPeopleReport: Decodable {
    struct Totals: Decodable {
        var othersRealUSD: Double?
        var paidBackUSD: Double?
        var differenceUSD: Double?
    }
    var totals: Totals?
    var people: [FundingPerson]?
}

/// One repayment on record. GET /api/kade/funding/ledger ->
/// { entries: [{ id, userId, name, kind, usd, at, note, via, voidedAt, voidReason }] },
/// newest first.
struct FundingEntry: Decodable, Hashable, Identifiable {
    var id: String
    var userId: String?
    var name: String?
    var kind: String?
    var usd: Double?
    var at: String?
    var note: String?
    var voidedAt: String?
    var voidReason: String?

    var isRemoved: Bool { !(voidedAt ?? "").isEmpty }
}

/// POST /repayments, /repayments/:id/void and /repayments/:id/restore ->
/// { ok, duplicate?, entry, summary, spoken }.
struct FundingChange: Decodable {
    var ok: Bool?
    var duplicate: Bool?
    var entry: FundingEntry?
    var summary: FundingPerson?
}

private struct FundingLedgerPage: Decodable {
    var entries: [FundingEntry]?
}

/// The { error } a refusal carries: plain sentences written for the family.
private struct FundingRefusal: Decodable {
    var error: String?
}

// MARK: - Service

enum AdminFundingError: Error {
    /// 403: the server's admin gate said no.
    case notAdmin
    /// Any other refusal, with the server's own sentence when it sent one.
    case server(Int, String?)
}

/// Thin fetch layer over /api/kade/funding, owned by the Funding screen and
/// handed down to the person page and the record sheet. No cache: funding
/// figures should be fresh every visit.
@MainActor
final class AdminFundingService: ObservableObject {
    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    func people() async throws -> FundingPeopleReport {
        let req = client.request(
            path: "api/kade/funding/people",
            authorized: true,
            queryItems: [URLQueryItem(name: "period", value: "all_time")]
        )
        return try await send(req, as: FundingPeopleReport.self)
    }

    func ledger(userId: String) async throws -> [FundingEntry] {
        let req = client.request(
            path: "api/kade/funding/ledger",
            authorized: true,
            queryItems: [
                URLQueryItem(name: "userId", value: userId),
                URLQueryItem(name: "kind", value: "repayment"),
            ]
        )
        return try await send(req, as: FundingLedgerPage.self).entries ?? []
    }

    /// Idempotent on clientKey: the same key records once, however often it
    /// is sent (the server answers { ok, duplicate: true } the second time).
    func recordRepayment(userId: String, usd: String, day: String, note: String, clientKey: String) async throws -> FundingChange {
        let body: [String: Any] = [
            "userId": userId,
            "usd": usd,
            "at": day,
            "note": note,
            "clientKey": clientKey,
        ]
        return try await post("api/kade/funding/repayments", body)
    }

    func removeRepayment(id: String) async throws -> FundingChange {
        try await post("api/kade/funding/repayments/\(id)/void", ["reason": ""])
    }

    func putBackRepayment(id: String) async throws -> FundingChange {
        try await post("api/kade/funding/repayments/\(id)/restore", [:])
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> FundingChange {
        var req = client.request(path: path, method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req, as: FundingChange.self)
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, http) = try await client.send(req)
        if http.statusCode == 403 { throw AdminFundingError.notAdmin }
        guard http.statusCode == 200 else {
            let said = (try? decoder.decode(FundingRefusal.self, from: data))?.error
            throw AdminFundingError.server(http.statusCode, said)
        }
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Words

/// Money and sentences for these screens. Dollars always carry cents and
/// never more than two decimals (every figure is rounded to the cent before
/// adminUSD sees it); the sign lives in the words, never in the number.
enum FundingWords {
    static func cents(_ value: Double?) -> Double {
        ((value ?? 0) * 100).rounded() / 100
    }

    /// "$22.25". Always positive: "ahead" and "behind" carry the direction.
    static func money(_ value: Double?) -> String {
        adminUSD(abs(cents(value)))
    }

    static func name(_ person: FundingPerson) -> String {
        let trimmed = (person.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Someone" : trimmed
    }

    /// "$7.75 ahead", "$3.20 behind" or "even".
    static func standing(_ person: FundingPerson) -> String {
        let difference = cents(person.differenceUSD)
        if difference > 0 { return "\(money(difference)) behind" }
        if difference < 0 { return "\(money(difference)) ahead" }
        return "even"
    }

    /// The visible second line of a person's row.
    static func figures(_ person: FundingPerson) -> String {
        "Really cost \(money(person.realCostUSD)), paid back \(money(person.paidBackUSD)), \(standing(person))"
    }

    /// A person's row, spoken as one stop.
    static func rowLabel(_ person: FundingPerson) -> String {
        "\(name(person)). Really cost \(money(person.realCostUSD)), paid back \(money(person.paidBackUSD)), \(standing(person))."
    }

    /// The line at the top: everyone but Kade, all time.
    static func summary(_ totals: FundingPeopleReport.Totals?) -> String {
        let cost = cents(totals?.othersRealUSD)
        let paid = cents(totals?.paidBackUSD)
        let difference = cents(totals?.differenceUSD)
        if cost <= 0 && paid <= 0 { return "Nobody else's use has cost you anything yet." }
        let head = "Everyone else's use has really cost you \(money(cost)) in all, and they have paid you back \(money(paid))."
        if difference > 0 { return "\(head) The difference: you have covered \(money(difference)) more than they paid back." }
        if difference < 0 { return "\(head) The difference: they are \(money(difference)) ahead." }
        return "\(head) The difference is \(money(0)), so you're all square."
    }

    /// The top of a person's page: their figures and where most of it went.
    static func personSummary(_ person: FundingPerson) -> String {
        let who = name(person)
        var line = "\(who)'s use has really cost you \(money(person.realCostUSD)) in all. Paid back \(money(person.paidBackUSD)). "
        let difference = cents(person.differenceUSD)
        if difference > 0 {
            line += "\(who) is \(money(difference)) behind."
        } else if difference < 0 {
            line += "\(who) is \(money(difference)) ahead."
        } else {
            line += "You're even."
        }
        let top = (person.breakdown ?? []).filter { cents($0.realUSD) >= 0.01 }.prefix(3)
        if !top.isEmpty {
            let parts: [String] = top.map { feature in
                "\(feature.label ?? "Other") \(money(feature.realUSD))"
            }
            line += " Most of it: \(parts.joined(separator: ", "))."
        }
        if person.child == true { line += " This is a child's account." }
        return line
    }

    /// The website's clock: a picked day is stored at noon US Central, so it
    /// reads as that day here too.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.timeZone = TimeZone(identifier: "America/Chicago") ?? TimeZone.current
        return f
    }()

    /// "September 25, 2026", or nil when the stamp does not read.
    static func day(_ iso: String?) -> String? {
        guard let iso, let date = KadeDateFormatting.date(from: iso) else { return nil }
        return dayFormatter.string(from: date)
    }

    /// One repayment, spoken as one stop:
    /// "$30.00 on September 20, 2026. Note: PayPal. Removed on September 25, 2026, so it does not count."
    static func entryLabel(_ entry: FundingEntry) -> String {
        var line = money(entry.usd)
        if let when = day(entry.at) { line += " on \(when)" }
        line += "."
        let note = (entry.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            line += " Note: \(note)"
            if !(note.hasSuffix(".") || note.hasSuffix("!") || note.hasSuffix("?")) { line += "." }
        }
        if entry.isRemoved {
            line += " Removed"
            if let when = day(entry.voidedAt) { line += " on \(when)" }
            line += ", so it does not count."
            let reason = (entry.voidReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty { line += " Reason: \(reason)." }
        }
        return line
    }

    /// The picked day in the server's date-picker form, "2026-09-25".
    static func postDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// What she typed ("30", "$12.50", "1,000"), rounded to the cent, or nil.
    /// A comma is a thousands mark unless this phone writes decimals with one.
    static func amount(_ typed: String) -> Double? {
        let decimalComma = Locale.current.decimalSeparator == ","
        var cleaned = ""
        for ch in typed {
            if ch.isWhitespace || ch == "$" { continue }
            if ch == "," {
                if decimalComma { cleaned += "." }
                continue
            }
            cleaned.append(ch)
        }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return cents(value)
    }

    /// One plain sentence for a failure. A 403 is always the same sentence.
    static func message(for error: Error, fallback: String) -> String {
        guard let refusal = error as? AdminFundingError else { return fallback }
        switch refusal {
        case .notAdmin:
            return "Only Kade's account can see this."
        case .server(_, let said):
            if let said, !said.isEmpty { return said }
            return fallback
        }
    }
}

// MARK: - Everyone

struct AdminFundingView: View {
    @EnvironmentObject private var auth: AuthService
    @StateObject private var service: AdminFundingService

    @State private var report: FundingPeopleReport?
    @State private var loadError: String?
    /// Set by a person's page after a change there, so coming back reloads.
    @State private var stale = false
    @State private var selected: FundingPerson?
    @State private var recordingFor: FundingPerson?

    private static let couldNotLoad = "Couldn't load the funding figures. Check your connection and try again."

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: AdminFundingService(client: apiClient))
    }

    /// The same test AdminView and the More tab use. Any other seat sees one
    /// sentence, and nothing is fetched.
    private var isAdminSeat: Bool {
        if case .signedIn(let user) = auth.state { return user.role == "ADMIN" }
        return false
    }

    var body: some View {
        screen
            .navigationTitle("Funding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isAdminSeat {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh the funding figures")
                    }
                }
            }
            .task {
                guard isAdminSeat, report == nil || stale else { return }
                stale = false
                await load()
            }
    }

    private var screen: some View {
        content
            .navigationDestination(item: $selected) { person in
                personPage(person)
            }
            .sheet(item: $recordingFor) { person in
                recordSheet(person)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !isAdminSeat {
            Text("Only Kade's account can see this.")
                .multilineTextAlignment(.center)
                .padding()
        } else if let report {
            peopleList(report)
        } else if let loadError {
            VStack(spacing: 12) {
                Text(loadError).multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        } else {
            ProgressView("Loading the funding figures…")
                .accessibilityLabel("Loading the funding figures")
        }
    }

    private func personPage(_ person: FundingPerson) -> some View {
        AdminFundingPersonView(service: service, person: person) {
            stale = true
        }
    }

    private func recordSheet(_ person: FundingPerson) -> some View {
        AdminFundingRecordSheet(service: service, person: person) { message, _ in
            recordingFor = nil
            announceLater(message)
            Task { await load() }
        }
    }

    private func peopleList(_ report: FundingPeopleReport) -> some View {
        let people = (report.people ?? []).filter { $0.admin != true }
        return List {
            Section {
                Text(FundingWords.summary(report.totals))
                    .font(.body.weight(.semibold))
            } footer: {
                Text("Really cost is what the providers charged for each person's use, at the real price. Paid back counts only repayments recorded here; credit added with the +$5 button never counts. Fixed monthly bills are not split per person.")
            }
            Section {
                if people.isEmpty {
                    Text("Nobody else has a cost or a repayment yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(people) { person in
                        personRow(person)
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Text("Most covered first. Open a person to see their repayments and record a new one.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await load()
            KadeHaptics.tap()
        }
    }

    /// ONE VoiceOver stop with the whole sentence; recording a repayment
    /// rides the Actions rotor, and the person's page has the same button
    /// on screen for sighted use and Voice Control.
    private func personRow(_ person: FundingPerson) -> some View {
        Button {
            selected = person
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(FundingWords.name(person))
                    .font(.body)
                Text(FundingWords.figures(person))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FundingWords.rowLabel(person))
        .accessibilityHint("Opens their repayments.")
        .accessibilityAction(named: "Record a repayment") { recordingFor = person }
    }

    private func load() async {
        guard isAdminSeat else { return }
        if report == nil { loadError = nil }
        do {
            report = try await service.people()
            loadError = nil
        } catch {
            let message = FundingWords.message(for: error, fallback: Self.couldNotLoad)
            if report == nil {
                loadError = message
            } else {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

    /// The toolbar button: the same load, and it says how it went.
    private func refresh() async {
        guard isAdminSeat else { return }
        do {
            report = try await service.people()
            loadError = nil
            UIAccessibility.post(notification: .announcement, argument: "Funding figures updated.")
        } catch {
            let message = FundingWords.message(for: error, fallback: Self.couldNotLoad)
            if report == nil { loadError = message }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    /// Said a beat after the sheet closes, so the focus move does not
    /// swallow it.
    private func announceLater(_ message: String) {
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}

// MARK: - One person's repayments

struct AdminFundingPersonView: View {
    @ObservedObject var service: AdminFundingService
    /// Tells the Funding screen its figures changed, so it reloads on return.
    let onChanged: () -> Void

    @EnvironmentObject private var auth: AuthService
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    @State private var person: FundingPerson
    @State private var entries: [FundingEntry] = []
    /// The first answer has arrived; later loads refresh in place.
    @State private var loaded = false
    @State private var loadError: String?
    @State private var showingRecord = false
    @State private var removing: FundingEntry?
    /// Entry ids with a remove or put-back in flight. Nothing is ever
    /// disabled (that retires the element under the VoiceOver cursor);
    /// a repeat press says so instead.
    @State private var busy: Set<String> = []

    init(service: AdminFundingService, person: FundingPerson, onChanged: @escaping () -> Void) {
        self.service = service
        self.onChanged = onChanged
        _person = State(initialValue: person)
    }

    private var isAdminSeat: Bool {
        if case .signedIn(let user) = auth.state { return user.role == "ADMIN" }
        return false
    }

    var body: some View {
        withDialogs(content)
            .navigationTitle(FundingWords.name(person))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard isAdminSeat, !loaded else { return }
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !isAdminSeat {
            Text("Only Kade's account can see this.")
                .multilineTextAlignment(.center)
                .padding()
        } else if loaded {
            ledger
        } else if let loadError {
            VStack(spacing: 12) {
                Text(loadError).multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        } else {
            ProgressView("Loading repayments…")
                .accessibilityLabel("Loading repayments")
        }
    }

    private func withDialogs<Base: View>(_ base: Base) -> some View {
        base
            .sheet(isPresented: $showingRecord) {
                AdminFundingRecordSheet(service: service, person: person) { message, summary in
                    showingRecord = false
                    if let summary { person = summary }
                    onChanged()
                    announceLater(message)
                    Task { await load() }
                }
            }
            // Remove is one flick away in the rotor, so it asks first
            // (the website asks too). Put it back does not need asking.
            .confirmationDialog(
                removeQuestion,
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove it", role: .destructive) {
                    if let entry = removing {
                        removing = nil
                        Task { await flip(entry, remove: true) }
                    }
                }
                Button("Keep it", role: .cancel) { removing = nil }
            } message: {
                Text("It stays on record and can be put back. A removed repayment does not count as paid back.")
            }
    }

    private var removeQuestion: String {
        guard let entry = removing else { return "Remove this repayment?" }
        var what = "\(FundingWords.money(entry.usd)) from \(FundingWords.name(person))"
        if let when = FundingWords.day(entry.at) { what += " on \(when)" }
        return "Remove \(what)?"
    }

    private var ledger: some View {
        List {
            Section {
                Text(FundingWords.personSummary(person))
                    .font(.body.weight(.semibold))
                Button {
                    showingRecord = true
                } label: {
                    Label("Record a repayment", systemImage: "plus.circle")
                }
                .accessibilityHint("The amount, the day they paid, and an optional note.")
            }
            Section {
                if entries.isEmpty {
                    Text("No repayments recorded for \(FundingWords.name(person)) yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
            } header: {
                Text("Repayments on record")
            } footer: {
                Text("Newest first. A removed repayment stays on record, does not count, and can be put back.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await load()
            KadeHaptics.tap()
        }
    }

    /// The entry is ONE spoken element with Remove or Put it back on the
    /// Actions rotor. The on-screen button is a separate sibling (never a
    /// control inside another element's label) and leaves the swipe order
    /// only while VoiceOver is on.
    private func entryRow(_ entry: FundingEntry) -> some View {
        let label = FundingWords.entryLabel(entry)
        let actionName = entry.isRemoved ? "Put it back" : "Remove this repayment"
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .foregroundStyle(entry.isRemoved ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(label)
                .accessibilityAction(named: actionName) { act(on: entry) }
            Button(entry.isRemoved ? "Put it back" : "Remove") { act(on: entry) }
                .buttonStyle(.bordered)
                .accessibilityHidden(voiceOverOn)
        }
        .padding(.vertical, 2)
    }

    private func act(on entry: FundingEntry) {
        if entry.isRemoved {
            Task { await flip(entry, remove: false) }
        } else {
            removing = entry
        }
    }

    private func load() async {
        guard isAdminSeat else { return }
        if !loaded { loadError = nil }
        do {
            entries = try await service.ledger(userId: person.userId)
            loaded = true
            loadError = nil
        } catch {
            let message = FundingWords.message(
                for: error,
                fallback: "Couldn't load the repayments. Check your connection and try again."
            )
            if loaded {
                UIAccessibility.post(notification: .announcement, argument: message)
            } else {
                loadError = message
            }
        }
    }

    /// Remove (void) or put back one repayment. The row keeps its id, so
    /// VoiceOver stays on it and it now reads the other way round.
    private func flip(_ entry: FundingEntry, remove: Bool) async {
        guard isAdminSeat else { return }
        guard !busy.contains(entry.id) else {
            UIAccessibility.post(notification: .announcement, argument: "Still saving that one.")
            return
        }
        busy.insert(entry.id)
        defer { busy.remove(entry.id) }
        do {
            let change: FundingChange
            if remove {
                change = try await service.removeRepayment(id: entry.id)
            } else {
                change = try await service.putBackRepayment(id: entry.id)
            }
            if let summary = change.summary { person = summary }
            if let updated = change.entry, let index = entries.firstIndex(where: { $0.id == updated.id }) {
                entries[index] = updated
            } else {
                await load()
            }
            onChanged()
            KadeHaptics.success()
            let who = FundingWords.name(person)
            let done = remove ? "Removed" : "Put back"
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(done) \(FundingWords.money(entry.usd)) from \(who). \(who) is now \(FundingWords.standing(person))."
            )
        } catch {
            KadeHaptics.error()
            UIAccessibility.post(
                notification: .announcement,
                argument: FundingWords.message(for: error, fallback: "That did not save. Try again.")
            )
        }
    }

    private func announceLater(_ message: String) {
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}

// MARK: - Record a repayment

struct AdminFundingRecordSheet: View {
    @ObservedObject var service: AdminFundingService
    let person: FundingPerson
    /// Called once on success with the sentence to say and the person's new
    /// figures (nil for a repeat of the same submit). The presenter closes
    /// the sheet, says the sentence and refreshes.
    let onRecorded: (String, FundingPerson?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var day = Date()
    @State private var note = ""
    /// Made once, when the sheet opens: however many times Record is
    /// pressed, the server records one repayment for this sheet.
    @State private var clientKey = UUID().uuidString
    @State private var isSaving = false
    @State private var status: String?

    init(service: AdminFundingService, person: FundingPerson, onRecorded: @escaping (String, FundingPerson?) -> Void) {
        self.service = service
        self.person = person
        self.onRecorded = onRecorded
    }

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("Record a repayment")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Amount in dollars", text: $amount)
                    .keyboardType(.decimalPad)
                    .accessibilityHint("What they paid you, like 30 or 12.50.")
                DatePicker("Day they paid", selection: $day, in: ...Date(), displayedComponents: .date)
                TextField("Note (optional)", text: $note)
            } header: {
                Text("From \(FundingWords.name(person))")
            } footer: {
                Text("Only what you record here counts as paid back. Credit added with the +$5 button never does.")
            }
            Section {
                // Never disabled: a second press while saving says so, and
                // the one clientKey means it still records once.
                Button {
                    Task { await save() }
                } label: {
                    Text("Record repayment")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else {
            say("Still saving the last one.")
            return
        }
        guard !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            say("Type the amount they paid, like 30.")
            return
        }
        guard let usd = FundingWords.amount(amount), usd >= 0.01 else {
            say("The amount must be at least one cent.")
            return
        }
        guard usd <= 1000 else {
            say("That is over $1,000. Check the amount and try again.")
            return
        }
        isSaving = true
        status = "Saving…"
        do {
            let change = try await service.recordRepayment(
                userId: person.userId,
                usd: String(format: "%.2f", usd),
                day: FundingWords.postDay(day),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                clientKey: clientKey
            )
            isSaving = false
            KadeHaptics.success()
            let recorded = change.entry?.usd ?? usd
            let message = change.duplicate == true
                ? "That one was already recorded."
                : "Recorded \(FundingWords.money(recorded)) from \(FundingWords.name(person))."
            onRecorded(message, change.summary)
        } catch {
            isSaving = false
            KadeHaptics.error()
            say(FundingWords.message(for: error, fallback: "That did not save. Try again."))
        }
    }

    private func say(_ text: String) {
        status = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
