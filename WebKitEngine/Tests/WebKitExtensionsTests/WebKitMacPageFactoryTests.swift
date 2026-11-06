#if os(macOS)
import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit
@testable import WebKitMacPlugin
import XCTest
@testable import WebKitExtensions

@MainActor
private final class FactoryEvents: WebPageStateEvents, WebPageViewEvents, WebPageMenus,
                                   WebNavigationPolicy, WebNavigationEvents, WebPageUIEvents, WebDialogPresenter {
    var prepared: (() -> Void)?
    var closed = 0
    var menus: any WebPageMenus { self }
    func titleOrAddressChanged() {}
    func loadingChanged() {}
    func progressChanged() {}
    func backOrForwardChanged() {}
    func secureContentChanged() {}
    func prepareSwipe() -> Bool { prepared?(); return true }
    func scrollWheel(_ event: NSEvent) -> Bool { false }
    func swipe(_ event: NSEvent) -> Bool { false }
    func movedToWindow() {}
    func willOpenMenu(_ menu: NSMenu, context: any WebContextMenu) {}
    func handOffLinkedFile(_ sender: NSMenuItem) {}
    func openLinkInPeek(_ sender: NSMenuItem) {}
    func detachPage() {}
    func decideNavigation(_ navigation: WebNavigation, reply: @MainActor (WebNavigationDecision) -> Void) { reply(.allow) }
    func decideResponse(_ response: WebResponse, reply: @MainActor (WebResponseDecision) -> Void) { reply(.allow) }
    func navigationStarted(url: URL?) {}
    func navigationRedirected(url: URL?) {}
    func navigationCommitted(url: URL?) {}
    func navigationFinished() {}
    func navigationFailed(_ error: WebLoadError, provisional: Bool) { XCTFail("Unexpected load") }
    func contentProcessEnded() {}
    func navigationBecameDownload(_ download: any WebEngineCore.WebDownload) {
        download.cancel { _ in }
        XCTFail("Unexpected download")
    }
    func childRequested(_ request: any WebChildRequest) -> (any WebEngineSurface)? { nil }
    func closeRequested() { closed += 1 }
    func contextMenuOpening(link: URL?) {}
    func scrollNotHandled(_ event: NSEvent) {}
    func alert(_ message: String, host: String, done: @escaping @MainActor () -> Void) { done() }
    func confirm(_ message: String, host: String, done: @escaping @MainActor (Bool) -> Void) { done(false) }
    func prompt(_ message: String, defaultText: String?, host: String, done: @escaping @MainActor (String?) -> Void) { done(nil) }
    func openFiles(allowsMultiple: Bool, allowsDirectories: Bool, done: @escaping @MainActor ([URL]?) -> Void) { done(nil) }
}

@MainActor
private final class FactoryChild: NSObject, WKUIDelegate, WKNavigationDelegate {
    let factory: any WebMacPageFactory
    let space: UUID
    var child: WebKitMacPage?
    var loaded: (() -> Void)?
    var requested: (() -> Void)?
    var calls: [String] = []
    var didLoad = false

    init(factory: any WebMacPageFactory, space: UUID) { self.factory = factory; self.space = space }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { didLoad = true; loaded?() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        calls.append("request")
        let request = WebKitChildRequest(configuration: configuration, action: navigationAction, features: windowFeatures)
        child = factory.makePage(space: space, source: .child(request)) as? WebKitMacPage
        calls.append("made")
        XCTAssertNotNil(child)
        XCTAssertFalse(child?.isExtensionPage ?? true)
        XCTAssertTrue(child?.webView.configuration.websiteDataStore === configuration.websiteDataStore)
        XCTAssertTrue(child?.webView.configuration.webExtensionController === configuration.webExtensionController)
        // A website's child gets its own script controller, not its
        // opener's, just as before. (WebKitMacPage puts it into the
        // configuration WebKit hands over, so compare with the opener.)
        XCTAssertFalse(child?.webView.configuration.userContentController === webView.configuration.userContentController)
        XCTAssertTrue(child?.webView.configuration.userContentController === configuration.userContentController)
        XCTAssertNil(child?.contentView.window)
        requested?()
        calls.append("return")
        return child?.webView
    }
}

final class WebKitMacPageFactoryTests: XCTestCase {
    @MainActor private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    @MainActor private func factory(store: WKWebsiteDataStore,
                                    controller: WKWebExtensionController? = nil,
                                    extensionConfiguration: @escaping (URL, UUID) -> (any ExtensionPageConfiguration)? = { _, _ in nil }) -> WebKitMacPageFactory {
        WebKitMacPageFactory(applicationNameForUserAgent: { "Fixture Safari/605.1.15" },
            extensionController: { _ in controller }, extensionConfiguration: extensionConfiguration,
            capture: { preconditionFailure("The factory must not start capture") }, store: { _ in store })
    }

