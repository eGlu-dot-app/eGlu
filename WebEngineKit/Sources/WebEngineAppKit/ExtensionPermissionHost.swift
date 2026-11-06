import Foundation

/// Captured synchronously before a delegate callback starts its task.
/// Only the app interprets this target and chooses its sheet's window.
@MainActor public protocol ExtensionPermissionTarget: AnyObject {}

/// This slice's host part. The final host also refines the browser and
/// auxiliary-page hosts. Cookie consent is saved by the app, inline.
@MainActor public protocol ExtensionPermissionHost: AnyObject {
    func extensionPermissionTarget(in space: UUID, tab: UUID?, kind: ExtensionPermissionPromptKind) -> (any ExtensionPermissionTarget)?
    func extensionPermissionTitle(name: String?, kind: ExtensionPermissionPromptKind) -> String
    func requestExtensionPermission(_ request: ExtensionPermissionRequest, target: any ExtensionPermissionTarget) async -> Bool
    func allowExtensionPermissionCookies(_ id: String)
}
