import AppKit

/// Value operations used by the app after controller and shim dispatch move.
@MainActor public protocol WebExtensionDispatch: AnyObject {
    func keepsCookiesBack(_ id: String, allowing on: Bool) -> Bool
    func startTabs()
    func isLoaded(_ id: String) -> Bool
    func asks(_ id: String, in space: UUID, for permission: String) -> Bool
    func openTab(_ url: URL, extension id: String, in space: UUID) -> UUID?
    func openOptions(_ id: String, in space: UUID)
    func permissionIcon(_ id: String, in space: UUID) -> NSImage?
    func commands(of id: String) -> [WebExtensionCommand]?
    func commands(of id: String, in space: UUID) -> [WebExtensionCommand]?
    func perform(_ command: WebExtensionCommand.Identity, of id: String, in space: UUID)
    func applyKeys(of id: String)
    func action(for id: String, tab: UUID?, in space: UUID, iconSize: CGSize?) -> WebExtensionAction?
    func run(_ id: String, tab: () -> UUID?, in space: UUID, popup: () -> Bool,
             panel: () -> Bool, pageURL: () -> URL?, togglePanel: () -> Void)
    func sidePanelSource(_ id: String, in space: UUID) -> ExtensionPaneSource?
    func webAccessible(_ url: URL, from source: URL, in space: UUID, fromRule: Bool) -> Bool
    func externalListings(in space: UUID) -> [String: [String]]
    func forgetCapture(_ id: String)
    func releaseCapture(_ view: NSView)
    func displayCaptureDecision(for view: NSView) -> Int
    func watchCapture(_ view: NSView, id: String)
    func forgetRecords(_ id: String)
    func errorRecovery(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery
}
