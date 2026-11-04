import PadCore
import WebKit
import XCTest
@testable import eGluMac

/// Every page is made through one factory, `MacPageEngine`
/// (Docs/EngineSplitPlan.md, 7, step 2): `Pages` asks the one it is given,
/// with the source each kind of page needs, and the app's own factory,
/// `AppWebKitEngine`, makes the pages and configurations the app made
/// before the factory existed.
@MainActor
final class PageEngineTests: PageTestCase {
    /// Pages made here straight from the app's factory, no tab's; torn down after each test.
    private var madeHere: [Page] = []
    /// A `Pages` of the test's own, given the spy; its live pages are closed after each test.
    private var spied: Pages?
    /// Tabs opened here in the test run's workspace; closed after each test.
    private var openedHere: [UUID] = []

    override func tearDown() async throws {
        if let spied {
            for tab in Array(spied.live.keys) { spied.close(tab) }
        }
        spied = nil
        for page in madeHere { page.tearDown() }
        madeHere.removeAll()
        for tab in openedHere { Session.shared.closeTab(tab) }
        openedHere.removeAll()
        try await super.tearDown()
    }

    // MARK: Pages asks its factory

    /// A tab's page is asked for once, with the tab's address; asked for
    /// again in the same space, the tab keeps the page it has.
    func testATabsPageIsAskedForOnce() throws {
        let spy = SpyEngine()
        let pages = spiedPages(spy)
        let (record, space) = try openRecord(Self.address("Engine"))

        let page = pages.page(for: record, in: space)
        XCTAssertEqual(spy.calls.count, 1)
        let call = try XCTUnwrap(spy.calls.first)
        XCTAssertEqual(call.source, .tab(record.url))
        XCTAssertNotNil(record.url, "the tab has an address, so .tab(nil) would not pass for it")
        XCTAssertEqual(call.tab, record.id)
        XCTAssertEqual(call.space, space)
        XCTAssertTrue(call.page === page, "Pages gave back a page the factory didn't make")
        XCTAssertTrue(pages.live[record.id] === page)

        let again = pages.page(for: record, in: space)
        XCTAssertTrue(again === page, "the same tab and space got a new page")
        XCTAssertEqual(spy.calls.count, 1, "the factory was asked again for a page the tab has")
    }

    /// A tab asked for in another space has moved: its page goes, and the
    /// factory is asked for one in the new space.
    func testAMovedTabsPageIsAskedForAgain() throws {
        let spy = SpyEngine()
        let pages = spiedPages(spy)
        let (record, space) = try openRecord(Self.address("Moving"))
        let first = pages.page(for: record, in: space)

        let other = UUID()
        let second = pages.page(for: record, in: other)
        XCTAssertEqual(spy.calls.count, 2)
        let call = try XCTUnwrap(spy.calls.last)
        XCTAssertEqual(call.source, .tab(record.url))
        XCTAssertEqual(call.tab, record.id)
        XCTAssertEqual(call.space, other)
        XCTAssertTrue(call.page === second)
        XCTAssertFalse(second === first, "the moved tab kept the page made in its old space")
        XCTAssertEqual(second.space, other)
        XCTAssertTrue(pages.live[record.id] === second)
    }

    /// A page WebKit made for a tab is asked for with the very configuration
    /// WebKit gave, and with its extension flag, which is off unless given.
    func testAdoptPassesTheConfigurationItWasGiven() throws {
        let spy = SpyEngine()
        let pages = spiedPages(spy)
        let space = try XCTUnwrap(Session.shared.workspace.spaces.first?.id)

        let website = Self.keepingNothing()
        let tab = UUID()
        let page = pages.adopt(tab: tab, space: space, configuration: website)
        let call = try XCTUnwrap(spy.calls.last)
        XCTAssertEqual(call.source, .supplied(extensionPage: false))
        XCTAssertTrue(call.configuration === website, "the factory was given another configuration")
        XCTAssertEqual(call.tab, tab)
        XCTAssertEqual(call.space, space)
        XCTAssertTrue(call.page === page)
        XCTAssertFalse(page.isExtensionPage)
        XCTAssertTrue(pages.live[tab] === page)

        let extensions = Self.keepingNothing()
        let extensionTab = UUID()
        let extensionPage = pages.adopt(tab: extensionTab, space: space, configuration: extensions, extensionPage: true)
        let extensionCall = try XCTUnwrap(spy.calls.last)
        XCTAssertEqual(extensionCall.source, .supplied(extensionPage: true))
        XCTAssertTrue(extensionCall.configuration === extensions, "the factory was given another configuration")
        XCTAssertEqual(extensionCall.tab, extensionTab)
        XCTAssertTrue(extensionPage.isExtensionPage)
        XCTAssertEqual(spy.calls.count, 2)
    }

    // MARK: The app's factory

