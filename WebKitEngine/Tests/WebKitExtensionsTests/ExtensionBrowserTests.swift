#if os(macOS)
import AppKit
import Combine
import WebEngineAppKit
import WebKit
import WebKitMacPlugin
import XCTest
@testable import WebKitExtensions

@MainActor
private final class BrowserHost: ExtensionBrowserHost {
    @Published var published = ExtensionBrowserWorkspace(spaces: [])
    var workspace: ExtensionBrowserWorkspace { published }
    var live: [UUID: ExtensionBrowserPage] = [:]
    var popupPages: [UUID: ExtensionBrowserPage] = [:]
    var windows: [UUID: ExtensionBrowserWindow] = [:]
    var calls: [String] = []
    var focusedSpace: UUID?
    var opened: UUID?
    var popupID = UUID()
    var popupClosed: (@MainActor () -> Void)?
    var focused: (@MainActor (ExtensionBrowserFocus) -> Void)?
    var watching: AnyCancellable?
    var afterWorkspace: (() -> Void)?
    var onInitialPopupLoad: (() -> Void)?
    var onConfiguration: (() -> Void)?

    func observe(workspace: @escaping @MainActor (ExtensionBrowserWorkspace) -> Void,
                 focus: @escaping @MainActor (ExtensionBrowserFocus) -> Void) {
        watching = $published.receive(on: DispatchQueue.main).sink { [weak self] next in
            MainActor.assumeIsolated {
                workspace(next)
                self?.afterWorkspace?()
            }
        }
        focused = focus
    }
    func record(_ tab: UUID) -> ExtensionBrowserTab? { workspace.spaces.flatMap(\.tabs).first { $0.id == tab } }
    func livePage(_ tab: UUID) -> ExtensionBrowserPage? { live[tab] }
    func window(in space: UUID) -> ExtensionBrowserWindow {
        windows[space] ?? ExtensionBrowserWindow(selected: nil, state: .minimized, frame: .null, screenFrame: .null,
                                                isVisible: false, isKey: false)
    }
    func isFocused(in space: UUID) -> Bool { focusedSpace == space }
    func openTab(_ url: URL?, in space: UUID, active: Bool, pinned: Bool, extensionID: () -> String,
                 configuration: () -> (any ExtensionPageConfiguration)?) -> UUID? {
        calls.append("open:\(space):\(url?.absoluteString ?? "nil"):\(active):\(pinned):\(extensionID())")
        onConfiguration?()
        _ = configuration()
        return opened
    }
    func activateTab(_ tab: UUID, in space: UUID) { calls.append("activate:\(tab):\(space)") }
    func closeTab(_ tab: UUID) { calls.append("close:\(tab)") }
    func loadTab(_ tab: UUID, in space: UUID, url: URL) { calls.append("load:\(tab):\(space):\(url.absoluteString)") }
    func reloadTab(_ tab: UUID, fromOrigin: Bool) { calls.append("reload:\(tab):\(fromOrigin)") }
    func goBack(_ tab: UUID) { calls.append("back:\(tab)") }
    func goForward(_ tab: UUID) { calls.append("forward:\(tab)") }
    func detectLocale(_ tab: UUID, in space: UUID, hasAccess: @escaping @MainActor (URL) -> Bool,
                      completionHandler: @escaping (Locale?, (any Error)?) -> Void) {
        calls.append("locale:\(tab):\(space)")
        completionHandler(Locale(identifier: "ko"), nil)
    }
    func setWindowFrame(_ frame: CGRect, in space: UUID) { calls.append("frame:\(space):\(frame)") }
    func focusWindow(in space: UUID) { calls.append("focus:\(space)") }
    func closeWindow(in space: UUID) -> (any Error)? {
        calls.append("closeWindow:\(space)")
        return NSError(domain: "fixture", code: 2)
    }
    func ensureWindow(in space: UUID) { calls.append("ensureWindow:\(space)") }
    func privateWindowRefusal() -> any Error { NSError(domain: "fixture", code: 3) }
    func openPopup(in space: UUID, configuration: (any ExtensionPageConfiguration)?, frame: CGRect,
                   closed: @escaping @MainActor () -> Void) -> UUID {
        calls.append("openPopup:\(space):\(configuration != nil):\(frame)")
        popupClosed = closed
        return popupID
    }
    func startPopup(_ popup: UUID, url: URL) { calls.append("startPopup:\(popup):\(url.absoluteString)"); onInitialPopupLoad?() }
    func popupPage(_ popup: UUID) -> ExtensionBrowserPage? { popupPages[popup] }
    func popupWindow(_ popup: UUID) -> ExtensionBrowserWindow { window(in: popup) }
    func loadPopup(_ popup: UUID, url: URL) -> (any Error)? { calls.append("loadPopup:\(popup):\(url.absoluteString)"); return nil }
    func reloadPopup(_ popup: UUID, fromOrigin: Bool) { calls.append("reloadPopup:\(popup):\(fromOrigin)") }
    func goBackInPopup(_ popup: UUID) { calls.append("backPopup:\(popup)") }
    func goForwardInPopup(_ popup: UUID) { calls.append("forwardPopup:\(popup)") }
    func setPopupFrame(_ frame: CGRect, popup: UUID) { calls.append("framePopup:\(popup):\(frame)") }
    func focusPopup(_ popup: UUID) { calls.append("focusPopup:\(popup)") }
    func closePopup(_ popup: UUID) {
        calls.append("closePopup:\(popup)")
        popupClosed?()
        popupClosed = nil
        popupPages[popup] = nil
    }
    func refocusFrontWindow() { calls.append("refocus") }
}

