#if os(macOS)
import AppKit
import Combine
import WebEngineAppKit
import WebEngineCore
import WebKit
import XCTest
@testable import WebKitExtensions

private struct BrowserAnswerFailure: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

@MainActor
private final class BrowserAnswerHost: ExtensionBrowserAnswerHost {
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
    var pages: [UUID: ExtensionAnswerPage] = [:]
    var visible: [UUID: ExtensionAnswerVisibility] = [:]
    var surfaces: [ExtensionAnswerSurface] = []
    var icon: NSImage?
    var iconReads: [URL?] = []
    var panelOptions: [String: Any] = [:]
    var panelCalls: [PanelCall] = []
    var opensOnAction = false
    var presentationError: (any Error)?
    struct PanelWindow {
        let id: Int
        let space: UUID
        let tab: UUID?
        let key: Bool
    }
    var panelWindows: [PanelWindow] = []
    var pending: [String: String] = [:]
    var shownPanels: [Int: String] = [:]

    enum PanelCall: Equatable {
        case set(String, UUID, UUID?, String?, Bool?)
        case get(String, UUID, UUID?)
        case behavior(String, UUID, Bool)
        case present(ExtensionAnswerPanelPresentation, String, UUID?, UUID)
    }
    func extensionAnswerTabs(in space: UUID) -> [ExtensionBrowserTab] { workspace.space(space)?.tabs ?? [] }
    func extensionAnswerPage(_ tab: UUID) -> ExtensionAnswerPage? { pages[tab] }
    func extensionAnswerVisibleWindow(showing tab: UUID) -> ExtensionAnswerVisibility? { visible[tab] }
    func extensionAnswerSurfaces(_ kind: ExtensionAnswerSurfaceKind) -> [ExtensionAnswerSurface] { surfaces.filter { $0.kind == kind } }
    func extensionAnswerIcon(for url: URL?) -> NSImage? { iconReads.append(url); return icon }
    func setExtensionPanelOptions(_ id: String, in space: UUID, tab: UUID?, path: String?, enabled: Bool?) {
        panelCalls.append(.set(id, space, tab, path, enabled))
    }
    func extensionPanelOptions(_ id: String, in space: UUID, tab: UUID?) -> [String: Any] {
        panelCalls.append(.get(id, space, tab)); return panelOptions
    }
    func setExtensionPanelOpensOnAction(_ id: String, in space: UUID, _ on: Bool) {
        panelCalls.append(.behavior(id, space, on)); opensOnAction = on
    }
    func extensionPanelOpensOnAction(_ id: String, in space: UUID) -> Bool { opensOnAction }
    func presentExtensionPanel(_ presentation: ExtensionAnswerPanelPresentation, _ id: String, tab: UUID?, in space: UUID) throws {
        panelCalls.append(.present(presentation, id, tab, space))
        if let presentationError { throw presentationError }
        let windows = panelWindows.filter { $0.space == space }
        let key = "\(space)/\(tab?.uuidString ?? "")"
        if let tab, !windows.contains(where: { $0.tab == tab }) {
            if presentation == .open { pending[key] = id } else if pending[key] == id { pending[key] = nil }
            return
        }
        guard let window = windows.first(where: { tab != nil && $0.tab == tab }) ?? windows.first(where: { $0.key }) ?? windows.first else { return }
        if presentation == .open { shownPanels[window.id] = id } else if shownPanels[window.id] == id { shownPanels[window.id] = nil }
    }
    func releaseExtensionPage(_ view: NSView) {}
    func extensionDisplayDecision(for view: NSView) -> Int { 0 }
    func watchExtensionPage(_ view: NSView, id: String) {}
    func requestExtensionMedia(_ media: ExtensionPageMedia, name: String, reply: @escaping @MainActor (Bool) -> Void) { reply(false) }
}

