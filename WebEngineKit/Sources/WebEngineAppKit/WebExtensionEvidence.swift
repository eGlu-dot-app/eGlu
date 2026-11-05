import Foundation

/// Sanitized runtime evidence. Evidence events carry no page text or
/// error messages. The app derives its warnings and unread state inline.
public struct WebExtensionEvidence: Equatable, Sendable {
    public enum Start: Sendable { case checking, started, failed, timedOut }
    public enum Probe: Sendable { case notApplicable, checking, passed, failed, skipped, timedOut }
    public struct Problem: Hashable, Sendable {
        public enum Kind: Sendable { case missing, notAFunction, wrongArguments }
        public var kind: Kind
        public var api: String
        public init(kind: Kind, api: String) { self.kind = kind; self.api = api }
    }
    public struct Tried: Equatable, Sendable {
        public var release: String
        public var works: Bool
        public var what: String
        public init(release: String, works: Bool, what: String) {
            self.release = release; self.works = works; self.what = what
        }
    }
    public var start: Start = .checking
    public var testPage: Probe = .notApplicable
    public var popup: Probe = .notApplicable
    public var optionsPage: Probe = .notApplicable
    public var problems: Set<Problem> = []
    public var unreachableApp: String?
    public var mayNotWork: [String] = []
    public var cookiesKeptBack = false
    public var tried: Tried?
    public init() {}
}

public struct WebExtensionEvidenceInstallation: Sendable {
    public let id: String
    public let version: String
    public init(id: String, version: String) { self.id = id; self.version = version }
}

/// A report's record values, without a dependency on the app's policy module.
public struct WebExtensionErrorRecord: Equatable, Sendable {
    public let id: String
    public let version: String
    public let eglu: String
    public let macOS: String
    public let shim: String
    public let place: String
    public let api: String
    public let kind: String
    public let count: Int
    public let first: Date
    public let last: Date
    public init(id: String, version: String, eglu: String, macOS: String, shim: String, place: String,
                api: String, kind: String, count: Int, first: Date, last: Date) {
        self.id = id; self.version = version; self.eglu = eglu; self.macOS = macOS; self.shim = shim
        self.place = place; self.api = api; self.kind = kind; self.count = count; self.first = first; self.last = last
    }
}

/// The evidence part of the runtime. The last hub slice composes its parts.
/// Change closures and the host's evidence callback finish before returning.
@MainActor public protocol WebExtensionEvidenceRuntime: AnyObject {
    var evidence: [UUID: [String: WebExtensionEvidence]] { get set }
    var lacking: [String: Set<String>] { get set }
    var recorded: [String: Set<String>] { get set }
    func recordOnce(_ key: String, _ text: String) -> Bool
    func readRecords()
    func pruneRecords()
    func saveRecords()
    func note(_ problem: WebExtensionEvidence.Problem, file: String?, of item: WebExtensionEvidenceInstallation)
    func records(of id: String) -> [WebExtensionErrorRecord]
    func update(_ id: String, in space: UUID, _ change: (inout WebExtensionEvidence) -> Void)
    func record(_ seen: WebExtensionEvidence, _ id: String, in space: UUID)
}
