import WebKit
import XCTest
@testable import eGluMac

/// `Page.stopLoading()` and `reloadFromOrigin()` are WebKit's own, passed
/// straight on (Docs/EngineSplitPlan.md, 7.1): Stop ends a load under way,
/// and reloading from origin loads the same document again without going
/// through the product's `reload(byHand:)`, which retries and resets more.
@MainActor
final class PageCommandTests: PageTestCase {
    func testStopEndsALoadUnderWay() async {
        let configuration = Self.keepingNothing()
        let never = NeverAnswers()
        configuration.setURLSchemeHandler(never, forURLScheme: NeverAnswers.scheme)
        let page = makePage(configuration: configuration)

        // The document is there at once, but its picture never comes, so
        // the page keeps loading until it is stopped.
        page.load(Self.address("Waiting", body: "<img src=\"\(NeverAnswers.scheme)://picture\">"))
        await waitUntil(page, "Waiting shown, still loading") { $0.title == "Waiting" && $0.isLoading }
        XCTAssertTrue(page.state.isLoading)

        page.stopLoading()
        await waitUntil(page, "the load stopped") { !$0.isLoading }
        XCTAssertFalse(page.state.isLoading)
        XCTAssertEqual(page.state.title, "Waiting")
        XCTAssertGreaterThan(never.started, 0, "the picture was asked for")
    }

    func testReloadFromOriginLoadsTheSameDocumentAgain() async throws {
        let page = makePage()
        await load(page, "One")
        await load(page, "Two")
        let before = page.state

        // A change the document didn't come with, which only a load undoes.
        _ = try await page.view.evaluateJavaScript("document.title = 'Changed'; 1")
        await waitUntil(page, "the title changed") { $0.title == "Changed" }

        page.reloadFromOrigin()
        await waitForPage(page, titled: "Two")
        XCTAssertEqual(page.state.url, before.url)
        XCTAssertEqual(page.state.canGoBack, before.canGoBack, "a reload adds nothing to the history")
        XCTAssertEqual(page.state.canGoForward, before.canGoForward)
        XCTAssertNil(page.failure)
    }
}

/// Never answers what it is asked for, so whatever the page asks it for
/// keeps the page loading.
private final class NeverAnswers: NSObject, WKURLSchemeHandler {
    static let scheme = "eglu-test-never"
    private(set) var started = 0

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        started += 1
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

extension PageTestCase {
    /// A page of its own named `title`, with `body` after its heading.
    static func address(_ title: String, body: String) -> URL {
        let html = "<!doctype html><title>\(title)</title><p>\(title)</p>\(body)"
        return URL(string: "data:text/html;charset=utf-8," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }
}
