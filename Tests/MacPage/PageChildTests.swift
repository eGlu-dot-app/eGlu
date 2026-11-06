import PadCore
import WebEngineCore
import WebKit
import WebKitMacPlugin
import XCTest
@testable import eGluMac

/// A window a website opens (Docs/EngineSplitPlan.md, 7, step 5): WebKit's
/// question reaches the page's host once, as a `WebChildRequest` with the
/// navigation and the size asked for; the page the host makes from it with
/// the app's engine is the one WebKit shows, tied to the page that opened
/// it, and marked as opened; a host that makes none rejects it; Pages makes
/// a tab's child from the request; and another app's link never reaches
/// the host.
///
/// Every page here is a data: page or about:blank, in a store that keeps
/// nothing, which the child shares: no network, no lasting website data. A
/// child a site asks for at a data: address is refused by WebKit itself and
/// commits nothing; a child that shows a document is at about:blank, which
/// the opener's script fills. Another app's link is
/// asked for only from a script, in a page no window shows, which eGlu
/// leaves without opening the app or asking (AppLink); the test checks it
/// is a script's before asking.
///
/// Not here: a window opened on an extension's page from a website (it
/// needs an installed extension: Extensions.isExtensionPage), Open Link in
/// Peek and document picture in picture (a window's menu and a site's
/// picture.js, each a real window), and the hosts' own choices of a tab, a
/// Peek, a pop-up or a little window (WindowModel, PeekPage, Popup,
/// LittleWindow), each of which shows a real window.
@MainActor
final class PageChildTests: PageTestCase {
    /// The hosts made here, with the children and tabs they made; let go of after each test.
    private var hosts: [ChildHost] = []

    override func tearDown() async throws {
        for host in hosts {
            for tab in host.tabs where Session.shared.workspace.tab(tab) != nil {
                Session.shared.closeTab(tab)
            }
            for child in host.made where !host.tabs.contains(child.tab) {
                child.tearDown()
            }
        }
        hosts.removeAll()
        try await super.tearDown()
    }

    // MARK: The request

    /// window.open from the page's script reaches the host once, with the
    /// address, as a script's from the page itself to no frame yet, with no
    /// size, and with the opener's own store.
    func testWindowOpenAsksTheHostOnce() async throws {
        let (page, host) = await opener()
        let url = Self.address("Child")

        let opened = try await open(url, from: page)
        XCTAssertEqual(opened, true, "window.open gave the script no window")
        XCTAssertEqual(host.requests.count, 1)
        let request = try XCTUnwrap(host.requests.first)
        XCTAssertEqual(request.navigation.request.url, url)
        XCTAssertEqual(request.navigation.sourceIsMainFrame, true)
        XCTAssertNil(request.navigation.targetIsMainFrame)
        XCTAssertEqual(request.navigation.kind, .other)
        XCTAssertEqual(request.features, WebWindowFeatures(width: nil, height: nil))
        let webKit = try XCTUnwrap(request as? WebKitChildRequest, "the request isn't WebKit's")
        XCTAssertTrue(webKit.configuration.websiteDataStore === page.view.configuration.websiteDataStore,
                      "the child's configuration isn't in the opener's store")
    }

    /// window.open with a width and a height gives the host that size.
    func testWindowOpenWithASizeGivesTheSize() async throws {
        let (page, host) = await opener()
        let url = Self.address("Sized")

        let opened = try await open(url, from: page, features: "width=300,height=200")
        XCTAssertEqual(opened, true)
        XCTAssertEqual(host.requests.count, 1)
        let request = try XCTUnwrap(host.requests.first)
        XCTAssertEqual(request.navigation.request.url, url)
        XCTAssertEqual(request.features, WebWindowFeatures(width: 300, height: 200))
    }

    // MARK: The child

