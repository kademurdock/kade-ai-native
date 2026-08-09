import Foundation

/// Aug 8 2026 — THE LOGBOOK CLIENT (native half of the Living Logbook that
/// shipped platform-side this week). The fork's user lane, own entries only:
///   GET    /api/diary        JWT -> { enabled, count, entries: [...] }
///   POST   /api/diary        JWT, { text } -> { ok, date }   (manual add,
///                            SHARED scope by design — written in her own
///                            logbook, any companion may recall it)
///   DELETE /api/diary/:id    JWT -> { ok, deleted } (own entries only)
/// Entries are the dated day-to-day record the companions keep — cards hold
/// who you ARE, the logbook holds what HAPPENED. Scope is sacred: an entry
/// belongs to the character it was told to; agentName rides for display.
@MainActor
final class LogbookService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct LogbookEntry: Decodable, Identifiable, Equatable {
        let id: String
        let date: String
        let text: String
        let agentId: String?
        let agentName: String?
        let source: String?

        /// "2026-08-04" -> "Tuesday, August 4, 2026" — dates are the spine
        /// of a logbook and deserve to be spoken like dates.
        var spokenDate: String {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            parser.timeZone = TimeZone(identifier: "America/Chicago")
            guard let d = parser.date(from: date) else { return date }
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE, MMMM d, yyyy"
            return fmt.string(from: d)
        }

        /// Who holds this entry, in plain words.
        var holder: String {
            if source == "manual" { return "Added by you" }
            if let name = agentName, !name.isEmpty { return "With \(name)" }
            if (agentId ?? "").isEmpty { return "Shared with every companion" }
            return "With one of your companions"
        }
    }

    struct LogbookPage: Decodable {
        let enabled: Bool?
        let count: Int
        let entries: [LogbookEntry]
    }

    struct LogbookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable { let error: String? }

    private func message(from data: Data, fallback: String) -> String {
        (try? decoder.decode(ServerError.self, from: data))?.error ?? fallback
    }

    func load() async -> LogbookPage? {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/diary", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = message(from: data, fallback: "Could not load your logbook (\(http.statusCode)).")
                return nil
            }
            return try decoder.decode(LogbookPage.self, from: data)
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    func add(text: String) async throws {
        var req = client.request(path: "api/diary", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw LogbookError(message: message(from: data, fallback: "Could not save the entry (\(http.statusCode))."))
        }
    }

    /// Aug 9 2026 — MEMORY QUALITY PACK: fix an entry's wording in place.
    /// PATCH /api/diary/:id { text } — the server re-embeds so search keeps
    /// working on the new words; the date and who-holds-it never change.
    func edit(entry: LogbookEntry, newText: String) async throws {
        var req = client.request(path: "api/diary/\(entry.id)", method: "PATCH", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": newText])
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw LogbookError(message: message(from: data, fallback: "Could not update the entry (\(http.statusCode))."))
        }
    }

    func forget(entry: LogbookEntry) async throws {
        let req = client.request(path: "api/diary/\(entry.id)", method: "DELETE", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw LogbookError(message: message(from: data, fallback: "Could not forget that entry (\(http.statusCode))."))
        }
    }
}
