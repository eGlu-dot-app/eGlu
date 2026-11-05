#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit

/// An extension's own page beside a website's: its popup or its side panel,
/// each in a view made from the extension's configuration, as Search's are
/// (its ExtensionPopup.swift): WebKit's own popup loses messages to the
/// worker for some extensions. To WebKit each is a tab of the space's
/// window at no place in its row, as Chrome puts a popup, since WebKit
/// carries a page's messages only when it can name the tab it is in.
@MainActor
public final class ExtensionSurface: NSObject, WebExtensionSurface, WKWebExtensionTab, WKUIDelegate, WKNavigationDelegate {
    public let extensionID: String
    public let space: UUID
    let web: WKWebView
    weak var context: WKWebExtensionContext?
    /// The controller it was opened with, told when it closes even after
    /// the extension's context has been unloaded from it.
    private weak var controller: WKWebExtensionController?
    private var closed = false
    /// The page asked to go: window.close(), or a link out of it.
    public var onClose: (() -> Void)?

    private let scheme: String
    private let tabs: ExtensionTabs?
    private let host: any ExtensionAuxiliaryPageHost

    public var view: NSView { web }
    public var url: URL? { web.url }
    public func focus() { web.window?.makeFirstResponder(web) }

    public static func page(_ url: URL, for context: WKWebExtensionContext, in space: UUID,
                            scheme: String, tabs: ExtensionTabs, host: any ExtensionAuxiliaryPageHost,
                            fallbackID: String? = nil) -> ExtensionPanePage? {
        guard let surface = ExtensionSurface(url, for: context, in: space, scheme: scheme,
                                             tabs: tabs, host: host) else { return nil }
        let package = context.webExtension
        return ExtensionPanePage(surface: surface, name: package.displayName ?? fallbackID ?? context.uniqueIdentifier,
                                 icon: package.icon(for: CGSize(width: 32, height: 32)))
    }

    /// Nil unless `url` is the extension's own: no site is ever loaded here.
    public convenience init?(_ url: URL, for context: WKWebExtensionContext, in space: UUID,
                             scheme: String, tabs: ExtensionTabs, host: any ExtensionAuxiliaryPageHost) {
        self.init(url, extensionID: context.uniqueIdentifier, context: context, in: space,
                  scheme: scheme, tabs: tabs, host: host, configuration: { context.webViewConfiguration })
    }

    // The factory lets package tests observe a load without starting one.
    init?(_ url: URL, extensionID: String, context: WKWebExtensionContext? = nil, in space: UUID,
          scheme: String, tabs: ExtensionTabs? = nil, host: any ExtensionAuxiliaryPageHost,
          configuration: () -> WKWebViewConfiguration?,
          makeView: @MainActor (NSRect, WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: $0, configuration: $1) }) {
        guard url.scheme == scheme, url.host() == extensionID,
              let configuration = configuration() else { return nil }
        self.extensionID = extensionID
        self.scheme = scheme
        self.tabs = tabs
        self.host = host
        self.space = space
        self.context = context
        web = makeView(NSRect(x: 0, y: 0, width: 25, height: 25), configuration)
        super.init()
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isInspectable = true
        // White behind the page, as Chrome paints a popup: many leave their
        // background unset, and their dark text over glass would vanish.
        web.underPageBackgroundColor = .white
        controller = context?.webExtensionController
        controller?.didOpenTab(self)
        web.load(URLRequest(url: url))
    }

    /// Put away for good: WebKit told, and nothing left that holds it.
    public func close() {
        guard !closed else { return }
        closed = true
        onClose = nil
        controller?.didCloseTab(self, windowIsClosing: false)
        host.releaseExtensionPage(web)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
    }

    /// Whether the keys go to its page now.
    public var hasFocus: Bool {
        (web.window?.firstResponder as? NSView)?.isDescendant(of: web) == true
    }

    // MARK: Chrome's measure of a popup (Search's)

    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still the 25-point square: the width the page names for itself if it
    /// names one, else its narrowest (min-content), else, for a page with
    /// next to no width of its own, what its content spans; then, laid out
    /// at that width, the height it names or spans. Widths are the content's,
    /// without a scrollbar shown always (Settings › Appearance), which is
    /// added back. Nothing of it is left on the page. The third number is 1
    /// when the page named its width, which is then followed both ways.
    static let preferred = """
    (() => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!d || !v) return null;
      const m = window.__egluSizing || (window.__egluSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const gutter = innerWidth - v.clientWidth;
      const box = d.getBoundingClientRect();
      let w, named = 1;
      if (Math.abs(box.width - v.clientWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - v.clientWidth) <= 1) w = m.w;
      else {
        named = 0;
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      w = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
      d.style.setProperty("width", (w - gutter) + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h + innerHeight - v.clientHeight))), named];
    })()
    """

    /// The page's own measure of itself, nil until it has one, and whether
    /// it named its width.
    public func measure() async -> (size: NSSize, named: Bool)? {
        guard let found = try? await web.evaluateJavaScript(Self.preferred) as? [Double], found.count == 3 else { return nil }
        return (NSSize(width: found[0], height: found[1]), found[2] == 1)
    }

    // MARK: The page asking

    public func webViewDidClose(_ webView: WKWebView) { onClose?() }

    /// A link that asks for a new window becomes a tab, and the surface
    /// goes, as a popup does in Chrome when you follow a link out of it.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? ""), let context {
            _ = tabs?.open(url, in: space, active: true, pinned: false, context: context)
        }
        onClose?()
        return nil
    }

    // Its page stays the extension's: a site loaded here would run with the
    // extension's configuration.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationPolicy(to: navigationAction.request.url,
                                         targetIsMainFrame: navigationAction.targetFrame?.isMainFrame))
    }

    func navigationPolicy(to: URL?, targetIsMainFrame: Bool?) -> WKNavigationActionPolicy {
        guard targetIsMainFrame != false else { return .allow }
        if to?.scheme == scheme, to?.host() == extensionID { return .allow }
        if let to, ["http", "https"].contains(to.scheme ?? ""), let context {
            _ = tabs?.open(to, in: space, active: true, pinned: false, context: context)
        }
        return .cancel
    }

    // No camera or microphone from a popup or a panel yet.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// The screen: yes only while eGlu's own recording call is under way in
    /// this page (ExtensionCapture), no otherwise.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    public func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        MainActor.assumeIsolated { decisionHandler(host.extensionDisplayDecision(for: web)) }
    }

    // MARK: As WebKit's tab

    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { tabs?.window(for: space) }
    public func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    public func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    public func title(for context: WKWebExtensionContext) -> String? { web.title }
    public func url(for context: WKWebExtensionContext) -> URL? { web.url }
    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    public func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    public func close(for context: WKWebExtensionContext) async throws { onClose?() }
}

#endif