    /// The page the host makes is the one WebKit shows: it commits the
    /// address asked for, the title the opener's script writes into the
    /// window it holds reaches it, it has an opener, and that window, closed
    /// from the opener, closes the child.
    func testTheHostsChildIsTheWindowWebKitShows() async throws {
        let (page, host) = await opener()
        let at = page.view.url
        let url = Self.blank

        let opened = try await open(url, from: page)
        XCTAssertEqual(opened, true)
        let child = try XCTUnwrap(host.made.first)
        XCTAssertFalse(child === page)
        XCTAssertTrue(child.host === host)
        await waitFor("the child committed") { child.committed != nil }
        XCTAssertEqual(child.committed, url, "the child's commit didn't reach it")
        XCTAssertEqual(child.view.url, url)
        _ = try await page.view.evaluateJavaScript("window.__opened.document.title = 'Shown'; 1")
        await waitForPage(child, titled: "Shown")
        XCTAssertEqual(child.state.title, "Shown")
        XCTAssertNil(child.failure)
        XCTAssertEqual(page.view.url, at, "the opener went somewhere")

        let hasOpener = try await child.view.evaluateJavaScript("window.opener !== null")
        XCTAssertEqual(hasOpener as? Bool, true, "the child lost its tie to the page that opened it")
        let live = try await page.view.evaluateJavaScript("window.__opened !== null && window.__opened.closed === false")
        XCTAssertEqual(live as? Bool, true, "the opener doesn't see the window it opened")

        _ = try await page.view.evaluateJavaScript("window.__opened.close(); 1")
        await waitFor("the child closed") { host.closed.contains { $0 === child } }
        XCTAssertFalse(host.closed.contains { $0 === page }, "the opener closed")
    }

    /// The child is marked as opened by another page: told of another app's
    /// link before anything has committed in it, it closes itself, as a
    /// window opened only to go to another app does. A page no other page
    /// opened, told the same, stays. (The child is at a data: address,
    /// which WebKit refuses a site, so nothing commits in it.)
    func testTheChildIsMarkedOpened() async throws {
        let (page, host) = await opener()

        let opened = try await open(Self.address("Refused"), from: page)
        XCTAssertEqual(opened, true)
        XCTAssertEqual(host.requests.count, 1)
        let child = try XCTUnwrap(host.made.first)
        _ = try await page.view.evaluateJavaScript("1")
        XCTAssertNil(child.committed, "the child committed a document, so the mark can't be seen")

        let control = makePage()
        control.host = host
        // A script's, never a click's, on pages no window shows: eGlu leaves
        // the link (AppLink.answer) without opening anything or asking.
        XCTAssertFalse(host.isShowing(child))
        let mailto = Self.navigation(to: Self.appLink)
        XCTAssertEqual(decide(control, mailto), .cancel)
        XCTAssertTrue(host.closed.isEmpty, "a page no other page opened closed itself")
        XCTAssertEqual(decide(child, mailto), .cancel)
        XCTAssertEqual(host.closed.count, 1)
        XCTAssertTrue(host.closed.first === child, "the child isn't marked as opened")
        XCTAssertNil(child.refusedAppLink)
    }

    /// A host that makes no page rejects the window: window.open gives the
    /// script null, and nothing is left: no page, no tab, no Peek, no
    /// picture window, and the opener where it was.
    func testAHostThatMakesNoneRejects() async throws {
        let (page, host) = await opener()
        host.answer = .reject
        let at = page.view.url
        let live = Session.shared.pages.live.count
        let tabs = Self.tabCount()

        let rejected = try await page.view.evaluateJavaScript("window.open('\(Self.address("Rejected").absoluteString)') === null")
        XCTAssertEqual(rejected as? Bool, true, "window.open gave the script a window")
        XCTAssertEqual(host.requests.count, 1)
        // One more round trip, for anything the rejection set going.
        _ = try await page.view.evaluateJavaScript("1")
        XCTAssertTrue(host.made.isEmpty)
        XCTAssertTrue(host.closed.isEmpty)
        XCTAssertEqual(Session.shared.pages.live.count, live, "a page was left live")
        XCTAssertEqual(Self.tabCount(), tabs, "a tab was left")
        XCTAssertNil(page.peek)
        XCTAssertNil(page.picture)
        XCTAssertEqual(page.view.url, at)
        XCTAssertEqual(page.state.title, "Opener")
        XCTAssertFalse(page.view.isLoading)
        XCTAssertNil(page.failure)
    }

