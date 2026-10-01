import Foundation
import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Owns the whole attachment operation, including time spent fetching an iCloud
/// photo. A deadline clears the UI without waiting for an uncooperative provider;
/// the operation id prevents its eventual callback from attaching an old file.
@MainActor
final class ChatAttachmentPreparation: ObservableObject {
    enum Source {
        case photo(PhotosPickerItem)
        case file(URL, deleteAfterPreparing: Bool = false)
        case clipboard
        case bytes(Data, mimeType: String, fileName: String)
        case prepared(ChatAttachment.PreparedFile)
    }

    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    var canRetry: Bool { retrySource != nil }

    typealias Upload = @MainActor (KadeAPIClient, ChatAttachment.PreparedFile, String?, String?) async throws -> ChatAttachment
    private let preparationTimeoutNanoseconds: UInt64
    private let uploadTimeoutNanoseconds: UInt64
    private let uploader: Upload

    // Injection is for offline lifecycle tests; production uses the same
    // upload operation and the 60s preparation / 120s upload deadlines.
    init(
        preparationTimeoutNanoseconds: UInt64 = 60_000_000_000,
        uploadTimeoutNanoseconds: UInt64 = 120_000_000_000,
        uploader: Upload? = nil
    ) {
        self.preparationTimeoutNanoseconds = preparationTimeoutNanoseconds
        self.uploadTimeoutNanoseconds = uploadTimeoutNanoseconds
        self.uploader = uploader ?? { client, prepared, conversationId, agentId in
            try await ChatAttachment.upload(client: client, prepared: prepared, conversationId: conversationId, agentId: agentId)
        }
    }

    private var retrySource: Source?
    private struct Context {
        let client: KadeAPIClient
        let conversationId: String?
        let agentId: String?
        let onReady: @MainActor (ChatAttachment) -> Void
    }
    private var retryContext: Context?
    private var operationId: UUID?
    private var stageId: UUID?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var preparationTask: Task<ChatAttachment.PreparedFile, Error>?
    private var providerProgress: Progress?
    private var providerContinuation: CheckedContinuation<Data, Error>?
    private var providerId: UUID?

    func start(
        _ source: Source,
        client: KadeAPIClient,
        conversationId: String?,
        agentId: String?,
        onReady: @escaping @MainActor (ChatAttachment) -> Void
    ) {
        cancel()
        retrySource = source
        retryContext = Context(client: client, conversationId: conversationId, agentId: agentId, onReady: onReady)
        let id = UUID()
        operationId = id
        isBusy = true
        statusMessage = "Preparing your attachment."
        armDeadline(operation: id, nanoseconds: preparationTimeoutNanoseconds, message: "Preparing the attachment took too long. Check your connection, then retry or choose another file.")
        worker = Task { @MainActor in
            do {
                let prepared = try await prepare(source, operation: id)
                guard operationId == id, !Task.isCancelled else { return }
                // A failed upload retries these same bytes, not a new clipboard
                // value or another download of the photo from iCloud.
                retrySource = .prepared(prepared)
                if case .file(let url, let deleteAfterPreparing) = source, deleteAfterPreparing {
                    // Only the app-owned Share Extension handoff opts in.
                    // Its original bytes are now retained for manual Retry.
                    try? FileManager.default.removeItem(at: url)
                }
                statusMessage = "Uploading your attachment."
                armDeadline(operation: id, nanoseconds: uploadTimeoutNanoseconds, message: "Uploading the attachment took too long. Check your connection and retry.")
                let attachment = try await uploader(client, prepared, conversationId, agentId)
                guard operationId == id, !Task.isCancelled else { return }
                finish()
                retrySource = nil
                retryContext = nil
                onReady(attachment)
            } catch {
                guard operationId == id else { return }
                finish()
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't attach that file. Check your connection and retry."
            }
        }
    }

    func retry() {
        guard let retrySource, let context = retryContext else { return }
        start(retrySource, client: context.client, conversationId: context.conversationId, agentId: context.agentId, onReady: context.onReady)
    }

    func showError(_ message: String) {
        cancel()
        errorMessage = message
    }

    func cancel() {
        // Invalidate first. Neither a late callback nor the cancelled worker's
        // catch block may change the state of the next attachment operation.
        operationId = nil
        finish()
        retrySource = nil
        retryContext = nil
        errorMessage = nil
    }

    private func finish() {
        operationId = nil
        stageId = nil
        deadline?.cancel()
        deadline = nil
        worker?.cancel()
        worker = nil
        preparationTask?.cancel()
        preparationTask = nil
        cancelProvider()
        isBusy = false
        statusMessage = ""
    }