/// A popup adapter can read a page without making any WebKit page or load.
@MainActor
private final class BrowserAnswerPage: WebMacPage {
    let contentView = NSView()
    var state: PageState
    let isExtensionPage = true
    var scripting: any WebPageScripting { fatalError("Unused fixture service") }
    var channels: any WebMessageChannels { fatalError("Unused fixture service") }
    var ruleListTarget: any WebRuleListTarget { fatalError("Unused fixture service") }
    var services: any WebFind & WebZoom & WebMediaCapture & WebUserAgent & WebPrinting & WebDeveloperTools & WebBackForward & WebRestoration & WebDownloadStarting { fatalError("Unused fixture service") }
    init(_ url: URL) {
        state = PageState(url: url, title: "Popup", isLoading: false, estimatedProgress: 1,
                          canGoBack: false, canGoForward: false, hasOnlySecureContent: true)
    }
    func connect(policy: any WebNavigationPolicy, navigation: any WebNavigationEvents, ui: any WebPageUIEvents,
                 presenter: any WebDialogPresenter, state: any WebPageStateEvents, view: any WebPageViewEvents) {}
    func stopObserving() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func reload() {}
    func reloadFromOrigin() {}
    func hiddenPage(ruleLists: [any WebRuleList], allows: @escaping @MainActor @Sendable (URL?) -> Bool) -> any WebHiddenPage { fatalError("Unused fixture service") }
    func takeSnapshot(with options: WebSnapshotOptions, completionHandler: @escaping @MainActor (NSImage?, (any Error)?) -> Void) { fatalError("Unused fixture service") }
    func tearDown() {}
    func load(_ request: URLRequest) { XCTFail("The answer must not load a page") }
    func loadFile(_ url: URL, allowingReadAccessTo readAccessURL: URL) { XCTFail("The answer must not load a file") }
}

@MainActor
private final class BrowserAnswerController: WKWebExtensionController {
    override func didOpenWindow(_ window: any WKWebExtensionWindow) {}
    override func didOpenTab(_ tab: any WKWebExtensionTab) {}
    override func __didActivate(_ tab: any WKWebExtensionTab, previousActiveTab: (any WKWebExtensionTab)?) {}
    override func didFocusWindow(_ window: (any WKWebExtensionWindow)?) {}
    override func __didClose(_ tab: any WKWebExtensionTab, windowIsClosing: Bool) {}
    override func didCloseWindow(_ window: any WKWebExtensionWindow) {}
}

@MainActor
private final class BrowserAnswerOffscreenView: AuxiliaryPageView {
    var address: URL?
    override var url: URL? { address }
}

