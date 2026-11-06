/// The size a website asked its window to be; nil where it did not say.
public struct WebWindowFeatures: Sendable, Equatable {
    public let width: Double?
    public let height: Double?

    public init(width: Double?, height: Double?) {
        self.width = width
        self.height = height
    }
}

/// A website asking for a window of its own. The host accepts it by
/// making the child page from it, through its engine, before the call
/// that asked returns, and rejects it by making none: the engine needs the
/// child at once to keep its tie to the page that opened it.
///
/// The plan's accept()/reject() methods wait until the app's page is the
/// engine's own page. For now, the host returns the app's child page or nil.
@MainActor
public protocol WebChildRequest: AnyObject {
    /// The navigation that asked for the window.
    var navigation: WebNavigation { get }
    var features: WebWindowFeatures { get }
}
