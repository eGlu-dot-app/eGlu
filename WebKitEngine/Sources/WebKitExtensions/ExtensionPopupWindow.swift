#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import WebKitMacPlugin

/// An extension's popup window: windows.create with type "popup", as a
/// password manager's vault opens (NordPass), or Bitwarden's passkey window,
/// or a sign-in. A small window of its one page (Popup), not the space's
/// window, which a space being one window to extensions made it before:
/// windows.remove failed ("A space can't be closed") and its size and its
/// onRemoved were wrong. To WebKit it is a window of its own, of the popup
/// kind, with one tab, so windows.get, update and remove and tabs.query
/// work on it. It shows only a website or the extension's own page, is
/// never kept, and goes when its extension is turned off or removed in the
/// space. (Search's 9bd5be5, 3674374)
@MainActor
public final class ExtensionPopupWindow: NSObject, WKWebExtensionWindow {
    /// Those open now, each held until its window closes.
    public private(set) static var open: [ExtensionPopupWindow] = []

    public let space: UUID
    public let extensionID: String
    public private(set) var id: UUID?
    fileprivate let owner: ExtensionTabs
    fileprivate var host: any ExtensionBrowserHost { owner.host }
    public private(set) lazy var tab = ExtensionPopupTab(window: self)
    private weak var controller: WKWebExtensionController?
    private var observations: [NSKeyValueObservation] = []

    public var page: (any WebMacPage)? { id.flatMap { host.popupPage($0)?.enginePage } }
    public var snapshot: ExtensionBrowserWindow? { id.map { host.popupWindow($0) } }
    fileprivate var pageSnapshot: ExtensionBrowserPage? { id.flatMap { host.popupPage($0) } }

    private init(space: UUID, extensionID: String, controller: WKWebExtensionController, owner: ExtensionTabs) {
        self.owner = owner
        self.space = space
        self.extensionID = extensionID
        self.controller = controller
    }

    /// The extension's own page, or a website; nil for anything else (a
    /// data: or blob: address, another extension's page), which the caller
    /// refuses.
    public static func open(_ url: URL, for context: WKWebExtensionContext, in space: UUID, controller: WKWebExtensionController,
                     frame asked: CGRect, focused: Bool, owner: ExtensionTabs, scheme: String) -> ExtensionPopupWindow? {
        let own = url.scheme?.lowercased() == scheme && url.host()?.lowercased() == context.uniqueIdentifier.lowercased()
        // about:blank: a popup asked for with no address, for a page later.
        guard own || ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank" else { return nil }
        let configuration: WebKitExtensionPageConfiguration?
        if own {
            guard let supplied = context.webViewConfiguration else { return nil }
            configuration = WebKitExtensionPageConfiguration(supplied)
        } else { configuration = nil }
        let made = ExtensionPopupWindow(space: space, extensionID: context.uniqueIdentifier, controller: controller, owner: owner)
        made.id = owner.host.openPopup(in: space, configuration: configuration, frame: asked) { [weak made] in made?.closed() }
        guard let page = made.page else { return nil }
        made.watch(page)
        if let id = made.id { owner.host.startPopup(id, url: url) }
        open.append(made)
        controller.didOpenWindow(made)
        controller.didOpenTab(made.tab)
        controller.didActivateTab(made.tab, previousActiveTab: nil)
        if focused {
            controller.didFocusWindow(made)
        } else {
            owner.host.refocusFrontWindow()
        }
        return made
    }

    /// The one showing `page`.
    public static func showing(_ page: any WebMacPage) -> ExtensionPopupWindow? {
        open.first { $0.page === page }
    }

    /// Its tab's properties changed, told to WebKit.
    public func tell(_ properties: WKWebExtension.TabChangedProperties) {
        controller?.didChangeTabProperties(properties, for: tab)
    }

    /// The tab's address, title and loading, told to WebKit as they change.
    private func watch(_ page: any WebMacPage) {
        let told: (WKWebExtension.TabChangedProperties) -> Void = { [weak self] properties in
            MainActor.assumeIsolated { self?.tell(properties) }
        }
        guard let view = (page as? WebKitMacPage)?.webView else { return }
        observations = [
            view.observe(\.url) { _, _ in told([.URL]) },
            view.observe(\.title) { _, _ in told([.title]) },
            view.observe(\.isLoading) { _, _ in told([.loading]) },
        ]
    }

