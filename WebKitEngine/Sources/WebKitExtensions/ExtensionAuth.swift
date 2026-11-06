#if os(macOS)
import AppKit
import WebKit

/// An extension's sign-in addresses and the flow that runs out of sight.
/// The app supplies the space's configuration and the error it used before.
@MainActor
public enum WebKitExtensionAuth {
    private static var quiet: [String: Quiet] = [:]

    private static func key(_ id: String, _ space: UUID) -> String {
        "\(space.uuidString)/\(id.lowercased())"
    }

    public static let notLoaded = "Authorization page could not be loaded."
    public static let needsUser = "User interaction required."

    /// The extension a chromiumapp.org address belongs to: https, and one
    /// name before chromiumapp.org.
    public static func owner(of url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              host.hasSuffix(".chromiumapp.org") else { return nil }
        let id = String(host.dropLast(".chromiumapp.org".count))
        return id.isEmpty || id.contains(".") ? nil : id
    }

    /// Any chromiumapp.org address, whosever and however sent.
    public static func chromiumapp(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        return bare == "chromiumapp.org" || bare.hasSuffix(".chromiumapp.org")
    }

    /// The space's cookies go only over https here, nobody watching:
    /// plain http only to this Mac itself.
    public static func secure(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    // MARK: Out of sight

    /// A flow that doesn't say it is interactive, as Chrome runs one: the
    /// provider's page loads in a view never on screen, signed in as the
    /// space's tabs are, and the flow ends the moment it heads for this
    /// extension's own chromiumapp.org address, or fails without a word to
    /// anyone once the page has loaded (unless the extension asked to wait)
    /// or the time is up, a minute at most. Claude in Chrome restores its
    /// sign-in this way each time the browser starts.
    ///
    /// No more than a tab opened behind would allow, which any extension
    /// may open: an http(s) page with the space's cookies, for a minute. It
    /// learns only the address it is sent to on its own chromiumapp.org,
    /// never the page; the page gets no extension, no window, question,
    /// download or app, and no other scheme.
    /// The configuration is requested inline after supersession and
    /// registration, before the plugin changes any of its settings.
    public static func quietly(_ url: URL, extension id: String, in space: UUID, abortOnLoad: Bool, timeout: TimeInterval?,
                               configuration: () -> WKWebViewConfiguration,
                               unanswered: @escaping (String) -> Error,
                               makeView: @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: $0, configuration: $1) }) async throws -> URL {
        guard secure(url) else { throw unanswered(notLoaded) }
        let key = key(id, space)
        let limit = min(max(timeout ?? Quiet.longest, 0.5), Quiet.longest)
        return try await withCheckedThrowingContinuation { continuation in
            quiet[key]?.end(.failure(unanswered(needsUser)))
            let flow = Quiet(extensionID: id, abortOnLoad: abortOnLoad, unanswered: unanswered) { result in
                quiet[key] = nil
                continuation.resume(with: result)
            }
            quiet[key] = flow
            flow.start(url, configuration: configuration, limit: limit, makeView: makeView)
        }
    }

    /// The view and its watcher for one flow out of sight.
    @MainActor
    final class Quiet: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// The longest a flow may run out of sight, whatever it asks.
        static let longest: TimeInterval = 60

        let extensionID: String
        let abortOnLoad: Bool
        private let unanswered: (String) -> Error
        private var finish: ((Result<URL, Error>) -> Void)?
        private(set) var view: WKWebView?
        private var timer: Timer?

        init(extensionID: String, abortOnLoad: Bool, unanswered: @escaping (String) -> Error, finish: @escaping (Result<URL, Error>) -> Void) {
            self.unanswered = unanswered
            self.extensionID = extensionID.lowercased()
            self.abortOnLoad = abortOnLoad
            self.finish = finish
        }

        func start(_ url: URL, configuration: () -> WKWebViewConfiguration, limit: TimeInterval,
                   makeView: @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: $0, configuration: $1) }) {
            // The space's sign-ins and user agent, as its tabs have; no
            // extension, and no script of eGlu's: such a flow often goes
            // through Google's sign-in, which eGlu never touches (HandsOff).
            let config = configuration()
            config.webExtensionController = nil
            // Nobody can click here: nothing plays.
            config.mediaTypesRequiringUserActionForPlayback = .all
            let view = makeView(CGRect(x: 0, y: 0, width: 800, height: 600), config)
            view.navigationDelegate = self
            // Without a UI delegate WebKit puts up its own question for the
            // camera, the microphone or the screen; here every one is no.
            view.uiDelegate = self
            self.view = view
            timer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.end(.failure(self.unanswered(WebKitExtensionAuth.needsUser)))
                }
            }
            view.load(URLRequest(url: url))
        }

        /// The extension's own address, and nobody else's.
        private func answer(_ url: URL?) -> Bool {
            guard WebKitExtensionAuth.owner(of: url) == extensionID, let url else { return false }
            end(.success(url))
            return true
        }

        func end(_ result: Result<URL, Error>) {
            guard let finish else { return }
            self.finish = nil
            timer?.invalidate()
            timer = nil
            if let view {
                view.navigationDelegate = nil
                view.uiDelegate = nil
                view.stopLoading()
            }
            view = nil
            finish(result)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let main = action.targetFrame?.isMainFrame ?? true
            if main, answer(action.request.url) { return decisionHandler(.cancel) }
            // Any other chromiumapp.org address (another extension's, this
            // one's over http) never loads: what it carries, a code or a
            // token, would go out over the network.
            if WebKitExtensionAuth.chromiumapp(action.request.url) {
                decisionHandler(.cancel)
                if main { end(.failure(unanswered(WebKitExtensionAuth.notLoaded))) }
                return
            }
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            let fine = main ? WebKitExtensionAuth.secure(action.request.url) : ["http", "https", "about", "data", "blob"].contains(scheme)
            guard !action.shouldPerformDownload, action.targetFrame != nil, fine else {
                if main, !WebKitExtensionAuth.secure(action.request.url) { end(.failure(unanswered(WebKitExtensionAuth.notLoaded))) }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if answer(webView.url) { return webView.stopLoading() }
            // Elsewhere on chromiumapp.org, or down to plain http: stopped.
            if WebKitExtensionAuth.chromiumapp(webView.url) || !WebKitExtensionAuth.secure(webView.url) {
                webView.stopLoading()
                end(.failure(unanswered(WebKitExtensionAuth.notLoaded)))
            }
        }

        // A site asking who you are, or for a client certificate, gets no
        // answer: that is asking the person. The server's certificate is
        // checked as usual.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A page meant to be seen: Chrome's flow ends here, unless the
            // extension asked to wait for a script to move on.
            if abortOnLoad { end(.failure(unanswered(WebKitExtensionAuth.needsUser))) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        /// A load cancelled here, or replaced by the page's next one, isn't
        /// the page failing.
        private func failed(_ error: Error) {
            let error = error as NSError
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain", error.code == 102 { return }
            end(.failure(unanswered(WebKitExtensionAuth.notLoaded)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            end(.failure(unanswered(WebKitExtensionAuth.notLoaded)))
        }

        // MARK: Nothing to show, nothing to ask

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            completionHandler(false)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
            completionHandler(nil)
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
            completionHandler(nil)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
        func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                            decisionHandler: @escaping (Int) -> Void) {
            decisionHandler(0)
        }

        @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
        func location(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                      decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
        func notifications(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
            decisionHandler(false)
        }
    }
}
#endif
