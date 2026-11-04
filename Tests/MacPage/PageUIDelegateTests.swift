import AppKit
import ObjectiveC
import WebEngineCore
import WebKit
import WebKitMacPlugin
import XCTest
@testable import eGluMac

/// WebKit's UI delegate for a Mac page (Docs/EngineSplitPlan.md, 7, step
/// 7b), through a real page and WebKit: the view's UI delegate is the
/// engine's adapter (`WebKitUIAdapter`), not the page, and answers exactly
/// the questions the page answered before; a script's alert, confirm and
/// prompt reach the page as their presenter, which holds each while its
/// host isn't showing the page, tells the host, shows nothing, and answers
/// it as cancelled when the page goes elsewhere or is torn down; a script's
/// window.close() in a window a script opened reaches that window's host;
/// and the context menu's element gives the page its link, or none.
///
/// Every page is a data: page or about:blank in a store that keeps
/// nothing: no network. Every host here says it is not showing the page and
/// has no window, so no dialog is ever shown: the page only ever holds one.
/// A dialog is started from the page's own world without waiting for it
/// (`start`), and its script's answer is waited for once the page has let
/// it go. The context menu's question is WebKit's private one, asked of the
/// view's UI delegate by the test, with stand-ins for WebKit's private
/// element and hit test result.
///
/// Not here: a file field's panel (`NSOpenPanel`, shown modally with no
/// window), which the WebKitMacPlugin package's tests (WebKitUIAdapterTests)
/// cover with a presenter of their own; a dialog shown on a host's window
/// (it would put an alert on screen); an extension's page, whose UI
/// delegate is ExtensionPageDelegate in front of the adapter (it needs an
/// installed extension); a website's window (PageChildTests); and what the
/// page's swipe does with a scroll the page left unused (PageSwipe), of
/// which only the question is checked here.
@MainActor
final class PageUIDelegateTests: PageTestCase {
    /// The hosts made here, with the children they made; let go of after each test.
    private var hosts: [UIHost] = []

    override func tearDown() async throws {
        for host in hosts {
            for child in host.made { child.tearDown() }
        }
        hosts.removeAll()
        try await super.tearDown()
    }

    // MARK: The delegate

    /// The view's UI delegate is the adapter, not the page, which is no
    /// longer one: it answers exactly the questions the page answered
    /// before, WebKit's two private ones among them, forwards none, and
    /// answers none of WebKit's others (the camera's and the microphone's
    /// among them), which WebKit then answers itself; the page answers none.
    func testTheViewsUIDelegateIsTheAdapterWithExactlyThePagesQuestions() throws {
        let page = makePage()
        let delegate = try XCTUnwrap(page.view.uiDelegate as? NSObject, "the view has no UI delegate")
        XCTAssertTrue(delegate is WebKitUIAdapter, "the view's UI delegate is a \(type(of: delegate))")
        XCTAssertFalse(delegate === page, "the page is still the view's UI delegate")
        XCTAssertFalse((page as AnyObject) is WKUIDelegate, "the page is still a UI delegate")

        for name in Self.questions {
            let selector = NSSelectorFromString(name)
            XCTAssertTrue(delegate.responds(to: selector), "the delegate doesn't answer \(name)")
            XCTAssertNil(delegate.forwardingTarget(for: selector), "the delegate forwards \(name)")
            XCTAssertFalse(page.responds(to: selector), "the page still answers \(name)")
        }

        let uiDelegate = try XCTUnwrap(objc_getProtocol("WKUIDelegate"))
        var publicQuestions = 0
        for required in [true, false] {
            var count: UInt32 = 0
            guard let methods = protocol_copyMethodDescriptionList(uiDelegate, required, true, &count) else { continue }
            defer { free(methods) }
            for index in 0..<Int(count) {
                guard let selector = methods[index].name else { continue }
                let name = NSStringFromSelector(selector)
                publicQuestions += 1
                XCTAssertEqual(delegate.responds(to: selector), Self.questions.contains(name), name)
            }
        }
        XCTAssertGreaterThan(publicQuestions, Self.questions.count, "WebKit's UI delegate has too few questions to tell")

        XCTAssertEqual(Self.webKitMethods(of: delegate), Self.questions, "the delegate's own WebKit methods")
        let media = NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")
        XCTAssertFalse(delegate.responds(to: media))
        XCTAssertFalse(page.responds(to: media))
    }

