import UIKit

/// Sep 25 2026, her ask: "some kind of autopaste thing … so we don't have to
/// manually paste youtube links." A link box fills itself with a link copied
/// in another app, once per copy.
///
/// Asking whether the clipboard holds a link (hasURLs, detectPatterns) shows
/// nothing. Reading it shows iOS's paste notice, or its Allow Paste question,
/// until Settings › Kade-AI › Paste from Other Apps is set to Allow. So the
/// clipboard is only read when a link is really there, and only once for each
/// copy (changeCount), per box.
@MainActor
enum CopiedLink {
    private static var seen: [String: Int] = [:]

    /// The link copied since `box` last looked, when `accept` likes it; nil otherwise.
    static func take(_ box: String, where accept: (URL) -> Bool) async -> String? {
        let board = UIPasteboard.general
        let count = board.changeCount
        guard seen[box] != count else { return nil }
        seen[box] = count
        guard await holdsLink(board) else { return nil }
        let text = board.url?.absoluteString ?? board.string ?? ""
        guard let link = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).first(where: { $0.lowercased().hasPrefix("http") }),
              let url = URL(string: link), accept(url) else { return nil }
        return link
    }

    private static func holdsLink(_ board: UIPasteboard) async -> Bool {
        if board.hasURLs { return true }
        guard board.hasStrings else { return false }
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
}
