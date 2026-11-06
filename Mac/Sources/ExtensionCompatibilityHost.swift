import Foundation
import PadCore
import WebEngineAppKit

extension ExtensionHost: ExtensionCompatibilityHost {
    var extensionCompatibilityInstallations: [WebExtensionCompatibilityInstallation] {
        Extensions.shared.installed.map { .init(id: $0.id, version: $0.version) }
    }

    func extensionCompatibilityInstallation(_ id: String) -> WebExtensionCompatibilityInstallation? {
        Extensions.shared.installed.first { $0.id == id }.map { .init(id: $0.id, version: $0.version) }
    }

    func extensionCompatibilityEvidence(_ evidence: WebExtensionCompatibilityEvidence, id: String, in space: UUID) {
        Extensions.shared.update(id, in: space) { seen in
            switch evidence {
            case .notes(let notes): seen.mayNotWork = notes
            case .checking(let testPage, let popup, let optionsPage):
                if popup { seen.popup = .checking }
                if optionsPage { seen.optionsPage = .checking }
                if testPage { seen.testPage = .checking }
            case .checked(let result):
                seen.testPage = Self.probe(result.testPage)
                seen.popup = Self.probe(result.popup)
                seen.optionsPage = Self.probe(result.optionsPage)
                seen.problems.formUnion(result.problems.map(Self.problem))
            }
        }
    }

    func extensionCompatibilityProblem(_ problem: WebExtensionCompatibilityResult.Problem,
                                       of item: WebExtensionCompatibilityInstallation) {
        // The runtime has just checked this catalog version, in the same turn.
        guard let installed = Extensions.shared.installed.first(where: { $0.id == item.id && $0.version == item.version }) else { return }
        Extensions.shared.note(Self.problem(problem), file: problem.file, of: installed)
    }

    private static func problem(_ problem: WebExtensionCompatibilityResult.Problem) -> ExtensionError.Problem {
        let kind: ExtensionError.Kind
        switch problem.kind {
        case .missing: kind = .missing
        case .notAFunction: kind = .notAFunction
        case .wrongArguments: kind = .wrongArguments
        }
        return ExtensionError.Problem(kind: kind, api: problem.api)
    }

    private static func probe(_ probe: WebExtensionCompatibilityResult.Probe) -> ExtensionEvidence.Probe {
        switch probe {
        case .notApplicable: return .notApplicable
        case .checking: return .checking
        case .passed: return .passed
        case .failed: return .failed
        case .skipped: return .skipped
        case .timedOut: return .timedOut
        }
    }
}