    @MainActor
    func testFreshConfigurationsAskForTheSameDependenciesInOrder() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let controller = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
        let space = UUID()
        var calls: [String] = []
        let factory: any WebMacPageFactory = WebKitMacPageFactory(
            applicationNameForUserAgent: { calls.append("agent"); return "Fixture Safari/605.1.15" },
            extensionController: { id in XCTAssertEqual(id, space); calls.append("controller"); return controller },
            extensionConfiguration: { _, id in XCTAssertEqual(id, space); calls.append("extension"); return nil },
            capture: { preconditionFailure("No capture request") },
            store: { id in XCTAssertEqual(id, space); calls.append("store"); return store })
        XCTAssertTrue(calls.isEmpty)
        for source in [WebMacPageSource.space, .tab(nil), .tab(URL(string: "https://factory.invalid/"))] {
            calls = []
            let page = try XCTUnwrap(factory.makePage(space: space, source: source) as? WebKitMacPage)
            defer { page.tearDown() }
            XCTAssertEqual(calls, sourceHasURL(source) ? ["extension", "store", "controller", "agent"] : ["store", "controller", "agent"])
            XCTAssertFalse(page.webView.configuration.websiteDataStore.isPersistent)
            XCTAssertTrue(page.webView.configuration.websiteDataStore === store)
            XCTAssertTrue(page.webView.configuration.webExtensionController === controller)
            XCTAssertEqual(page.webView.configuration.applicationNameForUserAgent, "Fixture Safari/605.1.15")
            XCTAssertEqual(page.webView.configuration.mediaTypesRequiringUserActionForPlayback, .audio)
            XCTAssertTrue(page.webView.configuration.preferences.isElementFullscreenEnabled)
            XCTAssertFalse(page.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            XCTAssertFalse(page.isExtensionPage)
            XCTAssertNil(page.contentView.window)
        }
        XCTAssertFalse(controller.configuration.isPersistent)
        XCTAssertTrue(controller.extensionContexts.isEmpty)
    }

    private func sourceHasURL(_ source: WebMacPageSource) -> Bool {
        if case .tab(.some) = source { return true }
        return false
    }