    // MARK: A tab's child

    /// Pages makes a tab's child from the request: live for the tab, in the
    /// tab's space, in the opener's store and not the space's lasting one,
    /// showing what the opener writes into it, which the tab keeps, and tied
    /// to the opener; the tab closed, it goes with it.
    func testPagesAdoptsATabsChildFromTheRequest() async throws {
        let session = Session.shared
        XCTAssertTrue(session.canUseWorkspace, "the test run's workspace can't be used")
        let space = try XCTUnwrap(session.workspace.spaces.first?.id)
        let (page, host) = await opener(space: space)
        host.answer = .adopt
        let url = Self.blank

        let opened = try await open(url, from: page)
        XCTAssertEqual(opened, true)
        let tab = try XCTUnwrap(host.tabs.first)
        let child = try XCTUnwrap(host.made.first)
        XCTAssertTrue(session.pages.live[tab] === child, "the tab's live page isn't the child")
        XCTAssertEqual(child.tab, tab)
        XCTAssertEqual(child.space, space)
        XCTAssertFalse(child.isExtensionPage)
        XCTAssertTrue(child.view.configuration.websiteDataStore === page.view.configuration.websiteDataStore,
                      "the child isn't in the opener's store")
        XCTAssertFalse(child.view.configuration.websiteDataStore.isPersistent, "the child is in a lasting store")

        await waitFor("the child committed") { child.committed != nil }
        XCTAssertEqual(child.committed, url)
        XCTAssertEqual(child.view.url, url)
        _ = try await page.view.evaluateJavaScript("window.__opened.document.title = 'Adopted'; 1")
        await waitForPage(child, titled: "Adopted")
        XCTAssertEqual(session.workspace.tab(tab)?.title, "Adopted", "the tab doesn't follow its page")
        let hasOpener = try await child.view.evaluateJavaScript("window.opener !== null")
        XCTAssertEqual(hasOpener as? Bool, true, "the tab's child lost its tie to the page that opened it")

        session.closeTab(tab)
        XCTAssertNil(session.pages.live[tab])
        XCTAssertNil(session.workspace.tab(tab))
        XCTAssertNil(child.host, "the tab's page wasn't let go of with it")
    }

    // MARK: Another app's link

    /// window.open to another app's link (mailto:) never reaches the host,
    /// and gives the script null; the opener stays where it was, with no
    /// refusal noted. The same script to a page asks the host first, and as
    /// a script's, or the app's link isn't asked for at all.
    func testAnotherAppsLinkNeverReachesTheHost() async throws {
        let (page, host) = await opener()
        host.answer = .reject
        let at = page.view.url

        let harmless = try await open(Self.address("Harmless"), from: page)
        XCTAssertEqual(harmless, false)
        let first = try XCTUnwrap(host.requests.first)
        // A click's would open the app at once (AppLink.answer): not asked for then.
        guard first.navigation.kind == .other, !host.isShowing(page), host.hostWindow == nil else {
            return XCTFail("window.open here isn't a script's in a page no window shows: \(first.navigation.kind)")
        }

        let rejected = try await page.view.evaluateJavaScript("window.open('\(Self.appLink.absoluteString)') === null")
        XCTAssertEqual(rejected as? Bool, true, "window.open gave the script a window")
        _ = try await page.view.evaluateJavaScript("1")
        XCTAssertEqual(host.requests.count, 1, "another app's link reached the host")
        XCTAssertTrue(host.made.isEmpty)
        XCTAssertTrue(host.closed.isEmpty)
        XCTAssertNil(page.refusedAppLink)
        XCTAssertNil(page.failure)
        XCTAssertEqual(page.view.url, at)
    }

