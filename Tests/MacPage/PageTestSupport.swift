import WebKit
import XCTest
@testable import eGluMac

/// What every Mac page test does around itself: waits for the app's own
/// start-up to finish, forgets what Session keeps between tests before and
/// after, and lets go of the pages and the tabs it made.
///
/// The app hosting these runs with a data folder and an identifier of its
/// own (scheme eGlu Mac Page Tests, StartUpTests), so a tab opened here is in
/// a workspace of the test run's, never the person's.
@MainActor
class PageTestCase: XCTestCase {
    /// Pages a test made itself, no tab's; torn down after it.
    private var made: [Page] = []
    /// Tabs a test opened in the workspace; closed after it, their pages with them.
    private var opened: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        await waitForStartUp()
        Session.shared.resetForTests()
    }

    override func tearDown() async throws {
        for page in made { page.tearDown() }
        made.removeAll()
        for tab in opened { Session.shared.closeTab(tab) }
        opened.removeAll()
        Session.shared.resetForTests()
        try await super.tearDown()
    }

    /// The app's start-up finished: browser data checked (LaunchState),
    /// then Session's start. Session isn't asked before the first.
    func waitForStartUp() async {
        let finished: @MainActor () -> Bool = { LaunchState.shared.ready && Session.shared.started }
        guard !finished() else { return }
        let done = expectation(description: "start-up finished")
        let look = Task { @MainActor in
            while !Task.isCancelled {
                if finished() { done.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await fulfillment(of: [done], timeout: 30)
        look.cancel()
    }

    // MARK: Pages and tabs

    /// A configuration whose store keeps nothing, made by the test, not by
    /// the app's engine (`AppWebKitEngine.configuration(space:)`), which would
    /// use the space's lasting store.
    static func keepingNothing() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    /// A page for a tab no workspace has, as a little window's, a Peek's or
    /// a pop-up's is (a fresh `UUID()` each), in a store that keeps nothing,
    /// or with a configuration of the test's own.
    func makePage(tab: UUID = UUID(), space: UUID = UUID(),
                  configuration: WKWebViewConfiguration? = nil) -> Page {
        let page = Page(tab: tab, space: space, configuration: configuration ?? Self.keepingNothing())
        made.append(page)
        return page
    }

    /// A new tab in the workspace's first space, its page live in Session's
    /// pages as a window's tab's is, in a store that keeps nothing.
    func openTab() throws -> (tab: UUID, space: UUID, page: Page) {
        let session = Session.shared
        XCTAssertTrue(session.canUseWorkspace, "the test run's workspace can't be used")
        let space = try XCTUnwrap(session.workspace.spaces.first?.id)
        let tab = try XCTUnwrap(session.change { $0.openTab(nil, in: space) })
        opened.append(tab)
        let page = session.pages.adopt(tab: tab, space: space, configuration: Self.keepingNothing())
        return (tab, space, page)
    }

    /// The tab's live page now, as Session's pages have it.
    func livePage(_ tab: UUID, file: StaticString = #filePath, line: UInt = #line) throws -> Page {
        try XCTUnwrap(Session.shared.pages.live[tab], "no live page for the tab", file: file, line: line)
    }

    // MARK: Loading

    /// A page of its own, named `title`, which no other page in the test is:
    /// a data: address, which no network or file is needed for.
    static func address(_ title: String) -> URL {
        let html = "<!doctype html><title>\(title)</title><p>\(title)</p>"
        return URL(string: "data:text/html;charset=utf-8," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    /// Loads the page named `title`, the way eGlu loads an address (Page.load), and waits for it.
    func load(_ page: Page, _ title: String, file: StaticString = #filePath, line: UInt = #line) async {
        page.load(Self.address(title))
        await waitForPage(page, titled: title, file: file, line: line)
    }

    /// The page named `title` on screen and loaded: after a load, Back or Forward.
    func waitForPage(_ page: Page, titled title: String, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(page, "\(title) shown", file: file, line: line) { $0.title == title && !$0.isLoading }
    }

    /// Waits, up to `timeout`, for `condition` to hold of the page's view,
    /// looked at again each time WebKit says one of its values changed.
    func waitUntil(_ page: Page, _ what: String, timeout: TimeInterval = 10,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @escaping @MainActor (PageView) -> Bool) async {
        let view = page.view
        guard !condition(view) else { return }
        let done = expectation(description: what)
        var fulfilled = false
        let check: @MainActor () -> Void = {
            guard !fulfilled, condition(view) else { return }
            fulfilled = true
            done.fulfill()
        }
        let observations: [NSKeyValueObservation] = [
            view.observe(\.isLoading) { _, _ in MainActor.assumeIsolated(check) },
            view.observe(\.url) { _, _ in MainActor.assumeIsolated(check) },
            view.observe(\.title) { _, _ in MainActor.assumeIsolated(check) },
            view.observe(\.estimatedProgress) { _, _ in MainActor.assumeIsolated(check) },
            view.observe(\.canGoBack) { _, _ in MainActor.assumeIsolated(check) },
            view.observe(\.canGoForward) { _, _ in MainActor.assumeIsolated(check) },
        ]
        await fulfillment(of: [done], timeout: timeout)
        observations.forEach { $0.invalidate() }
        if !fulfilled {
            XCTFail("\(what): not by \(timeout) s; the view is at \(view.url?.absoluteString ?? "nothing"), "
                    + "titled \(view.title ?? "nothing"), loading \(view.isLoading)", file: file, line: line)
        }
    }
}
