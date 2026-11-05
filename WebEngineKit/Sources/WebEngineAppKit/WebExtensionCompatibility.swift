import Foundation

/// A catalog identity, without the app's installation choices.
public struct WebExtensionCompatibilityInstallation: Equatable, Sendable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

/// Plain evidence from a copy's pages, with no verdict or display words.
public struct WebExtensionCompatibilityResult: Equatable, Sendable {
    public enum Probe: Sendable { case notApplicable, checking, passed, failed, skipped, timedOut }
    public struct Problem: Equatable, Sendable {
        public enum Kind: Sendable { case missing, notAFunction, wrongArguments }
        public let kind: Kind
        public let api: String
        public let file: String?

        public init(kind: Kind, api: String, file: String?) {
            self.kind = kind
            self.api = api
            self.file = file
        }
    }
    public let testPage: Probe
    public let popup: Probe
    public let optionsPage: Probe
    public let problems: [Problem]

    public init(testPage: Probe, popup: Probe, optionsPage: Probe, problems: [Problem]) {
        self.testPage = testPage
        self.popup = popup
        self.optionsPage = optionsPage
        self.problems = problems
    }
}

/// Each event replaces exactly the fields its original update changed.
public enum WebExtensionCompatibilityEvidence: Equatable, Sendable {
    case notes([String])
    case checking(testPage: Bool, popup: Bool, optionsPage: Bool)
    case checked(WebExtensionCompatibilityResult)
}

/// The compatibility part of the runtime. The last hub slice composes it.
/// Evidence callbacks stay inline, once per original update, on the main actor.
@MainActor public protocol WebExtensionCompatibility: AnyObject {
    func readCode(of item: WebExtensionCompatibilityInstallation)
    func measureTable() async
    func checkCopy(of item: WebExtensionCompatibilityInstallation)
    func checkStamp(_ version: String) -> String
    func currentFailures(_ held: [String: String], installed: [String: String]) -> [String: String]
    func forgetCheck(_ id: String)
}
