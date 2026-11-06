import CoreGraphics
import CoreText
import DocumentServiceKit
import DocumentsPlugin
import Engines
import Foundation
import HarperPlugin
import PadCore
import WebEngineCore
import WritingServiceKit
import XCTest
@testable import eGluMac

/// Grammar checking and document reading through the plugins the Mac app
/// is made with (Docs/EngineSplitPlan.md, 7, step 11), in the app's own
/// test host, each compared with what the `Engines` package gives when the
/// test calls it directly (the test target imports `Engines`, which the
/// host links through the plugins):
/// - the composition (Mac/Sources/Plugins.swift): Harper's engine for the
///   checker, the documents engine's reader for Handoff, the licences
///   About shows, whether the Mac can check, Harper's rules for Settings ›
///   Writing and its dialects for the picker;
/// - `WritingChecker.shared`, turned on with a `Preferences` value of the
///   test's (British, no rule changes), linting two English paragraphs
///   and a Korean one between them as a `Grammar` made directly with the
///   same settings lints each English paragraph, offsets included; a lint
///   ignored in both; and turned off, its linter dropped and no lints;
/// - the JSON a page is given: a lint message to the page's
///   `WritingHandler`, answered as the handler's mapping before this step
///   gives `Grammar`'s own lints; and `WritingIssue`'s Codable shape
///   against `GrammarLint`'s, for the writing panel's preview
///   (Mac/Sources/WindowModel.swift) and for an issue with each kind of
///   suggestion;
/// - `DocumentSource` reading a CSV and a one-page PDF made here, against
///   `Documents.markdown` and `Documents.pdfPages` of the same bytes; and
///   bytes the engines can't read, named as a kind they read, failing
///   with the words the source gave before for the engines' error.
///
/// The checker is given the test's value directly, Session's settings
/// untouched, and Session's settings again after each test: writing off
/// in the test host. The handler's test turns writing on in Session's
/// settings, as PageChannelTests does, never for other apps' fields, and
/// puts them back. The personal dictionary's words are read, never
/// written; no panel is shown. Documents are read from bytes in hand, into
/// a folder of the test's own in the test run's data folder, removed after
/// the test; no network.
///
/// Not here:
/// - `WritingHandler.json(for:in:)` given a fixed issue: it is private, so
///   only lints Harper finds reach it, through the handler's `handle`.
/// - Writing in a real page's fields: writing.js through a page
///   (PageChannelTests covers its channel).
/// - The Elsewhere checker and its panel: they work on other apps' fields
///   through Accessibility.
/// - Settings' screens (the rule list, the dialect picker, the dictionary).
/// - Office files read whole (the CSV stands for the engines' Markdown
///   path), pictures, recordings, archives, and a PDF's pages read by Vision.
/// - The iOS app, which compiles the same shared code with its own composition.
@MainActor
final class PageWritingTests: PageTestCase {
    /// Session's settings before the test, put back after it.
    private var preferences: Preferences?

    override func setUp() async throws {
        try await super.setUp()
        preferences = Session.shared.preferences
    }

    override func tearDown() async throws {
        if let preferences, Session.shared.preferences != preferences {
            Session.shared.preferences = preferences
        }
        preferences = nil
        // The checker as Session's settings have it: writing off in the test host.
        WritingChecker.shared.preferencesChanged(Session.shared.preferences)
        try await super.tearDown()
    }

    // MARK: The composition

