import XCTest
@testable import eGluMac

/// `Page.state` is WebKit's own values and nothing else: each field against
/// the view's property of the same name, before and after loading, after
/// going back and after going forward (Docs/EngineSplitPlan.md, 7.1).
@MainActor
final class PageStateTests: PageTestCase {
    func testBeforeAnyLoad() {
        let page = makePage()
        assertStateIsWebKits(page, "before any load")
        XCTAssertNil(page.state.url)
        XCTAssertFalse(page.state.isLoading)
        XCTAssertFalse(page.state.canGoBack)
        XCTAssertFalse(page.state.canGoForward)
    }

    func testWhileLoading() {
        let page = makePage()
        page.load(Self.address("Loading"))
        assertStateIsWebKits(page, "as the load begins")
    }

    func testAfterLoading() async {
        let page = makePage()
        await load(page, "One")
        assertStateIsWebKits(page, "after loading One")
        await load(page, "Two")
        assertStateIsWebKits(page, "after loading Two")
        XCTAssertEqual(page.state.title, "Two")
        XCTAssertFalse(page.state.isLoading)
        XCTAssertEqual(page.state.estimatedProgress, 1)
        XCTAssertTrue(page.state.canGoBack)
        XCTAssertFalse(page.state.canGoForward)
    }

    func testAfterGoingBack() async {
        let page = makePage()
        await load(page, "One")
        await load(page, "Two")
        page.goBack()
        await waitForPage(page, titled: "One")
        assertStateIsWebKits(page, "after going back")
        XCTAssertEqual(page.state.title, "One")
        XCTAssertFalse(page.state.canGoBack)
        XCTAssertTrue(page.state.canGoForward)
    }

    func testAfterGoingForward() async {
        let page = makePage()
        await load(page, "One")
        await load(page, "Two")
        page.goBack()
        await waitForPage(page, titled: "One")
        page.goForward()
        await waitForPage(page, titled: "Two")
        assertStateIsWebKits(page, "after going forward")
        XCTAssertEqual(page.state.title, "Two")
        XCTAssertTrue(page.state.canGoBack)
        XCTAssertFalse(page.state.canGoForward)
    }

    func testSameValuesAreEqual() async {
        let page = makePage()
        await load(page, "One")
        XCTAssertEqual(page.state, page.state)
        let one = page.state
        await load(page, "Two")
        XCTAssertNotEqual(page.state, one)
    }

    /// Each field of `state` against the view's own, read at the same moment.
    private func assertStateIsWebKits(_ page: Page, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = page.state
        let view = page.view
        XCTAssertEqual(state.url, view.url, "url, \(when)", file: file, line: line)
        XCTAssertEqual(state.title, view.title, "title, \(when)", file: file, line: line)
        XCTAssertEqual(state.isLoading, view.isLoading, "isLoading, \(when)", file: file, line: line)
        XCTAssertEqual(state.estimatedProgress, view.estimatedProgress, "estimatedProgress, \(when)", file: file, line: line)
        XCTAssertEqual(state.canGoBack, view.canGoBack, "canGoBack, \(when)", file: file, line: line)
        XCTAssertEqual(state.canGoForward, view.canGoForward, "canGoForward, \(when)", file: file, line: line)
        XCTAssertEqual(state.hasOnlySecureContent, view.hasOnlySecureContent, "hasOnlySecureContent, \(when)",
                       file: file, line: line)
    }
}
