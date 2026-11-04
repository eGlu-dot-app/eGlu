import WebKit
import WebKitMacPlugin

/// The app files that still need WebKit use this until their slices move.
typealias PageView = WebKitPageView

extension Page {
    /// WebKit returns the same content world for the same name.
    static let world = WKContentWorld.world(name: "eGlu")

    var view: PageView {
        guard let page = enginePage as? WebKitMacPage else {
            preconditionFailure("Page.view requires a WebKitMacPage")
        }
        return page.webView
    }

    var extensionIsCapturing: Bool { ExtensionCapture.screen(view) }
    func releaseExtensionCapture() { ExtensionCapture.shared.release(view) }

    // MARK: An extension's own page, for its recording (ExtensionCapture)

    /// Whether an extension's own page is seen, as WebKit counts it; never
    /// asked of a website's.
    static func extensionPageVisible(_ web: WKWebView) async -> Bool {
        guard web.url?.scheme?.lowercased() == Extensions.scheme else { return false }
        return (try? await web.evaluateJavaScript("document.visibilityState")) as? String == "visible"
    }

    /// The shim's recording call in an extension's own page, made by the
    /// app so WebKit counts it as a click (ExtensionCapture.force); never in
    /// a website's.
    static func startExtensionRecording(in web: WKWebView, token: String, video: Any) async throws -> Any? {
        guard web.url?.scheme?.lowercased() == Extensions.scheme else { return nil }
        return try await web.callAsyncJavaScript("return await globalThis[Symbol.for('eglu.capture')](token, video);",
                                                 arguments: ["token": token, "video": video], in: nil, contentWorld: .page)
    }

}
