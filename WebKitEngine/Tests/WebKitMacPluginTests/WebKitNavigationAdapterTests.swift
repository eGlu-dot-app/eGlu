import AppKit
import WebEngineCore
import WebKit
import WebKitSupport
@testable import WebKitMacPlugin
import XCTest

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class CaptureDelegate: NSObject, WKNavigationDelegate {
    var action: ((WKNavigationAction) -> WKNavigationActionPolicy)?
    var response: ((WKNavigationResponse) -> WKNavigationResponsePolicy)?
    var finished: (() -> Void)?
    var failed: ((Error) -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action?(navigationAction) ?? .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response?(navigationResponse) ?? .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed?(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed?(error)
    }
}

@MainActor
private final class Policy: WebNavigationPolicy {
    var decide: (WebNavigation, @MainActor (WebNavigationDecision) -> Void) -> Void = { _, reply in reply(.allow) }

    var response: (WebResponse, @MainActor (WebResponseDecision) -> Void) -> Void = { _, reply in reply(.allow) }

    func decideResponse(_ response: WebResponse, reply: @MainActor (WebResponseDecision) -> Void) {
        self.response(response, reply)
    }

    func decideNavigation(_ navigation: WebNavigation, reply: @MainActor (WebNavigationDecision) -> Void) {
        decide(navigation, reply)
    }
}

/// Every fixture is local; WebKit supplies the real navigation response.
private final class ResponseSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "eglu-response-test"

    static func url(_ path: String) -> URL { URL(string: "\(scheme)://fixture/\(path)")! }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        var headers = ["Content-Type": "text/html", "X-Eglu-Test": "kept",
                       "Accept-CH": "Sec-CH-Prefers-Color-Scheme", "Critical-CH": "Sec-CH-Prefers-Color-Scheme"]
        var body = "<!doctype html><title>response</title><p>fixture</p>"
        if url.lastPathComponent == "attachment" {
            headers["Content-Disposition"] = "attachment; filename=test.html"
        } else if url.lastPathComponent == "unsupported" {
            headers["Content-Type"] = "application/x-eglu-test"
            body = "unsupported content"
        } else if url.lastPathComponent == "frames" {
            body += "<iframe src='\(Self.url("child"))'></iframe>"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data(body.utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// No test download may get a destination, even if cancellation races its response.
@MainActor
private final class NoFileDownloadDelegate: NSObject, WebEngineCore.WebDownloadDelegate {
    func download(_ download: any WebEngineCore.WebDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        completionHandler(nil)
    }
    func downloadDidFinish(_ download: any WebEngineCore.WebDownload) {}
    func download(_ download: any WebEngineCore.WebDownload, didFailWithError error: any Error, resumeData: Data?) {}
}

final class WebKitNavigationAdapterTests: XCTestCase {
    @MainActor
    private func checkDownload(fromResponse: Bool) async throws {
        let view = makeView(schemeHandler: ResponseSchemeHandler())
        let policy = Policy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        let noFile = NoFileDownloadDelegate()
        view.navigationDelegate = adapter
        defer { view.stopLoading(); adapter.tearDown() }
        let received = expectation(description: "navigation became a download")
        let cancelled = expectation(description: "download cancelled without writing a file")
        // WebKit cannot turn a custom scheme's response into a download (it
        // stops the load with WebKitErrorDomain 102 instead), so the response's
        // case is a data: address, which it can.
        let url = fromResponse ? URL(string: "data:text/html,%3Ctitle%3Edownload%3C/title%3E")!
            : ResponseSchemeHandler.url("action-download")
        var actions = 0
        var responses = 0
        policy.decide = { navigation, reply in
            actions += 1
            XCTAssertEqual(navigation.request.url, url)
            reply(fromResponse ? .allow : .download)
        }
        policy.response = { response, reply in
            responses += 1
            XCTAssertEqual(response.response.url, url)
            reply(.download)
        }
        events.onDownload = { download in
            received.fulfill()
            guard let wrapper = download as? WebKitDownload else {
                XCTFail("download must wrap WebKit's own object")
                return
            }
            XCTAssertEqual(wrapper.originalURL, url)
            XCTAssertEqual(wrapper.originalURL, wrapper.originalRequest?.url)
            wrapper.delegate = noFile
            wrapper.cancel { _ in cancelled.fulfill() }
        }
        adapter.load(URLRequest(url: url))
        await fulfillment(of: [received, cancelled], timeout: 10)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(responses, fromResponse ? 1 : 0)
        XCTAssertEqual(events.downloads.count, 1)
        adapter.tearDown()
        XCTAssertEqual(events.downloads.first?.originalURL, url, "the host's download outlives the adapter")
    }

    @MainActor
    func testActionDownloadIsReportedOnceWithOriginalURL() async throws {
        try await checkDownload(fromResponse: false)
    }

    @MainActor
    func testResponseDownloadIsReportedOnceWithOriginalURL() async throws {
        try await checkDownload(fromResponse: true)
    }

    @MainActor
    private func makeView(schemeHandler: ResponseSchemeHandler? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let schemeHandler { config.setURLSchemeHandler(schemeHandler, forURLScheme: ResponseSchemeHandler.scheme) }
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        return WKWebView(frame: .zero, configuration: config)
    }

    @MainActor
    private func dataURL(_ html: String) -> URL {
        URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!
    }

    @MainActor
    private func load(_ html: String, in view: WKWebView, delegate: CaptureDelegate) async throws {
        let done = expectation(description: "data page finished")
        delegate.finished = { done.fulfill() }
        view.load(URLRequest(url: dataURL(html)))
        await fulfillment(of: [done], timeout: 10)
        delegate.finished = nil
        _ = try XCTUnwrap(view.url, "WebKit must load the fixture before its actions can be tested")
    }

    @MainActor
    private func capture(in view: WKWebView, delegate: CaptureDelegate, answer: WKNavigationActionPolicy = .cancel,
                         trigger: () throws -> Void) async rethrows -> WKNavigationAction? {
        let seen = expectation(description: "navigation action captured")
        var captured: WKNavigationAction?
        delegate.action = { action in
            captured = action
            seen.fulfill()
            return answer
        }
        try trigger()
        await fulfillment(of: [seen], timeout: 10)
        delegate.action = nil
        return captured
    }

    /// Waits, up to ten seconds, for `condition` to hold, looked at again
    /// each time WebKit says the history or the loading changed.
    @MainActor
    private func waitUntil(_ view: WKWebView, _ what: String, _ condition: @escaping @MainActor (WKWebView) -> Bool) async {
        guard !condition(view) else { return }
        let done = expectation(description: what)
        done.assertForOverFulfill = false
        let check: @Sendable (WKWebView) -> Void = { view in
            if MainActor.assumeIsolated({ condition(view) }) { done.fulfill() }
        }
        let watches = [
            view.observe(\.canGoForward) { view, _ in check(view) },
            view.observe(\.canGoBack) { view, _ in check(view) },
            view.observe(\.isLoading) { view, _ in check(view) },
        ]
        await fulfillment(of: [done], timeout: 10)
        watches.forEach { $0.invalidate() }
    }

    @MainActor
    private func check(_ action: WKNavigationAction, kind: WebNavigationKind,
                       mainFrame: Bool?, download: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let snapshot = WebKitNavigationAdapter.translate(action)
        XCTAssertEqual(snapshot.kind, kind, file: file, line: line)
        XCTAssertEqual(snapshot.targetIsMainFrame, mainFrame, file: file, line: line)
        XCTAssertEqual(snapshot.request, action.request, file: file, line: line)
        XCTAssertEqual(snapshot.requestsDownload, download, file: file, line: line)
        XCTAssertEqual(snapshot.buttonNumber, action.buttonNumber, file: file, line: line)
        XCTAssertEqual(snapshot.modifiers.contains(.command), action.modifierFlags.contains(.command), file: file, line: line)
        XCTAssertEqual(snapshot.modifiers.contains(.shift), action.modifierFlags.contains(.shift), file: file, line: line)
        XCTAssertEqual(snapshot.modifiers.contains(.option), action.modifierFlags.contains(.option), file: file, line: line)
        XCTAssertEqual(snapshot.modifiers.contains(.control), action.modifierFlags.contains(.control), file: file, line: line)
    }

    /// Lets the response through and waits for WebKit to finish or report that
    /// it cannot display it, so capture never leaves a load mid-change.
    @MainActor
    private func captureResponse(_ path: String) async throws -> (WKWebView, WKNavigationResponse) {
        let view = makeView(schemeHandler: ResponseSchemeHandler())
        let delegate = CaptureDelegate()
        let seen = expectation(description: "offline response captured: \(path)")
        let settled = expectation(description: "offline response settled: \(path)")
        var captured: WKNavigationResponse?
        delegate.response = { response in
            captured = response
            seen.fulfill()
            return .allow
        }
        delegate.finished = { settled.fulfill() }
        delegate.failed = { _ in settled.fulfill() }
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.load(URLRequest(url: ResponseSchemeHandler.url(path)))
        await fulfillment(of: [seen, settled], timeout: 10)
        return (view, try XCTUnwrap(captured))
    }

    @MainActor
    func testResponseTranslationKeepsDisplayableAttachmentAndUnsupportedResponses() async throws {
        for path in ["html", "attachment", "unsupported"] {
            let (view, original) = try await captureResponse(path)
            let policy = Policy()
            let events = NavigationEventsRecorder()
            let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
            defer { adapter.tearDown() }
            var decisions = 0
            policy.response = { response, reply in
                decisions += 1
                XCTAssertTrue(response.response === original.response)
                XCTAssertEqual(response.isForMainFrame, original.isForMainFrame)
                XCTAssertTrue(response.isForMainFrame)
                XCTAssertEqual(response.canShowMIMEType, original.canShowMIMEType)
                XCTAssertEqual(response.canShowMIMEType, path != "unsupported")
                // WebKit hands a custom scheme's response to the navigation
                // delegate as a plain URLResponse (macOS 27), without the
                // handler's status and headers; whatever it hands over is
                // passed on as the same object, so headers WebKit does give
                // (an http page's) read as before.
                if let http = original.response as? HTTPURLResponse {
                    XCTAssertEqual((response.response as? HTTPURLResponse)?.statusCode, http.statusCode)
                    XCTAssertEqual((response.response as? HTTPURLResponse)?.allHeaderFields.count, http.allHeaderFields.count)
                }
                XCTAssertEqual(response.response.mimeType, path == "unsupported" ? "application/x-eglu-test" : "text/html")
                reply(.allow)
            }
            var replies: [WKNavigationResponsePolicy] = []
            adapter.webView(view, decidePolicyFor: original) { replies.append($0) }
            XCTAssertEqual(decisions, 1)
            XCTAssertEqual(replies, [.allow])
        }
    }

    @MainActor
    func testResponseAdapterRepliesSynchronouslyOnceAndCancelsMissingRepliesOrPolicy() async throws {
        let (view, original) = try await captureResponse("html")
        var policy: Policy? = Policy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy!, events: events)
        defer { adapter.tearDown() }
        for expected in [WKNavigationResponsePolicy.allow, .cancel, .download] {
            var events: [String] = []
            policy!.response = { _, reply in
                events.append("policy")
                switch expected {
                case .allow: reply(.allow)
                case .download: reply(.download)
                default: reply(.cancel)
                }
                events.append("after reply")
                reply(.cancel)
            }
            var replies: [WKNavigationResponsePolicy] = []
            adapter.webView(view, decidePolicyFor: original) {
                replies.append($0)
                events.append("handler")
            }
            XCTAssertEqual(replies, [expected])
            XCTAssertEqual(events, ["policy", "handler", "after reply"])
        }
        policy!.response = { _, _ in }
        var replies: [WKNavigationResponsePolicy] = []
        adapter.webView(view, decidePolicyFor: original) { replies.append($0) }
        XCTAssertEqual(replies, [.cancel])
        let weakPolicy = WeakReference(policy!)
        policy = nil
        XCTAssertNil(weakPolicy.value)
        replies = []
        adapter.webView(view, decidePolicyFor: original) { replies.append($0) }
        XCTAssertEqual(replies, [.cancel])
    }

    @MainActor
    func testResponseGuardMapsDecisionsAndIgnoresDuplicateAndLateReplies() {
        // The public policy's reply cannot escape in safe Swift. Exercise the
        // adapter's same guard through its escaping entry, without unsafe casts.
        let response = WebResponse(response: URLResponse(url: ResponseSchemeHandler.url("html"), mimeType: "text/html",
                                                        expectedContentLength: 0, textEncodingName: nil),
                                   isForMainFrame: true, canShowMIMEType: true)
        let cases: [(WebResponseDecision, WKNavigationResponsePolicy)] = [(.allow, .allow), (.cancel, .cancel), (.download, .download)]
        for (decision, expected) in cases {
            var late: (@MainActor (WebResponseDecision) -> Void)?
            var replies: [WKNavigationResponsePolicy] = []
            var events: [String] = []
            WebKitNavigationAdapter.decideResponse(response, ask: { _, reply in
                events.append("policy")
                late = reply
                reply(decision)
                events.append("after reply")
                reply(.cancel)
            }) {
                replies.append($0)
                events.append("handler")
            }
            XCTAssertEqual(replies, [expected])
            XCTAssertEqual(events, ["policy", "handler", "after reply"])
            late?(.allow)
            late?(.download)
            XCTAssertEqual(replies, [expected])
            late = nil
        }
        var late: (@MainActor (WebResponseDecision) -> Void)?
        var replies: [WKNavigationResponsePolicy] = []
        WebKitNavigationAdapter.decideResponse(response, ask: { _, reply in late = reply }) { replies.append($0) }
        XCTAssertEqual(replies, [.cancel])
        late?(.allow)
        late?(.download)
        XCTAssertEqual(replies, [.cancel])
        late = nil
    }

    @MainActor
    func testResponseSelectorsBelongToAdapter() {
        let view = makeView()
        let policy = Policy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        defer { adapter.tearDown() }
        let responseSelector = NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")
        let variant = NSSelectorFromString("webView:decidePolicyForNavigationResponse:unusedVariant:")
        let actionSelector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(adapter.responds(to: responseSelector))
        XCTAssertTrue(adapter.responds(to: actionSelector))
        XCTAssertFalse(adapter.responds(to: variant))
        for selector in [responseSelector, actionSelector,
                         NSSelectorFromString("webView:navigationAction:didBecomeDownload:"),
                         NSSelectorFromString("webView:navigationResponse:didBecomeDownload:")] {
            XCTAssertTrue(adapter.responds(to: selector))
            XCTAssertNil(adapter.forwardingTarget(for: selector))
        }
    }

    @MainActor
    func testResponsePolicyHandlesMainAndChildFrames() async {
        let view = makeView(schemeHandler: ResponseSchemeHandler())
        let policy = Policy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        view.navigationDelegate = adapter
        defer { view.stopLoading(); adapter.tearDown() }
        let done = expectation(description: "main and child frames finished through adapter")
        events.onEvent = { if $0 == .finished { done.fulfill() } }
        var frames: [String: Bool] = [:]
        policy.response = { response, reply in
            let path = response.response.url!.lastPathComponent
            XCTAssertNil(frames[path], "one policy request per response")
            frames[path] = response.isForMainFrame
            XCTAssertTrue(response.canShowMIMEType)
            reply(.allow)
        }
        adapter.load(URLRequest(url: ResponseSchemeHandler.url("frames")))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(frames, ["frames": true, "child": false])
    }

    @MainActor
    func testTranslatorCapturesLinkScriptFormDownloadAndAbsentTarget() async throws {
        let view = makeView()
        let delegate = CaptureDelegate()
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        try await load("""
            <a id="link" href="about:blank#link">link</a>
            <a id="child" href="about:blank#child" target="_blank">child</a>
            <a id="download" href="data:text/plain,download" download="test.txt">download</a>
            <form id="form" action="about:blank" method="post"><input name="field" value="value"></form>
            <iframe name="subframe" src="about:blank"></iframe>
            <a id="subframe" href="about:blank#frame" target="subframe">frame</a>
            """, in: view, delegate: delegate)
        let cases: [(String, WebNavigationKind, Bool?, Bool)] = [
            ("document.getElementById('link').click()", .link, true, false),
            ("location.href = 'about:blank#script'", .other, true, false),
            ("document.getElementById('form').submit()", .form, true, false),
            ("document.getElementById('download').click()", .link, true, true),
            ("document.getElementById('child').click()", .link, nil, false),
            ("document.getElementById('subframe').click()", .link, false, false)
        ]
        for (script, kind, mainFrame, download) in cases {
            let action = await capture(in: view, delegate: delegate) {
                view.evaluateJavaScript(script + "; null;") { _, error in XCTAssertNil(error) }
            }
            let captured = try XCTUnwrap(action)
            check(captured, kind: kind, mainFrame: mainFrame, download: download)
            XCTAssertEqual(WebKitNavigationAdapter.translate(captured).sourceOrigin, .opaque)
            if kind == .form {
                XCTAssertEqual(captured.request.httpMethod, "POST")
            }
        }
    }

    @MainActor
    func testTranslatorCapturesReloadAndBackForwardAndIntactRequest() async throws {
        let view = makeView()
        let delegate = CaptureDelegate()
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        try await load("first", in: view, delegate: delegate)
        try await load("second", in: view, delegate: delegate)
        XCTAssertTrue(view.canGoBack)
        let reloaded = await capture(in: view, delegate: delegate) { view.reload() }
        check(try XCTUnwrap(reloaded), kind: .reload, mainFrame: true, download: false)
        // Back and forward are let through: a cancelled step in the history
        // leaves WebKit's back-forward list mid-change, which made this flaky.
        let back = await capture(in: view, delegate: delegate, answer: .allow) { view.goBack() }
        check(try XCTUnwrap(back), kind: .history, mainFrame: true, download: false)
        await waitUntil(view, "went back") { $0.canGoForward && !$0.isLoading }
        let forward = await capture(in: view, delegate: delegate, answer: .allow) { view.goForward() }
        check(try XCTUnwrap(forward), kind: .history, mainFrame: true, download: false)
        await waitUntil(view, "went forward") { !$0.canGoForward && !$0.isLoading }

        var request = URLRequest(url: dataURL("request"), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 23)
        request.httpMethod = "GET"
        request.setValue("kept", forHTTPHeaderField: "X-Test")
        let captured = await capture(in: view, delegate: delegate) { view.load(request) }
        let action = try XCTUnwrap(captured)
        check(action, kind: .other, mainFrame: true, download: false)
        let snapshot = WebKitNavigationAdapter.translate(action)
        // WebKit may normalize the input request. Preserve the request it actually supplies.
        XCTAssertEqual(snapshot.request.allHTTPHeaderFields, action.request.allHTTPHeaderFields)
        XCTAssertEqual(snapshot.request.httpBody, action.request.httpBody)
        XCTAssertEqual(snapshot.request.cachePolicy, action.request.cachePolicy)
        XCTAssertEqual(snapshot.request.timeoutInterval, action.request.timeoutInterval)
    }

    @MainActor
    func testAdapterRepliesSynchronouslyOnceAndCancelsMissingRepliesOrPolicy() async throws {
        let view = makeView()
        let captureDelegate = CaptureDelegate()
        view.navigationDelegate = captureDelegate
        let captured = await capture(in: view, delegate: captureDelegate) {
            view.load(URLRequest(url: dataURL("captured")))
        }
        let action = try XCTUnwrap(captured)
        var policy: Policy? = Policy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy!, events: events)
        defer { adapter.tearDown() }
        for expected in [WKNavigationActionPolicy.allow, .cancel, .download] {
            var events: [String] = []
            policy!.decide = { _, reply in
                events.append("policy")
                switch expected {
                case .allow: reply(.allow)
                case .download: reply(.download)
                default: reply(.cancel)
                }
                events.append("after reply")
                reply(.cancel)
            }
            var replies: [WKNavigationActionPolicy] = []
            adapter.webView(view, decidePolicyFor: action) {
                replies.append($0)
                events.append("handler")
            }
            XCTAssertEqual(replies, [expected])
            XCTAssertEqual(events, ["policy", "handler", "after reply"])
        }
        policy!.decide = { _, _ in }
        var replies: [WKNavigationActionPolicy] = []
        adapter.webView(view, decidePolicyFor: action) { replies.append($0) }
        XCTAssertEqual(replies, [.cancel])
        let weakPolicy = WeakReference(policy!)
        policy = nil
        XCTAssertNil(weakPolicy.value)
        replies = []
        adapter.webView(view, decidePolicyFor: action) { replies.append($0) }
        XCTAssertEqual(replies, [.cancel])
    }

    @MainActor
    func testAdapterLoadsAndReportsFinishAfterAssignment() async {
        let view = makeView()
        let policy = Policy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        view.navigationDelegate = adapter
        defer { adapter.tearDown() }
        let done = expectation(description: "real WebKit handler allowed load and reported finish")
        events.onEvent = { if $0 == .finished { done.fulfill() } }
        var decisions = 0
        policy.decide = { _, reply in decisions += 1; reply(.allow) }
        let loader: any WebRequestLoading = adapter
        loader.load(URLRequest(url: dataURL("allowed")))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(view.url, dataURL("allowed"))
        XCTAssertTrue(adapter.responds(to: #selector(WKNavigationDelegate.webView(_:didFinish:))))
        XCTAssertFalse(adapter.responds(to: NSSelectorFromString("unimplementedSelector:")))
    }

    @MainActor
    func testAdapterDoesNotAnswerOrForwardUnimplementedSelectorsAndTeardownClearsReferences() {
        let view = makeView()
        let policy = Policy()
        let events = NavigationEventsRecorder()
        let adapter = WebKitNavigationAdapter(view: view, policy: policy, events: events)
        view.navigationDelegate = adapter
        let selectors = [
            #selector(WKNavigationDelegate.webView(_:didReceive:completionHandler:)),
            NSSelectorFromString("webView:decidePolicyForNavigationAction:preferences:decisionHandler:"),
            NSSelectorFromString("_webView:didNotHandleWheelEvent:"),
            NSSelectorFromString("_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:"),
        ]
        for selector in selectors {
            XCTAssertFalse(adapter.responds(to: selector))
            XCTAssertNil(adapter.forwardingTarget(for: selector))
        }
        adapter.tearDown()
        adapter.tearDown()
        XCTAssertNil(view.navigationDelegate)
        // Loading after teardown is inert even while all former owners remain alive.
        adapter.load(URLRequest(url: dataURL("must not load")))
        adapter.loadFile(URL(fileURLWithPath: "/unused.html"), allowingReadAccessTo: URL(fileURLWithPath: "/"))
        XCTAssertNil(view.url)
    }

    @MainActor
    func testAdapterDoesNotRetainViewBeforeTeardown() {
        let policy = Policy()
        weak var weakView: WKWebView?
        let events = NavigationEventsRecorder()
        let adapter = autoreleasepool {
            let view = makeView()
            weakView = view
            return WebKitNavigationAdapter(view: view, policy: policy, events: events)
        }
        XCTAssertNil(weakView)
        XCTAssertTrue(adapter.responds(to: #selector(WKNavigationDelegate.webView(_:didFinish:))))
        adapter.tearDown()
    }
}
