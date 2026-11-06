import Foundation

/// The app keeps verdict wording and decides whether debug reporting is on.
@MainActor public protocol ExtensionDiagnosticHost: AnyObject {
    func extensionDiagnosticVerdictLines(_ id: String, in space: UUID, number: Int) -> [String]
}
