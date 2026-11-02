import AppKit
import PadCore
import UniformTypeIdentifiers
import WebKit

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
    /// returned view must be made with `configuration`, as WebKit requires,
    /// for the new page to keep its tie to the one that opened it.
    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView?
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
    private let controller: WKUserContentController
    weak var host: PageHost?

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

    /// `configuration`: WebKit's, for a page opened by another page; a new
    /// one in the space's store otherwise. Either way the page gets a script
    /// controller of its own, so the scripts swapped for one page (none at
    /// all on a hands-off host) never touch another's.
    init(tab: UUID, space: UUID, configuration: WKWebViewConfiguration? = nil, extensionPage: Bool = false) {
        self.tab = tab
        self.space = space
        isExtensionPage = extensionPage
        let config = configuration ?? Page.configuration(space: space)
        // An extension's page keeps the controller WebKit made for it.
        let controller = extensionPage ? config.userContentController : WKUserContentController()
        config.userContentController = controller
        self.controller = controller
        view = PageView(frame: .zero, configuration: config)
        super.init()
        view.page = self
        view.navigationDelegate = self
        // An extension's page has WebKit's question about recording the
        // screen answered by eGlu's recording channel (ExtensionCapture).
        if extensionPage {
            let delegate = ExtensionPageDelegate(next: self)
            extensionDelegate = delegate
            view.uiDelegate = delegate
        } else {
            view.uiDelegate = self
        }
        setUp()
    }

    static func configuration(space: UUID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Stores.store(for: space)
        // Safari, by name: the end of the user agent that WebKit leaves to
        // the app (Identity.swift). Without it sites read the app as a web
        // view inside an app, and Google refuses to sign in.
        config.applicationNameForUserAgent = Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion)
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.preferences.isElementFullscreenEnabled = true
        // window.open only from a click or a key, as Safari's pop-up
        // blocking has it; a sign-in window opened by its button opens.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // macOS's own picture in picture for a video (appWentBehind, and a
        // site's own button): WebKit has it, and turns it off in an app's
        // web views on macOS, with no public switch. This one is private: a
        // DMG has no App Review, and a macOS that takes it away leaves
        // picture in picture off, as it was. With the underscore the key
        // finds no setter and throws; without it, `_setAllows…:` is found.
        if config.preferences.responds(to: Selector(("_setAllowsPictureInPictureMediaPlayback:"))) {
            config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        // Right-click Inspect Element and console logging to the page's own
        // inspector: the same private switch Safari has, found the same way.
        // The developer tools need the _inspector object, not this; it only
        // opens WebKit's own inspector for a page that asks to be inspected.
        if config.preferences.responds(to: Selector(("_setDeveloperExtrasEnabled:"))) {
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        // The space's extensions (Extensions): WebKit takes a page's
        // controller only before the page's view is made.
        config.webExtensionController = Extensions.shared.controller(for: space)
        return config
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
            controller.add(StoreButton(page: self), contentWorld: Page.world, name: StoreButton.name)
            // A password field on the page, for history (PasswordWatch).
            controller.add(PasswordWatch(page: self), contentWorld: Page.world, name: PasswordWatch.name)
            // Grammar checking's questions to the Mac, from the app's own
            // world (WritingHandler, writing.js).
            controller.addScriptMessageHandler(WritingHandler(page: self),
                                               contentWorld: Page.world, name: WritingHandler.name)
            // The measuring tool's word from the page (MeasureHandler).
            controller.add(MeasureHandler(page: self), contentWorld: Page.world, name: MeasureHandler.name)
            // Apple Passwords under the sign-in box, only in a build that
            // may run Apple's helper (ApplePasswords).
            if ApplePasswords.entitled {
                controller.add(ApplePasswordsHandler(page: self), contentWorld: Page.world, name: ApplePasswordsForm.name)
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
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.page = nil
        view.removeFromSuperview()
        host = nil
    }

    // MARK: Loading

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
    private func opensExtensionPage(_ url: URL, for action: WKNavigationAction) -> Bool {
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
    static func site(sending action: WKNavigationAction, loadingFrom: URL?, to url: URL) -> URL? {
        let redirect = action.responds(to: NSSelectorFromString("_isRedirect")) && (action.value(forKey: "_isRedirect") as? Bool) == true
        let origin = action.sourceFrame.securityOrigin
        let frame: URL? = {
            guard origin.protocol.lowercased() == "https", !origin.host.isEmpty else { return nil }
            var parts = URLComponents()
            parts.scheme = "https"
            parts.host = origin.host
            if origin.port > 0 { parts.port = origin.port }
            parts.path = "/"
            return parts.url
        }()
        let redirecting = loadingFrom.flatMap { $0.scheme?.lowercased() == "https" && $0 != url ? $0 : nil }
        return redirect ? redirecting : frame ?? redirecting
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

    /// Whether a navigation to an extension's page is a content rule's
    /// redirect, which no page can make; WebKit says so only privately,
    /// each asked first. It makes one two ways (seen on macOS 27.0.1): a
    /// navigation of its own, marked, once the site's is dropped (nil
    /// here: the site is the one the tab was going to); or, for a load
    /// eGlu asked for in a view that has a page, the request rewritten
    /// before it is decided, the address asked for kept as its original:
    /// that address's site. `.none` for anything else, a server's
    /// redirect included.
    private static func ruleRedirect(_ action: WKNavigationAction) -> URL?? {
        func flag(_ key: String) -> Bool {
            action.responds(to: NSSelectorFromString(key)) && (action.value(forKey: key) as? Bool) == true
        }
        if flag("_isContentExtensionRedirect") || flag("isContentRuleListRedirect") { return .some(nil) }
        guard !flag("_isRedirect"), action.responds(to: NSSelectorFromString("_originalURL")),
              let original = action.value(forKey: "_originalURL") as? URL, original != action.request.url,
              let site = site(of: original)
        else { return .none }
        return .some(site)
    }

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
            view.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            view.load(URLRequest(url: url))
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
        hasPendingDialog || isHandsOff || view.cameraCaptureState != .none || view.microphoneCaptureState != .none
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
            controller.addUserScript(WKUserScript(source: PasswordWatch.script, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Page.world))
            // English typed here is checked by Harper on this Mac, where
            // Settings › Writing is on and the site isn't off (writing.js).
            // Its strings are the String Catalog's, written in as data.
            if writing {
                controller.addUserScript(WKUserScript(source: Self.writingScript,
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
            controller.addUserScript(WKUserScript(source: ApplePasswordsForm.script, injectionTime: .atDocumentEnd,
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
            controller.addUserScript(WKUserScript(source: Scripts.extensionStore, injectionTime: .atDocumentEnd,
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
    private static let writingScript = WritingScript.source(acceptKey: "⌃⌥G", acceptShortcut: "Control+Alt+G")

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
        view.callAsyncJavaScript(Self.writingScript, arguments: [:], in: nil, in: Page.world) { _ in }
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
        view.evaluateJavaScript(ApplePasswordsForm.script, in: nil, in: Page.world) { _ in }
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
    private func newTabChoice(for action: WKNavigationAction) -> NewTabClick.Choice {
        let flags = action.modifierFlags
        return NewTabClick.choice(for: action, command: flags.contains(.command), shift: flags.contains(.shift),
                                  middleButton: action.buttonNumber == 2)
    }

    // MARK: Find, zoom, print

    /// The next place the words are on the page, after the selection or
    /// before it; `found` hears whether there is one.
    func find(_ text: String, backwards: Bool = false, found: @escaping (Bool) -> Void) {
        guard !text.isEmpty else { return found(false) }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        view.find(text, configuration: configuration) { result in found(result.matchFound) }
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
        let now = view.pageZoom
        let next = step > 0 ? Self.zooms.first { $0 > now + 0.001 } : Self.zooms.last { $0 < now - 0.001 }
        guard let next else { return false }
        setZoom(Double(next))
        return true
    }

    /// Any zoom within Safari's, as a size typed in asks, to the whole percent the field shows.
    func setZoom(_ zoom: Double) {
        let zoom = min(max((zoom * 100).rounded() / 100, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        view.pageZoom = CGFloat(zoom)
        host?.pageDidChange(self)
    }

    func print() {
        guard let window = host?.hostWindow else { return }
        let operation = view.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = view.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
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
            guard let view = self?.view else { return "" }
            return MeasureNotes.window(width: Double(view.frame.width), height: Double(view.frame.height),
                                       zoom: Double(view.pageZoom))
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
        Task { [weak self] in
            // The tool ends its own way (Escape, the page put away): the
            // promise resolves and this run's model is let go.
            // The notes' dots again, found by their elements' names.
            let notes = model.notes.map { ["id": $0.id.uuidString, "name": $0.name, "number": $0.number] as [String: Any] }
            _ = try? await view.callAsyncJavaScript(Scripts.measure, arguments: ["guides": model.argument.merging(["notes": notes]) { _, new in new }],
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

    /// What the tool said (MeasureHandler), this run's only: a selection's
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
        view.customUserAgent = size == nil ? nil
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

    /// A Peek over the page, in place of the one open. `configuration`:
    /// WebKit's, for a window the page opened, which WebKit loads itself;
    /// nil for a link, loaded here.
    @discardableResult
    func openPeek(_ url: URL?, configuration: WKWebViewConfiguration? = nil, width: Double? = nil,
                  height: Double? = nil) -> PeekPage {
        peek?.close()
        let made = PeekPage(opener: self, configuration: configuration, url: url, width: width, height: height)
        peek = made
        if configuration != nil {
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
    private func peeksFromPinned(_ action: WKNavigationAction) -> Bool {
        let session = Session.shared
        guard canPeek, session.preferences.peekFromPinnedTabs, session.workspace.tab(tab)?.isPinned == true,
              host?.isShowing(self) == true else { return false }
        let kind: NewTabClick.Kind
        switch action.navigationType {
        case .linkActivated: kind = .link
        case .formSubmitted: kind = .form
        case .other: kind = .script
        default: kind = .history
        }
        return Peek.opensFromPinned(from: committed ?? view.url, to: action.request.url, kind: kind,
                                    method: action.request.httpMethod, mainFrame: action.targetFrame?.isMainFrame ?? true)
    }

    // MARK: Picture in picture

    /// Whether the page at `url` is given Document Picture-in-Picture (DocumentPicture).
    static func offersPicture(_ url: URL?) -> Bool {
        DocumentPicture.covers(url, extra: pictureTestHosts)
    }

    /// The window picture.js asked for, in place of the one open: one at a time, as in Chrome.
    private func openPicture(_ configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                             request: DocumentPicture.Request) -> WKWebView {
        picture?.close()
        let window = PictureWindow(opener: self, configuration: configuration, features: features, request: request)
        window.automatic = enteringPicture
        picture = window
        return window.view
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
        let inCall = view.cameraCaptureState != .none || view.microphoneCaptureState != .none
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

// MARK: - WebKit's questions

extension Page: WKNavigationDelegate, WKUIDelegate {
    /// WebKit's private way to hear which element a context menu is for:
    /// its link is kept for "Handoff Linked File", the menu itself shown
    /// as proposed, so willOpenMenu sees it all.
    @objc func _webView(_ webView: WKWebView, getContextMenuFromProposedMenu menu: NSMenu,
                        forElement element: NSObject?, userInfo: Any?,
                        completionHandler: @escaping (NSMenu?) -> Void) {
        linkForMenu = element.flatMap(Self.link(of:))
        completionHandler(menu)
    }

    /// The link a menu's element is on. The element is WebKit's private
    /// _WKContextMenuElementInfo, whose hit test result holds the link
    /// (absoluteLinkURL): each step is asked first, as picture in picture
    /// asks, since a key it doesn't have would raise.
    private static func link(of element: NSObject) -> URL? {
        guard element.responds(to: NSSelectorFromString("hitTestResult")),
              let result = element.value(forKey: "hitTestResult") as? NSObject,
              result.responds(to: NSSelectorFromString("absoluteLinkURL")) else { return nil }
        return result.value(forKey: "absoluteLinkURL") as? URL
    }

    /// WebKit's private word that the page left a scroll unused, the
    /// answer its own swipe waits for: the swipe's (PageSwipe.leftAlone).
    @objc func _webView(_ webView: WKWebView, didNotHandleWheelEvent event: NSEvent) {
        swipe?.leftAlone(event)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if let url = navigationAction.request.url, AppLink.isOne(scheme: url.scheme), !Extensions.shared.isExtensionPage(url) {
            decisionHandler(.cancel)
            openElsewhere(url, clicked: navigationAction.navigationType == .linkActivated, mainFrame: mainFrame)
            return
        }
        if navigationAction.shouldPerformDownload {
            return decisionHandler(.download)
        }
        // An extension's sign-in coming back to its own chromiumapp.org
        // address: the answer its flow waits for, or, with none waiting,
        // the address the extension watches its tab for. Never loaded.
        if mainFrame, let url = navigationAction.request.url, ExtensionAuth.owner(of: url) != nil,
           ExtensionAuth.intercept(url, page: self) || ExtensionAuth.handOver(url, page: self) {
            return decisionHandler(.cancel)
        }
        // An extension's rule sending a site to one of its pages (Norma's
        // block page, uBlock Origin Lite's warning): WebKit drops the site's
        // load and starts one to the page here, in a view that can't load
        // extension pages. The page takes this one's place in the tab, if
        // the extension shows it to the site the tab was going to. (Search)
        if mainFrame, !isExtensionPage, let url = navigationAction.request.url,
           url.scheme?.lowercased() == Extensions.scheme, let rule = Self.ruleRedirect(navigationAction) {
            let target = ExtensionPolicy.ruleTarget(url)
            let source = rule ?? goingTo
            goingTo = nil
            if let source, Extensions.shared.webAccessible(target, from: source, in: space, fromRule: true) {
                showInstead(target)
            }
            return decisionHandler(.cancel)
        }
        if mainFrame { goingTo = Self.site(of: navigationAction.request.url) }
        // Between a website and an extension's own page: WebKit needs a view
        // of the other kind, so the page opens in a new tab. From a website,
        // only to a page the extension shows it.
        if mainFrame, let url = navigationAction.request.url,
           ["http", "https", Extensions.scheme].contains(url.scheme?.lowercased() ?? ""),
           Extensions.shared.isExtensionPage(url) != isExtensionPage {
            if !isExtensionPage, !opensExtensionPage(url, for: navigationAction) { return decisionHandler(.cancel) }
            if host?.page(self, openInNewTab: url, inFront: true) == true { return decisionHandler(.cancel) }
        }
        let choice = newTabChoice(for: navigationAction)
        if choice != .here, let url = navigationAction.request.url,
           host?.page(self, openInNewTab: url, inFront: choice == .inFront) == true {
            return decisionHandler(.cancel)
        }
        if let url = navigationAction.request.url, peeksFromPinned(navigationAction) {
            decisionHandler(.cancel)
            openPeek(url)
            return
        }
        if mainFrame {
            beginNavigation(navigationAction.request.url)
            history.decided(navigationAction.navigationType, url: navigationAction.request.url)
        }
        if mainFrame, let request = askingInLightOrDark(navigationAction) {
            decisionHandler(.cancel)
            webView.load(request)
            return
        }
        if mainFrame {
            prepare(for: navigationAction.request.url)
            askingForPage = (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET"
        }
        decisionHandler(.allow)
    }

    /// The request again with the screen's light or dark, for a host that
    /// asks for it as a header and a request without it; nil otherwise. A
    /// step back or a reload goes as it was made, and a hands-off page is
    /// never asked for twice. Notes what the request was, for its answer.
    private func askingInLightOrDark(_ action: WKNavigationAction) -> URLRequest? {
        let request = action.request
        let repeatable = ![.backForward, .reload, .formResubmitted].contains(action.navigationType)
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

    private var isDark: Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // A page from a host that asks for the screen's light or dark, which came light on a dark screen: again, dark.
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           let url = response.url, !HandsOff.covers(url),
           let value = Self.colorHint.answered(url: url, acceptCH: response.value(forHTTPHeaderField: "Accept-CH"),
                                               criticalCH: response.value(forHTTPHeaderField: "Critical-CH"),
                                               requestCarried: hintCarried, repeatable: hintRepeatable, dark: isDark) {
            decisionHandler(.cancel)
            var again = URLRequest(url: url)
            again.setValue(value, forHTTPHeaderField: ColorSchemeHint.header)
            webView.load(again)
            return
        }
        // What WebKit can't show (a ZIP, an installer) and what the server says to save is a download.
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        let shows = navigationResponse.canShowMIMEType && !attachment
        // The kind of what the tab shows, which Handoff reads it by: a download leaves the page as it was.
        if navigationResponse.isForMainFrame, shows {
            mimeType = navigationResponse.response.mimeType
            // What the document is, known only now, before it commits: a PDF
            // or a picture gets no writing script, and a page after one gets
            // it back; a JSON page gets its view's script.
            prepare(for: preparedFor)
        }
        if navigationResponse.isForMainFrame {
            if shows { status.answered(navigationResponse.response) } else { status.dropped() }
        }
        decisionHandler(shows ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloading(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloading(download)
    }

    /// A tab that was only ever the file's way in, with no page of its own
    /// to show, goes once the download has begun, as Safari's does.
    private func downloading(_ download: WKDownload) {
        Downloads.shared.adopt(download, from: self)
        if committed == nil, !view.canGoBack { host?.pageDidClose(self) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadingFrom = webView.url
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        loadingFrom = webView.url
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
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
        committed = webView.url
        status.committed(webView.backForwardList.currentItem)
        googleRefused = SignIn.googleRefused(webView.url)
        failure = nil
        sendingFailed = false
        jsonView = nil
        refusedElsewhere = 0
        history.committed(url: webView.url, title: webView.title, entry: webView.backForwardList.currentItem,
                          space: space, tab: tab)
        passwordField = false
        // The old document's card went with it, unannounced.
        writingCardOpen = false
        changed()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        learnIcons()
        learnAbout()
        learnJSONView()
        host?.pageDidChange(self)
        #if DEBUG
        testPictureIfAsked()
        #endif
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingFrom = nil
        failed(error)
    }

    /// A load that failed for a reason worth telling: not one that was
    /// stopped, nor one that became a download.
    private func failed(_ error: Error) {
        let error = error as NSError
        let quiet = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code))
        guard !quiet else { return }
        history.failed()
        let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processEnded()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A website's window opened on an extension's page: only a page the
        // extension shows that site, as a navigation to one is held to
        // (opensExtensionPage); checked here too, before any view is made.
        if !isExtensionPage, let url = navigationAction.request.url, Extensions.shared.isExtensionPage(url),
           !(Self.site(sending: navigationAction, loadingFrom: nil, to: url).map { Extensions.shared.webAccessible(url, from: $0, in: space) } ?? false) {
            return nil
        }
        // Another app's link asked for in a window of its own: theirs to
        // open, with no tab made for a page that will never be.
        if let url = navigationAction.request.url, AppLink.isOne(scheme: url.scheme), !Extensions.shared.isExtensionPage(url) {
            openElsewhere(url, clicked: navigationAction.navigationType == .linkActivated,
                          mainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
            return nil
        }
        // picture.js's window, from the page itself and not a frame in it: it floats (PictureWindow).
        // Anywhere else, the same address is an ordinary pop-up.
        if let request = DocumentPicture.Request(url: navigationAction.request.url), navigationAction.sourceFrame.isMainFrame,
           Self.offersPicture(committed ?? view.url) {
            // Asked for on leaving the tab, but the tab is back on screen, with eGlu in front, by now: no window.
            if enteringPicture, !videoWanted || !Session.shared.preferences.automaticPictureInPicture { return nil }
            return openPicture(configuration, features: windowFeatures, request: request)
        }
        // While the app calls the site's handler for leaving the tab, the
        // click WebKit grants the call opens the site's picture window only.
        if enteringPicture { return nil }
        // Open Link in Peek, chosen from the page's menu a moment ago.
        if let asked = peekAsked {
            peekAsked = nil
            if Date().timeIntervalSince(asked) < 5, canPeek {
                return openPeek(navigationAction.request.url, configuration: configuration).page.view
            }
        }
        let made = host?.page(self, open: configuration, for: navigationAction, features: windowFeatures)
        if let child = (made as? PageView)?.page, child !== self {
            child.wasOpened = true
        }
        return made
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.pageDidClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? String(localized: "This page says") : String(localized: "\(frame.securityOrigin.host) says")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? String(localized: "This page asks") : String(localized: "\(frame.securityOrigin.host) asks")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? String(localized: "This page asks") : String(localized: "\(frame.securityOrigin.host) asks")
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
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
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let done: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = host?.hostWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }
}
