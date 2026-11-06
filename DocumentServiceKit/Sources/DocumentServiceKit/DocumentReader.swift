import Foundation

public enum DocumentKind: String, Sendable, Codable {
    case doc, docx, odt, pdf, ppt, pptx, rtf, epub, excel, ods, odp, csv
}

public struct DocumentPages: Sendable, Equatable, Codable {
    public struct Page: Sendable, Equatable, Codable {
        /// The page number, 0-based.
        public var page: Int
        public var markdown: String
        public var needsOCR: Bool
        public var reason: String?

        public init(page: Int, markdown: String, needsOCR: Bool, reason: String?) {
            self.page = page
            self.markdown = markdown
            self.needsOCR = needsOCR
            self.reason = reason
        }
    }

    public var pageCount: Int
    public var title: String?
    public var author: String?
    public var created: String?
    public var pages: [Page]
    public var withTables: [Int]
    public var withColumns: [Int]

    public init(pageCount: Int, title: String?, author: String?, created: String?,
                pages: [Page], withTables: [Int], withColumns: [Int]) {
        self.pageCount = pageCount
        self.title = title
        self.author = author
        self.created = created
        self.pages = pages
        self.withTables = withTables
        self.withColumns = withColumns
    }
}

public struct DocumentReadError: Error, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case needsOCR, unsupported, malformed, encrypted, resourceLimit
        case missingPart, io, panic, tooLarge, unknown
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Synchronous byte reading, called from the document source's concurrent work.
public protocol DocumentReader: Sendable {
    func detect(_ bytes: Data) throws -> DocumentKind?
    func markdown(_ bytes: Data, kind: DocumentKind?) throws -> (kind: DocumentKind?, markdown: String)
    func pdfPages(_ bytes: Data, pages: [Int]?) throws -> DocumentPages
}
