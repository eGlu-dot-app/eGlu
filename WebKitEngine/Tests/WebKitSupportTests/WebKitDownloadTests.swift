import WebEngineCore
import WebKit
import WebKitSupport
import XCTest

@MainActor
private final class DownloadRecorder: WebEngineCore.WebDownloadDelegate {
    var events: [String] = []
    var download: (any WebEngineCore.WebDownload)?
    var response: URLResponse?
    var name: String?
    var error: (any Error)?
    var failed: (() -> Void)?

    func download(_ download: any WebEngineCore.WebDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        events.append("destination")
        self.download = download
        self.response = response
        name = suggestedFilename
        // No test download ever has a destination or writes a file.
        completionHandler(nil)
    }

    func downloadDidFinish(_ download: any WebEngineCore.WebDownload) {
        XCTFail("A download with no destination cannot finish.")
    }

    func download(_ download: any WebEngineCore.WebDownload, didFailWithError error: any Error, resumeData: Data?) {
        events.append("failure")
        XCTAssertTrue(self.download === download)
        self.error = error
        failed?()
    }
}

final class WebKitDownloadTests: XCTestCase {
    @MainActor
    func testSpaceStarterForwardsDestinationThenFailureWithoutWriting() async throws {
        let starter = WebKitDownloadStarter(store: .nonPersistent())
        let request = URLRequest(url: URL(string: "data:application/octet-stream;base64,SGVsbG8=")!)
        let recorder = DownloadRecorder()
        let failed = expectation(description: "nil destination failed")
        recorder.failed = { failed.fulfill() }
        var download: (any WebEngineCore.WebDownload)?
        starter.startDownload(using: request) {
            download = $0
            $0.delegate = recorder
        }
        await fulfillment(of: [failed], timeout: 10)
        let wrapped = try XCTUnwrap(download as? WebKitDownload)
        // WebKit hands back its own copy of the request: the same address.
        XCTAssertEqual(wrapped.originalRequest?.url, request.url)
        XCTAssertEqual(wrapped.originalURL, request.url)
        XCTAssertTrue(recorder.download === wrapped)
        XCTAssertEqual(recorder.response?.url, request.url)
        XCTAssertFalse(try XCTUnwrap(recorder.name).isEmpty)
        XCTAssertNotNil(recorder.error)
        XCTAssertEqual(recorder.events, ["destination", "failure"])
        XCTAssertTrue(starter.canStartDownloads)
        // WebKit's own progress, not one of the wrapper's.
        let raw = try XCTUnwrap(Mirror(reflecting: wrapped).children.first { $0.label == "download" }?.value as? WKDownload)
        XCTAssertTrue(wrapped.progress === raw.progress)
    }

    @MainActor
    func testNoDelegateAnswersDestinationNilAndDelegateIsWeak() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        let started = expectation(description: "download wrapped")
        let cancelled = expectation(description: "download cancelled")
        view.startDownload(using: URLRequest(url: URL(string: "data:text/plain,fixture")!)) { raw in
            let wrapped = WebKitDownload(raw)
            XCTAssertTrue(raw.delegate === wrapped)
            weak var weakDelegate: DownloadRecorder?
            autoreleasepool {
                let delegate = DownloadRecorder()
                weakDelegate = delegate
                wrapped.delegate = delegate
            }
            XCTAssertNil(weakDelegate)
            XCTAssertNil(wrapped.delegate)
            let response = URLResponse(url: raw.originalRequest!.url!, mimeType: "text/plain",
                                       expectedContentLength: 7, textEncodingName: "utf-8")
            var answers = 0
            wrapped.download(raw, decideDestinationUsing: response, suggestedFilename: "fixture.txt") {
                XCTAssertNil($0)
                answers += 1
            }
            XCTAssertEqual(answers, 1)
            XCTAssertTrue(wrapped.progress === raw.progress)
            wrapped.cancel { _ in
                // Keep the wrapper as WebKit's nil-answer delegate until cancellation ends.
                withExtendedLifetime(wrapped) { cancelled.fulfill() }
            }
            started.fulfill()
        }
        await fulfillment(of: [started, cancelled], timeout: 10)
    }

    @MainActor
    func testTemporarySessionKeepsTheViewOnlyUntilReleased() throws {
        weak var weakView: WKWebView?
        var session: (any WebDownloadStarting)?
        let starter = autoreleasepool {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            weakView = view
            let starter = WebKitDownloadStarter(view: view)
            session = starter.keepingSessionAlive()
            return starter
        }
        XCTAssertNotNil(weakView)
        XCTAssertTrue(try XCTUnwrap(session).canStartDownloads)
        XCTAssertTrue(starter.canStartDownloads)
        session = nil
        XCTAssertNil(weakView)
        XCTAssertFalse(starter.canStartDownloads)
        XCTAssertFalse(starter.keepingSessionAlive().canStartDownloads)
    }

    @MainActor
    func testPageStarterDoesNotKeepItsView() {
        weak var weakView: WKWebView?
        let starter = autoreleasepool {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            weakView = view
            let starter = WebKitDownloadStarter(view: view)
            XCTAssertTrue(starter.canStartDownloads)
            return starter
        }
        XCTAssertNil(weakView)
        XCTAssertFalse(starter.canStartDownloads)
    }
}
