import Foundation
import UIKit

/// Session 26, leftovers item 1 -- the big one: attaching a photo or file
/// INTO a chat message, so the agent sees it as conversation context
/// (Describe is a separate tool and never fed chat; this does).
///
/// Wire contract, read off the web client's own upload path
/// (useFileHandling.ts `startUpload`) and the fork's agents controller:
///
///   1. POST /api/files (multipart): fields `endpoint=agents`,
///      `endpointType=` (empty, exactly as the web sends it), a
///      client-minted `file_id` UUID, `message_file=true` (the marker for
///      a chat-message upload as opposed to an Agent Builder knowledge
///      file), `agent_id` when one is selected, `conversationId` when the
///      conversation already exists (a brand-new chat legitimately omits
///      it -- the file links up at send time), `width`/`height` for
///      images -- then the `file` part itself, filename percent-encoded
///      like the web's encodeURIComponent. Fields precede the file part
///      so multer has them in hand while it processes the stream.
///   2. The next chat send carries `files: [{file_id, filepath, type,
///      width, height}]` in the POST body -- the exact array shape
///      useChatFunctions.ts builds -- and the server attaches them to the
///      user message (request.js: `buildMessageFiles(req.body.files, ...)`).
///
/// V1 scope, stated plainly: ONE attachment per message. The web allows
/// several; one keeps the composer a clean swipe under VoiceOver (chip +
/// remove button, no collection to manage) and covers the actual ask.
struct ChatAttachment: Identifiable, Equatable {
    let id: String
    let filepath: String
    let type: String
    let width: Int?
    let height: Int?
    let displayName: String

    var asMessagePayload: [String: Any] {
        var payload: [String: Any] = [
            "file_id": id,
            "filepath": filepath,
            "type": type,
        ]
        if let width { payload["width"] = width }
        if let height { payload["height"] = height }
        return payload
    }

    /// Local guard only -- fail fast before reading bytes, same shape as
    /// Describe/Transcribe's import guards. (The server's own per-endpoint
    /// file config is the real ceiling; 30MB matches the app's other
    /// upload surfaces so the spoken size rule stays one number.)
    static let maxUploadBytes: Int64 = 30 * 1024 * 1024

    enum UploadError: Error {
        case server(Int)
        case badResponse
    }

    /// Uploads one file and returns the attachment handle the next send
    /// spends. Throws on any failure -- the caller owns the spoken error.
    static func upload(
        client: KadeAPIClient,
        data: Data,
        mimeType: String,
        fileName: String,
        conversationId: String?,
        agentId: String?
    ) async throws -> ChatAttachment {
        var fields: [(String, String)] = [
            ("endpoint", "agents"),
            ("endpointType", ""),
            ("file_id", UUID().uuidString),
            ("message_file", "true"),
        ]
        if let agentId { fields.append(("agent_id", agentId)) }
        if let conversationId { fields.append(("conversationId", conversationId)) }

        var width: Int?
        var height: Int?
        if mimeType.hasPrefix("image/"), let image = UIImage(data: data) {
            width = Int(image.size.width * image.scale)
            height = Int(image.size.height * image.scale)
            if let width { fields.append(("width", String(width))) }
            if let height { fields.append(("height", String(height))) }
        }

        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let req = client.multipartRequest(
            path: "api/files",
            authorized: true,
            fields: fields,
            fileField: "file",
            fileData: data,
            fileName: encodedName,
            fileMimeType: mimeType
        )
        let (respData, http) = try await client.send(req)
        guard (200...201).contains(http.statusCode) else { throw UploadError.server(http.statusCode) }

        struct FileResponse: Decodable {
            let file_id: String
            let filepath: String?
            let type: String?
            let width: Int?
            let height: Int?
            let filename: String?
        }
        guard let file = try? JSONDecoder().decode(FileResponse.self, from: respData) else {
            throw UploadError.badResponse
        }
        return ChatAttachment(
            id: file.file_id,
            filepath: file.filepath ?? "",
            type: file.type ?? mimeType,
            width: file.width ?? width,
            height: file.height ?? height,
            displayName: fileName
        )
    }
}
