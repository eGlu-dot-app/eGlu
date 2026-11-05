import Foundation

/// The catalog facts workers need. The catalog itself stays in the app.
public struct WebExtensionWorkerInstallation: Sendable {
    public let id: String
    public let version: String
    public let spaces: [UUID]

    public init(id: String, version: String, spaces: [UUID]) {
        self.id = id
        self.version = version
        self.spaces = spaces
    }
}

/// Applied inline through the hub's existing evidence mutation.
public enum WebExtensionWorkerEvent: Sendable {
    case started, failed, timedOutIfChecking
}

/// The worker lifecycle part of the runtime, composed by the last hub slice.
/// Restart preserves the loaded context and controller and their grants.
@MainActor public protocol WebExtensionWorkers: AnyObject {
    func forgetWorkersIfChanged() async
    func workersChanged()
    @discardableResult func revive(_ id: String, in space: UUID, because reason: String) -> Bool
    @discardableResult func restart(_ id: String, in space: UUID, because reason: String) -> Bool
}
