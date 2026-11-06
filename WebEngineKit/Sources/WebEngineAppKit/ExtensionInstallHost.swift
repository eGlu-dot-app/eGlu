import Foundation

/// Facts are published inline after the package is written, before the
/// catalog changes. Roots are queried at the original file operations.
@MainActor public protocol ExtensionInstallHost: ExtensionStorageHost {
    func extensionInstallRefusal(_ refusal: WebExtensionInstallRefusal) -> any Error
    func noteExtensionInstallFacts(_ facts: WebExtensionManifestFacts?, of id: String)
}