final class ExtensionBrowserAnswersTests: XCTestCase {
    @MainActor private func context(_ extra: [String: Any] = [:]) async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("browser-answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Browser answers fixture", "version": "1", "permissions": ["tabs"]]
        manifest.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        // Parse only. Nothing loads an extension, a page or a controller.
        let package = try await WKWebExtension(resourceBaseURL: folder)
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "fixture"
        context.baseURL = URL(string: "chrome-extension://fixture/")!
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        XCTAssertFalse(context.isLoaded)
        return context
    }

    @MainActor private func runtime(_ host: BrowserAnswerHost) -> WebKitExtensionBrowserAnswers {
        WebKitExtensionBrowserAnswers(host: host, unanswered: { BrowserAnswerFailure(why: $0) }, scheme: "chrome-extension")
    }
    private func url(_ text: String) -> URL { URL(string: text)! }
    private func row(_ id: UUID, _ address: String = "https://frozen.invalid/", _ title: String = "Frozen") -> ExtensionBrowserTab {
        ExtensionBrowserTab(id: id, url: url(address), title: title, isPinned: false)
    }
    @MainActor private func rows(_ rows: [ExtensionBrowserTab], _ host: BrowserAnswerHost, _ space: UUID) {
        host.published = ExtensionBrowserWorkspace(spaces: [ExtensionBrowserSpace(id: space, tabs: rows, selected: rows.first?.id)])
    }
    @MainActor private func answer(_ api: String, _ args: [Any] = [], _ runtime: WebKitExtensionBrowserAnswers,
                                     _ context: WKWebExtensionContext, _ space: UUID) throws -> Any? {
        try runtime.answer(api, args, id: context.uniqueIdentifier, context: context, in: space)
    }
    private func json(_ value: Any?) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed]), encoding: .utf8)!
    }

    @MainActor
    func testTabDescriptionsKeepOrderNullsFrozenFallbacksAndLiveValues() async throws {
        let host = BrowserAnswerHost(), context = try await context(), space = UUID(), a = UUID(), b = UUID()
        let runtime = runtime(host)
        rows([row(a), row(b)], host, space)
        host.pages[b] = ExtensionAnswerPage(url: url("https://live.invalid/"), title: "Live", held: nil)
        let result = try answer("tabs.describe", [[1, NSNull(), -1, 0, 2, "0"]], runtime, context, space)
        XCTAssertEqual(try json(result), try json([["url": "https://live.invalid/", "title": "Live"], NSNull(), NSNull(),
            ["url": "https://frozen.invalid/", "title": "Frozen"], NSNull(), NSNull()]))
        host.pages[b] = ExtensionAnswerPage(url: nil, title: nil, held: nil)
        XCTAssertEqual(try json(answer("tabs.describe", [[1]], runtime, context, space)),
                       try json([["url": "https://frozen.invalid/", "title": "Frozen"]]))
        XCTAssertEqual(try json(answer("tabs.describe", ["wrong"], runtime, context, space)), "[]")
        XCTAssertEqual(try json(answer("tabs.describe", [[0]], runtime, context, UUID())), "[null]")
        XCTAssertEqual(host.iconReads.count, 3)
    }

    @MainActor
    func testHeldSignInIsShownOnlyToItsOwnerAndOtherExtensionsStayBlank() async throws {
        let host = BrowserAnswerHost(), context = try await context(), space = UUID(), a = UUID(), b = UUID(), c = UUID()
        let runtime = runtime(host)
        rows([row(a), row(b, "chrome-extension://other/saved", "Secret"), row(c)], host, space)
        let held = url("https://fixture.chromiumapp.org/code?value=fixture")
        host.pages[a] = ExtensionAnswerPage(url: url("https://signin.invalid/code"), title: "Sign in", held: held)
        host.pages[b] = ExtensionAnswerPage(url: url("https://ordinary.invalid/"), title: "Hidden", held: nil)
        host.pages[c] = ExtensionAnswerPage(url: url("chrome-extension://other/live"), title: "Hidden", held: nil)
        XCTAssertEqual(try json(answer("tabs.describe", [[0, 1, 2]], runtime, context, space)),
            try json([["url": held.absoluteString, "title": "Sign in"], ["url": "", "title": ""], ["url": "", "title": ""]]))
        context.uniqueIdentifier = "other"
        XCTAssertEqual(try json(answer("tabs.describe", [[0]], runtime, context, space)), try json([["url": "", "title": "Sign in"]]))
        XCTAssertEqual(host.iconReads, [held])
        context.setPermissionStatus(.deniedExplicitly, for: .tabs)
        XCTAssertThrowsError(try answer("tabs.describe", [[0]], runtime, context, space)) {
            XCTAssertEqual($0.localizedDescription, "eGlu doesn't answer tabs.describe.")
        }
    }

    @MainActor
    func testTabMappingChecksCurrentAddressButDoesNotSubstituteHeldAddress() {
        let host = BrowserAnswerHost(), space = UUID(), a = UUID(), runtime = runtime(host)
        rows([row(a)], host, space)
        XCTAssertEqual(runtime.tab(at: ["index": 0], in: space), a)
        XCTAssertEqual(runtime.tab(at: ["index": 0, "url": ""], in: space), a)
        XCTAssertEqual(runtime.tab(at: ["index": 0, "url": "https://frozen.invalid/"], in: space), a)
        host.pages[a] = ExtensionAnswerPage(url: url("https://live.invalid/"), title: "Live", held: url("https://fixture.chromiumapp.org/code"))
        XCTAssertNil(runtime.tab(at: ["index": 0, "url": "https://frozen.invalid/"], in: space))
        XCTAssertNil(runtime.tab(at: ["index": 0, "url": "https://fixture.chromiumapp.org/code"], in: space))
        XCTAssertEqual(runtime.tab(at: ["index": 0, "url": "https://live.invalid/"], in: space), a)
        for place: Any? in [nil, NSNull(), [:], ["index": -1], ["index": 1], ["index": "0"]] {
            XCTAssertNil(runtime.tab(at: place, in: space))
        }
        XCTAssertNil(runtime.tab(at: ["index": 0], in: UUID()))
        host.pages[a] = nil
        XCTAssertEqual(runtime.tab(at: ["index": 0, "url": "https://frozen.invalid/"], in: space), a)
    }

    @MainActor
    func testFaviconUsesCurrentImageIdentityAndMakes32PixelPNG() throws {
        let host = BrowserAnswerHost(), runtime = runtime(host), address = url("https://\(UUID().uuidString).invalid/")
        var draws = 0
        func image(_ colour: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                draws += 1; colour.setFill(); rect.fill(); return true
            }
        }
        host.icon = image(.red)
        let first = try XCTUnwrap(runtime.favIconURL(for: address))
        let drawn = draws
        XCTAssertGreaterThan(drawn, 0)
        XCTAssertEqual(runtime.favIconURL(for: address), first)
        XCTAssertEqual(draws, drawn)
        XCTAssertEqual(self.runtime(host).favIconURL(for: address), first)
        XCTAssertEqual(draws, drawn)
        let data = try XCTUnwrap(Data(base64Encoded: String(first.dropFirst("data:image/png;base64,".count))))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 32); XCTAssertEqual(bitmap.pixelsHigh, 32)
        host.icon = image(.blue)
        XCTAssertNotEqual(runtime.favIconURL(for: address), first)
        host.icon = nil
        XCTAssertNil(runtime.favIconURL(for: address))
        XCTAssertNil(runtime.favIconURL(for: nil))
        XCTAssertNil(runtime.favIconURL(for: url("about:blank")))
        XCTAssertEqual(host.iconReads.count, 5)
    }

    @MainActor
    func testOwnPagesKeepLiveTabsOcclusionSurfaceOrderAndExactIdentities() async throws {
        let host = BrowserAnswerHost(), context = try await context(), space = UUID(), a = UUID(), b = UUID(), frozen = UUID(), foreign = UUID()
        let runtime = runtime(host), own = url("chrome-extension://fixture/tab")
        rows([row(a), row(b), row(frozen, own.absoluteString), row(foreign)], host, space)
        host.pages[a] = ExtensionAnswerPage(url: own, title: "Own", held: nil)
        host.pages[b] = ExtensionAnswerPage(url: own, title: "Occluded", held: nil)
        host.pages[foreign] = ExtensionAnswerPage(url: url("chrome-extension://other/tab"), title: nil, held: nil)
        host.visible[a] = ExtensionAnswerVisibility(focused: true)
        host.surfaces = [
            ExtensionAnswerSurface(extensionID: "fixture", space: space, url: url("chrome-extension://fixture/popup"), window: 17, focused: false, kind: .popup),
            ExtensionAnswerSurface(extensionID: "fixture", space: space, url: nil, window: 18, focused: true, kind: .popup),
            ExtensionAnswerSurface(extensionID: "other", space: space, url: own, window: 19, focused: true, kind: .popup),
            ExtensionAnswerSurface(extensionID: "fixture", space: UUID(), url: own, window: 20, focused: true, kind: .popup),
            ExtensionAnswerSurface(extensionID: "fixture", space: space, url: own, window: 0, focused: true, kind: .sidePanel)]
        XCTAssertEqual(try json(answer("clients.pages", [], runtime, context, space)), try json([
            ["id": a.uuidString, "url": own.absoluteString, "visible": true, "focused": true],
            ["id": b.uuidString, "url": own.absoluteString, "visible": false, "focused": false],
            ["id": "popup-17", "url": "chrome-extension://fixture/popup", "visible": true, "focused": false, "kind": "POPUP"],
            ["id": "side_panel-0", "url": own.absoluteString, "visible": true, "focused": true, "kind": "SIDE_PANEL"]]))
        host.pages[a] = nil
        host.surfaces = []
        XCTAssertEqual((try answer("clients.pages", [], runtime, context, space) as? [[String: Any]])?.count, 1)
    }

    @MainActor
    func testContextsKeepWorkerFirstKindsFieldsAndFilters() async throws {
        let host = BrowserAnswerHost(), context = try await context(["background": ["service_worker": "worker.js"]]), space = UUID(), tab = UUID()
        let runtime = runtime(host)
        rows([row(tab)], host, space)
        host.pages[tab] = ExtensionAnswerPage(url: url("chrome-extension://fixture/tab"), title: nil, held: nil)
        host.surfaces = [ExtensionAnswerSurface(extensionID: "fixture", space: space, url: url("chrome-extension://fixture/panel"), window: 9, focused: true, kind: .sidePanel)]
        let found = try XCTUnwrap(answer("runtime.getContexts", [], runtime, context, space) as? [[String: Any]])
        XCTAssertEqual(found.compactMap { $0["contextType"] as? String }, ["BACKGROUND", "TAB", "SIDE_PANEL"])
        XCTAssertEqual(found.compactMap { $0["contextId"] as? String }, ["fixture-background", tab.uuidString, "side_panel-9"])
        XCTAssertEqual(found.compactMap { $0["frameId"] as? Int }, [-1, 0, 0])
        for record in found {
            XCTAssertEqual(record["tabId"] as? Int, -1); XCTAssertEqual(record["windowId"] as? Int, -1)
            XCTAssertEqual(record["documentOrigin"] as? String, "chrome-extension://fixture")
            XCTAssertEqual(record["incognito"] as? Bool, false)
        }
        XCTAssertEqual(found.first?["documentUrl"] as? String, "chrome-extension://fixture/worker.js")
        XCTAssertEqual(try json(answer("runtime.getContexts", [["contextTypes": ["TAB"], "documentUrls": ["chrome-extension://fixture/tab"]]], runtime, context, space)), try json([found[1]]))
        XCTAssertEqual(try json(answer("runtime.getContexts", [["contextTypes": []]], runtime, context, space)), "[]")
        XCTAssertEqual(try json(answer("runtime.getContexts", [["documentUrls": ["missing"]]], runtime, context, space)), "[]")
        XCTAssertEqual(try json(answer("runtime.getContexts", [["incognito": true]], runtime, context, space)), try json(found))
    }

    @MainActor
    func testSurfaceKindKeepsPopupPrecedenceNilMatchingAndSpaceOwnership() async throws {
        let host = BrowserAnswerHost(), context = try await context(), space = UUID(), runtime = runtime(host)
        let address = url("chrome-extension://fixture/shared")
        host.surfaces = [ExtensionAnswerSurface(extensionID: "fixture", space: space, url: address, window: 1, focused: false, kind: .sidePanel),
                         ExtensionAnswerSurface(extensionID: "fixture", space: space, url: address, window: 2, focused: false, kind: .popup)]
        XCTAssertEqual(try answer("surface.kind", [address.absoluteString], runtime, context, space) as? String, "popup")
        host.surfaces.removeLast()
        XCTAssertEqual(try answer("surface.kind", [address.absoluteString], runtime, context, space) as? String, "sidePanel")
        XCTAssertEqual(try answer("surface.kind", [address.absoluteString], runtime, context, UUID()) as? String, "tab")
        XCTAssertEqual(try answer("surface.kind", [], runtime, context, space) as? String, "tab")
        host.surfaces = [ExtensionAnswerSurface(extensionID: "fixture", space: space, url: nil, window: 0, focused: false, kind: .popup)]
        XCTAssertEqual(try answer("surface.kind", [], runtime, context, space) as? String, "popup")
    }

    @MainActor
    func testPopupPathsPreserveOverridesEmptyValuesAndPerSpaceRemoval() async throws {
        let host = BrowserAnswerHost(), context = try await context(["action": ["default_popup": "default.html?query=1"]]), space = UUID(), other = UUID()
        let runtime = runtime(host)
        XCTAssertEqual(runtime.popupURL(for: context, in: space), url("chrome-extension://fixture/default.html?query=1"))
        XCTAssertNil(try answer("action.popup", ["changed.html?query=2"], runtime, context, space))
        XCTAssertEqual(runtime.popupURL(for: context, in: space), url("chrome-extension://fixture/changed.html?query=2"))
        XCTAssertEqual(runtime.popupURL(for: context, in: other), url("chrome-extension://fixture/default.html?query=1"))
        XCTAssertNil(try answer("action.popup", [NSNull()], runtime, context, space))
        XCTAssertNil(runtime.popupURL(for: context, in: space))
        runtime.popupPaths = runtime.popupPaths.filter { !$0.key.hasSuffix("/fixture") }
        XCTAssertEqual(runtime.popupURL(for: context, in: space), url("chrome-extension://fixture/default.html?query=1"))
    }

    @MainActor
    func testRuntimeAddsPopupWindowThenOffscreenWithoutLoadingEither() async throws {
        let host = BrowserAnswerHost(), context = try await context(), space = UUID(), runtime = runtime(host)
        let page = BrowserAnswerPage(url("chrome-extension://fixture/window"))
        host.popupPages[host.popupID] = ExtensionBrowserPage(enginePage: page, held: nil, displayURL: nil)
        host.windows[host.popupID] = ExtensionBrowserWindow(selected: nil, state: .normal, frame: .null, screenFrame: .null,
                                                          isVisible: true, isKey: false)
        let controller = BrowserAnswerController(configuration: ExtensionTrial.throwaway())
        XCTAssertFalse(controller.configuration.isPersistent)
        XCTAssertFalse(controller.configuration.defaultWebsiteDataStore!.isPersistent)
        let tabs = ExtensionTabs(host: host, enabled: { _ in true }, controller: { _ in controller },
                                 othersPage: { _, _ in false }, refusal: { _, _ in nil }, heldOwner: { _ in nil })
        let popup = try XCTUnwrap(ExtensionPopupWindow.open(url("about:blank"), for: context, in: space,
            controller: controller, frame: .null, focused: true, owner: tabs, scheme: "chrome-extension"))
        defer { host.closePopup(host.popupID) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = BrowserAnswerOffscreenView(frame: .zero, configuration: configuration)
        view.address = url("chrome-extension://fixture/offscreen.html")
        let document = try ExtensionOffscreen.make("offscreen.html", reasons: [], for: context, in: space,
            scheme: "chrome-extension", host: host, configuration: { configuration }, makeView: { _, _ in view })
        defer { ExtensionOffscreen.close("fixture", in: space) }
        XCTAssertEqual((try answer("clients.pages", [], runtime, context, space) as? [[String: Any]])?.count, 1)
        document.webView(view, didFinish: nil)
        let windowID = "window-\(ObjectIdentifier(popup).hashValue)"
        XCTAssertEqual(try json(answer("clients.pages", [], runtime, context, space)), try json([
            ["id": windowID, "url": "chrome-extension://fixture/window", "visible": true, "focused": false],
            ["id": "offscreen", "url": "chrome-extension://fixture/offscreen.html", "visible": false, "focused": false]]))
        let found = try XCTUnwrap(answer("runtime.getContexts", [], runtime, context, space) as? [[String: Any]])
        XCTAssertEqual(found.compactMap { $0["contextType"] as? String }, ["TAB", "OFFSCREEN_DOCUMENT"])
        XCTAssertEqual(found.first?["contextId"] as? String, windowID)
        XCTAssertEqual(try json(answer("runtime.getContexts", [["contextTypes": ["OFFSCREEN_DOCUMENT"]]], runtime, context, space)), try json([found[1]]))
        XCTAssertEqual(try json(answer("runtime.getContexts", [["incognito": true]], runtime, context, space)), try json([found[0]]))
        XCTAssertTrue(view.loads.isEmpty)
        XCTAssertNil(view.window)
        XCTAssertTrue(controller.extensionContexts.isEmpty)
    }

    @MainActor
    func testPanelCallsLeavePendingAndWindowPresentationWithHost() async throws {
        let host = BrowserAnswerHost(), context = try await context(), space = UUID(), a = UUID(), b = UUID(), hidden = UUID()
        let runtime = runtime(host)
        rows([row(a), row(b), row(hidden)], host, space)
        host.panelWindows = [.init(id: 1, space: space, tab: a, key: false), .init(id: 2, space: space, tab: b, key: true),
                             .init(id: 3, space: UUID(), tab: hidden, key: true)]
        _ = try answer("sidePanel.open", [["tabId": 7, "__place": ["index": 2]]], runtime, context, space)
        XCTAssertEqual(host.pending["\(space)/\(hidden)"], "fixture")
        XCTAssertTrue(host.shownPanels.isEmpty)
        _ = try answer("sidePanel.close", [["tabId": 7, "__place": ["index": 2]]], runtime, context, space)
        XCTAssertTrue(host.pending.isEmpty)
        _ = try answer("sidePanel.open", [["tabId": 7, "__place": ["index": 0]]], runtime, context, space)
        XCTAssertEqual(host.shownPanels, [1: "fixture"])
        _ = try answer("sidePanel.open", [], runtime, context, space)
        XCTAssertEqual(host.shownPanels, [1: "fixture", 2: "fixture"])
        host.shownPanels[2] = "other"
        _ = try answer("sidePanel.close", [], runtime, context, space)
        XCTAssertEqual(host.shownPanels[2], "other")
        XCTAssertEqual(host.panelCalls.count, 5)
    }

    @MainActor
    func testPanelParsingMappingCallsErrorsAndInlineDelivery() async throws {
        let host = BrowserAnswerHost(), context = try await context(), space = UUID(), tab = UUID(), runtime = runtime(host)
        rows([row(tab)], host, space)
        let place: [String: Any] = ["index": 0, "url": "https://frozen.invalid/"]
        XCTAssertNil(try answer("sidePanel.setOptions", [["tabId": 7, "__place": place, "path": "panel.html", "enabled": false]], runtime, context, space))
        XCTAssertEqual(host.panelCalls, [.set("fixture", space, tab, "panel.html", false)])
        _ = try answer("sidePanel.setOptions", [["tabId": 7, "__place": ["index": 99]]], runtime, context, space)
        XCTAssertEqual(host.panelCalls.count, 1)
        _ = try answer("sidePanel.setOptions", [["__place": place]], runtime, context, space)
        XCTAssertEqual(host.panelCalls.last, .set("fixture", space, nil, nil, nil))
        host.panelOptions = ["enabled": false, "path": "fixture.html"]
        XCTAssertEqual(try json(answer("sidePanel.getOptions", [["__place": place]], runtime, context, space)), try json(host.panelOptions))
        XCTAssertEqual(host.panelCalls.last, .get("fixture", space, tab))
        _ = try answer("sidePanel.getOptions", [["tabId": 7, "__place": ["index": 99]]], runtime, context, space)
        XCTAssertEqual(host.panelCalls.last, .get("fixture", space, nil))
        _ = try answer("sidePanel.setPanelBehavior", [["openPanelOnActionClick": true]], runtime, context, space)
        XCTAssertEqual(host.panelCalls.last, .behavior("fixture", space, true))
        XCTAssertEqual(try json(answer("sidePanel.getPanelBehavior", [], runtime, context, space)), "{\"openPanelOnActionClick\":true}")
        let before = host.panelCalls
        _ = try answer("sidePanel.setPanelBehavior", [["openPanelOnActionClick": "wrong"]], runtime, context, space)
        XCTAssertEqual(host.panelCalls, before)
        for api in ["sidePanel.open", "sidePanel.close"] {
            _ = try answer(api, [["tabId": 7, "__place": place]], runtime, context, space)
            XCTAssertEqual(host.panelCalls.last, .present(api == "sidePanel.open" ? .open : .close, "fixture", tab, space))
            let count = host.panelCalls.count
            XCTAssertThrowsError(try answer(api, [["tabId": 7, "__place": ["index": 99]]], runtime, context, space)) {
                XCTAssertEqual($0.localizedDescription, "No tab with id: 7.")
            }
            XCTAssertEqual(host.panelCalls.count, count)
        }
        _ = try answer("sidePanel.open", [], runtime, context, space)
        XCTAssertEqual(host.panelCalls.last, .present(.open, "fixture", nil, space))
        host.presentationError = BrowserAnswerFailure(why: "No window to open the side panel in.")
        XCTAssertThrowsError(try answer("sidePanel.open", [], runtime, context, space)) {
            XCTAssertEqual($0.localizedDescription, "No window to open the side panel in.")
        }
    }
}
#endif
