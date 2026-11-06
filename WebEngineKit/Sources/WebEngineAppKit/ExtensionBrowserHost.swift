import AppKit

/// The runtime's configuration, returned to the app's engine unchanged.
/// Only that engine interprets it; the browser host never opens it.
@MainActor public protocol ExtensionPageConfiguration: AnyObject {}

public struct ExtensionBrowserTab: Equatable, Sendable {
    public let id: UUID
    public let url: URL?
    public let title: String
    public let isPinned: Bool

    public init(id: UUID, url: URL?, title: String, isPinned: Bool) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
    }
}

public struct ExtensionBrowserSpace: Equatable, Sendable {
    public let id: UUID
    public let tabs: [ExtensionBrowserTab]
    public let selected: UUID?

    public init(id: UUID, tabs: [ExtensionBrowserTab], selected: UUID?) {
        self.id = id
        self.tabs = tabs
        self.selected = selected
    }
}

public struct ExtensionBrowserWorkspace: Equatable, Sendable {
    public let spaces: [ExtensionBrowserSpace]
    public init(spaces: [ExtensionBrowserSpace]) { self.spaces = spaces }
    public func space(_ id: UUID) -> ExtensionBrowserSpace? { spaces.first { $0.id == id } }
    public func spaceID(of tab: UUID) -> UUID? { spaces.first { $0.tabs.contains { $0.id == tab } }?.id }
}

/// A live engine page with the app's address and access policy alongside it.
/// A frozen tab has a record but no such page. This never owns an app Page.
@MainActor public struct ExtensionBrowserPage {
    public let enginePage: any WebMacPage
    public let held: URL?
    public let displayURL: URL?

    public init(enginePage: any WebMacPage, held: URL?, displayURL: URL?) {
        self.enginePage = enginePage
        self.held = held
        self.displayURL = displayURL
    }
}

public enum ExtensionBrowserWindowState: Sendable { case normal, minimized, fullscreen }

public struct ExtensionBrowserWindow: Sendable {
    public let selected: UUID?
    public let state: ExtensionBrowserWindowState
    public let frame: CGRect
    public let screenFrame: CGRect
    public let isVisible: Bool
    public let isKey: Bool

    public init(selected: UUID?, state: ExtensionBrowserWindowState, frame: CGRect, screenFrame: CGRect,
                isVisible: Bool, isKey: Bool) {
        self.selected = selected
        self.state = state
        self.frame = frame
        self.screenFrame = screenFrame
        self.isVisible = isVisible
        self.isKey = isKey
    }
}

public struct ExtensionBrowserFocus: Sendable {
    public let space: UUID?
    public let popup: UUID?
    public init(space: UUID?, popup: UUID?) { self.space = space; self.popup = popup }
}

/// The app owns the workspace, product Back, window creation and refusals.
/// The runtime owns adapter identity and WebKit notifications. Workspace
/// callbacks arrive on the subscription's next main-queue turn, with no
/// further scheduling in the runtime. Page and focus callbacks stay inline.
@MainActor public protocol ExtensionBrowserHost: AnyObject {
    var workspace: ExtensionBrowserWorkspace { get }
    func observe(workspace: @escaping @MainActor (ExtensionBrowserWorkspace) -> Void,
                 focus: @escaping @MainActor (ExtensionBrowserFocus) -> Void)
    func record(_ tab: UUID) -> ExtensionBrowserTab?
    func livePage(_ tab: UUID) -> ExtensionBrowserPage?
    func window(in space: UUID) -> ExtensionBrowserWindow
    func isFocused(in space: UUID) -> Bool
    func openTab(_ url: URL?, in space: UUID, active: Bool, pinned: Bool, extensionID: () -> String,
                 configuration: () -> (any ExtensionPageConfiguration)?) -> UUID?
    func activateTab(_ tab: UUID, in space: UUID)
    func closeTab(_ tab: UUID)
    func loadTab(_ tab: UUID, in space: UUID, url: URL)
    func reloadTab(_ tab: UUID, fromOrigin: Bool)
    func goBack(_ tab: UUID)
    func goForward(_ tab: UUID)
    func detectLocale(_ tab: UUID, in space: UUID, hasAccess: @escaping @MainActor (URL) -> Bool,
                      completionHandler: @escaping (Locale?, (any Error)?) -> Void)
    func setWindowFrame(_ frame: CGRect, in space: UUID)
    func focusWindow(in space: UUID)
    func closeWindow(in space: UUID) -> (any Error)?
    func ensureWindow(in space: UUID)
    func privateWindowRefusal() -> any Error
    func openPopup(in space: UUID, configuration: (any ExtensionPageConfiguration)?, frame: CGRect,
                   closed: @escaping @MainActor () -> Void) -> UUID
    func startPopup(_ popup: UUID, url: URL)
    func popupPage(_ popup: UUID) -> ExtensionBrowserPage?
    func popupWindow(_ popup: UUID) -> ExtensionBrowserWindow
    func loadPopup(_ popup: UUID, url: URL) -> (any Error)?
    func reloadPopup(_ popup: UUID, fromOrigin: Bool)
    func goBackInPopup(_ popup: UUID)
    func goForwardInPopup(_ popup: UUID)
    func setPopupFrame(_ frame: CGRect, popup: UUID)
    func focusPopup(_ popup: UUID)
    func closePopup(_ popup: UUID)
    func refocusFrontWindow()
}
