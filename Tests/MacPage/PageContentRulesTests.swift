import AppKit
import WebEngineCore
import WebKit
import WebKitSupport
import XCTest
@testable import eGluMac

/// A Mac page's content blocking through the engine (Docs/EngineSplitPlan.md,
/// 7, step 10), through a real `Page` and real WebKit: the store the engine
/// gives the content blocker (`MacPageEngine.ruleListStore()`) and the one
/// the blocker keeps, both WebKit's; the target each page puts its lists in
/// (`WebKitRuleListTarget`), over the page's own controller; a list given to
/// that target, which hides an element from the page's next load and, taken
/// away, shows it again; a page given nothing by a blocker with no lists;
/// and the lists a hidden page is given (`WebKitHiddenPage`), which hide the
/// element in the page it loads.
///
/// The one list the tests use has one rule, `css-display-none` for `#ad`,
/// compiled into a store at a folder of the test's own in the temporary
/// folder, removed after it. The default store (the content blocker's, the
/// engine's) is only looked at, for its type and that it is WebKit's default
/// one: nothing is compiled into it, looked up in it or removed from it.
///
/// WebKit applies no rule list to a data: document (a data: page with the
/// list showed the element, in a first run of these tests), so every page
/// here is loaded from a string with no base (`loadHTMLString`), in a store
/// that keeps nothing: no network, and no site for SiteIcons or the history.
/// A hidden page begins only an address, so its view, read with `Mirror`, is
/// given the string itself. Whether the element shows is what
/// `getComputedStyle` says of it, read in the page's world for a page and in
/// the app's own world for a hidden page (`callInAppWorld`).
///
/// Not here:
/// - The content blocker's own compiling, looking up and removing, on the
///   default store: its services do not start in the test host, so it has no
///   lists, and the default store is the test host's own. The package tests
///   (WebKitContentRulesTests) cover the store at a folder of their own.
/// - The filter lists and the planning of the rules from them (PadCore's
///   tests), and a site's own switch or Settings turning blocking off.
/// - The iOS app's page, which does the same through its own `Page`.
@MainActor
final class PageContentRulesTests: PageTestCase {
    // MARK: Wiring

    /// The engine's store and the content blocker's are WebKit's, the
    /// blocker's over WebKit's default store; a page's target is WebKit's,
    /// over the page's own controller, the one its view has.
    func testTheEngineTheBlockerAndAPageUseWebKitsRuleLists() throws {
        let engineStore = Session.shared.engine.ruleListStore()
        XCTAssertTrue(engineStore is WebKitRuleListStore, "the engine's store is a \(String(describing: engineStore))")

        let blockerStore = try kept("store", of: ContentBlocker.shared, as: WebKitRuleListStore.self)
        let raw = try kept("store", of: blockerStore, as: WKContentRuleListStore.self)
        XCTAssertTrue(raw === WKContentRuleListStore.default(), "the blocker's store isn't WebKit's default one")

        let page = makePage()
        let target = try kept("ruleListTarget", of: page, as: WebKitRuleListTarget.self)
        // The page's own controller, kept by its engine page (WebKitMacPage).
        let controller = try kept("controller", of: page.enginePage, as: WKUserContentController.self)
        XCTAssertTrue(try kept("controller", of: target, as: WKUserContentController.self) === controller,
                      "the page's target is over another controller than the page's")
        XCTAssertTrue(page.view.configuration.userContentController === controller,
                      "the page's controller isn't its view's")
    }

    // MARK: A page's lists

    /// A list given to the page's target hides `#ad` from the page's next
    /// load, and taken away (`replaceAll(with: [])`) shows it from the next.
    /// The page's own blocking, with no lists from the blocker, leaves the
    /// list as it was given at each load.
    func testAPagesListHidesAnElementFromItsNextLoad() async throws {
        let list = try await compiledList()
        let page = makePage()
        let target = try kept("ruleListTarget", of: page, as: WebKitRuleListTarget.self)

        await loadAdPage(page, "Before")
        let before = try await displayInPageWorld(page)
        XCTAssertEqual(before, "block", "the element is hidden before the page has a list")

        target.replaceAll(with: [list])
        await loadAdPage(page, "Hidden")
        let hidden = try await displayInPageWorld(page)
        XCTAssertEqual(hidden, "none", "the page's list didn't hide the element")
        XCTAssertFalse(page.blocksContent, "the page took the test's list as the blocker's")

        target.replaceAll(with: [])
        await loadAdPage(page, "Shown")
        let shown = try await displayInPageWorld(page)
        XCTAssertEqual(shown, "block", "the element is still hidden with the list taken away")
    }

    /// The test host's content blocker has no lists, so a page that loads
    /// gets none from it, and after the blocker says it has new lists
    /// (`blockingChanged()`) still none: an element a rule would hide shows.
    func testAPageGetsNoListsFromABlockerWithNone() async throws {
        XCTAssertTrue(ContentBlocker.shared.lists.isEmpty, "the test host's content blocker has lists")
        let page = makePage()

        await loadAdPage(page, "No Lists")
        let first = try await displayInPageWorld(page)
        XCTAssertEqual(first, "block", "the element is hidden with no lists")
        XCTAssertFalse(page.blocksContent)
        XCTAssertEqual(try blockingIdentifiers(of: page), [])

        page.blockingChanged()
        await loadAdPage(page, "Still No Lists")
        let again = try await displayInPageWorld(page)
        XCTAssertEqual(again, "block", "the element is hidden after the blocker's change")
        XCTAssertFalse(page.blocksContent)
        XCTAssertEqual(try blockingIdentifiers(of: page), [])
    }

