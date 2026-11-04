import Foundation

/// A page of a site loaded out of sight, beside a page and in its store,
/// read once by the app and let go (Page.transcript).
@MainActor public protocol WebHiddenPage: AnyObject {
    /// Loads the address: true once it has begun (its document committed);
    /// false if it fails, a step is refused, or `limit` passes first.
    func begin(_ url: URL, within limit: Duration) async -> Bool
    /// Calls `body` in the app's own world of its main frame with `arguments`.
    func callInAppWorld(_ body: String, arguments: [String: Any]) async throws -> Any?
    /// It goes: whoever waits on `begin` hears false.
    func stop()
}
