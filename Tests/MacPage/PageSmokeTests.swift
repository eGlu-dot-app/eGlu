import XCTest
@testable import eGluMac

/// A Page against a real WKWebView, in a store that keeps nothing: two
/// pages loaded the way eGlu loads an address, one after the other.
@MainActor
final class PageSmokeTests: PageTestCase {
    func testLoadsTwoPages() async {
        let page = makePage()
        await load(page, "One")
        XCTAssertEqual(page.view.title, "One")
        XCTAssertFalse(page.view.canGoBack)

        await load(page, "Two")
        XCTAssertEqual(page.view.title, "Two")
        XCTAssertTrue(page.view.canGoBack)
        XCTAssertEqual(page.view.backForwardList.backList.count, 1)
        XCTAssertNil(page.failure)
    }
}
