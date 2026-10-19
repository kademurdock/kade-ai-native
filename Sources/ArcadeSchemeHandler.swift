import Foundation
import WebKit

/// Serves the game page and every file it asks for out of the downloaded
/// packs, under a private scheme:
///   kadearcade://game/<path>  the page's origin: the game pack first, then the
///                             kit pack (so play.html's "../../core/app.js"
///                             imports and EmulatorJS's data stay same-origin)
///   kadearcade://kit/<path>   the kit pack only
/// Each answer is one slice of blob.bin (pack.json gives its offset and
/// length), with the right MIME type (application/wasm for the cores,
/// text/javascript for modules) and single Range requests for media.
/// Missing files get a real 404 so the page's own error paths run.
///
/// Threading: WebKit calls start and stop on the main thread. Reading happens
/// on a private serial queue, and every answer goes back to WebKit on the main
/// actor, only for a task that has not been stopped (answering a stopped task
/// raises an exception inside WebKit). The packs' indexes never change while
/// the handler lives.
///
/// Every start gets its own token, and an answer is delivered only when the
/// live task under its key still carries that token. A task's identity alone
/// is not enough: once WebKit stops and frees a task, a new one can be made at
/// the same address (a page restarted after its process died asks for every
/// file again), and a slow read for the old task would otherwise land in it.
@MainActor
final class ArcadeSchemeHandler: NSObject, WKURLSchemeHandler {
    private let game: [ArcadeMount]
    private let kit: [ArcadeMount]
    /// A game added from Files, served at the path its page expects (Oct 19 2026).
    private let overlays: [ArcadeOverlay]
    private let queue = DispatchQueue(label: "com.kademurdock.kadeai.arcade.scheme", qos: .userInitiated)
    /// Tasks WebKit has started and not stopped, by identity, with the token of their start.
    private var live: [ObjectIdentifier: (token: Int, task: WKURLSchemeTask)] = [:]
    private var nextToken = 0
    /// Files served, for the how-the-game-ran text.
    private(set) var served = 0
    private(set) var missing: [String] = []
    /// Oct 19 2026: told every missing path, after its 404 has gone, so the
    /// game's host can say at once when EmulatorJS cannot start without it.
    /// The answer stays a 404: a failed load would send EmulatorJS to its
    /// public CDN for a core, a different build from the kit's.
    var onMissing: (@MainActor (String) -> Void)?

    init(game: [ArcadeMount], kit: [ArcadeMount], overlays: [ArcadeOverlay] = []) {
        self.game = game
        self.kit = kit
        self.overlays = overlays
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        nextToken += 1
        let token = nextToken
        live[key] = (token: token, task: urlSchemeTask)
        let request = urlSchemeTask.request
        guard let url = request.url else {
            answerMissing(key, token: token, url: URL(string: ArcadeRoute.root(.game))!, path: "(no address)")
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")
        let isHead = request.httpMethod?.uppercased() == "HEAD"
        switch ArcadeServePlan.make(url: url, rangeHeader: range, game: game, kit: kit, overlays: overlays) {
        case .notFound(let path):
            answerMissing(key, token: token, url: url, path: path)
        case .unsatisfiable(let total):
            answer(key, token: token, url: url, status: 416,
                   headers: ["Content-Range": "bytes */\(total)", "Content-Length": "0", "Access-Control-Allow-Origin": "*"],
                   body: Data())
        case .serve(let blob, let offset, let length, let status, let headers):
            if isHead {
                answer(key, token: token, url: url, status: status, headers: headers, body: Data())
                return
            }
            // Oct 19 2026: a big answer (an added N64 ROM is up to 64 MB, read
            // twice per boot) goes to WebKit piece by piece, never whole in memory.
            if length > Self.wholeAnswerBytes {
                stream(key, token: token, url: url, status: status, headers: headers, blob: blob, offset: offset, length: length)
                return
            }
            // Only plain values cross to the reading queue and back: the key, the token, the URL and the bytes.
            queue.async {
                let result: Result<Data, Error> = Result { try ArcadeBlobReader.read(blob, offset: offset, length: length) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let data):
                        self.answer(key, token: token, url: url, status: status, headers: headers, body: data)
                    case .failure:
                        self.answer(key, token: token, url: url, status: 500, headers: ["Content-Type": "text/plain; charset=utf-8"],
                                    body: Data("The game's file could not be read.".utf8))
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        // Only this very task: never a newer one that happens to share its address.
        if let entry = live[key], (entry.task as AnyObject) === (urlSchemeTask as AnyObject) {
            live[key] = nil
        }
    }

    private func answerMissing(_ key: ObjectIdentifier, token: Int, url: URL, path: String) {
        if missing.count < 20 { missing.append(path) }
        answer(key, token: token, url: url, status: 404,
               headers: ["Content-Type": "text/plain; charset=utf-8", "Access-Control-Allow-Origin": "*"],
               body: Data("Not in the downloaded game: \(path)".utf8))
        onMissing?(path)
    }

    /// Answers up to this size are read whole; bigger ones go in pieces.
    private static let wholeAnswerBytes: Int64 = 4 * 1024 * 1024
    /// One piece of a big answer.
    private static let pieceBytes: Int64 = 2 * 1024 * 1024

    /// A big answer: the headers (Content-Length already says the whole size)
    /// at once, then one piece read on the queue at a time, each handed to
    /// WebKit only while the task is still live under its token, then the end.
    private func stream(_ key: ObjectIdentifier, token: Int, url: URL, status: Int, headers: [String: String],
                        blob: URL, offset: Int64, length: Int64) {
        guard let entry = live[key], entry.token == token else { return }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            live[key] = nil
            entry.task.didFailWithError(URLError(.badServerResponse))
            return
        }
        served += 1
        entry.task.didReceive(response)
        readPiece(key, token: token, blob: blob, at: offset, left: length)
    }

    /// Reads the next piece on the queue; only one is ever in flight per task,
    /// so the pieces reach WebKit in order.
    private func readPiece(_ key: ObjectIdentifier, token: Int, blob: URL, at position: Int64, left: Int64) {
        let count = min(left, Self.pieceBytes)
        queue.async {
            let result: Result<Data, Error> = Result { try ArcadeBlobReader.read(blob, offset: position, length: count) }
            Task { @MainActor [weak self] in
                self?.pieceRead(key, token: token, blob: blob, at: position, left: left, result: result)
            }
        }
    }

    private func pieceRead(_ key: ObjectIdentifier, token: Int, blob: URL, at position: Int64, left: Int64,
                           result: Result<Data, Error>) {
        // Stopped meanwhile, or the key now belongs to a newer task: nothing more is sent.
        guard let entry = live[key], entry.token == token else { return }
        switch result {
        case .success(let data):
            entry.task.didReceive(data)
            let rest = left - Int64(data.count)
            if rest > 0 {
                readPiece(key, token: token, blob: blob, at: position + Int64(data.count), left: rest)
            } else {
                live[key] = nil
                entry.task.didFinish()
            }
        case .failure:
            live[key] = nil
            entry.task.didFailWithError(URLError(.cannotOpenFile))
        }
    }

    private func answer(_ key: ObjectIdentifier, token: Int, url: URL, status: Int, headers: [String: String], body: Data) {
        // Stopped meanwhile, or the key now belongs to a newer task: drop the answer.
        guard let entry = live[key], entry.token == token else { return }
        live[key] = nil
        let task = entry.task
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        if status < 300 { served += 1 }
        task.didReceive(response)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
    }
}
