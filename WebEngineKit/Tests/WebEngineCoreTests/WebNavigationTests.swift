import Foundation
import WebEngineCore
import XCTest

final class WebNavigationTests: XCTestCase {
    func testInitializersPreserveEveryField() {
        var request = URLRequest(url: URL(string: "https://example.com:8443/path?q=1")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 17)
        request.httpMethod = "POST"
        request.httpBody = Data("body".utf8)
        request.setValue("value", forHTTPHeaderField: "X-Test")
        let origin = WebOrigin.tuple(scheme: "https", host: "source.example", port: 9443)
        let site = URL(string: "http://original.example:8080/")!
        let navigation = WebNavigation(request: request, sourceOrigin: origin, targetIsMainFrame: false,
                                       kind: .unknown(101), modifiers: [.command, .option], buttonNumber: 7,
                                       requestsDownload: true, isServerRedirect: true,
                                       contentRuleRedirect: WebContentRuleRedirect(originalSite: site))
        XCTAssertEqual(navigation.request, request)
        XCTAssertEqual(navigation.sourceOrigin, origin)
        XCTAssertEqual(navigation.targetIsMainFrame, false)
        XCTAssertEqual(navigation.kind, .unknown(101))
        XCTAssertEqual(navigation.modifiers, [.command, .option])
        XCTAssertEqual(navigation.buttonNumber, 7)
        XCTAssertTrue(navigation.requestsDownload)
        XCTAssertTrue(navigation.isServerRedirect)
        XCTAssertEqual(navigation.contentRuleRedirect?.originalSite, site)
    }

    func testAbsentTargetAndMarkedRedirectRemainDistinctFromNoRedirect() {
        func navigation(_ redirect: WebContentRuleRedirect?) -> WebNavigation {
            WebNavigation(request: URLRequest(url: URL(string: "about:blank")!), sourceOrigin: .opaque,
                          targetIsMainFrame: nil, kind: .other, modifiers: [], buttonNumber: -1,
                          requestsDownload: false, isServerRedirect: false, contentRuleRedirect: redirect)
        }
        let marked = navigation(WebContentRuleRedirect(originalSite: nil))
        XCTAssertNil(marked.targetIsMainFrame)
        XCTAssertEqual(marked.sourceOrigin, .opaque)
        XCTAssertEqual(marked.buttonNumber, -1)
        XCTAssertFalse(marked.requestsDownload)
        XCTAssertFalse(marked.isServerRedirect)
        XCTAssertNotNil(marked.contentRuleRedirect)
        XCTAssertNil(marked.contentRuleRedirect?.originalSite)
        XCTAssertNil(navigation(nil).contentRuleRedirect)
    }

    func testModifierSets() {
        let flags: [WebModifiers] = [.command, .shift, .option, .control]
        XCTAssertEqual(Set(flags.map(\.rawValue)).count, 4)
        var all: WebModifiers = []
        for flag in flags {
            XCTAssertNotEqual(flag.rawValue, 0)
            XCTAssertEqual(flag.rawValue.nonzeroBitCount, 1)
            all.insert(flag)
        }
        for flag in flags { XCTAssertTrue(all.contains(flag)) }
        all.remove(.option)
        XCTAssertFalse(all.contains(.option))
        XCTAssertTrue(all.contains([.command, .shift, .control]))
        XCTAssertEqual(WebModifiers(rawValue: all.rawValue), all)
    }

    func testKindsAndOriginsUseAllAssociatedValuesForEquality() {
        let kinds: [WebNavigationKind] = [.link, .form, .formResubmission, .history, .reload, .other,
                                          .unknown(-1), .unknown(0), .unknown(99)]
        for (i, kind) in kinds.enumerated() {
            for (j, other) in kinds.enumerated() { XCTAssertEqual(kind == other, i == j) }
        }
        let origin = WebOrigin.tuple(scheme: "https", host: "example.com", port: 443)
        XCTAssertEqual(origin, .tuple(scheme: "https", host: "example.com", port: 443))
        XCTAssertNotEqual(origin, .tuple(scheme: "http", host: "example.com", port: 443))
        XCTAssertNotEqual(origin, .tuple(scheme: "https", host: "other.example", port: 443))
        XCTAssertNotEqual(origin, .tuple(scheme: "https", host: "example.com", port: 8443))
        XCTAssertNotEqual(origin, .opaque)
        XCTAssertEqual(WebOrigin.opaque, .opaque)
    }
}
