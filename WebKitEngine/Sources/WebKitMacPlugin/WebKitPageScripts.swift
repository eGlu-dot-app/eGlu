import WebEngineCore
import WebKit
import WebKitSupport

/// Kept separately so a measuring run holds only the view and controller,
/// as before, without extending the page's adapters or observations.
@MainActor
final class WebKitPageScripts: WebPageScripting {
    private let webView: WKWebView
    private let controller: WKUserContentController

    init(view: WKWebView, controller: WKUserContentController) {
        webView = view
        self.controller = controller
    }

    public func removeAllUserScripts() { controller.removeAllUserScripts() }

    public func addUserScript(source: String, injectionTime: WebInjection,
                              forMainFrameOnly: Bool, world: WebWorld) {
        controller.addUserScript(WKUserScript(source: source,
            injectionTime: injectionTime == .atDocumentStart ? .atDocumentStart : .atDocumentEnd,
            forMainFrameOnly: forMainFrameOnly, in: contentWorld(world)))
    }

    public func addFilterScripts(blocker: String?, scriptlets: String?) {
        controller.addFilterScripts(blocker: blocker, scriptlets: scriptlets, appWorld: WebKitMacPage.appWorld)
    }

    private func contentWorld(_ world: WebWorld) -> WKContentWorld {
        world == .app ? WebKitMacPage.appWorld : .page
    }

    public func evaluateJavaScript(_ source: String, world: WebWorld,
                                   completionHandler: (@MainActor (Result<Any, any Error>) -> Void)?) {
        webView.evaluateJavaScript(source, in: nil, in: contentWorld(world), completionHandler: completionHandler)
    }

    public func callAsyncJavaScript(_ body: String, arguments: [String: Any], world: WebWorld,
                                    completionHandler: (@MainActor (Result<Any, any Error>) -> Void)?) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: contentWorld(world),
                                   completionHandler: completionHandler)
    }

    public func callAsyncJavaScript(_ body: String, arguments: [String: Any], world: WebWorld) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: contentWorld(world))
    }
}
