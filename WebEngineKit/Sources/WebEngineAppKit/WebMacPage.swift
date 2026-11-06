import AppKit
import WebEngineCore

/// WebKit's menu metadata, with the app's menu policy kept in the app.
@MainActor public protocol WebContextMenu: AnyObject {
    var actionTarget: AnyObject { get }
    var openLinkInNewWindowIdentifier: String { get }
    func title(for identifier: String) -> String?
    func isExtensionItem(_ item: NSMenuItem) -> Bool
}

@MainActor public protocol WebPageViewEvents: AnyObject {
    /// Installs the app's swipe, before magnification, inspection and KVO.
    /// False asks the engine to enable its own back-forward gestures.
    func prepareSwipe() -> Bool
    /// True consumes the event before the engine sees it.
    func scrollWheel(_ event: NSEvent) -> Bool
    func swipe(_ event: NSEvent) -> Bool
    /// After the engine's viewDidMoveToWindow implementation.
    func movedToWindow()
    var menus: any WebPageMenus { get }
}

/// Kept by the view. Its page recipient is weak and is cleared at teardown,
/// but menu renaming and forwarding an existing WebKit action still work.
@MainActor public protocol WebPageMenus: AnyObject {
    func willOpenMenu(_ menu: NSMenu, context: any WebContextMenu)
    func handOffLinkedFile(_ sender: NSMenuItem)
    func openLinkInPeek(_ sender: NSMenuItem)
    func detachPage()
}

/// nil leaves the engine's snapshot default untouched.
public struct WebSnapshotOptions: Sendable {
    public let rect: CGRect?
    public let width: Double?
    public let afterScreenUpdates: Bool?

    public init(rect: CGRect? = nil, afterScreenUpdates: Bool? = nil, width: Double? = nil) {
        self.rect = rect
        self.width = width
        self.afterScreenUpdates = afterScreenUpdates
    }
}

/// The engine's page and its own view, with product policy supplied by Page.
@MainActor public protocol WebMacPage: WebRequestLoading {
    var contentView: NSView { get }
    var traits: Set<WebTrait> { get }
    var swipe: (any WebSwipe)? { get }
    var coordinates: (any WebPageCoordinates)? { get }
    /// Must make the child within the call that handed over the request.
    func makePicturePage(from request: any WebChildRequest, size: CGSize) -> (any WebPicturePage)?
    var state: PageState { get }
    var isExtensionPage: Bool { get }
    var scripting: any WebPageScripting { get }
    var channels: any WebMessageChannels { get }
    var ruleListTarget: any WebRuleListTarget { get }
    var services: any WebFind & WebZoom & WebMediaCapture & WebUserAgent & WebPrinting & WebDeveloperTools & WebBackForward & WebRestoration & WebDownloadStarting { get }
    func connect(policy: any WebNavigationPolicy, navigation: any WebNavigationEvents,
                 ui: any WebPageUIEvents, presenter: any WebDialogPresenter,
                 state: any WebPageStateEvents, view: any WebPageViewEvents)
    func stopObserving()
    func goBack()
    func goForward()
    func stopLoading()
    func reload()
    func reloadFromOrigin()
    func hiddenPage(ruleLists: [any WebRuleList],
                    allows: @escaping @MainActor @Sendable (URL?) -> Bool) -> any WebHiddenPage
    func takeSnapshot(with options: WebSnapshotOptions,
                      completionHandler: @escaping @MainActor (NSImage?, (any Error)?) -> Void)
    /// Stops loading, detaches delegates and removes the view. Script and
    /// rule removal stay explicit so Page preserves its teardown order.
    func tearDown()
}

/// Engines without these capabilities keep their own gestures and make no
/// picture child. Existing hosts need not provide unsupported services.
extension WebMacPage {
    public var traits: Set<WebTrait> { [] }
    public var swipe: (any WebSwipe)? { nil }
    public var coordinates: (any WebPageCoordinates)? { nil }
    public func makePicturePage(from request: any WebChildRequest, size: CGSize) -> (any WebPicturePage)? { nil }
}
