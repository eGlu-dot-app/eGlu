import AppKit
import WebKitExtensions

extension ExtensionPopupWindow {
    nonisolated static func frame(asked: CGRect, on screen: CGRect) -> CGRect? {
        ExtensionHost.popupFrame(asked: asked, on: screen)
    }

    static func showing(_ page: Page) -> ExtensionPopupWindow? {
        showing(page.enginePage)
    }
}
