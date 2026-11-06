import AppKit
import WebEngineAppKit
import WebKit

/// The picture child's WebKit objects. Window policy and presentation belong
/// to the app; these delegates call it synchronously, with no queue or task.
@MainActor
public final class WebKitPicturePage: NSObject, WebPicturePage, WKNavigationDelegate, WKUIDelegate {
    public let webView: WKWebView
    private weak var events: (any WebPicturePageEvents)?

    public init(request: WebKitChildRequest, size: CGSize) {
        let configuration = request.configuration
        // None of the opener's scripts: the page in it is the site's to fill.
        configuration.userContentController = WKUserContentController()
        // A call's videos, moved here, play on in a page no one has clicked yet.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WebKitPictureView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        super.init()
    }

    public var view: NSView { webView }
    public func focus() { webView.window?.makeFirstResponder(webView) }

    public func connect(events: any WebPicturePageEvents) {
        self.events = events
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
    }

    public func tearDown() {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        events = nil
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let events else { return decisionHandler(.allow) }
        events.decidePictureNavigation(url: navigationAction.request.url,
                                       targetIsMainFrame: navigationAction.targetFrame?.isMainFrame ?? true) {
            decisionHandler($0 ? .allow : .cancel)
        }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        events?.pictureRequestedWindow(url: navigationAction.request.url)
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) { events?.pictureCloseRequested() }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { events?.pictureProcessEnded() }
}

/// A click on a call's controls works the first time, with the app behind.
private final class WebKitPictureView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
