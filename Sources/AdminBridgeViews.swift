import SwiftUI
import UIKit

/// Build 197 — TWO THINGS THE PHONE COULD NEVER SEE, now on the phone.
///
/// Both of these already existed and both were only readable by someone with
/// a terminal and the bridge secret. The front desk has been taking messages
/// from unknown callers since Aug 9 (bridge 38f2846) and the crash catcher
/// has been filing stacks since Aug 4 — Kade could hear the push about each
/// one and then had no way to go look. That's the whole gap these close.
///
/// Neither screen can change anything. They are read-only by construction:
/// the fork's `/api/kade/admin/front-desk` and `/api/kade/admin/app-crashes`
/// are GET-only proxies, and the phone carries no bridge secret at all — it
/// sends the ordinary admin JWT and the server holds the key.
///
/// House rules inherited: one information card = ONE spoken element (so
/// VoiceOver reads a message or a crash as a sentence, not as eight
/// fragments the user has to reassemble); no disabled buttons; refresh is a
/// plain Button, never a gesture only.

// MARK: - Front desk

/// One message the desk took. Lenient by hand — one odd row must never fail
/// the whole list out of loading.
struct FrontDeskMessage: Decodable, Identifiable, Hashable {
    var id: String { (at ?? "") + from + message }
    let at: String?
    let from: String
    let fromName: String?
    let message: String
    let targetUserName: String?
    let context: String?

    private enum Keys: String, CodingKey {
        case at, from, fromName, message, targetUserName, context
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.at = try? c.decode(String.self, forKey: .at)
        self.from = (try? c.decode(String.self, forKey: .from)) ?? "an unknown number"
        self.fromName = try? c.decode(String.self, forKey: .fromName)
        self.message = (try? c.decode(String.self, forKey: .message)) ?? ""
        self.targetUserName = try? c.decode(String.self, forKey: .targetUserName)
        self.context = try? c.decode(String.self, forKey: .context)
    }

    /// A phone number said the way a person says it, so VoiceOver doesn't
    /// read "+18165551234" as one enormous number.
    var spokenFrom: String {
        if let fromName, !fromName.isEmpty { return fromName }
        let digits = from.filter(\.isNumber)
        guard digits.count == 10 || digits.count == 11 else { return from }
        let d = Array(digits.suffix(10))
        return "\(String(d[0...2])) \(String(d[3...5])) \(String(d[6...9]))"
    }

    /// The whole message as one sentence — the card's single spoken element.
    var spokenCard: String {
        var s = "From \(spokenFrom)"
        if let targetUserName, !targetUserName.isEmpty { s += ", for \(targetUserName)" }
        if let context, !context.isEmpty { s += ", about \(context)" }
        if let at, let rel = KadeDateFormatting.relative(from: at) { s += ", \(rel)" }
        s += ". \(message)"
        return s
    }
}

private struct FrontDeskResponse: Decodable {
    let count: Int?
    let messages: [FrontDeskMessage]?
}

// MARK: - Crash ring

struct AppCrashEntry: Decodable, Identifiable, Hashable {
    var id: String { (at ?? "") + (build ?? "") + (signature ?? "") }
    let at: String?
    let kind: String?
    let build: String?
    let device: String?
    let signature: String?
    let breadcrumbs: [String]

    private enum Keys: String, CodingKey {
        case at, kind, build, device, signature, breadcrumbs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.at = try? c.decode(String.self, forKey: .at)
        self.kind = try? c.decode(String.self, forKey: .kind)
        self.build = try? c.decode(String.self, forKey: .build)
        self.device = try? c.decode(String.self, forKey: .device)
        self.signature = try? c.decode(String.self, forKey: .signature)
        self.breadcrumbs = (try? c.decode([String].self, forKey: .breadcrumbs)) ?? []
    }

    var spokenCard: String {
        var s = (kind == "crash") ? "Crash" : (kind?.capitalized ?? "Report")
        if let build, !build.isEmpty, build != "?" { s += " on build \(build)" }
        if let device, !device.isEmpty, device != "?" { s += ", \(device)" }
        if let at, let rel = KadeDateFormatting.relative(from: at) { s += ", \(rel)" }
        if let signature, !signature.isEmpty { s += ". \(signature)" }
        return s + "."
    }
}

private struct AppCrashResponse: Decodable {
    let count: Int?
    let entries: [AppCrashEntry]?
}

// MARK: - Service