    // MARK: A script's dialogs

    /// A script's alert, on a page its host isn't showing, is held: the
    /// page has a dialog, the host is told while it has, the script waits,
    /// and nothing is shown, even when the page is asked to show what it
    /// holds; the page going elsewhere answers it, and the script goes on.
    func testAnAlertIsHeldThenAnsweredWhenThePageGoesElsewhere() async throws {
        let (page, host) = await asking()
        let windows = Self.visibleWindows()

        let run = start("alert('Hello from the page'); 'went on'", in: page)
        await waitFor("the alert held") { page.hasPendingDialog }
        assertHeld(page, host, run, windows)

        page.load(Self.address("Elsewhere"))
        XCTAssertFalse(page.hasPendingDialog, "the alert outlived the page's going elsewhere")
        await fulfillment(of: [run.finished], timeout: 10)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.value as? String, "went on")
        await waitForPage(page, titled: "Elsewhere")
        XCTAssertFalse(page.hasPendingDialog)
        XCTAssertEqual(Self.visibleWindows(), windows, "a window was shown")
    }

    /// A script's confirm, held the same way, is answered as cancelled
    /// when the page goes elsewhere: the script's confirm gives false.
    func testAConfirmIsHeldThenCancelledWhenThePageGoesElsewhere() async throws {
        let (page, host) = await asking()
        let windows = Self.visibleWindows()

        let run = start("confirm('Leave this page?')", in: page)
        await waitFor("the confirm held") { page.hasPendingDialog }
        assertHeld(page, host, run, windows)

        page.load(Self.address("Elsewhere"))
        XCTAssertFalse(page.hasPendingDialog, "the confirm outlived the page's going elsewhere")
        await fulfillment(of: [run.finished], timeout: 10)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.value as? Bool, false, "the script's confirm gave \(String(describing: run.value))")
        await waitForPage(page, titled: "Elsewhere")
        XCTAssertEqual(Self.visibleWindows(), windows, "a window was shown")
    }

    /// A script's prompt, held the same way, is answered as cancelled when
    /// the page is torn down: the script's prompt gives null, not the
    /// default text.
    func testAPromptIsHeldThenCancelledWhenThePageIsTornDown() async throws {
        let host = UIHost()
        hosts.append(host)
        // Torn down here, once, and not again after the test.
        let page = Page(tab: UUID(), space: UUID(), configuration: Self.keepingNothing())
        var tornDown = false
        defer { if !tornDown { page.tearDown() } }
        page.host = host
        await load(page, "Asking")
        host.told.removeAll()
        let windows = Self.visibleWindows()

        let run = start("JSON.stringify(prompt('Your name?', 'Default name'))", in: page)
        await waitFor("the prompt held") { page.hasPendingDialog }
        assertHeld(page, host, run, windows)

        page.tearDown()
        tornDown = true
        XCTAssertFalse(page.hasPendingDialog, "the prompt outlived the page")
        await fulfillment(of: [run.finished], timeout: 10)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.value as? String, "null", "the script's prompt gave \(String(describing: run.value))")
        XCTAssertEqual(Self.visibleWindows(), windows, "a window was shown")
    }

    // MARK: A window's closing

    /// window.close() in a window the page's script opened reaches that
    /// window's host as the child's closing, and the opener's not at all.
    func testWindowCloseInAWindowAScriptOpenedReachesItsHost() async throws {
        let configuration = Self.keepingNothing()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let page = makePage(configuration: configuration)
        let host = UIHost()
        host.makesChildren = true
        hosts.append(host)
        page.host = host
        await load(page, "Opener")

        let opened = try await page.view.evaluateJavaScript(
            "window.__opened = window.open('about:blank'); window.__opened !== null")
        XCTAssertEqual(opened as? Bool, true, "window.open gave the script no window")
        let child = try XCTUnwrap(host.made.first)
        XCTAssertFalse(child === page)
        XCTAssertTrue(child.view.uiDelegate is WebKitUIAdapter, "the child's UI delegate isn't the adapter")
        await waitFor("the child committed") { child.committed != nil }
        XCTAssertTrue(host.closed.isEmpty)

        _ = try await child.view.evaluateJavaScript("window.close(); 1")
        await waitFor("the child closed") { host.closed.contains { $0 === child } }
        XCTAssertEqual(host.closed.count, 1)
        XCTAssertFalse(host.closed.contains { $0 === page }, "the opener closed")
    }

    // MARK: The context menu

    /// WebKit's private question before a context menu opens: the page
    /// keeps the element's link (for "Handoff Linked File"), and the menu
    /// proposed is the one shown. An element with no hit test result, one
    /// whose hit test result has no link, and no element at all leave the
    /// page with none, and each gets its menu back too.
    func testTheContextMenusElementGivesThePageItsLink() throws {
        let page = makePage()
        let delegate = try XCTUnwrap(page.view.uiDelegate as? NSObject, "the view has no UI delegate")
        let question = NSSelectorFromString("_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:")
        guard delegate.responds(to: question) else {
            return XCTFail("the view's UI delegate doesn't answer WebKit's context menu question")
        }
        // The delegate answers the selector without saying it conforms, so it
        // is asked through a protocol of the test's with that selector.
        let asked = unsafeBitCast(delegate, to: ContextMenuQuestion.self)
        let link = URL(string: "https://eglu-tests.invalid/paper.pdf")!
        XCTAssertNil(try linkForMenu(page))

        let elements: [(String, NSObject?, URL?)] = [
            ("a link's element", StandInElement(StandInHitTest(link)), link),
            ("an element with no hit test result", NSObject(), nil),
            ("a link's element again", StandInElement(StandInHitTest(link)), link),
            ("an element whose hit test result has no link", StandInElement(NSObject()), nil),
            ("a link's element once more", StandInElement(StandInHitTest(link)), link),
            ("no element", nil, nil),
        ]
        for (what, element, expected) in elements {
            let proposed = NSMenu(title: "Proposed")
            var given: [NSMenu?] = []
            asked.getContextMenu(page.view, proposedMenu: proposed, element: element, userInfo: nil) { given.append($0) }
            XCTAssertEqual(given.count, 1, "answers for \(what)")
            XCTAssertTrue(given.first.flatMap { $0 } === proposed, "the menu shown for \(what) isn't the one proposed")
            XCTAssertEqual(try linkForMenu(page), expected, what)
        }
    }

    // MARK: Helpers

    /// The questions the page answered as the view's UI delegate before
    /// 7b, which the adapter answers now.
    private static let questions: Set<String> = [
        "_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:",
        "_webView:didNotHandleWheelEvent:",
        "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
        "webViewDidClose:",
        "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
        "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
    ]

    /// The methods named for WebKit's questions (webView..., _webView...)
    /// that the object's own class has.
    private static func webKitMethods(of object: NSObject) -> Set<String> {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(object_getClass(object), &count) else { return [] }
        defer { free(methods) }
        return Set((0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }
            .filter { $0.hasPrefix("webView") || $0.hasPrefix("_webView") })
    }

    /// The windows on screen now.
    private static func visibleWindows() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    }

    /// A page named Asking, loaded, its host a `UIHost`, which has been told nothing since.
    private func asking() async -> (Page, UIHost) {
        let page = makePage()
        let host = UIHost()
        hosts.append(host)
        page.host = host
        await load(page, "Asking")
        host.told.removeAll()
        return (page, host)
    }

    /// `script` run in the page's own world, not waited for: what it gave
    /// back, once it has (`finished`).
    private func start(_ script: String, in page: Page) -> ScriptRun {
        let run = ScriptRun(finished: expectation(description: "the script finished"))
        page.view.evaluateJavaScript(script) { value, error in
            run.value = value
            run.error = error
            run.isFinished = true
            run.finished.fulfill()
        }
        return run
    }

    /// The page holds a dialog its host was told of, the script waits for
    /// it, nothing is on screen that wasn't, and asking the page to show
    /// what it holds shows nothing, as its host isn't showing it.
    private func assertHeld(_ page: Page, _ host: UIHost, _ run: ScriptRun, _ windows: Set<ObjectIdentifier>,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(page.hasPendingDialog, file: file, line: line)
        XCTAssertTrue(host.told.contains(true), "the host wasn't told of the dialog", file: file, line: line)
        XCTAssertFalse(run.isFinished, "the script didn't wait for its dialog", file: file, line: line)
        XCTAssertFalse(host.isShowing(page), file: file, line: line)
        XCTAssertNil(host.hostWindow, file: file, line: line)
        XCTAssertNil(NSApp.modalWindow, "a dialog is shown modally", file: file, line: line)
        XCTAssertEqual(Self.visibleWindows(), windows, "a window was shown", file: file, line: line)
        page.reviewPendingDialog()
        XCTAssertTrue(page.hasPendingDialog, "the page let its dialog go for a host not showing it",
                      file: file, line: line)
        XCTAssertFalse(run.isFinished, file: file, line: line)
        XCTAssertEqual(Self.visibleWindows(), windows, "a window was shown", file: file, line: line)
    }

    /// The link the page keeps for the context menu (Page.linkForMenu),
    /// which nothing the page shows depends on alone.
    private func linkForMenu(_ page: Page, file: StaticString = #filePath, line: UInt = #line) throws -> URL? {
        let child = try XCTUnwrap(Mirror(reflecting: page).children.first { $0.label == "linkForMenu" },
                                  "Page keeps no linkForMenu", file: file, line: line)
        return try XCTUnwrap(child.value as? URL?, "Page's linkForMenu is a \(Swift.type(of: child.value))",
                             file: file, line: line)
    }

    /// Waits, up to `timeout`, for `condition`, looked at every 20 ms: for
    /// what the page keeps, which WebKit doesn't report a change of.
    private func waitFor(_ what: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !condition() { XCTFail("\(what): not by \(timeout) s", file: file, line: line) }
    }
}

