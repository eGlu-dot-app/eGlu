import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit

/// The web view's whole UI delegate, with presentation kept in the host.
@MainActor
public final class WebKitUIAdapter: NSObject, WKUIDelegate {
    private weak var view: WKWebView?
    private weak var events: (any WebPageUIEvents)?
    private weak var presenter: (any WebDialogPresenter)?

    /// Complete construction before assigning the adapter as uiDelegate:
    /// WebKit caches the selectors the delegate responds to at assignment.
    public init(view: WKWebView, events: any WebPageUIEvents, presenter: any WebDialogPresenter) {
        self.view = view
        self.events = events
        self.presenter = presenter
        super.init()
    }

    /// WebKit's private way to hear which element a context menu is for:
    /// its link is kept for "Handoff Linked File", the menu itself shown
    /// as proposed, so willOpenMenu sees it all.
    @objc public func _webView(_ webView: WKWebView, getContextMenuFromProposedMenu menu: NSMenu,
                               forElement element: NSObject?, userInfo: Any?,
                               completionHandler: @escaping (NSMenu?) -> Void) {
        if let events {
            events.contextMenuOpening(link: element.flatMap(Self.link(of:)))
        }
        completionHandler(menu)
    }

    /// The link a menu's element is on. The element is WebKit's private
    /// _WKContextMenuElementInfo, whose hit test result holds the link
    /// (absoluteLinkURL): each step is asked first, as picture in picture
    /// asks, since a key it doesn't have would raise.
    private static func link(of element: NSObject) -> URL? {
        guard element.responds(to: NSSelectorFromString("hitTestResult")),
              let result = element.value(forKey: "hitTestResult") as? NSObject,
              result.responds(to: NSSelectorFromString("absoluteLinkURL")) else { return nil }
        return result.value(forKey: "absoluteLinkURL") as? URL
    }

    /// WebKit's private word that the page left a scroll unused, the
    /// answer its own swipe waits for: the swipe's (PageSwipe.leftAlone).
    @objc public func _webView(_ webView: WKWebView, didNotHandleWheelEvent event: NSEvent) {
        events?.scrollNotHandled(event)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = WebKitChildRequest(configuration: configuration, action: navigationAction, features: windowFeatures)
        let surface = events?.childRequested(request)
        return surface?.view as? WKWebView
    }

    public func webViewDidClose(_ webView: WKWebView) {
        events?.closeRequested()
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let presenter else { return completionHandler() }
        presenter.alert(message, host: frame.securityOrigin.host) { completionHandler() }
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let presenter else { return completionHandler(false) }
        presenter.confirm(message, host: frame.securityOrigin.host) { completionHandler($0) }
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let presenter else { return completionHandler(nil) }
        presenter.prompt(prompt, defaultText: defaultText, host: frame.securityOrigin.host) { completionHandler($0) }
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let presenter else { return completionHandler(nil) }
        presenter.openFiles(allowsMultiple: parameters.allowsMultipleSelection,
                            allowsDirectories: parameters.allowsDirectories) { completionHandler($0) }
    }

    public func tearDown() {
        view = nil
        events = nil
        presenter = nil
    }
}
