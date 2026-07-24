import Foundation
import WebKit

/// THE ENGINE BRIDGE (July 24 2026, the pure-native Clubhouse).
///
/// Honest architecture note, so nobody "fixes" this later: iOS's libwebrtc
/// owns exactly ONE audio pipeline — the microphone. A native app cannot
/// publish a second custom audio track, which the Clubhouse needs twice over
/// (the jukebox's hi-fi stereo 'music' track and the bot guest's 'bot'
/// voice). WebKit's WebRTC CAN publish any WebAudio stream, so the app keeps
/// a 1-point invisible WKWebView hosting the fork's headless
/// /clubhouse-engine page and drives it like a sound card: commands go in
/// via evaluateJavaScript (window.KE.*), events come back through
/// webkit.messageHandlers.engine. The engine joins the room as its own
/// "<name>-<id4>-dj" participant, which every roster/steward/announcement
/// path (web and native) filters out — furniture, not a person.
///
/// Song files never touch the network: the picked file's bytes are served to
/// the page over a kadefile:// custom scheme straight from memory.
@MainActor
final class ClubhouseEngine: NSObject {
    enum Event {
        case ready
        case dead
        case gone
        case playing(id: String, pos: Double)
        case pos(id: String, pos: Double, silenced: Bool)
        case ended(id: String)
        case playFail(id: String)
        case botReady
        case botDone
        case botFail
        case ears(String)
    }

    var onEvent: ((Event) -> Void)?

    private(set) var webView: WKWebView?
    private let songs = SongSchemeHandler()

    /// Loads the headless page with everything it needs riding the URL
    /// FRAGMENT (LiveKit token, signal URL, the app's own API token) —
    /// fragments never leave the device in a request, and the page scrubs
    /// them from its address on boot.
    func connect(livekitToken: String, livekitURL: String, apiToken: String) {
        teardown()
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(songs, forURLScheme: "kadefile")
        config.userContentController.add(WeakScriptHandler(self), name: "engine")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.isHidden = true
        web.accessibilityElementsHidden = true
        webView = web

        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let frag = "lk=\(enc(livekitToken))&url=\(enc(livekitURL))&api=\(enc(apiToken))"
        if let url = URL(string: "https://kademurdock.com/clubhouse-engine#\(frag)") {
            web.load(URLRequest(url: url))
        }
    }

    func teardown() {
        if let web = webView {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "engine")
            web.stopLoading()
            web.load(URLRequest(url: URL(string: "about:blank")!))
        }
        webView = nil
        songs.clear()
    }

    var isUp: Bool { webView != nil }

    /// Hands a picked song's bytes to the kadefile:// lane.
    func register(songId: String, data: Data) {
        songs.put(id: songId, data: data)
    }

    func command(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// JSON-encodes a Swift string into a safe JS string literal.
    static func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
           let out = String(data: data, encoding: .utf8) {
            return out
        }
        return "\"\""
    }

    fileprivate func handle(message body: Any) {
        guard let dict = body as? [String: Any], let t = dict["t"] as? String else { return }
        let id = (dict["id"] as? String) ?? ""
        let pos = (dict["pos"] as? NSNumber)?.doubleValue ?? 0
        switch t {
        case "ready": onEvent?(.ready)
        case "dead": onEvent?(.dead)
        case "gone": onEvent?(.gone)
        case "playing": onEvent?(.playing(id: id, pos: pos))
        case "pos": onEvent?(.pos(id: id, pos: pos, silenced: (dict["silenced"] as? Bool) ?? false))
        case "ended": onEvent?(.ended(id: id))
        case "playfail": onEvent?(.playFail(id: id))
        case "botReady": onEvent?(.botReady)
        case "botDone": onEvent?(.botDone)
        case "botFail": onEvent?(.botFail)
        case "ears":
            if let text = dict["text"] as? String, !text.isEmpty { onEvent?(.ears(text)) }
        default: break
        }
    }
}

/// WKUserContentController retains its message handlers strongly — a weak
/// proxy keeps the engine (and the webview it owns) collectable.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: ClubhouseEngine?
    init(_ target: ClubhouseEngine) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            self.target?.handle(message: message.body)
        }
    }
}

/// Serves picked song bytes to the engine page as kadefile://song/<id>.
/// CORS headers included — WebKit applies cross-origin rules to custom-scheme
/// fetches made from an https page.
private final class SongSchemeHandler: NSObject, WKURLSchemeHandler {
    private var files: [String: Data] = [:]
    private let lock = NSLock()

    func put(id: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        // Keep at most three songs in memory — radio fights replay recents.
        if files.count >= 3, files[id] == nil, let oldest = files.keys.first {
            files.removeValue(forKey: oldest)
        }
        files[id] = data
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        files.removeAll()
    }

    private func data(for id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[id]
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = url.lastPathComponent
        guard let bytes = data(for: id) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers: [String: String] = [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(bytes.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
        ]
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(bytes)
            urlSchemeTask.didFinish()
        } else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
