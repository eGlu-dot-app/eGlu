@MainActor public protocol WebBackForward: AnyObject {
    /// The engine's own object for the back-forward entry on screen, for
    /// its identity only: the same entry is the same object while it is held.
    var currentEntry: AnyObject? { get }
}
