import AppKit
import WebEngineCore

@MainActor public protocol WebPageUIEvents: AnyObject {
    /// A site asked for a window of its own. Return the child's surface,
    /// made from `request` before returning, or nil to refuse it.
    func childRequested(_ request: any WebChildRequest) -> (any WebEngineSurface)?
    /// A script closed the page's window.
    func closeRequested()
    /// A context menu is about to open over an element; `link` is the
    /// element's link, nil where it has none or the engine does not say.
    func contextMenuOpening(link: URL?)
    /// A scroll the page left unused (only an engine with the
    /// `correlatedUnusedWheelEvents` trait reports these).
    func scrollNotHandled(_ event: NSEvent)
}
