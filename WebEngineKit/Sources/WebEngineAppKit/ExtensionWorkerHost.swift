import Foundation

/// Catalog and product decisions needed by worker recovery. Each answer is
/// read at the original call site, including after worker clearing awaits.
@MainActor public protocol ExtensionWorkerHost: AnyObject {
    var extensionWorkerSpaces: [UUID] { get }
    var extensionWorkerInstallations: [WebExtensionWorkerInstallation] { get }
    func extensionWorkerCheckStamp(_ version: String) -> String
    func resetExtensionWorkerCompatibility(_ id: String)
    func markExtensionWorkerIncompatible(_ id: String, version: String)
    func updateExtensionWorker(_ id: String, in space: UUID, event: WebExtensionWorkerEvent)
    func releaseExtensionWorkerPower(_ key: String)
    func noteExtensionWorker(_ line: String)
}
