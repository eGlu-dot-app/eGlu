import AppKit
import ObjectiveC
import WebEngineAppKit
import WebEngineCore
import WebKit
import WebKitMacPlugin
import XCTest

private final class UIWeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class UIPresenter: WebDialogPresenter {
    enum Call: Equatable {
        case alert(String, String)
        case confirm(String, String)
        case prompt(String, String?, String)
        case files(Bool, Bool)
    }

    var calls: [Call] = []
    var onAlert: (@MainActor (@escaping @MainActor () -> Void) -> Void)?
    var onConfirm: (@MainActor (@escaping @MainActor (Bool) -> Void) -> Void)?
    var onPrompt: (@MainActor (@escaping @MainActor (String?) -> Void) -> Void)?

    func alert(_ message: String, host: String, done: @escaping @MainActor () -> Void) {
        calls.append(.alert(message, host))
        if let onAlert { onAlert(done) } else { done() }
    }

    func confirm(_ message: String, host: String, done: @escaping @MainActor (Bool) -> Void) {
        calls.append(.confirm(message, host))
        if let onConfirm { onConfirm(done) } else { done(false) }
    }

    func prompt(_ message: String, defaultText: String?, host: String,
                done: @escaping @MainActor (String?) -> Void) {
        calls.append(.prompt(message, defaultText, host))
        if let onPrompt { onPrompt(done) } else { done(nil) }
    }

    func openFiles(allowsMultiple: Bool, allowsDirectories: Bool,
                   done: @escaping @MainActor ([URL]?) -> Void) {
        calls.append(.files(allowsMultiple, allowsDirectories))
        done(nil)
    }
}

@MainActor
private final class UIEvents: WebPageUIEvents {
    var closed = 0
    var links: [URL?] = []
    var scrolls: [NSEvent] = []

    func childRequested(_ request: any WebChildRequest) -> (any WebEngineSurface)? { nil }
    func closeRequested() { closed += 1 }
    func contextMenuOpening(link: URL?) { links.append(link) }
    func scrollNotHandled(_ event: NSEvent) { scrolls.append(event) }
}

@MainActor
private final class UIResult: NSObject, WKScriptMessageHandler {
    var values: [WebJSON] = []
    var hosts: [String] = []
    var frame: WKFrameInfo?
    var received: (() -> Void)?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                          didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            values.append(WebJSON(foundation: message.body))
            hosts.append(message.frameInfo.securityOrigin.host)
            frame = message.frameInfo
            received?()
        }
    }
}

@MainActor
private final class UIFixture {
    let view: WKWebView
    let adapter: WebKitUIAdapter
    let events = UIEvents()
    let result = UIResult()

    init(presenter: any WebDialogPresenter) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(result, name: "result")
        view = WKWebView(frame: .zero, configuration: configuration)
        adapter = WebKitUIAdapter(view: view, events: events, presenter: presenter)
        view.uiDelegate = adapter
    }

    func load(_ script: String, base: URL? = URL(string: "http://example.test/")) {
        // All content is inline. The base supplies an origin without a request.
        view.loadHTMLString("<!doctype html><script>\(script)</script>", baseURL: base)
    }

    func tearDown() {
        view.stopLoading()
        view.uiDelegate = nil
        adapter.tearDown()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "result")
        result.received = nil
    }
}

// These stand in for WebKit's private objects without importing its SPI.
@MainActor
private final class UIHitTest: NSObject {
    @objc let absoluteLinkURL: URL
    init(_ link: URL) { absoluteLinkURL = link }
}

@MainActor
private final class UIElement: NSObject {
    @objc let hitTestResult: NSObject
    init(_ hit: NSObject) { hitTestResult = hit }
}

final class WebKitUIAdapterTests: XCTestCase {
    @MainActor
    func testPageScriptsReachPresenterAndReceiveEveryAnswer() async {
        let presenter = UIPresenter()
        var confirms = [true, false]
        var prompts: [String?] = ["typed answer", nil]
        presenter.onConfirm = { $0(confirms.removeFirst()) }
        presenter.onPrompt = { $0(prompts.removeFirst()) }
        let fixture = UIFixture(presenter: presenter)
        defer { fixture.tearDown() }
        let finished = expectation(description: "script continued after all dialogs")
        fixture.result.received = { finished.fulfill() }
        fixture.load("""
            alert('alert message');
            const yes = confirm('confirm yes');
            const no = confirm('confirm no');
            const text = prompt('prompt text', 'default text');
            const cancelled = prompt('prompt cancel');
            webkit.messageHandlers.result.postMessage([yes, no, text, cancelled]);
            """)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(presenter.calls, [
            .alert("alert message", "example.test"),
            .confirm("confirm yes", "example.test"),
            .confirm("confirm no", "example.test"),
            .prompt("prompt text", "default text", "example.test"),
            .prompt("prompt cancel", "", "example.test")
        ])
        XCTAssertEqual(fixture.result.values, [.array([.bool(true), .bool(false), .string("typed answer"), .null])])
    }