/// A script started without waiting for it, and what it gave back.
@MainActor
private final class ScriptRun {
    let finished: XCTestExpectation
    var isFinished = false
    var value: Any?
    var error: (any Error)?

    init(finished: XCTestExpectation) { self.finished = finished }
}

/// WebKit's private question before a context menu opens, as the view
/// asks its UI delegate (WKUIDelegatePrivate.h).
@objc private protocol ContextMenuQuestion {
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func getContextMenu(_ webView: WKWebView, proposedMenu: NSMenu, element: NSObject?, userInfo: Any?,
                        completionHandler: @escaping (NSMenu?) -> Void)
}

/// Stands in for WebKit's private _WKContextMenuElementInfo: its hit test result.
private final class StandInElement: NSObject {
    @objc let hitTestResult: NSObject
    init(_ result: NSObject) { hitTestResult = result }
}

/// Stands in for WebKit's private _WKHitTestResult: the link it is on.
private final class StandInHitTest: NSObject {
    @objc let absoluteLinkURL: URL
    init(_ link: URL) { absoluteLinkURL = link }
}

/// A host that keeps, each time the page told it of a change, whether the
/// page held a dialog then; makes the window a page asks for with the
/// app's engine where `makesChildren`, and none otherwise; and keeps each
/// page that told it it closed. For everything else, the least a host
/// does: it shows nothing, and has no window.
@MainActor
private final class UIHost: PageHost {
    var told: [Bool] = []
    var makesChildren = false
    /// The children made, in order, each the one given back.
    private(set) var made: [Page] = []
    private(set) var closed: [Page] = []

    func page(_ page: Page, openChild request: any WebChildRequest) -> Page? {
        guard makesChildren else { return nil }
        let child = Session.shared.engine.makePage(tab: UUID(), space: page.space, source: .child(request))
        child.host = self
        made.append(child)
        return child
    }

    func pageDidChange(_ page: Page) { told.append(page.hasPendingDialog) }
    func isShowing(_ page: Page) -> Bool { false }
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool { false }
    func pageDidClose(_ page: Page) { closed.append(page) }
    var hostWindow: NSWindow? { nil }
}