    private func closed() {
        observations = []
        Self.open.removeAll { $0 === self }
        controller?.didCloseTab(tab, windowIsClosing: true)
        controller?.didCloseWindow(self)
        id = nil
    }

    /// An extension's, in a space: turned off, removed or reloaded there.
    public static func closeAll(of id: String, in space: UUID) {
        for window in open where window.extensionID == id && window.space == space { window.id.map { window.host.closePopup($0) } }
    }

    /// Every one in a space, whichever extension opened it: windows.getAll
    /// lists every window, as Chrome's does.
    public static func all(in space: UUID) -> [ExtensionPopupWindow] {
        open.filter { $0.space == space }
    }

    /// The one with the keys, in a space.
    public static func key(in space: UUID) -> ExtensionPopupWindow? {
        open.first { $0.space == space && $0.snapshot?.isKey == true }
    }

    // MARK: WKWebExtensionWindow

    public func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tab]
    }

    public func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab
    }

    public func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .popup
    }

    public func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        snapshot?.state == .minimized ? .minimized : .normal
    }

    public func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    public func frame(for context: WKWebExtensionContext) -> CGRect {
        snapshot?.frame ?? .null
    }

    public func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        snapshot?.screenFrame ?? NSScreen.main?.frame ?? .null
    }

    /// windows.update with a position or a size: what is left unset comes
    /// as NaN and stays as it is.
    public func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let id { host.setPopupFrame(frame, popup: id) }
        completionHandler(nil)
    }

    public func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let id { host.focusPopup(id) }
        completionHandler(nil)
    }

    public func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let id { host.closePopup(id) }
        completionHandler(nil)
    }

}

/// The one tab of an extension's popup window.
@MainActor
public final class ExtensionPopupTab: NSObject, WKWebExtensionTab {
    private weak var window: ExtensionPopupWindow?
    private let othersPage: (URL?, WKWebExtensionContext) -> Bool
    private let refusal: (URL?, WKWebExtensionContext) -> (any Error)?
    private let heldOwner: (URL?) -> String?

    init(window: ExtensionPopupWindow) {
        self.window = window
        othersPage = window.owner.othersPage
        refusal = window.owner.refusal
        heldOwner = window.owner.heldOwner
    }

    private var view: WKWebView? {
        (window?.page as? WebKitMacPage)?.webView
    }

    /// Another extension's page here gives an extension nothing of it, as
    /// a tab's (ExtensionTab.sealed): the one shown, or the one on its way.
    private func sealed(_ context: WKWebExtensionContext) -> Bool {
        othersPage(view?.url, context) || othersPage(window?.pageSnapshot?.displayURL, context)
    }

    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    public func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    public func webView(for context: WKWebExtensionContext) -> WKWebView? {
        sealed(context) ? nil : view
    }

    public func title(for context: WKWebExtensionContext) -> String? {
        sealed(context) ? nil : view?.title
    }

    public func url(for context: WKWebExtensionContext) -> URL? {
        sealed(context) ? nil : ExtensionTab.address(of: window?.pageSnapshot, for: context, owner: heldOwner, else: view?.url)
    }

    public func isSelected(for context: WKWebExtensionContext) -> Bool {
        true
    }

    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(view?.isLoading ?? false)
    }

    public func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        !sealed(context) && ExtensionPolicy.grantsOnClick(view?.url)
    }

    /// Only to a page of the same kind as the one shown: a website's view
    /// can't show an extension's page, nor the extension's a website.
    public func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let refused = refusal(url, context) { return completionHandler(refused) }
        guard let window, let id = window.id else { return completionHandler(nil) }
        completionHandler(window.host.loadPopup(id, url: url))
    }

    public func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window, let id = window.id { window.host.reloadPopup(id, fromOrigin: fromOrigin) }
        completionHandler(nil)
    }

    public func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window, let id = window.id { window.host.goBackInPopup(id) }
        completionHandler(nil)
    }

    public func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window, let id = window.id { window.host.goForwardInPopup(id) }
        completionHandler(nil)
    }

    public func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window, let id = window.id { window.host.focusPopup(id) }
        completionHandler(nil)
    }

    public func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window, let id = window.id { window.host.closePopup(id) }
        completionHandler(nil)
    }

}
#endif
