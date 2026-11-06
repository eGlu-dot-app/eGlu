import DocumentServiceKit
import Engines
import Foundation

public struct EnginesDocumentReader: DocumentReader {
    public init() {}

    public func detect(_ bytes: Data) throws -> DocumentKind? {
        try reading { try Documents.detect(bytes).map { DocumentKind(rawValue: $0.rawValue)! } }
    }

    public func markdown(_ bytes: Data, kind: DocumentKind?) throws -> (kind: DocumentKind?, markdown: String) {
        try reading {
            let read = try Documents.markdown(bytes, format: kind.map { DocumentFormat(rawValue: $0.rawValue)! })
            return (read.format.map { DocumentKind(rawValue: $0.rawValue)! }, read.markdown)
        }
    }

    public func pdfPages(_ bytes: Data, pages: [Int]?) throws -> DocumentPages {
        try reading {
            let read = try Documents.pdfPages(bytes, pages: pages)
            return DocumentPages(pageCount: read.pageCount, title: read.title, author: read.author,
                                 created: read.created, pages: read.pages.map {
                                     DocumentPages.Page(page: $0.page, markdown: $0.markdown,
                                                        needsOCR: $0.needsOCR, reason: $0.reason)
                                 }, withTables: read.withTables, withColumns: read.withColumns)
        }
    }

    /// Other failures pass through unchanged, as they did from Documents.
    private func reading<T>(_ read: () throws -> T) throws -> T {
        do {
            return try read()
        } catch let error as EngineError {
            throw DocumentReadError(kind: DocumentReadError.Kind(rawValue: error.kind.rawValue)!,
                                    message: error.message)
        }
    }
}