    @MainActor
    func testSuppliedAndTabExtensionConfigurationsKeepIdentityAndDelegateOrder() throws {
        let configuration = configuration()
        let controller = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
        configuration.webExtensionController = controller
        let scripts = configuration.userContentController
        scripts.addUserScript(WKUserScript(source: "globalThis.fixture = true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let handle = WebKitExtensionPageConfiguration(configuration)
        let url = URL(string: "chrome-extension://fixture/page.html")!
        let space = UUID()
        let factory = WebKitMacPageFactory(applicationNameForUserAgent: { XCTFail("Supplied agent changed"); return "" },
            extensionController: { _ in XCTFail("Supplied controller changed"); return nil },
            extensionConfiguration: { address, id in XCTAssertEqual(address, url); XCTAssertEqual(id, space); return handle },
            capture: { preconditionFailure("Wiring the delegate must not start capture") },
            store: { _ in preconditionFailure("Supplied store changed") })
        XCTAssertTrue(factory.supplied(handle) === configuration)
        for source in [WebMacPageSource.supplied(handle), .tab(url)] {
            let page = try XCTUnwrap(factory.makePage(space: space, source: source) as? WebKitMacPage)
            let events = FactoryEvents()
            defer { events.prepared = nil; page.stopObserving(); page.tearDown() }
            events.prepared = {
                XCTAssertTrue(page.webView.uiDelegate is ExtensionPageDelegate)
                XCTAssertNotNil(page.webView.navigationDelegate as? WebKitNavigationAdapter)
                XCTAssertFalse(page.webView.allowsMagnification)
                XCTAssertFalse(page.webView.isInspectable)
            }
            page.connect(policy: events, navigation: events, ui: events, presenter: events, state: events, view: events)
            let delegate = try XCTUnwrap(page.webView.uiDelegate as? ExtensionPageDelegate)
            XCTAssertTrue(delegate.next is WebKitUIAdapter)
            XCTAssertTrue(page.isExtensionPage)
            XCTAssertTrue(page.webView.configuration.userContentController === scripts)
            XCTAssertTrue(page.webView.configuration.webExtensionController === controller)
            XCTAssertTrue(page.webView.configuration.websiteDataStore === configuration.websiteDataStore)
            XCTAssertEqual(scripts.userScripts.count, 1)
            XCTAssertTrue(page.webView.allowsMagnification)
            XCTAssertTrue(page.webView.isInspectable)
            // Forward through the extension delegate to the UI adapter inline.
            let selector = NSSelectorFromString("webViewDidClose:")
            XCTAssertTrue(delegate.responds(to: selector))
            XCTAssertTrue((delegate.forwardingTarget(for: selector) as AnyObject?) === delegate.next)
            delegate.next?.webViewDidClose?(page.webView)
            XCTAssertEqual(events.closed, 1)
        }
        XCTAssertTrue(controller.extensionContexts.isEmpty)
    }

    @MainActor
    func testChildFromAnAlreadyTranslatedRequestIsMadeInline() throws {
        let configuration = configuration()
        let scripts = configuration.userContentController
        let navigation = WebNavigation(request: URLRequest(url: URL(string: "about:blank")!),
            sourceOrigin: .opaque, targetIsMainFrame: nil, kind: .other, modifiers: [],
            buttonNumber: 0, requestsDownload: false, isServerRedirect: false,
            contentRuleRedirect: nil, sourceIsMainFrame: true)
        let request = WebKitChildRequest(configuration: configuration, navigation: navigation,
            features: WebWindowFeatures(width: nil, height: nil))
        let factory: any WebMacPageFactory = WebKitMacPageFactory(
            applicationNameForUserAgent: { preconditionFailure("A child already has its agent") },
            extensionController: { _ in preconditionFailure("A child already has its controller") },
            extensionConfiguration: { _, _ in preconditionFailure("A child already has its configuration") },
            capture: { preconditionFailure("A child does not start capture") },
            store: { _ in preconditionFailure("A child already has its store") })
        let page = try XCTUnwrap(factory.makePage(space: UUID(), source: .child(request)) as? WebKitMacPage)
        defer { page.tearDown() }
        XCTAssertFalse(page.isExtensionPage)
        XCTAssertTrue(page.webView.configuration.websiteDataStore === configuration.websiteDataStore)
        XCTAssertFalse(page.webView.configuration.userContentController === scripts)
        XCTAssertNil(page.contentView.window)
        XCTAssertFalse(page.webView.configuration.websiteDataStore.isPersistent)
    }

    @MainActor
    func testChildIsMadeInlineFromWebKitsRequestAndKeepsItsOpener() async throws {
        let configuration = configuration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let parent = WebKitMacPage(configuration: configuration)
        let factory = factory(store: configuration.websiteDataStore)
        let delegate = FactoryChild(factory: factory, space: UUID())
        parent.webView.uiDelegate = delegate
        parent.webView.navigationDelegate = delegate
        defer { delegate.child?.tearDown(); parent.tearDown() }
        let loaded = expectation(description: "Local parent loaded")
        delegate.loaded = { loaded.fulfill() }
        parent.webView.loadHTMLString("<!doctype html><title>Factory fixture</title>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        delegate.loaded = nil
        guard delegate.didLoad else { return XCTFail("Local parent did not load") }
        let requested = expectation(description: "Child returned inline")
        delegate.requested = { requested.fulfill() }
        let result = try await parent.webView.callAsyncJavaScript("""
            window.marker = 'factory fixture';
            window.child = window.open('about:blank');
            return window.child !== null && window.child.opener === window;
            """, arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [requested], timeout: 10)
        XCTAssertEqual(delegate.calls, ["request", "made", "return"])
        XCTAssertEqual(result as? Bool, true)
        let child = try XCTUnwrap(delegate.child)
        let marker = try await child.webView.callAsyncJavaScript("return window.opener.marker", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(marker as? String, "factory fixture")
        XCTAssertNil(child.contentView.window)
        XCTAssertFalse(child.webView.configuration.websiteDataStore.isPersistent)
    }

    @MainActor
    func testPageDelegateDoesNotKeepItsFactoryAlive() throws {
        let configuration = configuration()
        var factory: WebKitMacPageFactory? = factory(store: configuration.websiteDataStore)
        let factories = NSHashTable<WebKitMacPageFactory>.weakObjects()
        factories.add(factory!)
        let page = try XCTUnwrap(factory?.makePage(space: UUID(), source: .supplied(WebKitExtensionPageConfiguration(configuration))) as? WebKitMacPage)
        let events = FactoryEvents()
        defer { page.stopObserving(); page.tearDown() }
        page.connect(policy: events, navigation: events, ui: events, presenter: events, state: events, view: events)
        factory = nil
        XCTAssertTrue(factories.allObjects.isEmpty)
        let delegate = try XCTUnwrap(page.webView.uiDelegate as? ExtensionPageDelegate)
        delegate.next?.webViewDidClose?(page.webView)
        XCTAssertEqual(events.closed, 1)
    }

    @MainActor
    func testCaptureQueryDoesNotAskForTheReleaseRuntime() {
        var released: NSView?
        let capture = WebExtensionPageCapture(screen: { ExtensionCaptureRuntime.screen($0) }, release: { released = $0 })
        let view = NSView()
        XCTAssertFalse(capture.isCapturing(view))
        XCTAssertNil(released)
        capture.release(view)
        XCTAssertTrue(released === view)
    }
}
#endif
