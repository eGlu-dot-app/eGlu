import AppKit

/// Installation refusal values. The host returns the app's original error type.
public enum WebExtensionInstallRefusal: LocalizedError {
    case download(Int)
    case nothing
    case notAPackage
    case noManifest
    case badVersion
    case notChecked(String)

    public var errorDescription: String? {
        switch self {
        case .download(let code): return String(localized: "The Chrome Web Store answered \(code).")
        case .nothing: return String(localized: "The Chrome Web Store has nothing for that extension. It may have been taken down.")
        case .notAPackage: return String(localized: "That isn't a Chrome extension.")
        case .noManifest: return String(localized: "The extension has no manifest.json.")
        case .badVersion: return String(localized: "The extension's version isn't one Chrome would take.")
        case .notChecked(let reason): return reason
        }
    }
}

/// A parsed archive. Name and icon reads stay at their original call sites.
@MainActor public protocol WebExtensionInstallArchive: AnyObject {
    var version: String { get }
    var grants: [String] { get }
    var permissions: [String] { get }
    var sites: [String] { get }
    func checkedVersion() throws -> String
    func name(fallback: String) -> String
    func icon() -> NSImage?
}

/// The app decides whether the loaded replacement is current and whether
/// to restore the catalog. Execution then finishes inline with that answer.
public enum WebExtensionInstallCompletion {
    case finished(Bool, keeping: String?)
    case restore(WebExtensionInstallation)
}

/// Installation execution, composed into the runtime by the last hub slice.
/// The app creates the original tasks and owns all catalog and consent changes.
@MainActor public protocol WebExtensionInstallExecution: AnyObject {
    func download(_ id: String, from address: URL?) async throws -> Data
    func readArchive(_ archive: Data) throws -> any WebExtensionInstallArchive
    func describeOffer(_ archive: Data, id: String) throws -> (any WebExtensionInstallArchive, String)
    func verifyUpdate(_ crx: Data, id: String, size: Int?, sha256: String?, version: String) throws -> (Data, any WebExtensionInstallArchive, String)
    func keepArchive(_ archive: Data, id: String, name: String, version: String) throws -> String
    func unload(_ item: WebExtensionInstallation)
    func loadReplacement(_ item: WebExtensionInstallation,
                         completion: (Bool) -> WebExtensionInstallCompletion) async -> Bool
    func loadNew(_ item: WebExtensionInstallation, didLoad: () -> Void) async -> Bool
    func removeOtherVersions(of id: String, keeping version: String)
    func trial(_ archive: Data, id: String) async throws
    func snapshot(_ folder: URL) async throws -> WebExtensionFolderSnapshot
    func zipped(_ folder: URL) async throws -> Data
    func sha256(_ data: Data) -> String
}

public struct WebExtensionFolderSnapshot: Sendable {
    public let path: String
    public let id: String
    public let archive: Data

    public init(path: String, id: String, archive: Data) {
        self.path = path
        self.id = id
        self.archive = archive
    }
}
