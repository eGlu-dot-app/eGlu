import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit
@testable import WebKitMacPlugin
import XCTest

@MainActor
private final class InteractionView: WKWebView {
    var reads: [String] = []
    var writes: [(String, UInt)] = []

    override func value(forKey key: String) -> Any? {
        if key == "pinnedState" {
            MainActor.assumeIsolated { reads.append(key) }
            return NSNumber(value: 5)
        }
        return super.value(forKey: key)
    }

    override func setValue(_ value: Any?, forKey key: String) {
        if key == "rubberBandingEnabled" {
            let edges = (value as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated { writes.append((key, edges)) }
            return
        }
        super.setValue(value, forKey: key)
    }
}

final class WebKitInteractionTests: XCTestCase {
    @MainActor private func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return config
    }

    @MainActor
    func testTraitsMatchThisWebKitsSelectors() {
        let page = WebKitMacPage(configuration: configuration())
        defer { page.tearDown() }
        let view = page.webView
        XCTAssertNil(view.window)
        XCTAssertTrue(page.traits.contains(.isolatedScripts))
        XCTAssertTrue(page.traits.contains(.documentPictureInPicture))
        let rubber = ["_pinnedState", "_setRubberBandingEnabled:"].allSatisfy { view.responds(to: NSSelectorFromString($0)) }
        XCTAssertEqual(page.traits.contains(.rubberBandControl), rubber)
        XCTAssertEqual(page.swipe != nil, rubber)
        // The adapter supplies the two private callbacks; each element's
        // hit-test selectors are still checked when its menu arrives.
        let adapter = WebKitUIAdapter(view: view, events: InteractionEvents(), presenter: InteractionPresenter())
        XCTAssertEqual(page.traits.contains(.correlatedUnusedWheelEvents),
                       adapter.responds(to: NSSelectorFromString("_webView:didNotHandleWheelEvent:")))
        XCTAssertEqual(page.traits.contains(.contextMenuElement), adapter.responds(to: NSSelectorFromString(
            "_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:")))
        XCTAssertEqual(page.traits.contains(.videoPictureInPicture),
                       view.configuration.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")))
    }

    @MainActor
    func testSwipeUsesTheSameKVCKeysAndEdgeValuesSynchronously() {
        let view = InteractionView(frame: .zero, configuration: configuration())
        let service = WebKitPageInteraction(view: view)
        XCTAssertNil(view.window)
        service.setRubberBandingEnabled(Set(WebPageEdge.allCases))
        service.setRubberBandingEnabled([])
        service.setRubberBandingEnabled([.top, .bottom])
        XCTAssertEqual(view.writes.map { $0.0 }, Array(repeating: "rubberBandingEnabled", count: 3))
        XCTAssertEqual(view.writes.map { $0.1 }, [15, 0, 10])
        XCTAssertEqual(service.pinnedEdges, [.left, .right])
        XCTAssertEqual(view.reads, ["pinnedState"])
        XCTAssertEqual(service.isInFullscreen, view.fullscreenState != .notInFullscreen)
    }

    @MainActor
    func testSwipePrivateCallsOnARealViewWithoutAWindow() throws {
        let page = WebKitMacPage(configuration: configuration())
        defer { page.tearDown() }
        guard let swipe = page.swipe else { throw XCTSkip("This WebKit lacks rubber-band control") }
        XCTAssertNil(page.contentView.window)
        swipe.setRubberBandingEnabled(Set(WebPageEdge.allCases))
        swipe.setRubberBandingEnabled([])
        let raw = (page.webView.value(forKey: "pinnedState") as? NSNumber)?.uintValue ?? 0
        let flags: [(WebPageEdge, UInt)] = [(.left, 1), (.top, 2), (.right, 4), (.bottom, 8)]
        XCTAssertEqual(swipe.pinnedEdges, Set(flags.compactMap { raw & $0.1 != 0 ? $0.0 : nil }))
        swipe.setRubberBandingEnabled(Set(WebPageEdge.allCases))
    }

    @MainActor
    func testApplePasswordsCoordinatesWithoutAWindowAtBothZooms() throws {
        let page = WebKitMacPage(configuration: configuration())
        defer { page.tearDown() }
        let coordinates = try XCTUnwrap(page.coordinates)
        let field = CGRect(x: 13, y: 29, width: 120, height: 24)
        for zoom in [CGFloat(1), 2] {
            page.services.pageZoom = Double(zoom)
            XCTAssertNil(page.contentView.window)
            XCTAssertNil(coordinates.screenRect(of: field, zoom: zoom))
        }
    }

    @MainActor
    func testApplePasswordsCoordinatesInAnUnshownWindowKeepScalingAndConversion() throws {
        let page = WebKitMacPage(configuration: configuration())
        let window = NSWindow(contentRect: NSRect(x: 71, y: 93, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = page.contentView
        defer { page.tearDown(); window.contentView = nil; window.close() }
        XCTAssertFalse(window.isVisible)
        let coordinates = try XCTUnwrap(page.coordinates)
        for zoom in [CGFloat(1), 2] {
            page.services.pageZoom = Double(zoom)
            let field = CGRect(x: 13, y: 29, width: 120, height: 24)
            let view = page.contentView
            let scaled = CGRect(x: 13 * zoom, y: 29 * zoom, width: 120 * zoom, height: 24 * zoom)
            let local = view.isFlipped ? scaled : CGRect(x: scaled.minX, y: view.bounds.height - scaled.maxY,
                                                        width: scaled.width, height: scaled.height)
            XCTAssertEqual(coordinates.screenRect(of: field, zoom: zoom), window.convertToScreen(view.convert(local, to: nil)))
            XCTAssertEqual(coordinates.screenRect(of: field, zoom: zoom)?.size, scaled.size)
        }
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testInteractionServiceDoesNotRetainTheView() {
        weak var weakView: WKWebView?
        let service = autoreleasepool {
            let view = WKWebView(frame: .zero, configuration: configuration())
            weakView = view
            return WebKitPageInteraction(view: view)
        }
        XCTAssertNil(weakView)
        XCTAssertNil(service.screenRect(of: .zero, zoom: 1))
    }
}

@MainActor
private final class InteractionEvents: WebPageUIEvents {
    func childRequested(_ request: any WebChildRequest) -> (any WebEngineSurface)? { nil }
    func closeRequested() {}
    func contextMenuOpening(link: URL?) {}
    func scrollNotHandled(_ event: NSEvent) {}
}

@MainActor
private final class InteractionPresenter: WebDialogPresenter {
    func alert(_ message: String, host: String, done: @escaping @MainActor () -> Void) { done() }
    func confirm(_ message: String, host: String, done: @escaping @MainActor (Bool) -> Void) { done(false) }
    func prompt(_ message: String, defaultText: String?, host: String, done: @escaping @MainActor (String?) -> Void) { done(nil) }
    func openFiles(allowsMultiple: Bool, allowsDirectories: Bool, done: @escaping @MainActor ([URL]?) -> Void) { done(nil) }
}
