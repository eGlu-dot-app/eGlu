import Foundation
import WebEngineCore
import XCTest

final class WebChildRequestTests: XCTestCase {
    func testWindowFeaturesPreserveFieldsAndCompareBothDimensions() {
        let cases = [
            WebWindowFeatures(width: nil, height: nil),
            WebWindowFeatures(width: 300, height: nil),
            WebWindowFeatures(width: nil, height: 200),
            WebWindowFeatures(width: 300, height: 200),
            WebWindowFeatures(width: 301, height: 200),
            WebWindowFeatures(width: 300, height: 201)
        ]
        XCTAssertNil(cases[0].width)
        XCTAssertNil(cases[0].height)
        XCTAssertEqual(cases[3].width, 300)
        XCTAssertEqual(cases[3].height, 200)
        for (i, value) in cases.enumerated() {
            XCTAssertEqual(value, WebWindowFeatures(width: value.width, height: value.height))
            for (j, other) in cases.enumerated() {
                XCTAssertEqual(value == other, i == j)
            }
        }
    }

    func testSourceFrameDefaultsToUnknownAndPreservesTrueAndFalse() {
        let request = URLRequest(url: URL(string: "about:blank")!)
        let unspecified = WebNavigation(request: request, sourceOrigin: .opaque, targetIsMainFrame: nil,
                                        kind: .other, modifiers: [], buttonNumber: 0, requestsDownload: false,
                                        isServerRedirect: false, contentRuleRedirect: nil)
        XCTAssertNil(unspecified.sourceIsMainFrame)
        for source in [true, false] {
            let navigation = WebNavigation(request: request, sourceOrigin: .opaque, targetIsMainFrame: nil,
                                           kind: .other, modifiers: [], buttonNumber: 0, requestsDownload: false,
                                           isServerRedirect: false, contentRuleRedirect: nil, sourceIsMainFrame: source)
            XCTAssertEqual(navigation.sourceIsMainFrame, source)
        }
    }
}