    /// The checker's engine is Harper's plugin and the documents' reader
    /// the documents plugin's; About's licences are the engines' own text;
    /// the Mac can check, as a `Grammar` with the default settings can be
    /// made; the checker's rules are `Grammar.rules()` field for field, in
    /// their order; and the picker's dialects are Harper's, in its order.
    func testThePluginsGiveWhatTheEnginesGive() throws {
        XCTAssertTrue(WritingChecker.engine is HarperGrammarEngine,
                      "the checker's engine is a \(type(of: WritingChecker.engine))")
        XCTAssertTrue(DocumentSource.reader is EnginesDocumentReader,
                      "the documents' reader is a \(type(of: DocumentSource.reader))")

        XCTAssertEqual(PluginLicences.text, EngineLicenses.text)
        XCTAssertFalse(PluginLicences.text.isEmpty)
        XCTAssertNotEqual(PluginLicences.text, "The engines' licences did not load.")

        XCTAssertTrue(WritingChecker.canCheck)
        XCTAssertEqual(WritingChecker.canCheck, (try? Grammar()) != nil)

        let rules = WritingChecker.rules()
        let direct = try Grammar.rules()
        XCTAssertFalse(direct.isEmpty, "Grammar lists no rules")
        XCTAssertEqual(rules.count, direct.count)
        XCTAssertEqual(rules.map(\.id), direct.map(\.id))
        XCTAssertEqual(rules.map(\.label), direct.map(\.label))
        XCTAssertEqual(rules.map(\.description), direct.map(\.description))
        XCTAssertEqual(rules.map(\.group), direct.map(\.group))
        XCTAssertEqual(rules.map(\.isOnByDefault), direct.map(\.isOnByDefault))

        XCTAssertEqual(WritingDialect.allCases.map(\.rawValue), Dialect.allCases.map(\.rawValue))
    }

    // MARK: The checker

    /// Turned on with a value of the test's (British, no rule changes),
    /// the checker makes a linter with those settings and the personal
    /// dictionary's words, and lints a text of three paragraphs as a
    /// `Grammar` made directly with the same settings lints the first and
    /// the last, their offsets moved by what comes before them (an emoji
    /// counts two). The Korean paragraph between them, in which Harper
    /// flags a word, isn't sent. A lint ignored is gone from the checker's
    /// answer as from the direct one's. Turned off, the checker drops its
    /// linter and answers nothing.
    func testTheCheckerLintsAsGrammarDoes() async throws {
        let checker = WritingChecker.shared
        var off = Session.shared.preferences
        off.writing = false
        // From no linter, so the one made is the test's alone.
        checker.preferencesChanged(off)
        var on = off
        on.writing = true
        on.writingDialect = WritingDialect.british.rawValue
        on.writingRules = [:]
        checker.preferencesChanged(on)

        let words = WritingWords.load()
        XCTAssertEqual(try kept("made", of: checker, as: WritingConfiguration.self),
                       WritingConfiguration(dialect: .british, rules: [:], words: words))
        let service = try kept("grammar", of: checker, as: (any GrammarService).self)
        XCTAssertEqual(String(describing: type(of: service)), "HarperGrammarService")

        let paragraphs: [(text: String, english: Bool)] = [
            ("😀 I has a apple, and teh colour of it is nice.", true),
            ("오늘은 날씨가 정말 좋아서 공원에 산책을 가려고 합니다. teh 친구와 함께 커피도 마실 거예요.", false),
            ("This are an example of the the checker at work today.", true),
        ]
        let text = paragraphs.map(\.text).joined(separator: "\n")
        let grammar = try Grammar(settings: GrammarSettings(dialect: .british, rules: [:], words: words))

        let lints = await checker.lint(text)
        let direct = try await Self.lints(of: paragraphs, by: grammar)
        XCTAssertFalse(lints.isEmpty, "the checker found nothing")
        XCTAssertEqual(lints, try Self.issues(direct))
        XCTAssertEqual(try Self.sortedJSON(lints), try Self.sortedJSON(direct))

        // Each English paragraph has lints; the Korean one, which Harper
        // flags when given it, has none in the checker's answer.
        let koreanStart = paragraphs[0].text.utf16.count + 1
        let lastStart = koreanStart + paragraphs[1].text.utf16.count + 1
        XCTAssertTrue(lints.contains { $0.end < koreanStart }, "nothing found in the first paragraph")
        XCTAssertTrue(lints.contains { $0.start >= lastStart }, "nothing found in the last paragraph")
        XCTAssertFalse(lints.contains { $0.start >= koreanStart && $0.start < lastStart },
                       "the Korean paragraph was sent")
        let flagged = try await grammar.lint(paragraphs[1].text)
        XCTAssertFalse(flagged.isEmpty, "Harper flags nothing in the Korean paragraph, so its filter isn't seen")

        // A lint ignored, by the context its answer carried.
        let ignored = try XCTUnwrap(lints.first)
        checker.ignore(context: ignored.context)
        try await grammar.ignore(context: ignored.context)
        let after = await checker.lint(text)
        let directAfter = try await Self.lints(of: paragraphs, by: grammar)
        XCTAssertFalse(after.contains { $0.context == ignored.context }, "the ignored lint is still there")
        XCTAssertLessThan(after.count, lints.count)
        XCTAssertEqual(after, try Self.issues(directAfter))

        checker.preferencesChanged(off)
        XCTAssertTrue(try isNil("grammar", of: checker), "the checker kept its linter with writing off")
        XCTAssertTrue(try isNil("made", of: checker))
        let none = await checker.lint(text)
        XCTAssertEqual(none, [])
    }

