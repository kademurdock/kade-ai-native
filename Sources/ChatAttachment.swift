import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

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

    struct PreparedFile: Sendable {
        let data: Data
        let mimeType: String
        let fileName: String
        let width: Int?
        let height: Int?
    }

    enum UploadError: LocalizedError {
        case server(Int)
        case badResponse
        case tooLarge
        case emptyFile
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .tooLarge, .server(413):
                return "That attachment is larger than 30 megabytes. Choose a smaller photo or file."
            case .emptyFile:
                return "That file is empty. Choose another photo or file."
            case .unreadableImage:
                return "Couldn't read that photo. Choose another photo or retry."
            case .server(401):
                return "Your sign-in expired. Sign in again before retrying the attachment."
            case .badResponse:
                return "The upload didn't return a usable attachment. Please retry."
            case .server:
                return "Couldn't upload that attachment. Check your connection and retry."
            }
        }
    }

    /// One size/type guard for Photos, camera, Files and paste. Run off the
    /// main actor so HEIC conversion cannot prevent Cancel or the deadline.
    static func prepare(data: Data, mimeType: String, fileName: String) throws -> PreparedFile {
        try Task.checkCancellation()
        try validateSize(data)
        var data = data
        var mimeType = mimeType
        var fileName = fileName
        var width: Int?
        var height: Int?
        var source = CGImageSourceCreateWithData(data as CFData, nil)
        let imageType = source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        if mimeType.hasPrefix("image/") || imageType?.conforms(to: .image) == true {
            guard source != nil else { throw UploadError.unreadableImage }
            let actualMime = imageType?.preferredMIMEType ?? mimeType
            let visionSafe = ["image/jpeg", "image/png", "image/webp", "image/gif"]
            if !visionSafe.contains(actualMime.lowercased()) {
                guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else {
                    throw UploadError.unreadableImage
                }
                data = jpeg
                mimeType = "image/jpeg"
                fileName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent + ".jpg"
                source = CGImageSourceCreateWithData(data as CFData, nil)
            } else {
                mimeType = actualMime
            }
            guard let source,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let pixelsWide = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let pixelsHigh = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  pixelsWide.intValue > 0, pixelsHigh.intValue > 0 else {
                throw UploadError.unreadableImage
            }
            width = pixelsWide.intValue
            height = pixelsHigh.intValue
        }
        try Task.checkCancellation()
        try validateSize(data) // HEIC -> JPEG can increase the byte count.
        return PreparedFile(data: data, mimeType: mimeType, fileName: fileName, width: width, height: height)
    }

    private static func validateSize(_ data: Data) throws {
        guard !data.isEmpty else { throw UploadError.emptyFile }
        guard Int64(data.count) <= maxUploadBytes else { throw UploadError.tooLarge }
    }

    /// Uploads one file and returns the attachment handle the next send
    /// spends. Throws on any failure -- the caller owns the spoken error.
    /// @MainActor because `KadeAPIClient` is a main-actor class (its pacing
    /// clock is main-actor state) -- building the request is isolated even
    /// though the network await itself hops off. Caught by the first
    /// Codemagic attempt of this batch: a nonisolated static calling
    /// `multipartRequest` is a compile error, not a warning.
    @MainActor
    static func upload(
        client: KadeAPIClient,
        prepared: PreparedFile,
        conversationId: String?,
        agentId: String?
    ) async throws -> ChatAttachment {
        try Task.checkCancellation()
        try validateSize(prepared.data)
        var fields: [(String, String)] = [
            ("endpoint", "agents"),
            ("endpointType", ""),
            ("file_id", UUID().uuidString),
            ("message_file", "true"),
        ]
        if let agentId { fields.append(("agent_id", agentId)) }
        if let conversationId { fields.append(("conversationId", conversationId)) }

        if let width = prepared.width { fields.append(("width", String(width))) }
        if let height = prepared.height { fields.append(("height", String(height))) }

        let encodedName = prepared.fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prepared.fileName
        let req = client.multipartRequest(
            path: "api/files",
            authorized: true,
            fields: fields,
            fileField: "file",
            fileData: prepared.data,
            fileName: encodedName,
            fileMimeType: prepared.mimeType
        )
        let (respData, http) = try await client.sendUpload(req, resourceTimeout: 120)
        try Task.checkCancellation()
        guard (200...201).contains(http.statusCode) else { throw UploadError.server(http.statusCode) }

        struct FileResponse: Decodable {
            let file_id: String
            let filepath: String?
            let type: String?
            let width: Int?
            let height: Int?
            let filename: String?
        }
        guard let file = try? JSONDecoder().decode(FileResponse.self, from: respData),
              !file.file_id.isEmpty, let filepath = file.filepath, !filepath.isEmpty else {
            throw UploadError.badResponse
        }
        return ChatAttachment(
            id: file.file_id,
            filepath: filepath,
            type: file.type ?? prepared.mimeType,
            width: file.width ?? prepared.width,
            height: file.height ?? prepared.height,
            displayName: prepared.fileName
        )
    }
}
