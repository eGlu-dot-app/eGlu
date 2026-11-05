import AppKit

/// Facts from the original manifest, before a prepared copy adds permissions.
public struct WebExtensionManifestFacts: Equatable, Sendable {
    public let offersCookies: Bool
    public let nativeRequired: Bool
    public let nativeOptional: Bool

    public init(offersCookies: Bool, nativeRequired: Bool, nativeOptional: Bool) {
        self.offersCookies = offersCookies
        self.nativeRequired = nativeRequired
        self.nativeOptional = nativeOptional
    }
}

/// A retained package's name and facts. A missing package keeps its saved name.
public struct WebExtensionPackageName: Equatable, Sendable {
    public let name: String
    public let facts: WebExtensionManifestFacts?

    public init(name: String, facts: WebExtensionManifestFacts?) {
        self.name = name
        self.facts = facts
    }
}

/// The metadata part of the runtime. The last hub slice composes its parts.
/// Queries stay inline, including lazy context lookups and the shared icon
/// cache. Only the retained package name is read by the caller's detached task.
@MainActor public protocol WebExtensionMetadata: AnyObject, Sendable {
    func icon(of id: String) -> NSImage?
    func icon(of id: String, in space: UUID) -> NSImage?
    func forgetIcon(_ id: String)
    func manifestFacts(permissions: [String], optionalPermissions: [String]) -> WebExtensionManifestFacts
    func optionsPageURL(_ id: String, in space: UUID) -> URL?
    func newTabPageURL(_ id: String, in space: UUID) -> URL?
    func hasNewTabPage(_ id: String) -> Bool
    func isNewTabPage(_ url: URL, in space: UUID) -> Bool
    func sidePanelDefaultPath(_ id: String, in space: UUID) -> String?
    nonisolated func packageName(at file: URL, fallback: String) -> WebExtensionPackageName
}
