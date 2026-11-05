import WebKit
import WebKitMacPlugin
import WebKitExtensions

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

    var extensionIsCapturing: Bool { ExtensionCaptureRuntime.screen(view) }
    func releaseExtensionCapture() { ExtensionCapture.shared.runtime.release(view) }

}