    // MARK: The hidden page's lists

    /// A hidden page given the list, as `Page.hiddenPage` gives the
    /// blocker's, hides `#ad` in the page it loads; one given none shows it.
    /// The page beside which each goes is in a plain view with no window.
    func testTheHiddenPageHidesWithTheListsItIsGiven() async throws {
        let list = try await compiledList()
        let page = makePage()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        page.view.frame = parent.bounds
        parent.addSubview(page.view)
        addTeardownBlock { @MainActor in withExtendedLifetime(parent) {} }
        XCTAssertNil(parent.window)

        let hiding = WebKitHiddenPage(beside: page.view, ruleLists: [list], appWorld: Page.world,
                                      allows: { _ in true })
        defer { hiding.stop() }
        let hidden = try await displayInHiddenPage(hiding, "Hidden Page")
        XCTAssertEqual(hidden, "none", "the hidden page's list didn't hide the element")

        let plain = WebKitHiddenPage(beside: page.view, ruleLists: [], appWorld: Page.world,
                                     allows: { _ in true })
        defer { plain.stop() }
        let shown = try await displayInHiddenPage(plain, "Plain Hidden Page")
        XCTAssertEqual(shown, "block", "the hidden page given no lists hid the element")
    }

    // MARK: Helpers

    /// One rule: `#ad` hidden in every document.
    private static let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#ad"}}]
        """

    /// What the element's style says of how it shows.
    private static let displayCall = "return getComputedStyle(document.getElementById('ad')).display;"

    /// A page named `title` with the element a rule hides.
    private static func adHTML(_ title: String) -> String {
        "<!doctype html><title>\(title)</title><div id=\"ad\">Advertisement</div><p>\(title)</p>"
    }

    /// The list, compiled into a store at a folder of the test's own,
    /// removed after the test. Never the default store.
    private func compiledList(file: StaticString = #filePath, line: UInt = #line) async throws -> any WebRuleList {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eglu-tests-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let raw = try XCTUnwrap(WKContentRuleListStore(url: folder), "no store at the test's folder", file: file, line: line)
        XCTAssertFalse(raw === WKContentRuleListStore.default(), "the test's store is the default one", file: file, line: line)
        let store = WebKitRuleListStore(store: raw)
        let (made, error) = await withCheckedContinuation { (done: CheckedContinuation<((any WebRuleList)?, (any Error)?), Never>) in
            store.compile(forIdentifier: "eglu-tests.ad", encodedRules: Self.rules) { list, error in
                done.resume(returning: (list, error))
            }
        }
        XCTAssertNil(error, "the list didn't compile", file: file, line: line)
        let list = try XCTUnwrap(made, "no list compiled", file: file, line: line)
        XCTAssertTrue(list is WebKitRuleList, "the compiled list is a \(type(of: list))", file: file, line: line)
        XCTAssertEqual(list.identifier, "eglu-tests.ad", file: file, line: line)
        return list
    }

    /// Loads the page named `title` with the element into the page's view,
    /// from a string with no base, and waits for it.
    private func loadAdPage(_ page: Page, _ title: String, file: StaticString = #filePath, line: UInt = #line) async {
        page.view.loadHTMLString(Self.adHTML(title), baseURL: nil)
        await waitForPage(page, titled: title, file: file, line: line)
    }

    /// How the page's element shows, read in the page's own world.
    private func displayInPageWorld(_ page: Page) async throws -> String? {
        try await page.view.callAsyncJavaScript(Self.displayCall, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    /// The hidden page's view loads the page named `title` with the
    /// element, from a string with no base; once it has, the hidden page
    /// says how the element shows, read in the app's world.
    private func displayInHiddenPage(_ hidden: WebKitHiddenPage, _ title: String,
                                     file: StaticString = #filePath, line: UInt = #line) async throws -> String? {
        let view = try kept("view", of: hidden, as: WKWebView.self, file: file, line: line)
        XCTAssertTrue(view.navigationDelegate === hidden, file: file, line: line)
        view.loadHTMLString(Self.adHTML(title), baseURL: nil)
        await waitFor("the hidden page loaded \(title)", file: file, line: line) {
            view.title == title && !view.isLoading
        }
        return try await hidden.callInAppWorld(Self.displayCall, arguments: [:]) as? String
    }

    /// The identifiers of the blocker's lists the page has (PageBlocking.identifiers).
    private func blockingIdentifiers(of page: Page, file: StaticString = #filePath,
                                     line: UInt = #line) throws -> [String] {
        let blocking = try kept("blocking", of: page, as: PageBlocking.self, file: file, line: line)
        return try kept("identifiers", of: blocking, as: [String].self, file: file, line: line)
    }

    /// A value `subject` keeps to itself, read by its name.
    private func kept<T>(_ name: String, of subject: Any, as type: T.Type = T.self,
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let child = try XCTUnwrap(Mirror(reflecting: subject).children.first { $0.label == name },
                                  "\(Swift.type(of: subject)) keeps no \(name)", file: file, line: line)
        return try XCTUnwrap(child.value as? T, "\(name) is a \(Swift.type(of: child.value))", file: file, line: line)
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