@MainActor
final class AdminBridgeService: ObservableObject {
    private let client: KadeAPIClient
    init(client: KadeAPIClient) { self.client = client }

    func frontDesk() async throws -> [FrontDeskMessage] {
        let req = client.request(path: "api/kade/admin/front-desk", method: "GET", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(FrontDeskResponse.self, from: data).messages ?? []
    }

    func crashes() async throws -> [AppCrashEntry] {
        let req = client.request(path: "api/kade/admin/app-crashes", method: "GET", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(AppCrashResponse.self, from: data).entries ?? []
    }
}

@MainActor
private final class BridgeServiceBox: ObservableObject {
    let service: AdminBridgeService
    init(client: KadeAPIClient) { self.service = AdminBridgeService(client: client) }
}

// MARK: - Front desk screen

struct FrontDeskView: View {
    let apiClient: KadeAPIClient

    @StateObject private var box: BridgeServiceBox
    @State private var items: [FrontDeskMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _box = StateObject(wrappedValue: BridgeServiceBox(client: apiClient))
    }

    var body: some View {
        List {
            Section {
                if isLoading {
                    Text("Checking the desk…").foregroundStyle(.secondary)
                } else if let loadError {
                    Text(loadError)
                    Button("Try again") { Task { await load() } }
                } else if items.isEmpty {
                    Text("No messages. Nobody the phone doesn't recognize has called.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.message).font(.body)
                            Text(headline(for: item)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        // ONE spoken element: the whole message as a sentence.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.spokenCard)
                    }
                }
            } header: {
                Text("Messages taken")
            } footer: {
                Text("When someone the phone doesn't know calls the toll-free line, the front desk takes a message instead of handing them a conversation on your dime. This is that message book — newest first, the last fifty.")
            }

            Section {
                Button { Task { await load() } } label: {
                    Label("Check for new messages", systemImage: "arrow.clockwise")
                }
                .accessibilityHint("Asks the phone bridge for the message book again.")
            }
        }
        .navigationTitle("Front Desk")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func headline(for item: FrontDeskMessage) -> String {
        var bits: [String] = ["From \(item.spokenFrom)"]
        if let t = item.targetUserName, !t.isEmpty { bits.append("for \(t)") }
        if let c = item.context, !c.isEmpty { bits.append("re: \(c)") }
        if let at = item.at, let rel = KadeDateFormatting.relative(from: at) { bits.append(rel) }
        return bits.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            items = try await box.service.frontDesk()
        } catch {
            loadError = "Couldn't reach the phone bridge. The messages are safe on it either way — try again in a minute."
        }
        isLoading = false
    }
}

// MARK: - Crash ring screen

struct AppCrashesView: View {
    let apiClient: KadeAPIClient

    @StateObject private var box: BridgeServiceBox
    @State private var items: [AppCrashEntry] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var expanded: Set<String> = []

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _box = StateObject(wrappedValue: BridgeServiceBox(client: apiClient))
    }

    var body: some View {
        List {
            Section {
                if isLoading {
                    Text("Reading the ring…").foregroundStyle(.secondary)
                } else if let loadError {
                    Text(loadError)
                    Button("Try again") { Task { await load() } }
                } else if items.isEmpty {
                    Text("Nothing here. The app hasn't crashed on any device that's reported in.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.spokenCard).font(.body)
                            if expanded.contains(item.id), !item.breadcrumbs.isEmpty {
                                Text(item.breadcrumbs.joined(separator: "\n"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.spokenCard)

                        if !item.breadcrumbs.isEmpty {
                            Button {
                                if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                            } label: {
                                Label(
                                    expanded.contains(item.id) ? "Hide what led up to it" : "What led up to it",
                                    systemImage: expanded.contains(item.id) ? "chevron.up" : "chevron.down"
                                )
                                .font(.footnote)
                            }
                            .accessibilityHint("The last few things the app did before this one. Plain breadcrumbs, not a stack trace.")
                        }
                    }
                }
            } header: {
                Text("What the app told on itself about")
            } footer: {
                Text("Every crash the app catches gets filed here automatically, newest first — you already get one push a day when it happens. The full stack stays on the server; this is the readable part. Nothing here needs doing: it's for knowing.")
            }

            Section {
                Button { Task { await load() } } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle("Crash Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            items = try await box.service.crashes()
        } catch {
            loadError = "Couldn't reach the bridge. Nothing is lost — the ring lives on the server."
        }
        isLoading = false
    }
}
