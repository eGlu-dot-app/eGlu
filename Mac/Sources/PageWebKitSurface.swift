import AppKit
import WebEngineAppKit

/// The page's own web view, as its host places it and gives it the keys.
@MainActor
final class PageWebKitSurface: WebEngineSurface {
    let view: NSView

    init(view: NSView) {
        self.view = view
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }
}
