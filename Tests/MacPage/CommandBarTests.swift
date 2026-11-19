import AppKit
import PadCore
import XCTest
@testable import eGluMac

@MainActor
final class CommandBarTests: PageTestCase {
    func testDirectActionSendsTypedAddressDespiteSelectedSuggestion() async throws {
        let (model, _, page) = try await showingPage()
        defer { model.suggestions.end() }
        _ = model.suggestions.begin(in: model, purpose: .newTab)
        let index = try XCTUnwrap(model.suggestions.rows.firstIndex { $0.action == .command(.history) })
        for _ in 0...index { model.suggestions.move(1) }
        XCTAssertEqual(model.suggestions.selected?.action, .command(.history))

        model.commandBar = .here
        model.sendCommandBar(Self.address("Typed address").absoluteString, started: "", purpose: .here)

        await waitForPage(page, titled: "Typed address")
        XCTAssertFalse(model.historyShown, "the selected command must not replace the typed destination")
        XCTAssertNil(model.commandBar)
    }

    func testReturnTakesSelectedSuggestionInsteadOfTypedAddress() async throws {
        let (model, _, page) = try await showingPage()
        let before = Session.shared.workspace
        let row = Suggestion(id: "history", source: .command, action: .command(.history), phrase: "History", typed: [])
        model.commandBar = .newTab

        model.sendCommandBar(Self.address("Not taken").absoluteString, started: "", purpose: .newTab, taking: row)

        XCTAssertTrue(model.historyShown)
        XCTAssertEqual(page.state.title, "Original")
        XCTAssertEqual(Session.shared.workspace, before)
        XCTAssertNil(model.commandBar)
    }

    func testTypedAddressHereKeepsTheCurrentTab() async throws {
        let (model, tab, page) = try await showingPage()
        let count = model.space?.tabs.count
        model.commandBar = .here

        model.sendCommandBar("  " + Self.address("Here").absoluteString + "  ", started: "", purpose: .here)

        await waitForPage(page, titled: "Here")
        XCTAssertEqual(model.tabID, tab)
        XCTAssertEqual(model.space?.tabs.count, count)
        XCTAssertNil(model.commandBar)
    }

    func testTypedAddressForNewTabPreservesTheCurrentPage() async throws {
        let (model, original, page) = try await showingPage()
        let count = try XCTUnwrap(model.space?.tabs.count)
        model.commandBar = .newTab

        model.sendCommandBar(Self.address("New tab").absoluteString, started: "", purpose: .newTab)

        let opened = try XCTUnwrap(model.tabID)
        defer { if opened != original { Session.shared.closeTab(opened) } }
        XCTAssertNotEqual(opened, original)
        XCTAssertEqual(model.space?.tabs.count, count + 1)
        await waitForPage(try livePage(opened), titled: "New tab")
        XCTAssertEqual(page.state.title, "Original")
        XCTAssertNil(model.commandBar)
    }

    func testUnchangedAddressReloadsWithoutAddingATabOrHistoryEntry() async throws {
        let (model, tab, page) = try await showingPage()
        let address = try XCTUnwrap(page.state.url).absoluteString
        let count = model.space?.tabs.count
        _ = try await page.view.evaluateJavaScript("document.title = 'Changed'; 1")
        await waitUntil(page, "the document changed") { $0.title == "Changed" }
        model.commandBar = .here

        model.sendCommandBar(address, started: address, purpose: .here)

        await waitForPage(page, titled: "Original")
        XCTAssertEqual(model.tabID, tab)
        XCTAssertEqual(model.space?.tabs.count, count)
        XCTAssertFalse(page.state.canGoBack)
        XCTAssertNil(model.commandBar)
    }

    func testTypedSearchUsesTheChosenEngine() async throws {
        let (model, _, page) = try await showingPage()
        let words = "한글 design notes"
        let expected = Destination.search(words, engine: Session.shared.preferences.engine)
        model.commandBar = .here

        model.sendCommandBar(words, started: "", purpose: .here)

        XCTAssertEqual(page.displayURL, expected)
        XCTAssertNil(model.commandBar)
        page.stopLoading()
    }

    func testEmptySubmissionDismissesWithoutChangingTheWorkspace() async throws {
        let (model, _, page) = try await showingPage()
        let before = Session.shared.workspace
        model.commandBar = .newTab

        model.sendCommandBar("   ", started: "", purpose: .newTab)

        XCTAssertNil(model.commandBar)
        XCTAssertEqual(Session.shared.workspace, before)
        XCTAssertEqual(page.state.title, "Original")
    }

    func testCancelRestoresPageFocusWithoutNavigating() async throws {
        let (model, _, page) = try await showingPage()
        let before = Session.shared.workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        model.window = window
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(page.surface.view)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        content.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        model.commandBar = .here

        model.dismissCommandBar()
        let focused = expectation(description: "page focus restored")
        DispatchQueue.main.async { focused.fulfill() }
        await fulfillment(of: [focused], timeout: 2)

        XCTAssertNil(model.commandBar)
        XCTAssertTrue(window.firstResponder === page.surface.view)
        XCTAssertEqual(Session.shared.workspace, before)
        XCTAssertEqual(page.state.title, "Original")
    }

    private func showingPage() async throws -> (WindowModel, UUID, Page) {
        let (tab, space, page) = try openTab()
        let model = WindowModel(space: space)
        model.show(tab: tab, inSpace: space)
        await load(page, "Original")
        return (model, tab, page)
    }
}
