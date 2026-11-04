import AppKit
import PadCore
import WebKit
import WebKitExtensions

/// chrome.identity.launchWebAuthFlow: an extension's sign-in through its
/// provider's page, in the space the extension asked from. The moment the
/// page heads for the extension's own https://<id>.chromiumapp.org/, that
/// address is the answer; nothing is ever loaded from chromiumapp.org.
/// A flow that says it is interactive gets a tab in front; one that
/// doesn't runs out of sight, as Chrome runs it. (Search's ExtensionAuth)
@MainActor
enum ExtensionAuth {
    /// A sign-in waiting for its answer, by space and extension: one at a
    /// time for each, a new one ending the last, as in Chrome.
    private struct Flow {
        let tab: UUID
        let finish: (Result<URL, Error>) -> Void
        let watch: Timer
    }

    private static var waiting: [String: Flow] = [:]
    private static var quiet: [String: Quiet] = [:]

    private static func key(_ id: String, _ space: UUID) -> String {
        "\(space.uuidString)/\(id.lowercased())"
    }

    /// Chrome's words for each way a flow ends without an answer.
    static let declined = "The user did not approve access."
    static let notLoaded = "Authorization page could not be loaded."
    static let needsUser = "User interaction required."

    /// The extension a chromiumapp.org address belongs to: https, and one
    /// name before chromiumapp.org.
    static func owner(of url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              host.hasSuffix(".chromiumapp.org") else { return nil }
        let id = String(host.dropLast(".chromiumapp.org".count))
        return id.isEmpty || id.contains(".") ? nil : id
    }

    /// Any chromiumapp.org address, whosever and however sent.
    static func chromiumapp(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        return bare == "chromiumapp.org" || bare.hasSuffix(".chromiumapp.org")
    }

    // MARK: In a tab

