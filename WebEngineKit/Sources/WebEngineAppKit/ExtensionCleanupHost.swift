import Foundation

/// Product cleanup stays inline with the runtime's teardown. Tab closure
/// uses the live address first, then the recorded address, as before.
@MainActor public protocol ExtensionCleanupHost: ExtensionBrowserHost, ExtensionAuxiliaryPageHost {
    func extensionSpaceExists(_ space: UUID) -> Bool
    func extensionCleanupIsInstalled(_ id: String) -> Bool
    func extensionCleanupIDs(in space: UUID) -> [String]
    func removeExtensionCleanupMembership(in space: UUID)
    func clearExtensionCleanupVerdicts(in space: UUID)
    func closeExtensionCleanupPages(of id: String, in space: UUID)
    func closeExtensionCleanupPopups(in space: UUID)
    func closeExtensionCleanupSidePanels(in space: UUID)
    func scheduleExtensionCleanupStoreSweep()
    /// The app evaluates this only in its own DEBUG configuration.
    func noteExtensionCleanup(_ message: () -> String)
}