    // MARK: The JSON a page is given

    /// A lint message to the page's writing handler, as writing.js sends
    /// one, is answered with the JSON the handler gave before: its mapping
    /// before this step, applied to what a `Grammar` made with Session's
    /// writing settings finds in the text, sorted by where each starts.
    /// The text is one English paragraph, which the checker sends whole;
    /// its emoji counts two in the offsets and the words flagged.
    func testTheHandlerAnswersALintAsBefore() async throws {
        var preferences = Session.shared.preferences
        preferences.writing = true
        preferences.writingOtherApps = false
        preferences.writingDialect = WritingDialect.american.rawValue
        preferences.writingRules = [:]
        Session.shared.preferences = preferences
        let page = makePage()
        await load(page, "Written")
        XCTAssertTrue(page.checksWriting())

        let text = "😀 I has a apple and teh dog ran to the the park with my friends."
        let handler = WritingHandler(page: page)
        let message = WebMessage(channel: WritingHandler.name, world: .app, isMainFrame: true, origin: .opaque,
                                 body: .object(["kind": .string("lint"), "text": .string(text)]))
        let answered = expectation(description: "the handler answered")
        var answer: WebJSON?
        handler.handle(message) { reply in
            answer = reply
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 60)

        let grammar = try Grammar(settings: GrammarSettings(dialect: .american, rules: [:], words: WritingWords.load()))
        let lints = try await grammar.lint(text).sorted { $0.start < $1.start }
        XCTAssertFalse(lints.isEmpty, "Harper found nothing in \"\(text)\"")
        XCTAssertEqual(answer, WebJSON(foundation: lints.map { Self.jsonBefore(for: $0, in: text) }))
    }

    /// The writing panel's preview, WindowModel's fixed JSON (its literal
    /// copied here, and still the app's), decodes as a `WritingIssue`, as
    /// does an issue with each kind of suggestion; each encodes to the
    /// bytes a `GrammarLint` decoded from the same JSON encodes to.
    func testAnIssueHasTheShapeOfGrammarsLint() throws {
        let model = try String(contentsOf: Self.windowModel, encoding: .utf8)
        XCTAssertTrue(model.contains(Self.preview), "WindowModel's preview isn't the JSON copied here")

        let preview = try JSONDecoder().decode(WritingIssue.self, from: Data(Self.preview.utf8))
        XCTAssertEqual(preview, WritingIssue(start: 0, end: 4, rule: "SpellCheck", kind: "Spelling",
                                             message: "Did you mean to spell `IPTV` this way?", priority: 0,
                                             suggestions: [], context: "IPTV"))
        let every = try JSONDecoder().decode(WritingIssue.self, from: Data(Self.everySuggestion.utf8))
        XCTAssertEqual(every.suggestions, [.replace("the"), .insert("s"), .remove])
        XCTAssertEqual(try Self.sortedJSON(every), Data(Self.everySuggestion.utf8))

        for json in [Self.preview, Self.everySuggestion] {
            let issue = try JSONDecoder().decode(WritingIssue.self, from: Data(json.utf8))
            let lint = try JSONDecoder().decode(GrammarLint.self, from: Data(json.utf8))
            XCTAssertEqual(try Self.sortedJSON(issue), try Self.sortedJSON(lint), "encoded unlike a GrammarLint: \(json)")
        }
    }

