import WebEngineCore
import WebKit

/// Translates action and response policy. All other delegate selectors still belong to the page.
///
/// It must not outlive its legacy delegate: WebKit remembers which selectors
/// a delegate answers when it is assigned, and one forwarded to a delegate
/// that has gone would raise. Page owns its adapter, and WebKit holds its
/// navigation delegate weakly, so the two go together.
@MainActor
public final class WebKitNavigationAdapter: NSObject, WKNavigationDelegate, WebRequestLoading {
    private weak var view: WKWebView?
    private weak var policy: (any WebNavigationPolicy)?
    private weak var legacy: (any WKNavigationDelegate)?

    /// Complete construction before assigning the adapter as navigationDelegate:
    /// WebKit caches the selectors the delegate responds to at assignment.
    public init(view: WKWebView, policy: any WebNavigationPolicy, legacy: any WKNavigationDelegate) {
        self.view = view
        self.policy = policy
        self.legacy = legacy
        super.init()
    }

    public override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        // Every form of the decision on a navigation is the policy's, never
        // the legacy delegate's: WebKit asks the `preferences:` form first.
        let name = NSStringFromSelector(selector)
        if name.contains("decidePolicyForNavigationAction") || name.contains("decidePolicyForNavigationResponse") {
            return false
        }
        // WebKit asks on the main thread; anything asking elsewhere gets the
        // adapter's own answer rather than a crash.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { legacy?.responds(to: selector) ?? false }
    }

    public override func forwardingTarget(for selector: Selector!) -> Any? {
        guard Thread.isMainThread else { return super.forwardingTarget(for: selector) }
        let target = MainActor.assumeIsolated { () -> (any WKNavigationDelegate)? in
            // As in responds(to:): a decision is never the legacy delegate's.
            let name = NSStringFromSelector(selector)
            if name.contains("decidePolicyForNavigationAction") || name.contains("decidePolicyForNavigationResponse") {
                return nil
            }
            if let legacy, legacy.responds(to: selector) { return legacy }
            return nil as (any WKNavigationDelegate)?
        }
        if let target { return target }
        return super.forwardingTarget(for: selector)
    }

    public func snapshot(_ action: WKNavigationAction) -> WebNavigation {
        Self.translate(action)
    }

    /// Also used by the temporary child-creation WKNavigationAction overload.
    public static func translate(_ action: WKNavigationAction) -> WebNavigation {
        let kind: WebNavigationKind
        switch action.navigationType {
        case .linkActivated: kind = .link
        case .formSubmitted: kind = .form
        case .formResubmitted: kind = .formResubmission
        case .backForward: kind = .history
        case .reload: kind = .reload
        case .other: kind = .other
        @unknown default: kind = .unknown(action.navigationType.rawValue)
        }
        var modifiers: WebModifiers = []
        if action.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if action.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if action.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if action.modifierFlags.contains(.control) { modifiers.insert(.control) }
        // `sourceFrame` is declared never nil, but WebKit leaves it nil for
        // some loads the app starts itself; read as non-optional, a nil one
        // crashes. Read as optional, it is an opaque origin.
        let sourceFrame: WKFrameInfo? = action.sourceFrame
        let source: WebOrigin
        if let origin = sourceFrame?.securityOrigin, !origin.protocol.isEmpty, !origin.host.isEmpty {
            source = .tuple(scheme: origin.protocol, host: origin.host, port: origin.port)
        } else {
            source = .opaque
        }
        return WebNavigation(request: action.request, sourceOrigin: source,
                             targetIsMainFrame: action.targetFrame?.isMainFrame, kind: kind,
                             modifiers: modifiers, buttonNumber: action.buttonNumber,
                             requestsDownload: action.shouldPerformDownload,
                             isServerRedirect: flag("_isRedirect", on: action),
                             contentRuleRedirect: ruleRedirect(action))
    }

    private static func flag(_ key: String, on action: WKNavigationAction) -> Bool {
        action.responds(to: NSSelectorFromString(key)) && (action.value(forKey: key) as? Bool) == true
    }

    /// Whether a navigation to an extension's page is a content rule's
    /// redirect, which no page can make; WebKit says so only privately,
    /// each asked first. It makes one two ways (seen on macOS 27.0.1): a
    /// navigation of its own, marked, once the site's is dropped (no
    /// original site here: the site is the one the tab was going to); or,
    /// for a load eGlu asked for in a view that has a page, the request
    /// rewritten before it is decided, the address asked for kept as its
    /// original: that address's site. nil for anything else, a server's
    /// redirect included.
    private static func ruleRedirect(_ action: WKNavigationAction) -> WebContentRuleRedirect? {
        if flag("_isContentExtensionRedirect", on: action) || flag("isContentRuleListRedirect", on: action) {
            return WebContentRuleRedirect(originalSite: nil)
        }
        guard !flag("_isRedirect", on: action), action.responds(to: NSSelectorFromString("_originalURL")),
              let original = action.value(forKey: "_originalURL") as? URL, original != action.request.url,
              let site = site(of: original)
        else { return nil }
        return WebContentRuleRedirect(originalSite: site)
    }

    private static func site(of url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        parts.path = "/"
        return parts.url
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        var replied = false
        policy?.decideNavigation(snapshot(navigationAction)) { decision in
            guard !replied else { return }
            replied = true
            switch decision {
            case .allow: decisionHandler(.allow)
            case .cancel: decisionHandler(.cancel)
            case .download: decisionHandler(.download)
            }
        }
        // A missing policy or a policy that returned without replying must not
        // leave WebKit waiting; and a late reply must not answer WebKit twice.
        if !replied {
            replied = true
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let response = WebResponse(response: navigationResponse.response,
                                   isForMainFrame: navigationResponse.isForMainFrame,
                                   canShowMIMEType: navigationResponse.canShowMIMEType)
        Self.decideResponse(response, ask: { [self] response, reply in
            policy?.decideResponse(response, reply: reply)
        }, decisionHandler: decisionHandler)
    }

    // The escaping callback here lets the guard cover even a policy that
    // violates its synchronous contract. The public policy stays nonescaping.
    static func decideResponse(_ response: WebResponse,
                               ask: (WebResponse, @escaping @MainActor (WebResponseDecision) -> Void) -> Void,
                               decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        var replied = false
        ask(response) { decision in
            guard !replied else { return }
            replied = true
            switch decision {
            case .allow: decisionHandler(.allow)
            case .cancel: decisionHandler(.cancel)
            case .download: decisionHandler(.download)
            }
        }
        // A missing policy or a policy that returned without replying must not
        // leave WebKit waiting; and a late reply must not answer WebKit twice.
        if !replied {
            replied = true
            decisionHandler(.cancel)
        }
    }

    public func load(_ request: URLRequest) {
        view?.load(request)
    }

    public func tearDown() {
        if view?.navigationDelegate === self { view?.navigationDelegate = nil }
        view = nil
        policy = nil
        legacy = nil
    }
}
