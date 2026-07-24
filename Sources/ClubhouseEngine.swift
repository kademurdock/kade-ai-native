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
/// Song files never touch the network: the picked file's bytes are FED to
/// the page as chunked base64 over evaluateJavaScript (KE.feedB64) — fetch()
/// flatly refuses custom URL schemes in WebKit, a lesson build 156 taught
/// live, so there is no kadefile:// lane anymore, only the JS bridge.
@MainActor
final class ClubhouseEngine: NSObject {
    enum Event {
        case ready
        case dead
        case gone
        case playing(id: String, pos: Double, dur: Double)
        case pos(id: String, pos: Double, silenced: Bool)
        case ended(id: String)
        case halted(id: String, pos: Double)
        case playFail(id: String, why: String)
        case needSong(id: String)
        case feedFail(id: String)
        case botReady
        case botDone
        case botFail
        case ears(String)
        case recStarted
        case recChunk(b64: String)
        case recDone(mime: String, secs: Double)
        case recFail
    }

    var onEvent: ((Event) -> Void)?

    private(set) var webView: WKWebView?

    /// Loads the headless page with everything it needs riding the URL
    /// FRAGMENT (LiveKit token, signal URL, the app's own API token) —
    /// fragments never leave the device in a request, and the page scrubs
    /// them from its address on boot.
    func connect(livekitToken: String, livekitURL: String, apiToken: String) {
        teardown()
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
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
            // Always fetch the engine page FRESH — a cached copy from an old
            // deploy replays yesterday's bugs on today's phone (round 5; the
            // server now also sends Cache-Control: no-store).
            web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    func teardown() {
        if let web = webView {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "engine")
            web.stopLoading()
            web.load(URLRequest(url: URL(string: "about:blank")!))
        }
        webView = nil
    }

    var isUp: Bool { webView != nil }

    func command(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Runs JS and reports whether WebKit accepted it — the song-feeding
    /// lane awaits each chunk so big files never pile up in flight.
    func commandAsync(_ js: String) async -> Bool {
        guard let web = webView else { return false }
        return await withCheckedContinuation { cont in
            web.evaluateJavaScript(js) { _, error in
                cont.resume(returning: error == nil)
            }
        }
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
        case "playing": onEvent?(.playing(id: id, pos: pos, dur: (dict["dur"] as? NSNumber)?.doubleValue ?? 0))
        case "halted": onEvent?(.halted(id: id, pos: pos))
        case "pos": onEvent?(.pos(id: id, pos: pos, silenced: (dict["silenced"] as? Bool) ?? false))
        case "ended": onEvent?(.ended(id: id))
        case "playfail": onEvent?(.playFail(id: id, why: (dict["why"] as? String) ?? ""))
        case "need": onEvent?(.needSong(id: id))
        case "feedfail": onEvent?(.feedFail(id: id))
        case "botReady": onEvent?(.botReady)
        case "botDone": onEvent?(.botDone)
        case "botFail": onEvent?(.botFail)
        case "ears":
            if let text = dict["text"] as? String, !text.isEmpty { onEvent?(.ears(text)) }
        case "recon": onEvent?(.recStarted)
        case "recb":
            if let b64 = dict["b64"] as? String, !b64.isEmpty { onEvent?(.recChunk(b64: b64)) }
        case "recdone":
            onEvent?(.recDone(mime: (dict["mime"] as? String) ?? "audio/mp4",
                              secs: (dict["secs"] as? NSNumber)?.doubleValue ?? 0))
        case "recfail": onEvent?(.recFail)
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

