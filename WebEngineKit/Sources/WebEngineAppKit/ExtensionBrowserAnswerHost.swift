import AppKit

/// A live page's values, without retaining the app's Page or its view.
public struct ExtensionAnswerPage: Sendable {
    public let url: URL?
    public let title: String?
    public let held: URL?

    public init(url: URL?, title: String?, held: URL?) {
        self.url = url; self.title = title; self.held = held
    }
}

public struct ExtensionAnswerVisibility: Sendable {
    public let focused: Bool
    public init(focused: Bool) { self.focused = focused }
}

public enum ExtensionAnswerSurfaceKind: String, Sendable {
    case popup = "POPUP", sidePanel = "SIDE_PANEL"
}

/// Identity uses the presenting window's original hash, including nil's zero.
public struct ExtensionAnswerSurface: Sendable {
    public let extensionID: String
    public let space: UUID
    public let url: URL?
    public let window: Int
    public let focused: Bool
    public let kind: ExtensionAnswerSurfaceKind

    public init(extensionID: String, space: UUID, url: URL?, window: Int, focused: Bool, kind: ExtensionAnswerSurfaceKind) {
        self.extensionID = extensionID; self.space = space; self.url = url
        self.window = window; self.focused = focused; self.kind = kind
    }
}

public enum ExtensionAnswerPanelPresentation: Sendable { case open, close }

/// Product snapshots and panel operations, called inline at the original
/// reads and mutations. The app keeps pending panels and window selection.
@MainActor public protocol ExtensionBrowserAnswerHost: AnyObject {
    func extensionAnswerTabs(in space: UUID) -> [ExtensionBrowserTab]
    func extensionAnswerPage(_ tab: UUID) -> ExtensionAnswerPage?
    func extensionAnswerVisibleWindow(showing tab: UUID) -> ExtensionAnswerVisibility?
    func extensionAnswerSurfaces(_ kind: ExtensionAnswerSurfaceKind) -> [ExtensionAnswerSurface]
    func extensionAnswerIcon(for url: URL?) -> NSImage?
    func setExtensionPanelOptions(_ id: String, in space: UUID, tab: UUID?, path: String?, enabled: Bool?)
    func extensionPanelOptions(_ id: String, in space: UUID, tab: UUID?) -> [String: Any]
    func setExtensionPanelOpensOnAction(_ id: String, in space: UUID, _ on: Bool)
    func extensionPanelOpensOnAction(_ id: String, in space: UUID) -> Bool
    func presentExtensionPanel(_ presentation: ExtensionAnswerPanelPresentation, _ id: String, tab: UUID?, in space: UUID) throws
}
