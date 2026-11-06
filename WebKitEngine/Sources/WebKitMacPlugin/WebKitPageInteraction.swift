import AppKit
import WebEngineAppKit
import WebKit

/// Holds neither the page nor its view alive, as the app's swipe did.
@MainActor
public final class WebKitPageInteraction: WebSwipe, WebPageCoordinates {
    private weak var view: WKWebView?

    public init(view: WKWebView) { self.view = view }

    /// `_WKRectEdge`'s four bits. The app knows only the named edges.
    private static let flags: [(WebPageEdge, UInt)] = [(.left, 1), (.top, 2), (.right, 4), (.bottom, 8)]

    public var pinnedEdges: Set<WebPageEdge> {
        let flags = (view?.value(forKey: "pinnedState") as? NSNumber)?.uintValue ?? 0
        return Set(Self.flags.compactMap { flags & $0.1 != 0 ? $0.0 : nil })
    }

    public var isInFullscreen: Bool { view?.fullscreenState != .notInFullscreen }

    public func setRubberBandingEnabled(_ edges: Set<WebPageEdge>) {
        let flags = Self.flags.reduce(UInt(0)) { edges.contains($1.0) ? $0 | $1.1 : $0 }
        // The key without its underscore finds `_setRubberBandingEnabled:`.
        view?.setValue(NSNumber(value: flags), forKey: "rubberBandingEnabled")
    }

    public func screenRect(of rect: CGRect, zoom: CGFloat) -> CGRect? {
        guard let view, let window = view.window else { return nil }
        let scaled = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        let local = view.isFlipped ? scaled : CGRect(x: scaled.minX, y: view.bounds.height - scaled.maxY, width: scaled.width, height: scaled.height)
        return window.convertToScreen(view.convert(local, to: nil))
    }
}
