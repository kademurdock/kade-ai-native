import Foundation

/// Photo, video, and document description — the native port of the web
/// `/describe` page (Kade, session 16: "let's keep coding... mo betta stuff
/// and feachas"). A blind-first accessibility feature in its own right, not
/// just parity: point it at a photo, a video, a flyer, a PDF, or a Word
/// document and get back a full spoken description, or the verbatim text
/// for anything that has real text in it.
///
/// Two server calls, contract read straight off `api/server/routes/
/// kadeDescribe.js` and `api/server/services/kadeDescribe.js` before any
/// Swift was written — the standing rule after `DELETE /api/convos` turned
/// out to nest its arguments, applied again here:
///
///   POST /api/kade/describe/upload   JWT, multipart. Field name "media"
///                                    (matches the web page's own
///                                    `fd.append('media', f, f.name)` —
///                                    cosmetic parity, since the server's
///                                    `multer().any()` + `firstFile(req)`
///                                    actually accepts any field name).
///                                    -> 200 { ok:true, id }
///                                    -> 400 { error }
///   POST /api/kade/describe/run      JWT, JSON { id }. Runs the actual
///                                    vision/document pipeline server-side
///                                    (a few seconds) and returns the
///                                    result directly — no polling, one
///                                    request. The web page calls this
///                                    immediately after upload succeeds;
///                                    this client does the same.
///                                    -> 200 { ok:true, kind, name,
///                                       description, readText, dates,
///                                       costUSD, model } (costUSD/model
///                                       not surfaced in this app's UI —
///                                       same treatment as every other
///                                       metered call here)
///                                    -> 400/401/500 { error }
///   POST /api/kade/describe/reminder JWT, JSON { id, when, label }. Saves
///                                    one detected date as a real reminder
///                                    memory card. `id` is the SAME id from
///                                    upload — it is NOT included in the
///                                    /run response, so the caller has to
///                                    carry it forward itself (see
///                                    `Outcome`).
///                                    -> 200 { ok:true, key, when, label }
///                                    -> 400/401 { error }
///
/// Session 17 adds video (was deliberately deferred in the batch above as
/// "an easy, well-scoped follow-up if she asks" — Kade's "any new stuff you
/// can build?" is close enough to an ask, and the server contract was
/// already sitting there proven): `kind:"video"` uses the SAME upload/run
/// pair as a photo, just with a `video/*` mime type. Server-side confirmed
/// LIVE before writing any of this, not just read off source — a real
/// 2-second test clip round-tripped through `/upload` then `/run` and came
/// back `{"kind":"video","description":"<an accurate read of the actual
/// video content>",...}`, same shape as an image result, cost $0.01252.
/// `maxUploadBytes` below matches the server's own `MAX_MEDIA_BYTES` (also
/// read from source, not guessed) — video files reach that ceiling far more
/// easily than a photo ever would, which is why this app never had a
/// client-side size guard worth naming until now.
@MainActor
final class DescribeService: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Ready."

    private let client: KadeAPIClient

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct DescribeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Mirrors `kadeDescribe.js`'s own `MAX_MEDIA_BYTES = 30 * 1024 * 1024`
    /// (confirmed live, not assumed — see the class doc comment above).
    /// `DescribeView` checks this early where it has a file URL to inspect
    /// (a video picked via Photos or Files) so an oversized pick fails in
    /// under a second rather than after loading the whole thing into
    /// memory; `describe(data:mimeType:fileName:)` below checks it again as
    /// a backstop so no entry point — including a future one nobody's
    /// written yet — can skip the guard by accident.
    static let maxUploadBytes: Int64 = 30 * 1024 * 1024

    private struct ServerError: Decodable { let error: String? }

    struct DateOffer: Decodable, Identifiable, Hashable {
        let when: String
        let label: String
        var id: String { when + "|" + label }
    }

    struct Result: Decodable {
        let kind: String
        let name: String?
        let description: String
        let readText: String?
        let dates: [DateOffer]
    }

    /// What the caller needs to hold onto after a successful describe:
    /// the result to show, and the item's own `id` (needed later ONLY if
    /// she saves one of the detected dates as a reminder — `/reminder`
    /// re-reads the item server-side rather than trusting whatever text the
    /// client sends back).
    struct Outcome {
        let itemId: String
        let result: Result
    }

    /// Uploads one photo or document and returns its description. Never
    /// deletes anything the caller handed it — matches
    /// `TranscribeService.transcribeUploaded`'s same reasoning: this app
    /// didn't create the file, so it isn't this app's place to remove it.
    func describe(data: Data, mimeType: String, fileName: String) async throws -> Outcome {
        guard !data.isEmpty else {
            throw DescribeError(message: "That came through empty. Try again.")
        }
        guard data.count <= Self.maxUploadBytes else {
            throw DescribeError(message: "\(fileName) is larger than 30 megabytes, which is more than this can describe. Try a smaller file or a shorter video.")
        }

        isWorking = true
        statusMessage = "Uploading \(fileName)…"
        defer { isWorking = false }

        let uploadReq = client.multipartRequest(
            path: "api/kade/describe/upload",
            authorized: true,
            fields: [],
            fileField: "media",
            fileData: data,
            fileName: fileName,
            fileMimeType: mimeType
        )
        let (uploadData, uploadHttp) = try await client.send(uploadReq)
        guard uploadHttp.statusCode == 200 else {
            let decoded = try? JSONDecoder().decode(ServerError.self, from: uploadData)
            statusMessage = "Ready."
            throw DescribeError(message: decoded?.error ?? "Couldn't upload that. Try again.")
        }
        struct UploadResponse: Decodable { let id: String }
        guard let uploaded = try? JSONDecoder().decode(UploadResponse.self, from: uploadData) else {
            statusMessage = "Ready."
            throw DescribeError(message: "Couldn't read the upload response. Try again.")
        }

        statusMessage = "Describing — this usually takes a few seconds…"
        var runReq = client.request(path: "api/kade/describe/run", method: "POST", authorized: true)
        runReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        runReq.httpBody = try? JSONSerialization.data(withJSONObject: ["id": uploaded.id])

        let (runData, runHttp) = try await client.send(runReq)
        guard runHttp.statusCode == 200 else {
            let decoded = try? JSONDecoder().decode(ServerError.self, from: runData)
            statusMessage = "Ready."
            throw DescribeError(message: decoded?.error ?? "Couldn't describe that. Try again.")
        }
        guard let result = try? JSONDecoder().decode(Result.self, from: runData) else {
            statusMessage = "Ready."
            throw DescribeError(message: "Couldn't read the description that came back. Try again.")
        }
        statusMessage = describedStatus(for: result.kind)
        return Outcome(itemId: uploaded.id, result: result)
    }

    private func describedStatus(for kind: String) -> String {
        switch kind {
        case "image": return "Photo described."
        case "video": return "Video described."
        case "document": return "Document described."
        default: return "Described."
        }
    }

    /// Saves one detected date as a real reminder. `itemId` is the id from
    /// the ORIGINAL upload — the item that produced the dates in the first
    /// place, still resolvable server-side for up to ~45 minutes after a
    /// successful describe.
    func saveReminder(itemId: String, when: String, label: String) async throws {
        var req = client.request(path: "api/kade/describe/reminder", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["id": itemId, "when": when, "label": label]
        )
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let decoded = try? JSONDecoder().decode(ServerError.self, from: data)
            throw DescribeError(message: decoded?.error ?? "Couldn't save that reminder. Try again.")
        }
    }

    func resetStatus() {
        statusMessage = "Ready."
    }
}
