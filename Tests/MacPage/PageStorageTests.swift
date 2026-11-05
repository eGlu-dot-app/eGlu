import AppKit
import PadCore
import WebEngineCore
import WebKit
import WebKitSupport
import XCTest
@testable import eGluMac

/// What a page keeps of WebKit's and gives back to it (Docs/EngineSplitPlan.md,
/// 7, step 8), through a real `Page`, `Pages` and `Session`: the back and
/// forward entries its history and its status are kept by, which are
/// WebKit's own objects (`WebBackForward.currentEntry`); the record that
/// brings a page back where it was (`Page.restorationData`), for a new page
/// and for a tab frozen and opened again; and each space's one website store
/// (`WebKitStores`), let go of and removed when the space is erased.
///
/// Adapted where WebKit or the app can't be made to show it otherwise:
/// - A data: page's answer is no HTTP answer, so it has no status to keep.
///   The status test loads real pages for WebKit's real entries, then tells
///   the page of an HTTP answer, a failure and a commit by hand, as
///   PageResponsePolicyTests and PageLifecycleTests do.
/// - History keeps only web pages, so the web app's page is loaded with
///   `loadHTMLString` at a `.invalid` address, which names no host anywhere.
///   It names a data: icon of its own, which SiteIcons takes before it would
///   look for the site's /favicon.ico; it loads nothing else. WebKit gives
///   such a document, and the pages it pushes, no back and forward entries,
///   so a web app's step back to a page seen before is not made here: that
///   a step back adds no entry is shown with data: pages, which history
///   keeps no visits of.
/// - Pages lets a tab's page go only from `enforce(pressure:)`; the test
///   calls it as the memory pressure source does, with no pressure.
/// - The erased store is a fresh space's, made only for the test, which no
///   view has used. Session's own erase of a removed space
///   (`Session.removeSpace`) is not run: it would remove a space of the
///   test run's workspace. Back past a replaced page, which reads the old
///   page's record (`Session.replacePage`), is PageBackTests'.
@MainActor
final class PageStorageTests: PageTestCase {
    /// Tabs opened here with no page made for them yet; closed after each test.
    private var openedHere: [UUID] = []

    override func tearDown() async throws {
        for tab in openedHere { Session.shared.closeTab(tab) }
        openedHere.removeAll()
        try await super.tearDown()
    }

    // MARK: History identities

    /// The entries the page's history keeps visits at are the very objects
    /// of the view's back and forward list, one for each document, and a
    /// step back or forward to one adds none. The status is kept by the
    /// same objects, and found by the one on screen.
    func testHistoryAndStatusKeepWebKitsOwnEntries() async throws {
        let page = makePage()
        XCTAssertTrue(try entries(of: page).isEmpty)

        await load(page, "One")
        let one = try XCTUnwrap(page.view.backForwardList.currentItem)
        var kept = try entries(of: page)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept.first === one, "the history keeps another object than WebKit's entry")

