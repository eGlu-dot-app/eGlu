import Foundation

/// Catalog queries and evidence delivery. The composed host also refines
/// the browser and auxiliary page hosts. No verdict is decided by the runtime.
@MainActor public protocol ExtensionCompatibilityHost: AnyObject {
    var extensionCompatibilityInstallations: [WebExtensionCompatibilityInstallation] { get }
    func extensionCompatibilityInstallation(_ id: String) -> WebExtensionCompatibilityInstallation?
    func extensionCompatibilityEvidence(_ evidence: WebExtensionCompatibilityEvidence, id: String, in space: UUID)
    func extensionCompatibilityProblem(_ problem: WebExtensionCompatibilityResult.Problem,
                                       of item: WebExtensionCompatibilityInstallation)
}
