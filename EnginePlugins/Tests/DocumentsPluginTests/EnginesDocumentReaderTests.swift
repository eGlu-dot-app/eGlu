import CoreGraphics
import CoreText
import DocumentServiceKit
import DocumentsPlugin
import Engines
import Foundation
import XCTest

final class EnginesDocumentReaderTests: XCTestCase {
    private let reader = EnginesDocumentReader()

    private func pdf(pictureSecond: Bool = false) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box,
                                             [kCGPDFContextTitle: "Report", kCGPDFContextAuthor: "Ada"] as CFDictionary))
        for page in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
            if !pictureSecond || page == 0 {
                let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                let text = NSAttributedString(string: "Hello from eGlu. This document has readable text.",
                                              attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                context.textPosition = CGPoint(x: 10, y: 120)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }

    func testCSVMatchesDocuments() throws {
        let bytes = Data("Name,City\nAda,Seoul\n".utf8)
        XCTAssertEqual(try reader.detect(bytes)?.rawValue, try Documents.detect(bytes)?.rawValue)
        XCTAssertNil(try reader.detect(bytes))
        let direct = try Documents.markdown(bytes, format: .csv)
        let read = try reader.markdown(bytes, kind: .csv)
        XCTAssertEqual(read.kind?.rawValue, direct.format?.rawValue)
        XCTAssertEqual(read.markdown, direct.markdown)
        XCTAssertTrue(read.markdown.contains("Seoul"))
    }

    func testPDFMatchesDocumentsIncludingPageSelection() throws {
        let bytes = try pdf()
        XCTAssertEqual(try reader.detect(bytes), .pdf)
        XCTAssertEqual(try reader.detect(bytes)?.rawValue, try Documents.detect(bytes)?.rawValue)
        for kind: DocumentKind? in [nil, .pdf] {
            let direct = try Documents.markdown(bytes, format: kind.map { DocumentFormat(rawValue: $0.rawValue)! })
            let read = try reader.markdown(bytes, kind: kind)
            XCTAssertEqual(read.kind?.rawValue, direct.format?.rawValue)
            XCTAssertEqual(read.markdown, direct.markdown)
        }
        for selection: [Int]? in [nil, [1], [0, 1]] {
            let direct = try Documents.pdfPages(bytes, pages: selection)
            let expected = try JSONDecoder().decode(DocumentPages.self, from: JSONEncoder().encode(direct))
            XCTAssertEqual(try reader.pdfPages(bytes, pages: selection), expected)
        }
    }

    func testPicturePageKeepsItsOCRFlagAndError() throws {
        let bytes = try pdf(pictureSecond: true)
        let direct = try Documents.pdfPages(bytes)
        let expected = try JSONDecoder().decode(DocumentPages.self, from: JSONEncoder().encode(direct))
        let read = try reader.pdfPages(bytes, pages: nil)
        XCTAssertEqual(read, expected)
        XCTAssertEqual(read.pages.map(\.needsOCR), [false, true])
        var directError: EngineError?
        do { _ = try Documents.markdown(bytes, format: .pdf); XCTFail("Expected an OCR error") }
        catch { directError = try XCTUnwrap(error as? EngineError) }
        let error = try XCTUnwrap(directError)
        XCTAssertEqual(error.kind, .needsOCR)
        XCTAssertThrowsError(try reader.markdown(bytes, kind: .pdf)) { readError in
            XCTAssertEqual((readError as? DocumentReadError)?.kind.rawValue, error.kind.rawValue)
            XCTAssertEqual((readError as? DocumentReadError)?.message, error.message)
        }
    }

    func testEngineErrorKeepsItsKindAndMessage() throws {
        let bytes = Data([0x11, 0x22, 0x33])
        var direct: EngineError?
        do { _ = try Documents.markdown(bytes, format: .docx); XCTFail("Expected unreadable bytes") }
        catch { direct = try XCTUnwrap(error as? EngineError) }
        let expected = try XCTUnwrap(direct)
        XCTAssertThrowsError(try reader.markdown(bytes, kind: .docx)) { error in
            XCTAssertEqual((error as? DocumentReadError)?.kind.rawValue, expected.kind.rawValue)
            XCTAssertEqual((error as? DocumentReadError)?.message, expected.message)
        }
        var pdfError: EngineError?
        do { _ = try Documents.pdfPages(bytes); XCTFail("Expected unreadable PDF") }
        catch { pdfError = try XCTUnwrap(error as? EngineError) }
        let expectedPDF = try XCTUnwrap(pdfError)
        XCTAssertThrowsError(try reader.pdfPages(bytes, pages: nil)) { error in
            XCTAssertEqual((error as? DocumentReadError)?.kind.rawValue, expectedPDF.kind.rawValue)
            XCTAssertEqual((error as? DocumentReadError)?.message, expectedPDF.message)
        }
    }

    func testAllKindRawValuesMatchEngines() {
        let kinds: [DocumentKind] = [.doc, .docx, .odt, .pdf, .ppt, .pptx, .rtf, .epub, .excel, .ods, .odp, .csv]
        for kind in kinds { XCTAssertEqual(DocumentFormat(rawValue: kind.rawValue)?.rawValue, kind.rawValue) }
        let errors: [EngineError.Kind] = [.needsOCR, .unsupported, .malformed, .encrypted, .resourceLimit,
                                          .missingPart, .io, .panic, .tooLarge, .unknown]
        for kind in errors { XCTAssertEqual(DocumentReadError.Kind(rawValue: kind.rawValue)?.rawValue, kind.rawValue) }
    }
}
