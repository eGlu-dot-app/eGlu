import Foundation
import WebEngineCore
import WebKit
import WebKitMacPlugin
import XCTest

private final class ChildSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "eglu-child-test"

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let body = Data("""
        <!doctype html><title>offline child fixture</title>
        <a id="child" href="\(Self.scheme)://fixture/child" target="_blank" rel="opener">child</a>
        """.utf8)
        let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                   expectedContentLength: body.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor
private final class ChildDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {
    var request: WebKitChildRequest?
    var child: WKWebView?
    var parentFinished: (() -> Void)?
    var childRequested: (() -> Void)?
    var childFinished: (() -> Void)?

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = WebKitChildRequest(configuration: configuration, action: navigationAction, features: windowFeatures)
        self.request = request
        XCTAssertTrue(request.configuration === configuration)
        let child = WKWebView(frame: .zero, configuration: request.configuration)
        child.navigationDelegate = self
        self.child = child
        childRequested?()
        // Return this very child inside WebKit's call, without loading it ourselves.
        return child
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === child {
            // Ignore any initial blank document; check the window.open destination.
            if webView.url?.path == "/child" { childFinished?() }
        } else {
            parentFinished?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("offline fixture failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("offline fixture failed before commit: \(error)")
    }
}

final class WebKitChildRequestTests: XCTestCase {
    @MainActor
    func testScriptWindowWithoutSizeKeepsOpenerAndUnknownTarget() async throws {
        try await checkChild(script: "window.open('\(ChildSchemeHandler.scheme)://fixture/child')",
                             features: WebWindowFeatures(width: nil, height: nil), kind: .other)
    }

    @MainActor
    func testScriptWindowPreservesRequestedSizeAndOpener() async throws {
        try await checkChild(script: "window.open('\(ChildSchemeHandler.scheme)://fixture/child', '', 'width=300,height=200')",
                             features: WebWindowFeatures(width: 300, height: 200), kind: .other)
    }

    @MainActor
    func testTargetLinkUsesTheSameSynchronousChildRequest() async throws {
        try await checkChild(script: "document.getElementById('child').click()",
                             features: WebWindowFeatures(width: nil, height: nil), kind: .link)
    }

    @MainActor
    private func checkChild(script: String, features: WebWindowFeatures, kind: WebNavigationKind) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.setURLSchemeHandler(ChildSchemeHandler(), forURLScheme: ChildSchemeHandler.scheme)
        let parent = WKWebView(frame: .zero, configuration: configuration)
        let delegate = ChildDelegate()
        parent.uiDelegate = delegate
        parent.navigationDelegate = delegate
        defer {
            parent.stopLoading()
            parent.uiDelegate = nil
            parent.navigationDelegate = nil
            delegate.child?.stopLoading()
            delegate.child?.navigationDelegate = nil
            delegate.child = nil
        }
        let loaded = expectation(description: "offline parent loaded")
        var parentLoaded = false
        delegate.parentFinished = { parentLoaded = true; loaded.fulfill() }
        parent.load(URLRequest(url: URL(string: "\(ChildSchemeHandler.scheme)://fixture/parent")!))
        await fulfillment(of: [loaded], timeout: 10)
        delegate.parentFinished = nil
        guard parentLoaded else { return }

        let requested = expectation(description: "WebKit asked synchronously for a child")
        let finished = expectation(description: "child destination loaded")
        let evaluated = expectation(description: "window-opening script evaluated")
        delegate.childRequested = { requested.fulfill() }
        delegate.childFinished = { finished.fulfill() }
        parent.evaluateJavaScript(script + "; null;") { _, error in
            XCTAssertNil(error)
            evaluated.fulfill()
        }
        await fulfillment(of: [requested, finished, evaluated], timeout: 10)
        let request = try XCTUnwrap(delegate.request)
        let child = try XCTUnwrap(delegate.child)
        XCTAssertEqual(request.navigation.request.url, URL(string: "\(ChildSchemeHandler.scheme)://fixture/child"))
        XCTAssertEqual(request.navigation.sourceIsMainFrame, true)
        XCTAssertNil(request.navigation.targetIsMainFrame)
        XCTAssertEqual(request.navigation.kind, kind)
        XCTAssertEqual(request.features, features)
        XCTAssertTrue(child.configuration.websiteDataStore === request.configuration.websiteDataStore)

        let opener = expectation(description: "child retains its opener")
        child.evaluateJavaScript("window.opener !== null") { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? Bool, true)
            opener.fulfill()
        }
        await fulfillment(of: [opener], timeout: 10)
    }
}
