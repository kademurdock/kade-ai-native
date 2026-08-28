import Foundation

/// Aug 7 2026 (Kade: "Can we also get memory stuff on native?") — the CRUD
/// client for the platform's memory cards, mirroring the web memory panel
/// on the fork's own routes (api/server/routes/memories.js):
///   GET    /api/memories            JWT -> { memories:[...], totalTokens,
///                                    tokenLimit, usagePercentage }
///   POST   /api/memories            JWT, {key, value, agentId?} -> 201
///   PATCH  /api/memories/:key       JWT, {key?, value, agentId?}
///   DELETE /api/memories/:key?agentId= JWT -> {deleted:true}
///   PATCH  /api/memories/preferences JWT, {memories:Bool} — the
///                                    remembering on/off switch.
/// Cards carry an optional agentId/agentName — scope is sacred (an
/// agent-scoped card belongs to ONE character; shared cards belong to
/// everyone), and this screen groups them exactly that way.
@MainActor
final class MemoriesService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct MemoryCard: Decodable, Identifiable, Equatable {
        let key: String
        let value: String
        let updated_at: String?
        let agentId: String?
        let agentName: String?
        let tokenCount: Int?
        var id: String { "\(agentId ?? "shared")::\(key)" }

        /// snake_case keys read badly by ear — "dad_health" speaks as
        /// "Dad health."
        var spokenKey: String {
            key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    struct MemoriesPage: Decodable {
        let memories: [MemoryCard]
        let totalTokens: Int?
        let tokenLimit: Int?
        let usagePercentage: Int?
    }

    struct MemoriesError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable { let error: String? }

    private func message(from data: Data, fallback: String) -> String {
        (try? decoder.decode(ServerError.self, from: data))?.error ?? fallback
    }

    func load() async -> MemoriesPage? {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/memories", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = message(from: data, fallback: "Could not load memories (\(http.statusCode)).")
                return nil
            }
            return try decoder.decode(MemoriesPage.self, from: data)
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    func create(key: String, value: String) async throws {
        var req = client.request(path: "api/memories", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["key": key, "value": value])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw MemoriesError(message: message(from: data, fallback: "Could not save the memory (\(http.statusCode))."))
        }
    }

    func update(card: MemoryCard, newValue: String) async throws {
        let encodedKey = card.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? card.key
        var req = client.request(path: "api/memories/\(encodedKey)", method: "PATCH", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["value": newValue]
        if let agentId = card.agentId, !agentId.isEmpty {
            body["agentId"] = agentId
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw MemoriesError(message: message(from: data, fallback: "Could not update the memory (\(http.statusCode))."))
        }
    }

    func delete(card: MemoryCard) async throws {
        let encodedKey = card.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? card.key
        var queryItems: [URLQueryItem] = []
        if let agentId = card.agentId, !agentId.isEmpty {
            queryItems.append(URLQueryItem(name: "agentId", value: agentId))
        }
        let req = client.request(
            path: "api/memories/\(encodedKey)",
            method: "DELETE",
            authorized: true,
            queryItems: queryItems.isEmpty ? nil : queryItems
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw MemoriesError(message: message(from: data, fallback: "Could not forget that memory (\(http.statusCode))."))
        }
    }

    struct LedgerChange: Decodable, Identifiable, Equatable {
        let key: String
        let action: String
        let note: String?
        let agentId: String?
        let createdAt: String?
        var id: String { "\(createdAt ?? "")::\(key)::\(action)" }
        var spokenKey: String {
            key.replacingOccurrences(of: "_", with: " ").capitalized
        }
        /// The ledger's verb, phrased for the ear.
        var spokenAction: String {
            switch action.lowercased() {
            case "create", "created", "add": return "added"
            case "update", "updated", "rewrite": return "updated"
            case "merge", "merged": return "merged with another card"
            case "supersede", "superseded", "stale": return "marked out of date"
            case "delete", "deleted", "forget": return "removed"
            default: return action.lowercased()
            }
        }
    }

    private struct LedgerPage: Decodable {
        let count: Int?
        let changes: [LedgerChange]
    }

    /// Aug 28 2026 — "what changed this week": the caller's own consolidation
    /// trail (GET /api/memories/ledger, shipped Part 69/92.33 as the readable
    /// half of "never silent loss"; the UI half lived nowhere until now).
    /// FAIL-SOFT: any error returns an empty list and the section simply
    /// doesn't render — a missing trail must never block the cards screen.
    func loadWeekChanges(limit: Int = 20) async -> [LedgerChange] {
        do {
            let req = client.request(
                path: "api/memories/ledger",
                authorized: true,
                queryItems: [
                    URLQueryItem(name: "sinceDays", value: "7"),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
            )
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else { return [] }
            return (try? decoder.decode(LedgerPage.self, from: data))?.changes ?? []
        } catch {
            return []
        }
    }

    func setRemembering(_ enabled: Bool) async throws {
        var req = client.request(path: "api/memories/preferences", method: "PATCH", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["memories": enabled])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw MemoriesError(message: message(from: data, fallback: "Could not change the remembering switch (\(http.statusCode))."))
        }
    }
}
