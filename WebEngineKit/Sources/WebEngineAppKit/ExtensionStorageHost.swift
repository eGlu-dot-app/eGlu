import Foundation

/// The app supplies roots without giving the runtime its catalog or Session.
/// Queried inline for each path, as the app's original computed root was.
@MainActor public protocol ExtensionStorageHost: ExtensionBrowserHost, ExtensionAuxiliaryPageHost {
    var extensionStorageEnvironment: WebExtensionStorageEnvironment { get }
}
