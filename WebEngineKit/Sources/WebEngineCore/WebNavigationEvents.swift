import Foundation

/// Why a load failed, as the engine sorts it. The page stays quiet about
/// the first two kinds: the person or the page stopped it, or it turned
/// into something else (a download, a plug-in's own load).
public struct WebLoadError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case cancelled, interrupted, other }
    public let kind: Kind
    /// The engine's own error domain and code, for the message the page shows.
    public let domain: String
    public let code: Int
    /// The address that failed, when the engine says.
    public let failingURL: URL?

    public init(kind: Kind, domain: String, code: Int, failingURL: URL?) {
        self.kind = kind
        self.domain = domain
        self.code = code
        self.failingURL = failingURL
    }
}

/// What happens to the main frame's load, reported in order, on the main actor.
/// Navigation and document identifiers wait until a slice needs them:
/// Page does not use WebKit's navigation objects in these callbacks.
@MainActor
public protocol WebNavigationEvents: AnyObject {
    /// A load began; `url` is the address the engine now shows for it.
    func navigationStarted(url: URL?)
    /// The server redirected the load that has not committed yet.
    func navigationRedirected(url: URL?)
    /// The new document replaced the old one.
    func navigationCommitted(url: URL?)
    func navigationFinished()
    /// `provisional` is true when the load failed before it committed.
    func navigationFailed(_ error: WebLoadError, provisional: Bool)
    /// The page's content process ended; the page is blank.
    func contentProcessEnded()
}
