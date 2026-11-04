import WebEngineCore
import WebKit

/// A page's session held weakly, or a retry's hidden page kept for its owner.
@MainActor
public final class WebKitDownloadStarter: WebDownloadStarting {
    private weak var view: WKWebView?
    private let held: WKWebView?

    public init(view: WKWebView) {
        self.view = view
        held = nil
    }

    public init(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: configuration)
        self.view = view
        held = view
    }

    private init(keeping view: WKWebView) {
        self.view = view
        held = view
    }

    public func keepingSessionAlive() -> any WebDownloadStarting {
        guard held == nil, let view else { return self }
        return WebKitDownloadStarter(keeping: view)
    }

    public var canStartDownloads: Bool { view != nil }

    public func startDownload(using request: URLRequest,
                              completionHandler: @escaping @MainActor @Sendable (any WebEngineCore.WebDownload) -> Void) {
        view?.startDownload(using: request) { completionHandler(WebKitDownload($0)) }
    }

    public func resumeDownload(fromResumeData data: Data,
                               completionHandler: @escaping @MainActor @Sendable (any WebEngineCore.WebDownload) -> Void) {
        view?.resumeDownload(fromResumeData: data) { completionHandler(WebKitDownload($0)) }
    }
}
