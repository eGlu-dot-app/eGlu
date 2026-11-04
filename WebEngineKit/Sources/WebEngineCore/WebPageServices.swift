@MainActor public protocol WebFind: AnyObject {
    /// The next match after the selection, or before it; `found` hears whether there is one.
    func find(_ text: String, backwards: Bool, caseSensitive: Bool, wraps: Bool,
              found: @escaping @MainActor (Bool) -> Void)
}

@MainActor public protocol WebZoom: AnyObject {
    /// The page's own zoom, 1 at actual size.
    var pageZoom: Double { get set }
    /// The pinch's magnification over it, 1 with none.
    var magnification: Double { get }
}

@MainActor public protocol WebMediaCapture: AnyObject {
    /// The page has the camera or the microphone, live or muted.
    var isCapturing: Bool { get }
}

@MainActor public protocol WebUserAgent: AnyObject {
    /// The user agent sent instead of the engine's own; nil for the engine's.
    var customUserAgent: String? { get set }
}

public enum WebDeveloperTool: Sendable, Equatable { case inspector, console, elementSelection }

@MainActor public protocol WebDeveloperTools: AnyObject {
    /// Opens the tool for the page; false where the engine cannot (the host says where else to find it).
    func show(_ tool: WebDeveloperTool) -> Bool
}
