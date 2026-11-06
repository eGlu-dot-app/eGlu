import AppKit
import PadCore
import WebKit

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
final class ExtensionPopupWindow: NSObject, WKWebExtensionWindow {
    /// Those open now, each held until its window closes.
    private(set) static var open: [ExtensionPopupWindow] = []

    let space: UUID
    let extensionID: String
    private(set) var popup: Popup?
    private(set) lazy var tab = ExtensionPopupTab(window: self)
    private weak var controller: WKWebExtensionController?
    private var observations: [NSKeyValueObservation] = []

    var page: Page? {
        popup?.page
    }

    private init(space: UUID, extensionID: String, controller: WKWebExtensionController) {
        self.space = space
        self.extensionID = extensionID
        self.controller = controller
    }

    /// The extension's own page, or a website; nil for anything else (a
    /// data: or blob: address, another extension's page), which the caller
    /// refuses.
    static func open(_ url: URL, for context: WKWebExtensionContext, in space: UUID, controller: WKWebExtensionController,
                     frame asked: CGRect, focused: Bool) -> ExtensionPopupWindow? {
        let own = url.scheme?.lowercased() == Extensions.scheme && url.host()?.lowercased() == context.uniqueIdentifier.lowercased()
        // about:blank: a popup asked for with no address, for a page later.
        guard own || ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank" else { return nil }
        let page: Page
        if own {
            guard let configuration = context.webViewConfiguration else { return nil }
            page = Session.shared.engine.makePage(tab: UUID(), space: space, source: .supplied(configuration, extensionPage: true))
        } else {
            page = Session.shared.engine.makePage(tab: UUID(), space: space, source: .space)
        }
        let made = ExtensionPopupWindow(space: space, extensionID: context.uniqueIdentifier, controller: controller)
        let screen = (Session.shared.frontWindow?.window?.screen ?? NSScreen.main)?.visibleFrame
        made.popup = Popup.open(page: page, frame: screen.flatMap { frame(asked: asked, on: $0) }, minimum: NSSize(width: 200, height: 150)) { [weak made] in made?.closed() }
        made.watch(page)
        page.load(url)
        open.append(made)
        controller.didOpenWindow(made)
        controller.didOpenTab(made.tab)
        controller.didActivateTab(made.tab, previousActiveTab: nil)
        if focused {
            controller.didFocusWindow(made)
        } else {
            Session.shared.frontWindow?.window?.makeKeyAndOrderFront(nil)
        }
        return made
    }

    /// The frame asked for: as given, with its place; a size alone (a
    /// sign-in's), in the middle of the screen; nil when it isn't a size
    /// either, for the pop-up's own.
    nonisolated static func frame(asked: CGRect, on screen: CGRect) -> CGRect? {
        guard !asked.isNull, asked.width.isFinite, asked.height.isFinite, asked.width >= 200, asked.height >= 150 else { return nil }
        let width = min(asked.width, screen.width), height = min(asked.height, screen.height)
        if asked.origin.x.isFinite, asked.origin.y.isFinite {
            return CGRect(x: asked.origin.x, y: asked.origin.y, width: width, height: height)
        }
        return CGRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }

    /// The one showing `page`.
    static func showing(_ page: Page) -> ExtensionPopupWindow? {
        open.first { $0.page === page }
    }

    /// The one whose window is `window`.
    static func of(_ window: NSWindow?) -> ExtensionPopupWindow? {
        open.first { $0.popup?.window === window }
    }

    /// Its tab's properties changed, told to WebKit.
    func tell(_ properties: WKWebExtension.TabChangedProperties) {
        controller?.didChangeTabProperties(properties, for: tab)
    }

    /// The tab's address, title and loading, told to WebKit as they change.
    private func watch(_ page: Page) {
        let told: (WKWebExtension.TabChangedProperties) -> Void = { [weak self] properties in
            MainActor.assumeIsolated { self?.tell(properties) }
        }
        observations = [
            page.view.observe(\.url) { _, _ in told([.URL]) },
            page.view.observe(\.title) { _, _ in told([.title]) },
            page.view.observe(\.isLoading) { _, _ in told([.loading]) },
        ]
    }

    private func closed() {
        observations = []
        Self.open.removeAll { $0 === self }
        controller?.didCloseTab(tab, windowIsClosing: true)
        controller?.didCloseWindow(self)
        popup = nil
    }

    /// An extension's, in a space: turned off, removed or reloaded there.
    static func closeAll(of id: String, in space: UUID) {
        for window in open where window.extensionID == id && window.space == space { window.popup?.window.close() }
    }

    /// Every one in a space, whichever extension opened it: windows.getAll
    /// lists every window, as Chrome's does.
    static func all(in space: UUID) -> [ExtensionPopupWindow] {
        open.filter { $0.space == space }
    }

    /// The one with the keys, in a space.
    static func key(in space: UUID) -> ExtensionPopupWindow? {
        open.first { $0.space == space && $0.popup?.window.isKeyWindow == true }
    }

    // MARK: WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tab]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .popup
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        popup?.window.isMiniaturized == true ? .minimized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        popup?.window.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (popup?.window.screen ?? NSScreen.main)?.frame ?? .null
    }

    /// windows.update with a position or a size: what is left unset comes
    /// as NaN and stays as it is.
    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = popup?.window else { return completionHandler(nil) }
        let now = window.frame
        func or(_ value: CGFloat, _ current: CGFloat) -> CGFloat { value.isFinite ? value : current }
        let size = NSSize(width: max(window.minSize.width, or(frame.size.width, now.width)),
                          height: max(window.minSize.height, or(frame.size.height, now.height)))
        window.setFrame(NSRect(origin: NSPoint(x: or(frame.origin.x, now.origin.x), y: or(frame.origin.y, now.origin.y)), size: size),
                        display: true, animate: false)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        popup?.window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        popup?.window.close()
        completionHandler(nil)
    }
}

/// The one tab of an extension's popup window.
@MainActor
final class ExtensionPopupTab: NSObject, WKWebExtensionTab {
    private weak var window: ExtensionPopupWindow?

    init(window: ExtensionPopupWindow) {
        self.window = window
    }

    private var view: WKWebView? {
        window?.page?.view
    }

    /// Another extension's page here gives an extension nothing of it, as
    /// a tab's (ExtensionTab.sealed): the one shown, or the one on its way.
    private func sealed(_ context: WKWebExtensionContext) -> Bool {
        Extensions.othersPage(view?.url, for: context) || Extensions.othersPage(window?.page?.displayURL, for: context)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        sealed(context) ? nil : view
    }

    func title(for context: WKWebExtensionContext) -> String? {
        sealed(context) ? nil : view?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        sealed(context) ? nil : ExtensionTab.address(of: window?.page, for: context, else: view?.url)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(view?.isLoading ?? false)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        !sealed(context) && ExtensionPolicy.grantsOnClick(view?.url)
    }

    /// Only to a page of the same kind as the one shown: a website's view
    /// can't show an extension's page, nor the extension's a website.
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let refused = Extensions.refusal(opening: url, by: context) { return completionHandler(refused) }
        guard let page = window?.page else { return completionHandler(nil) }
        let toExtension = url.scheme?.lowercased() == Extensions.scheme
        guard toExtension == page.isExtensionPage, toExtension || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return completionHandler(Extensions.Unanswered(why: "Cannot navigate a popup window to that address."))
        }
        page.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { view?.reloadFromOrigin() } else { view?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        view?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        view?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.popup?.window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.popup?.window.close()
        completionHandler(nil)
    }
}
