#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import WebKitMacPlugin

/// eGlu's tabs and windows, as extensions see them.
///
/// Chrome's windows each hold tabs of their own. eGlu's spaces hold the
/// tabs, and every window showing a space lists all of them; only the tab on
/// screen is the window's own. So, to extensions, each space is one window,
/// as the person sees it too, and a frozen tab, with no page until it is
/// shown again, is like a tab Chrome has discarded: listed, with its address
/// and title, and no page to send a message to.
///
/// What changes is told to each space's controller from the workspace's own
/// changes: tabs opened, closed and moved, the one selected, their titles,
/// addresses and pins.
@MainActor
public final class ExtensionTabs {
    public let host: any ExtensionBrowserHost
    let enabled: (UUID) -> Bool
    let controller: (UUID) -> WKWebExtensionController
    let othersPage: (URL?, WKWebExtensionContext) -> Bool
    let refusal: (URL?, WKWebExtensionContext) -> (any Error)?
    let heldOwner: (URL?) -> String?

    public init(host: any ExtensionBrowserHost, enabled: @escaping (UUID) -> Bool,
                controller: @escaping (UUID) -> WKWebExtensionController,
                othersPage: @escaping (URL?, WKWebExtensionContext) -> Bool,
                refusal: @escaping (URL?, WKWebExtensionContext) -> (any Error)?,
                heldOwner: @escaping (URL?) -> String?) {
        self.host = host
        self.enabled = enabled
        self.controller = controller
        self.othersPage = othersPage
        self.refusal = refusal
        self.heldOwner = heldOwner
    }
    private var tabs: [UUID: ExtensionTab] = [:]
    private var windows: [UUID: SpaceWindow] = [:]
    private var last: ExtensionBrowserWorkspace?

    public func start() {
        last = host.workspace
        host.observe(workspace: { [weak self] next in self?.changed(to: next) },
                     focus: { [weak self] focus in self?.focused(focus) })
    }

    public func tab(_ id: UUID, in space: UUID) -> ExtensionTab {
        if let tab = tabs[id], tab.space == space { return tab }
        let tab = ExtensionTab(id: id, space: space, owner: self)
        tabs[id] = tab
        return tab
    }

    public func window(for space: UUID) -> SpaceWindow {
        if let window = windows[space] { return window }
        let window = SpaceWindow(space: space, owner: self)
        windows[space] = window
        return window
    }

    public func openWindows(in space: UUID) -> [any WKWebExtensionWindow] {
        [window(for: space)] + ExtensionPopupWindow.all(in: space)
    }

    public func focusedWindow(in space: UUID) -> (any WKWebExtensionWindow)? {
        if let popup = ExtensionPopupWindow.key(in: space) { return popup }
        guard host.isFocused(in: space) else { return nil }
        return window(for: space)
    }

    /// A tab an extension opened: in the space, loaded at once even off
    /// screen, since extensions open tabs behind and wait for them. One on
    /// an extension's own page gets a page made from the extension's
    /// configuration, as WebKit needs.
    public func open(_ url: URL?, in space: UUID, active: Bool, pinned: Bool, context: WKWebExtensionContext) -> ExtensionTab? {
        guard let id = host.openTab(url, in: space, active: active, pinned: pinned,
                                    extensionID: { context.uniqueIdentifier }, configuration: {
            context.webViewConfiguration.map { WebKitExtensionPageConfiguration($0) }
        }) else { return nil }
        return tab(id, in: space)
    }

    // MARK: Telling the controllers

