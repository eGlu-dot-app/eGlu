import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit
@testable import WebKitMacPlugin
import XCTest

@MainActor
private final class PageRecorder: WebPageStateEvents, WebPageViewEvents, WebNavigationPolicy,
                                  WebNavigationEvents, WebPageUIEvents, WebDialogPresenter {
    var changes: [String] = []
    var onChange: (() -> Void)?
    var finished: (() -> Void)?
    var viewEvents: [String] = []
    var consumes = false
    var customSwipe = false
    var onPrepare: (() -> Void)?
    var menu: NSMenu?
    weak var actionTarget: AnyObject?

    private func changed(_ kind: String) {
        XCTAssertTrue(Thread.isMainThread)
        changes.append(kind)
        onChange?()
    }
    func titleOrAddressChanged() { changed("title/address") }
    func loadingChanged() { changed("loading") }
    func progressChanged() { changed("progress") }
    func backOrForwardChanged() { changed("back/forward") }
    func secureContentChanged() { changed("secure") }
    func prepareSwipe() -> Bool { onPrepare?(); return customSwipe }
    func scrollWheel(_ event: NSEvent) -> Bool { viewEvents.append("scroll"); return consumes }
    func swipe(_ event: NSEvent) -> Bool { viewEvents.append("swipe"); return consumes }
    func movedToWindow() { viewEvents.append("window") }
    var menus: any WebPageMenus { MenuRecorder(owner: self) }
    func decideNavigation(_ navigation: WebNavigation, reply: @MainActor (WebNavigationDecision) -> Void) { reply(.allow) }
    func decideResponse(_ response: WebResponse, reply: @MainActor (WebResponseDecision) -> Void) { reply(.allow) }
    func navigationStarted(url: URL?) {}
    func navigationRedirected(url: URL?) {}
    func navigationCommitted(url: URL?) {}
    func navigationFinished() { finished?() }
    func navigationFailed(_ error: WebLoadError, provisional: Bool) { XCTFail("Fixture load failed: \(error)") }
    func contentProcessEnded() {}
    func navigationBecameDownload(_ download: any WebEngineCore.WebDownload) {
        // No fixture should download. Refuse every destination if WebKit does.
        download.cancel { _ in }
        XCTFail("Unexpected download")
    }
    func childRequested(_ request: any WebChildRequest) -> (any WebEngineSurface)? { nil }
    func closeRequested() { viewEvents.append("close") }
    func contextMenuOpening(link: URL?) {}
    func scrollNotHandled(_ event: NSEvent) {}
    func alert(_ message: String, host: String, done: @escaping @MainActor () -> Void) { done() }
    func confirm(_ message: String, host: String, done: @escaping @MainActor (Bool) -> Void) { done(false) }
    func prompt(_ message: String, defaultText: String?, host: String, done: @escaping @MainActor (String?) -> Void) { done(nil) }
    func openFiles(allowsMultiple: Bool, allowsDirectories: Bool, done: @escaping @MainActor ([URL]?) -> Void) { done(nil) }
}

@MainActor
private final class MenuRecorder: WebPageMenus {
    weak var owner: PageRecorder?
    init(owner: PageRecorder) { self.owner = owner }
    func detachPage() { owner = nil }
    func willOpenMenu(_ menu: NSMenu, context: any WebContextMenu) {
        owner?.menu = menu
        owner?.actionTarget = context.actionTarget
        for item in menu.items {
            if let id = item.identifier?.rawValue, let title = context.title(for: id) { item.title = title }
        }
        menu.addItem(withTitle: "App item", action: nil, keyEquivalent: "")
    }
    func handOffLinkedFile(_ sender: NSMenuItem) { owner?.viewEvents.append("handoff") }
    func openLinkInPeek(_ sender: NSMenuItem) { owner?.viewEvents.append("peek") }
}

@MainActor
private final class FrontDelegate: NSObject, WKUIDelegate {
    weak var next: (any WKUIDelegate)?
    var calls = 0
    init(next: any WKUIDelegate) { self.next = next }
    override func responds(to selector: Selector!) -> Bool {
        MainActor.assumeIsolated { super.responds(to: selector) || (next?.responds(to: selector) ?? false) }
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { MainActor.assumeIsolated { next } }
    func webViewDidClose(_ webView: WKWebView) {
        calls += 1
        next?.webViewDidClose?(webView)
    }
}

final class WebKitMacPageTests: XCTestCase {
    @MainActor private func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return config
    }

