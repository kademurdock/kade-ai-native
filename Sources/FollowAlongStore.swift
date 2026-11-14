import Combine
import CryptoKit
import Foundation

/// One follow-along track kept on this phone (Tellavision, Nov 14 2026).
struct FollowStoredTrack: Identifiable, Hashable {
    /// The folder's name: the job and the copy.
    let id: String
    let folder: URL
    let job: String
    let copyVersion: Int
    let title: String
    let filmSeconds: Double
    let coversStart: Double
    let coversEnd: Double
    let lines: Int
    let bytes: Int
    let savedAt: Date

    /// "1 hour 42 minutes, 380 lines, kept 14 November 2026".
    var summary: String {
        var parts = [FollowWords.length(filmSeconds)]
        if coversStart > 1 || coversEnd < filmSeconds - 1 {
            if coversStart <= 1 {
                parts.append("the first \(FollowWords.length(coversEnd))")
            } else {
                parts.append("from \(FollowWords.clock(coversStart)) on")
            }
        }
        parts.append(lines == 1 ? "1 line" : "\(lines) lines")
        parts.append("kept " + Self.dayWords.string(from: savedAt))
        return parts.joined(separator: ", ")
    }

    private static let dayWords: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}

/// Keeps every downloaded track for good, in the app's own storage, under
/// the account that downloaded it (her decision: tracks are tiny, and a
/// video expires on the server after 7 to 30 days; the copy here keeps
/// working, with no internet). Only her own tracks: they come from her own
/// jobs (the server checks the owner), and another account signed in on the
/// same phone sees its own list, never hers. Nothing is shared.
///
/// Each track is a folder: track.json exactly as the server sent it, the
/// fingerprint (print.sypr), and meta.json for the list.
@MainActor
final class FollowAlongStore: ObservableObject {
    static let shared = FollowAlongStore()

    enum StoreError: LocalizedError {
        case noAccount
        case damaged
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noAccount: return "Please sign in to Kade-AI again."
            case .damaged: return FollowWords.damagedDownload
            case .unreadable: return FollowWords.damagedOnPhone
            }
        }
    }

    enum Fetched {
        case ready(FollowStoredTrack)
        /// Not ready yet, or not possible: the words to say.
        case notYet(String)
    }

    /// Newest first.
    @Published private(set) var tracks: [FollowStoredTrack] = []
    private var account: String?

    /// The biggest fingerprint taken: a two-hour film is 1 to 2 MB.
    static let largestPrint = 32 * 1024 * 1024

    private init() {}

    /// Sign-in (the account's id) and sign-out (nil).
    func bind(userId: String?) {
        account = userId.map { Self.accountFolderName($0) }
        refresh()
    }

    func refresh() {
        guard let account else {
            tracks = []
            return
        }
        tracks = Self.list(in: Self.folder(account: account))
    }

    func stored(job: String, version: Int) -> FollowStoredTrack? {
        tracks.first { $0.job == job && $0.copyVersion == version }
    }

    /// Gets the track of one finished copy from the server: asks for it,
    /// asks the server to make it when it can, downloads the fingerprint,
    /// checks it whole against the track's checksum (once more if it is
    /// not), and keeps both.
    func fetch(jobId: String, version: Int, service: DescribedVideoService) async throws -> Fetched {
        var answer = try await service.track(jobId: jobId, version: version)
        if !answer.isReady && answer.state == "possible" {
            answer = try await service.makeTrack(jobId: jobId, version: version)
        }
        guard answer.isReady, let trackData = answer.trackData, let link = answer.printLink else {
            switch answer.state {
            case "making", "possible": return .notYet(answer.reason ?? FollowWords.making)
            case "gone": return .notYet(answer.reason ?? FollowWords.gone)
            default: return .notYet(answer.reason ?? FollowWords.notReady)
            }
        }
        let track: FollowTrack
        do {
            track = try FollowTrack.read(trackData)
        } catch let problem as FollowTrack.Problem {
            return .notYet(problem.words)
        }
        for _ in 0..<2 {
            let print = try await service.downloadData(from: link, limit: Self.largestPrint)
            if Self.matches(print, track.print) {
                return .ready(try save(trackData: trackData, print: print, track: track, job: jobId, version: version))
            }
            KadeBreadcrumbs.drop("follow along: a fingerprint download did not match its checksum (\(print.count) bytes)")
        }
        throw StoreError.damaged
    }

    /// The fingerprint is whole: its size and its sha256 are the track's.
    nonisolated static func matches(_ print: Data, _ expected: FollowTrack.Print) -> Bool {
        print.count == expected.bytes && sha256(print) == expected.sha256.lowercased()
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func delete(_ item: FollowStoredTrack) throws {
        try FileManager.default.removeItem(at: item.folder)
        refresh()
    }

    /// The two files of a stored track, read off the main thread by the player.
    nonisolated static func files(of item: FollowStoredTrack) throws -> (track: Data, print: Data) {
        do {
            let track = try Data(contentsOf: item.folder.appendingPathComponent("track.json"))
            let print = try Data(contentsOf: item.folder.appendingPathComponent("print.sypr"))
            return (track, print)
        } catch {
            throw StoreError.unreadable
        }
    }

    // MARK: Folders

    private func save(trackData: Data, print: Data, track: FollowTrack, job: String, version: Int) throws -> FollowStoredTrack {
        guard let account else { throw StoreError.noAccount }
        let name = Self.folderName(job: job, version: version)
        let folder = Self.folder(account: account).appendingPathComponent(name, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try trackData.write(to: folder.appendingPathComponent("track.json"), options: .atomic)
        try print.write(to: folder.appendingPathComponent("print.sypr"), options: .atomic)
        let meta = Meta(title: track.title, job: job, copyVersion: version, filmSeconds: track.filmSeconds,
                        coversStart: track.covers.startSec, coversEnd: track.covers.endSec, lines: track.cues.count,
                        bytes: trackData.count + print.count, savedAt: Date().timeIntervalSince1970)
        try JSONEncoder().encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        refresh()
        guard let kept = tracks.first(where: { $0.id == name }) else { throw StoreError.unreadable }
        return kept
    }

    private struct Meta: Codable {
        let title: String
        let job: String
        let copyVersion: Int
        let filmSeconds: Double
        let coversStart: Double
        let coversEnd: Double
        let lines: Int
        let bytes: Int
        let savedAt: Double
    }

    private static func list(in folder: URL) -> [FollowStoredTrack] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [FollowStoredTrack] = []
        for name in names {
            let place = folder.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: place.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data) else { continue }
            found.append(FollowStoredTrack(
                id: name, folder: place, job: meta.job, copyVersion: meta.copyVersion, title: meta.title,
                filmSeconds: meta.filmSeconds, coversStart: meta.coversStart, coversEnd: meta.coversEnd,
                lines: meta.lines, bytes: meta.bytes, savedAt: Date(timeIntervalSince1970: meta.savedAt)))
        }
        return found.sorted { $0.savedAt > $1.savedAt }
    }

    /// Application Support/FollowAlong/<account>, made when first needed.
    private static func folder(account: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FollowAlong", isDirectory: true).appendingPathComponent(account, isDirectory: true)
    }

    /// The account's id, hashed, so the folder never shows it.
    private static func accountFolderName(_ userId: String) -> String {
        String(sha256(Data(userId.utf8)).prefix(16))
    }

    private static func folderName(job: String, version: Int) -> String {
        let safe = job.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        let stem = String(String.UnicodeScalarView(safe)).prefix(64)
        return "\(stem.isEmpty ? "track" : String(stem))-v\(version)"
    }
}
