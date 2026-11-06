#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit

/// `chrome.offscreen`: a page with a DOM for an extension's worker, which
/// has none, never a tab anyone sees. One for each extension in each space,
/// as Chrome allows one an extension; made, found and closed through the
/// same record, also while its page is loading. After Search's
/// (github.com/driceroland/Search, MIT, its ExtensionOffscreen.swift), keyed
/// by space and extension. One made to record (its reasons USER_MEDIA or
/// DISPLAY_MEDIA) records through ExtensionCapture, lent to its pill while
/// it does; any other is refused the camera, the microphone and the screen.
@MainActor
public final class ExtensionOffscreen: NSObject, WKNavigationDelegate, WKUIDelegate, WKWebExtensionTab {
    private static var documents: [String: ExtensionOffscreen] = [:]

    private static func key(_ id: String, _ space: UUID) -> String { "\(space.uuidString)/\(id)" }

    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    public static func create(_ path: String, reasons: Set<String> = [], for context: WKWebExtensionContext, in space: UUID,
                              scheme: String, host: any ExtensionAuxiliaryPageHost) async throws {
        let document = try make(path, reasons: reasons, for: context, in: space, scheme: scheme, host: host,
                                configuration: { context.webViewConfiguration })
        try await document.load()
    }

    // Tests supply a non-persistent configuration and a view that records loads.
    static func make(_ path: String, reasons: Set<String>, for context: WKWebExtensionContext, in space: UUID,
                       scheme: String, host: any ExtensionAuxiliaryPageHost,
                       configuration: () -> WKWebViewConfiguration?,
                       makeView: @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: $0, configuration: $1) }) throws -> ExtensionOffscreen {
        let key = key(context.uniqueIdentifier, space)
        guard documents[key] == nil else { throw Refused(why: "Only a single offscreen document may be created.") }
        guard let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
              url.scheme == context.baseURL.scheme, url.host() == context.baseURL.host(),
              url.user == nil, url.password == nil,
              let configuration = configuration(),
              prepare(configuration, reasons: reasons)
        else { throw Refused(why: "The offscreen document must belong to this extension.") }
        let document = ExtensionOffscreen(context: context, space: space, url: url, key: key,
                                          configuration: configuration, scheme: scheme, host: host, makeView: makeView)
        document.reasons = reasons
        // Its place taken before the first wait, so two at once can't
        // leave two pages for one extension.
        documents[key] = document
        // WebKit needs a tab for it to know the content scripts in its
        // frames. Only it knows of this one; no window lists it.
        context.didOpenTab(document)
        return document
    }

    public static func close(_ id: String, in space: UUID) {
        documents[key(id, space)]?.close(error: Refused(why: "The offscreen document was closed."))
    }

    /// Every one of a space's, when the space goes; or of every space, when
    /// the extension does.
    public static func closeAll(in space: UUID? = nil, of id: String? = nil) {
        for document in documents.values where (space == nil || document.space == space) && (id == nil || document.extensionID == id) {
            document.close(error: Refused(why: "The offscreen document was closed."))
        }
    }

    public static func hasDocument(_ id: String, in space: UUID) -> Bool { documents[key(id, space)] != nil }

    /// The reasons an offscreen document was made for, when `web` is one's
    /// page; nil for any other page.
    public static func reasons(of web: NSView) -> Set<String>? {
        documents.values.first { $0.web === web }?.reasons
    }

    /// Where it is now, for the extension's list of its own pages.
    public static func url(_ id: String, in space: UUID) -> URL? {
        documents[key(id, space)].flatMap { $0.ready ? $0.web.url : nil }
    }

    /// What runtime.getContexts says of it.
    public static func contexts(_ id: String, in space: UUID, matching filter: [String: Any]) -> [[String: Any]] {
        guard let document = documents[key(id, space)], document.ready else { return [] }
        let value = document.record
        let fields = ["contextIds": "contextId", "contextTypes": "contextType",
                      "documentIds": "documentId", "documentOrigins": "documentOrigin",
                      "documentUrls": "documentUrl", "frameIds": "frameId",
                      "tabIds": "tabId", "windowIds": "windowId"]
        for (plural, singular) in fields {
            guard let asked = filter[plural] else { continue }
            guard let choices = asked as? NSArray, let actual = value[singular], choices.contains(actual) else { return [] }
        }
        if let incognito = filter["incognito"] as? Bool, incognito { return [] }
        return [value]
    }

    static func prepare(_ configuration: WKWebViewConfiguration, reasons: Set<String>) -> Bool {
        guard let preferences = configuration.preferences.copy() as? WKPreferences else { return false }
        // It has no window by design: its DOM and its answers keep working,
        // with WebKit's throttling of pages out of sight still on.
        preferences.inactiveSchedulingPolicy = .throttle
        // One made to listen may start the microphone with no focus: it has
        // no window to have it (ExtensionCapture lends it the pill's).
        if reasons.contains("USER_MEDIA") { ExtensionCaptureRuntime.set("_setGetUserMediaRequiresFocus:", false, in: preferences) }
        configuration.preferences = preferences
        return true
    }

    private let scheme: String
    private let host: any ExtensionAuxiliaryPageHost
    private let extensionID: String
    private let space: UUID
    private let key: String
    private weak var extensionContext: WKWebExtensionContext?
    private let url: URL
    private let contextID = UUID().uuidString
    private let documentID = UUID().uuidString
    let web: WKWebView
    /// What it was made for (offscreen.createDocument's reasons).
    private var reasons: Set<String> = []
    private var loading: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var closed = false
    private var ready = false

    private var record: [String: Any] {
        ["contextId": contextID, "contextType": "OFFSCREEN_DOCUMENT",
         "documentId": documentID, "documentUrl": url.absoluteString,
         "documentOrigin": "\(url.scheme ?? "")://\(url.host() ?? "")",
         "frameId": 0, "tabId": -1, "windowId": -1, "incognito": false]
    }

    init(context: WKWebExtensionContext, space: UUID, url: URL, key: String, configuration: WKWebViewConfiguration,
         scheme: String, host: any ExtensionAuxiliaryPageHost,
         makeView: @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: $0, configuration: $1) }) {
        self.scheme = scheme
        self.host = host
        extensionContext = context
        extensionID = context.uniqueIdentifier
        self.space = space
        self.key = key
        self.url = url
        web = makeView(CGRect(x: 0, y: 0, width: 800, height: 600), configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.close(error: Refused(why: "The offscreen document did not finish loading."))
            }
            web.load(URLRequest(url: url))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        deadline?.cancel()
        deadline = nil
        let continuation = loading
        loading = nil
        continuation?.resume(with: result)
    }

    private func close(error: Error) {
        guard !closed else { return }
        closed = true
        if Self.documents[key] === self { Self.documents[key] = nil }
        extensionContext?.didCloseTab(self, windowIsClosing: false)
        // What it records ends with it, and the pill gives its view back.
        host.releaseExtensionPage(web)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
        finish(.failure(error))
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, !ready else { return }
        ready = true
        finish(.success(()))
    }

    // The document stays on the extension's own pages, as Chrome keeps it:
    // a site loaded in its place would run out of sight, for as long as it
    // liked, with the extension's configuration. Its frames may go
    // anywhere; reading sites in them is what it is for. Nothing is saved
    // from it: no one asked for a file from a page no one sees.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
        guard navigationAction.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
        let to = navigationAction.request.url
        decisionHandler(to?.scheme == url.scheme && to?.host() == url.host() ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    // Only its first page failing ends it: once it is there, a later
    // navigation that fails leaves it where it was.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !ready { close(error: error) }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !ready { close(error: error) }
    }

    /// The camera or the microphone: only for one made to record, asked on
    /// the window in front, naming the extension, and watched for the pill
    /// while it lasts. Any other gets neither.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // The extension's own page asking, not a site framed in it: the
        // question names the extension, so only the extension may have it.
        guard reasons.contains("USER_MEDIA"), origin.protocol.lowercased() == scheme,
              origin.host.lowercased() == extensionID.lowercased() else {
            return decisionHandler(.deny)
        }
        let name = extensionContext?.webExtension.displayName ?? String(localized: "An extension")
        let media: ExtensionPageMedia
        switch type {
        case .camera: media = .camera
        case .microphone: media = .microphone
        default: media = .cameraAndMicrophone
        }
        host.requestExtensionMedia(media, name: name) { yes in
            if yes { self.host.watchExtensionPage(webView, id: self.extensionID) }
            decisionHandler(yes ? .grant : .deny)
        }
    }

    /// The screen: yes only while eGlu's own recording call is under way in
    /// this page (ExtensionCapture), no otherwise.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    public func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        MainActor.assumeIsolated { decisionHandler(host.extensionDisplayDecision(for: web)) }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close(error: Refused(why: "The offscreen document's web process exited."))
    }

    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { nil }
    public func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    public func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    public func title(for context: WKWebExtensionContext) -> String? { web.title }
    public func url(for context: WKWebExtensionContext) -> URL? { web.url }
    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    public func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    public func close(for context: WKWebExtensionContext) async throws { close(error: Refused(why: "The offscreen document was closed.")) }
}
#endif
