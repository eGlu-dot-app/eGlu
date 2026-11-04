import Engines
import WritingServiceKit

public struct HarperGrammarEngine: GrammarEngine {
    public init() {}

    public func makeService(_ configuration: WritingConfiguration) throws -> any GrammarService {
        try HarperGrammarService(configuration)
    }

    public func rules() throws -> [WritingRule] {
        try Grammar.rules().map {
            WritingRule(id: $0.id, label: $0.label, description: $0.description,
                        group: $0.group, isOnByDefault: $0.isOnByDefault)
        }
    }

    public var canCheck: Bool { (try? Grammar()) != nil }

    /// Both plugins link the same Engines target, whose text covers both.
    public static var licences: String { EngineLicenses.text }
}

/// Owns exactly one Grammar actor, which keeps its own executor and thread.
private final class HarperGrammarService: GrammarService {
    private let grammar: Grammar

    init(_ configuration: WritingConfiguration) throws {
        grammar = try Grammar(settings: configuration.settings)
    }

    nonisolated(nonsending) func configure(_ configuration: WritingConfiguration) async throws {
        try await grammar.configure(settings: configuration.settings)
    }

    nonisolated(nonsending) func warmUp() async throws {
        try await grammar.warmUp()
    }

    nonisolated(nonsending) func lint(_ text: String) async throws -> [WritingIssue] {
        try await grammar.lint(text).map { lint in
            WritingIssue(start: lint.start, end: lint.end, rule: lint.rule, kind: lint.kind,
                         message: lint.message, priority: lint.priority,
                         suggestions: lint.suggestions.map { suggestion in
                             switch suggestion {
                             case .replace(let text): return .replace(text)
                             case .insert(let text): return .insert(text)
                             case .remove: return .remove
                             }
                         }, context: lint.context)
        }
    }

    nonisolated(nonsending) func ignore(context: String) async throws {
        try await grammar.ignore(context: context)
    }
}

private extension WritingConfiguration {
    var settings: GrammarSettings {
        GrammarSettings(dialect: dialect.map { Dialect(rawValue: $0.rawValue)! }, rules: rules, words: words)
    }
}
