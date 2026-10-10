import SwiftUI
import UIKit

@MainActor
private struct MessageImageDownload {
    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func load(_ file: KadeMessageFile, client: KadeAPIClient) async throws -> (UIImage, URL) {
        guard let userData = Keychain.data(for: .user),
              let user = try? JSONDecoder().decode(KadeUser.self, from: userData) else {
            throw DownloadError(message: "Sign in again to open this image.")
        }
        guard let path = file.downloadPath(userId: user.id) else {
            throw DownloadError(message: "This image isn't available for download.")
        }
        try Task.checkCancellation()
        var request = client.request(path: path, authorized: true, timeout: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, http) = try await client.send(request)
        try Task.checkCancellation()
        guard http.statusCode == 200 else {
            let message: String
            switch http.statusCode {
            case 401: message = "Sign in again to open this image."
            case 403: message = "You no longer have access to this image."
            case 404: message = "This image is no longer available."
            default: message = "Couldn't load this image. Try again."
            }
            throw DownloadError(message: message)
        }
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024, let image = UIImage(data: data) else {
            throw DownloadError(message: "This file couldn't be opened as an image.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kade-image-\(UUID().uuidString)")
            .appendingPathExtension(file.imageExtension)
        try data.write(to: url, options: .atomic)
        return (image, url)
    }
}

/// Open stored chat images through the same authenticated, owner-checked file route as web.
/// The saved URL may be expired; no bearer token is ever sent to that URL.
struct MessageImagesView: View {
    let files: [KadeMessageFile]
    let apiClient: KadeAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    @State private var image: UIImage?
    @State private var fileURL: URL?
    @State private var error: String?
    @State private var loading = false
    @State private var retry = 0
    @State private var shareItem: ShareItem?
    @State private var presented = true

    private var selectedFile: KadeMessageFile? {
        files.indices.contains(selection) ? files[selection] : nil
    }
    private var imageLabel: String { "Image \(selection + 1) of \(files.count)" }
    private var loadKey: String { "\(selectedFile?.id ?? "none")-\(retry)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let selectedFile {
                        Text(imageLabel).font(.headline)
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel(imageLabel)
                        } else if loading {
                            ProgressView("Loading image")
                        } else if let error {
                            Text(error).foregroundStyle(.red)
                            Button("Retry loading image") { retry += 1 }
                                .buttonStyle(.bordered)
                        }
                        if let name = selectedFile.filename { Text(name).font(.caption) }
                        Button("Save or share image") {
                            if let fileURL { shareItem = ShareItem(fileURL: fileURL) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(fileURL == nil || loading)
                        .accessibilityHint("Opens the share sheet to save the image to Photos or Files, or choose where to share it.")
                        if files.count > 1 {
                            HStack {
                                Button("Previous image") { selection -= 1 }
                                    .disabled(selection == 0)
                                Spacer()
                                Button("Next image") { selection += 1 }
                                    .disabled(selection + 1 >= files.count)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("No images are available in this message.")
                    }
                }
                .padding()
            }
            .navigationTitle("Chat images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: loadKey) { await load() }
        .sheet(item: $shareItem, onDismiss: { if !presented { clearImage() } }) { ShareSheet(item: $0) }
        .onDisappear {
            presented = false
            if shareItem == nil { clearImage() }
        }
        .onAppear { presented = true }
    }

    @MainActor
    private func load() async {
        clearImage()
        error = nil
        guard let file = selectedFile else { return }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let (loadedImage, url) = try await MessageImageDownload.load(file, client: apiClient)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: url)
                return
            }
            image = loadedImage
            fileURL = url
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func clearImage() {
        image = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }
}
