import AppKit
import PadCore
import UniformTypeIdentifiers
import WebEngineAppKit
import WebEngineCore
import WebKit
import WebKitMacPlugin

/// What a page asks of whoever is showing it: a window (WindowModel), a
/// Peek over a tab (PeekPage), a little window (LittleWindow) or a sign-in
/// pop-up (Popup).
@MainActor
protocol PageHost: AnyObject {
    /// "Handoff Linked File" from a link's menu; a no-op for a host
    /// without Handoff, whose menus never show the item (takesHandoffFiles).
    func page(_ page: Page, handOffFileAt url: URL)
    /// Whether the page's menus may offer file handoffs at all.
    var takesHandoffFiles: Bool { get }

    func pageDidChange(_ page: Page)
    func isShowing(_ page: Page) -> Bool
    /// A window the page opened (window.open, a link to a new window). The
    /// returned page must be made from `request`, before this call returns,
    /// for the new page to keep its tie to the one that opened it. nil rejects it.
    func page(_ page: Page, openChild request: any WebChildRequest) -> Page?
    /// A ⌘-click's address, for a tab of its own (NewTabClick); false where
    /// there are no tabs, and the page goes there itself.
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool
    func pageDidClose(_ page: Page)
    /// The window to put an alert or a sheet on.
    var hostWindow: NSWindow? { get }
}

/// A page's web view: WebKit's, with its menu saying "Tab" where WebKit's says
/// "Window", since a page asking for a window gets a tab here as in Safari.
extension PageHost {
    func page(_ page: Page, handOffFileAt url: URL) {}
    var takesHandoffFiles: Bool { false }
}

final class PageView: WKWebView {
    weak var page: Page?

    private static let renamed: [String: String] = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": String(localized: "Open Link in New Tab"),
        "WKMenuItemIdentifierOpenImageInNewWindow": String(localized: "Open Image in New Tab"),
        "WKMenuItemIdentifierOpenMediaInNewWindow": String(localized: "Open Video in New Tab"),
        "WKMenuItemIdentifierOpenFrameInNewWindow": String(localized: "Open Frame in New Tab"),
    ]

    /// One of WebKit's items for an extension: its own class, the one
    /// mark WebKit gives them.
    static func isExtensionItem(_ item: NSMenuItem) -> Bool {
        NSStringFromClass(type(of: item)) == "_WKWebExtensionMenuItem"
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items {
            if let id = item.identifier?.rawValue, let title = Self.renamed[id] { item.title = title }
        }
        // Open Link in Peek, after Open Link in New Tab, on a page in a
        // window's tab: WebKit's own item for the link under the pointer,
        // with the window it opens made a Peek (Page.peekAsked).
        if let page, page.canPeek, !page.isHandsOff,
           let newTab = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            let item = NSMenuItem(title: String(localized: "Open Link in Peek"), action: #selector(openLinkInPeek(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = newTab
            menu.insertItem(item, at: menu.index(of: newTab) + 1)
            // Handoff Linked File, after it, for a link to a file eGlu
            // reads, where the window's Handoff is on (takesHandoffFiles).
            // The link's address comes from the context menu's own element
            // (Page.linkForMenu): WebKit's items carry none.
            if let link = page.linkForMenu, DocumentSource.linkExtensions.contains(link.pathExtension.lowercased()),
               page.host?.takesHandoffFiles == true, !page.isHandsOff {
                let off = NSMenuItem(title: String(localized: "Handoff Linked File"),
                                     action: #selector(handOffLinkedFile(_:)), keyEquivalent: "")
                off.target = self
                off.representedObject = link
                menu.insertItem(off, at: menu.index(of: item) + 1)
            }
        }
        // WebKit puts the extensions' own items (contextMenus) in itself,
        // after the page's; on Google's sign-in they are taken out, with
        // the line WebKit drew above them.
        if page?.isHandsOff == true {
            for item in menu.items.reversed() where Self.isExtensionItem(item) {
                let index = menu.index(of: item)
                menu.removeItem(item)
                if index > 0, menu.items[index - 1].isSeparatorItem,
                   index == menu.items.count || menu.items[index].isSeparatorItem {
                    menu.removeItem(at: index - 1)
                }
            }
        }
        super.willOpenMenu(menu, with: event)
    }

    @objc private func handOffLinkedFile(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? URL, let page else { return }
        page.host?.page(page, handOffFileAt: link)
    }

    @objc private func openLinkInPeek(_ sender: NSMenuItem) {
        guard let newTab = sender.representedObject as? NSMenuItem, let action = newTab.action else { return }
        page?.peekAsked = Date()
        NSApp.sendAction(action, to: newTab.target, from: newTab)
    }

    /// Two fingers on the trackpad: the swipe back and forward's first
    /// (PageSwipe), and the page's whatever the swipe doesn't take.
    override func scrollWheel(with event: NSEvent) {
        if page?.swipe?.scrolled(event) == true { return }
        super.scrollWheel(with: event)
    }

    /// Three fingers sideways, where System Settings has those swipe between pages.
    override func swipe(with event: NSEvent) {
        if page?.swipe?.swiped(event) == true { return }
        super.swipe(with: event)
    }

    /// Off the screen (another tab shown, another window's), or onto it: a
    /// swipe under way is called off, its arrow with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        page?.swipe?.callOff()
        if window == nil, let page { ApplePasswordsCard.shared.left(page) }
    }
}

/// One tab's page while it is live: its web view, the content blocker's
/// lists and scripts it gets, and everything WebKit tells it.
///
/// On a Mac the trackpad, the mouse and every ⌘ key reach the page as they
/// do in Safari, so none of the iPad's bridges (bridge.js) go into a page
/// here. This is still the only place the app calls into a page or changes
/// what goes into one, and every such call first asks HandsOff whether it
/// may (PolicyTests keeps it that way).
@MainActor
final class Page: NSObject {
    /// The app's own content world: what it asks a page lives here, out of the page's sight.
    static let world = WKContentWorld.world(name: "eGlu")

    let tab: UUID
    let space: UUID
    let view: PageView
    /// The same view, for hosts to place, move and give the keys.
    private(set) lazy var surface: any WebEngineSurface = PageWebKitSurface(view: view)
    private var navigationAdapter: WebKitNavigationAdapter!
    private var uiAdapter: WebKitUIAdapter!
    private let channels: any WebMessageChannels
    private let services: any WebFind & WebZoom & WebMediaCapture & WebUserAgent & WebPrinting & WebDeveloperTools
    private let controller: WKUserContentController
    weak var host: PageHost?

    /// What WebKit reports now, without the tab's replacement history.
    var state: PageState {
        PageState(url: view.url, title: view.title, isLoading: view.isLoading,
                  estimatedProgress: view.estimatedProgress, canGoBack: view.canGoBack,
                  canGoForward: view.canGoForward, hasOnlySecureContent: view.hasOnlySecureContent)
    }

    var pageZoom: Double { services.pageZoom }
    var magnification: Double { services.magnification }

    func showDeveloperTool(_ tool: WebDeveloperTool) -> Bool { services.show(tool) }

    /// Whether Back can use the page's history or the page it replaced.
    var canGoBack: Bool {
        view.canGoBack || Session.shared.canGoBackPastReplacement(tab)
    }

    /// The site's adapter, for what its own reader can add to a handoff (a
    /// video's transcript) and how heavy its pages are; none of its bridges.
    private(set) var adapter = Adapters.standard
    /// The scripts installed for the next document: the scripted filters'
    /// stamp, `handsOffScripts`, or nil before the first page.
    private var installed: String?
    /// The address the scripts were last chosen for, chosen again once the
    /// response says what kind of document it is.
    private var preparedFor: URL?
    private static let handsOffScripts = "hands-off"
    /// The content blocker's lists on this page, by identifier: none on a
    /// hands-off page, or where Settings or the site's switch turns it off.
    private var blocking = PageBlocking()
    private(set) var committed: URL?
    private(set) var mimeType: String?
    /// A PDF read as a document for a handoff (PageShared.readingForHandoff).
    var handoffDocument: DocumentSource?
    /// Writing's card is open on this page: ⌃⌥G takes its first suggestion
    /// then (Command.acceptWritingSuggestion, WritingHandler's card messages).
    /// The window hears of the change, for the menu's item to follow it.
    var writingCardOpen = false {
        didSet { if writingCardOpen != oldValue { host?.pageDidChange(self) } }
    }
    /// The main frame's HTTP status, for the developer bar; nil before the
    /// first answer, for a file or data page, or where the load failed.
    var statusCode: Int? { status.code }
    private var status = PageStatus()
    /// Why the last load failed, to show in place of the page; nil once one loads.
    private(set) var failure: String?
    private var loadState = PageLoadState()
    var displayURL: URL? { held ?? loadState.displayURL(current: view.url) }
    private(set) var refusedAppLink: URL?
    private var pendingDialog: (show: () -> Void, cancel: () -> Void)?
    var hasPendingDialog: Bool { pendingDialog != nil }

