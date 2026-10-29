import Foundation

var checks = 0
func check(_ passed: Bool, _ label: String) {
    checks += 1
    if !passed { fatalError(label) }
}
func message(_ extra: String = "") throws -> KadeMessage {
    let json = """
    {"messageId":"reply-1","conversationId":"chat-1","createdAt":"2026-01-01T00:00:00Z",
     "isCreatedByUser":false,"sender":"Synthetic artist","text":"Your image is ready."\(extra)}
    """
    return try JSONDecoder().decode(KadeMessage.self, from: Data(json.utf8))
}
let generated = #"{"file_id":"image-1","filename":"synthetic.png","filepath":"https://expired.invalid/private.png?expired=1","type":"image/png","width":1024,"height":768}"#
let second = #"{"file_id":"image-2","filename":"second.jpg","type":"image/jpeg"}"#
let generatedOnly = try message(",\"attachments\":[\(generated)]")
check(generatedOnly.files == nil, "fixture uses the actual generated-artifact field, not upload files")
check(generatedOnly.imageFiles.map(\.id) == ["image-1"], "generated-only reply remains visible after final reload and reopen")
check(generatedOnly.readableText == "Your image is ready.", "decoding images preserves reply text")
check(try message().displayFiles.isEmpty, "legacy text-only reply remains valid")
check(try message(",\"attachments\":null").imageFiles.isEmpty, "null attachments remain valid")
check(try message(",\"attachments\":[]").imageFiles.isEmpty, "empty attachments remain valid")
let mixed = try message(",\"attachments\":[null,42,\"future\",{\"memory\":{\"key\":\"synthetic\",\"type\":\"create\"}},{\"type\":\"citation\"},{\"type\":\"image/png\",\"file_id\":7},\(generated),\(second)]")
check(mixed.imageFiles.map(\.id) == ["image-1", "image-2"], "memory, unrelated and malformed artifacts do not hide valid images")
check(try message(",\"attachments\":{\"future\":true}").imageFiles.isEmpty, "unknown attachment container fails soft")
let duplicated = try message(",\"files\":[\(generated)],\"attachments\":[\(generated),\(generated),\(second)]")
check(duplicated.displayFiles.map(\.id) == ["image-1", "image-2"], "uploads and generated images retain order with unique identities")
let uploaded = try message(",\"files\":[\(second),{\"file_id\":\"doc-1\",\"type\":\"application/pdf\"}]")
check(uploaded.displayFiles.count == 2 && uploaded.imageFiles.count == 1, "existing uploaded images and documents remain available")
let file = generatedOnly.imageFiles[0]
check(file.downloadPath(userId: "signed-in-user") == "api/files/download/signed-in-user/image-1", "downloads use current-account file route even for an expired stored URL")
check(file.imageExtension == "png", "PNG output extension")
check(mixed.imageFiles[1].imageExtension == "jpg", "JPEG output extension")
check(file.downloadPath(userId: "../other") == nil, "reject traversal in user identity")
check(file.downloadPath(userId: "") == nil, "reject absent account identity")
for invalidId in ["../secret", "file?direct=true", "file/name", "file%2Fname", "", String(repeating: "x", count: 129)] {
    let invalid = KadeMessageFile(file_id: invalidId, filename: "../../unsafe.png", filepath: "https://attacker.invalid", type: "image/png", width: nil, height: nil)
    check(invalid.downloadPath(userId: "signed-in-user") == nil, "untrusted identity cannot change download route")
}
check(uploaded.displayFiles[1].downloadPath(userId: "signed-in-user") == nil, "image viewer rejects non-image files")
check(file.spokenLabel == "a photo, synthetic.png", "generated image has an accessible label")
let roundTrip = try JSONDecoder().decode(KadeMessage.self, from: JSONEncoder().encode(generatedOnly))
check(roundTrip.imageFiles == generatedOnly.imageFiles, "image-bearing message round trip")
print("\(checks) message attachment checks passed. Synthetic fixtures only; no network, generation or iOS build.")
