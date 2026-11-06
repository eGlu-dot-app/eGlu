import AppKit
import Combine
import PadCore
import WebEngineAppKit

/// The app's workspace and windows, asked for by the extension runtime.
@MainActor
final class ExtensionHost: ExtensionBrowserHost {
    static let shared = ExtensionHost()
    private var watching: AnyCancellable?
    private var keyWatch: NSObjectProtocol?
    private var popups: [UUID: Popup] = [:]

    var workspace: ExtensionBrowserWorkspace { snapshot(Session.shared.workspace) }

    private func snapshot(_ workspace: Workspace) -> ExtensionBrowserWorkspace {
        ExtensionBrowserWorkspace(spaces: workspace.spaces.map {
            ExtensionBrowserSpace(id: $0.id, tabs: $0.tabs.map(snapshot), selected: $0.selected)
        })
    }

    private func snapshot(_ record: TabRecord) -> ExtensionBrowserTab {
        ExtensionBrowserTab(id: record.id, url: record.url, title: record.title, isPinned: record.isPinned)
    }

    func snapshot(_ page: Page) -> ExtensionBrowserPage {
        ExtensionBrowserPage(enginePage: page.enginePage, held: page.held, displayURL: page.displayURL)
    }

    func observe(workspace changed: @escaping @MainActor (ExtensionBrowserWorkspace) -> Void,
                 focus: @escaping @MainActor (ExtensionBrowserFocus) -> Void) {
        // @Published tells before the new workspace is in place, and the
        // tabs read the workspace: told on the turn after.
        watching = Session.shared.$workspace.receive(on: DispatchQueue.main).sink { [weak self] next in
            MainActor.assumeIsolated {
                guard let self else { return }
                changed(self.snapshot(next))
            }
        }
        keyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let window = note.object as? NSWindow
                let model = Session.shared.allWindows.first { $0.window === window }
                let popup = self.popups.first { $0.value.window === window }?.key
                focus(ExtensionBrowserFocus(space: model?.spaceID, popup: popup))
            }
        }
    }

    func record(_ tab: UUID) -> ExtensionBrowserTab? { Session.shared.workspace.tab(tab).map(snapshot) }
    func livePage(_ tab: UUID) -> ExtensionBrowserPage? { Session.shared.pages.live[tab].map(snapshot) }

    /// The eGlu window last used on the space, if one shows it.
    private func shower(_ space: UUID) -> WindowModel? {
        let windows = Session.shared.allWindows.filter { $0.spaceID == space }
        return windows.first { $0.window?.isKeyWindow == true } ?? windows.first
    }

    private func snapshot(_ window: NSWindow?, selected: UUID?, popup: Bool = false) -> ExtensionBrowserWindow {
        let state: ExtensionBrowserWindowState
        if !popup, window == nil { state = .minimized }
        else if !popup, window?.styleMask.contains(.fullScreen) == true { state = .fullscreen }
        else { state = window?.isMiniaturized == true ? .minimized : .normal }
        return ExtensionBrowserWindow(selected: selected, state: state, frame: window?.frame ?? .null,
                                      screenFrame: (window?.screen ?? NSScreen.main)?.frame ?? .null,
                                      isVisible: window?.isVisible == true, isKey: window?.isKeyWindow == true)
    }

    func window(in space: UUID) -> ExtensionBrowserWindow {
        let model = shower(space)
        return snapshot(model?.window, selected: model?.tabID)
    }

    func isFocused(in space: UUID) -> Bool {
        guard Session.shared.frontWindow?.spaceID == space,
              Session.shared.frontWindow?.window?.isKeyWindow == true else { return false }
        return true
    }

    func openTab(_ url: URL?, in space: UUID, active: Bool, pinned: Bool, extensionID: () -> String,
                 configuration: () -> (any ExtensionPageConfiguration)?) -> UUID? {
        let session = Session.shared
        let selected = session.workspace.space(space)?.selected
        guard let id = session.change({ $0.openTab(url, in: space) }), let record = session.workspace.tab(id) else { return nil }
        // Opening selects; a tab opened behind leaves the selection as it was.
        if !active, let selected { session.change { $0.select(selected) } }
        if pinned { session.change { _ = $0.pin(id) } }
        // Its own page, in its own configuration; another's is refused before here.
        if let url, url.host()?.lowercased() == extensionID().lowercased(), Extensions.shared.isExtensionPage(url),
           let configuration = configuration() {
            let page = session.pages.adoptExtension(tab: id, space: space, configuration: configuration)
            page.load(url)
        } else if url != nil {
            _ = session.pages.page(for: record, in: space)
        }
        if active {
            let window = session.allWindows.first { $0.spaceID == space && $0.window?.isKeyWindow == true }
                ?? session.allWindows.first { $0.spaceID == space }
            window?.select(id)
        }
        return id
    }

    func activateTab(_ tab: UUID, in space: UUID) {
        let session = Session.shared
        // A page on screen already, either of a split's two, is in view: the
        // keys stay where they are, so an extension can't move typing from
        // one page to the other. (Search) Its window comes forward, as
        // activating a tab does, with the keys where that window had them.
        if let showing = session.allWindows.first(where: { $0.shows(tab) }) {
            if showing.window?.isKeyWindow != true { showing.window?.makeKeyAndOrderFront(nil) }
            return
        }
        let window = session.allWindows.first { $0.spaceID == space } ?? session.frontWindow
        window?.select(tab)
        window?.window?.makeKeyAndOrderFront(nil)
    }

    func closeTab(_ tab: UUID) { Session.shared.closeTab(tab) }
    func loadTab(_ tab: UUID, in space: UUID, url: URL) {
        guard let record = Session.shared.workspace.tab(tab) else { return }
        Session.shared.pages.page(for: record, in: space).load(url)
    }
    func reloadTab(_ tab: UUID, fromOrigin: Bool) {
        if fromOrigin { Session.shared.pages.live[tab]?.enginePage.reloadFromOrigin() }
        else { Session.shared.pages.live[tab]?.enginePage.reload() }
    }
    func goBack(_ tab: UUID) {
        // Past a rule's page too, to the page it replaced, as Back does.
        if Session.shared.pages.live[tab]?.enginePage.state.canGoBack != true,
           Session.shared.wentBackPastReplacement(tab) { return }
        Session.shared.pages.live[tab]?.enginePage.goBack()
    }
    func goForward(_ tab: UUID) { Session.shared.pages.live[tab]?.enginePage.goForward() }

    func detectLocale(_ tab: UUID, in space: UUID, hasAccess: @escaping @MainActor (URL) -> Bool,
                      completionHandler: @escaping (Locale?, (any Error)?) -> Void) {
        guard let page = Session.shared.pages.live[tab], page.space == space,
              Session.shared.workspace.space(space)?.tabs.contains(where: { $0.id == tab }) == true,
              let url = page.state.url, !page.isHandsOff, hasAccess(url) else {
            completionHandler(nil, nil)
            return
        }
        Task { @MainActor in
            do {
                let result = try await ExtensionLanguage.webpage(isAllowed: {
                    Session.shared.pages.live[tab] === page && page.space == space &&
                        Session.shared.workspace.space(space)?.tabs.contains(where: { $0.id == tab }) == true &&
                        page.state.url == url && !page.isHandsOff && hasAccess(url)
                }, sample: { try await page.extensionLanguageText() })
                completionHandler(result?.locale, nil)
            } catch { completionHandler(nil, error) }
        }
    }

    func setWindowFrame(_ frame: CGRect, in space: UUID) { setFrame(frame, window: shower(space)?.window) }
    func focusWindow(in space: UUID) {
        if let window = shower(space)?.window { window.makeKeyAndOrderFront(nil) }
        else { Session.shared.openWindow?(space) }
    }
    func closeWindow(in space: UUID) -> (any Error)? {
        NSError(domain: "eGlu", code: 2, userInfo: [NSLocalizedDescriptionKey: "A space can't be closed by an extension."])
    }
    func ensureWindow(in space: UUID) {
        if Session.shared.allWindows.contains(where: { $0.spaceID == space }) == false { Session.shared.openWindow?(space) }
    }
    func privateWindowRefusal() -> any Error {
        Extensions.Unanswered(why: "Private windows can't be opened by extensions.")
    }

    func openPopup(in space: UUID, configuration: (any ExtensionPageConfiguration)?, frame asked: CGRect,
                   closed: @escaping @MainActor () -> Void) -> UUID {
        let page = Session.shared.engine.makeExtensionPopupPage(space: space, configuration: configuration)
        let id = UUID()
        let screen = (Session.shared.frontWindow?.window?.screen ?? NSScreen.main)?.visibleFrame
        popups[id] = Popup.open(page: page, frame: screen.flatMap { Self.popupFrame(asked: asked, on: $0) },
                                minimum: NSSize(width: 200, height: 150)) { [weak self] in
            closed()
            self?.popups[id] = nil
        }
        return id
    }
    func startPopup(_ popup: UUID, url: URL) { popups[popup]?.page.load(url) }
    func popupPage(_ popup: UUID) -> ExtensionBrowserPage? { popups[popup].map { snapshot($0.page) } }
    func popupWindow(_ popup: UUID) -> ExtensionBrowserWindow { snapshot(popups[popup]?.window, selected: nil, popup: true) }
    func loadPopup(_ popup: UUID, url: URL) -> (any Error)? {
        guard let page = popups[popup]?.page else { return nil }
        let toExtension = url.scheme?.lowercased() == Extensions.scheme
        guard toExtension == page.isExtensionPage, toExtension || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return Extensions.Unanswered(why: "Cannot navigate a popup window to that address.")
        }
        page.load(url)
        return nil
    }
    func reloadPopup(_ popup: UUID, fromOrigin: Bool) {
        if fromOrigin { popups[popup]?.page.enginePage.reloadFromOrigin() } else { popups[popup]?.page.enginePage.reload() }
    }
    func goBackInPopup(_ popup: UUID) { popups[popup]?.page.enginePage.goBack() }
    func goForwardInPopup(_ popup: UUID) { popups[popup]?.page.enginePage.goForward() }
    func setPopupFrame(_ frame: CGRect, popup: UUID) { setFrame(frame, window: popups[popup]?.window) }
    func focusPopup(_ popup: UUID) { popups[popup]?.window.makeKeyAndOrderFront(nil) }
    func closePopup(_ popup: UUID) { popups[popup]?.window.close() }
    func refocusFrontWindow() { Session.shared.frontWindow?.window?.makeKeyAndOrderFront(nil) }

    /// The frame asked for: as given, with its place; a size alone (a
    /// sign-in's), in the middle of the screen; nil when it isn't a size
    /// either, for the pop-up's own.
    nonisolated static func popupFrame(asked: CGRect, on screen: CGRect) -> CGRect? {
        guard !asked.isNull, asked.width.isFinite, asked.height.isFinite, asked.width >= 200, asked.height >= 150 else { return nil }
        let width = min(asked.width, screen.width), height = min(asked.height, screen.height)
        if asked.origin.x.isFinite, asked.origin.y.isFinite {
            return CGRect(x: asked.origin.x, y: asked.origin.y, width: width, height: height)
        }
        return CGRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }

    private func setFrame(_ frame: CGRect, window: NSWindow?) {
        guard let window else { return }
        let now = window.frame
        func or(_ value: CGFloat, _ current: CGFloat) -> CGFloat { value.isFinite ? value : current }
        let size = NSSize(width: max(window.minSize.width, or(frame.size.width, now.width)),
                          height: max(window.minSize.height, or(frame.size.height, now.height)))
        window.setFrame(NSRect(origin: NSPoint(x: or(frame.origin.x, now.origin.x), y: or(frame.origin.y, now.origin.y)), size: size),
                        display: true, animate: false)
    }
}
