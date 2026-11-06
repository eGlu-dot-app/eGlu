import Foundation

/// The English dialect the grammar service checks against.
public enum WritingDialect: String, Sendable, Codable, CaseIterable {
    case american = "American"
    case british = "British"
    case canadian = "Canadian"
    case australian = "Australian"
    case indian = "Indian"
}

/// Only rules that differ from the engine's defaults need to be listed.
public struct WritingConfiguration: Sendable, Equatable {
    public var dialect: WritingDialect?
    public var rules: [String: Bool]
    public var words: [String]

    public init(dialect: WritingDialect? = nil, rules: [String: Bool] = [:], words: [String] = []) {
        self.dialect = dialect
        self.rules = rules
        self.words = words
    }
}

public struct WritingRule: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var label: String
    public var description: String
    public var group: String
    public var isOnByDefault: Bool

    public init(id: String, label: String, description: String, group: String, isOnByDefault: Bool) {
        self.id = id
        self.label = label
        self.description = description
        self.group = group
        self.isOnByDefault = isOnByDefault
    }
}

/// The synthesized Codable shape is also used by the Mac's lint preview.
public enum WritingSuggestion: Sendable, Equatable, Codable {
    case replace(String)
    case insert(String)
    case remove
}

/// Offsets are UTF-16 code units in the text given to lint.
/// `context` is the stable identifier passed back to ignore(context:).
public struct WritingIssue: Sendable, Equatable, Codable {
    public var start: Int
    public var end: Int
    public var rule: String
    public var kind: String
    public var message: String
    public var priority: Int
    public var suggestions: [WritingSuggestion]
    public var context: String

    public init(start: Int, end: Int, rule: String, kind: String, message: String,
                priority: Int, suggestions: [WritingSuggestion], context: String) {
        self.start = start
        self.end = end
        self.rule = rule
        self.kind = kind
        self.message = message
        self.priority = priority
        self.suggestions = suggestions
        self.context = context
    }
}

/// Identity lets a caller discard answers from a service it has dropped.
/// Forwarding keeps the caller's isolation until the engine actor is called.
public protocol GrammarService: AnyObject, Sendable {
    nonisolated(nonsending) func configure(_ configuration: WritingConfiguration) async throws
    nonisolated(nonsending) func warmUp() async throws
    nonisolated(nonsending) func lint(_ text: String) async throws -> [WritingIssue]
    nonisolated(nonsending) func ignore(context: String) async throws
}

public protocol GrammarEngine: Sendable {
    /// Synchronous and quick: dictionary building waits for warmUp or lint.
    func makeService(_ configuration: WritingConfiguration) throws -> any GrammarService
    func rules() throws -> [WritingRule]
    var canCheck: Bool { get }
}
