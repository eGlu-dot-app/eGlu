import AppKit

/// Product decisions stay inline at the delegate's original read points.
@MainActor public protocol ExtensionDispatchHost: AnyObject {
    func clearExtensionLoadVerdict(_ id: String, in space: UUID)
    func extensionActionsChanged()
    func presentExtensionActionPopup(in space: UUID, tab: UUID?, address: () -> URL?,
                                     page: (URL, UUID) -> ExtensionPanePage?)
    func runExtensionAuth(_ url: URL, extension id: String, in space: UUID,
                          openTab: () -> UUID?) async throws -> URL
    func extensionFirstLookNativeFacts(_ facts: WebExtensionManifestFacts, of id: String)
    func extensionFirstLookEvidence(_ seen: WebExtensionEvidence, id: String) -> WebExtensionEvidence
    func noteExtensionError(_ api: String, words: () -> String?)
    func extensionKey(_ name: String) -> String?
    func suggestExtensionKey(_ key: String?, for name: String)
    func extensionHasEnabledItems(in space: UUID) -> Bool
}
