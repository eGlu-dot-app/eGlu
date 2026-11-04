import Foundation
import WebEngineCore
import XCTest

final class WebNavigationEventsTests: XCTestCase {
    func testLoadErrorPreservesFieldsAndUsesEveryFieldForEquality() {
        let url = URL(string: "https://example.com/failed")!
        let error = WebLoadError(kind: .other, domain: "engine", code: 101, failingURL: url)
        XCTAssertEqual(error.kind, .other)
        XCTAssertEqual(error.domain, "engine")
        XCTAssertEqual(error.code, 101)
        XCTAssertEqual(error.failingURL, url)
        XCTAssertEqual(error, WebLoadError(kind: .other, domain: "engine", code: 101, failingURL: url))
        XCTAssertNotEqual(error, WebLoadError(kind: .cancelled, domain: "engine", code: 101, failingURL: url))
        XCTAssertNotEqual(error, WebLoadError(kind: .interrupted, domain: "engine", code: 101, failingURL: url))
        XCTAssertNotEqual(error, WebLoadError(kind: .other, domain: "another", code: 101, failingURL: url))
        XCTAssertNotEqual(error, WebLoadError(kind: .other, domain: "engine", code: 102, failingURL: url))
        XCTAssertNotEqual(error, WebLoadError(kind: .other, domain: "engine", code: 101, failingURL: nil))
        XCTAssertNotEqual(error, WebLoadError(kind: .other, domain: "engine", code: 101,
                                              failingURL: URL(string: "https://example.com/another")!))
        let noURL = WebLoadError(kind: .cancelled, domain: NSURLErrorDomain, code: NSURLErrorCancelled, failingURL: nil)
        XCTAssertNil(noURL.failingURL)
        XCTAssertEqual(noURL, WebLoadError(kind: .cancelled, domain: NSURLErrorDomain,
                                           code: NSURLErrorCancelled, failingURL: nil))
    }
}
