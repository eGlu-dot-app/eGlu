import WebEngineCore
import WebKit

/// Stands in the window under the page on screen, where WebKit runs it as
/// a page that shows; out of a window its timers are slowed and it may
/// never be drawn. No media starts without a touch, and none can be given.
@MainActor
public final class WebKitHiddenPage: NSObject, WKNavigationDelegate, WebHiddenPage {
    private let view: WKWebView
    private let appWorld: WKContentWorld
    private let allows: @MainActor (URL?) -> Bool
    private var loaded: ((Bool) -> Void)?

    /// `customUserAgent` is the agent the app gives it, if any: the iPad's
    /// asks to be served the site as a computer is.
    public init(beside view: WKWebView, ruleLists: [WKContentRuleList], appWorld: WKContentWorld,
                customUserAgent: String? = nil, allows: @escaping @MainActor (URL?) -> Bool) {
        self.appWorld = appWorld
        self.allows = allows
        let config = WKWebViewConfiguration()
        config.websiteDataStore = view.configuration.websiteDataStore
        #if os(iOS)
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        #endif
        config.applicationNameForUserAgent = view.configuration.applicationNameForUserAgent
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        config.allowsPictureInPictureMediaPlayback = false
        #endif
        config.allowsAirPlayForMediaPlayback = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = WKUserContentController()
        for list in ruleLists { controller.add(list) }
        config.userContentController = controller
        self.view = WKWebView(frame: view.frame, configuration: config)
        super.init()
        if let customUserAgent { self.view.customUserAgent = customUserAgent }
        self.view.navigationDelegate = self
        #if os(macOS)
        self.view.alphaValue = 0
        self.view.setAccessibilityElement(false)
        self.view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        view.superview?.addSubview(self.view, positioned: .below, relativeTo: view)
        #else
        self.view.isUserInteractionEnabled = false
        self.view.accessibilityElementsHidden = true
        self.view.scrollView.scrollsToTop = false
        self.view.alpha = 0
        self.view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        view.superview?.insertSubview(self.view, belowSubview: view)
        #endif
    }

    public func callInAppWorld(_ body: String, arguments: [String: Any]) async throws -> Any? {
        try await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: appWorld)
    }

    /// Whether the page began to load, in the time it is given.
    public func begin(_ url: URL, within limit: Duration) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            loaded = { done.resume(returning: $0) }
            view.load(URLRequest(url: url))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                self?.finish(false)
            }
        }
    }

    /// The one answer to whether it began, from whichever comes first: the page, a failure, or the time running out.
    private func finish(_ ok: Bool) {
        loaded?(ok)
        loaded = nil
    }

    /// The page goes, and whoever waits on its load hears that nothing came of it.
    public func stop() {
        finish(false)
        view.navigationDelegate = nil
        view.stopLoading()
        view.removeFromSuperview()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The main frame stays within the rule its owner gave it.
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
        let url = navigationAction.request.url
        guard allows(url), !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            finish(false)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        finish(true)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(false)
    }
}
