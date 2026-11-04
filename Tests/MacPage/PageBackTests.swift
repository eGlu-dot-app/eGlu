import XCTest
@testable import eGluMac

/// The product's Back on top of WebKit's: `Page.canGoBack` and `goBack()`
/// keep the rule the window had (WindowModel.back, refresh). Only where
/// WebKit can't go back does Back take the tab to the page a rule replaced
/// (Session.replacePage), once; otherwise it is WebKit's own.
@MainActor
final class PageBackTests: PageTestCase {
    // MARK: No replacement

    func testWithoutAReplacementBackIsWebKits() async throws {
        let (tab, _, page) = try openTab()
        XCTAssertEqual(page.canGoBack, page.view.canGoBack)
        XCTAssertFalse(page.canGoBack)

        await load(page, "One")
        XCTAssertEqual(page.canGoBack, page.view.canGoBack)
        await load(page, "Two")
        XCTAssertEqual(page.canGoBack, page.view.canGoBack)
        XCTAssertTrue(page.canGoBack)

        page.goBack()
        await waitForPage(page, titled: "One")
        XCTAssertEqual(page.canGoBack, page.view.canGoBack)
        XCTAssertFalse(page.canGoBack)
        XCTAssertTrue(page.view.canGoForward)

        // Nothing to go back to: Back does nothing, and the tab keeps its page.
        let workspace = Session.shared.workspace
        page.goBack()
        XCTAssertTrue(try livePage(tab) === page)
        XCTAssertEqual(page.view.title, "One")
        XCTAssertEqual(Session.shared.workspace, workspace)

        page.goForward()
        await waitForPage(page, titled: "Two")
    }

    // MARK: A replaced page

    /// A rule put another page in the tab's place: its view has no history,
    /// so Back is the replaced page's, history and all, and only once.
    func testBackPastAReplacementIsUsedOnce() async throws {
        let (tab, space, first) = try openTab()
        await load(first, "Before One")
        await load(first, "Before Two")

        Session.shared.replacePage(of: tab, in: space, with: Self.address("Replacement"))
        let replacement = try livePage(tab)
        XCTAssertFalse(replacement === first)
        await waitForPage(replacement, titled: "Replacement")
        XCTAssertFalse(replacement.view.canGoBack)
        XCTAssertTrue(Session.shared.canGoBackPastReplacement(tab))
        XCTAssertTrue(replacement.canGoBack, "Back past the replacement")

        replacement.goBack()
        XCTAssertFalse(Session.shared.canGoBackPastReplacement(tab), "the replacement is used up")
        let restored = try livePage(tab)
        XCTAssertFalse(restored === replacement)
        await waitForPage(restored, titled: "Before Two")
        XCTAssertTrue(restored.view.canGoBack, "the replaced page's own history came back with it")
        XCTAssertEqual(Session.shared.workspace.tab(tab)?.url, restored.view.url)

        // Back again on the page that was replaced uses nothing again.
        replacement.goBack()
        XCTAssertTrue(try livePage(tab) === restored)
        XCTAssertFalse(Session.shared.wentBackPastReplacement(tab))

        // The restored page goes back in its own history, then no further.
        XCTAssertTrue(restored.canGoBack)
        restored.goBack()
        await waitForPage(restored, titled: "Before One")
        XCTAssertTrue(try livePage(tab) === restored)
        XCTAssertFalse(restored.canGoBack)
        restored.goBack()
        XCTAssertTrue(try livePage(tab) === restored)
        XCTAssertEqual(restored.view.title, "Before One")
    }

    /// A replaced tab whose page went on to another: Back is WebKit's,
    /// and the replaced page waits until WebKit's history runs out.
    func testReplacedTabWithHistoryOfItsOwnGoesBackInWebKit() async throws {
        let (tab, space, first) = try openTab()
        await load(first, "Old")

        Session.shared.replacePage(of: tab, in: space, with: Self.address("Replacement"))
        let replacement = try livePage(tab)
        await waitForPage(replacement, titled: "Replacement")
        await load(replacement, "Later")
        XCTAssertTrue(replacement.view.canGoBack)
        XCTAssertTrue(replacement.canGoBack)

        replacement.goBack()
        await waitForPage(replacement, titled: "Replacement")
        XCTAssertTrue(try livePage(tab) === replacement, "Back went in WebKit, in the same page")
        XCTAssertTrue(Session.shared.canGoBackPastReplacement(tab), "the replacement is not used")
        XCTAssertTrue(replacement.view.canGoForward)

        // WebKit's history used up: now Back is the replaced page's.
        XCTAssertFalse(replacement.view.canGoBack)
        XCTAssertTrue(replacement.canGoBack)
        replacement.goBack()
        XCTAssertFalse(Session.shared.canGoBackPastReplacement(tab))
        let restored = try livePage(tab)
        XCTAssertFalse(restored === replacement)
        await waitForPage(restored, titled: "Old")
    }

    func testResetForgetsReplacements() async throws {
        let (tab, space, first) = try openTab()
        await load(first, "Old")
        Session.shared.replacePage(of: tab, in: space, with: Self.address("Replacement"))
        XCTAssertTrue(Session.shared.canGoBackPastReplacement(tab))
        Session.shared.resetForTests()
        XCTAssertFalse(Session.shared.canGoBackPastReplacement(tab))
        XCTAssertFalse(try livePage(tab).canGoBack)
    }

    // MARK: Transient hosts

    /// Little windows, Peeks and pop-ups give their pages fresh tab
    /// identities that no workspace has and nothing replaces: for them
    /// the rule answers no, and Back is WebKit's.
    func testTransientTabHasNoReplacement() async throws {
        let page = makePage(tab: UUID())
        let workspace = Session.shared.workspace
        let live = Set(Session.shared.pages.live.keys)

        XCTAssertFalse(Session.shared.canGoBackPastReplacement(page.tab))
        XCTAssertFalse(Session.shared.wentBackPastReplacement(page.tab))
        XCTAssertEqual(Session.shared.workspace, workspace)
        XCTAssertEqual(Set(Session.shared.pages.live.keys), live)
        XCTAssertFalse(page.canGoBack)

        await load(page, "One")
        await load(page, "Two")
        XCTAssertEqual(page.canGoBack, page.view.canGoBack)
        page.goBack()
        await waitForPage(page, titled: "One")
        XCTAssertFalse(page.canGoBack)
        page.goBack()
        XCTAssertEqual(page.view.title, "One")
        XCTAssertEqual(Session.shared.workspace, workspace, "Back changed the workspace")
        XCTAssertEqual(Set(Session.shared.pages.live.keys), live, "Back made or closed a tab's page")
    }

    /// Another tab's replacement is that tab's alone.
    func testAnotherTabsReplacementIsNotTheTransientTabs() async throws {
        let (tab, space, first) = try openTab()
        await load(first, "Old")
        Session.shared.replacePage(of: tab, in: space, with: Self.address("Replacement"))
        XCTAssertTrue(Session.shared.canGoBackPastReplacement(tab))

        let page = makePage(tab: UUID(), space: space)
        XCTAssertFalse(Session.shared.canGoBackPastReplacement(page.tab))
        XCTAssertFalse(page.canGoBack)
        XCTAssertFalse(Session.shared.wentBackPastReplacement(page.tab))
        XCTAssertTrue(Session.shared.canGoBackPastReplacement(tab), "the other tab's replacement was used")
    }
}