@MainActor
private final class BrowserController: WKWebExtensionController {
    var events: [String] = []
    var openedTabs: [any WKWebExtensionTab] = []
    var onEvent: (() -> Void)?
    private func event(_ text: String) { events.append(text); onEvent?() }
    private func name(_ tab: any WKWebExtensionTab) -> String { (tab as? ExtensionTab)?.id.uuidString ?? "popup" }
    override func didOpenTab(_ tab: any WKWebExtensionTab) { openedTabs.append(tab); event("open:\(name(tab))") }
    override func __didClose(_ tab: any WKWebExtensionTab, windowIsClosing: Bool) { event("close:\(name(tab)):\(windowIsClosing)") }
    override func __didActivate(_ tab: any WKWebExtensionTab, previousActiveTab: (any WKWebExtensionTab)?) {
        event("activate:\(name(tab)):\(previousActiveTab.map(name) ?? "nil")")
    }
    override func __didMove(_ tab: any WKWebExtensionTab, from index: Int, in oldWindow: (any WKWebExtensionWindow)?) {
        event("move:\(name(tab)):\(index)")
    }
    override func didChangeTabProperties(_ properties: WKWebExtension.TabChangedProperties, for tab: any WKWebExtensionTab) {
        event("properties:\(name(tab)):\(properties.rawValue)")
    }
    override func didOpenWindow(_ window: any WKWebExtensionWindow) { event("openWindow") }
    override func didCloseWindow(_ window: any WKWebExtensionWindow) { event("closeWindow") }
    override func didFocusWindow(_ window: (any WKWebExtensionWindow)?) {
        event("focus:\((window as? SpaceWindow)?.space.uuidString ?? (window == nil ? "nil" : "popup"))")
    }
}