    @MainActor private func connect(_ page: WebKitMacPage, _ recorder: PageRecorder) {
        page.connect(policy: recorder, navigation: recorder, ui: recorder, presenter: recorder,
                     state: recorder, view: recorder)
    }

    @MainActor private func load(_ page: WebKitMacPage, _ recorder: PageRecorder,
                                 html: String = "<!doctype html><title>Page fixture</title><p>offline</p>") async {
        let loaded = expectation(description: "page finished")
        recorder.finished = { loaded.fulfill() }
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://page.eglu.invalid/"))
        await fulfillment(of: [loaded], timeout: 10)
        recorder.finished = nil
    }

    @MainActor
    func testObservationsMatchWebKitsOrderAndStateSynchronously() async {
        let page = WebKitMacPage(configuration: configuration())
        let recorder = PageRecorder()
        connect(page, recorder)
        defer { page.stopObserving(); page.tearDown() }
        var native: [String] = []
        let view = page.webView
        let observations = [
            view.observe(\.title) { _, _ in MainActor.assumeIsolated { native.append("title/address") } },
            view.observe(\.url) { _, _ in MainActor.assumeIsolated { native.append("title/address") } },
            view.observe(\.isLoading) { _, _ in MainActor.assumeIsolated { native.append("loading") } },
            view.observe(\.estimatedProgress) { _, _ in MainActor.assumeIsolated { native.append("progress") } },
            view.observe(\.canGoBack) { _, _ in MainActor.assumeIsolated { native.append("back/forward") } },
            view.observe(\.canGoForward) { _, _ in MainActor.assumeIsolated { native.append("back/forward") } },
            view.observe(\.hasOnlySecureContent) { _, _ in MainActor.assumeIsolated { native.append("secure") } },
        ]
        recorder.onChange = {
            XCTAssertEqual(page.state, PageState(url: view.url, title: view.title, isLoading: view.isLoading,
                estimatedProgress: view.estimatedProgress, canGoBack: view.canGoBack,
                canGoForward: view.canGoForward, hasOnlySecureContent: view.hasOnlySecureContent))
        }
        await load(page, recorder)
        XCTAssertFalse(native.isEmpty)
        XCTAssertTrue(native.contains("title/address"))
        XCTAssertTrue(native.contains("loading"))
        XCTAssertTrue(native.contains("progress"))
        XCTAssertEqual(recorder.changes, native)
        page.stopObserving()
        let count = recorder.changes.count
        await load(page, recorder, html: "<!doctype html><title>Second</title>")
        XCTAssertEqual(recorder.changes.count, count)
        observations.forEach { $0.invalidate() }
        recorder.onChange = nil
    }

    /// Each of the seven observations reaches the page within WebKit's own
    /// change notification, not later: a change told by hand is heard
    /// before the next line runs, as the kind the page tells apart.
    @MainActor
    func testEachObservationReachesThePageAtOnce() {
        let page = WebKitMacPage(configuration: configuration())
        let recorder = PageRecorder()
        connect(page, recorder)
        defer { page.stopObserving(); page.tearDown() }
        let view = page.webView
        let keys = [("title", "title/address"), ("URL", "title/address"), ("loading", "loading"),
                    ("estimatedProgress", "progress"), ("canGoBack", "back/forward"),
                    ("canGoForward", "back/forward"), ("hasOnlySecureContent", "secure")]
        for (key, kind) in keys {
            let before = recorder.changes.count
            view.willChangeValue(forKey: key)
            view.didChangeValue(forKey: key)
            XCTAssertEqual(recorder.changes.count, before + 1, "\(key) was not heard at once")
            XCTAssertEqual(recorder.changes.last, kind, key)
        }
        page.stopObserving()
        let count = recorder.changes.count
        view.willChangeValue(forKey: "title")
        view.didChangeValue(forKey: "title")
        XCTAssertEqual(recorder.changes.count, count, "a change was heard after observing stopped")
    }

