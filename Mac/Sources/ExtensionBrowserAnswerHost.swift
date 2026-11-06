import AppKit
import WebEngineAppKit

extension ExtensionHost: ExtensionBrowserAnswerHost {
    func extensionAnswerTabs(in space: UUID) -> [ExtensionBrowserTab] {
        (Session.shared.workspace.space(space)?.tabs ?? []).map {
            ExtensionBrowserTab(id: $0.id, url: $0.url, title: $0.title, isPinned: $0.isPinned)
        }
    }

    func extensionAnswerPage(_ tab: UUID) -> ExtensionAnswerPage? {
        guard let page = Session.shared.pages.live[tab] else { return nil }
        let state = page.state
        return ExtensionAnswerPage(url: state.url, title: state.title, held: page.held)
    }

    func extensionAnswerVisibleWindow(showing tab: UUID) -> ExtensionAnswerVisibility? {
        let window = Session.shared.allWindows.first { $0.tabID == tab && $0.window?.occlusionState.contains(.visible) == true }
        return window.map { ExtensionAnswerVisibility(focused: $0.window?.isKeyWindow == true) }
    }

    func extensionAnswerSurfaces(_ kind: ExtensionAnswerSurfaceKind) -> [ExtensionAnswerSurface] {
        let surfaces: [(any WebExtensionSurface, WindowModel?)]
        switch kind {
        case .popup: surfaces = ExtensionPopups.shared.shown.values.map { ($0.surface, $0.window) }
        case .sidePanel: surfaces = ExtensionSidePanels.shared.shown.values.map { ($0.surface, $0.window) }
        }
        return surfaces.map { surface, window in
            ExtensionAnswerSurface(extensionID: surface.extensionID, space: surface.space, url: surface.url,
                window: window.map { ObjectIdentifier($0).hashValue } ?? 0,
                focused: window?.window?.isKeyWindow == true, kind: kind)
        }
    }

    func extensionAnswerIcon(for url: URL?) -> NSImage? { SiteIcons.shared.image(for: url) }

    func setExtensionPanelOptions(_ id: String, in space: UUID, tab: UUID?, path: String?, enabled: Bool?) {
        ExtensionSidePanels.shared.setOptions(id, in: space, tab: tab, path: path, enabled: enabled)
    }
    func extensionPanelOptions(_ id: String, in space: UUID, tab: UUID?) -> [String: Any] {
        ExtensionSidePanels.shared.options(id, in: space, tab: tab)
    }
    func setExtensionPanelOpensOnAction(_ id: String, in space: UUID, _ on: Bool) {
        ExtensionSidePanels.shared.setOpensOnAction(id, in: space, on)
    }
    func extensionPanelOpensOnAction(_ id: String, in space: UUID) -> Bool {
        ExtensionSidePanels.shared.opensOnAction(id, in: space)
    }

    func presentExtensionPanel(_ presentation: ExtensionAnswerPanelPresentation, _ id: String, tab: UUID?, in space: UUID) throws {
        let panels = ExtensionSidePanels.shared
        let windows = Session.shared.allWindows.filter { $0.spaceID == space }
        // A tab not on screen: its panel opens when it is.
        if let tab, !windows.contains(where: { $0.tabID == tab }) {
            if presentation == .open { panels.open(id, whenShowing: tab, in: space) } else { panels.cancel(id, tab: tab, in: space) }
            return
        }
        guard let window = windows.first(where: { tab != nil && $0.tabID == tab }) ?? windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first
        else { throw Extensions.Unanswered(why: "No window to open the side panel in.") }
        if presentation == .open { ExtensionSidePanels.shared.open(id, in: window) } else if ExtensionSidePanels.shared.panel(in: window)?.surface.extensionID == id {
            ExtensionSidePanels.shared.close(in: window)
        }
    }
}
