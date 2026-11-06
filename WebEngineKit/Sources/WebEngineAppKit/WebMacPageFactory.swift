import AppKit
import WebEngineCore

/// Where a new engine page gets its configuration.
public enum WebMacPageSource {
    case space
    case tab(URL?)
    /// Made before the call handing over the request returns.
    case child(any WebChildRequest)
    /// An extension's configuration, used as given.
    case supplied(any ExtensionPageConfiguration)
}

/// Makes engine pages; the app wraps each in its product Page.
@MainActor public protocol WebMacPageFactory: AnyObject {
    var svgRasterizer: any WebSVGRasterizer { get }
    var spaceStores: any WebSpaceStores { get }
    func ruleListStore() -> (any WebRuleListStore)?
    func makePage(space: UUID, source: WebMacPageSource) -> any WebMacPage
    func downloadStarter(space: UUID) -> any WebDownloadStarting
    func spellingFollows(writing: Bool, pages: [any WebMacPage])
}

/// A query does not start capture's runtime. Release asks for it only when
/// the page is torn down, as it did before the engine boundary.
@MainActor public struct WebExtensionPageCapture {
    private let screen: @MainActor (NSView) -> Bool
    private let releasePage: @MainActor (NSView) -> Void

    public init(screen: @escaping @MainActor (NSView) -> Bool,
                release: @escaping @MainActor (NSView) -> Void) {
        self.screen = screen
        self.releasePage = release
    }

    public func isCapturing(_ view: NSView) -> Bool { screen(view) }
    public func release(_ view: NSView) { releasePage(view) }
}