    @MainActor
    func testScriptsKeepWorldInjectionOrderAndFrameChoiceThenAreRemoved() async throws {
        let page = WebKitMacPage(configuration: configuration())
        let recorder = PageRecorder()
        connect(page, recorder)
        defer { page.stopObserving(); page.tearDown() }
        let scripts = page.scripting
        var reports: [WebMessage] = []
        let reported = expectation(description: "scripts in both frames and worlds")
        reported.expectedFulfillmentCount = 12
        for world in [WebWorld.app, .page] {
            page.channels.open("scripts", in: world) { reports.append($0); reported.fulfill() }
            for injection in [WebInjection.atDocumentStart, .atDocumentEnd] {
                for mainOnly in [true, false] {
                    let label = "\(world):\(injection):\(mainOnly)"
                    let source = page.channels.bridgeScript + "\negluBridge.post('scripts', {label: '\(label)', state: document.readyState});"
                    scripts.addUserScript(source: source, injectionTime: injection,
                                          forMainFrameOnly: mainOnly, world: world)
                }
            }
        }
        scripts.addFilterScripts(blocker: "globalThis.filterApp = 1", scriptlets: "globalThis.filterPage = 2")
        let installed = page.webView.configuration.userContentController.userScripts
        XCTAssertEqual(installed.count, 10)
        for (index, script) in installed.prefix(8).enumerated() {
            XCTAssertEqual(script.injectionTime, index % 4 < 2 ? .atDocumentStart : .atDocumentEnd)
            XCTAssertEqual(script.isForMainFrameOnly, index % 2 == 0)
        }
        XCTAssertEqual(installed[8].injectionTime, .atDocumentStart)
        XCTAssertEqual(installed[9].injectionTime, .atDocumentStart)
        XCTAssertTrue(installed[8].isForMainFrameOnly && installed[9].isForMainFrameOnly)
        await load(page, recorder, html: "<!doctype html><title>Scripts</title><iframe srcdoc='<p>child</p>'></iframe>")
        await fulfillment(of: [reported], timeout: 10)
        for world in [WebWorld.app, .page] {
            let inWorld = reports.filter { $0.world == world }
            XCTAssertEqual(inWorld.filter(\.isMainFrame).count, 4)
            XCTAssertEqual(inWorld.filter { !$0.isMainFrame }.count, 2)
            for report in inWorld {
                let body = try XCTUnwrap(report.body.foundation as? [String: String])
                let label = try XCTUnwrap(body["label"])
                // Each script ran in the world it was given.
                XCTAssertTrue(label.hasPrefix("\(world):"), "\(label) reported from \(world)")
                if label.contains("atDocumentStart") { XCTAssertEqual(body["state"], "loading") }
                if label.contains("atDocumentEnd") { XCTAssertNotEqual(body["state"], "loading") }
                if !report.isMainFrame { XCTAssertTrue(label.hasSuffix("false")) }
            }
        }
        let app = try await scripts.callAsyncJavaScript("return [globalThis.filterApp, typeof filterPage]", world: .app) as? [Any]
        let site = try await scripts.callAsyncJavaScript("return [globalThis.filterPage, typeof filterApp]", world: .page) as? [Any]
        XCTAssertEqual(app?.first as? Int, 1)
        XCTAssertEqual(site?.first as? Int, 2)
        XCTAssertEqual(app?.last as? String, "undefined")
        XCTAssertEqual(site?.last as? String, "undefined")
        scripts.removeAllUserScripts()
        XCTAssertTrue(page.webView.configuration.userContentController.userScripts.isEmpty)
        await load(page, recorder)
        for world in [WebWorld.app, .page] {
            let absent = try await scripts.callAsyncJavaScript("return [typeof egluBridge, typeof filterApp, typeof filterPage]", world: world) as? [String]
            XCTAssertEqual(absent, ["undefined", "undefined", "undefined"])
        }
        XCTAssertEqual(reports.count, 12)
    }

