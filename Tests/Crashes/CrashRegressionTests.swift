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

    func testOverviewFilterMatchesNamesAddressesAndUnicode() throws {
        let home = try XCTUnwrap(URL(string: "https://example.com/%ED%95%9C%EA%B8%80"))
        let pin = TabRecord(url: URL(string: "https://away.test/path"), title: "Café 한글 👩‍💻", pinned: home)
        for query in ["", " \n ", "CAFE", "한글", "👩‍💻", "cafe example.com", "AWAY.test", "%ED%95%9C%EA%B8%80"] {
            XCTAssertTrue(TabOverviewFilter(query).matches(pin), query)
        }
        XCTAssertFalse(TabOverviewFilter("missing").matches(pin))
        XCTAssertFalse(TabOverviewFilter("cafe missing").matches(pin))
        XCTAssertTrue(TabOverviewFilter(TabRecord(url: nil).label).matches(TabRecord(url: nil)))
        let long = TabRecord(url: nil, title: String(repeating: "a", count: 80) + " final")
        XCTAssertTrue(TabOverviewFilter("final").matches(long))
    }

    func testOverviewFilteringPreservesIdentitySpaceAndEmptyStates() async throws {
        let session = Session.shared
        let alpha = TabRecord(url: URL(string: "https://alpha.test/"), title: "Alpha café")
        let beta = TabRecord(url: URL(string: "https://beta.test/"), title: "Beta 한글")
        let pin = TabRecord(url: URL(string: "https://pin.test/"), title: "Pinned page", pinned: URL(string: "https://pin.test/"))
        let hidden = TabRecord(url: URL(string: "https://hidden.test/"), title: "Hidden pin", pinned: URL(string: "https://hidden.test/"))
        let space = Space(name: "Filter regression", symbol: "square", tabs: [pin, hidden, alpha, beta])
        let other = Space(name: "Other Space", symbol: "circle", tabs: [TabRecord(url: nil, title: "Other Space only")])
        session.change { $0.spaces.append(contentsOf: [space, other]) }
        session.preferences.hiddenPinnedTabs.insert(hidden.id)
        defer {
            session.preferences.hiddenPinnedTabs.remove(hidden.id)
            session.change { $0.spaces.removeAll { $0.id == space.id || $0.id == other.id } }
        }
        let model = WindowModel(spaceID: space.id)
        model.tabID = alpha.id
        var chosen: UUID?
        let overview = TabOverviewController(session: session, window: model, act: { _ in }, done: { action in
            if case .select(let id)? = action { chosen = id }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = overview
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        overview.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        overview.view.layoutIfNeeded()
        let collection = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let search = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UISearchBar }.first)
        let empty = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UIContentUnavailableView }.first)
        let dock = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? PinnedDock }.first)
        let newTab = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == String(localized: "New Tab") })
        let keyboard = overview.view.convert(CGRect(x: 0, y: 460, width: 393, height: 240), to: window)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: window.convert(keyboard, to: window.screen.coordinateSpace),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ])
        overview.view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(newTab.frame.maxY, 460, "Footer must clear the docked software keyboard")
        XCTAssertLessThanOrEqual(dock.frame.maxY, 460)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 5000, width: 393, height: 240),
        ])
        func filter(_ query: String) {
            search.text = query
            overview.searchBar(search, textDidChange: query)
            overview.view.layoutIfNeeded()
            collection.layoutIfNeeded()
        }
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2)
        XCTAssertTrue(empty.isHidden)
        filter("beta")
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        XCTAssertFalse(collection.dragInteractionEnabled)
        overview.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertEqual(chosen, beta.id, "Selection must use the filtered tab's identity, not its original index")
        XCTAssertTrue(dock.isHidden)
        filter("Other Space only")
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.text, String(localized: "No matching tabs"))
        filter("hidden")
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.text, String(localized: "No matching tabs"))
        filter("pinned page")
        XCTAssertFalse(dock.isHidden)
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.text, String(localized: "Pinned tabs"))
        filter("")
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2)
        XCTAssertTrue(collection.dragInteractionEnabled)
        XCTAssertEqual(session.workspace.space(space.id)?.tabs.map(\.id), space.tabs.map(\.id))
        filter("cafe")
        session.change { $0.record(beta.id, url: beta.url, title: "Café updated") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2, "Live title changes must update filtered results")
        model.spaceID = other.id
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 0)
        filter("")
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        session.change { workspace in
            guard let index = workspace.spaces.firstIndex(where: { $0.id == other.id }) else { return }
            workspace.spaces[index].tabs = []
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.text, String(localized: "No tabs to show"))
        XCTAssertFalse(empty.isHidden)
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