final class ExtensionBrowserTests: XCTestCase {
    @MainActor private func context() async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Browser fixture","version":"1"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        // Parse a fixture only. No controller loads this context or an installed extension.
        let package = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "fixture"
        XCTAssertFalse(context.isLoaded)
        return context
    }

    @MainActor private func controller() -> BrowserController {
        let controller = BrowserController(configuration: ExtensionTrial.throwaway())
        XCTAssertFalse(controller.configuration.isPersistent)
        XCTAssertFalse(controller.configuration.defaultWebsiteDataStore!.isPersistent)
        XCTAssertTrue(controller.extensionContexts.isEmpty)
        return controller
    }

    @MainActor private func adapters(_ host: BrowserHost, _ controller: BrowserController,
                                     enabled: @escaping (UUID) -> Bool = { _ in true }) -> ExtensionTabs {
        ExtensionTabs(host: host, enabled: enabled, controller: { _ in controller }, othersPage: { url, context in
            guard let url, ["chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "") else { return false }
            return url.host()?.lowercased() != context.uniqueIdentifier.lowercased()
        }, refusal: { url, _ in
            url?.scheme == "file" ? NSError(domain: "fixture", code: 7) : nil
        }, heldOwner: { url in
            guard let host = url?.host(), host.hasSuffix(".chromiumapp.org") else { return nil }
            return String(host.dropLast(".chromiumapp.org".count))
        })
    }

    @MainActor private func row(_ id: UUID, _ url: String = "https://frozen.invalid/", title: String = "Frozen", pinned: Bool = false) -> ExtensionBrowserTab {
        ExtensionBrowserTab(id: id, url: URL(string: url), title: title, isPinned: pinned)
    }
    @MainActor private func workspace(_ space: UUID, _ rows: [ExtensionBrowserTab], _ selected: UUID?) -> ExtensionBrowserWorkspace {
        ExtensionBrowserWorkspace(spaces: [ExtensionBrowserSpace(id: space, tabs: rows, selected: selected)])
    }
    @MainActor private func notify(_ view: WKWebView, key: String) {
        view.willChangeValue(forKey: key)
        view.didChangeValue(forKey: key)
    }
    @MainActor private func page() -> WebKitMacPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // No load, window, download or network operation is made by this fixture.
        return WebKitMacPage(configuration: configuration)
    }

    @MainActor
    func testFrozenAnswersIdentityOrderSelectionAndWindowSnapshots() async throws {
        let context = try await context(), host = BrowserHost(), controller = controller()
        let space = UUID(), other = UUID(), a = UUID(), b = UUID()
        host.published = workspace(space, [row(a, pinned: true), row(b)], b)
        let tabs = adapters(host, controller), window = tabs.window(for: space), tab = tabs.tab(a, in: space)
        XCTAssertTrue(tab === tabs.tab(a, in: space))
        XCTAssertTrue(window === tabs.window(for: space))
        XCTAssertFalse(tab === tabs.tab(a, in: other))
        let current = tabs.tab(a, in: space)
        XCTAssertTrue((current.window(for: context) as? SpaceWindow) === window)
        XCTAssertEqual(window.tabs(for: context).compactMap { ($0 as? ExtensionTab)?.id }, [a, b])
        XCTAssertEqual((window.activeTab(for: context) as? ExtensionTab)?.id, b)
        XCTAssertEqual(current.indexInWindow(for: context), 0)
        XCTAssertEqual(tabs.tab(b, in: space).indexInWindow(for: context), 1)
        XCTAssertEqual(current.title(for: context), "Frozen")
        XCTAssertEqual(current.url(for: context), URL(string: "https://frozen.invalid/"))
        XCTAssertNil(current.webView(for: context))
        XCTAssertTrue(current.isPinned(for: context))
        XCTAssertFalse(current.isSelected(for: context))
        XCTAssertTrue(tabs.tab(b, in: space).isSelected(for: context))
        XCTAssertTrue(current.isLoadingComplete(for: context))
        XCTAssertEqual(tabs.openWindows(in: space).count, 1)
        XCTAssertTrue((tabs.openWindows(in: space).first as? SpaceWindow) === window)
        XCTAssertNil(tabs.focusedWindow(in: space))
        host.focusedSpace = space
        XCTAssertTrue((tabs.focusedWindow(in: space) as? SpaceWindow) === window)
        XCTAssertEqual(window.windowType(for: context), .normal)
        XCTAssertEqual(window.windowState(for: context), .minimized)
        XCTAssertFalse(window.isPrivate(for: context))
        XCTAssertTrue(window.frame(for: context).isNull)
        let frame = CGRect(x: 1, y: 2, width: 500, height: 400)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        host.windows[space] = ExtensionBrowserWindow(selected: a, state: .fullscreen, frame: frame, screenFrame: screen, isVisible: true, isKey: true)
        XCTAssertEqual((window.activeTab(for: context) as? ExtensionTab)?.id, a)
        XCTAssertEqual(window.windowState(for: context), .fullscreen)
        XCTAssertEqual(window.frame(for: context), frame)
        XCTAssertEqual(window.screenFrame(for: context), screen)
        host.published = workspace(space, [], nil)
        XCTAssertEqual(current.indexInWindow(for: context), 0)
        XCTAssertNil(current.title(for: context))
        XCTAssertNil(current.url(for: context))
        XCTAssertFalse(current.isPinned(for: context))
        XCTAssertTrue(controller.events.isEmpty)
    }

    @MainActor
    func testLiveViewHeldAddressesAndSealing() async throws {
        let context = try await context(), host = BrowserHost(), controller = controller()
        let space = UUID(), id = UUID(), engine = page()
        defer { engine.tearDown() }
        host.published = workspace(space, [row(id)], id)
        let tabs = adapters(host, controller), tab = tabs.tab(id, in: space)
        host.live[id] = ExtensionBrowserPage(enginePage: engine, held: nil, displayURL: nil)
        XCTAssertTrue(tab.webView(for: context) === engine.webView)
        XCTAssertEqual(tab.title(for: context), engine.webView.title ?? "Frozen")
        XCTAssertEqual(tab.url(for: context), engine.webView.url ?? URL(string: "https://frozen.invalid/"))
        XCTAssertEqual(tab.isLoadingComplete(for: context), !engine.webView.isLoading)
        let held = URL(string: "https://fixture.chromiumapp.org/code")!
        host.live[id] = ExtensionBrowserPage(enginePage: engine, held: held, displayURL: held)
        XCTAssertEqual(tab.url(for: context), held)
        context.uniqueIdentifier = "other"
        XCTAssertNil(tab.url(for: context))
        context.uniqueIdentifier = "fixture"
        host.published = workspace(space, [row(id, "chrome-extension://other/vault", title: "Hidden")], id)
        XCTAssertNil(tab.webView(for: context))
        XCTAssertNil(tab.title(for: context))
        XCTAssertNil(tab.url(for: context))
        XCTAssertFalse(tab.shouldGrantPermissionsOnUserGesture(for: context))
        host.published = workspace(space, [row(id, "https://accounts.google.com/")], id)
        host.live[id] = nil
        XCTAssertFalse(tab.shouldGrantPermissionsOnUserGesture(for: context))
    }

    @MainActor
    func testRequestsCallHostAndCompleteInlineIncludingFrozenNavigation() async throws {
        let context = try await context(), host = BrowserHost(), controller = controller()
        let space = UUID(), id = UUID(), url = URL(string: "https://request.invalid/")!
        host.opened = id
        let tabs = adapters(host, controller), tab = tabs.tab(id, in: space), window = tabs.window(for: space)
        var configurationAsked = false
        host.onConfiguration = { configurationAsked = true }
        XCTAssertTrue(tabs.open(url, in: space, active: false, pinned: true, context: context) === tab)
        XCTAssertTrue(configurationAsked)
        var completed = 0
        let done: ((any Error)?) -> Void = { error in XCTAssertNil(error); completed += 1 }
        tab.activate(for: context, completionHandler: done)
        tab.close(for: context, completionHandler: done)
        tab.loadURL(url, for: context, completionHandler: done)
        tab.reload(fromOrigin: false, for: context, completionHandler: done)
        tab.reload(fromOrigin: true, for: context, completionHandler: done)
        tab.goBack(for: context, completionHandler: done)
        tab.goForward(for: context, completionHandler: done)
        tab.detectWebpageLocale(for: context) { locale, error in XCTAssertEqual(locale?.identifier, "ko"); XCTAssertNil(error); completed += 1 }
        window.focus(for: context, completionHandler: done)
        let frame = CGRect(x: CGFloat.nan, y: 5, width: 600, height: CGFloat.nan)
        window.setFrame(frame, for: context, completionHandler: done)
        XCTAssertEqual(completed, 10)
        window.close(for: context) { error in XCTAssertEqual((error as NSError?)?.code, 2) }
        XCTAssertEqual(host.calls, ["open:\(space):\(url.absoluteString):false:true:fixture", "activate:\(id):\(space)", "close:\(id)",
            "load:\(id):\(space):\(url.absoluteString)", "reload:\(id):false", "reload:\(id):true", "back:\(id)", "forward:\(id)",
            "locale:\(id):\(space)", "focus:\(space)", "frame:\(space):\(frame)", "closeWindow:\(space)"])
        let before = host.calls
        tab.loadURL(URL(fileURLWithPath: "/fixture"), for: context) { error in XCTAssertEqual((error as NSError?)?.code, 7) }
        XCTAssertEqual(host.calls, before)
        // The original adapter implements neither request. Keep WebKit's defaults.
        XCTAssertFalse(tab.responds(to: NSSelectorFromString("setPinned:forWebExtensionContext:completionHandler:")))
        XCTAssertFalse(tab.responds(to: NSSelectorFromString("setSelected:forWebExtensionContext:completionHandler:")))
        host.opened = nil
        XCTAssertNil(tabs.open(nil, in: space, active: true, pinned: false, context: context))
    }

    @MainActor
    func testWorkspaceEventsKeepOrderIdentityAndExactlyTheSubscriptionTurn() async {
        let host = BrowserHost(), controller = controller(), space = UUID(), a = UUID(), b = UUID(), c = UUID(), d = UUID()
        host.published = workspace(space, [row(a), row(b), row(c)], a)
        let tabs = adapters(host, controller)
        let oldA = tabs.tab(a, in: space), oldB = tabs.tab(b, in: space)
        tabs.start()
        // Drain @Published's initial value before making a change.
        let initial = expectation(description: "initial workspace")
        host.afterWorkspace = { initial.fulfill() }
        await fulfillment(of: [initial], timeout: 2)
        host.afterWorkspace = nil
        XCTAssertTrue(controller.events.isEmpty)
        let delivered = expectation(description: "workspace delivered")
        var inDelivery = false
        var setterReturned = false
        controller.onEvent = { XCTAssertTrue(setterReturned); XCTAssertTrue(Thread.isMainThread); inDelivery = true }
        host.afterWorkspace = { XCTAssertTrue(inDelivery); delivered.fulfill() }
        host.published = workspace(space, [row(c, "https://changed.invalid/", title: "Changed", pinned: true), row(b), row(d)], c)
        XCTAssertTrue(controller.events.isEmpty)
        setterReturned = true
        await fulfillment(of: [delivered], timeout: 2)
        let changes: WKWebExtension.TabChangedProperties = [.URL, .title, .pinned]
        XCTAssertEqual(controller.events, ["properties:\(c):\(changes.rawValue)", "move:\(c):2", "move:\(b):1", "open:\(d)", "close:\(a):false", "activate:\(c):\(a)"])
        XCTAssertTrue(oldB === tabs.tab(b, in: space))
        XCTAssertFalse(oldA === tabs.tab(a, in: space))
        XCTAssertEqual((controller.openedTabs.first as? ExtensionTab)?.id, d)
        controller.events = []
        controller.onEvent = nil
        tabs.loadingChanged(tab: b, in: space)
        XCTAssertEqual(controller.events, ["properties:\(b):\(WKWebExtension.TabChangedProperties.loading.rawValue)"])
        host.focused?(ExtensionBrowserFocus(space: space, popup: nil))
        host.focused?(ExtensionBrowserFocus(space: nil, popup: nil))
        XCTAssertEqual(Array(controller.events.suffix(2)), ["focus:\(space)", "focus:nil"])
    }

    @MainActor
    func testPopupIdentityRequestsNotificationsAndCloseWithoutAWindowOrLoad() async throws {
        let context = try await context(), host = BrowserHost(), controller = controller(), space = UUID(), engine = page()
        defer { engine.tearDown() }
        host.popupPages[host.popupID] = ExtensionBrowserPage(enginePage: engine, held: nil, displayURL: nil)
        let tabs = adapters(host, controller)
        host.onInitialPopupLoad = { XCTAssertTrue(controller.events.isEmpty); XCTAssertTrue(ExtensionPopupWindow.all(in: space).isEmpty) }
        let popup = try XCTUnwrap(ExtensionPopupWindow.open(URL(string: "about:blank")!, for: context, in: space,
            controller: controller, frame: .null, focused: false, owner: tabs, scheme: "chrome-extension"))
        defer { if let id = popup.id { host.closePopup(id) } }
        XCTAssertNil(engine.webView.window)
        XCTAssertNil(engine.webView.url)
        XCTAssertEqual(controller.events, ["openWindow", "open:popup", "activate:popup:nil"])
        XCTAssertEqual(host.calls.last, "refocus")
        XCTAssertTrue(popup.page === engine)
        XCTAssertTrue(ExtensionPopupWindow.showing(engine) === popup)
        XCTAssertTrue((popup.tabs(for: context).first as? ExtensionPopupTab) === popup.tab)
        XCTAssertTrue((popup.activeTab(for: context) as? ExtensionPopupTab) === popup.tab)
        XCTAssertTrue((popup.tab.window(for: context) as? ExtensionPopupWindow) === popup)
        XCTAssertEqual(popup.windowType(for: context), .popup)
        XCTAssertEqual(popup.tab.indexInWindow(for: context), 0)
        XCTAssertTrue(popup.tab.isSelected(for: context))
        XCTAssertFalse(popup.isPrivate(for: context))
        XCTAssertTrue(popup.tab.webView(for: context) === engine.webView)
        XCTAssertEqual(popup.tab.title(for: context), engine.webView.title)
        XCTAssertNil(popup.tab.url(for: context))
        let frame = CGRect(x: 2, y: 3, width: 500, height: 600)
        host.windows[host.popupID] = ExtensionBrowserWindow(selected: nil, state: .minimized, frame: frame, screenFrame: frame, isVisible: true, isKey: true)
        XCTAssertTrue(ExtensionPopupWindow.key(in: space) === popup)
        XCTAssertEqual(tabs.openWindows(in: space).count, 2)
        XCTAssertTrue(tabs.openWindows(in: space).first is SpaceWindow)
        XCTAssertTrue((tabs.openWindows(in: space).last as? ExtensionPopupWindow) === popup)
        XCTAssertTrue((tabs.focusedWindow(in: space) as? ExtensionPopupWindow) === popup)
        XCTAssertEqual(popup.windowState(for: context), .minimized)
        XCTAssertEqual(popup.frame(for: context), frame)
        XCTAssertEqual(popup.screenFrame(for: context), frame)
        let done: ((any Error)?) -> Void = { XCTAssertNil($0) }
        host.calls = []
        popup.tab.loadURL(URL(string: "https://request.invalid/")!, for: context, completionHandler: done)
        popup.tab.reload(fromOrigin: false, for: context, completionHandler: done)
        popup.tab.reload(fromOrigin: true, for: context, completionHandler: done)
        popup.tab.goBack(for: context, completionHandler: done)
        popup.tab.goForward(for: context, completionHandler: done)
        popup.tab.activate(for: context, completionHandler: done)
        popup.focus(for: context, completionHandler: done)
        popup.setFrame(frame, for: context, completionHandler: done)
        let beforeProperties = controller.events.count
        var native: [WKWebExtension.TabChangedProperties] = []
        let observations = [
            engine.webView.observe(\.url) { _, _ in MainActor.assumeIsolated { native.append(.URL) } },
            engine.webView.observe(\.title) { _, _ in MainActor.assumeIsolated { native.append(.title) } },
            engine.webView.observe(\.isLoading) { _, _ in MainActor.assumeIsolated { native.append(.loading) } },
        ]
        // WebKit suppresses some unchanged properties. Compare its own KVO
        // delivery rather than assuming a manual notification changes one.
        for key in ["url", "title", "isLoading"] { notify(engine.webView, key: key) }
        XCTAssertFalse(native.isEmpty)
        XCTAssertEqual(Array(controller.events.dropFirst(beforeProperties)), native.map { "properties:popup:\($0.rawValue)" })
        withExtendedLifetime(observations) {}
        popup.tell(.loading)
        XCTAssertEqual(host.calls, ["loadPopup:\(host.popupID):https://request.invalid/", "reloadPopup:\(host.popupID):false",
            "reloadPopup:\(host.popupID):true", "backPopup:\(host.popupID)", "forwardPopup:\(host.popupID)",
            "focusPopup:\(host.popupID)", "focusPopup:\(host.popupID)", "framePopup:\(host.popupID):\(frame)"])
        popup.tab.close(for: context, completionHandler: done)
        XCTAssertEqual(Array(controller.events.suffix(2)), ["close:popup:true", "closeWindow"])
        XCTAssertNil(popup.page)
        XCTAssertNil(popup.id)
        XCTAssertTrue(ExtensionPopupWindow.all(in: space).isEmpty)
    }

    @MainActor
    func testClosedPopupTabKeepsRefusalsWithoutKeepingItsWindowAlive() async throws {
        let context = try await context(), host = BrowserHost(), controller = controller(), space = UUID(), engine = page()
        defer { engine.tearDown() }
        host.popupPages[host.popupID] = ExtensionBrowserPage(enginePage: engine, held: nil, displayURL: nil)
        let tabs = adapters(host, controller)
        var popup = try XCTUnwrap(ExtensionPopupWindow.open(URL(string: "about:blank")!, for: context, in: space,
            controller: controller, frame: .null, focused: true, owner: tabs, scheme: "chrome-extension")) as ExtensionPopupWindow?
        weak var released: ExtensionPopupWindow?
        released = popup
        let tab = try XCTUnwrap(popup?.tab)
        XCTAssertEqual(controller.events.last, "focus:popup")
        popup?.close(for: context) { XCTAssertNil($0) }
        popup = nil
        XCTAssertNil(released)
        XCTAssertNil(tab.window(for: context))
        XCTAssertNil(tab.webView(for: context))
        XCTAssertNil(tab.url(for: context))
        XCTAssertNil(tab.title(for: context))
        XCTAssertTrue(tab.isLoadingComplete(for: context))
        let calls = host.calls
        tab.loadURL(URL(fileURLWithPath: "/fixture"), for: context) { error in XCTAssertEqual((error as NSError?)?.code, 7) }
        tab.goBack(for: context) { XCTAssertNil($0) }
        tab.reload(fromOrigin: true, for: context) { XCTAssertNil($0) }
        XCTAssertEqual(host.calls, calls)
    }

    @MainActor
    func testQueuedWorkspacesUseEachSnapshotWithoutExtraTurnsOrInsertMoves() async {
        let host = BrowserHost(), controller = controller(), space = UUID(), disabled = UUID(), a = UUID(), b = UUID(), c = UUID()
        host.published = workspace(space, [row(a), row(b)], a)
        let tabs = adapters(host, controller, enabled: { $0 == space })
        tabs.start()
        let initial = expectation(description: "initial")
        host.afterWorkspace = { initial.fulfill() }
        await fulfillment(of: [initial], timeout: 2)
        let delivered = expectation(description: "two snapshots")
        delivered.expectedFulfillmentCount = 2
        var deliveries = 0
        host.afterWorkspace = {
            deliveries += 1
            XCTAssertEqual(controller.events.count, deliveries == 1 ? 2 : 4)
            delivered.fulfill()
        }
        host.published = ExtensionBrowserWorkspace(spaces: [
            ExtensionBrowserSpace(id: disabled, tabs: [row(UUID())], selected: nil),
            ExtensionBrowserSpace(id: space, tabs: [row(a), row(c), row(b)], selected: c)])
        host.published = workspace(space, [row(a), row(b)], a)
        XCTAssertTrue(controller.events.isEmpty)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(controller.events, ["open:\(c)", "activate:\(c):\(a)", "close:\(c):false", "activate:\(a):\(c)"])
    }

    @MainActor
    func testAdapterCachesDoNotKeepTheirRuntimeAlive() {
        let host = BrowserHost(), controller = controller()
        weak var runtime: ExtensionTabs?
        weak var tab: ExtensionTab?
        weak var window: SpaceWindow?
        do {
            let tabs = adapters(host, controller)
            runtime = tabs
            tab = tabs.tab(UUID(), in: UUID())
            window = tabs.window(for: UUID())
            XCTAssertNotNil(tab)
            XCTAssertNotNil(window)
        }
        XCTAssertNil(runtime)
        XCTAssertNil(tab)
        XCTAssertNil(window)
    }

}
#endif
