import AppKit

public enum ExtensionPermissionPromptKind: Sendable { case permissions, matchPatterns, afterClick }

/// Values for the app's existing access sheet or after-click alert.
/// The runtime keeps WebKit's permissions, patterns and context private.
public struct ExtensionPermissionRequest {
    public let extensionID: String
    public let space: UUID
    public let tab: UUID?
    public let name: String?
    /// Made by the app before a delegate starts its task, as before.
    public let title: String?
    public let image: NSImage?
    public let permissions: [String]
    public let sites: [String]
    public let kind: ExtensionPermissionPromptKind

    public init(extensionID: String, space: UUID, tab: UUID?, name: String?, image: NSImage?,
                permissions: [String], sites: [String], kind: ExtensionPermissionPromptKind, title: String? = nil) {
        self.extensionID = extensionID
        self.space = space
        self.tab = tab
        self.name = name
        self.title = title
        self.image = image
        self.permissions = permissions
        self.sites = sites
        self.kind = kind
    }
}

/// The permission part of the runtime, composed by the last hub slice.
/// The process-wide press dates are also read by capture's existing allowance.
@MainActor public protocol WebExtensionPermissions: AnyObject {
    var permissionPresses: [String: Date] { get set }
}