    // MARK: Documents

    /// A CSV handed off from bytes, named as one, reads as the documents
    /// engine's Markdown of the same bytes, made a reading as a document's
    /// is (`HandoffDocument`), with the facts the source keeps of it.
    func testACSVReadsAsTheEnginesMarkdown() async throws {
        let bytes = Data("Name,City,Note\nAda,Seoul,\"Hello, world\"\nGrace,Busan,Plain\n".utf8)
        let name = "people.csv"
        let folder = try folderOfOwn()
        let source = DocumentSource(data: bytes, name: name)
        let outcome = await source.reading(limit: Handoff.limit, into: folder, telling: nil)
        guard case .content(let reading) = outcome else { return XCTFail("the CSV wasn't read: \(outcome)") }

        XCTAssertNil(try Documents.detect(bytes), "CSV has no signature; the name tells it")
        let direct = try Documents.markdown(bytes, format: .csv)
        XCTAssertTrue(direct.markdown.contains("Seoul"), "the engines' Markdown: \(direct.markdown)")
        var facts = FileFacts(format: .csv, name: name, bytes: bytes.count)
        let declared = HandoffDocument.declared(in: bytes)
        facts.title = declared.title
        facts.author = declared.author
        facts.created = declared.created
        let fitted = HandoffDocument.fitted(direct.markdown, room: Handoff.limit)
        facts.unread = fitted.unread
        XCTAssertEqual(reading, HandoffDocument.reading(markdown: fitted.markdown, facts: facts, truncated: fitted.truncated))
        XCTAssertFalse(reading.blocks.isEmpty)
        XCTAssertEqual(source.file, facts)
    }

    /// A one-page PDF made here, with a line of text, a title and an
    /// author, reads as `Documents.pdfPages` gives its pages (the first
    /// 300, as the source asks for them), with its page count, title and
    /// author in the facts the source keeps.
    func testAPDFReadsAsTheEnginesPages() async throws {
        let bytes = try Self.pdf()
        let name = "report.pdf"
        let folder = try folderOfOwn()
        let source = DocumentSource(data: bytes, name: name)
        let outcome = await source.reading(limit: Handoff.limit, into: folder, telling: nil)
        guard case .content(let reading) = outcome else { return XCTFail("the PDF wasn't read: \(outcome)") }

        XCTAssertEqual(try Documents.detect(bytes), .pdf)
        let direct = try Documents.pdfPages(bytes, pages: Array(0..<DocumentSource.pageLimit))
        XCTAssertEqual(direct.pageCount, 1)
        XCTAssertEqual(direct.pages.map(\.needsOCR), [false], "the page's text isn't readable to the engines")
        let markdown = direct.pages.map(\.markdown).filter { !$0.isEmpty }.joined(separator: "\n\n")
        XCTAssertTrue(markdown.contains("Hello from eGlu"), "the engines' Markdown: \(markdown)")
        var facts = FileFacts(format: .pdf, name: name, bytes: bytes.count)
        facts.pages = direct.pageCount
        facts.title = direct.title
        facts.author = direct.author
        facts.created = direct.created
        XCTAssertEqual(reading, HandoffDocument.reading(markdown: markdown, facts: facts, truncated: false))
        XCTAssertEqual(source.file, facts)
    }