    private func armDeadline(operation: UUID, nanoseconds: UInt64, message: String) {
        deadline?.cancel()
        let stage = UUID()
        stageId = stage
        deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard operationId == operation, stageId == stage else { return }
            finish()
            errorMessage = message
        }
    }

    private func prepare(_ source: Source, operation: UUID) async throws -> ChatAttachment.PreparedFile {
        try Task.checkCancellation()
        switch source {
        case .prepared(let prepared):
            return prepared
        case .file(let url, _):
            let task = Task.detached(priority: .userInitiated) {
                try Self.readFile(url)
            }
            preparationTask = task
            let prepared = try await task.value
            try Task.checkCancellation()
            guard operationId == operation else { throw CancellationError() }
            if operationId == operation { preparationTask = nil }
            return prepared
        case .photo(let item):
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let data = try await loadProviderData { callback in
                item.loadTransferable(type: Data.self, completionHandler: callback)
            }
            return try await prepareBytes(data, mimeType: type.preferredMIMEType ?? "image/jpeg", fileName: "photo.\(type.preferredFilenameExtension ?? "jpg")", operation: operation)
        case .bytes(let data, let mimeType, let fileName):
            return try await prepareBytes(data, mimeType: mimeType, fileName: fileName, operation: operation)
        case .clipboard:
            let kinds: [UTType] = [.image, .pdf, .movie, .data]
            for provider in UIPasteboard.general.itemProviders {
                let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
                for kind in kinds {
                    guard let type = types.first(where: { $0.conforms(to: kind) && !$0.conforms(to: .text) }) else { continue }
                    let data = try await loadProviderData { callback in
                        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                            if let error { callback(.failure(error)) }
                            else { callback(.success(data)) }
                        }
                    }
                    try Task.checkCancellation()
                    guard operationId == operation else { throw CancellationError() }
                    guard !data.isEmpty else { continue }
                    let ext = type.preferredFilenameExtension ?? "bin"
                    var name = provider.suggestedName ?? "pasted"
                    if !name.lowercased().hasSuffix(".\(ext)") { name += ".\(ext)" }
                    return try await prepareBytes(data, mimeType: type.preferredMIMEType ?? "application/octet-stream", fileName: name, operation: operation)
                }
            }
            if let image = UIPasteboard.general.image {
                let task = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    guard let data = image.jpegData(compressionQuality: 0.85) else { throw PreparationError.unreadable }
                    return try ChatAttachment.prepare(data: data, mimeType: "image/jpeg", fileName: "pasted.jpg")
                }
                preparationTask = task
                let prepared = try await task.value
                try Task.checkCancellation()
                guard operationId == operation else { throw CancellationError() }
                preparationTask = nil
                return prepared
            }
            throw PreparationError.nothingToPaste
        }
    }

    private func prepareBytes(_ data: Data, mimeType: String, fileName: String, operation: UUID) async throws -> ChatAttachment.PreparedFile {
        try Task.checkCancellation()
        guard operationId == operation else { throw CancellationError() }
        let task = Task.detached(priority: .userInitiated) {
            try ChatAttachment.prepare(data: data, mimeType: mimeType, fileName: fileName)
        }
        preparationTask = task
        let prepared = try await task.value
        try Task.checkCancellation()
        guard operationId == operation else { throw CancellationError() }
        if operationId == operation { preparationTask = nil }
        return prepared
    }

    nonisolated private static func readFile(_ url: URL) throws -> ChatAttachment.PreparedFile {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        if let size = values.fileSize, Int64(size) > ChatAttachment.maxUploadBytes {
            throw ChatAttachment.UploadError.tooLarge
        }
        let data = try Data(contentsOf: url)
        return try ChatAttachment.prepare(
            data: data,
            mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
            fileName: url.lastPathComponent
        )
    }

    private func loadProviderData(
        _ start: (@escaping (Result<Data?, Error>) -> Void) -> Progress
    ) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            providerId = id
            providerContinuation = continuation
            providerProgress = start { [weak self] result in
                Task { @MainActor in
                    guard let self, self.providerId == id,
                          let continuation = self.providerContinuation else { return }
                    self.providerContinuation = nil
                    self.providerProgress = nil
                    self.providerId = nil
                    switch result {
                    case .success(let data):
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: PreparationError.unreadable) }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func cancelProvider() {
        providerId = nil
        providerProgress?.cancel()
        providerProgress = nil
        let continuation = providerContinuation
        providerContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    private enum PreparationError: LocalizedError {
        case unreadable
        case nothingToPaste

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't load that photo or file. Retry or choose another one."
            case .nothingToPaste: return "Nothing to paste yet. Copy a photo or file first. Copied words go straight into the message box."
            }
        }
    }
}
