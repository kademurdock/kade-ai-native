import Foundation
import MetricKit
import UIKit

/// Aug 4 2026 -- the crash catcher, built for the "watermelon crash"
/// (the app died mid-chat and TestFlight never synced a stack, so there
/// was nothing to fix from). Two halves:
///
/// 1. `KadeCrashWatch` subscribes to MetricKit. When the app crashes or
///    hangs, Apple writes a diagnostic and hands it over ON THE NEXT
///    LAUNCH -- no TestFlight sync, no waiting on Apple's dashboard. Each
///    payload is saved as JSON under Documents/Diagnostics (newest 10
///    kept).
/// 2. `KadeBreadcrumbs` keeps a small trail of recent app events (launch,
///    background/foreground, memory pressure, send started/landed/failed,
///    call started/ended) so a crash report comes with CONTEXT: what was
///    the app doing right before it died. Never message content, never
///    credentials -- event names and timestamps only, capped at 400 lines.
///
/// Settings > Support > "Share diagnostics" hands both to a share sheet.
///
/// 3. (Aug 5 2026, queued after "the native app just crashed on me" — the
///    on-device JSON existed but reaching it took her hands): unsent crash
///    reports now ALSO auto-upload to the bridge's /diagnostics sink on the
///    launch after a crash — Apple's crash JSON + the breadcrumb tail, never
///    message content (same promise as the Share footer). Capped, marked
///    uploaded once accepted, silent and fail-soft; the manual Share lane
///    stays for everything else.
///
/// Everything here is fail-soft: a diagnostics feature that can itself
/// crash the app would be a bad joke.
enum KadeBreadcrumbs {
    private static let queue = DispatchQueue(label: "kade.breadcrumbs", qos: .utility)
    private static let maxLines = 400

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    static var logFile: URL { directory.appendingPathComponent("breadcrumbs.log") }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Appends one timestamped line to the trail. Safe from any thread;
    /// never throws; never blocks the caller.
    static func drop(_ event: String) {
        let line = "\(stamp.string(from: Date()))  \(event)\n"
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(line.utf8))
                } else {
                    try line.data(using: .utf8)?.write(to: logFile)
                }
            } catch {
                // Fail-soft by design.
            }
        }
    }

    /// Keeps the trail small. Called once per launch, off the main thread.
    static func trim() {
        queue.async {
            guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count > maxLines else { return }
            let kept = lines.suffix(maxLines).joined(separator: "\n") + "\n"
            try? kept.data(using: .utf8)?.write(to: logFile)
        }
    }
}

final class KadeCrashWatch: NSObject, MXMetricManagerSubscriber {
    static let shared = KadeCrashWatch()
    private static let maxReports = 10

