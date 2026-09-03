import UIKit
import UniformTypeIdentifiers
import Social

/// SHARE TO YOUR AGENT — the extension half (Part 120, Sep 3 2026).
///
/// Her ask: "if I want to send a picture or file to Kiana, my default agent."
///
/// This is `SLComposeServiceViewController` on purpose rather than a custom
/// SwiftUI sheet: it is the system's own share composer, so VoiceOver already
/// knows it — a text field, a Post button, a Cancel button, all labelled by
/// iOS, in the order every other share sheet in the OS uses. A hand-rolled
/// sheet would have to re-earn all of that, and a share sheet is a two-second
/// interaction that must never become a puzzle.
///
/// What it does: pulls the shared item's bytes, writes them into the App Group
/// with her note, and says plainly that the app has to be opened to finish.
/// It does NOT send anything — see KadeShareStore for the whole reasoning, but
/// the short version is that sending from here would mean copying this
/// account's access token into a second binary, and that is a bad trade for
/// one saved tap.
class ShareViewController: SLComposeServiceViewController {

    private var loadedData: Data?
    private var loadedName: String?
    private var loadedKind: String = "file"
    private var loadFailed: String?

    /// 30 MB — the same ceiling the in-app attachment path uses, so the number
    /// she hears is one number wherever she meets it.
    private let maxBytes = 30 * 1024 * 1024

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Send to Kade-AI"
        placeholder = "Say something about this (optional)"
        loadItem()
    }

    override func isContentValid() -> Bool {
        // Post stays available while the item is still loading; the real
        // refusal (with a reason) happens in didSelectPost.
        return loadFailed == nil
    }

    override func didSelectPost() {
        if let problem = loadFailed {
            finish(saying: problem, success: false)
            return
        }
        guard let data = loadedData, let name = loadedName else {
            finish(saying: "That did not finish loading. Try sharing it again.", success: false)
            return
        }
        let note = contentText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = KadeShareStore.write(
            data: data,
            displayName: name,
            note: (note?.isEmpty ?? true) ? nil : note,
            kind: loadedKind
        )
        if ok {
            finish(saying: "Saved. Open Kade-AI to send it.", success: true)
        } else {
            finish(saying: "Couldn't hand that to Kade-AI. Open the app once and try again.", success: false)
        }
    }

    override func configurationItems() -> [Any]! { [] }

    // MARK: - Loading the item

    private func loadItem() {
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
              let providers = item.attachments, !providers.isEmpty else {
            loadFailed = "There was nothing to share."
            return
        }
        // ONE item, matching the app's one-attachment-per-message rule. If a
        // share carries several, the first is taken and the rest are ignored
        // rather than silently concatenated into something she did not ask for.
        let provider = providers[0]
        let types: [UTType] = [.image, .movie, .audio, .pdf, .plainText, .data]
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            loadFailed = "Kade-AI can't take that kind of file yet."
            return
        }
        loadedKind = (type == .image) ? "image" : "file"
        provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { [weak self] value, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.loadFailed = "Couldn't read that. \(error.localizedDescription)" }
                return
            }
            var data: Data?
            var name = "shared"
            if let url = value as? URL {
                name = url.lastPathComponent
                let scoped = url.startAccessingSecurityScopedResource()
                data = try? Data(contentsOf: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            } else if let image = value as? UIImage {
                data = image.jpegData(compressionQuality: 0.9)
                name = "photo.jpg"
            } else if let raw = value as? Data {
                data = raw
                name = "shared.\(type.preferredFilenameExtension ?? "dat")"
            } else if let text = value as? String {
                data = Data(text.utf8)
                name = "shared.txt"
            }
            DispatchQueue.main.async {
                guard let data else {
                    self.loadFailed = "Couldn't read that file."
                    return
                }
                guard data.count <= self.maxBytes else {
                    self.loadFailed = "That is larger than 30 megabytes. Try a smaller one."
                    return
                }
                self.loadedData = data
                self.loadedName = name
            }
        }
    }

    /// One exit. The message is announced BEFORE the sheet dismisses — an
    /// announcement posted into a disappearing view controller is dropped, and
    /// a share that says nothing is indistinguishable from one that failed.
    private func finish(saying message: String, success: Bool) {
        UIAccessibility.post(notification: .announcement, argument: message)
        /* Explicitly () -> Void. Inferred, this closure's type is () -> Void?
         * — `self?.extensionContext?.completeRequest(...)` is an optional
         * chain, so its result is Void? — and asyncAfter(execute:) then reads
         * it as a DispatchWorkItem and refuses. Caught by the compile gate on
         * the first run, for a few cents and no build on her phone. */
        let done: () -> Void = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
        if success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
        } else {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
            present(alert, animated: true)
        }
    }
}