    func reviewPendingDialog() {
        guard host?.isShowing(self) == true, let pendingDialog else { return }
        guard let window = host?.hostWindow, window.attachedSheet == nil else { return }
        self.pendingDialog = nil
        pendingDialog.show()
        host?.pageDidChange(self)
    }

    private func cancelPendingDialog() {
        let old = pendingDialog
        pendingDialog = nil
        old?.cancel()
    }

    private func beginNavigation(_ url: URL?) {
        if held != nil {
            held = nil
            Extensions.shared.tabs.addressChanged(self)
        }
        cancelPendingDialog()
        loadState.begin(url)
        failure = nil
        sendingFailed = false
        googleRefused = false
        // The tool's page is going: the tool with it, overlay and all, so
        // a document the address only moves within never keeps it; and the
        // notes on its elements.
        stopMeasuring()
        measureNotes = []
        ApplePasswordsCard.shared.left(self)
    }
    /// The request under way is for a page (GET), not a form's sending: a
    /// form sent again by its address alone would lose what it sent.
    private var askingForPage = true
    /// The failure shown is a form's sending (a POST), not the page's own:
    /// the form is still there under it, filled in.
    private var sendingFailed = false
    /// The page's process kept ending; it waits for a click to load again.
    private(set) var exhausted = false
    private(set) var googleRefused = false
    private var crashes = CrashGuard()
    /// The question about a link for another app, while it is up, and how
    /// often this page has been told no (openElsewhere).
    private var askingElsewhere = false
    private var refusedElsewhere = 0
    /// The screen's light or dark, to the sites that ask for it as a header
    /// (ColorSchemeHint): for every page, and for the run only.
    private static var colorHint = ColorSchemeHint()
    /// Whether the page's last request had that header, and could be made again.
    private var hintCarried = false
    private var hintRepeatable = false
    /// A page another page opened (window.open, a link to a new window).
    private var wasOpened = false
    /// One of an extension's own pages, in a view from the extension's
    /// configuration. It stays one: a navigation to a website goes to a new
    /// tab, as one from a website to an extension's page does.
    let isExtensionPage: Bool
    private var observations: [NSKeyValueObservation] = []
    /// An extension's page's UI delegate, which the view holds weakly.
    private var extensionDelegate: ExtensionPageDelegate?
    /// Back and forward by two fingers on the trackpad; nil where WebKit's own swipe has them.
    private(set) var swipe: PageSwipe?
    /// The visit the document on screen is, in its space's history (PageHistory).
    private var history = PageHistory()

    /// The page is a tab coming back as it was (thawed, or at launch): its
    /// first document was visited already.
    func restoring() {
        history.restoring()
    }

    /// The document shows a password field (PasswordWatch): a sign-in page.
    private(set) var passwordField = false

    /// The page on screen has a password field, or no longer has
    /// (PasswordWatch): a sign-in page, whose visit history takes back and
    /// keeps nothing more of while the field is there, and which the open
    /// tabs other devices see leave out.
    func password(_ present: Bool) {
        if present { history.signInFound() } else { history.signInGone() }
        passwordField = present
    }

    /// The page over this one, while one is open (PeekPage): a pop-up it
    /// opened, or a link that left a pinned tab's site.
    private(set) var peek: PeekPage?
    /// When Open Link in Peek was chosen from the page's menu: the window
    /// WebKit opens for it, a moment later, is a Peek.
    fileprivate var peekAsked: Date?
    /// The link the context menu is on (getContextMenuFromProposedMenu),
    /// for "Handoff Linked File"; WebKit's menu items carry no address.
    fileprivate var linkForMenu: URL?

    /// The site's picture-in-picture window, while one is open (DocumentPicture, PictureWindow).
    private(set) var picture: PictureWindow?
    /// The app is calling the site's handler for leaving the tab, so a window opened now is the app's doing.
    private var enteringPicture = false
    /// A video the app put in macOS's picture in picture.
    private var videoFloated = false
    /// The page is out of sight: a late picture request goes back if it returned meanwhile.
    private var videoWanted = false
    /// The call that floats a video is on its way.
    private var floatingVideo = false
    /// Hosts given Document Picture-in-Picture besides DocumentPicture's, for
    /// a test build's own page: `-pictureHosts 127.0.0.1,localhost`. None in a release.
    private static let pictureTestHosts: [String] = {
        #if DEBUG
        (UserDefaults.standard.string(forKey: "pictureHosts") ?? "").split(separator: ",").map(String.init)
        #else
        []
        #endif
    }()

    /// `configuration`: supplied by the page engine. A page gets a script
    /// controller of its own unless it is an extension's page, so scripts
    /// swapped for one page never touch another's.
    init(tab: UUID, space: UUID, configuration: WKWebViewConfiguration, extensionPage: Bool = false) {
        self.tab = tab
        self.space = space
        isExtensionPage = extensionPage
        let config = configuration
        // An extension's page keeps the controller WebKit made for it.
        let controller = extensionPage ? config.userContentController : WKUserContentController()
        config.userContentController = controller
        self.controller = controller
        channels = WebKitMessageChannels(controller: controller, appWorld: Page.world)
        let view = PageView(frame: .zero, configuration: config)
        self.view = view
        services = WebKitPageServices(view: view)
        super.init()
        view.page = self
        navigationAdapter = WebKitNavigationAdapter(view: view, policy: self, events: self)
        view.navigationDelegate = navigationAdapter
        uiAdapter = WebKitUIAdapter(view: view, events: self, presenter: self)
        // An extension's page has WebKit's question about recording the
        // screen answered by eGlu's recording channel (ExtensionCapture).
        if extensionPage {
            let delegate = ExtensionPageDelegate(next: uiAdapter)
            extensionDelegate = delegate
            view.uiDelegate = delegate
        } else {
            view.uiDelegate = uiAdapter
        }
        setUp()
    }

