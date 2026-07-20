import Foundation

/// Per-user pronunciation dictionary (Kade, session 17, right after the
/// Spotter/Deepgram fixes shipped: "I know my name Kade is pronounced
/// Katie. What if everyone had a dictionary they can put their own names
/// in? Transcribe would benefit from a dictionary anyway."). Two effects,
/// both entirely server-side -- this file is just the CRUD client:
///   - STT (Deepgram keyterms, both phone/web calls and the Transcribe
///     feature) is biased toward each entry's `term` spelling, so it
///     recognizes it correctly instead of mishearing it.
///   - TTS (voice-message read-aloud, phone/Spotter call speech) gets
///     `term` substituted for `pronunciation` right before synthesis,
///     since none of Kade-AI's speech engines take a phoneme hint from
///     arbitrary caller text -- respelling what's actually sent to be
///     spoken is the one trick that works everywhere.
/// See the fork's `api/models/kadePronunciation.js` and kade-ai-bridge's
/// matching logic in `voice-commands.js`/`voice-stream.js` for exactly how
/// each half is consumed.
///
///   GET    /api/kade/pronunciation-dictionary       JWT -> {entries:[...]}
///   POST   /api/kade/pronunciation-dictionary       JWT, body
///                                                    {term, pronunciation}
///                                                    -> {entry}. Upserts
///                                                    BY TERM -- saving the
///                                                    same term text again
///                                                    overwrites its
///                                                    pronunciation rather
///                                                    than duplicating the
///                                                    row (server-side
///                                                    unique index on
///                                                    (userId, term)).
///   DELETE /api/kade/pronunciation-dictionary/:id   JWT -> {ok}
@MainActor
final class PronunciationDictionaryService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient
    private let decoder = JSONDecoder()

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct DictionaryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable {
        let error: String?
    }

    private func errorMessage(from data: Data, fallback: String) -> String {
        (try? decoder.decode(ServerError.self, from: data))?.error ?? fallback
    }

    private struct EntriesResponse: Decodable { let entries: [PronunciationEntry] }

    func loadEntries() async -> [PronunciationEntry] {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let req = client.request(path: "api/kade/pronunciation-dictionary", authorized: true)
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = "Couldn't load your dictionary. Try again."
                return []
            }
            return try decoder.decode(EntriesResponse.self, from: data).entries
                .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        } catch {
            loadError = "Couldn't load your dictionary. Try again."
            return []
        }
    }

    /// Upserts by `term` -- see this class's doc comment. Callers editing
    /// an EXISTING entry should pass its unchanged `term` back unchanged
    /// (see `PronunciationDictionaryView`'s editor, which keeps the term
    /// field read-only for exactly this reason) so this always updates the
    /// same row instead of creating a second, orphaned one.
    func saveEntry(term: String, pronunciation: String) async throws {
        var req = client.request(path: "api/kade/pronunciation-dictionary", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["term": term, "pronunciation": pronunciation])
        let (data, http) = try await client.send(req)
        guard (200...299).contains(http.statusCode) else {
            throw DictionaryError(message: errorMessage(from: data, fallback: "Couldn't save that entry."))
        }
    }

    func deleteEntry(id: String) async throws {
        let req = client.request(path: "api/kade/pronunciation-dictionary/\(id)", method: "DELETE", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw DictionaryError(message: errorMessage(from: data, fallback: "Couldn't remove that entry."))
        }
    }
}

/// One entry from `GET /api/kade/pronunciation-dictionary`.
struct PronunciationEntry: Decodable, Identifiable, Hashable {
    let id: String
    let term: String
    let pronunciation: String
}
