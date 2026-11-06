import Foundation

/// The catalog facts used by generated scripts and management's self info.
/// Only an unsigned ZIP is described as a development installation today.
public struct WebExtensionScriptInstallation: Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let isUnsigned: Bool

    public init(id: String, name: String, version: String, isUnsigned: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.isUnsigned = isUnsigned
    }
}

/// The identity is read at each original catalog comparison.
/// Queried inline where the original answer read the catalog or its root.
/// The composed host also refines the browser and auxiliary page hosts.
@MainActor public protocol ExtensionScriptHost: AnyObject {
    var extensionScriptRoot: URL { get }
    func extensionScriptInstallation(_ id: () -> String) -> WebExtensionScriptInstallation?
}
