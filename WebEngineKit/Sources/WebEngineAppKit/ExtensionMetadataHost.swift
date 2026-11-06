import Foundation

/// The catalog identity needed to find an uncached icon's retained package.
public struct WebExtensionMetadataInstallation: Sendable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

/// The composed runtime host will also refine the browser and page hosts.
@MainActor public protocol ExtensionMetadataHost: AnyObject {
    func extensionMetadataInstallation(_ id: String) -> WebExtensionMetadataInstallation?
}
