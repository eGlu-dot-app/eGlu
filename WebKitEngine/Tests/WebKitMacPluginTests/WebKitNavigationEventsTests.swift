import Foundation
import WebEngineCore
import WebKit
@testable import WebKitMacPlugin
import XCTest

@MainActor
final class NavigationEventsRecorder: WebNavigationEvents {
    enum Event: Equatable {
        case started(URL?), redirected(URL?), committed(URL?), finished
        case failed(WebLoadError, provisional: Bool)
        case processEnded
    }

    var received: [Event] = []
    var onEvent: ((Event) -> Void)?
    var downloads: [any WebEngineCore.WebDownload] = []
    var onDownload: ((any WebEngineCore.WebDownload) -> Void)?

    private func record(_ event: Event) {
        received.append(event)
        onEvent?(event)
    }

    func navigationStarted(url: URL?) { record(.started(url)) }
    func navigationRedirected(url: URL?) { record(.redirected(url)) }
    func navigationCommitted(url: URL?) { record(.committed(url)) }
    func navigationFinished() { record(.finished) }
    func navigationFailed(_ error: WebLoadError, provisional: Bool) { record(.failed(error, provisional: provisional)) }
    func contentProcessEnded() { record(.processEnded) }
    func navigationBecameDownload(_ download: any WebEngineCore.WebDownload) {
        downloads.append(download)
        onDownload?(download)
    }
}

@MainActor
private final class AllowPolicy: WebNavigationPolicy {
    func decideNavigation(_ navigation: WebNavigation, reply: @MainActor (WebNavigationDecision) -> Void) { reply(.allow) }
    func decideResponse(_ response: WebResponse, reply: @MainActor (WebResponseDecision) -> Void) { reply(.allow) }
}

private final class LifecycleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "eglu-lifecycle-test"
    let error: NSError?

    init(error: NSError? = nil) { self.error = error }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        if let error {
            urlSchemeTask.didFailWithError(error)
            return
        }
        let body = Data("<!doctype html><title>lifecycle</title><p>offline fixture</p>".utf8)
        let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                   expectedContentLength: body.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

final class WebKitNavigationEventsTests: XCTestCase {
    @MainActor
    func testLoadFileReportsStartedCommittedFinishedWithFileURL() async throws {
        // A folder of its own in the temporary folder, readable as a whole, so
        // the read-access address differs from the file's.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("page.html")
        try Data("<!doctype html><title>file</title><p>offline file</p>".utf8).write(to: url)
        let view = makeView()
        let policy = AllowPolicy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        view.navigationDelegate = adapter
        defer { view.stopLoading(); adapter.tearDown() }
        let done = expectation(description: "file load finished")
        events.onEvent = { event in
            if event == .finished { done.fulfill() }
            if case .failed = event { XCTFail("file fixture must succeed"); done.fulfill() }
        }
        let loader: any WebRequestLoading = adapter
        loader.loadFile(url, allowingReadAccessTo: folder)
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(events.received, [.started(url), .committed(url), .finished])
        XCTAssertEqual(view.url, url)
    }

