import Foundation

/// SHARE TO YOUR AGENT — the contract between the share extension and the app
/// (Part 120, Sep 3 2026).
///
/// Her ask: "put a share with your Kade-ai agent. Like, I know that has nothing
/// to do with sound booth but if I want to send a picture or file to Kiana, my
/// default agent."
///
/// ⭐ WHY THE EXTENSION DOES NOT SEND IT ITSELF, which is the whole design.
///
/// A share extension is its own process with its own container. It does not
/// have the app's Keychain, its cookie jar, or its session — so for the
/// extension to POST a file to kademurdock.com, this app's ACCESS TOKEN would
/// have to be copied into a shared keychain group that a second, far less
/// scrutinised binary can read. That is a real widening of the blast radius
/// on an account that reaches every family member's conversations, and it
/// buys one saved tap.
///
/// So the extension does the one thing it is good at: it takes the item the
/// OS hands it, writes it into the App Group, and says so. The APP does the
/// sending, on the session it already holds, through the attachment path that
/// already exists and is already tested. This is the same shape as the Kade
/// Keys dictation hand-off (KadeKeysSharedStore) and it fails the same safe
/// way: if the app never opens, nothing was sent and nothing leaked.
///
/// TWO CARRIERS, and the reason is scar tissue. The keyboard hand-off learned
/// (round 5, Aug 2026) that a suspended extension's `UserDefaults` flush can
/// be lost, so the marker rides BOTH a defaults key and an atomic file write.
/// Same belt and braces here: the payload JSON goes to defaults, the FILE goes
/// to the container (it has to anyway — a URL from another process's temp
/// directory is meaningless), and either half being present is enough to know
/// something is waiting.
enum KadeShareStore {
    static let appGroupId = "group.com.kademurdock.kadeai"
    static let pendingKey = "kadeShare.pending.v1"
    static let inboxFolder = "SharedInbox"

    /// Anything older than this is dropped without sending. A share she made
    /// last Tuesday must not surprise her by landing in a chat today.
    static let maxAgeSeconds: TimeInterval = 30 * 60

    struct Pending: Codable {
        /// File name inside the App Group's SharedInbox folder.
        let fileName: String
        /// What to show and speak — the original name, not the stored one.
        let displayName: String
        /// The note she typed in the share sheet, if any.
        let note: String?
        let at: Date
        /// "image", "file" — only used for what gets said out loud.
        let kind: String
    }

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static var inbox: URL? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent(inboxFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Extension side

    /// Writes the shared item into the App Group. Returns false if the
    /// container is missing, which is the one failure the extension must
    /// report out loud rather than swallow — a silent success that sends
    /// nothing is the worst outcome for someone who cannot see the sheet.
    @discardableResult
    static func write(data: Data, displayName: String, note: String?, kind: String) -> Bool {
        guard let inbox else { return false }
        let ext = (displayName as NSString).pathExtension
        let stored = "share-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))"
            + (ext.isEmpty ? "" : ".\(ext)")
        let target = inbox.appendingPathComponent(stored)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            return false
        }
        let pending = Pending(
            fileName: stored,
            displayName: displayName,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines),
            at: Date(),
            kind: kind
        )
        guard let blob = try? JSONEncoder().encode(pending) else { return false }
        UserDefaults(suiteName: appGroupId)?.set(blob, forKey: pendingKey)
        return true
    }

    // MARK: - App side

    /// Reads and CLEARS the waiting share. Returns the on-disk URL of the file
    /// plus what to say. The caller owns deleting the file once it is uploaded.
    static func take() -> (url: URL, pending: Pending)? {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let blob = defaults.data(forKey: pendingKey),
              let pending = try? JSONDecoder().decode(Pending.self, from: blob) else {
            return nil
        }
        defaults.removeObject(forKey: pendingKey)
        guard Date().timeIntervalSince(pending.at) < maxAgeSeconds else {
            sweep()
            return nil
        }
        guard let inbox else { return nil }
        let url = inbox.appendingPathComponent(pending.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, pending)
    }

    /// Deletes every file in the inbox. Called when a stale share is dropped,
    /// so an abandoned hand-off cannot sit in the container forever.
    static func sweep() {
        guard let inbox,
              let items = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }
}
