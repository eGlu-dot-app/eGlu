import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit
import WebKitSupport

/// Owns the Mac page's WebKit objects. Every callback goes straight to the
/// app on the main actor; no task or queue is inserted between them.
@MainActor
public final class WebKitMacPage: WebMacPage {
    public static let appWorld = WKContentWorld.world(name: "eGlu")
    public let webView: WebKitPageView
    public let isExtensionPage: Bool
    public let scripting: any WebPageScripting
    public let channels: any WebMessageChannels
    public let ruleListTarget: any WebRuleListTarget
    public let services: any WebFind & WebZoom & WebMediaCapture & WebUserAgent & WebPrinting & WebDeveloperTools & WebBackForward & WebRestoration & WebDownloadStarting
    private let controller: WKUserContentController
    private var navigationAdapter: WebKitNavigationAdapter!
    private var uiAdapter: WebKitUIAdapter!
    private var extensionDelegate: (any WKUIDelegate)?
    private let extensionUIDelegate: (@MainActor (WebKitUIAdapter) -> any WKUIDelegate)?
    private weak var stateEvents: (any WebPageStateEvents)?
    private var observations: [NSKeyValueObservation] = []

    public init(configuration: WKWebViewConfiguration, extensionPage: Bool = false,
                extensionUIDelegate: (@MainActor (WebKitUIAdapter) -> any WKUIDelegate)? = nil) {
        isExtensionPage = extensionPage
        self.extensionUIDelegate = extensionUIDelegate
        let config = configuration
        let controller = extensionPage ? config.userContentController : WKUserContentController()
        config.userContentController = controller
        self.controller = controller
        ruleListTarget = WebKitRuleListTarget(controller: controller)
        channels = WebKitMessageChannels(controller: controller, appWorld: Self.appWorld)
        let view = WebKitPageView(frame: .zero, configuration: config)
        webView = view
        scripting = WebKitPageScripts(view: view, controller: controller)
        services = WebKitPageServices(view: view)
    }

    public var contentView: NSView { webView }
    public var traits: Set<WebTrait> {
        var traits: Set<WebTrait> = [.isolatedScripts, .documentPictureInPicture]
        if ["_pinnedState", "_setRubberBandingEnabled:"].allSatisfy({ webView.responds(to: NSSelectorFromString($0)) }) {
            traits.insert(.rubberBandControl)
        }
        // These two are the plugin's own answers to WebKit's private UI
        // delegate questions: they say the adapter answers them. Whether this
        // WebKit asks them cannot be asked of WebKit; it asks every macOS
        // the app runs on. An extension delegate forwards them to the same adapter.
        if WebKitUIAdapter.instancesRespond(to: NSSelectorFromString("_webView:didNotHandleWheelEvent:")) {
            traits.insert(.correlatedUnusedWheelEvents)
        }
        if WebKitUIAdapter.instancesRespond(to: NSSelectorFromString("_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:")) {
            traits.insert(.contextMenuElement)
        }
        if webView.configuration.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
            traits.insert(.videoPictureInPicture)
        }
        return traits
    }
    public var swipe: (any WebSwipe)? {
        traits.contains(.rubberBandControl) ? WebKitPageInteraction(view: webView) : nil
    }
    public var coordinates: (any WebPageCoordinates)? { WebKitPageInteraction(view: webView) }

    public func makePicturePage(from request: any WebChildRequest, size: CGSize) -> (any WebPicturePage)? {
        guard let request = request as? WebKitChildRequest else { return nil }
        return WebKitPicturePage(request: request, size: size)
    }
    public var state: PageState {
        PageState(url: webView.url, title: webView.title, isLoading: webView.isLoading,
                  estimatedProgress: webView.estimatedProgress, canGoBack: webView.canGoBack,
                  canGoForward: webView.canGoForward, hasOnlySecureContent: webView.hasOnlySecureContent)
    }

    public func connect(policy: any WebNavigationPolicy, navigation: any WebNavigationEvents,
                        ui: any WebPageUIEvents, presenter: any WebDialogPresenter,
                        state: any WebPageStateEvents, view: any WebPageViewEvents) {
        let webView = webView
        webView.events = view
        webView.menus = view.menus
        stateEvents = state
        navigationAdapter = WebKitNavigationAdapter(view: webView, policy: policy, events: navigation)
        webView.navigationDelegate = navigationAdapter
        uiAdapter = WebKitUIAdapter(view: webView, events: ui, presenter: presenter)
        if isExtensionPage, let extensionUIDelegate {
            let delegate = extensionUIDelegate(uiAdapter)
            extensionDelegate = delegate
            webView.uiDelegate = delegate
        } else {
            webView.uiDelegate = uiAdapter
        }
        if !view.prepareSwipe() { webView.allowsBackForwardNavigationGestures = true }
        webView.allowsMagnification = true
        webView.isInspectable = true
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.stateEvents?.titleOrAddressChanged() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.stateEvents?.titleOrAddressChanged() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.stateEvents?.loadingChanged() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.stateEvents?.progressChanged() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.stateEvents?.backOrForwardChanged() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.stateEvents?.backOrForwardChanged() } },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.stateEvents?.secureContentChanged() } },
        ]
    }

    public func stopObserving() {
        observations.forEach { $0.invalidate() }
        observations = []
    }

    public func takeSnapshot(with options: WebSnapshotOptions,
                             completionHandler: @escaping @MainActor (NSImage?, (any Error)?) -> Void) {
        let configuration = WKSnapshotConfiguration()
        if let rect = options.rect { configuration.rect = rect }
        if let after = options.afterScreenUpdates { configuration.afterScreenUpdates = after }
        if let width = options.width { configuration.snapshotWidth = NSNumber(value: width) }
        webView.takeSnapshot(with: configuration, completionHandler: completionHandler)
    }

    public func hiddenPage(ruleLists: [any WebRuleList],
                           allows: @escaping @MainActor @Sendable (URL?) -> Bool) -> any WebHiddenPage {
        WebKitHiddenPage(beside: webView, ruleLists: ruleLists, appWorld: Self.appWorld, allows: allows)
    }

    public func load(_ request: URLRequest) { navigationAdapter.load(request) }
    public func loadFile(_ url: URL, allowingReadAccessTo readAccessURL: URL) {
        navigationAdapter.loadFile(url, allowingReadAccessTo: readAccessURL)
    }
    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func stopLoading() { webView.stopLoading() }
    public func reload() { webView.reload() }
    public func reloadFromOrigin() { webView.reloadFromOrigin() }

    public func tearDown() {
        webView.stopLoading()
        navigationAdapter?.tearDown()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        uiAdapter?.tearDown()
        webView.events = nil
        webView.menus?.detachPage()
        webView.removeFromSuperview()
    }
}