    /// Call once, early in launch. Registers for MetricKit diagnostics and
    /// starts the lifecycle breadcrumbs (background/foreground/memory) via
    /// notification observers, so no other file needs lifecycle wiring.
    func start() {
        MXMetricManager.shared.add(self)
        KadeBreadcrumbs.trim()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        KadeBreadcrumbs.drop("app launched -- v\(version) build \(build)")
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            KadeBreadcrumbs.drop("app backgrounded")
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            KadeBreadcrumbs.drop("app foregrounded")
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            KadeBreadcrumbs.drop("MEMORY WARNING")
        }
        uploadPendingReports()
    }

    /// MetricKit hands crash/hang/CPU diagnostics here on the launch after
    /// they happen. Arrives on a background queue -- file work only.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let dir = KadeBreadcrumbs.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for (i, payload) in payloads.enumerated() {
            let name = "crash-\(stamp)-\(i).json"
            try? payload.jsonRepresentation().write(to: dir.appendingPathComponent(name))
        }
        KadeBreadcrumbs.drop("MetricKit delivered \(payloads.count) diagnostic payload(s)")
        pruneOldReports(in: dir)
        uploadPendingReports()
    }

    private func pruneOldReports(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let reports = files
            .filter { $0.lastPathComponent.hasPrefix("crash-") }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for stale in reports.dropFirst(Self.maxReports) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// The auto-upload half (see the file header's item 3). Utility queue,
    /// bounded work: at most two reports per call, 10s per request, first
    /// failure stops the batch (network's down — next launch retries).
    /// Reports too large for the sink's 64KB cap are marked uploaded
    /// without sending so they can never wedge the queue; the Share lane
    /// still carries them by hand.
    private static let uploadedKey = "kade.diag.uploaded.v1"
    private static let sinkURL = URL(string: "https://kade-ai-bridge-production.up.railway.app/diagnostics")!

    /// The signed-in account this crash belongs to, or "" if nobody is signed
    /// in (a crash on the sign-in screen is still worth having, just anonymous).
    ///
    /// Reads the Keychain copy AuthService already caches rather than reaching
    /// for AuthService itself: this runs on a utility queue during launch,
    /// AuthService is @MainActor, and a diagnostics uploader must never be the
    /// reason launch waits on the main thread. Fail-soft like everything else
    /// in this file — no account, no field, upload proceeds regardless.
    private static func signedInAccount() -> String {
        guard let data = Keychain.data(for: .user),
              let user = try? JSONDecoder().decode(KadeUser.self, from: data)
        else { return "" }
        let name = user.displayName
        return name == user.email ? user.email : "\(name) <\(user.email)>"
    }

    private func uploadPendingReports() {
        DispatchQueue.global(qos: .utility).async {
            let dir = KadeBreadcrumbs.directory
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            let defaults = UserDefaults.standard
            var uploaded = Set(defaults.stringArray(forKey: Self.uploadedKey) ?? [])
            let crumbs = (try? String(contentsOf: KadeBreadcrumbs.logFile, encoding: .utf8))
                .map { $0.split(separator: "\n").suffix(30).joined(separator: "\n") } ?? ""
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            let device = UIDevice.current.model + " iOS " + UIDevice.current.systemVersion
            let who = Self.signedInAccount()
            var sent = 0
            let candidates = files
                .filter { $0.lastPathComponent.hasPrefix("crash-") && !uploaded.contains($0.lastPathComponent) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in candidates {
                guard sent < 2 else { break }
                let name = file.lastPathComponent
                guard var payload = try? String(contentsOf: file, encoding: .utf8) else {
                    uploaded.insert(name)
                    continue
                }
                // Build 196 (the "why did the system never tell me?" audit):
                // real MetricKit crash payloads routinely run 100-300KB, and
                // the old 60KB guard marked them uploaded WITHOUT SENDING —
                // the exact crashes worth reporting were the ones silently
                // dropped. The bridge accepts 600KB now; send whole payloads
                // up to 400KB and truncate the rare monster instead of
                // dropping it (a cut-off stack beats no stack).
                if payload.count > 400_000 {
                    payload = String(payload.prefix(400_000)) + "…[truncated at 400KB of \(payload.count)]"
                }
                var req = URLRequest(url: Self.sinkURL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 10
                var body: [String: Any] = [
                    "build": build,
                    "device": device,
                    "kind": "crash",
                    "payload": payload,
                    "breadcrumbs": crumbs,
                ]
                // Build 199 (Aug 13 2026) — WHO. Amber took five watchdog
                // kills on 197 and the alert, had it worked at all, could
                // only have said "build 197, iPhone iOS 26.6." Finding out it
                // was Amber meant hand-correlating the crash ring against
                // LibreChat's server logs by timestamp. The report now names
                // its own account, so the push can too.
                if !who.isEmpty { body["who"] = who }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                let gate = DispatchSemaphore(value: 0)
                var accepted = false
                URLSession.shared.dataTask(with: req) { _, response, _ in
                    accepted = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false
                    gate.signal()
                }.resume()
                _ = gate.wait(timeout: .now() + 12)
                if accepted {
                    uploaded.insert(name)
                    sent += 1
                } else {
                    break
                }
            }
            defaults.set(Array(uploaded), forKey: Self.uploadedKey)
            if sent > 0 { KadeBreadcrumbs.drop("auto-uploaded \(sent) crash report(s)") }
        }
    }

    /// Everything Settings' share sheet should offer: crash reports plus
    /// the breadcrumb trail. The trail exists from first launch, so this
    /// is never empty once the app has run.
    func shareableFiles() -> [URL] {
        let dir = KadeBreadcrumbs.directory
        var urls: [URL] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            urls = files.filter { $0.lastPathComponent.hasPrefix("crash-") }
        }
        if FileManager.default.fileExists(atPath: KadeBreadcrumbs.logFile.path) {
            urls.append(KadeBreadcrumbs.logFile)
        }
        return urls
    }
}
