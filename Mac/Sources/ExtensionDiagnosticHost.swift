import Foundation
import WebEngineAppKit

extension ExtensionHost: ExtensionDiagnosticHost {
    func extensionDiagnosticVerdictLines(_ id: String, in space: UUID, number: Int) -> [String] {
        #if DEBUG
        if let verdict = Extensions.shared.verdicts[space]?[id] {
            return ["space \(number) verdict \(verdict.title)"] + verdict.lines.map { "space \(number) line \($0)" }
        }
        #endif
        return []
    }
}