    @MainActor
    func testNoBasePassesTheHostWebKitReportsWithoutOriginConversion() async throws {
        let presenter = UIPresenter()
        let fixture = UIFixture(presenter: presenter)
        defer { fixture.tearDown() }
        let finished = expectation(description: "dialogs without a base finished")
        fixture.result.received = { finished.fulfill() }
        fixture.load("""
            alert('alert'); confirm('confirm'); prompt('prompt', 'default');
            webkit.messageHandlers.result.postMessage('finished');
            """, base: nil)
        await fulfillment(of: [finished], timeout: 10)
        // Compare with the same document's real frame host. This also works
        // if a WebKit version assigns a nonempty host to loadHTMLString.
        let host = try XCTUnwrap(fixture.result.hosts.first)
        XCTAssertEqual(presenter.calls, [.alert("alert", host), .confirm("confirm", host), .prompt("prompt", "default", host)])
        XCTAssertEqual(fixture.result.values, [.string("finished")])
    }

    @MainActor
    func testEachDialogCanAnswerAfterItsCallbackReturns() async throws {
        for kind in ["alert", "confirm", "prompt"] {
            let presenter = UIPresenter()
            let asked = expectation(description: "\(kind) held by presenter")
            let finished = expectation(description: "\(kind) script received later reply")
            var release: (@MainActor () -> Void)?
            presenter.onAlert = { done in release = { done() }; asked.fulfill() }
            presenter.onConfirm = { done in release = { done(true) }; asked.fulfill() }
            presenter.onPrompt = { done in release = { done("later") }; asked.fulfill() }
            let fixture = UIFixture(presenter: presenter)
            defer { fixture.tearDown() }
            fixture.result.received = { finished.fulfill() }
            fixture.load("""
                const answer = \(kind)('held');
                webkit.messageHandlers.result.postMessage(\(kind == "alert" ? "'continued'" : "answer"));
                """)
            await fulfillment(of: [asked], timeout: 10)
            XCTAssertTrue(fixture.result.values.isEmpty)
            let reply = try XCTUnwrap(release)
            release = nil
            reply()
            await fulfillment(of: [finished], timeout: 10)
            let expected: WebJSON = kind == "alert" ? .string("continued") : kind == "confirm" ? .bool(true) : .string("later")
            XCTAssertEqual(fixture.result.values, [expected])
        }
    }

    @MainActor
    func testReleasedPresenterUsesDefaultsAndScriptContinues() async throws {
        var presenter: UIPresenter? = UIPresenter()
        let weakPresenter = UIWeakReference(try XCTUnwrap(presenter))
        let fixture = UIFixture(presenter: try XCTUnwrap(presenter))
        defer { fixture.tearDown() }
        presenter = nil
        XCTAssertNil(weakPresenter.value)
        let finished = expectation(description: "missing presenter answered all dialogs")
        fixture.result.received = { finished.fulfill() }
        fixture.load("""
            alert('absent');
            webkit.messageHandlers.result.postMessage([confirm('absent'), prompt('absent')]);
            """)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(fixture.result.values, [.array([.bool(false), .null])])
    }

    @MainActor
    func testDirectDialogCallbacksReplySynchronouslyIncludingAfterTeardown() async throws {
        let presenter = UIPresenter()
        let fixture = UIFixture(presenter: presenter)
        defer { fixture.tearDown() }
        let loaded = expectation(description: "real frame captured for direct callbacks")
        fixture.result.received = { loaded.fulfill() }
        fixture.load("webkit.messageHandlers.result.postMessage('loaded');")
        await fulfillment(of: [loaded], timeout: 10)
        let frame = try XCTUnwrap(fixture.result.frame)
        presenter.onConfirm = { $0(true) }
        presenter.onPrompt = { $0("answer") }
        var alertReplies = 0
        var confirmReplies: [Bool] = []
        var promptReplies: [String?] = []
        fixture.adapter.webView(fixture.view, runJavaScriptAlertPanelWithMessage: "alert", initiatedByFrame: frame) {
            alertReplies += 1
        }
        fixture.adapter.webView(fixture.view, runJavaScriptConfirmPanelWithMessage: "confirm", initiatedByFrame: frame) {
            confirmReplies.append($0)
        }
        fixture.adapter.webView(fixture.view, runJavaScriptTextInputPanelWithPrompt: "prompt", defaultText: nil,
                                initiatedByFrame: frame) { promptReplies.append($0) }
        XCTAssertEqual(alertReplies, 1)
        XCTAssertEqual(confirmReplies, [true])
        XCTAssertEqual(promptReplies, ["answer"])
        XCTAssertEqual(presenter.calls, [.alert("alert", "example.test"), .confirm("confirm", "example.test"),
                                         .prompt("prompt", nil, "example.test")])
        fixture.adapter.tearDown()
        fixture.adapter.webView(fixture.view, runJavaScriptAlertPanelWithMessage: "absent", initiatedByFrame: frame) {
            alertReplies += 1
        }
        fixture.adapter.webView(fixture.view, runJavaScriptConfirmPanelWithMessage: "absent", initiatedByFrame: frame) {
            confirmReplies.append($0)
        }
        fixture.adapter.webView(fixture.view, runJavaScriptTextInputPanelWithPrompt: "absent", defaultText: nil,
                                initiatedByFrame: frame) { promptReplies.append($0) }
        XCTAssertEqual(alertReplies, 2)
        XCTAssertEqual(confirmReplies, [true, false])
        XCTAssertEqual(promptReplies, ["answer", nil])
        XCTAssertEqual(presenter.calls.count, 3)
    }