    /// Bytes the engines can't read, named as a kind they read (Word old
    /// and new, PowerPoint, Excel, OpenDocument, EPUB and PDF), and a PDF
    /// locked with a password: each fails with the words the source gave
    /// before for the error the engines give for the same bytes and kind,
    /// a protected file as a protected page, any other as a failure. The
    /// engines call the broken ones malformed, whose words the source's
    /// catch-all says too; the locked PDF, encrypted, is a protected page,
    /// which only the engines' error makes.
    func testUnreadableBytesFailWithTheWordsOfBefore() async throws {
        let folder = try folderOfOwn()
        let garbage = Data([0x11, 0x22, 0x33])
        let locked = try Self.pdf(password: "eglu-tests")
        let pages = Array(0..<DocumentSource.pageLimit)
        XCTAssertNil(try? Documents.detect(garbage), "the engines tell a kind from the bytes, not the name")
        XCTAssertEqual(try? Documents.detect(locked), .pdf)
        let cases: [(name: String, bytes: Data, read: () throws -> Void)] = [
            ("broken.docx", garbage, { _ = try Documents.markdown(garbage, format: .docx) }),
            ("broken.doc", garbage, { _ = try Documents.markdown(garbage, format: .doc) }),
            ("broken.pptx", garbage, { _ = try Documents.markdown(garbage, format: .pptx) }),
            ("broken.xlsx", garbage, { _ = try Documents.markdown(garbage, format: .excel) }),
            ("broken.odt", garbage, { _ = try Documents.markdown(garbage, format: .odt) }),
            ("broken.epub", garbage, { _ = try Documents.markdown(garbage, format: .epub) }),
            ("broken.pdf", garbage, { _ = try Documents.pdfPages(garbage, pages: pages) }),
            ("locked.pdf", locked, { _ = try Documents.pdfPages(locked, pages: pages) }),
        ]
        for (name, bytes, read) in cases {
            var failure: EngineError?
            do {
                try read()
                XCTFail("the engines read \(name)")
            } catch {
                failure = error as? EngineError
            }
            let error = try XCTUnwrap(failure, "\(name): the engines failed with no EngineError")
            // The locked PDF is the one whose words only the engines' error
            // gives (a protected page); the others' are the catch-all's too.
            XCTAssertEqual(error.kind == .encrypted, name == "locked.pdf", "\(name): the engines said \(error.kind)")
            let words = Self.wordsBefore(for: error.kind)
            let outcome = await DocumentSource(data: bytes, name: name).reading(limit: Handoff.limit, into: folder, telling: nil)
            switch outcome {
            case .protectedPage(let said):
                XCTAssertEqual(error.kind, .encrypted, "\(name) was said to be protected")
                XCTAssertEqual(said, words, name)
            case .failed(let said):
                XCTAssertNotEqual(error.kind, .encrypted, "\(name) wasn't said to be protected")
                XCTAssertEqual(said, words, name)
            default:
                XCTFail("\(name) didn't fail: \(outcome)")
            }
        }
    }

    // MARK: Helpers

    /// The writing panel's preview in Mac/Sources/WindowModel.swift, as it is there.
    private static let preview = #"{"start":0,"end":4,"rule":"SpellCheck","kind":"Spelling","message":"Did you mean to spell `IPTV` this way?","priority":0,"suggestions":[],"context":"IPTV"}"#

    /// An issue with each kind of suggestion, its keys sorted as an encoder sorting them writes them.
    private static let everySuggestion = #"{"context":"stable","end":6,"kind":"Spelling","message":"Did you mean `the`?","priority":63,"rule":"SpellCheck","start":3,"suggestions":[{"replace":{"_0":"the"}},{"insert":{"_0":"s"}},{"remove":{}}]}"#

