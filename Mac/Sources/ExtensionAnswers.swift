import AppKit
import WebEngineAppKit

extension Extensions {
    struct Unanswered: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }


    static func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        try EngineComposition.scriptAnswers.scriptingFile(function, arguments: arguments, in: folder)
    }
    static func kept(_ name: String, of id: String, in space: UUID) -> URL { EngineComposition.scriptAnswers.kept(name, of: id, in: space) }
    static func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool = true) throws -> String {
        try EngineComposition.scriptAnswers.userScriptFile(script, in: folder, writing: writing)
    }
    static func pruneUserScripts(of id: String, in folder: URL) { EngineComposition.scriptAnswers.pruneUserScripts(of: id, in: folder) }
    static func favIconURL(for url: URL?) -> String? { EngineComposition.browserAnswers.favIconURL(for: url) }
    static var pressed: [String: Date] {
        get { EngineComposition.pressed }
        set { EngineComposition.pressed = newValue }
    }
    func asks(_ id: String, in space: UUID, for permission: String) -> Bool { runtime.asks(id, in: space, for: permission) }
    func tab(at place: Any?, in space: UUID) -> UUID? { runtime.tab(at: place, in: space) }
    static func appName(ofHost host: String) -> String { EngineComposition.appName(ofHost: host) }
    func sidePanelDefaultPath(_ id: String, in space: UUID) -> String? { runtime.sidePanelDefaultPath(id, in: space) }
    func sidePanelSource(_ id: String, in space: UUID) -> ExtensionPaneSource? { runtime.sidePanelSource(id, in: space) }
}
