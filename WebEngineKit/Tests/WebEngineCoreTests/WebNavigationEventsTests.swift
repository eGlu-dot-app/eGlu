import Foundation
import WebEngineCore
import XCTest

final class WebNavigationEventsTests: XCTestCase {
    @MainActor
    func testAnEventsObjectCanKeepTheDownloadsItIsGiven() {
        let recorder = DownloadEvents()
        let events: any WebNavigationEvents = recorder
        let url = URL(string: "https://example.com/file")!
        weak var weakDownload: Download?
        do {
            let download = Download(originalURL: url)
            weakDownload = download
            events.navigationBecameDownload(download)
            XCTAssertTrue(recorder.downloads.first === download)
        }
        XCTAssertNotNil(weakDownload)
        XCTAssertEqual(recorder.downloads.first?.originalURL, url)
        events.navigationBecameDownload(Download(originalURL: nil))
        XCTAssertEqual(recorder.downloads.count, 2)
        XCTAssertNil(recorder.downloads.last?.originalURL)
    }

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

@MainActor
private final class Download: WebDownload {
    let originalURL: URL?
    init(originalURL: URL?) { self.originalURL = originalURL }
}

@MainActor
private final class DownloadEvents: WebNavigationEvents {
    var downloads: [any WebDownload] = []
    func navigationBecameDownload(_ download: any WebDownload) { downloads.append(download) }
    func navigationStarted(url: URL?) {}
    func navigationRedirected(url: URL?) {}
    func navigationCommitted(url: URL?) {}
    func navigationFinished() {}
    func navigationFailed(_ error: WebLoadError, provisional: Bool) {}
    func contentProcessEnded() {}
}
