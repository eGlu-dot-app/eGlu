import AppKit

/// A page's view, as the host sees it: an NSView to place, size, move
/// between windows and focus (Docs/EngineSplitPlan.md 5.3).
@MainActor public protocol WebEngineSurface: AnyObject {
    /// The engine's own view, never a wrapper. Key events, the responder
    /// chain and appearance stay the view's.
    var view: NSView { get }
    /// Makes the view its window's first responder.
    func focus()
}