        await load(page, "Two")
        let two = try XCTUnwrap(page.view.backForwardList.currentItem)
        XCTAssertFalse(two === one)
        XCTAssertTrue(page.view.backForwardList.backItem === one)
        kept = try entries(of: page)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.first === one && kept.last === two, "the history keeps other objects than WebKit's entries")

        // Two's answer, kept with Two's entry as its document commits.
        XCTAssertEqual(decideAnswer(page, status: 203), .allow)
        page.navigationCommitted(url: page.view.url)
        XCTAssertEqual(page.statusCode, 203)
        var keys = try statusKeys(of: page)
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys.first === two, "the status is kept by another object than WebKit's entry")

        // A document that commits with no answer, as one WebKit brings back
        // from its back-forward cache does: the status its entry had, found
        // by the entry on screen. The failure first shows none.
        page.navigationFailed(WebLoadError(kind: .other, domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                           failingURL: URL(string: "https://eglu-tests.invalid/missing")),
                              provisional: true)
        XCTAssertNil(page.statusCode)
        page.navigationCommitted(url: page.view.url)
        XCTAssertEqual(page.statusCode, 203, "the status wasn't found by the entry on screen")

        // Back to an entry the page was on already: no new one.
        page.goBack()
        await waitForPage(page, titled: "One")
        XCTAssertTrue(page.view.backForwardList.currentItem === one, "Back made WebKit a new entry")
        kept = try entries(of: page)
        XCTAssertEqual(kept.count, 2, "a step back added an entry")
        XCTAssertTrue(kept.first === one && kept.last === two)

        // One's answer, kept beside Two's: each by its own entry.
        XCTAssertEqual(decideAnswer(page, status: 500), .allow)
        page.navigationCommitted(url: page.view.url)
        XCTAssertEqual(page.statusCode, 500)
        let table = try statusTable(of: page)
        keys = try statusKeys(of: page)
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.contains { $0 === one } && keys.contains { $0 === two },
                      "the status is kept by other objects than WebKit's entries")
        XCTAssertEqual(table.object(forKey: one)?.intValue, 500)
        XCTAssertEqual(table.object(forKey: two)?.intValue, 203)

        // Forward again: still the same two.
        page.goForward()
        await waitForPage(page, titled: "Two")
        XCTAssertTrue(page.view.backForwardList.currentItem === two, "Forward made WebKit a new entry")
        kept = try entries(of: page)
        XCTAssertEqual(kept.count, 2, "a step forward added an entry")
        XCTAssertTrue(kept.first === one && kept.last === two)
    }

    /// A web app's own page change (`history.pushState`) in a tab is a
    /// visit in the space's history, one for each page it moves to, and no
    /// more: each is written once, in order, the first document's too.
    ///
    /// Not here: the web app's step back (`history.back()`) to a page seen
    /// before. WebKit keeps a document loaded from a string, and the pages
    /// it pushes, out of its back and forward list (no entry, in both runs),
    /// so there is no step back to make without loading a website.
    func testAWebAppsOwnPagesAreAVisitEach() async throws {
        try XCTSkipIf(Session.shared.preferences.iCloudSync, "the test run's history would go to iCloud")
        XCTAssertEqual(HistoryRecorder.shared.availability, .available, "the test run's history can't be used")
        try XCTSkipIf((try? Data(contentsOf: Self.icon)) == nil,
                      "the page's data: icon can't be read, and SiteIcons would look for the site's own")
        let (_, space, page) = try openTab()
        let folder = "https://eglu-tests.invalid/eglu-tests-\(UUID().uuidString.lowercased())/"
        let document = try XCTUnwrap(URL(string: folder + "app"))
        let pushed = try XCTUnwrap(URL(string: folder + "one"))
        let later = try XCTUnwrap(URL(string: folder + "two"))

        let html = "<!doctype html><title>Web App</title><link rel=\"icon\" href=\"\(Self.icon.absoluteString)\"><p>Web App</p>"
        page.view.loadHTMLString(html, baseURL: document)
        await waitForPage(page, titled: "Web App")
        XCTAssertEqual(page.view.url, document)
        await waitForVisits(1, in: space, to: document)

        _ = try await page.view.evaluateJavaScript("history.pushState(null, '', 'one'); 1")
        await waitUntil(page, "the web app's own page shown") { $0.url == pushed }
        await waitForVisits(1, in: space, to: pushed)
        XCTAssertFalse(page.view.isLoading)

        // Another page of the web app's own: its visit is written after any
        // second one the pages before it would have had, so once it is
        // there, those would be too.
        _ = try await page.view.evaluateJavaScript("history.pushState(null, '', 'two'); 1")
        await waitUntil(page, "the web app's next page shown") { $0.url == later }
        await waitForVisits(1, in: space, to: later)
        let visitsToDocument = await visits(in: space, to: document)
        let visitsToPushed = await visits(in: space, to: pushed)
        XCTAssertEqual(visitsToDocument.count, 1, "the first document was visited twice")
        XCTAssertEqual(visitsToPushed.count, 1, "the pushed page was visited twice")
    }

    // MARK: Restoration data

    /// The record of a page with two documents is Data; given to a new page
    /// before it has loaded anything, the new page comes back at the same
    /// address with the same back list. Nil given after changes nothing.
    func testRestorationDataBringsANewPageBackWhereTheOtherWas() async throws {
        let page = makePage()
        await load(page, "One")
        await load(page, "Two")
        let record = try XCTUnwrap(page.restorationData, "no record after two loads")
        let data = try XCTUnwrap(record as? Data, "the record is a \(type(of: record)), not Data")
        XCTAssertFalse(data.isEmpty)
        let back = page.view.backForwardList.backList.map(\.url)
        XCTAssertEqual(page.view.backForwardList.backList.map(\.title), ["One"])
        let shown = try XCTUnwrap(page.view.url)

        let restored = makePage()
        XCTAssertNil(restored.view.url)
        restored.restorationData = data
        await waitForPage(restored, titled: "Two")
        XCTAssertEqual(restored.view.url, shown)
        XCTAssertEqual(restored.view.backForwardList.currentItem?.url, shown)
        XCTAssertEqual(restored.view.backForwardList.backList.map(\.url), back)
        XCTAssertTrue(restored.canGoBack)

        restored.restorationData = nil
        XCTAssertNotNil(restored.restorationData, "nil took the page's record")
        XCTAssertEqual(restored.view.url, shown)
        XCTAssertEqual(restored.view.backForwardList.backList.map(\.url), back, "nil changed the back list")
        XCTAssertFalse(restored.view.isLoading, "nil started a load")
        restored.goBack()
        await waitForPage(restored, titled: "One")
        XCTAssertEqual(restored.view.backForwardList.forwardList.map(\.url), [shown])
    }

    /// A tab whose page Pages lets go (as for want of memory) gets a new
    /// page when it is next asked for, back at the tab's address with the
    /// back list it had.
    func testAFrozenTabComesBackWithItsBackList() async throws {
        let (tab, space, page) = try openTab()
        await load(page, "Frozen One")
        await load(page, "Frozen Two")
        let back = page.view.backForwardList.backList.map(\.url)
        XCTAssertEqual(page.view.backForwardList.backList.map(\.title), ["Frozen One"])
        let shown = try XCTUnwrap(page.view.url)
        XCTAssertEqual(Session.shared.workspace.tab(tab)?.url, shown)
        XCTAssertFalse(Session.shared.shownTabs.contains(tab), "the tab is on screen")
        XCTAssertFalse(page.mustStay)

        Session.shared.pages.enforce(pressure: true)
        await waitFor("the tab's page let go") { !Session.shared.pages.isLive(tab) }

        let record = try XCTUnwrap(Session.shared.workspace.tab(tab))
        let thawed = Session.shared.pages.page(for: record, in: space)
        XCTAssertFalse(thawed === page, "the tab kept the page it let go")
        XCTAssertTrue(try livePage(tab) === thawed)
        await waitForPage(thawed, titled: "Frozen Two")
        XCTAssertEqual(thawed.view.url, shown)
        XCTAssertEqual(thawed.view.backForwardList.backList.map(\.url), back, "the tab came back without its back list")
        XCTAssertTrue(thawed.canGoBack)
        thawed.goBack()
        await waitForPage(thawed, titled: "Frozen One")
    }

    // MARK: Each space's store

    /// A space has one store object, made once, and a tab's page in the
    /// space has it as its website store, as its other tabs' pages do.
    func testATabsPageIsInItsSpacesOneStore() throws {
        let (record, space) = try openRecord()
        let page = Session.shared.pages.page(for: record, in: space)
        XCTAssertTrue(WebKitStores.isMade(space))
        let store = WebKitStores.store(for: space)
        XCTAssertTrue(WebKitStores.store(for: space) === store, "the space got a second store")
        XCTAssertEqual(store.identifier, space)
        XCTAssertTrue(page.view.configuration.websiteDataStore === store, "the tab's page is not in its space's store")

        let (other, _) = try openRecord()
        let second = Session.shared.pages.page(for: other, in: space)
        XCTAssertFalse(second === page)
        XCTAssertTrue(second.view.configuration.websiteDataStore === store,
                      "another tab's page in the space is in another store")
    }

    /// A space made only for this test, never the workspace's: its store,
    /// erased through the app's engine, is let go of at once and written
    /// down under `stores.erasing` in the test host's preferences; the sweep
    /// two seconds later removes it, once WebKit has, and takes it off.
    func testErasingAFreshSpacesStoreLetsItGoAndRemovesIt() async throws {
        let host = try XCTUnwrap(Bundle.main.bundleIdentifier)
        guard host.hasSuffix(".pagetests") else {
            return XCTFail("not the test host, \(host): its preferences are not the run's own")
        }
        let fresh = UUID()
        XCTAssertNil(Session.shared.workspace.space(fresh), "the fresh space is the workspace's")
        XCTAssertFalse(WebKitStores.isMade(fresh))
        XCTAssertFalse(Self.erasing.contains(fresh.uuidString))
        addTeardownBlock { @MainActor in await PageStorageTests.cleanUp(fresh) }

        autoreleasepool {
            let store = WebKitStores.store(for: fresh)
            XCTAssertTrue(WebKitStores.isMade(fresh))
            XCTAssertTrue(WebKitStores.store(for: fresh) === store, "the space got a second store")
            XCTAssertEqual(store.identifier, fresh)
            if let workspaceSpace = Session.shared.workspace.spaces.first?.id {
                XCTAssertFalse(WebKitStores.store(for: workspaceSpace) === store, "two spaces share a store")
            }
        }

        EngineComposition.makePageEngine().eraseStore(space: fresh)
        let erased = Date()
        XCTAssertFalse(WebKitStores.isMade(fresh), "the erased space's store is still made")
        XCTAssertTrue(Self.erasing.contains(fresh.uuidString), "the erased space isn't written down")
        let kept = UserDefaults.standard.persistentDomain(forName: host)?[Self.erasingKey] as? [String]
        XCTAssertEqual(kept?.contains(fresh.uuidString), true, "not written down in the test host's own preferences")

        await waitFor("the store removed and taken off \(Self.erasingKey)", timeout: 20) {
            !Self.erasing.contains(fresh.uuidString)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(erased), 1.9, "the sweep came before its two seconds")
        XCTAssertFalse(WebKitStores.isMade(fresh), "the sweep made the store again")
    }

    // MARK: Helpers

    /// The preference the app writes removed spaces' stores down under (Stores).
    private static let erasingKey = "stores.erasing"

    /// The spaces written down for their stores' removal, in the test host's preferences.
    private static var erasing: [String] {
        UserDefaults.standard.stringArray(forKey: erasingKey) ?? []
    }

    /// The fresh space gone from everything the test may have left: taken
    /// off `stores.erasing`, its store let go of and removed, tried for a
    /// few seconds while WebKit still holds it. Nothing where the sweep did it.
    private static func cleanUp(_ space: UUID) async {
        let listed = erasing.contains(space.uuidString)
        guard listed || WebKitStores.isMade(space) else { return }
        if listed { UserDefaults.standard.set(erasing.filter { $0 != space.uuidString }, forKey: erasingKey) }
        WebKitStores.forget(space)
        WebKitStores.prepareForRemoval()
        for _ in 0..<20 {
            let removed = await withCheckedContinuation { done in
                WebKitStores.remove(space) { done.resume(returning: $0) }
            }
            if removed { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("the test's store \(space) is still on disk")
    }

    /// A picture of the page's own, as a data: address: SiteIcons takes it,
    /// so it never looks for the site's /favicon.ico.
    private static let icon: URL = {
        let side = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return URL(string: "data:image/png;base64,")! }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:]) ?? Data()
        return URL(string: "data:image/png;base64," + png.base64EncodedString())!
    }()

    /// A new tab in the workspace's first space, with no address and no page made for it yet.
    private func openRecord() throws -> (record: TabRecord, space: UUID) {
        let session = Session.shared
        XCTAssertTrue(session.canUseWorkspace, "the test run's workspace can't be used")
        let space = try XCTUnwrap(session.workspace.spaces.first?.id)
        let tab = try XCTUnwrap(session.change { $0.openTab(nil, in: space) })
        openedHere.append(tab)
        return (try XCTUnwrap(session.workspace.tab(tab)), space)
    }

    /// A value `subject` keeps to itself, read by its name.
    private func kept<T>(_ name: String, of subject: Any, as type: T.Type = T.self,
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let child = try XCTUnwrap(Mirror(reflecting: subject).children.first { $0.label == name },
                                  "\(Swift.type(of: subject)) keeps no \(name)", file: file, line: line)
        return try XCTUnwrap(child.value as? T, "\(name) is a \(Swift.type(of: child.value))", file: file, line: line)
    }

    /// The back and forward entries the page's history made visits at (PageHistory.entries).
    private func entries(of page: Page, file: StaticString = #filePath, line: UInt = #line) throws -> [AnyObject] {
        let history = try kept("history", of: page, as: PageHistory.self, file: file, line: line)
        return try kept("entries", of: history, as: [AnyObject].self, file: file, line: line)
    }

    /// The statuses the page keeps by back and forward entry (PageStatus.byItem).
    private func statusTable(of page: Page, file: StaticString = #filePath,
                             line: UInt = #line) throws -> NSMapTable<AnyObject, NSNumber> {
        let status = try kept("status", of: page, as: PageStatus.self, file: file, line: line)
        return try kept("byItem", of: status, as: NSMapTable<AnyObject, NSNumber>.self, file: file, line: line)
    }

    /// The entries the page keeps a status for.
    private func statusKeys(of page: Page, file: StaticString = #filePath, line: UInt = #line) throws -> [AnyObject] {
        try statusTable(of: page, file: file, line: line).keyEnumerator().allObjects.map { $0 as AnyObject }
    }

    /// The page's one answer to a website's main-frame response with
    /// `status`, which the next commit makes the page's status.
    private func decideAnswer(_ page: Page, status: Int,
                              file: StaticString = #filePath, line: UInt = #line) -> WebResponseDecision? {
        let url = URL(string: "https://eglu-tests.invalid/answered")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        var answers: [WebResponseDecision] = []
        page.decideResponse(WebResponse(response: response, isForMainFrame: true, canShowMIMEType: true)) {
            answers.append($0)
        }
        XCTAssertEqual(answers.count, 1, "answers to the response", file: file, line: line)
        return answers.first
    }

    /// The space's visits to `url`, as its history keeps them.
    private func visits(in space: UUID, to url: URL) async -> [HistoryEntry] {
        let key = History.pageKey(url)
        return await HistoryRecorder.shared.entries(space: space, limit: 200)
            .filter { $0.handoff == nil && $0.page.key == key }
    }

    /// Waits, up to `timeout`, for the space's history to have `count`
    /// visits to `url`, read again every 50 ms.
    private func waitForVisits(_ count: Int, in space: UUID, to url: URL, timeout: TimeInterval = 10,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        var found = await visits(in: space, to: url).count
        while found != count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            found = await visits(in: space, to: url).count
        }
        XCTAssertEqual(found, count, "visits to \(url.lastPathComponent) by \(timeout) s", file: file, line: line)
    }

    /// Waits, up to `timeout`, for `condition`, looked at every 20 ms: for
    /// what WebKit doesn't report a change of.
    private func waitFor(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath,
                         line: UInt = #line, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "\(what): not by \(timeout) s", file: file, line: line)
    }
}