    @MainActor
    private func makeView(handler: LifecycleSchemeHandler? = nil) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let handler { configuration.setURLSchemeHandler(handler, forURLScheme: LifecycleSchemeHandler.scheme) }
        return WKWebView(frame: .zero, configuration: configuration)
    }

    @MainActor
    func testLoadErrorMapsKindAndPreservesDomainCodeAndOptionalFailingURL() {
        let url = URL(string: "https://example.com/failed")!
        let cases: [(String, Int, WebLoadError.Kind)] = [
            (NSURLErrorDomain, NSURLErrorCancelled, .cancelled),
            ("WebKitErrorDomain", 102, .interrupted),
            ("WebKitErrorDomain", 204, .interrupted),
            ("WebKitErrorDomain", 101, .other),
            (NSURLErrorDomain, NSURLErrorNotConnectedToInternet, .other),
            ("another-domain", NSURLErrorCancelled, .other),
            (NSURLErrorDomain, 102, .other),
        ]
        for (domain, code, kind) in cases {
            for failingURL in [nil, url] as [URL?] {
                let info: [String: Any] = failingURL.map { [NSURLErrorFailingURLErrorKey: $0] } ?? [:]
                let original = NSError(domain: domain, code: code, userInfo: info)
                XCTAssertEqual(WebKitNavigationAdapter.loadError(original),
                               WebLoadError(kind: kind, domain: domain, code: code, failingURL: failingURL))
            }
        }
        let stringURL = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                userInfo: [NSURLErrorFailingURLErrorKey: url.absoluteString])
        XCTAssertNil(WebKitNavigationAdapter.loadError(stringURL).failingURL)
    }

    @MainActor
    func testOfflineLoadReportsStartedCommittedFinishedInOrderAndRedirectUsesCurrentURL() async {
        let view = makeView(handler: LifecycleSchemeHandler())
        let policy = AllowPolicy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        view.navigationDelegate = adapter
        defer { view.stopLoading(); adapter.tearDown() }
        let done = expectation(description: "offline load finished")
        events.onEvent = { event in
            if event == .finished { done.fulfill() }
            if case .failed = event { XCTFail("offline fixture must succeed"); done.fulfill() }
        }
        let url = URL(string: "\(LifecycleSchemeHandler.scheme)://fixture/success")!
        adapter.load(URLRequest(url: url))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(events.received, [.started(url), .committed(url), .finished])
        adapter.webView(view, didReceiveServerRedirectForProvisionalNavigation: nil)
        adapter.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(events.received, [.started(url), .committed(url), .finished, .redirected(url), .processEnded])
    }

    @MainActor
    func testOfflineFailureReportsStartedThenMappedProvisionalFailure() async {
        let url = URL(string: "\(LifecycleSchemeHandler.scheme)://fixture/failure")!
        let original = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                               userInfo: [NSURLErrorFailingURLErrorKey: url])
        let view = makeView(handler: LifecycleSchemeHandler(error: original))
        let policy = AllowPolicy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        view.navigationDelegate = adapter
        defer { view.stopLoading(); adapter.tearDown() }
        let done = expectation(description: "offline load failed")
        events.onEvent = { event in
            if case .failed = event { done.fulfill() }
            if event == .finished { XCTFail("offline fixture must fail"); done.fulfill() }
        }
        adapter.load(URLRequest(url: url))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(events.received, [.started(url), .failed(WebKitNavigationAdapter.loadError(original), provisional: true)])
    }

    @MainActor
    private func reportAllCallbacks(_ adapter: WebKitNavigationAdapter, view: WKWebView, error: Error) {
        adapter.webView(view, didStartProvisionalNavigation: nil)
        adapter.webView(view, didReceiveServerRedirectForProvisionalNavigation: nil)
        adapter.webView(view, didCommit: nil)
        adapter.webView(view, didFinish: nil)
        adapter.webView(view, didFail: nil, withError: error)
        adapter.webView(view, didFailProvisionalNavigation: nil, withError: error)
        adapter.webViewWebContentProcessDidTerminate(view)
    }

    @MainActor
    func testAllLifecycleCallbacksReportSynchronously() {
        let view = makeView()
        let policy = AllowPolicy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        defer { adapter.tearDown() }
        let selectors = [
            #selector(WKNavigationDelegate.webView(_:didStartProvisionalNavigation:)),
            #selector(WKNavigationDelegate.webView(_:didReceiveServerRedirectForProvisionalNavigation:)),
            #selector(WKNavigationDelegate.webView(_:didCommit:)),
            #selector(WKNavigationDelegate.webView(_:didFinish:)),
            #selector(WKNavigationDelegate.webView(_:didFail:withError:)),
            #selector(WKNavigationDelegate.webView(_:didFailProvisionalNavigation:withError:)),
            #selector(WKNavigationDelegate.webViewWebContentProcessDidTerminate(_:)),
        ]
        for selector in selectors {
            XCTAssertTrue(adapter.responds(to: selector))
            XCTAssertNil(adapter.forwardingTarget(for: selector))
        }
        let original = NSError(domain: "WebKitErrorDomain", code: 204)
        reportAllCallbacks(adapter, view: view, error: original)
        let mapped = WebKitNavigationAdapter.loadError(original)
        XCTAssertEqual(events.received, [.started(nil), .redirected(nil), .committed(nil), .finished,
                                         .failed(mapped, provisional: false), .failed(mapped, provisional: true), .processEnded])
        adapter.tearDown()
        reportAllCallbacks(adapter, view: view, error: original)
        XCTAssertEqual(events.received.count, 7, "teardown clears the events reference while its owner is still alive")
    }

    @MainActor
    func testAdapterHoldsEventsWeakly() {
        let view = makeView()
        let policy = AllowPolicy()
        weak var weakEvents: NavigationEventsRecorder?
        let adapter = autoreleasepool {
            let events = NavigationEventsRecorder()
            weakEvents = events
            return WebKitNavigationAdapter(view: view, policy: policy, events: events)
        }
        XCTAssertNil(weakEvents)
        reportAllCallbacks(adapter, view: view, error: NSError(domain: "fixture", code: 1))
        adapter.tearDown()
    }
}
