import AppKit
import WebEngineCore

public enum WebPageEdge: Sendable, Hashable, CaseIterable { case left, top, right, bottom }

/// The page's edges, read and written synchronously before the engine handles
/// the scroll. Each engine keeps its own representation behind this service.
@MainActor public protocol WebSwipe: AnyObject {
    var pinnedEdges: Set<WebPageEdge> { get }
    var isInFullscreen: Bool { get }
    func setRubberBandingEnabled(_ edges: Set<WebPageEdge>)
}

/// A field's CSS pixels from the page's top left, in screen coordinates.
@MainActor public protocol WebPageCoordinates: AnyObject {
    /// nil while the view is in no window. The caller supplies page zoom
    /// times pinch magnification, as it does when placing its card.
    func screenRect(of rect: CGRect, zoom: CGFloat) -> CGRect?
}

/// A child page for the site's picture window, made synchronously from the
/// engine's child request. The host owns the window and its product rules.
@MainActor public protocol WebPicturePage: WebEngineSurface {
    func connect(events: any WebPicturePageEvents)
    /// Detaches both delegates and removes the view, without stopping its
    /// load: releasing the child lets the site's pagehide run as before.
    func tearDown()
}

@MainActor public protocol WebPicturePageEvents: AnyObject {
    /// Reply before returning. The host can open a tab after cancelling.
    func decidePictureNavigation(url: URL?, targetIsMainFrame: Bool,
                                 reply: @MainActor (Bool) -> Void)
    func pictureRequestedWindow(url: URL?)
    func pictureCloseRequested()
    func pictureProcessEnded()
}