    /// A supplied configuration makes a page with it, an extension's page
    /// only when the source says so.
    func testSuppliedConfigurationKeepsItsExtensionFlag() {
        let engine = AppWebKitEngine()
        for extensionPage in [false, true] {
            let configuration = Self.keepingNothing()
            let tab = UUID()
            let space = UUID()
            let page = made(engine.makePage(tab: tab, space: space,
                                            source: .supplied(configuration, extensionPage: extensionPage)))
            XCTAssertEqual(page.isExtensionPage, extensionPage)
            XCTAssertEqual(page.tab, tab)
            XCTAssertEqual(page.space, space)
            XCTAssertTrue(page.view.configuration.websiteDataStore === configuration.websiteDataStore,
                          "the page is not in the supplied configuration's store")
        }
    }

    /// A tab with no address, a website's address or no tab at all gets an
    /// ordinary page in the space's lasting store.
    func testTabAndSpaceSourcesMakeOrdinaryPages() throws {
        let engine = AppWebKitEngine()
        let space = try XCTUnwrap(Session.shared.workspace.spaces.first?.id)
        let sources: [(String, MacPageSource)] = [
            ("a tab with no address", .tab(nil)),
            ("a tab with a website's address", .tab(Self.address("Website"))),
            ("the space", .space),
        ]
        for (what, source) in sources {
            let page = made(engine.makePage(tab: UUID(), space: space, source: source))
            XCTAssertFalse(page.isExtensionPage, "\(what) made an extension's page")
            XCTAssertEqual(page.space, space, what)
            XCTAssertTrue(page.view.configuration.websiteDataStore === Stores.store(for: space),
                          "\(what): the page is not in the space's store")
        }
    }

    /// A new configuration has the space's store and extension controller,
    /// and Safari's name at the end of the user agent.
    func testConfigurationIsTheSpaces() throws {
        let engine = AppWebKitEngine()
        let space = try XCTUnwrap(Session.shared.workspace.spaces.first?.id)
        let configuration = engine.configuration(space: space)
        XCTAssertTrue(configuration.websiteDataStore === Stores.store(for: space), "not the space's store")
        XCTAssertEqual(configuration.applicationNameForUserAgent,
                       Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion))
        XCTAssertTrue(configuration.webExtensionController === Extensions.shared.controller(for: space),
                      "not the space's extension controller")
    }

    /// The app's one Session makes its pages with the app's WebKit factory.
    func testSessionUsesTheAppsFactory() {
        XCTAssertTrue(Session.shared.engine is AppWebKitEngine)
    }

    // MARK: Helpers

    /// A `Pages` of the test's own, which asks `spy` for its pages.
    private func spiedPages(_ spy: SpyEngine) -> Pages {
        let pages = Pages(engine: spy)
        spied = pages
        return pages
    }

    /// A page from the app's factory, torn down after the test.
    private func made(_ page: Page) -> Page {
        madeHere.append(page)
        return page
    }

    /// A new tab at `url` in the workspace's first space, as `openTab()`
    /// opens one, but with no page made for it yet.
    private func openRecord(_ url: URL?) throws -> (record: TabRecord, space: UUID) {
        let session = Session.shared
        XCTAssertTrue(session.canUseWorkspace, "the test run's workspace can't be used")
        let space = try XCTUnwrap(session.workspace.spaces.first?.id)
        let tab = try XCTUnwrap(session.change { $0.openTab(url, in: space) })
        openedHere.append(tab)
        let record = try XCTUnwrap(session.workspace.tab(tab))
        return (record, space)
    }
}

/// A page factory that writes down each page it is asked for, and makes it
/// as the app's factory would, but in a store that keeps nothing unless a
/// configuration is supplied. It sweeps and starts nothing.
@MainActor
final class SpyEngine: MacPageEngine {
    /// The source a page was asked for with; a supplied configuration is in `Call`.
    enum Source: Equatable {
        case space
        case tab(URL?)
        case supplied(extensionPage: Bool)
    }

    /// One page asked for, and the page made.
    struct Call {
        let source: Source
        let tab: UUID
        let space: UUID
        /// The configuration given with `.supplied`, as it was given.
        let configuration: WKWebViewConfiguration?
        let page: Page
    }

    private(set) var calls: [Call] = []

    func makePage(tab: UUID, space: UUID, source: MacPageSource) -> Page {
        let page: Page
        let kind: Source
        var supplied: WKWebViewConfiguration?
        switch source {
        case .space:
            kind = .space
            page = Page(tab: tab, space: space, configuration: PageTestCase.keepingNothing())
        case .tab(let url):
            kind = .tab(url)
            page = Page(tab: tab, space: space, configuration: PageTestCase.keepingNothing())
        case .supplied(let configuration, let extensionPage):
            kind = .supplied(extensionPage: extensionPage)
            supplied = configuration
            page = Page(tab: tab, space: space, configuration: configuration, extensionPage: extensionPage)
        }
        calls.append(Call(source: kind, tab: tab, space: space, configuration: supplied, page: page))
        return page
    }

    func configuration(space: UUID) -> WKWebViewConfiguration {
        PageTestCase.keepingNothing()
    }

    func sweepStores() {}

    func startContentBlocking() {}

    func startExtensions(afterLaunch: Bool) {}
}