    // MARK: Helpers

    /// A window's first, empty document, the opener's to fill.
    private static let blank = URL(string: "about:blank")!

    /// Another app's link, at `.invalid`, which names no host anywhere.
    private static let appLink = URL(string: "mailto:x@eglu-tests.invalid")!

    /// A page at a data: page named Opener, which may open windows from its
    /// script, its host a `ChildHost` that makes children by default.
    private func opener(space: UUID = UUID()) async -> (Page, ChildHost) {
        let configuration = Self.keepingNothing()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let page = makePage(space: space, configuration: configuration)
        let host = ChildHost()
        hosts.append(host)
        page.host = host
        await load(page, "Opener")
        return (page, host)
    }

    /// window.open(`url`) from the page's script, the window kept as
    /// `window.__opened`: whether the script got one.
    private func open(_ url: URL, from page: Page, features: String? = nil) async throws -> Bool? {
        let size = features.map { ", '', '\($0)'" } ?? ""
        let script = "window.__opened = window.open('\(url.absoluteString)'\(size)); window.__opened !== null"
        return try await page.view.evaluateJavaScript(script) as? Bool
    }

    /// Every tab in the workspace.
    private static func tabCount() -> Int {
        Session.shared.workspace.spaces.reduce(0) { $0 + $1.tabs.count }
    }

    /// A script's navigation in the main frame, as WebKit's adapter gives one.
    private static func navigation(to url: URL) -> WebNavigation {
        WebNavigation(request: URLRequest(url: url), sourceOrigin: .opaque, targetIsMainFrame: true, kind: .other,
                      modifiers: [], buttonNumber: 0, requestsDownload: false, isServerRedirect: false,
                      contentRuleRedirect: nil, sourceIsMainFrame: true)
    }

    /// The page's one answer to `navigation`, given before the call returns.
    private func decide(_ page: Page, _ navigation: WebNavigation,
                        file: StaticString = #filePath, line: UInt = #line) -> WebNavigationDecision? {
        var answers: [WebNavigationDecision] = []
        page.decideNavigation(navigation) { answers.append($0) }
        XCTAssertEqual(answers.count, 1, "answers to a navigation", file: file, line: line)
        return answers.first
    }

    /// Waits, up to `timeout`, for `condition`, looked at every 20 ms.
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

/// A host that keeps each window a page asked it for, and makes the child
/// with the app's engine (`make`), makes it a tab's through Pages (`adopt`),
/// or makes none (`reject`); it keeps each page that told it it closed. For
/// everything else, the least a host does: it shows nothing.
@MainActor
private final class ChildHost: PageHost {
    enum Answer {
        case make, adopt, reject
    }

    var answer: Answer = .make
    private(set) var requests: [any WebChildRequest] = []
    /// The children made, in order, each the one given back.
    private(set) var made: [Page] = []
    /// The tabs opened for children (`adopt`).
    private(set) var tabs: [UUID] = []
    private(set) var closed: [Page] = []

    func page(_ page: Page, openChild request: any WebChildRequest) -> Page? {
        requests.append(request)
        let child: Page
        switch answer {
        case .reject:
            return nil
        case .make:
            child = Session.shared.engine.makePage(tab: UUID(), space: page.space, source: .child(request))
        case .adopt:
            let session = Session.shared
            guard let tab = session.change({ $0.openTab(request.navigation.request.url, in: page.space) }) else {
                return nil
            }
            tabs.append(tab)
            child = session.pages.adopt(tab: tab, space: page.space, child: request)
        }
        child.host = self
        made.append(child)
        return child
    }

    func pageDidChange(_ page: Page) {}
    func isShowing(_ page: Page) -> Bool { false }
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool { false }
    func pageDidClose(_ page: Page) { closed.append(page) }
    var hostWindow: NSWindow? { nil }
}
