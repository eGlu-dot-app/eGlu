#if os(macOS)
import AppKit
import WebKit
import WebKitSupport
import XCTest

final class WebKitHiddenPageTests: XCTestCase {
    @MainActor
    private func besideView(allows: @escaping @MainActor (URL?) -> Bool = { _ in true })
        -> (NSView, WKWebView, WebKitHiddenPage) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "HiddenPageTests"
        let view = WKWebView(frame: NSRect(x: 2, y: 3, width: 240, height: 180), configuration: configuration)
        let parent = NSView(frame: view.frame)
        parent.addSubview(view)
        let hidden = WebKitHiddenPage(beside: view, ruleLists: [], appWorld: .world(name: "hidden-test"), allows: allows)
        return (parent, view, hidden)
    }

    @MainActor
    func testHiddenPageIsBelowItsNeighbourTransparentAndNotAccessible() throws {
        let (parent, view, hidden) = besideView()
        defer { hidden.stop() }
        XCTAssertNil(parent.window)
        XCTAssertEqual(parent.subviews.count, 2)
        XCTAssertTrue(parent.subviews.last === view)
        let made = try XCTUnwrap(parent.subviews.first as? WKWebView)
        XCTAssertFalse(made === view)
        XCTAssertEqual(made.frame, view.frame)
        XCTAssertEqual(made.alphaValue, 0)
        XCTAssertFalse(made.isAccessibilityElement())
        XCTAssertTrue(made.configuration.websiteDataStore === view.configuration.websiteDataStore)
        XCTAssertEqual(made.configuration.applicationNameForUserAgent, "HiddenPageTests")
        XCTAssertEqual(made.configuration.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertFalse(made.configuration.allowsAirPlayForMediaPlayback)
        XCTAssertFalse(made.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(made.configuration.userContentController.userScripts.isEmpty)
    }

    @MainActor
    func testAllowedPageCommitsAndAppWorldCallSeesItsArguments() async throws {
        let (parent, _, hidden) = besideView { $0?.scheme == "data" }
        defer { hidden.stop(); withExtendedLifetime(parent) {} }
        let url = URL(string: "data:text/html,%3Ctitle%3Efixture%3C/title%3E")!
        let began = await hidden.begin(url, within: .seconds(3))
        guard began else { return XCTFail("The allowed data page must commit.") }
        let result = try await hidden.callInAppWorld("globalThis.fromApp = value; return value + suffix;",
                                                    arguments: ["value": "argument", "suffix": " kept"])
        XCTAssertEqual(result as? String, "argument kept")
        let made = try XCTUnwrap(parent.subviews.first as? WKWebView)
        let inPageWorld = try await made.callAsyncJavaScript("return typeof globalThis.fromApp", arguments: [:],
                                                            in: nil, contentWorld: .page)
        XCTAssertEqual(inPageWorld as? String, "undefined")
    }

    @MainActor
    func testRefusedNavigationAnswersFalseAndDoesNotCommit() async throws {
        var asked: [URL?] = []
        let (parent, _, hidden) = besideView { asked.append($0); return false }
        defer { hidden.stop(); withExtendedLifetime(parent) {} }
        let url = URL(string: "data:text/html,refused")!
        let began = await hidden.begin(url, within: .seconds(3))
        XCTAssertFalse(began)
        XCTAssertEqual(asked, [url])
        let made = try XCTUnwrap(parent.subviews.first as? WKWebView)
        XCTAssertNotEqual(made.url, url)
    }

    @MainActor
    func testStopWhileBeginWaitsAnswersFalseAndRemovesThePage() async throws {
        let (parent, view, hidden) = besideView()
        let made = try XCTUnwrap(parent.subviews.first as? WKWebView)
        // This task can run once begin has installed its continuation and yielded.
        let stopping = Task { @MainActor in hidden.stop() }
        let began = await hidden.begin(URL(string: "about:blank")!, within: .seconds(3))
        await stopping.value
        XCTAssertFalse(began)
        XCTAssertNil(made.superview)
        XCTAssertNil(made.navigationDelegate)
        XCTAssertEqual(parent.subviews.count, 1)
        XCTAssertTrue(parent.subviews.first === view)
    }

    @MainActor
    func testLimitPassingBeforeCommitAnswersFalse() async {
        let (parent, _, hidden) = besideView()
        defer { hidden.stop(); withExtendedLifetime(parent) {} }
        let began = await hidden.begin(URL(string: "about:blank")!, within: .zero)
        XCTAssertFalse(began)
    }
}
#endif
