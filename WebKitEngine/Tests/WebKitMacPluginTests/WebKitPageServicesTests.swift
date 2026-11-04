import AppKit
import WebEngineCore
import WebKit
import WebKitMacPlugin
import XCTest

@MainActor
private final class ServicesLoadDelegate: NSObject, WKNavigationDelegate {
    var completed: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completed?() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("Services fixture failed: \(error)")
        completed?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Services fixture failed before commit: \(error)")
        completed?()
    }
}

final class WebKitPageServicesTests: XCTestCase {
    @MainActor
    private func makeView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
    }

    @MainActor
    private func navigate(_ view: WKWebView, action: () -> Void) async {
        let delegate = ServicesLoadDelegate()
        let loaded = expectation(description: "services fixture loaded")
        delegate.completed = { loaded.fulfill() }
        view.navigationDelegate = delegate
        action()
        await fulfillment(of: [loaded], timeout: 10)
        view.navigationDelegate = nil
    }

    @MainActor
    private func find(_ text: String, in services: WebKitPageServices, backwards: Bool = false,
                      caseSensitive: Bool = false, wraps: Bool = true) async -> Bool {
        let completed = expectation(description: "find completed")
        var result = false
        services.find(text, backwards: backwards, caseSensitive: caseSensitive, wraps: wraps) {
            result = $0
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 10)
        return result
    }

    @MainActor
    private func fixtureURL(_ title: String) -> URL {
        URL(string: "data:text/html;base64," + Data("<!doctype html><title>\(title)</title><p>\(title)</p>".utf8).base64EncodedString())!
    }

    @MainActor
    func testCurrentEntryIsTheViewsOwnObjectBeforeAndAfterLoads() async throws {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        XCTAssertNil(services.currentEntry)
        XCTAssertNil(view.backForwardList.currentItem)
        await navigate(view) { view.load(URLRequest(url: fixtureURL("first"))) }
        let first = try XCTUnwrap(services.currentEntry)
        XCTAssertTrue(first === view.backForwardList.currentItem)
        await navigate(view) { view.load(URLRequest(url: fixtureURL("second"))) }
        let second = try XCTUnwrap(services.currentEntry)
        XCTAssertTrue(second === view.backForwardList.currentItem)
        XCTAssertFalse(first === second)
        XCTAssertTrue(first === view.backForwardList.backList.last)
        await navigate(view) { view.goBack() }
        XCTAssertTrue(services.currentEntry === view.backForwardList.currentItem)
        XCTAssertTrue(services.currentEntry === first)
    }

    @MainActor
    func testRestorationDataRestoresTheBackForwardListInANewView() async throws {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        let first = fixtureURL("restored first")
        let second = fixtureURL("restored second")
        await navigate(view) { view.load(URLRequest(url: first)) }
        await navigate(view) { view.load(URLRequest(url: second)) }
        let data = try XCTUnwrap(services.restorationData as? Data)
        let back = view.backForwardList.backList.map(\.url)
        let current = try XCTUnwrap(view.backForwardList.currentItem).url
        XCTAssertEqual(back, [first])
        XCTAssertEqual(current, second)

        let restored = makeView()
        defer { restored.stopLoading() }
        let restoredServices = WebKitPageServices(view: restored)
        await navigate(restored) { restoredServices.restorationData = data }
        XCTAssertEqual(restored.backForwardList.backList.map(\.url), back)
        XCTAssertEqual(restored.backForwardList.currentItem?.url, current)
        XCTAssertEqual(restored.url, current)
        XCTAssertTrue(restoredServices.currentEntry === restored.backForwardList.currentItem)
    }

    @MainActor
    func testFindForwardsBackwardsMissingTextAndCaseSensitivity() async {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        await navigate(view) {
            view.loadHTMLString("<!doctype html><p>First MiXeDcAsE last.</p>", baseURL: nil)
        }
        for backwards in [false, true] {
            let insensitive = await find("mixedcase", in: services, backwards: backwards)
            XCTAssertTrue(insensitive)
            let sensitive = await find("mixedcase", in: services, backwards: backwards, caseSensitive: true)
            XCTAssertFalse(sensitive)
            let exact = await find("MiXeDcAsE", in: services, backwards: backwards, caseSensitive: true)
            XCTAssertTrue(exact)
            let missing = await find("absent from the fixture", in: services, backwards: backwards)
            XCTAssertFalse(missing)
        }
    }

    @MainActor
    func testFindWrapsOnlyWhenAsked() async {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        await navigate(view) { view.loadHTMLString("<!doctype html><p>unique</p>", baseURL: nil) }
        let first = await find("unique", in: services, wraps: false)
        XCTAssertTrue(first)
        let pastEnd = await find("unique", in: services, wraps: false)
        XCTAssertFalse(pastEnd)
        let wrapped = await find("unique", in: services)
        XCTAssertTrue(wrapped)
        let beforeStart = await find("unique", in: services, backwards: true, wraps: false)
        XCTAssertFalse(beforeStart)
        let backwardsWrapped = await find("unique", in: services, backwards: true)
        XCTAssertTrue(backwardsWrapped)
    }

    /// The direction is WebKit's: with two matches and no wrapping, two
    /// finds forwards reach the second, then one backwards reaches the first
    /// and the next backwards finds none. Ignoring `backwards` would find
    /// none at the first step back.
    @MainActor
    func testFindGoesTheWayAsked() async {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        await navigate(view) { view.loadHTMLString("<!doctype html><p>alpha beta alpha</p>", baseURL: nil) }
        let first = await find("alpha", in: services, wraps: false)
        let second = await find("alpha", in: services, wraps: false)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let back = await find("alpha", in: services, backwards: true, wraps: false)
        XCTAssertTrue(back, "a find backwards from the second match found none")
        let beforeFirst = await find("alpha", in: services, backwards: true, wraps: false)
        XCTAssertFalse(beforeFirst, "a find backwards from the first match found one")
    }

    @MainActor
    func testZoomAndMagnificationFollowTheViewInBothDirections() {
        let view = makeView()
        let services = WebKitPageServices(view: view)
        XCTAssertEqual(services.pageZoom, Double(view.pageZoom))
        services.pageZoom = 1.25
        XCTAssertEqual(view.pageZoom, 1.25)
        view.pageZoom = 1.75
        XCTAssertEqual(services.pageZoom, 1.75)
        view.allowsMagnification = true
        view.setMagnification(1.5, centeredAt: .zero)
        XCTAssertEqual(view.magnification, 1.5)
        XCTAssertEqual(services.magnification, Double(view.magnification))
    }

    @MainActor
    func testPageWithoutCaptureIsNotCapturing() async {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        await navigate(view) { view.loadHTMLString("<!doctype html><p>No capture</p>", baseURL: nil) }
        XCTAssertEqual(view.cameraCaptureState, .none)
        XCTAssertEqual(view.microphoneCaptureState, .none)
        XCTAssertFalse(services.isCapturing)
    }

    @MainActor
    func testCustomUserAgentReachesTheViewAndReloadedPage() async throws {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        services.customUserAgent = "eGlu services first agent"
        XCTAssertEqual(view.customUserAgent, services.customUserAgent)
        await navigate(view) { view.loadHTMLString("<!doctype html><p>User agent</p>", baseURL: nil) }
        let first = try await view.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(first, "eGlu services first agent")
        services.customUserAgent = "eGlu services reloaded agent"
        XCTAssertEqual(view.customUserAgent, "eGlu services reloaded agent")
        await navigate(view) { view.reload() }
        let reloaded = try await view.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(reloaded, "eGlu services reloaded agent")
        view.customUserAgent = "view agent"
        XCTAssertEqual(services.customUserAgent, "view agent")
        services.customUserAgent = nil
        // WebKit reads an empty string back for its own agent; the service says nil.
        XCTAssertEqual(view.customUserAgent ?? "", "")
        XCTAssertNil(services.customUserAgent)
    }

    @MainActor
    func testPrintOperationUsesTheViewsBoundsAndGivenPrintInfo() async throws {
        let view = makeView()
        defer { view.stopLoading() }
        let services = WebKitPageServices(view: view)
        await navigate(view) { view.loadHTMLString("<!doctype html><p>Print fixture</p>", baseURL: nil) }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 500, height: 700)
        let operation = services.printOperation(with: info)
        XCTAssertEqual(try XCTUnwrap(operation.view).frame, view.bounds)
        XCTAssertEqual(operation.printInfo.paperSize, info.paperSize)
    }

    @MainActor
    func testReleasedViewDefaultsAndFindRepliesBeforeReturning() throws {
        weak var released: WKWebView?
        let services = autoreleasepool {
            let view = makeView()
            released = view
            return WebKitPageServices(view: view)
        }
        XCTAssertNil(released)
        XCTAssertNil(services.currentEntry)
        XCTAssertNil(services.restorationData)
        var found: Bool?
        services.find("anything", backwards: true, caseSensitive: true, wraps: false) { found = $0 }
        XCTAssertEqual(found, false)
        XCTAssertEqual(services.pageZoom, 1)
        XCTAssertEqual(services.magnification, 1)
        XCTAssertFalse(services.isCapturing)
        XCTAssertNil(services.customUserAgent)
        services.pageZoom = 2
        services.customUserAgent = "ignored"
        XCTAssertEqual(services.pageZoom, 1)
        XCTAssertNil(services.customUserAgent)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 500, height: 700)
        let operation = services.printOperation(with: info)
        let empty = try XCTUnwrap(operation.view)
        XCTAssertTrue(type(of: empty) == NSView.self)
        XCTAssertEqual(empty.frame, .zero)
        XCTAssertEqual(operation.printInfo.paperSize, info.paperSize)
        for tool in [WebDeveloperTool.inspector, .console, .elementSelection] {
            XCTAssertFalse(services.show(tool))
        }
    }

    /// The developer tools reach WebKit's private inspector as before: each
    /// step asked first, then its verb performed. A stand-in inspector takes
    /// the verbs, so no inspector window opens in a test.
    @MainActor
    func testDeveloperToolsPerformTheInspectorsVerbsAskedFirst() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = InspectorStandInView(frame: .zero, configuration: configuration)
        let services = WebKitPageServices(view: view)
        XCTAssertTrue(services.show(.inspector))
        XCTAssertTrue(services.show(.console))
        XCTAssertTrue(services.show(.elementSelection))
        XCTAssertEqual(view.standIn.calls, ["show", "showConsole", "toggleElementSelection"])
        // An inspector without the verb: false, and nothing performed.
        view.standIn.answers = false
        XCTAssertFalse(services.show(.inspector))
        XCTAssertEqual(view.standIn.calls.count, 3)
        // A WebKit without _inspector: false.
        view.standIn.answers = true
        view.hasInspector = false
        XCTAssertFalse(services.show(.console))
        XCTAssertEqual(view.standIn.calls.count, 3)
    }

    /// This WebKit has the private inspector and the three verbs the
    /// service performs: asked, never performed, so no window opens.
    @MainActor
    func testThisWebKitHasTheInspectorsVerbs() throws {
        let view = makeView()
        let inspector = try XCTUnwrap(view.responds(to: NSSelectorFromString("_inspector"))
            ? view.value(forKey: "_inspector") as? NSObject : nil)
        for verb in ["show", "showConsole", "toggleElementSelection"] {
            XCTAssertTrue(inspector.responds(to: NSSelectorFromString(verb)), verb)
        }
    }
}

/// Stands in for WebKit's _WKInspector: records the verbs performed on it.
private final class InspectorStandIn: NSObject, @unchecked Sendable {
    nonisolated(unsafe) var calls: [String] = []
    nonisolated(unsafe) var answers = true

    override func responds(to selector: Selector!) -> Bool {
        if ["show", "showConsole", "toggleElementSelection"].contains(NSStringFromSelector(selector)) { return answers }
        return super.responds(to: selector)
    }

    @objc func show() { calls.append("show") }
    @objc func showConsole() { calls.append("showConsole") }
    @objc func toggleElementSelection() { calls.append("toggleElementSelection") }
}

/// A web view whose _inspector is the stand-in.
private final class InspectorStandInView: WKWebView {
    nonisolated let standIn = InspectorStandIn()
    nonisolated(unsafe) var hasInspector = true

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if selector == Selector(("_inspector")) { return hasInspector }
        return super.responds(to: selector)
    }

    nonisolated override func value(forKey key: String) -> Any? {
        key == "_inspector" ? standIn : super.value(forKey: key)
    }
}
