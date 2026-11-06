import Engines
import Foundation
import HarperPlugin
import WritingServiceKit
import XCTest

@MainActor
final class HarperGrammarEngineTests: XCTestCase {
    private let engine = HarperGrammarEngine()

    /// Decode the old public Codable value independently of the plugin's mapping.
    private func issues(_ lints: [GrammarLint]) throws -> [WritingIssue] {
        try JSONDecoder().decode([WritingIssue].self, from: JSONEncoder().encode(lints))
    }

    func testConfiguredServiceMatchesGrammarFieldForField() async throws {
        let configuration = WritingConfiguration(dialect: .british, rules: ["SpellCheck": true], words: ["Safience"])
        let service = try engine.makeService(configuration)
        let grammar = try Grammar(settings: GrammarSettings(dialect: .british,
                                                             rules: configuration.rules, words: configuration.words))
        try await service.warmUp()
        try await grammar.warmUp()
        for text in ["I has a apple. Safience works.", "😀 teh", "# I has a apple.\n`teh`"] {
            let direct = try await grammar.lint(text)
            let read = try await service.lint(text)
            XCTAssertFalse(direct.isEmpty)
            XCTAssertEqual(read, try issues(direct))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            XCTAssertEqual(try encoder.encode(read), try encoder.encode(direct))
        }
    }

    func testConfigureAddsWordAndChangesRules() async throws {
        let service = try engine.makeService(WritingConfiguration())
        let before = try await service.lint("Safience works.")
        XCTAssertTrue(before.contains { $0.rule == "SpellCheck" })
        try await service.configure(WritingConfiguration(words: ["Safience"]))
        let after = try await service.lint("Safience works.")
        XCTAssertFalse(after.contains { $0.rule == "SpellCheck" })
        try await service.configure(WritingConfiguration(rules: ["SpellCheck": false]))
        let off = try await service.lint("I havv teh answer.")
        XCTAssertFalse(off.contains { $0.rule == "SpellCheck" })
    }

    func testIgnoreUsesTheOriginalContext() async throws {
        let service = try engine.makeService(WritingConfiguration())
        let before = try await service.lint("I has a apple.")
        let lint = try XCTUnwrap(before.first)
        try await service.ignore(context: lint.context)
        let after = try await service.lint("I has a apple.")
        XCTAssertFalse(after.contains { $0.context == lint.context })
    }

    func testRulesAvailabilityAndLicences() throws {
        let direct = try Grammar.rules()
        let expected = try JSONDecoder().decode([WritingRule].self, from: JSONEncoder().encode(direct))
        XCTAssertEqual(try engine.rules(), expected)
        XCTAssertTrue(engine.canCheck)
        XCTAssertEqual(HarperGrammarEngine.licences, EngineLicenses.text)
    }

    func testEveryDialectMatchesGrammar() async throws {
        XCTAssertEqual(WritingDialect.allCases.map(\.rawValue), Dialect.allCases.map(\.rawValue))
        for dialect in WritingDialect.allCases {
            let service = try engine.makeService(WritingConfiguration(dialect: dialect))
            let grammar = try Grammar(settings: GrammarSettings(dialect: Dialect(rawValue: dialect.rawValue)))
            let direct = try await grammar.lint("It cost one lakh rupees.")
            let read = try await service.lint("It cost one lakh rupees.")
            XCTAssertEqual(read, try issues(direct))
        }
    }

    func testGrammarErrorsPassThroughUnchanged() async throws {
        let service = try engine.makeService(WritingConfiguration())
        let grammar = try Grammar()
        let text = String(repeating: "a", count: 200_001)
        var direct: EngineError?
        do { _ = try await grammar.lint(text); XCTFail("Expected a size error") }
        catch { direct = try XCTUnwrap(error as? EngineError) }
        do { _ = try await service.lint(text); XCTFail("Expected a size error") }
        catch { XCTAssertEqual(error as? EngineError, direct) }
    }

    func testServicesHaveDistinctStableIdentity() throws {
        let first = try engine.makeService(WritingConfiguration())
        let retained = first
        let second = try engine.makeService(WritingConfiguration())
        XCTAssertTrue(first === retained)
        XCTAssertFalse(first === second)
    }
}
