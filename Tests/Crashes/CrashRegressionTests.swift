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

    func testPinnedDockAnnouncesUnloadAndReopenWithoutLosingThePin() throws {
        let session = Session.shared
        let home = try XCTUnwrap(URL(string: "https://example.com/"))
        let away = try XCTUnwrap(URL(string: "https://example.com/away"))
        let pin = TabRecord(url: home, title: "Pinned page", pinned: home)
        let space = Space(name: "Pinned state regression", symbol: "pin", tabs: [pin])
        session.change { $0.spaces.append(space) }
        defer {
            session.pages.close(pin.id)
            session.change { $0.spaces.removeAll { $0.id == space.id } }
        }
        let icon = DockIcon()
        _ = session.pages.adopt(tab: pin.id, space: space.id, configuration: WKWebViewConfiguration())
        icon.configure(tab: pin, current: true, color: .blue)
        XCTAssertEqual(icon.accessibilityValue, String(localized: "Open"))
        XCTAssertTrue(icon.accessibilityTraits.contains(.selected))

        session.change { $0.record(pin.id, url: away, title: "Away from home") }
        session.closeTab(pin.id)
        let unloaded = try XCTUnwrap(session.workspace.tab(pin.id))
        XCTAssertEqual(unloaded.url, home)
        XCTAssertEqual(unloaded.pinned, home)
        XCTAssertFalse(session.pages.isLive(pin.id))
        icon.configure(tab: unloaded, current: false, color: .blue)
        XCTAssertEqual(icon.accessibilityValue, String(localized: "Unloaded"))
        XCTAssertFalse(icon.accessibilityTraits.contains(.selected))

        _ = session.pages.adopt(tab: pin.id, space: space.id, configuration: WKWebViewConfiguration())
        icon.configure(tab: unloaded, current: true, color: .blue)
        XCTAssertEqual(icon.accessibilityValue, String(localized: "Open"))
        XCTAssertTrue(icon.accessibilityTraits.contains(.selected))
    }

    func testOverviewNamesPinnedAndOrdinaryCloseActionsDifferently() throws {
        let session = Session.shared
        let home = try XCTUnwrap(URL(string: "https://example.com/"))
        let pin = TabRecord(url: home, title: "Pinned page", pinned: home)
        let ordinary = TabRecord(url: nil, title: "Ordinary tab")
        let space = Space(name: "Pinned menu regression", symbol: "pin", tabs: [pin, ordinary])
        session.change { $0.spaces.append(space) }
        defer { session.change { $0.spaces.removeAll { $0.id == space.id } } }
        let model = WindowModel(spaceID: space.id)
        model.tabID = ordinary.id
        let overview = TabOverviewController(session: session, window: model, act: { _ in }, done: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = overview
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        overview.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        overview.view.layoutIfNeeded()

        func descendants(of view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
        func titles(in menu: UIMenu) -> [String] {
            menu.children.flatMap { element -> [String] in
                if let submenu = element as? UIMenu { return titles(in: submenu) }
                return [element.title]
            }
        }
        let icon = try XCTUnwrap(descendants(of: overview.view).compactMap { $0 as? DockIcon }.first)
        let pinnedMenu = titles(in: try XCTUnwrap(icon.menu))
        XCTAssertTrue(pinnedMenu.contains(String(localized: "Close and Unload")))
        XCTAssertFalse(pinnedMenu.contains(String(localized: "Close Tab")))
        XCTAssertTrue(pinnedMenu.contains(String(localized: "Unpin Tab")))
        XCTAssertEqual(icon.accessibilityValue, String(localized: "Unloaded"))

        let collection = try XCTUnwrap(overview.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? TabCardCell)
        let ordinaryMenu = titles(in: try XCTUnwrap(cell.menu))
        XCTAssertTrue(ordinaryMenu.contains(String(localized: "Close Tab")))
        XCTAssertFalse(ordinaryMenu.contains(String(localized: "Close and Unload")))
        XCTAssertEqual(cell.accessibilityCustomActions?.first?.name, String(localized: "Close Tab"))
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
