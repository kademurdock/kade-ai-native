import SwiftUI
import WebKit

/// The local renderer receives a value snapshot, never credentials or a game API.
struct WorldPictureView: UIViewRepresentable {
    let snapshot: WorldPictureSnapshot
    let motion: Bool
    @Binding var description: String

    func makeCoordinator() -> Coordinator { Coordinator(description: $description) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.isUserInteractionEnabled = false
        if let url = Bundle.main.url(forResource: "ReverieStage", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            context.coordinator.report("The room picture is unavailable. All world controls and sound remain available.")
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.snapshot = snapshot
        context.coordinator.motion = motion
        context.coordinator.update(view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.evaluateJavaScript("window.reverieNativeDispose && window.reverieNativeDispose()")
        view.stopLoading()
        view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var snapshot: WorldPictureSnapshot?
        var motion = false
        var ready = false
        var active = true
        private var lastPayload: String?
        private var revision = 0
        private var description: Binding<String>

        init(description: Binding<String>) { self.description = description }

        func report(_ text: String) {
            Task { @MainActor [weak self] in
                guard let self, active else { return }
                description.wrappedValue = text
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            lastPayload = nil
            update(webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            report("The room picture stopped to free resources. All world controls and sound remain available.")
        }

        func update(_ view: WKWebView) {
            guard active, ready, let snapshot,
                  let data = try? JSONEncoder().encode(snapshot),
                  let json = String(data: data, encoding: .utf8) else { return }
            let payload = json + String(motion)
            guard payload != lastPayload else { return }
            lastPayload = payload
            revision += 1
            let requested = revision
            view.callAsyncJavaScript("return window.reverieNativeUpdate(JSON.parse(json), motion)",
                arguments: ["json": json, "motion": motion], in: nil, in: .page) { [weak self] result in
                guard let self, self.active, self.revision == requested else { return }
                if case .success(let text as String) = result { self.report(text) }
                else { self.report("The room picture is unavailable. All world controls and sound remain available.") }
            }
        }
    }
}
