/// Transient UI state. A rejected exit keeps its original intent (especially
/// Skip Setup); only an acknowledged write may dismiss the welcome.
public enum SetupSaveState: Equatable, Sendable {
    case idle
    case saving(SetupProgress.Completion)
    case failed(SetupProgress.Completion)
    case saved(SetupProgress.Completion)

    public init() { self = .idle }

    public var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    public var retryReason: SetupProgress.Completion? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    @discardableResult
    public mutating func begin(_ reason: SetupProgress.Completion) -> Bool {
        switch self {
        case .idle: self = .saving(reason)
        case .failed(let original): self = .saving(original)
        case .saving, .saved: return false
        }
        return true
    }

    public mutating func acknowledge(_ saved: Bool) {
        guard case .saving(let reason) = self else { return }
        self = saved ? .saved(reason) : .failed(reason)
    }
}

/// Exactly one footer action owns bookmark recovery in first run. The result
/// card keeps its receipt and destination picker, not another submit button.
public enum SetupBookmarkAction: Equatable, Sendable {
    case wait, chooseFile, chooseDestination, importSelected, retrySave, continueSetup

    public static func resolve(outcome: BookmarkImportOutcome?, working: Bool, hasDestination: Bool) -> Self {
        if working { return .wait }
        if outcome?.isComplete == true { return .continueSetup }
        if outcome?.parsed != nil { return hasDestination ? .importSelected : .chooseDestination }
        if outcome?.needsSave == true { return .retrySave }
        return .chooseFile
    }
}