    @MainActor
    func testExactlyTheEightUIDelegateSelectorsAreImplemented() throws {
        let presenter = UIPresenter()
        let fixture = UIFixture(presenter: presenter)
        defer { fixture.tearDown() }
        let expected: Set<String> = [
            "_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:",
            "_webView:didNotHandleWheelEvent:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            "webViewDidClose:",
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:"
        ]
        for name in expected {
            let selector = NSSelectorFromString(name)
            XCTAssertTrue(fixture.adapter.responds(to: selector), name)
            XCTAssertNil(fixture.adapter.forwardingTarget(for: selector), name)
        }
        let uiProtocol = try XCTUnwrap(objc_getProtocol("WKUIDelegate"))
        for required in [true, false] {
            var count: UInt32 = 0
            guard let methods = protocol_copyMethodDescriptionList(uiProtocol, required, true, &count) else { continue }
            defer { free(methods) }
            for index in 0..<Int(count) {
                let selector = try XCTUnwrap(methods[index].name)
                let name = NSStringFromSelector(selector)
                XCTAssertEqual(fixture.adapter.responds(to: selector), expected.contains(name), name)
            }
        }
        XCTAssertFalse(fixture.adapter.responds(to: NSSelectorFromString(
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
        XCTAssertFalse(fixture.adapter.responds(to: NSSelectorFromString("unimplementedSelector:")))
    }

    @MainActor
    func testCloseContextMenuAndUnusedScrollAreForwardedSynchronously() throws {
        let presenter = UIPresenter()
        let fixture = UIFixture(presenter: presenter)
        defer { fixture.tearDown() }
        fixture.adapter.webViewDidClose(fixture.view)
        XCTAssertEqual(fixture.events.closed, 1)
        let menu = NSMenu()
        let link = try XCTUnwrap(URL(string: "https://example.test/file"))
        let elements: [NSObject?] = [UIElement(UIHitTest(link)), UIElement(NSObject()), NSObject(), nil]
        for (index, element) in elements.enumerated() {
            var replies = 0
            fixture.adapter._webView(fixture.view, getContextMenuFromProposedMenu: menu,
                                     forElement: element, userInfo: nil) { answer in
                replies += 1
                XCTAssertTrue(answer === menu)
                XCTAssertEqual(fixture.events.links.count, index + 1)
            }
            XCTAssertEqual(replies, 1)
        }
        XCTAssertEqual(fixture.events.links, [link, nil, nil, nil])
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    subtype: 0, data1: 0, data2: 0))
        fixture.adapter._webView(fixture.view, didNotHandleWheelEvent: event)
        XCTAssertTrue(fixture.events.scrolls.first === event)
        fixture.adapter.tearDown()
        fixture.adapter.tearDown()
        fixture.adapter.webViewDidClose(fixture.view)
        fixture.adapter._webView(fixture.view, didNotHandleWheelEvent: event)
        XCTAssertEqual(fixture.events.closed, 1)
        XCTAssertEqual(fixture.events.scrolls.count, 1)
        var answered = false
        fixture.adapter._webView(fixture.view, getContextMenuFromProposedMenu: menu,
                                 forElement: UIElement(UIHitTest(link)), userInfo: nil) {
            answered = true
            XCTAssertTrue($0 === menu)
        }
        XCTAssertTrue(answered)
        XCTAssertEqual(fixture.events.links.count, 4)
    }

    @MainActor
    func testAdapterDoesNotRetainItsViewOrEvents() throws {
        let presenter = UIPresenter()
        var events: UIEvents? = UIEvents()
        let weakEvents = UIWeakReference(try XCTUnwrap(events))
        weak var weakView: WKWebView?
        let adapter = try autoreleasepool {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            weakView = view
            return WebKitUIAdapter(view: view, events: try XCTUnwrap(events), presenter: presenter)
        }
        events = nil
        XCTAssertNil(weakEvents.value)
        XCTAssertNil(weakView)
        adapter.tearDown()
    }
}
