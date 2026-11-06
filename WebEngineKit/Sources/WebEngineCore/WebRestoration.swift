@MainActor public protocol WebRestoration: AnyObject {
    /// The engine's own record of the page's history and scroll position, to
    /// give back to a page of the same engine; nil where it has none. The
    /// app keeps it as it is and never reads inside it.
    /// Kept as Any because WebKit's public API does not promise Data.
    var restorationData: Any? { get set }
}
