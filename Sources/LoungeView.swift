import SwiftUI
import WebKit
import UIKit

/// KADE'S CLUBHOUSE, native doorway (born THE LOUNGE — renamed July 24 2026
/// per CLUBHOUSE_VISION: the web page this hosts now carries the shared
/// jukebox, the Hotel's passcode rooms, and companion guests; the doorway
/// inherits all of it for free because the page IS the feature).
/// Original note (July 24 2026 — Kade: "Can you build the
/// lounge into native so I can test it there? My computer has a crap
/// internal mic.").
///
/// Honest architecture note: this screen hosts the PROVEN /lounge web room
/// (LiveKit JS) inside an in-app WebKit view — WebKit runs full WebRTC with
/// the phone's real mics, echo cancellation and all, and the page is already
/// blind-first (VoiceOver drives web content natively). A PURE-native
/// LiveKit Swift build stays on the roadmap as its own phase; tonight's job
/// is her phone's good mic in the room.
///
/// Sign-in handshake: the app's own access token rides the URL FRAGMENT
/// (#lktok=...) — fragments never leave the device in the request, and the
/// page scrubs it from the address on load. No cookies needed, no second
/// sign-in.
///
/// Mic permission: WKUIDelegate grants the page's capture request directly
/// (iOS still gates the FIRST use behind the system microphone prompt the
/// app already carries NSMicrophoneUsageDescription for).
struct LoungeView: View {
    let apiClient: KadeAPIClient

    var body: some View {
        LoungeWebContainer()
            .navigationTitle("Kade's Clubhouse")
            .navigationBarTitleDisplayMode(.inline)
            .ignoresSafeArea(edges: .bottom)
    }
}

private struct LoungeWebContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.scrollView.keyboardDismissMode = .interactive
        load(into: web)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func load(into web: WKWebView) {
        var urlString = "https://kademurdock.com/lounge"
        if let token = Keychain.string(for: .accessToken), !token.isEmpty,
           let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "#lktok=\(encoded)"
        }
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        web.load(req)
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        /// The page asking for the mic IS the point of this screen — grant
        /// it; iOS's own system prompt still protects the very first use.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(origin.host == "kademurdock.com" && type == .microphone ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            UIAccessibility.post(
                notification: .announcement,
                argument: "The Clubhouse page couldn't load — check the connection and reopen this screen."
            )
        }
    }
}
