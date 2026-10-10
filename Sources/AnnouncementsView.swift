import SwiftUI

// MARK: - Announcements (Part 112, build 258)
//
// Her report, the night the 914-char What's New digest fired: iOS truncated
// the banner after a few sentences, the tap opened a brand-new conversation
// (the app's launch default — Part 83's bug back for an unrouted push type),
// and once the banner was gone the text existed NOWHERE a person could
// reach — the bridge kept no broadcast history and the Alerts screen is the
// nudge queue, which a broadcast never touches.
//
// This screen is the fix she chose (option B, with the route as option A):
// the bridge now stores the last 50 broadcasts in a volume-backed ring, the
// fork serves them to any signed-in seat at GET /api/kade/announcements, and
// a broadcast push now defaults to route "announcements" so the tap lands
// HERE — including for a digest you missed, which is the part no push can
// ever give you back.
//
// Server contract (fork api/server/routes/kade.js, Part 112):
//   GET /api/kade/announcements   JWT -> 200 { broadcasts: [ { id, ts,
//     title, body, agentId, agentName, sent, backfilled? } ] } — newest
//     first, capped 50 bridge-side. `sent` is how many devices took the
//     push (null on a backfilled row); it is server bookkeeping and is
//     deliberately not shown or spoken here.

@MainActor
final class AnnouncementsService: ObservableObject {
    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct AnnouncementsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable { let error: String? }

    func load() async throws -> [Announcement] {
        let req = client.request(path: "api/kade/announcements", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let msg = (try? decoder.decode(ServerError.self, from: data))?.error
            throw AnnouncementsError(message: msg ?? "Couldn't load announcements.")
        }
        struct Wrapper: Decodable { let broadcasts: [Announcement]? }
        return (try? decoder.decode(Wrapper.self, from: data))?.broadcasts ?? []
    }
}

struct Announcement: Decodable, Identifiable {
    let id: String?
    let ts: String?
    let title: String?
    let body: String?
    /// Optional explicit chat target. Old announcements remain plain text.
    let kadeRoute: String?
    let kadeAgentId: String?
    let agentName: String?
    private enum CodingKeys: String, CodingKey {
        case id, ts, title, body, kadeRoute, kadeAgentId, agentName
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try? values.decode(String.self, forKey: .id)
        ts = try? values.decode(String.self, forKey: .ts)
        title = try? values.decode(String.self, forKey: .title)
        body = try? values.decode(String.self, forKey: .body)
        kadeRoute = try? values.decode(String.self, forKey: .kadeRoute)
        kadeAgentId = try? values.decode(String.self, forKey: .kadeAgentId)
        agentName = try? values.decode(String.self, forKey: .agentName)
    }
    /// Identifiable fallback only — a row with no id can't be allowed to crash.
    var stableId: String { id ?? (ts ?? "") + (title ?? "") }
}

extension Announcement {
    var listId: String { stableId }
    var chatActionTitle: String? {
        guard let route = kadeRoute,
              KadeFreshAgentChatParser.targetID(routeName: route, agentValue: kadeAgentId) != nil else { return nil }
        if kadeAgentId == CharacterMotion.angelID { return "Chat with Angel" }
        let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Open new chat" : "Chat with " + String(name.prefix(80))
    }
}

/// The announcements list. Layout follows AlertsView's proven
/// List-with-Sections shape; each row is one VoiceOver element (the same
/// `.accessibilityElement(children: .ignore)` + explicit-label pattern every
/// list in this app uses — fine in Lists, broken in Forms, per the build-135
/// lesson in AgentEditorView).
struct AnnouncementsView: View {
    let apiClient: KadeAPIClient

    @StateObject private var service: AnnouncementsService

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: AnnouncementsService(client: apiClient))
    }

    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var announcements: [Announcement] = []

    var body: some View {
        List {
            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("Try again") {
                        Task { await load() }
                    }
                }
            }

            Section {
                if isLoading && announcements.isEmpty {
                    ProgressView("Loading…")
                        .accessibilityLabel("Loading announcements")
                } else if announcements.isEmpty {
                    // Redesign B10: the empty list says what goes here. One
                    // VoiceOver stop, as before.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No announcements yet")
                            .font(.headline)
                        Text("News about the app from Kade lands here.")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(announcements, id: \.listId) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title ?? "Kade-AI")
                                    .font(.headline)
                                Text(item.body ?? "")
                                    .font(.body)
                                Text(when(item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(item.title ?? "Kade-AI"). \(item.body ?? ""). \(when(item))")
                            if let title = item.chatActionTitle {
                                Button(title) {
                                    // Parse on activation: each tap receives its
                                    // own fresh identity, never a cached row nonce.
                                    guard let route = item.kadeRoute,
                                          let request = KadeFreshAgentChatParser.push(routeName: route,
                                            agentValue: item.kadeAgentId) else { return }
                                    IntentRouter.shared.requestFreshAgentChat(request)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Starts a new conversation with this character.")
                            }
                        }
                    }
                }
            } header: {
                Text("What's New")
            } footer: {
                Text("Platform news sent to the whole family, newest first. The push notification is just the headline — the full text is always here, and Help has the details.")
            }
        }
        .navigationTitle("Announcements")
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            announcements = try await service.load()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func when(_ item: Announcement) -> String {
        guard let ts = item.ts else { return "" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        guard let date else { return ts }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
