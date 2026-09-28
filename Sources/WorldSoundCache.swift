import Foundation
import CryptoKit
import AVFoundation

/// Concurrent room/effect requests share a download. Failed and corrupt files are retryable.
actor WorldSoundCache {
    static let shared = WorldSoundCache()
    private var pending: [String: Task<URL?, Never>] = [:]

    func file(for value: String, revision: String?) async -> URL? {
        guard let remote = URL(string: value), ["https", "http"].contains(remote.scheme ?? "") else { return nil }
        let identity = WorldSoundIdentity.cacheIdentity(remote, revision: revision)
        if let task = pending[identity] { return await task.value }
        let task = Task<URL?, Never> {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("world-sounds", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
            let ext = remote.pathExtension.isEmpty ? "snd" : remote.pathExtension
            let local = dir.appendingPathComponent("\(digest).\(ext)")
            if let file = try? AVAudioFile(forReading: local), file.length > 0 { return local }
            try? FileManager.default.removeItem(at: local)
            var request = URLRequest(url: remote)
            request.timeoutInterval = 12
            guard let out = try? await URLSession.shared.download(for: request),
                  (out.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            defer { try? FileManager.default.removeItem(at: out.0) }
            guard let file = try? AVAudioFile(forReading: out.0), file.length > 0 else { return nil }
            do { try FileManager.default.moveItem(at: out.0, to: local) } catch { return nil }
            return local
        }
        pending[identity] = task
        let result = await task.value
        pending[identity] = nil
        return result
    }
}