    /// The provider's page in a tab in front. Closing the tab is saying no;
    /// so is ten minutes with nobody finishing. A page that can't load ends
    /// it at once (loadFailed).
    static func run(_ url: URL, extension id: String, context: WKWebExtensionContext, in space: UUID) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Extensions.Unanswered(why: notLoaded) }
        let key = key(id, space)
        return try await withCheckedThrowingContinuation { continuation in
            // The last one's tab goes with it: its page can't finish anything now.
            let superseded = waiting[key]?.tab
            end(key, .failure(Extensions.Unanswered(why: declined)))
            if let superseded, Session.shared.workspace.tab(superseded) != nil { Session.shared.closeTab(superseded) }
            guard let tab = Extensions.shared.tabs.open(url, in: space, active: true, pinned: false, context: context) else {
                return continuation.resume(throwing: Extensions.Unanswered(why: notLoaded))
            }
            inFront(tab.id, in: space)
            let started = Date()
            let watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let flow = waiting[key], flow.tab == tab.id else { return }
                    if Session.shared.workspace.tab(flow.tab) == nil || Date().timeIntervalSince(started) > 600 {
                        end(key, .failure(Extensions.Unanswered(why: declined)))
                    }
                }
            }
            waiting[key] = Flow(tab: tab.id, finish: { continuation.resume(with: $0) }, watch: watch)
        }
    }

    /// The sign-in's tab where the person can see it: in a window on its
    /// space, brought forward, or in a new one when none shows the space.
    private static func inFront(_ tab: UUID, in space: UUID) {
        let session = Session.shared
        if let window = session.allWindows.first(where: { $0.shows(tab) }) ?? session.allWindows.first(where: { $0.spaceID == space }) {
            window.select(tab)
            window.window?.makeKeyAndOrderFront(nil)
        } else {
            session.openWindow?(space)
        }
    }

    /// The flow's tab couldn't load its page: the flow ends now, as
    /// Chrome's does, not ten minutes on.
    static func loadFailed(_ page: Page) {
        guard let (key, _) = waiting.first(where: { $0.value.tab == page.tab && Session.shared.workspace.spaceID(of: page.tab) == page.space })
        else { return }
        end(key, .failure(Extensions.Unanswered(why: notLoaded)))
    }

    private static func end(_ key: String, _ result: Result<URL, Error>) {
        guard let flow = waiting.removeValue(forKey: key) else { return }
        flow.watch.invalidate()
        flow.finish(result)
    }

    /// Whether `url`, on an extension's chromiumapp.org, is the answer a
    /// flow waits for: arriving in the tab the flow began in, or in a
    /// window that tab's page opened, since some providers finish in a
    /// pop-up. Any page can head for such an address, and what it carries
    /// would be taken for the answer: only those two may finish it. The
    /// tab goes, and the pop-up with it.
    static func intercept(_ url: URL, page: Page) -> Bool {
        guard let id = owner(of: url) else { return false }
        let key = key(id, page.space)
        guard let flow = waiting[key], page.tab == flow.tab || page.openedFrom == flow.tab else { return false }
        end(key, .success(url))
        DispatchQueue.main.async {
            if page.tab != flow.tab { page.host?.pageDidClose(page) }
            if Session.shared.workspace.tab(flow.tab) != nil { Session.shared.closeTab(flow.tab) }
        }
        return true
    }

    /// The same address with no flow waiting for it. Some extensions open
    /// the provider's page with tabs.create and watch that tab until it
    /// reaches their chromiumapp.org address, then close it (Figma's). In
    /// Chrome the load fails onto an error page that still carries the
    /// address, which tabs.onUpdated reports; in WebKit a failed load never
    /// commits, so nothing would. The tab takes the address without loading
    /// anything (Page.hold), for an extension on in the space that asked
    /// for identity; what each extension sees of it is WebKit's call, as
    /// for any address.
    static func handOver(_ url: URL, page: Page) -> Bool {
        // A tab's page, or an extension's popup window's (windows.create).
        let shown = Session.shared.workspace.spaceID(of: page.tab) == page.space || ExtensionPopupWindow.showing(page) != nil
        guard let id = owner(of: url), shown,
              let context = Extensions.shared.context(id, in: page.space), Extensions.asks(context, for: "identity")
        else { return false }
        page.hold(url)
        return true
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
    static func quietly(_ url: URL, extension id: String, in space: UUID, abortOnLoad: Bool, timeout: TimeInterval?) async throws -> URL {
        guard Quiet.secure(url) else { throw Extensions.Unanswered(why: notLoaded) }
        let key = key(id, space)
        let limit = min(max(timeout ?? Quiet.longest, 0.5), Quiet.longest)
        return try await withCheckedThrowingContinuation { continuation in
            quiet[key]?.end(.failure(Extensions.Unanswered(why: needsUser)))
            let flow = Quiet(extensionID: id, abortOnLoad: abortOnLoad) { result in
                quiet[key] = nil
                continuation.resume(with: result)
            }
            quiet[key] = flow
            flow.start(url, in: space, limit: limit)
        }
    }

    /// The view and its watcher for one flow out of sight.
    @MainActor
    final class Quiet: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// The longest a flow may run out of sight, whatever it asks.
        static let longest: TimeInterval = 60

        /// The space's cookies go only over https here, nobody watching:
        /// plain http only to this Mac itself.
        static func secure(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased() else { return false }
            if scheme == "https" { return true }
            let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
        }

        let extensionID: String
        let abortOnLoad: Bool
        private var finish: ((Result<URL, Error>) -> Void)?
        private var view: WKWebView?
        private var timer: Timer?

        init(extensionID: String, abortOnLoad: Bool, finish: @escaping (Result<URL, Error>) -> Void) {
            self.extensionID = extensionID.lowercased()
            self.abortOnLoad = abortOnLoad
            self.finish = finish
        }

        func start(_ url: URL, in space: UUID, limit: TimeInterval) {
            // The space's sign-ins and user agent, as its tabs have; no
            // extension, and no script of eGlu's: such a flow often goes
            // through Google's sign-in, which eGlu never touches (HandsOff).
            let config = Session.shared.engine.configuration(space: space)
            config.webExtensionController = nil
            // Nobody can click here: nothing plays.
            config.mediaTypesRequiringUserActionForPlayback = .all
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            view.navigationDelegate = self
            // Without a UI delegate WebKit puts up its own question for the
            // camera, the microphone or the screen; here every one is no.
            view.uiDelegate = self
            self.view = view
            timer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.end(.failure(Extensions.Unanswered(why: ExtensionAuth.needsUser))) }
            }
            view.load(URLRequest(url: url))
        }

        /// The extension's own address, and nobody else's.
        private func answer(_ url: URL?) -> Bool {
            guard ExtensionAuth.owner(of: url) == extensionID, let url else { return false }
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
            if ExtensionAuth.chromiumapp(action.request.url) {
                decisionHandler(.cancel)
                if main { end(.failure(Extensions.Unanswered(why: ExtensionAuth.notLoaded))) }
                return
            }
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            let fine = main ? Self.secure(action.request.url) : ["http", "https", "about", "data", "blob"].contains(scheme)
            guard !action.shouldPerformDownload, action.targetFrame != nil, fine else {
                if main, !Self.secure(action.request.url) { end(.failure(Extensions.Unanswered(why: ExtensionAuth.notLoaded))) }
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
            if ExtensionAuth.chromiumapp(webView.url) || !Self.secure(webView.url) {
                webView.stopLoading()
                end(.failure(Extensions.Unanswered(why: ExtensionAuth.notLoaded)))
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
            if abortOnLoad { end(.failure(Extensions.Unanswered(why: ExtensionAuth.needsUser))) }
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
            end(.failure(Extensions.Unanswered(why: ExtensionAuth.notLoaded)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            end(.failure(Extensions.Unanswered(why: ExtensionAuth.notLoaded)))
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
