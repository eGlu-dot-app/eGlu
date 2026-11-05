import Foundation
import PadCore
import WebEngineAppKit

extension ExtensionHost: ExtensionEvidenceHost {
    var extensionEvidenceAppVersion: String { Extensions.egluVersion }
    var extensionEvidenceOSVersion: String { Extensions.macOSVersion }

    func extensionErrorsChanged(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery {
        Extensions.shared.errorRecovery(id, in: space, failed: failed)
    }

    func extensionEvidenceChanged(_ seen: WebExtensionEvidence, _ id: String, in space: UUID) {
        Extensions.shared.evidenceChanged(seen.policyEvidence, id, in: space)
    }
}

// PadCore's product policy stays outside the contracts package.
extension WebExtensionEvidence.Problem {
    init(_ value: ExtensionError.Problem) {
        let kind: Kind
        switch value.kind {
        case .missing: kind = .missing
        case .notAFunction: kind = .notAFunction
        case .wrongArguments: kind = .wrongArguments
        }
        self.init(kind: kind, api: value.api)
    }

    var policyProblem: ExtensionError.Problem {
        let kind: ExtensionError.Kind
        switch self.kind {
        case .missing: kind = .missing
        case .notAFunction: kind = .notAFunction
        case .wrongArguments: kind = .wrongArguments
        }
        return .init(kind: kind, api: api)
    }
}

extension WebExtensionEvidence {
    init(_ value: ExtensionEvidence) {
        self.init()
        switch value.start {
        case .checking: start = .checking
        case .started: start = .started
        case .failed: start = .failed
        case .timedOut: start = .timedOut
        }
        switch value.testPage {
        case .notApplicable: testPage = .notApplicable
        case .checking: testPage = .checking
        case .passed: testPage = .passed
        case .failed: testPage = .failed
        case .skipped: testPage = .skipped
        case .timedOut: testPage = .timedOut
        }
        switch value.popup {
        case .notApplicable: popup = .notApplicable
        case .checking: popup = .checking
        case .passed: popup = .passed
        case .failed: popup = .failed
        case .skipped: popup = .skipped
        case .timedOut: popup = .timedOut
        }
        switch value.optionsPage {
        case .notApplicable: optionsPage = .notApplicable
        case .checking: optionsPage = .checking
        case .passed: optionsPage = .passed
        case .failed: optionsPage = .failed
        case .skipped: optionsPage = .skipped
        case .timedOut: optionsPage = .timedOut
        }
        problems = Set(value.problems.map(WebExtensionEvidence.Problem.init))
        unreachableApp = value.unreachableApp
        mayNotWork = value.mayNotWork
        cookiesKeptBack = value.cookiesKeptBack
        tried = value.tried.map { .init(release: $0.release, works: $0.works, what: $0.what) }
    }

    var policyEvidence: ExtensionEvidence {
        var value = ExtensionEvidence()
        switch start {
        case .checking: value.start = .checking
        case .started: value.start = .started
        case .failed: value.start = .failed
        case .timedOut: value.start = .timedOut
        }
        switch testPage {
        case .notApplicable: value.testPage = .notApplicable
        case .checking: value.testPage = .checking
        case .passed: value.testPage = .passed
        case .failed: value.testPage = .failed
        case .skipped: value.testPage = .skipped
        case .timedOut: value.testPage = .timedOut
        }
        switch popup {
        case .notApplicable: value.popup = .notApplicable
        case .checking: value.popup = .checking
        case .passed: value.popup = .passed
        case .failed: value.popup = .failed
        case .skipped: value.popup = .skipped
        case .timedOut: value.popup = .timedOut
        }
        switch optionsPage {
        case .notApplicable: value.optionsPage = .notApplicable
        case .checking: value.optionsPage = .checking
        case .passed: value.optionsPage = .passed
        case .failed: value.optionsPage = .failed
        case .skipped: value.optionsPage = .skipped
        case .timedOut: value.optionsPage = .timedOut
        }
        value.problems = Set(problems.map(\.policyProblem))
        value.unreachableApp = unreachableApp
        value.mayNotWork = mayNotWork
        value.cookiesKeptBack = cookiesKeptBack
        value.tried = tried.map { .init(release: $0.release, works: $0.works, what: $0.what) }
        return value
    }
}
