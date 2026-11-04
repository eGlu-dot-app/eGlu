import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit
@testable import WebKitMacPlugin
import XCTest

@MainActor
private final class PictureFixture: NSObject, WKUIDelegate, WKNavigationDelegate, WebPicturePageEvents {
    let parent: WebKitMacPage
    var backend: WebKitPicturePage?
    var didLoad = false
    var loaded: (() -> Void)?
    var requested: (() -> Void)?
    var calls: [String] = []
    var action: WKNavigationAction?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        parent = WebKitMacPage(configuration: config)
        super.init()
        parent.webView.uiDelegate = self
        parent.webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { didLoad = true; loaded?() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        action = navigationAction
        let request = WebKitChildRequest(configuration: configuration, action: navigationAction, features: windowFeatures)
        XCTAssertTrue(request.configuration === configuration)
        let child = parent.makePicturePage(from: request, size: CGSize(width: 320, height: 240)) as? WebKitPicturePage
        backend = child
        child?.connect(events: self)
        XCTAssertNotNil(child)
        XCTAssertTrue(child?.webView.configuration.userContentController === configuration.userContentController)
        XCTAssertTrue(child?.webView.configuration.websiteDataStore === configuration.websiteDataStore)
        XCTAssertEqual(child?.view.frame.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(child?.webView.configuration.userContentController.userScripts.count, 0)
        XCTAssertEqual(child?.webView.configuration.mediaTypesRequiringUserActionForPlayback, [])
        XCTAssertNil(child?.view.window)
        requested?()
        // This very view is returned in the call that supplied its configuration.
        return child?.webView
    }

    func decidePictureNavigation(url: URL?, targetIsMainFrame: Bool, reply: @MainActor (Bool) -> Void) {
        calls.append("navigation:\(targetIsMainFrame):\(url?.absoluteString ?? "nil")")
        reply(true)
        calls.append("replied")
    }
    func pictureRequestedWindow(url: URL?) { calls.append("window:\(url?.absoluteString ?? "nil")") }
    func pictureCloseRequested() { calls.append("close") }
    func pictureProcessEnded() { calls.append("process ended") }

    func tearDown() {
        backend?.tearDown()
        backend = nil
        parent.tearDown()
    }
}

final class WebKitPicturePageTests: XCTestCase {
    @MainActor
    func testChildFromLoadHTMLStringKeepsOpenerInTheSameCall() async throws {
        let fixture = PictureFixture()
        defer { fixture.tearDown() }
        // A script in the opener must not be installed in the child.
        fixture.parent.scripting.addUserScript(source: "globalThis.parentScript = true", injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, world: .page)
        let loaded = expectation(description: "HTML string parent loaded")
        fixture.loaded = { loaded.fulfill() }
        fixture.parent.webView.loadHTMLString("<!doctype html><title>picture fixture</title>", baseURL: URL(string: "https://picture.eglu.invalid/"))
        await fulfillment(of: [loaded], timeout: 10)
        fixture.loaded = nil
        guard fixture.didLoad else { return XCTFail("The parent page did not load") }
        let requested = expectation(description: "picture child made before returning")
        fixture.requested = { requested.fulfill() }
        let result = try await fixture.parent.webView.callAsyncJavaScript("""
            window.marker = 'opener';
            window.child = window.open('about:blank', '', 'width=320,height=240');
            return window.child !== null && window.child.opener === window;
            """, arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [requested], timeout: 10)
        XCTAssertEqual(result as? Bool, true)
        let backend = try XCTUnwrap(fixture.backend)
        XCTAssertNil(fixture.parent.contentView.window)
        XCTAssertNil(backend.view.window)
        XCTAssertTrue(backend.webView.isInspectable)
        XCTAssertTrue(backend.webView.acceptsFirstMouse(for: nil))
        let opener = try await backend.webView.callAsyncJavaScript("return window.opener.marker", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(opener as? String, "opener")
        let childScript = try await backend.webView.callAsyncJavaScript("return typeof parentScript", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(childScript as? String, "undefined")
    }

    @MainActor
    func testDelegatesForwardSynchronouslyAndTeardownDetachesThem() async throws {
        let fixture = PictureFixture()
        defer { fixture.tearDown() }
        let loaded = expectation(description: "parent loaded")
        fixture.loaded = { loaded.fulfill() }
        fixture.parent.webView.loadHTMLString("<!doctype html><title>delegates</title>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        fixture.loaded = nil
        guard fixture.didLoad else { return XCTFail("The parent page did not load") }
        _ = try await fixture.parent.webView.callAsyncJavaScript("window.open('about:blank'); return true", arguments: [:], in: nil, contentWorld: .page)
        let backend = try XCTUnwrap(fixture.backend)
        let action = try XCTUnwrap(fixture.action)
        fixture.calls = []
        backend.webView(backend.webView, decidePolicyFor: action) { decision in
            XCTAssertEqual(decision, .allow)
            XCTAssertEqual(fixture.calls, ["navigation:true:about:blank"])
            fixture.calls.append("WebKit replied")
        }
        XCTAssertEqual(fixture.calls, ["navigation:true:about:blank", "WebKit replied", "replied"])
        let nested = backend.webView(backend.webView, createWebViewWith: backend.webView.configuration,
                                     for: action, windowFeatures: WKWindowFeatures())
        XCTAssertNil(nested)
        backend.webViewDidClose(backend.webView)
        backend.webViewWebContentProcessDidTerminate(backend.webView)
        XCTAssertEqual(Array(fixture.calls.suffix(3)), ["window:about:blank", "close", "process ended"])
        XCTAssertTrue(backend.webView.navigationDelegate === backend)
        XCTAssertTrue(backend.webView.uiDelegate === backend)
        let container = NSView()
        container.addSubview(backend.view)
        backend.tearDown()
        backend.tearDown()
        XCTAssertNil(backend.webView.navigationDelegate)
        XCTAssertNil(backend.webView.uiDelegate)
        XCTAssertNil(backend.view.superview)
        let count = fixture.calls.count
        backend.webViewDidClose(backend.webView)
        backend.webViewWebContentProcessDidTerminate(backend.webView)
        XCTAssertEqual(fixture.calls.count, count)
    }
}