    /// Mac/Sources/WindowModel.swift in the checkout these tests were built from.
    private static var windowModel: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Mac/Sources/WindowModel.swift")
    }

    /// The lints of each English paragraph, by `grammar` alone, moved by
    /// the paragraphs and line breaks before it, sorted by where each starts.
    private static func lints(of paragraphs: [(text: String, english: Bool)],
                              by grammar: Grammar) async throws -> [GrammarLint] {
        var lints: [GrammarLint] = []
        var offset = 0
        for paragraph in paragraphs {
            if paragraph.english {
                for var lint in try await grammar.lint(paragraph.text) {
                    lint.start += offset
                    lint.end += offset
                    lints.append(lint)
                }
            }
            offset += paragraph.text.utf16.count + 1
        }
        return lints.sorted { $0.start < $1.start }
    }

    /// `Grammar`'s lints as issues, by their Codable shape, not the plugin's mapping.
    private static func issues(_ lints: [GrammarLint]) throws -> [WritingIssue] {
        try JSONDecoder().decode([WritingIssue].self, from: JSONEncoder().encode(lints))
    }

    /// The value's JSON, its keys sorted.
    private static func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// WritingHandler's `json(for:in:)` before this step, of `Grammar`'s own lint.
    private static func jsonBefore(for lint: GrammarLint, in text: String) -> [String: Any] {
        let ns = text as NSString
        let span = NSRange(location: lint.start, length: lint.end - lint.start)
        let word = span.location != NSNotFound && NSMaxRange(span) <= ns.length
            ? ns.substring(with: span) : ""
        return [
            "start": lint.start,
            "end": lint.end,
            "kind": lint.kind,
            "rule": lint.rule,
            "message": lint.message,
            "context": lint.context,
            "word": word,
            "suggestions": lint.suggestions.map { suggestion -> [String: Any] in
                switch suggestion {
                case .replace(let text): return ["replace": text]
                case .insert(let text): return ["insert": text]
                case .remove: return ["remove": true]
                }
            },
        ]
    }

    /// DocumentSource's `words(for:)` before this step, by the engines' own error.
    private static func wordsBefore(for kind: EngineError.Kind) -> String {
        switch kind {
        case .encrypted: return String(localized: "This file is protected by a password.")
        case .unsupported: return String(localized: "eGlu can't read this kind of file.")
        case .tooLarge: return String(localized: "This file is too large to read.")
        default: return String(localized: "The file could not be read.")
        }
    }

    /// A one-page PDF, 200 points square, titled Report by Ada: a black
    /// square and a line of text in Helvetica. With `password`, it opens
    /// only with it.
    private static func pdf(password: String? = nil) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        var info: [CFString: Any] = [kCGPDFContextTitle: "Report", kCGPDFContextAuthor: "Ada"]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password + "-owner"
        }
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let text = NSAttributedString(string: "Hello from eGlu. This document has readable text.",
                                      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 10, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        return bytes as Data
    }

    /// A folder of the test's own in the test run's data folder (never the
    /// person's), removed after the test.
    private func folderOfOwn(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let root = try XCTUnwrap(Session.dataRootOverride, "the test host has no data folder of its own",
                                 file: file, line: line)
        XCTAssertEqual(Session.folder, root, file: file, line: line)
        XCTAssertFalse(root.path.contains("Application Support/Safience"), "the data folder is \(root.path)",
                       file: file, line: line)
        let folder = root.appendingPathComponent("eglu-tests-documents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the test's folder is still there")
        }
        return folder
    }

    /// A value `subject` keeps to itself, read by its name.
    private func kept<T>(_ name: String, of subject: Any, as type: T.Type = T.self,
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let child = try XCTUnwrap(Mirror(reflecting: subject).children.first { $0.label == name },
                                  "\(Swift.type(of: subject)) keeps no \(name)", file: file, line: line)
        return try XCTUnwrap(child.value as? T, "\(name) is a \(Swift.type(of: child.value))", file: file, line: line)
    }

    /// Whether the optional `subject` keeps by `name` is nil.
    private func isNil(_ name: String, of subject: Any, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let child = try XCTUnwrap(Mirror(reflecting: subject).children.first { $0.label == name },
                                  "\(Swift.type(of: subject)) keeps no \(name)", file: file, line: line)
        let value = Mirror(reflecting: child.value)
        XCTAssertEqual(value.displayStyle, .optional, "\(name) is no optional", file: file, line: line)
        return value.children.isEmpty
    }
}
