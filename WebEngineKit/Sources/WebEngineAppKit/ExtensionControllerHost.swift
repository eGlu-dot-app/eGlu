import Foundation

/// Catalog checks and app-owned pane teardown. Every answer and callback is
/// made at its original point in loading or unloading, without scheduling.
@MainActor public protocol ExtensionControllerHost: ExtensionBrowserHost, ExtensionAuxiliaryPageHost {
    func extensionInstallation(_ id: String) -> WebExtensionInstallation?
    func extensionSpaceExists(_ space: UUID) -> Bool
    func extensionIsIncompatible(_ id: String) -> Bool
    func extensionCleared(_ id: String, in space: UUID) async -> Bool
    func markExtensionLoadIncompatible(_ id: String, version: String)
    func releaseExtensionLoadPower(_ key: String)
    func closeExtensionLoadPopup(_ id: String, in space: UUID)
    func closeExtensionLoadSidePanel(_ id: String, in space: UUID)
    func clearExtensionLoadVerdict(_ id: String, in space: UUID)
    func noteExtensionLoadFailure(_ error: any Error)
    var extensionControllerMockCapture: Bool { get }
}