    private func changed(to next: ExtensionBrowserWorkspace) {
        guard let before = last else { last = next; return }
        last = next
        for space in next.spaces {
            guard enabled(space.id) else { continue }
            let controller = self.controller(space.id)
            let old = before.space(space.id)
            let oldTabs = Dictionary(uniqueKeysWithValues: (old?.tabs ?? []).map { ($0.id, $0) })
            // Order among the tabs there before and after: a tab closed or
            // opened shifts the others' indexes without moving them.
            let kept = Set(space.tabs.map(\.id)).intersection(oldTabs.keys)
            let oldOrder = (old?.tabs ?? []).map(\.id).filter(kept.contains)
            let newOrder = space.tabs.map(\.id).filter(kept.contains)
            for record in space.tabs {
                let adapter = tab(record.id, in: space.id)
                guard let was = oldTabs[record.id] else {
                    controller.didOpenTab(adapter)
                    continue
                }
                var changes: WKWebExtension.TabChangedProperties = []
                if was.url != record.url { changes.insert(.URL) }
                if was.title != record.title { changes.insert(.title) }
                if was.isPinned != record.isPinned { changes.insert(.pinned) }
                if !changes.isEmpty { controller.didChangeTabProperties(changes, for: adapter) }
                if oldOrder.firstIndex(of: record.id) != newOrder.firstIndex(of: record.id),
                   let from = old?.tabs.firstIndex(where: { $0.id == record.id }) {
                    controller.didMoveTab(adapter, from: from, in: window(for: space.id))
                }
            }
            let now = Set(space.tabs.map(\.id))
            for record in old?.tabs ?? [] where !now.contains(record.id) {
                controller.didCloseTab(tab(record.id, in: space.id), windowIsClosing: false)
                tabs[record.id] = nil
            }
            if old?.selected != space.selected, let selected = space.selected {
                controller.didActivateTab(tab(selected, in: space.id), previousActiveTab: old?.selected.map { tab($0, in: space.id) })
            }
        }
    }

    /// A page's address changed without a load or a record of it (Page.hold).
    public func addressChanged(_ page: any WebMacPage, tab id: UUID, in space: UUID) {
        if let popup = ExtensionPopupWindow.showing(page) { return popup.tell(.URL) }
        guard enabled(space), host.workspace.spaceID(of: id) == space else { return }
        controller(space).didChangeTabProperties(.URL, for: tab(id, in: space))
    }

    /// A popup's page tells its own loading through KVO; a page of no tab
    /// has no workspace tab to tell of.
    public func loadingChanged(tab id: UUID, in space: UUID) {
        guard enabled(space), host.workspace.spaceID(of: id) == space else { return }
        controller(space).didChangeTabProperties(.loading, for: tab(id, in: space))
    }

    private func focused(_ focus: ExtensionBrowserFocus) {
        let popup = ExtensionPopupWindow.open.first { $0.id == focus.popup }
        for space in host.workspace.spaces where enabled(space.id) {
            let controller = controller(space.id)
            if let popup, popup.space == space.id {
                controller.didFocusWindow(popup)
            } else {
                controller.didFocusWindow(focus.space == space.id ? window(for: space.id) : nil)
            }
        }
    }

}

/// One tab, kept by its id apart from its page, which freezing lets go.
@MainActor
public final class ExtensionTab: NSObject, WKWebExtensionTab {
    public let id: UUID
    public let space: UUID

    // The app keeps its runtime for as long as any adapter can be asked.
    private unowned let owner: ExtensionTabs
    private var host: any ExtensionBrowserHost { owner.host }

    init(id: UUID, space: UUID, owner: ExtensionTabs) {
        self.owner = owner
        self.id = id
        self.space = space
    }

    private var record: ExtensionBrowserTab? {
        host.record(id)
    }

