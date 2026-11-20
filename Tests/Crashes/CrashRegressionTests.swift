import XCTest
import UIKit
import WebKit
import PadCore
@testable import eGlu

@MainActor
final class CrashRegressionTests: XCTestCase {
    func testDiscardedAlertCancelsItsReply() {
        var values: [Bool] = []
        autoreleasepool {
            let reply = DialogReply(fallback: false) { values.append($0) }
            let alert = UIAlertController(title: "Confirm", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in reply(true) })
            withExtendedLifetime(alert) { XCTAssertTrue(values.isEmpty) }
        }
        XCTAssertEqual(values, [false])
    }

    func testAnsweredDialogDoesNotReplyAgainOnCancellationOrRelease() {
        var values: [String?] = []
        autoreleasepool {
            let reply = DialogReply<String?>(fallback: nil) { values.append($0) }
            reply("typed answer")
            reply.cancel()
            reply("second answer")
        }
        XCTAssertEqual(values, ["typed answer"])
    }

    func testDiscardedPromptAndCredentialsCancel() {
        var prompts: [String?] = []
        var credentials: [URLCredential?] = []
        autoreleasepool {
            let prompt = DialogReply<String?>(fallback: nil) { prompts.append($0) }
            let login = DialogReply<URLCredential?>(fallback: nil) { credentials.append($0) }
            withExtendedLifetime((prompt, login)) {}
        }
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.allSatisfy { $0 == nil })
        XCTAssertEqual(credentials.count, 1)
        XCTAssertTrue(credentials.allSatisfy { $0 == nil })
    }

    func testOverviewLayoutAcrossWidthsAndTabUpdates() async throws {
        let session = Session.shared
        let space = Space(name: "Crash regression", symbol: "square", tabs:
            (0..<40).map { TabRecord(url: nil, title: "Test tab \($0)") })
        session.change { $0.spaces.append(space) }
        defer { session.change { $0.spaces.removeAll { $0.id == space.id } } }
        let model = WindowModel(spaceID: space.id)
        model.tabID = space.tabs.last?.id
        let overview = TabOverviewController(session: session, window: model, act: { _ in }, done: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        container.addChild(overview)
        container.view.addSubview(overview.view)
        overview.didMove(toParent: container)
        let collection = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UICollectionView }.first)
        for width in [320.0, 393.0, 402.0, 852.0, 375.0, 600.0, 320.0] {
            overview.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            overview.view.setNeedsLayout()
            overview.view.layoutIfNeeded()
            for item in [0, 20, 39, 10, 0] {
                collection.scrollToItem(at: IndexPath(item: item, section: 0), at: .centeredVertically, animated: false)
                collection.layoutIfNeeded()
                model.tabID = space.tabs[item].id
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(collection.numberOfItems(inSection: 0), 40)
            }
        }
    }

    func testOverviewCentersSelectedTabOnOpenAndAfterSwitchingSpaces() async throws {
        let session = Session.shared
        let firstTabs = makeTabs(40, named: "First")
        let secondTabs = makeTabs(40, named: "Second")
        let first = Space(name: "First overview", symbol: "square", tabs: firstTabs, selected: firstTabs[8].id)
        let second = Space(name: "Second overview", symbol: "book", tabs: secondTabs, selected: secondTabs[22].id)
        let spaces = [first, second]
        let ids = Set(spaces.map(\.id))
        session.change { $0.spaces.append(contentsOf: spaces) }
        defer { session.change { $0.spaces.removeAll { ids.contains($0.id) } } }

        let model = WindowModel(spaceID: first.id)
        model.tabID = firstTabs[8].id
        let (window, overview, collection) = try makeOverview(session: session, model: model)
        defer { window.isHidden = true }

        let openedAtSelected = try await waitForPosition(overview, collection, itemCount: 40, selectedIndex: 8)
        XCTAssertTrue(openedAtSelected)
        collection.scrollToItem(at: IndexPath(item: 39, section: 0), at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        XCTAssertGreaterThan(collection.contentOffset.y, 0)

        model.spaceID = second.id
        model.tabID = secondTabs[22].id
        let switchedToSelected = try await waitForPosition(overview, collection, itemCount: 40, selectedIndex: 22)
        XCTAssertTrue(switchedToSelected)
    }

    func testOverviewStartsAtTopWhenSelectedTabIsNotInGrid() async throws {
        let session = Session.shared
        let pinnedOrdinary = makeTabs(40, named: "Pinned ordinary")
        let unselectedOrdinary = makeTabs(40, named: "Unselected ordinary")
        let absentOrdinary = makeTabs(40, named: "Absent ordinary")
        let sourceTabs = makeTabs(40, named: "Source")
        let pinURL = URL(string: "https://example.com")
        let pinnedTab = TabRecord(url: pinURL, title: "Pinned", pinned: pinURL)
        let source = Space(name: "Source overview", symbol: "square", tabs: sourceTabs, selected: sourceTabs[10].id)
        let pinned = Space(name: "Pinned selection", symbol: "book", tabs: [pinnedTab] + pinnedOrdinary, selected: pinnedTab.id)
        let noSelection = Space(name: "No selection", symbol: "star", tabs: unselectedOrdinary)
        let absent = Space(name: "Absent selection", symbol: "heart", tabs: absentOrdinary)
        let empty = Space(name: "Empty selection", symbol: "leaf")
        let spaces = [source, pinned, noSelection, absent, empty]
        let ids = Set(spaces.map(\.id))
        session.change { $0.spaces.append(contentsOf: spaces) }
        defer { session.change { $0.spaces.removeAll { ids.contains($0.id) } } }

        let model = WindowModel(spaceID: source.id)
        model.tabID = sourceTabs[10].id
        let (window, overview, collection) = try makeOverview(session: session, model: model)
        defer { window.isHidden = true }

        let openedAtSelected = try await waitForPosition(overview, collection, itemCount: 40, selectedIndex: 10)
        XCTAssertTrue(openedAtSelected)

        for (space, tabID, itemCount) in [
            (pinned, Optional(pinnedTab.id), 40),
            (noSelection, nil, 40),
            (absent, Optional(UUID()), 40),
            (empty, nil, 0),
        ] {
            if collection.numberOfItems(inSection: 0) > 0 {
                let last = collection.numberOfItems(inSection: 0) - 1
                collection.scrollToItem(at: IndexPath(item: last, section: 0), at: .centeredVertically, animated: false)
                collection.layoutIfNeeded()
                XCTAssertGreaterThan(collection.contentOffset.y, 0)
            }
            model.spaceID = space.id
            model.tabID = tabID
            let atTop = try await waitForPosition(overview, collection, itemCount: itemCount, selectedIndex: nil)
            XCTAssertTrue(atTop, "Expected the \(space.name) grid to start at the top")
        }
    }

    func testOverviewIgnoresStalePositionRequestsAfterRapidSpaceChanges() async throws {
        let session = Session.shared
        let firstTabs = makeTabs(40, named: "First")
        let intermediateTabs = makeTabs(28, named: "Intermediate")
        let finalTabs = makeTabs(36, named: "Final")
        let first = Space(name: "First rapid", symbol: "square", tabs: firstTabs, selected: firstTabs[8].id)
        let intermediate = Space(name: "Intermediate rapid", symbol: "book", tabs: intermediateTabs,
                                 selected: intermediateTabs[12].id)
        let final = Space(name: "Final rapid", symbol: "star", tabs: finalTabs, selected: finalTabs[24].id)
        let spaces = [first, intermediate, final]
        let ids = Set(spaces.map(\.id))
        session.change { $0.spaces.append(contentsOf: spaces) }
        defer { session.change { $0.spaces.removeAll { ids.contains($0.id) } } }

        let model = WindowModel(spaceID: first.id)
        model.tabID = firstTabs[8].id
        let (window, overview, collection) = try makeOverview(session: session, model: model)
        defer { window.isHidden = true }

        let openedAtSelected = try await waitForPosition(overview, collection, itemCount: 40, selectedIndex: 8)
        XCTAssertTrue(openedAtSelected)
        collection.scrollToItem(at: IndexPath(item: 39, section: 0), at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()

        model.spaceID = intermediate.id
        model.tabID = intermediateTabs[12].id
        let intermediateApplied = try await waitForItemCount(collection, 28)
        XCTAssertTrue(intermediateApplied)
        model.spaceID = final.id
        model.tabID = finalTabs[24].id

        let finalPositioned = try await waitForPosition(overview, collection, itemCount: 36, selectedIndex: 24)
        XCTAssertTrue(finalPositioned)
    }

    func testOverviewPreservesSameSpaceScrollAcrossUpdatesAndResize() async throws {
        let session = Session.shared
        let tabs = makeTabs(40, named: "Same space")
        let space = Space(name: "Same-space updates", symbol: "square", tabs: tabs, selected: tabs[8].id)
        session.change { $0.spaces.append(space) }
        defer { session.change { $0.spaces.removeAll { $0.id == space.id } } }

        let model = WindowModel(spaceID: space.id)
        model.tabID = tabs[8].id
        let (window, overview, collection) = try makeOverview(session: session, model: model)
        defer { window.isHidden = true }

        let openedAtSelected = try await waitForPosition(overview, collection, itemCount: 40, selectedIndex: 8)
        XCTAssertTrue(openedAtSelected)
        collection.scrollToItem(at: IndexPath(item: 30, section: 0), at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        let userOffset = collection.contentOffset.y

        model.tabID = tabs[12].id
        session.change { workspace in
            guard let index = workspace.spaces.firstIndex(where: { $0.id == space.id }) else { return }
            workspace.spaces[index].tabs[0].title = "Updated title"
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(collection.contentOffset.y, userOffset, accuracy: 1)

        overview.view.frame.size.height += 24
        overview.view.setNeedsLayout()
        overview.view.layoutIfNeeded()
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.contentOffset.y, userOffset, accuracy: 1)
    }

    func testCachedPreviewWhileOpeningOverviewDoesNotReenterSnapshot() async throws {
        let session = Session.shared
        let tab = TabRecord(url: URL(string: "about:blank"), title: "Cached local page")
        let space = Space(name: "Cached preview regression", symbol: "square", tabs: [tab])
        session.change { $0.spaces.append(space) }
        defer {
            session.pages.close(tab.id)
            session.change { $0.spaces.removeAll { $0.id == space.id } }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let page = session.pages.adopt(tab: tab.id, space: space.id, configuration: WKWebViewConfiguration())
        page.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        container.view.addSubview(page.view)
        page.view.loadHTMLString("<html><body style='background:blue'>Cached preview</body></html>", baseURL: nil)
        // Wait for a real WebKit snapshot, then force the cached, synchronous path.
        for _ in 0..<50 {
            session.pages.keepPreview(of: page)
            try await Task.sleep(for: .milliseconds(100))
            if session.pages.slidePicture(for: tab.id) != nil { break }
        }
        XCTAssertNotNil(session.pages.slidePicture(for: tab.id))
        page.view.removeFromSuperview()
        page.view.frame = .zero
        var deliveredInline = false
        session.pages.preview(for: tab.id, width: Pages.previewWidth) { image in
            deliveredInline = image != nil
        }
        XCTAssertTrue(deliveredInline, "Exercise the synchronous callback recorded in both crash groups")
        let model = WindowModel(spaceID: space.id)
        model.tabID = tab.id
        let overview = TabOverviewController(session: session, window: model, act: { _ in }, done: { _ in })
        container.addChild(overview)
        container.view.addSubview(overview.view)
        overview.didMove(toParent: container)
        overview.view.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        overview.view.layoutIfNeeded()
        let collection = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        XCTAssertFalse(collection.visibleCells.isEmpty)
    }

    func testDismissedConfirmationRepliesFalse() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let probe = DialogProbe(presenter: presenter)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        presenter.view.addSubview(web)
        web.uiDelegate = probe
        web.navigationDelegate = probe
        let loaded = expectation(description: "local page loaded")
        probe.loaded = { loaded.fulfill() }
        web.loadHTMLString("<html><body>Dismissal regression</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let presented = expectation(description: "confirmation requested")
        probe.requested = { presented.fulfill() }
        let replied = expectation(description: "dismissed confirmation answered")
        probe.replied = { value in
            XCTAssertFalse(value)
            replied.fulfill()
        }
        requestConfirmation(in: web)
        await fulfillment(of: [presented], timeout: 5)
        // Finish UIKit's presentation before dismissing without a button tap.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(presenter.presentedViewController is UIAlertController)
        presenter.dismiss(animated: false)
        await fulfillment(of: [replied], timeout: 5)
        web.uiDelegate = nil
    }

    /// UIKit can reject a presentation without invoking an action. WebKit
    /// still requires a reply, even when no alert ever reaches the screen.
    func testRejectedConfirmationRepliesFalse() async throws {
        let presenter = UIViewController()
        let probe = DialogProbe(presenter: presenter)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        web.uiDelegate = probe
        web.navigationDelegate = probe
        let loaded = expectation(description: "local page loaded")
        probe.loaded = { loaded.fulfill() }
        web.loadHTMLString("<html><body>Dialog regression</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let replied = expectation(description: "rejected confirmation answered")
        probe.replied = { value in
            XCTAssertFalse(value)
            replied.fulfill()
        }
        requestConfirmation(in: web)
        await fulfillment(of: [replied], timeout: 5)
        web.uiDelegate = nil
    }

    // Awaiting JavaScript here would wait for the dialog that the test must dismiss.
    private func requestConfirmation(in web: WKWebView) {
        web.evaluateJavaScript("confirm('Continue?')", completionHandler: nil)
    }

    private func makeTabs(_ count: Int, named name: String) -> [TabRecord] {
        (0..<count).map { TabRecord(url: nil, title: "\(name) \($0)") }
    }

    private func makeOverview(session: Session, model: WindowModel) throws -> (UIWindow, TabOverviewController, UICollectionView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        let overview = TabOverviewController(session: session, window: model, act: { _ in }, done: { _ in })
        container.addChild(overview)
        container.view.addSubview(overview.view)
        overview.didMove(toParent: container)
        overview.view.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        overview.view.setNeedsLayout()
        overview.view.layoutIfNeeded()
        let collection = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UICollectionView }.first)
        return (window, overview, collection)
    }

    private func waitForPosition(_ overview: TabOverviewController, _ collection: UICollectionView,
                                 itemCount: Int, selectedIndex: Int?) async throws -> Bool {
        for _ in 0..<100 {
            overview.view.setNeedsLayout()
            overview.view.layoutIfNeeded()
            collection.layoutIfNeeded()
            if collection.numberOfItems(inSection: 0) == itemCount {
                if let selectedIndex {
                    let path = IndexPath(item: selectedIndex, section: 0)
                    let center = collection.bounds.midY + (collection.adjustedContentInset.top - collection.adjustedContentInset.bottom) / 2
                    if let frame = collection.layoutAttributesForItem(at: path)?.frame,
                       abs(frame.midY - center) < 3 {
                        return true
                    }
                } else if abs(collection.contentOffset.y + collection.adjustedContentInset.top) < 1 {
                    return true
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForItemCount(_ collection: UICollectionView, _ itemCount: Int) async throws -> Bool {
        for _ in 0..<100 {
            collection.layoutIfNeeded()
            if collection.numberOfItems(inSection: 0) == itemCount { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@MainActor
private final class DialogProbe: NSObject, WKUIDelegate, WKNavigationDelegate {
    let presenter: UIViewController
    var loaded: (() -> Void)?
    var replied: ((Bool) -> Void)?
    var requested: (() -> Void)?

    init(presenter: UIViewController) { self.presenter = presenter }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?()
        loaded = nil
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        Dialogs.confirm(message, from: frame, on: presenter) { [weak self] value in
            completionHandler(value)
            self?.replied?(value)
        }
        requested?()
    }
}
