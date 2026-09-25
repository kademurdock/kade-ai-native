import UIKit

/// Sep 25 2026, her ask: "some kind of autopaste thing … so we don't have to
/// manually paste youtube links." A link box fills itself with a link copied
/// in another app, once per copy.
///
/// Asking whether the clipboard holds a link (hasURLs, detectPatterns) shows
/// nothing. Reading it shows iOS's paste notice, or its Allow Paste question,
/// until Settings › Kade-AI › Paste from Other Apps is set to Allow. So the
/// clipboard is only read when the silent check finds a web link, and each
/// copy (changeCount) is read at most once for the whole app; every box then
/// fills from that one read, once per copy.
@MainActor
enum CopiedLink {
    private static var seen: [String: Int] = [:]
    /// The one read of the latest copy: its changeCount and the first web link in it.
    private static var lastRead: (count: Int, link: String?)?

    /// The link copied since `box` last looked, when `accept` likes it; nil otherwise.
    static func take(_ box: String, where accept: (URL) -> Bool) async -> String? {
        let board = UIPasteboard.general
        let count = board.changeCount
        guard seen[box] != count else { return nil }
        seen[box] = count
        guard let link = await copiedLink(board, count: count),
              let url = URL(string: link), accept(url) else { return nil }
        return link
    }

    /// The first web link in copy `count`, reading the clipboard at most once per copy.
    private static func copiedLink(_ board: UIPasteboard, count: Int) async -> String? {
        if let last = lastRead, last.count == count { return last.link }
        guard board.hasURLs || board.hasStrings, await holdsWebLink(board) else { return nil }
        // Another box may have read this copy during the check; a newer copy waits for its own check.
        if let last = lastRead, last.count == count { return last.link }
        guard board.changeCount == count else { return nil }
        let text = (board.hasURLs ? board.url?.absoluteString : nil) ?? board.string ?? ""
        let link = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).first(where: { $0.lowercased().hasPrefix("http") })
        lastRead = (count: count, link: link)
        return link
    }

    /// Whether the copy looks like a web link, asked without iOS showing anything.
    private static func holdsWebLink(_ board: UIPasteboard) async -> Bool {
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            board.detectPatterns(for: [.probableWebURL]) { result in
                if case .success(let found) = result {
                    done.resume(returning: found.contains(.probableWebURL))
                } else {
                    done.resume(returning: false)
                }
            }
        }
    }

    nonisolated static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    nonisolated static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A link the Clubhouse jukebox can pull a song from: YouTube, a Spotify
    /// song, SoundCloud, Bandcamp, Mixcloud, archive.org, or an audio file.
    nonisolated static func isSongLink(_ url: URL) -> Bool {
        guard isWebLink(url), let host = url.host?.lowercased() else { return false }
        if isYouTube(url) { return true }
        if host == "open.spotify.com" { return url.path.contains("/track/") }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if ["soundcloud.com", "m.soundcloud.com", "on.soundcloud.com", "mixcloud.com", "archive.org"].contains(bare)
            || bare.hasSuffix(".bandcamp.com") { return true }
        return ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "aif"].contains(url.pathExtension.lowercased())
    }
}
