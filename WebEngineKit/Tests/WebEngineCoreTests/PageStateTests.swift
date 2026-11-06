import Foundation
import WebEngineCore
import XCTest

final class PageStateTests: XCTestCase {
    func testEqualityUsesEveryField() {
        func state(url: URL? = URL(string: "https://example.com"), title: String? = "Example",
                   isLoading: Bool = false, estimatedProgress: Double = 1,
                   canGoBack: Bool = false, canGoForward: Bool = false,
                   hasOnlySecureContent: Bool = true) -> PageState {
            PageState(url: url, title: title, isLoading: isLoading, estimatedProgress: estimatedProgress,
                      canGoBack: canGoBack, canGoForward: canGoForward, hasOnlySecureContent: hasOnlySecureContent)
        }

        let original = state()
        XCTAssertEqual(original, state())
        XCTAssertNotEqual(original, state(url: nil))
        XCTAssertNotEqual(original, state(title: nil))
        XCTAssertNotEqual(original, state(isLoading: true))
        XCTAssertNotEqual(original, state(estimatedProgress: 0.5))
        XCTAssertNotEqual(original, state(canGoBack: true))
        XCTAssertNotEqual(original, state(canGoForward: true))
        XCTAssertNotEqual(original, state(hasOnlySecureContent: false))
    }
}
