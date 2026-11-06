import Foundation

/// The generated-script part of the runtime. The last hub slice composes
/// its parts. Reads, writes and pruning stay synchronous on the main actor.
/// The shim's WebKit context and dispatch remain implementation details.
@MainActor public protocol WebExtensionScriptAnswers: AnyObject {
    func kept(_ name: String, of id: String, in space: UUID) -> URL
    func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String
    func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool) throws -> String
    func userScripts(of id: String, in space: UUID) -> Any
    func changeUserScripts(_ first: Any?, of id: String, in space: UUID) throws -> [[String: Any]]
    func userScriptWorlds(of id: String, in space: UUID) -> [[String: Any]]
    func setUserScriptWorld(_ first: Any?, of id: String, in space: UUID) throws
    func pruneUserScripts(of id: String, in folder: URL)
}
