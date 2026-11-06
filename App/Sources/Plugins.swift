import DocumentServiceKit
import DocumentsPlugin
import HarperPlugin
import WritingServiceKit

extension WritingChecker {
    nonisolated static let engine: any GrammarEngine = HarperGrammarEngine()
}

extension DocumentSource {
    nonisolated static let reader: any DocumentReader = EnginesDocumentReader()
}
