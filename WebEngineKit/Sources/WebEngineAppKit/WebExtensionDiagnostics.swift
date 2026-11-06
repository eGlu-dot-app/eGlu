import Foundation

/// Runtime lines are queried between the app's own report lines, inline.
/// The verdict and other-extension callbacks are read at their old positions.
@MainActor public protocol WebExtensionDiagnostics: AnyObject {
    func diagnosticTableLines() -> [String]
    func diagnosticLines(id: String, name: String, version: String, in space: UUID,
                         number: Int, otherExtension: () -> String) -> [String]
    func diagnosticPageLine(_ page: (any WebMacPage)?, number: Int) -> String
    static func words(_ text: String?, enabled: Bool) -> String
    static func note(_ line: String, outputPath: String?)
}