    private func setUp() {
        // A two-finger swipe goes back and forward, after a shorter way than
        // WebKit's own swipe goes (PageSwipe); WebKit's where this macOS lacks
        // what that asks of it. A pinch zooms, as in Safari.
        if PageSwipe.works(on: view) {
            swipe = PageSwipe(view: view)
        } else {
            view.allowsBackForwardNavigationGestures = true
        }
        view.allowsMagnification = true
        view.isInspectable = true
        observations = [
            view.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            view.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            // How a load is going is the window's to show and not the workspace's to keep.
            view.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progressed()
                    Extensions.shared.tabs.loadingChanged(self)
                }
            },
            view.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressed() } },
            view.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.wentSomewhere() } },
            view.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.wentSomewhere() } },
            view.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressed() } },
        ]
        // The Chrome Web Store's button asks through this, from the app's
        // own world (StoreButton).
        if !isExtensionPage {
            channels.open(StoreButton.name, in: .app) { [store = StoreButton(page: self)] in store.received($0) }
            // A password field on the page, for history (PasswordWatch).
            channels.open(PasswordWatch.name, in: .app) { [watch = PasswordWatch(page: self)] in watch.received($0) }
            // Grammar checking's questions to the Mac, from the app's own
            // world (WritingHandler, writing.js).
            channels.open(WritingHandler.name, in: .app) { [writing = WritingHandler(page: self)] in writing.handle($0, reply: $1) }
            // The measuring tool's word from the page (MeasureChannel).
            channels.open(MeasureChannel.name, in: .app) { [tool = MeasureChannel(page: self)] in tool.received($0) }
            // Apple Passwords under the sign-in box, only in a build that
            // may run Apple's helper (ApplePasswords).
            if ApplePasswords.entitled {
                channels.open(ApplePasswordsForm.name, in: .app) { [apple = ApplePasswordsHandler(page: self)] in apple.received($0) }
            }
        }
    }

    /// Where the page is, or what it is called, is another: kept, and shown.
    private func changed() {
        Session.shared.pages.navigationChanged(self)
        if let url = view.url {
            Session.shared.record(tab, url: url, title: view.title)
        }
        history.changed(url: view.url, title: view.title, entry: view.backForwardList.currentItem,
                        loading: view.isLoading, space: space, tab: tab)
        host?.pageDidChange(self)
    }

    private func progressed() {
        host?.pageDidChange(self)
    }

    /// There is a page to go back to, or forward to, or no longer: the swipe hears (PageSwipe.wentSomewhere).
    private func wentSomewhere() {
        swipe?.wentSomewhere()
        progressed()
    }

    /// Lets the page go: the view out of its window, its scripts gone.
    /// WebKit ends the page's process once nothing holds the view.
    func tearDown() {
        // The tool's run holds the view until it ends: it ends first.
        stopMeasuring()
        cancelPendingDialog()
        ApplePasswordsCard.shared.left(self)
        picture?.close()
        peek?.close()
        observations.forEach { $0.invalidate() }
        observations = []
        swipe?.stop()
        swipe = nil
        controller.removeAllUserScripts()
        blocking.remove(from: controller)
        if isExtensionPage { ExtensionCapture.shared.release(view) }
        view.stopLoading()
        navigationAdapter.tearDown()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        uiAdapter.tearDown()
        view.page = nil
        view.removeFromSuperview()
        host = nil
    }

    // MARK: Loading

    /// Back in WebKit, or past a replaced page when its history is empty.
    func goBack() {
        if !view.canGoBack, Session.shared.wentBackPastReplacement(tab) { return }
        view.goBack()
    }

    /// Forward in the page's own history.
    func goForward() {
        view.goForward()
    }

    /// Stop the load under way.
    func stopLoading() {
        view.stopLoading()
    }

    /// Reload from origin without the page's retry or crash reset.
    func reloadFromOrigin() {
        view.reloadFromOrigin()
    }

    func load(_ url: URL) {
        beginNavigation(url)
        exhausted = false
        askedHere = url
        request(url)
    }

    /// An address eGlu itself loads here (typed, a link from another app),
    /// which may be an extension's page; a website's own navigation to one
    /// is held to what the extension shows websites (opensExtensionPage).
    private var askedHere: URL?
    /// Where this page's load is coming from, as WebKit reports it: the
    /// address it started at, then each server redirect's. A redirect to an
    /// extension's page is checked against the site that sent it, since the
    /// frame that asked may be a blank tab's.
    private var loadingFrom: URL?

    /// Whether a navigation of this website's to an extension's page may
    /// go: one eGlu asked for here, or one the extension shows the https
    /// site that sent it (web_accessible_resources), as Chrome. Any other
    /// is refused: no website opens a password manager's vault. (Search)
    private func opensExtensionPage(_ url: URL, for action: WebNavigation) -> Bool {
        if let asked = askedHere, asked == url { askedHere = nil; return true }
        guard let source = Self.site(sending: action, loadingFrom: loadingFrom, to: url) else { return false }
        return Extensions.shared.webAccessible(url, from: source, in: space)
    }

    /// The https site a navigation to `url` comes from: for a server
    /// redirect, the site that redirected (a sign-in site sending its
    /// answer back to the extension); otherwise the frame that asked. WebKit
    /// says which only privately (_isRedirect), asked first; without it,
    /// the frame, and a redirect from a blank tab reads as the site that
    /// redirected. nil for anything else.
    static func site(sending action: WebNavigation, loadingFrom: URL?, to url: URL) -> URL? {
        let frame: URL? = {
            guard case let .tuple(scheme, host, port) = action.sourceOrigin,
                  scheme.lowercased() == "https", !host.isEmpty else { return nil }
            var parts = URLComponents()
            parts.scheme = "https"
            parts.host = host
            if port > 0 { parts.port = port }
            parts.path = "/"
            return parts.url
        }()
        let redirecting = loadingFrom.flatMap { $0.scheme?.lowercased() == "https" && $0 != url ? $0 : nil }
        return action.isServerRedirect ? redirecting : frame ?? redirecting
    }

    /// The tab whose page opened this one, for a Peek's or a pop-up's page.
    var openedFrom: UUID?

    /// An address the tab shows without loading it (ExtensionAuth.handOver),
    /// until it goes somewhere else.
    private(set) var held: URL?

    /// Holds `url` as the tab's address; left there four seconds, it says
    /// what Chrome's error page would. Only the page and the extensions
    /// see it: what it carries, a code or a token, isn't written into the
    /// workspace, where it would be saved and synced.
    func hold(_ url: URL) {
        held = url
        Extensions.shared.tabs.addressChanged(self)
        host?.pageDidChange(self)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.held == url else { return }
            self.failure = String(localized: "No site at that address.")
            self.host?.pageDidChange(self)
        }
    }

    // MARK: Apple Passwords (ApplePasswords)

    /// An account from the Passwords app, into the sign-in box the caret
    /// was in, only if the page is still the host it was asked for; never
    /// on a hands-off page.
    func fillApplePassword(host: String, user: String, password: String) async {
        guard !isHandsOff else { return }
        _ = try? await view.callAsyncJavaScript("return globalThis.__egluApplePasswordsFill ? globalThis.__egluApplePasswordsFill(host, user, password) : false;",
                                                arguments: ["host": host, "user": user, "password": password], in: nil, contentWorld: Page.world)
    }

    // MARK: An extension's own page, for its recording (ExtensionCapture)

    /// Whether an extension's own page is seen, as WebKit counts it; never
    /// asked of a website's.
    static func extensionPageVisible(_ web: WKWebView) async -> Bool {
        guard web.url?.scheme?.lowercased() == Extensions.scheme else { return false }
        return (try? await web.evaluateJavaScript("document.visibilityState")) as? String == "visible"
    }

    /// The shim's recording call in an extension's own page, made by the
    /// app so WebKit counts it as a click (ExtensionCapture.force); never in
    /// a website's.
    static func startExtensionRecording(in web: WKWebView, token: String, video: Any) async throws -> Any? {
        guard web.url?.scheme?.lowercased() == Extensions.scheme else { return nil }
        return try await web.callAsyncJavaScript("return await globalThis[Symbol.for('eglu.capture')](token, video);",
                                                 arguments: ["token": token, "video": video], in: nil, contentWorld: .page)
    }

    /// The http or https site this page was last asked to go to: what an
    /// extension's rule redirect is checked against, since WebKit starts
    /// it with nothing behind it to name the site.
    private var goingTo: URL?

    /// An http or https address's site, as a web_accessible_resources
    /// check reads one.
    static func site(of url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        parts.path = "/"
        return parts.url
    }

    /// An extension's page in this one's place in its tab, made from the
    /// extension's configuration, as WebKit needs; a Peek's or a little
    /// window's, which no tab keeps, opens in a new tab instead.
    private func showInstead(_ url: URL) {
        let tab = self.tab, space = self.space
        guard Session.shared.workspace.spaceID(of: tab) == space else {
            _ = host?.page(self, openInNewTab: url, inFront: true)
            return
        }
        DispatchQueue.main.async { Session.shared.replacePage(of: tab, in: space, with: url) }
    }

    /// Try Again where the page couldn't load (a Peek's, a little window's,
    /// which no tab of the workspace keeps an address for): the address that
    /// failed; for a form whose sending failed, the form again as it was,
    /// its fields still filled in, to send again, which a reload would empty;
    /// otherwise the page again.
    func retry() {
        if sendingFailed, view.url != nil {
            failure = nil
            sendingFailed = false
            host?.pageDidChange(self)
            return
        }
        reload()
    }

    /// A site by request; a file opened from Finder with leave for the page
    /// to read it, and only it, which a request for its address is refused,
    /// and readable again through its bookmark after a relaunch (FileAccess).
    private func request(_ url: URL) {
        if url.isFileURL {
            FileAccess.open(url)
            navigationAdapter.loadFile(url, allowingReadAccessTo: url)
        } else {
            navigationAdapter.load(URLRequest(url: url))
        }
    }

    /// `byHand`: asked for, so the count of endings starts over.
    func reload(byHand: Bool = true) {
        let retry = loadState.failed
        beginNavigation(retry ?? view.url)
        exhausted = false
        if byHand { crashes.reset() }
        if let retry {
            request(retry)
        } else if view.url == nil, let url = committed ?? Session.shared.workspace.tab(tab)?.url {
            request(url)
        } else {
            view.reload()
        }
        host?.pageDidChange(self)
    }

    var isHandsOff: Bool {
        HandsOff.covers(view.url) || HandsOff.covers(committed)
    }

    #if DEBUG
    /// What the store page's button says, for the command-line check.
    func storeButtonLabel() async -> String? {
        guard StoreButton.isStore(view.url) else { return nil }
        let script = "const b = document.querySelector('button[data-eglu=\"add\"]'); return b ? b.textContent.trim() + (b.disabled ? ' (off)' : '') : 'none'"
        return (try? await view.callAsyncJavaScript(script, contentWorld: Page.world)) as? String
    }

    /// A line of the test page's own script, in the page's world, for the
    /// picture test's run of Tests/picture.html (PictureTest.swift), which
    /// goes through here as every call into a page does. Never on a hands-off page.
    func pictureTestCall(_ body: String, arguments: [String: Any] = [:]) async -> Any? {
        guard !isHandsOff else { return nil }
        return try? await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }
    #endif

    /// The Chrome Web Store page's button told what is installed and what
    /// is on its way (StoreButton), in the app's own world; only there.
    func tellStore(_ state: String) {
        guard !isHandsOff, StoreButton.isStore(view.url) else { return }
        view.evaluateJavaScript("window.__egluStore && window.__egluStore.state(\(state))", in: nil, in: Page.world)
    }

    var isSignIn: Bool {
        SignIn.isSignInPage(view.url)
    }

    var isHeavy: Bool {
        adapter.isHeavy(view.url)
    }

    /// Only a live page can keep these going: a call, a recording, a download,
    /// a picture-in-picture window, whose page is this one's.
    var mustStay: Bool {
        hasPendingDialog || isHandsOff || services.isCapturing
            || (isExtensionPage && ExtensionCapture.screen(view))
            || Downloads.shared.isDownloading(for: self) || picture != nil || videoFloated || floatingVideo || enteringPicture || peek != nil
    }

    /// Puts in what the page about to load at `url` gets: the content
    /// blocker's lists and the scripts for what its filters ask that WebKit's
    /// rules can't do (ScriptedFilters), and nothing at all on a hands-off
    /// host. Called before each main-frame document is made, from the
    /// navigation's policy decision, so the document starts with them.
    private func prepare(for url: URL?) {
        preparedFor = url
        let handsOff = HandsOff.covers(url)
        blocking.apply(for: url, to: controller)
        adapter = Adapters.adapter(for: url)
        let filters = blocksContent ? ContentBlocker.shared.scriptedRules(for: url) : PageRules()
        let store = StoreButton.isStore(url)
        let picture = Self.offersPicture(url)
        let json = Session.shared.preferences.formatJSON && DeveloperMode.isJSON(mimeType: mimeType)
        let writing = checksWriting(on: url)
        // A website an extension on in the space lists reaches it as
        // chrome.runtime (ExtensionExternal).
        let external = isExtensionPage ? nil : ExtensionExternal.script(listings: Extensions.shared.externalListings(in: space))
        // The sign-in boxes, for Apple Passwords (ApplePasswordsForm).
        let apple = !isExtensionPage && ApplePasswords.serves(url)
        let wanted = handsOff ? Self.handsOffScripts
            : (filters.isEmpty ? "" : filters.stamp) + (store ? "+store" : "") + (picture ? "|picture" : "")
            + (writing ? Self.writingStamp : "") + (json ? "|json" : "") + (external.map { "|external\($0.hashValue)" } ?? "")
            + (apple ? "|apple" : "")
        guard wanted != installed else { return }
        installed = wanted
        controller.removeAllUserScripts()
        guard !handsOff else { return }
        if !isExtensionPage {
            controller.addUserScript(WKUserScript(source: Self.bridged(PasswordWatch.script, using: channels), injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Page.world))
            // English typed here is checked by Harper on this Mac, where
            // Settings › Writing is on and the site isn't off (writing.js).
            // Its strings are the String Catalog's, written in as data.
            if writing {
                controller.addUserScript(WKUserScript(source: writingScript,
                                                      injectionTime: .atDocumentEnd,
                                                      forMainFrameOnly: true, in: Page.world))
            }
        }
        // Document Picture-in-Picture, in the page's own world before its
        // scripts look for it, on the sites given it.
        if picture {
            controller.addUserScript(WKUserScript(source: Scripts.picture, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
        if apple {
            controller.addUserScript(WKUserScript(source: Self.bridged(ApplePasswordsForm.script, using: channels), injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Page.world))
        }
        // In the page's own world, where WebKit's browser is, before the
        // page's scripts look for chrome. The page's own frame only: a
        // frame inside it can be Google's sign-in, which nothing of eGlu's
        // touches (HandsOff), and a user script can't be kept from one frame.
        if let external {
            controller.addUserScript(WKUserScript(source: external, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
        controller.addFilterScripts(for: filters)
        if store {
            controller.addUserScript(WKUserScript(source: Self.bridged(Scripts.extensionStore, using: channels), injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Page.world))
        }
        // The JSON view, while Settings formats JSON and the response's type
        // says the document is (the stamp's |json re-prepares where the
        // answer only comes with the response).
        if json {
            controller.addUserScript(WKUserScript(source: Scripts.jsonView, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Page.world))
        }
    }

    /// Whether English in this page's fields is checked: Settings › Writing
    /// on, this site not one it is off for (the never-checked sites in
    /// WritingSites always count as off), a document text is typed in (not
    /// a PDF or a picture) and not an extension's own page.
    func checksWriting(on url: URL? = nil) -> Bool {
        let page = url ?? committed ?? view.url
        let typedIn = mimeType.map { $0 != "application/pdf" && !$0.hasPrefix("image/") } ?? true
        return Session.shared.preferences.writing && !isExtensionPage && typedIn
            && !WritingSites.isOff(page, sites: Session.shared.preferences.writingOffSites)
    }

    /// What `installed` holds while writing.js is among the scripts.
    private static let writingStamp = "~writing"

    /// writing.js with the card's words and the Mac's key for its first
    /// suggestion (Edit › Accept Writing Suggestion).
    private static let writingSource = WritingScript.source(acceptKey: "⌃⌥G", acceptShortcut: "Control+Alt+G")
    private var writingScript: String { Self.bridged(Self.writingSource, using: channels) }

    private static func bridged(_ script: String, using channels: any WebMessageChannels) -> String {
        channels.bridgeScript + "\n" + script
    }

    /// ⌃⌥G takes the open card's first suggestion: the fix goes in the way
    /// the page's own Undo takes back (writing.js apply()).
    func writingAcceptFirst() async -> Bool {
        guard checksWriting(), !isHandsOff else { return false }
        let accepted = try? await view.callAsyncJavaScript(
            "return window.__egluWriting ? window.__egluWriting.acceptFirst() : false",
            contentWorld: Page.world)
        return accepted as? Bool == true
    }

    /// Writing's script is told to leave: its style, hosts, mirror and
    /// listeners go with it. Only ever in the app's own world, never a
    /// hands-off page.
    private func writingStop() {
        guard !isHandsOff else { return }
        view.callAsyncJavaScript(
            "window.__egluWriting && window.__egluWriting.stop(); return true;",
            arguments: [:], in: nil, in: Page.world) { _ in }
    }

    /// Writing's script put into the document that is up, for checking
    /// turned on while it was open: user scripts reach only the next one.
    /// One already there, stopped, starts again instead.
    private func writingStart() {
        guard !isHandsOff else { return }
        view.callAsyncJavaScript(writingScript, arguments: [:], in: nil, in: Page.world) { _ in }
    }

    /// Whether the page on screen has ads and trackers blocked, for its menu.
    var blocksContent: Bool {
        blocking.isOn
    }

    /// The content blocker has new lists: this page's next load has them.
    func blockingChanged() {
        blocking.apply(for: committed ?? view.url, to: controller)
    }

    /// After Settings changed: from the next page. Writing, turned off here
    /// (or this site turned off), leaves the page that is up at once;
    /// turned on, it comes into it at once, so the field being typed in is
    /// checked without a reload.
    /// Apple Passwords turned on in Settings: the document shown now gets
    /// the sign-in box script, as its next load would.
    func applePasswordsTurnedOn() {
        let had = installed?.contains("|apple") == true
        prepare(for: committed ?? view.url)
        guard !had, installed?.contains("|apple") == true, !isHandsOff, !HandsOff.covers(view.url), !isExtensionPage else { return }
        view.evaluateJavaScript(Self.bridged(ApplePasswordsForm.script, using: channels), in: nil, in: Page.world) { _ in }
    }

    func settingsChanged() {
        let wasWriting = installed?.contains(Self.writingStamp) == true
        prepare(for: committed ?? view.url)
        let writing = installed?.contains(Self.writingStamp) == true
        if wasWriting, !writing { writingStop() }
        if writing, !wasWriting { writingStart() }
    }

    /// Whether a navigation is a ⌘-click (or ⌘⇧, or a middle click) to open
    /// in a new tab (NewTabClick), from the keys and the button WebKit says made it.
    private func newTabChoice(for action: WebNavigation) -> NewTabClick.Choice {
        let kind: NewTabClick.Kind
        switch action.kind {
        case .link: kind = .link
        case .form: kind = .form
        case .other: kind = .script
        default: kind = .history
        }
        return NewTabClick.choice(kind: kind, command: action.modifiers.contains(.command),
                                  shift: action.modifiers.contains(.shift), middleButton: action.buttonNumber == 2,
                                  method: action.request.httpMethod, scheme: action.request.url?.scheme,
                                  mainFrame: action.targetIsMainFrame ?? true)
    }

    // MARK: Find, zoom, print

    /// The next place the words are on the page, after the selection or
    /// before it; `found` hears whether there is one.
    func find(_ text: String, backwards: Bool = false, found: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !text.isEmpty else { return found(false) }
        services.find(text, backwards: backwards, caseSensitive: false, wraps: true, found: found)
    }

    /// Safari's steps of zoom, from half to three times.
    private static let zooms: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    /// As far as a zoom typed in goes: Safari's steps' ends.
    static let zoomRange = 0.5...3.0

    /// The next of Safari's steps up or down, or actual size for 0; false
    /// at either end, where there is none.
    @discardableResult
    func zoom(by step: Int) -> Bool {
        guard step != 0 else {
            setZoom(1)
            return true
        }
        // Sizes are whole percents (setZoom), so a margin well under one
        // takes a typed 99% up to 100% and 299% up to 300%.
        let now = CGFloat(services.pageZoom)
        let next = step > 0 ? Self.zooms.first { $0 > now + 0.001 } : Self.zooms.last { $0 < now - 0.001 }
        guard let next else { return false }
        setZoom(Double(next))
        return true
    }

    /// Any zoom within Safari's, as a size typed in asks, to the whole percent the field shows.
    func setZoom(_ zoom: Double) {
        let zoom = min(max((zoom * 100).rounded() / 100, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        services.pageZoom = zoom
        host?.pageDidChange(self)
    }

    func print() {
        guard let window = host?.hostWindow else { return }
        services.printOperation(with: NSPrintInfo.shared).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Calls into the page

    /// Whether letting the page go could lose a draft. The read-only probe
    /// needs no input bridge. An unavailable result is unsafe to release.
    func holdsTyping(_ done: @escaping (Bool?) -> Void) {
        guard !isHandsOff, let installed, installed != Self.handsOffScripts else {
            done(nil)
            return
        }
        view.callAsyncJavaScript(Scripts.draftCall,
                                 arguments: ["handsOff": HandsOff.hosts], in: nil, in: Page.world) { result in
            if case .success(let value) = result { done(value as? Bool) } else { done(nil) }
        }
    }

    /// Bounded rendered text for an extension's authorized language request.
    /// The tab adapter separately owns its per-space and website-grant checks.
    func extensionLanguageText() async throws -> String? {
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed), let url = view.url else { return nil }
        let value = try await view.callAsyncJavaScript(ExtensionLanguage.sampleText,
            arguments: ["limit": ExtensionLanguage.maximumScalars, "expectedURL": url.absoluteString, "protectedHosts": HandsOff.hosts],
            in: nil, contentWorld: Page.world)
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed), view.url == url else { return nil }
        return value as? String
    }

    /// The page as it looks, `pixels` wide, for Apple Intelligence's model
    /// to look at a page with too few words to go by (HandoffJob). A picture,
    /// not a script: nil when the page is not in a window.
    func picture(pixels: CGFloat) async -> CGImage? {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(pixels / max(1, view.window?.backingScaleFactor ?? 2)))
        return await withCheckedContinuation { continuation in
            view.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    // MARK: Developer mode

    /// An element picked on the page, as the inspector's: the part of the
    /// view it covers, with 16 points round it, or nil for Escape, a page
    /// with nothing to pick, and a hands-off host (element-pick.js in the
    /// app's own world; DeveloperMode.pickedRect turns its CSS pixels into
    /// the view's points, whatever the zoom or the pinch).
    func pickElement() async -> CGRect? {
        guard !isHandsOff else { return nil }
        let value = try? await view.callAsyncJavaScript(Scripts.elementPick, arguments: [:],
                                                        in: nil, contentWorld: Page.world)
        return DeveloperMode.pickedRect(value, view: view.bounds.size)
    }

    /// The part of the view in `rect` (pickElement's) as a picture.
    func picture(of rect: CGRect) async -> NSImage? {
        guard view.window != nil, !rect.isEmpty else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        return await withCheckedContinuation { continuation in
            view.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
    }

    /// Whether the response's MIME type says the document is JSON (the
    /// JSON view covers it while Settings formats: json-view.js).
    var isJSON: Bool {
        DeveloperMode.isJSON(mimeType: mimeType)
    }

    /// The measuring tool's panel state while it runs on this page
    /// (MeasureModel): non-nil is the tool being on.
    var measure: MeasureModel?
    /// Each run's number, which the script's messages carry: an earlier
    /// run's ending never takes a later one's panel.
    private var measureRuns = 0
    /// The notes on this page's elements, the tab's while the tool comes
    /// and goes; nothing about them is saved (Decided 7).
    private var measureNotes: [MeasureNote] = []

    /// The measuring tool on (⌃⌥M, the bar's Measure). Never on a
    /// hands-off host: the app never looks in there.
    func startMeasuring() {
        guard measure == nil, !isHandsOff, !isExtensionPage else { return }
        measureRuns += 1
        let model = MeasureModel(guides: MeasureGuides(preferences: Session.shared.preferences), run: measureRuns)
        model.pageURL = view.url?.absoluteString ?? ""
        model.window = { [weak self] in
            guard let view = self?.view, let services = self?.services else { return "" }
            return MeasureNotes.window(width: Double(view.frame.width), height: Double(view.frame.height),
                                       zoom: services.pageZoom)
        }
        // The tab's notes, from an earlier run on this page too.
        model.notes = measureNotes
        model.notesChanged = { [weak self] notes in self?.measureNotes = notes }
        model.apply = { [weak self] argument in
            self?.measureCall("if (window.__egluMeasure) window.__egluMeasure.settings(guides);", ["guides": argument])
        }
        model.pickColour = { [weak self] in self?.pickColour() }
        model.end = { [weak self] in self?.stopMeasuring() }
        model.pin = { [weak self] id, ref, number in self?.pinNote(id: id.uuidString, ref: ref, number: number) }
        model.unpin = { [weak self] id in self?.unpinNote(id: id.uuidString) }
        measure = model
        host?.pageDidChange(self)
        let view = view
        let channels = channels
        Task { [weak self] in
            // The tool ends its own way (Escape, the page put away): the
            // promise resolves and this run's model is let go.
            // The notes' dots again, found by their elements' names.
            let notes = model.notes.map { ["id": $0.id.uuidString, "name": $0.name, "number": $0.number] as [String: Any] }
            _ = try? await view.callAsyncJavaScript(Self.bridged(Scripts.measure, using: channels), arguments: ["guides": model.argument.merging(["notes": notes]) { _, new in new }],
                                                    in: nil, contentWorld: Page.world)
            guard let self, self.measure === model else { return }
            self.measure = nil
            self.host?.pageDidChange(self)
        }
    }

    /// The measuring tool off: the page's overlay told to remove itself,
    /// which resolves the run.
    func stopMeasuring() {
        guard measure != nil else { return }
        measure = nil
        host?.pageDidChange(self)
        measureCall("if (window.__egluMeasure) window.__egluMeasure.stop();", [:])
    }

    /// Measure on or off (Command.measure).
    func toggleMeasuring() {
        measure == nil ? startMeasuring() : stopMeasuring()
    }

    /// What the tool said (MeasureChannel), this run's only: a selection's
    /// details, a distance, what shows, a tapped point, its ending.
    func measured(_ body: [String: Any]) {
        guard let model = measure, (body["run"] as? NSNumber)?.intValue == model.run else { return }
        if let details = MeasureDetails(body: body) { model.said(details) }
        if let distance = MeasureDistance(body: body) { model.said(distance) }
        switch body["kind"] as? String {
        case "shown":
            model.said(guides: body["guides"] as? Bool ?? false, rulers: body["rulers"] as? Bool ?? true,
                       xray: body["xray"] as? Bool ?? false)
        case "point": sampled(at: body)
        case "ended":
            measure = nil
        default: break
        }
        // The panel grows and shrinks with what it shows.
        host?.pageDidChange(self)
    }

    /// The tool's calls after its start: never on a hands-off host.
    private func measureCall(_ body: String, _ arguments: [String: Any]) {
        guard !isHandsOff else { return }
        view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Page.world) { _ in }
    }

    /// A colour picked from anywhere on the screen, the Mac's way:
    /// the system's own loupe (Decided 5).
    func pickColour() {
        guard let model = measure else { return }
        model.colourBusy = true
        NSColorSampler().show { color in
            let srgb = color?.usingColorSpace(.sRGB)
            let picked = srgb.map {
                MeasureColour(red: Int(($0.redComponent * 255).rounded()), green: Int(($0.greenComponent * 255).rounded()),
                              blue: Int(($0.blueComponent * 255).rounded()))
            }
            Task { @MainActor in
                model.colourBusy = false
                if let picked { model.colour = picked }
            }
        }
    }

    /// The Mac's colour comes from the loupe, never from a tap.
    private func sampled(at body: [String: Any]) {}

    /// A note's dot pinned to an element the tool has seen (measure.js's
    /// `pin`), or taken away. In the notes' second part.
    func pinNote(id: String, ref: Int, number: Int) {
        measureCall("if (window.__egluMeasure) window.__egluMeasure.pin(id, ref, number);",
                    ["id": id, "ref": ref, "number": number])
    }

    func unpinNote(id: String) {
        measureCall("if (window.__egluMeasure) window.__egluMeasure.unpin(id);", ["id": id])
    }

    /// The JSON view over the page, from the script's own say
    /// (window.__egluJSON): true while it is drawn, false while Raw has put
    /// it away, nil where there is none (not JSON, over ten megabytes, a
    /// hands-off host), so no Raw to offer.
    private(set) var jsonView: Bool?

    /// The page loaded: whether it has a JSON view, and whether it is drawn.
    private func learnJSONView() {
        guard isJSON, !isHandsOff else { jsonView = nil; return }
        view.evaluateJavaScript("window.__egluJSON ? window.__egluJSON.drawn() : null", in: nil, in: Page.world) { [weak self] result in
            guard let self, case .success(let value) = result else { return }
            self.jsonView = value as? Bool
            self.changed()
        }
    }

    /// Raw or the view again: the bar's Raw, answered by the script.
    func toggleJSONView() {
        guard jsonView != nil, !isHandsOff else { return }
        view.evaluateJavaScript("window.__egluJSON ? window.__egluJSON.toggle() : null", in: nil, in: Page.world) { [weak self] result in
            guard let self, case .success(let value) = result, let shown = value as? Bool else { return }
            self.jsonView = shown
            self.changed()
        }
    }

    /// The size the bar's Size menu has the page at (Decided 9): a
    /// phone's or an iPad's, centred in the card; nil is Full. For this
    /// tab only, nothing saved.
    private(set) var deviceSize: CGSize?

    /// The page at a device's size with its user agent, then a reload.
    /// Full puts both back: WebKit's own agent, the card's whole room.
    func size(_ size: CGSize?, pad: Bool) {
        deviceSize = size
        services.customUserAgent = size == nil ? nil
            : Identity.mobileUserAgent(for: ProcessInfo.processInfo.operatingSystemVersion, pad: pad)
        changed()
        view.reload()
    }

    /// The icons the page names, best first, as bridge.js's siteIcons() has
    /// them on the iPad: the site's own icon, as browsers show it, a drawing
    /// before its largest picture; then Apple's touch icon, a square for a
    /// Home Screen; then /favicon.ico, the one every site had before <link>
    /// did. SiteIcons fetches the first that loads.
    private static let iconsCall = """
        const found = [];
        for (const link of document.querySelectorAll('link[rel][href]')) {
          const rel = String(link.rel || '').toLowerCase().split(/\\s+/);
          const touch = rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed');
          if (!touch && !rel.includes('icon')) continue;
          if (rel.includes('mask-icon')) continue;
          const href = link.href;
          if (!/^(https?:|data:image\\/)/i.test(href)) continue;
          const type = String(link.type || '').toLowerCase();
          const svg = type.includes('svg') || /^data:image\\/svg/i.test(href) || /\\.svg([?#]|$)/i.test(href);
          const sizes = String(link.getAttribute('sizes') || '').toLowerCase().split(/\\s+/);
          const size = Math.min(Math.max(0, ...sizes.map((each) => parseInt(each, 10) || 0)), 512);
          // The site's own icon first, as browsers show it: a drawing, then one
          // for any size (an .ico of several), then its largest picture, then an
          // alternate; Apple's touch icon (a square for a Home Screen) after them,
          // and a speck under 32 pixels after that.
          let score;
          if (touch) score = 1000 + size;
          else if (svg) score = 3000;
          else if (sizes.includes('any')) score = 2600;
          else if (size && size < 32) score = 500 + size;
          else score = (rel.includes('alternate') ? 1500 : 2000) + size;
          // One for a dark screen, or for another kind of screen, after the rest:
          // the icon kept is the one for a light screen.
          const media = String(link.media || '').toLowerCase();
          const scheme = /prefers-color-scheme/.test(media);
          if ((scheme && /prefers-color-scheme:\\s*dark/.test(media)) || (media && !scheme && !window.matchMedia(media).matches)) {
            score -= 2900;
          }
          found.push({ href, score });
        }
        found.sort((a, b) => b.score - a.score);
        const urls = found.map((icon) => icon.href);
        if (/^https?:$/.test(location.protocol)) urls.push(location.origin + '/favicon.ico');
        return Array.from(new Set(urls)).slice(0, 6);
        """

    /// Asks the page for its icons once it has loaded, unless SiteIcons has
    /// the site's already. Never on a hands-off host.
    private func learnIcons() {
        guard let url = view.url, ["http", "https"].contains(url.scheme ?? ""), !HandsOff.covers(url),
              SiteIcons.shared.needs(url) else { return }
        view.callAsyncJavaScript(Self.iconsCall, arguments: [:], in: nil, in: Page.world) { result in
            guard case .success(let value) = result, let strings = value as? [String] else { return }
            SiteIcons.shared.learn(strings.compactMap(URL.init(string:)), for: url)
        }
    }

    /// What the page says it is about (its meta description), for its
    /// history to be found by; never its own text, never on a hands-off host.
    private func learnAbout() {
        guard !isHandsOff, let origin = history.metadataOrigin, let url = view.url,
              ["http", "https"].contains(url.scheme ?? ""), !HandsOff.covers(url) else { return }
        let call = """
            const meta = document.querySelector('meta[name="description" i], meta[property="og:description" i]');
            return meta && meta.content ? String(meta.content).trim().slice(0, 400) : '';
            """
        view.callAsyncJavaScript(call, arguments: [:], in: nil, in: Page.world) { [weak self] result in
            guard let self, !self.isHandsOff, self.view.url == url, self.history.metadataOrigin == origin,
                  case .success(let value) = result, let text = value as? String else { return }
            history.described(text, url: url, space: space, origin: origin)
        }
    }

    // MARK: Another app's link

    func reviewExternalRequest() {
        guard host?.isShowing(self) == true, let url = refusedAppLink else { return }
        refusedElsewhere = 0
        openElsewhere(url, clicked: false, mainFrame: true)
    }

    fileprivate func openElsewhere(_ url: URL, clicked: Bool, mainFrame: Bool) {
        switch AppLink.answer(clicked: clicked, mainFrame: mainFrame, showing: host?.isShowing(self) == true,
                              asking: askingElsewhere, refusals: refusedElsewhere) {
        case .leave:
            if mainFrame, refusedElsewhere >= AppLink.refusalsHeard {
                refusedAppLink = url
                host?.pageDidChange(self)
            }
            closeIfOpenedForThis()
        case .open:
            hand(url)
        case .ask:
            guard let window = host?.hostWindow, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            let asker = (committed ?? view.url)?.host ?? String(localized: "This page")
            alert.messageText = String(localized: "Open in Another App?")
            let appName = NSWorkspace.shared.urlForApplication(toOpen: url)
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? $0.deletingPathExtension().lastPathComponent }
                ?? AppLink.applicationName(for: url.scheme) ?? String(localized: "the app registered for this link")
            alert.informativeText = String(localized: "\(asker) wants to open \(appName).") + "\n" + String(localized: "Link type: \(url.scheme ?? String(localized: "unknown"))")
            alert.addButton(withTitle: String(localized: "Open"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            askingElsewhere = true
            alert.beginSheetModal(for: window) { [weak self] answer in
                guard let self else { return }
                askingElsewhere = false
                if answer == .alertFirstButtonReturn {
                    hand(url)
                } else {
                    refusedElsewhere += 1
                    refusedAppLink = url
                    host?.pageDidChange(self)
                    closeIfOpenedForThis()
                }
            }
        }
    }

    /// To whichever app opens it.
    private func hand(_ url: URL) {
        refusedAppLink = nil
        host?.pageDidChange(self)
        guard NSWorkspace.shared.open(url) else {
            failure = String(localized: "No app on this Mac opens this link. Install its app or return to the website.")
            host?.pageDidChange(self)
            return
        }
        closeIfOpenedForThis()
    }

    /// A window a page opened only to go to another app has nothing to
    /// show, and goes, as one that closed itself would.
    private func closeIfOpenedForThis() {
        guard wasOpened, committed == nil else { return }
        host?.pageDidClose(self)
    }

    // MARK: Peek

    /// Whether a window this page opens can be a Peek over it: a page in a
    /// window's tab, not one in a Peek, a little window or a pop-up itself.
    var canPeek: Bool {
        host is WindowModel
    }

    /// A Peek over the page, in place of the one open. `child`:
    /// the request for a window the page opened, which the engine loads itself;
    /// nil for a link, loaded here.
    @discardableResult
    func openPeek(_ url: URL?, child: (any WebChildRequest)? = nil, width: Double? = nil,
                  height: Double? = nil) -> PeekPage {
        peek?.close()
        let made = PeekPage(opener: self, child: child, url: url, width: width, height: height)
        peek = made
        if child != nil {
            made.page.wasOpened = true
        } else if let url {
            made.page.load(url)
        }
        host?.pageDidChange(self)
        return made
    }

    /// The page is a tab's now, as it was: a Peek's or a little window's,
    /// opened in a tab. What it shows goes into the space's history.
    func becameTab() {
        history.adopted(url: view.url, title: view.title, entry: view.backForwardList.currentItem, space: space, tab: tab)
    }

    /// The Peek is gone, closed or given a tab. The tab may freeze now.
    func peekDidEnd(_ ended: PeekPage) {
        guard peek === ended else { return }
        peek = nil
        host?.pageDidChange(self)
        Task { @MainActor in Session.shared.pages.enforce() }
    }

    /// Whether a navigation leaves a pinned tab's site, for a Peek over the
    /// tab (Peek.opensFromPinned), as Arc keeps a pinned tab on its own site.
    private func peeksFromPinned(_ action: WebNavigation) -> Bool {
        let session = Session.shared
        guard canPeek, session.preferences.peekFromPinnedTabs, session.workspace.tab(tab)?.isPinned == true,
              host?.isShowing(self) == true else { return false }
        let kind: NewTabClick.Kind
        switch action.kind {
        case .link: kind = .link
        case .form: kind = .form
        case .other: kind = .script
        default: kind = .history
        }
        return Peek.opensFromPinned(from: committed ?? view.url, to: action.request.url, kind: kind,
                                    method: action.request.httpMethod, mainFrame: action.targetIsMainFrame ?? true)
    }

    // MARK: Picture in picture

    /// Whether the page at `url` is given Document Picture-in-Picture (DocumentPicture).
    static func offersPicture(_ url: URL?) -> Bool {
        DocumentPicture.covers(url, extra: pictureTestHosts)
    }

    /// The window picture.js asked for, in place of the one open: one at a time, as in Chrome.
    private func openPicture(_ child: WebKitChildRequest,
                             request: DocumentPicture.Request) -> any WebEngineSurface {
        picture?.close()
        let window = PictureWindow(opener: self, configuration: child.configuration, features: child.features, request: request)
        window.automatic = enteringPicture
        picture = window
        return PageWebKitSurface(view: window.view)
    }

    /// The window is gone, however it went. The tab may freeze now, once
    /// whatever closed the window (a tab closing, the freezer) is done.
    func pictureDidClose(_ window: PictureWindow) {
        guard picture === window else { return }
        picture = nil
        Task { @MainActor in Session.shared.pages.enforce() }
    }

    /// A tab or space switch left the page out of sight.
    func leftScreen() {
        ApplePasswordsCard.shared.left(self)
        appWentBehind()
    }

    /// The site's handler for leaving the tab, called, if it has one.
    /// `otherwise`: what to do when the site has no handler to call.
    func enterPicture(otherwise: (() -> Void)? = nil) {
        guard picture == nil, !enteringPicture, !HandsOff.covers(view.url), !HandsOff.covers(committed),
              Self.offersPicture(committed ?? view.url)
        else { return }
        enteringPicture = true
        view.callAsyncJavaScript("return typeof __egluEnterPicture === 'function' ? __egluEnterPicture() : false",
                                 arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.enteringPicture = false
            guard self.videoWanted, Session.shared.preferences.automaticPictureInPicture else {
                self.cameOnScreen()
                return
            }
            if case .success(let called) = result, called as? Bool == true { return }
            otherwise?()
        }
    }

    /// The tab is on screen again: a window the app opened for it goes, as Chrome's does.
    func cameOnScreen() {
        sinkVideo()
        if picture?.automatic == true { picture?.close() }
    }

    /// The page left the screen, or eGlu went behind another app. Prefer
    /// the site's own picture window, then a playing video with sound
    /// (any playing video in a call, whose sound may come separately).
    func appWentBehind() {
        guard Session.shared.preferences.automaticPictureInPicture,
              !HandsOff.covers(view.url), !HandsOff.covers(committed) else { return }
        videoWanted = true
        guard picture == nil, !videoFloated, !floatingVideo, !enteringPicture else { return }
        let inCall = services.isCapturing
        if Self.offersPicture(committed ?? view.url) {
            return enterPicture { [weak self] in self?.floatVideo(anyPlaying: inCall) }
        }
        floatVideo(anyPlaying: inCall)
    }

    private func floatVideo(anyPlaying: Bool) {
        guard videoWanted, !videoFloated, !floatingVideo else { return }
        floatingVideo = true
        view.callAsyncJavaScript(VideoPicture.float, arguments: ["anyPlaying": anyPlaying], in: nil, in: Page.world) { [weak self] result in
            guard let self else { return }
            self.floatingVideo = false
            guard case .success(let floated) = result, floated as? Bool == true else { return }
            self.videoFloated = true
            // eGlu came back while the video went: back it comes.
            if !self.videoWanted { self.sinkVideo() }
        }
    }

    /// eGlu is in front again, with this page on screen: what floated as it went behind comes back.
    func appCameBack() {
        cameOnScreen()
    }

    /// Restore only the video this app floated, leaving manual PiP alone.
    func sinkVideo() {
        videoWanted = false
        guard videoFloated else { return }
        videoFloated = false
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed) else { return }
        view.callAsyncJavaScript(VideoPicture.sink, arguments: [:], in: nil, in: Page.world) { _ in }
    }

    // MARK: When the page's process ends

    /// The page went blank: loaded again by itself unless it keeps ending,
    /// when it waits for Reload.
    fileprivate func processEnded() {
        picture?.close()
        videoWanted = false
        videoFloated = false
        if crashes.shouldReload(at: Date()) {
            reload(byHand: false)
        } else {
            exhausted = true
            // Its own failure, not a form's nor an earlier address's: Try Again loads it again.
            sendingFailed = false
            failure = String(localized: "This page used too much memory and was closed several times. Reload to try again.")
            host?.pageDidChange(self)
        }
    }
}

// MARK: Page UI events and dialogs

extension Page: WebPageUIEvents, WebDialogPresenter {
    func contextMenuOpening(link: URL?) {
        linkForMenu = link
    }

    func scrollNotHandled(_ event: NSEvent) {
        swipe?.leftAlone(event)
    }

    private var isDark: Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func childRequested(_ request: any WebChildRequest) -> (any WebEngineSurface)? {
        let navigation = request.navigation
        // A website's window opened on an extension's page: only a page the
        // extension shows that site, as a navigation to one is held to
        // (opensExtensionPage); checked here too, before any view is made.
        if !isExtensionPage, let url = navigation.request.url, Extensions.shared.isExtensionPage(url),
           !(Self.site(sending: navigation, loadingFrom: nil, to: url).map { Extensions.shared.webAccessible(url, from: $0, in: space) } ?? false) {
            return nil
        }
        // Another app's link asked for in a window of its own: theirs to
        // open, with no tab made for a page that will never be.
        if let url = navigation.request.url, AppLink.isOne(scheme: url.scheme), !Extensions.shared.isExtensionPage(url) {
            openElsewhere(url, clicked: navigation.kind == .link,
                          mainFrame: navigation.targetIsMainFrame ?? true)
            return nil
        }
        // picture.js's window, from the page itself and not a frame in it: it floats (PictureWindow).
        // Anywhere else, the same address is an ordinary pop-up.
        // The source can be absent; the old non-optional sourceFrame read would crash then.
        if let pictureRequest = DocumentPicture.Request(url: navigation.request.url), navigation.sourceIsMainFrame == true,
           Self.offersPicture(committed ?? view.url) {
            // Asked for on leaving the tab, but the tab is back on screen, with eGlu in front, by now: no window.
            if enteringPicture, !videoWanted || !Session.shared.preferences.automaticPictureInPicture { return nil }
            guard let request = request as? WebKitChildRequest else {
                preconditionFailure("Page.openPicture requires a WebKitChildRequest")
            }
            return openPicture(request, request: pictureRequest)
        }
        // While the app calls the site's handler for leaving the tab, the
        // click WebKit grants the call opens the site's picture window only.
        if enteringPicture { return nil }
        // Open Link in Peek, chosen from the page's menu a moment ago.
        if let asked = peekAsked {
            peekAsked = nil
            if Date().timeIntervalSince(asked) < 5, canPeek {
                return openPeek(navigation.request.url, child: request).page.surface
            }
        }
        let made = host?.page(self, openChild: request)
        if let child = made, child !== self {
            child.wasOpened = true
        }
        return made?.surface
    }

    func closeRequested() {
        host?.pageDidClose(self)
    }

    /// `frameHost`: the asking frame's host (not the page's `host`, its window).
    func alert(_ message: String, host frameHost: String, done: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = frameHost.isEmpty ? String(localized: "This page says") : String(localized: "\(frameHost) says")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert) { _ in done() }
    }

    func confirm(_ message: String, host frameHost: String, done: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frameHost.isEmpty ? String(localized: "This page asks") : String(localized: "\(frameHost) asks")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { done($0 == .alertFirstButtonReturn) }
    }

    func prompt(_ message: String, defaultText: String?, host frameHost: String,
                done: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frameHost.isEmpty ? String(localized: "This page asks") : String(localized: "\(frameHost) asks")
        alert.informativeText = message
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        present(alert) { done($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Retain one background dialog until its tab is shown or explicitly reviewed.
    private func present(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        cancelPendingDialog()
        pendingDialog = (show: { [weak self] in
            guard let window = self?.host?.hostWindow else { return done(.cancel) }
            alert.beginSheetModal(for: window, completionHandler: done)
        }, cancel: { done(.cancel) })
        host?.pageDidChange(self)
        reviewPendingDialog()
    }

    /// A page's upload field: the files chosen in the system's panel, which
    /// the sandbox then lets the page read.
    func openFiles(allowsMultiple: Bool, allowsDirectories: Bool,
                   done: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = allowsMultiple
        let completed: (NSApplication.ModalResponse) -> Void = { response in
            done(response == .OK ? panel.urls : nil)
        }
        if let window = host?.hostWindow {
            panel.beginSheetModal(for: window, completionHandler: completed)
        } else {
            completed(panel.runModal())
        }
    }
}

// MARK: Navigation events

extension Page: WebNavigationEvents {
    /// A tab that was only ever the file's way in, with no page of its own
    /// to show, goes once the download has begun, as Safari's does.
    func navigationBecameDownload(_ download: any WebEngineCore.WebDownload) {
        guard let download = (download as? WebKitDownload)?.download else {
            assertionFailure("Expected a WebKitDownload")
            return
        }
        Downloads.shared.adopt(download, from: self)
        if committed == nil, !view.canGoBack { host?.pageDidClose(self) }
    }

    func navigationStarted(url: URL?) {
        loadingFrom = url
    }

    func navigationRedirected(url: URL?) {
        loadingFrom = url
    }

    func navigationCommitted(url: URL?) {
        loadingFrom = nil
        askedHere = nil
        Session.shared.pages.navigationChanged(self, committed: true)
        cancelPendingDialog()
        loadState.commit()
        refusedAppLink = nil
        // A new document: the old one's picture-in-picture window goes with it,
        // as in Chrome, and WebKit takes the old document's video out of its own.
        picture?.close()
        videoWanted = false
        videoFloated = false
        committed = url
        status.committed(view.backForwardList.currentItem)
        googleRefused = SignIn.googleRefused(url)
        failure = nil
        sendingFailed = false
        jsonView = nil
        refusedElsewhere = 0
        history.committed(url: url, title: view.title, entry: view.backForwardList.currentItem,
                          space: space, tab: tab)
        passwordField = false
        // The old document's card went with it, unannounced.
        writingCardOpen = false
        changed()
    }

    func navigationFinished() {
        learnIcons()
        learnAbout()
        learnJSONView()
        host?.pageDidChange(self)
        #if DEBUG
        testPictureIfAsked()
        #endif
    }

    func navigationFailed(_ error: WebLoadError, provisional: Bool) {
        if provisional { loadingFrom = nil }
        guard error.kind == .other else { return }
        history.failed()
        let failedURL = error.failingURL
        if askingForPage {
            loadState.fail(failedURL)
            status.failed()
        } else {
            // A form's sending: the form is still there, filled in, and the
            // address stays its page's; Try Again goes back to it (retry).
            loadState.commit()
        }
        sendingFailed = !askingForPage
        let reason = PageLoadFailure.message(domain: error.domain, code: error.code)
        failure = loadState.failed?.host.map { "\($0): \(reason)" } ?? reason
        host?.pageDidChange(self)
        if askingForPage { ExtensionAuth.loadFailed(self) }
    }

    func contentProcessEnded() {
        processEnded()
    }
}

// MARK: Navigation policy

extension Page: WebNavigationPolicy {
    func decideNavigation(_ navigation: WebNavigation,
                          reply: @MainActor (WebNavigationDecision) -> Void) {
        let mainFrame = navigation.targetIsMainFrame ?? true
        if let url = navigation.request.url, AppLink.isOne(scheme: url.scheme), !Extensions.shared.isExtensionPage(url) {
            reply(.cancel)
            openElsewhere(url, clicked: navigation.kind == .link, mainFrame: mainFrame)
            return
        }
        if navigation.requestsDownload {
            return reply(.download)
        }
        // An extension's sign-in coming back to its own chromiumapp.org
        // address: the answer its flow waits for, or, with none waiting,
        // the address the extension watches its tab for. Never loaded.
        if mainFrame, let url = navigation.request.url, ExtensionAuth.owner(of: url) != nil,
           ExtensionAuth.intercept(url, page: self) || ExtensionAuth.handOver(url, page: self) {
            return reply(.cancel)
        }
        // An extension's rule sending a site to one of its pages (Norma's
        // block page, uBlock Origin Lite's warning): WebKit drops the site's
        // load and starts one to the page here, in a view that can't load
        // extension pages. The page takes this one's place in the tab, if
        // the extension shows it to the site the tab was going to. (Search)
        if mainFrame, !isExtensionPage, let url = navigation.request.url,
           url.scheme?.lowercased() == Extensions.scheme, let rule = navigation.contentRuleRedirect {
            let target = ExtensionPolicy.ruleTarget(url)
            let source = rule.originalSite ?? goingTo
            goingTo = nil
            if let source, Extensions.shared.webAccessible(target, from: source, in: space, fromRule: true) {
                showInstead(target)
            }
            return reply(.cancel)
        }
        if mainFrame { goingTo = Self.site(of: navigation.request.url) }
        // Between a website and an extension's own page: WebKit needs a view
        // of the other kind, so the page opens in a new tab. From a website,
        // only to a page the extension shows it.
        if mainFrame, let url = navigation.request.url,
           ["http", "https", Extensions.scheme].contains(url.scheme?.lowercased() ?? ""),
           Extensions.shared.isExtensionPage(url) != isExtensionPage {
            if !isExtensionPage, !opensExtensionPage(url, for: navigation) { return reply(.cancel) }
            if host?.page(self, openInNewTab: url, inFront: true) == true { return reply(.cancel) }
        }
        let choice = newTabChoice(for: navigation)
        if choice != .here, let url = navigation.request.url,
           host?.page(self, openInNewTab: url, inFront: choice == .inFront) == true {
            return reply(.cancel)
        }
        if let url = navigation.request.url, peeksFromPinned(navigation) {
            reply(.cancel)
            openPeek(url)
            return
        }
        if mainFrame {
            beginNavigation(navigation.request.url)
            let kind: PageHistory.NavigationKind
            switch navigation.kind {
            case .link: kind = .link
            case .form: kind = .form
            case .formResubmission: kind = .formResubmission
            case .history: kind = .history
            case .reload: kind = .reload
            case .other: kind = .other
            case .unknown(let raw): kind = .unknown(raw)
            }
            history.decided(kind, url: navigation.request.url)
        }
        if mainFrame, let request = askingInLightOrDark(navigation) {
            reply(.cancel)
            navigationAdapter.load(request)
            return
        }
        if mainFrame {
            prepare(for: navigation.request.url)
            askingForPage = (navigation.request.httpMethod ?? "GET").uppercased() == "GET"
        }
        reply(.allow)
    }

    func decideResponse(_ response: WebResponse,
                        reply: @MainActor (WebResponseDecision) -> Void) {
        // A page from a host that asks for the screen's light or dark, which came light on a dark screen: again, dark.
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
           let url = http.url, !HandsOff.covers(url),
           let value = Self.colorHint.answered(url: url, acceptCH: http.value(forHTTPHeaderField: "Accept-CH"),
                                               criticalCH: http.value(forHTTPHeaderField: "Critical-CH"),
                                               requestCarried: hintCarried, repeatable: hintRepeatable, dark: isDark) {
            reply(.cancel)
            var again = URLRequest(url: url)
            again.setValue(value, forHTTPHeaderField: ColorSchemeHint.header)
            navigationAdapter.load(again)
            return
        }
        // What WebKit can't show (a ZIP, an installer) and what the server says to save is a download.
        let attachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        let shows = response.canShowMIMEType && !attachment
        // The kind of what the tab shows, which Handoff reads it by: a download leaves the page as it was.
        if response.isForMainFrame, shows {
            mimeType = response.response.mimeType
            // What the document is, known only now, before it commits: a PDF
            // or a picture gets no writing script, and a page after one gets
            // it back; a JSON page gets its view's script.
            prepare(for: preparedFor)
        }
        if response.isForMainFrame {
            if shows { status.answered(response.response) } else { status.dropped() }
        }
        reply(shows ? .allow : .download)
    }

    /// The request again with the screen's light or dark, for a host that
    /// asks for it as a header and a request without it; nil otherwise. A
    /// step back or a reload goes as it was made, and a hands-off page is
    /// never asked for twice. Notes what the request was, for its answer.
    private func askingInLightOrDark(_ action: WebNavigation) -> URLRequest? {
        let request = action.request
        let repeatable = ![.history, .reload, .formResubmission].contains(action.kind)
            && (request.httpMethod ?? "GET").uppercased() == "GET" && !HandsOff.covers(request.url)
        hintCarried = ColorSchemeHint.carries(request.allHTTPHeaderFields)
        hintRepeatable = repeatable
        guard repeatable, let value = Self.colorHint.missing(url: request.url, method: request.httpMethod,
                                                             headers: request.allHTTPHeaderFields, dark: isDark)
        else { return nil }
        var again = request
        again.setValue(value, forHTTPHeaderField: ColorSchemeHint.header)
        return again
    }
}
