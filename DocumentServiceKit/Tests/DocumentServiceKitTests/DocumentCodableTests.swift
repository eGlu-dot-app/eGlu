import DocumentServiceKit
import Foundation
import XCTest

final class DocumentCodableTests: XCTestCase {
    func testPagesKeepTheOriginalSynthesizedShape() throws {
        let json = #"{"author":"Ada","created":"2026","pageCount":2,"pages":[{"markdown":"Hello","needsOCR":false,"page":0},{"markdown":"","needsOCR":true,"page":1,"reason":"picture"}],"title":"Report","withColumns":[0],"withTables":[0]}"#
        let bytes = Data(json.utf8)
        let pages = try JSONDecoder().decode(DocumentPages.self, from: bytes)
        XCTAssertEqual(pages.pages[1], DocumentPages.Page(page: 1, markdown: "", needsOCR: true, reason: "picture"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(pages), bytes)
    }

    func testKindsKeepTheirRawValues() throws {
        let json = #"["doc","docx","odt","pdf","ppt","pptx","rtf","epub","excel","ods","odp","csv"]"#
        let kinds = try JSONDecoder().decode([DocumentKind].self, from: Data(json.utf8))
        XCTAssertEqual(kinds, [.doc, .docx, .odt, .pdf, .ppt, .pptx, .rtf, .epub, .excel, .ods, .odp, .csv])
        XCTAssertEqual(try JSONEncoder().encode(kinds), Data(json.utf8))
    }
}
