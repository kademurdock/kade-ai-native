import Foundation

struct KadeMessageFile: Codable, Equatable, Identifiable {
    let file_id: String?
    let filename: String?
    let filepath: String?
    let type: String?
    let width: Int?
    let height: Int?

    /// Stable identity for ForEach: prefer the server's own id; a file
    /// with no id at all (not seen live, but the schema allows it) falls
    /// back to path/name so identity stays stable across reloads.
    var id: String { file_id ?? filepath ?? filename ?? "attachment" }

    var isImage: Bool { (type ?? "").lowercased().hasPrefix("image/") }

    /// What VoiceOver calls this attachment -- "a photo, orange_square.png"
    /// reads better than a bare filename, and "a file" covers the rest.
    var spokenLabel: String {
        let kind = isImage ? "a photo" : "a file"
        if let filename, !filename.isEmpty {
            return "\(kind), \(filename)"
        }
        return kind
    }
}

extension KadeMessageFile {
    static func merging(_ uploaded: [Self], _ generated: [Self]) -> [Self] {
        var seen = Set<String>()
        return (uploaded + generated).filter { seen.insert($0.id).inserted }
    }

    // Use server file identity, never a stored (possibly expired) signed URL.
    func downloadPath(userId: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        guard isImage, let file_id, valid(file_id), valid(userId) else { return nil }
        return "api/files/download/\(userId)/\(file_id)"
    }

    var imageExtension: String {
        switch type?.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        default: return "png"
        }
    }
}

/// Generated files share this server array with memory receipts and other artifacts.
/// Skip unrelated/malformed entries without losing the reply or its valid images.
struct KadeGeneratedAttachments: Codable {
    let files: [KadeMessageFile]

    init(from decoder: Decoder) throws {
        guard var entries = try? decoder.unkeyedContainer() else { files = []; return }
        var images: [KadeMessageFile] = []
        while !entries.isAtEnd {
            let entry = try entries.superDecoder()
            guard let file = try? KadeMessageFile(from: entry), file.isImage,
                  file.file_id?.isEmpty == false else { continue }
            images.append(file)
        }
        files = KadeMessageFile.merging([], images)
    }

    func encode(to encoder: Encoder) throws {
        var entries = encoder.unkeyedContainer()
        for file in files { try entries.encode(file) }
    }
}
