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