    private var view: WKWebView? {
        (host.livePage(id)?.enginePage as? WebKitMacPage)?.webView
    }

    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        owner.window(for: space)
    }

    public func indexInWindow(for context: WKWebExtensionContext) -> Int {
        host.workspace.space(space)?.tabs.firstIndex { $0.id == id } ?? 0
    }

    /// A tab showing another extension's page gives an extension nothing of
    /// it: no view to run a script in or take a picture of, no address, no
    /// title, whatever it was granted (Extensions.withheld). (Search)
    private func sealed(_ context: WKWebExtensionContext) -> Bool {
        owner.othersPage(view?.url, context) || owner.othersPage(record?.url, context)
    }

    public func webView(for context: WKWebExtensionContext) -> WKWebView? {
        sealed(context) ? nil : view
    }

    public func title(for context: WKWebExtensionContext) -> String? {
        sealed(context) ? nil : view?.title ?? record?.title
    }

    public func url(for context: WKWebExtensionContext) -> URL? {
        guard !sealed(context) else { return nil }
        return Self.address(of: host.livePage(id), for: context, owner: owner.heldOwner, else: view?.url ?? record?.url)
    }

    /// A held chromiumapp.org address (Page.hold), which carries a
    /// sign-in's code: the extension it belongs to sees it, others don't.
    public static func held(_ page: ExtensionBrowserPage?, for context: WKWebExtensionContext, owner: (URL?) -> String?) -> URL? {
        guard let held = page?.held, owner(held) == context.uniqueIdentifier.lowercased() else { return nil }
        return held
    }

    /// The address an extension sees for a page: `shown` as a rule; while
    /// the page holds a sign-in's address, that address for the extension
    /// it belongs to and none for any other, since what the tab showed
    /// before may carry that sign-in too.
    public static func address(of page: ExtensionBrowserPage?, for context: WKWebExtensionContext, owner: (URL?) -> String?, else shown: @autoclosure () -> URL?) -> URL? {
        guard page?.held != nil else { return shown() }
        return held(page, for: context, owner: owner)
    }

    public func isPinned(for context: WKWebExtensionContext) -> Bool {
        record?.isPinned ?? false
    }

    public func isSelected(for context: WKWebExtensionContext) -> Bool {
        host.workspace.space(space)?.selected == id
    }

    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(view?.isLoading ?? false)
    }

    /// No grant from a click on Google's sign-in, which comes before the
    /// denials in WebKit's order (ExtensionPolicy), nor on another
    /// extension's page.
    public func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        !sealed(context) && ExtensionPolicy.grantsOnClick(url(for: context))
    }

    public func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, (any Error)?) -> Void) {
        host.detectLocale(id, in: space, hasAccess: { context.hasAccess(to: $0, in: self) }, completionHandler: completionHandler)
    }

    public func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host.activateTab(id, in: space)
        completionHandler(nil)
    }

    public func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host.closeTab(id)
        completionHandler(nil)
    }

    public func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let refused = owner.refusal(url, context) { return completionHandler(refused) }
        host.loadTab(id, in: space, url: url)
        completionHandler(nil)
    }

    public func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host.reloadTab(id, fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    public func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host.goBack(id)
        completionHandler(nil)
    }

    public func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host.goForward(id)
        completionHandler(nil)
    }

}

/// A space, as the one window extensions see it in.
@MainActor
public final class SpaceWindow: NSObject, WKWebExtensionWindow {
    public let space: UUID

    // The app keeps its runtime for as long as any adapter can be asked.
    private unowned let owner: ExtensionTabs
    private var host: any ExtensionBrowserHost { owner.host }

    init(space: UUID, owner: ExtensionTabs) {
        self.space = space
        self.owner = owner
    }

    public func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        let tabs = owner
        return (host.workspace.space(space)?.tabs ?? []).map { tabs.tab($0.id, in: space) }
    }

    public func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        let selected = host.window(in: space).selected ?? host.workspace.space(space)?.selected
        return selected.map { owner.tab($0, in: space) }
    }

    public func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    public func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        switch host.window(in: space).state {
        case .normal: return .normal
        case .minimized: return .minimized
        case .fullscreen: return .fullscreen
        }
    }

    public func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    public func frame(for context: WKWebExtensionContext) -> CGRect {
        host.window(in: space).frame
    }

    public func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        host.window(in: space).screenFrame
    }

    /// windows.update with a position or a size, for the window showing the
    /// space: what is left unset comes as NaN and stays as it is, and the
    /// window never goes below its smallest size. (Search)
    public func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host.setWindowFrame(frame, in: space)
        completionHandler(nil)
    }

    public func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host.focusWindow(in: space)
        completionHandler(nil)
    }

    /// A space isn't an extension's to close.
    public func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(host.closeWindow(in: space))
    }
}
#endif