    @MainActor
    func testEvaluationMatchesWebKitValuesAndErrorsInEachWorld() async throws {
        let page = WebKitMacPage(configuration: configuration())
        let recorder = PageRecorder()
        connect(page, recorder)
        defer { page.stopObserving(); page.tearDown() }
        await load(page, recorder)
        let scripting = page.scripting
        for world in [WebWorld.app, .page] {
            let wkWorld: WKContentWorld = world == .app ? WebKitMacPage.appWorld : .page
            let value = world == .app ? 17 : 29
            _ = try await scripting.callAsyncJavaScript("globalThis.ownValue = n; return true", arguments: ["n": value], world: world)
            let body = "return {value: globalThis.ownValue, input: text, empty: null}"
            let arguments: [String: Any] = ["text": "fixture"]
            let actual = try await scripting.callAsyncJavaScript(body, arguments: arguments, world: world)
            let native = try await page.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: wkWorld)
            XCTAssertEqual(WebJSON(foundation: actual ?? NSNull()), WebJSON(foundation: native ?? NSNull()))
            let callback: Result<WebJSON, any Error> = await withCheckedContinuation { done in
                scripting.callAsyncJavaScript(body, arguments: arguments, world: world) { done.resume(returning: $0.map { WebJSON(foundation: $0) }) }
            }
            XCTAssertEqual(try callback.get(), WebJSON(foundation: native ?? NSNull()))
            for source in ["globalThis.ownValue", "throw new Error('fixture failure')", "("] {
                let result: Result<WebJSON, any Error> = await withCheckedContinuation { done in
                    scripting.evaluateJavaScript(source, world: world) { done.resume(returning: $0.map { WebJSON(foundation: $0) }) }
                }
                let direct: Result<WebJSON, any Error> = await withCheckedContinuation { done in
                    page.webView.evaluateJavaScript(source, in: nil, in: wkWorld) { done.resume(returning: $0.map { WebJSON(foundation: $0) }) }
                }
                compare(result, direct)
                if source == "globalThis.ownValue" { XCTAssertEqual(try result.get(), .number(Double(value))) }
            }
            let failure = "throw new Error('async fixture failure')"
            let result: Result<WebJSON, any Error> = await withCheckedContinuation { done in
                scripting.callAsyncJavaScript(failure, arguments: [:], world: world) { done.resume(returning: $0.map { WebJSON(foundation: $0) }) }
            }
            let direct: Result<WebJSON, any Error> = await withCheckedContinuation { done in
                page.webView.callAsyncJavaScript(failure, arguments: [:], in: nil, in: wkWorld) { done.resume(returning: $0.map { WebJSON(foundation: $0) }) }
            }
            compare(result, direct)
            do {
                _ = try await scripting.callAsyncJavaScript(failure, arguments: [:], world: world)
                XCTFail("The async call must throw")
            } catch {
                if case .failure(let nativeError) = direct {
                    XCTAssertEqual((error as NSError).domain, (nativeError as NSError).domain)
                    XCTAssertEqual((error as NSError).code, (nativeError as NSError).code)
                }
            }
        }
    }

    private func compare(_ result: Result<WebJSON, any Error>, _ direct: Result<WebJSON, any Error>,
                         file: StaticString = #filePath, line: UInt = #line) {
        switch (result, direct) {
        case (.success(let a), .success(let b)):
            XCTAssertEqual(a, b, file: file, line: line)
        case (.failure(let a), .failure(let b)):
            XCTAssertEqual((a as NSError).domain, (b as NSError).domain, file: file, line: line)
            XCTAssertEqual((a as NSError).code, (b as NSError).code, file: file, line: line)
            XCTAssertEqual((a as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String,
                           (b as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String, file: file, line: line)
        default: XCTFail("Different outcomes", file: file, line: line)
        }
    }

    @MainActor
    func testViewOffersEventsFirstAndFallsThroughOnlyWhenDeclined() throws {
        let page = WebKitMacPage(configuration: configuration())
        let recorder = PageRecorder()
        connect(page, recorder)
        defer { page.stopObserving(); page.tearDown() }
        // No window or event delivery is needed. Test the forwarding methods
        // the overrides use, with their superclass calls supplied as closures.
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        for consumes in [true, false] {
            recorder.consumes = consumes
            recorder.viewEvents = []
            page.webView.forwardScrollWheel(event) { recorder.viewEvents.append("WebKit scroll") }
            page.webView.forwardSwipe(event) { recorder.viewEvents.append("WebKit swipe") }
            XCTAssertEqual(recorder.viewEvents, consumes ? ["scroll", "swipe"]
                : ["scroll", "WebKit scroll", "swipe", "WebKit swipe"])
        }
        recorder.viewEvents = []
        page.webView.viewDidMoveToWindow()
        XCTAssertEqual(recorder.viewEvents, ["window"])
        page.tearDown()
        recorder.viewEvents = []
        page.webView.forwardScrollWheel(event) { recorder.viewEvents.append("WebKit scroll") }
        XCTAssertEqual(recorder.viewEvents, ["WebKit scroll"])
    }

    @MainActor
    func testMenuHookUsesSameMenuAndViewTargetAndAppCanAddItems() {
        let page = WebKitMacPage(configuration: configuration())
        let recorder = PageRecorder()
        connect(page, recorder)
        defer { page.stopObserving(); page.tearDown() }
        let menu = NSMenu()
        let identifiers = ["OpenLink", "OpenImage", "OpenMedia", "OpenFrame"].map { "WKMenuItemIdentifier\($0)InNewWindow" }
        for id in identifiers {
            let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        page.webView.prepareMenu(menu)
        XCTAssertTrue(recorder.menu === menu)
        XCTAssertTrue(recorder.actionTarget === page.webView)
        XCTAssertEqual(menu.items.map(\.title), ["Open Link in New Tab", "Open Image in New Tab",
                                                "Open Video in New Tab", "Open Frame in New Tab", "App item"])
        XCTAssertFalse(page.webView.isExtensionItem(menu.items[0]))
        _ = page.webView.perform(NSSelectorFromString("openLinkInPeek:"), with: menu.items[0])
        _ = page.webView.perform(NSSelectorFromString("handOffLinkedFile:"), with: menu.items[0])
        XCTAssertEqual(recorder.viewEvents, ["peek", "handoff"])
    }

    @MainActor
    func testExtensionControllerAndDelegateChainAndViewSettings() throws {
        for extensionPage in [false, true] {
            let config = configuration()
            let controller = config.userContentController
            var factories = 0
            weak var front: FrontDelegate?
            let page = WebKitMacPage(configuration: config, extensionPage: extensionPage, extensionUIDelegate: {
                factories += 1
                let delegate = FrontDelegate(next: $0)
                front = delegate
                return delegate
            })
            let recorder = PageRecorder()
            recorder.customSwipe = extensionPage
            recorder.onPrepare = {
                XCTAssertNotNil(page.webView.navigationDelegate as? WebKitNavigationAdapter)
                XCTAssertNotNil(page.webView.uiDelegate)
                XCTAssertFalse(page.webView.allowsMagnification)
                XCTAssertFalse(page.webView.isInspectable)
            }
            connect(page, recorder)
            XCTAssertEqual(page.webView.configuration.userContentController === controller, extensionPage)
            XCTAssertEqual(factories, extensionPage ? 1 : 0)
            XCTAssertTrue(page.webView.allowsMagnification)
            XCTAssertTrue(page.webView.isInspectable)
            XCTAssertEqual(page.webView.allowsBackForwardNavigationGestures, !extensionPage)
            if extensionPage {
                let delegate = try XCTUnwrap(front)
                XCTAssertTrue(page.webView.uiDelegate === delegate)
                XCTAssertNotNil(delegate.next as? WebKitUIAdapter)
                XCTAssertTrue(delegate.responds(to: NSSelectorFromString("_webView:didNotHandleWheelEvent:")))
                delegate.webViewDidClose(page.webView)
                XCTAssertEqual(delegate.calls, 1)
            } else {
                page.webView.uiDelegate?.webViewDidClose?(page.webView)
            }
            XCTAssertEqual(recorder.viewEvents, ["close"])
            page.stopObserving()
            page.tearDown()
            XCTAssertNil(page.webView.navigationDelegate)
            XCTAssertNil(page.webView.uiDelegate)
            XCTAssertNil(page.webView.events)
            recorder.onPrepare = nil
        }
    }

    @MainActor
    func testViewAndAdaptersDoNotKeepPageRecipientAlive() {
        let page = WebKitMacPage(configuration: configuration())
        weak var recipient: PageRecorder?
        autoreleasepool {
            let recorder = PageRecorder()
            recipient = recorder
            connect(page, recorder)
        }
        XCTAssertNil(recipient)
        XCTAssertNil(page.webView.events)
        page.stopObserving()
        page.tearDown()
    }

    @MainActor
    func testKeepingScriptsAliveDoesNotExtendAdaptersOrObservations() {
        let recorder = PageRecorder()
        var scripting: (any WebPageScripting)?
        weak var plugin: WebKitMacPage?
        weak var view: WebKitPageView?
        autoreleasepool {
            let page = WebKitMacPage(configuration: configuration())
            connect(page, recorder)
            plugin = page
            view = page.webView
            scripting = page.scripting
        }
        XCTAssertNotNil(scripting)
        XCTAssertNil(plugin)
        XCTAssertNotNil(view)
        XCTAssertNil(view?.navigationDelegate)
        XCTAssertNil(view?.uiDelegate)
        scripting = nil
    }

}
