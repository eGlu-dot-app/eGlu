import Foundation

/// The current catalog entry and the worker slice's inline recovery result.
public struct WebExtensionErrorRecovery: Sendable {
    public let installation: WebExtensionEvidenceInstallation?
    public let restarting: Bool
    public init(installation: WebExtensionEvidenceInstallation?, restarting: Bool) {
        self.installation = installation; self.restarting = restarting
    }
}

/// The evidence slice's host answers. Composition also refines the browser
/// and auxiliary page hosts. No event is scheduled onto another turn.
@MainActor public protocol ExtensionEvidenceHost: AnyObject {
    var extensionEvidenceAppVersion: String { get }
    var extensionEvidenceOSVersion: String { get }
    func extensionErrorsChanged(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery
    func extensionEvidenceChanged(_ seen: WebExtensionEvidence, _ id: String, in space: UUID)
}
