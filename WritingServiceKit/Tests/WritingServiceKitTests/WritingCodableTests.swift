import Foundation
import WritingServiceKit
import XCTest

final class WritingCodableTests: XCTestCase {
    private func roundTrip<T: Codable>(_ type: T.Type, _ json: String) throws -> T {
        let bytes = Data(json.utf8)
        let value = try JSONDecoder().decode(type, from: bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(value), bytes)
        return value
    }

    func testIssueHasTheOriginalSynthesizedShape() throws {
        let json = #"{"context":"stable","end":6,"kind":"Spelling","message":"Did you mean `the`?","priority":63,"rule":"SpellCheck","start":3,"suggestions":[{"replace":{"_0":"the"}},{"insert":{"_0":"s"}},{"remove":{}}]}"#
        let issue = try roundTrip(WritingIssue.self, json)
        XCTAssertEqual(issue.start, 3)
        XCTAssertEqual(issue.end, 6)
        XCTAssertEqual(issue.context, "stable")
        XCTAssertEqual(issue.suggestions, [.replace("the"), .insert("s"), .remove])
    }

    func testEachSuggestionHasTheOriginalSynthesizedShape() throws {
        XCTAssertEqual(try roundTrip(WritingSuggestion.self, #"{"replace":{"_0":"the"}}"#), .replace("the"))
        XCTAssertEqual(try roundTrip(WritingSuggestion.self, #"{"insert":{"_0":"s"}}"#), .insert("s"))
        XCTAssertEqual(try roundTrip(WritingSuggestion.self, #"{"remove":{}}"#), .remove)
    }

    func testMacPreviewStillDecodes() throws {
        let json = #"{"start":0,"end":4,"rule":"SpellCheck","kind":"Spelling","message":"Did you mean to spell `IPTV` this way?","priority":0,"suggestions":[],"context":"IPTV"}"#
        let issue = try JSONDecoder().decode(WritingIssue.self, from: Data(json.utf8))
        XCTAssertEqual(issue, WritingIssue(start: 0, end: 4, rule: "SpellCheck", kind: "Spelling",
                                          message: "Did you mean to spell `IPTV` this way?", priority: 0,
                                          suggestions: [], context: "IPTV"))
    }
}
