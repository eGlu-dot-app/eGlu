import PadCore
import UIKit
import WebKit
import WebKitSupport

/// What a page asks of whoever is showing it: a window (Browser) or a
/// sign-in pop-up (Popup).
@MainActor
protocol PageHost: AnyObject {
    func pageDidChange(_ page: Page)
    /// How far the load has got, and nothing else: many times a load, so
    /// it costs only what the loading line needs.
    func pageDidAdvance(_ page: Page)
    func isShowing(_ page: Page) -> Bool
    /// A window the page opened (window.open, a link to a new window). The
    /// returned view must be made with `configuration`, as WebKit requires,
    /// for the new page to keep its tie to the one that opened it.
    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView?
    /// A ⌘-click's address, for a tab of its own (NewTabClick); false where
    /// there are no tabs, and the page goes there itself.
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool
    /// Whether it has tabs to open a link in: a window has, a pop-up hasn't.
    var opensTabs: Bool { get }
    /// A link's address to share, from its menu (Page.linkMenu).
    func page(_ page: Page, share url: URL)
    /// "Handoff Linked File" from a link's menu; a no-op for a host
    /// without Handoff, whose menus never show the item (takesHandoffFiles).
    func page(_ page: Page, handOffFileAt url: URL)
    /// Whether the page's menus may offer file handoffs at all.
    var takesHandoffFiles: Bool { get }
    /// A link's address to the clipboard, from its menu (Page.linkMenu).
    func page(_ page: Page, copy url: URL)
    func pageDidClose(_ page: Page)
    /// Somewhere to show an alert, a sign-in prompt or a save sheet.
    var presenter: UIViewController? { get }
    /// A link for another app the page went to by itself again after being
    /// told no twice: kept, unasked, for the page's menu to review.
    func page(_ page: Page, held appLink: URL)
}

extension PageHost {
    func page(_ page: Page, handOffFileAt url: URL) {}
    var takesHandoffFiles: Bool { false }
}

extension PageHost {
    /// A host with no toast to say so (Popup) only copies it.
    func page(_ page: Page, copy url: URL) {
        UIPasteboard.general.url = Tracking.clean(url)
    }

    /// A host that shows no loading line (Popup) hears it as any change.
    func pageDidAdvance(_ page: Page) {
        pageDidChange(page)
    }

    /// A host with no toast (Popup) says nothing; its menu has no review either.
    func page(_ page: Page, held appLink: URL) {}
}

/// One tab's page while it is live: its web view, the scripts it gets, the
/// bridges between the iPad's input and it, and everything WebKit tells it.
///
/// This is the only place the app calls into a page or changes what goes
/// into one, and every such call first asks HandsOff whether it may
/// (PolicyTests keeps it that way).
@MainActor
final class Page: NSObject {
    /// The app's own content world: the bridge's variables live here, out of
    /// the page's sight, and the page can't reach its message handler.
    static let world = WKContentWorld.world(name: "eGlu")
    static let handlerName = "eglu"

    let tab: UUID
    let space: UUID
    let view: PageView
    private let controller: WKUserContentController
    weak var host: PageHost?
    /// Watches the find bar until it has gone (find()).
    private var findWatch: Timer?
    /// What the page did with the last secondary click's contextmenu event,
    /// and a link's menu waiting to hear it (contextMenuConfigurationForElement).
    private var contextAnswer: (time: CFTimeInterval, kept: Bool)?
    private var contextWaiting: (menu: UIContextMenuConfiguration, since: CFTimeInterval,
                                 done: @MainActor (UIContextMenuConfiguration?) -> Void)?

    private(set) var adapter = Adapters.standard
    private(set) var bridges = Bridges.standard
    /// The scripts installed for the next document: an adapter's id and its
    /// settings, "hands-off", or nil before the first page.
    private var installed: String?
    /// The content blocker's lists on this page, by identifier: none on a
    /// hands-off page, or where Settings or the site's switch turns it off.
    private var blocking = PageBlocking()
    /// The app itself is loading the page (an address typed, a reload): no
    /// click of the page's asked for it, whatever the pointer last did. True
    /// from the start: a page WebKit opens for a link loads it in place,
    /// though that load carries the ⌘ of the click that opened it.
    private var ownLoad = true
    /// The screen's light or dark, to the sites that ask for it as a header
    /// (ColorSchemeHint): for every page, and for the run only.
    private static var colorHint = ColorSchemeHint()
    /// Whether the page's last request had that header, and could be made again.
    private var hintCarried = false
    private var hintRepeatable = false
    private(set) var committed: URL?
    /// Desktop or mobile site, chosen for each page as it loads (SiteMode).
    private(set) var mode: SiteMode = .desktop
    /// In the iPhone's desktop view (DesktopPad): laid out at an iPad's size,
    /// always the desktop site, and reached only through the cursor, so
    /// touches on the page itself are off.
    /// What the iPhone's desktop view shows of the page, in the page view's
    /// points, for the tab overview's picture of it: what was being looked
    /// at, not the whole desktop squeezed into a card.
    var desktopShown: CGRect? {
        didSet { if desktopShown != oldValue { sampleFootSoon() } }
    }

    var desktopView = false {
        didSet {
            guard desktopView != oldValue else { return }
            if !desktopView { desktopShown = nil }
            view.isUserInteractionEnabled = !desktopView
            view.accessibilityElementsHidden = desktopView
            // Writing is never in the Desktop View (Decided 2): a check
            // running now stops, and comes back on leaving it, whether or
            // not the page loads again then (a site already asked for as a
            // desktop site doesn't).
            followWriting()
            applyScrolling()
        }
    }
    /// The cursor's moves, one at a time: while one is on its way to the
    /// page, only the latest of those after it is kept.
    private var moving = false
    private var nextMove: [String: Any]?
    private(set) var mimeType: String?
    /// A PDF read as a document for a handoff (PageShared.readingForHandoff).
    var handoffDocument: DocumentSource?
    /// Writing's card is open on this page: ⌃⌥G takes its first
    /// suggestion only then (WritingHandler's card messages).
    var writingCardOpen = false
    /// The main frame's HTTP status, for the developer bar's small label:
    /// the document's on screen, nil for a failed load (PageStatus).
    var statusCode: Int? { status.code }
    private var status = PageStatus()
    private(set) var passwordField = false
    /// The visit the document on screen is, in its space's history (PageHistory).
    private var history = PageHistory()

    /// The page is a tab coming back as it was (thawed, or at launch): its
    /// first document was visited already.
    func restoring() {
        history.restoring()
    }
    /// The focus is in a field someone types in (bridge.js decides).
    private(set) var editing = false {
        didSet { if editing != oldValue { desktopFocusChanged?(editing) } }
    }
    var desktopFocusChanged: ((Bool) -> Void)?
    var desktopContextResult: ((Bool) -> Void)?
    private(set) var failure: String?
    private var loadState = PageLoadState()
    var displayURL: URL? { loadState.displayURL(current: view.url) }
    private(set) var refusedAppLink: URL?
    private var pendingDialog: (show: () -> Void, cancel: () -> Void)?
    var hasPendingDialog: Bool { pendingDialog != nil }

    func reviewPendingDialog() {
        guard host?.isShowing(self) == true, let pendingDialog else { return }
        guard let presenter = host?.presenter, presenter.presentedViewController == nil else { return }
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
        cancelPendingDialog()
        loadState.begin(url)
        failure = nil
        googleRefused = false
        // The tool's page is going: the tool with it, overlay and all, so
        // a document the address only moves within never keeps it; and the
        // notes on its elements.
        stopMeasuring()
        measureNotes = []
    }
    private(set) var googleRefused = false
    /// The page's process kept ending; it waits for a click to load again.
    private(set) var exhausted = false
    private var crashes = CrashGuard()

    /// The colour of the page's top, which the bars above it take on.
    private(set) var siteColor: SiteColor?
    private var sampling: Task<Void, Never>?
    /// The looks after a touch on the page (touched).
    private var touchSampling: Task<Void, Never>?
    /// The look put off while a finger is on the page or it glides (sampleColor).
    private var heldLook: Task<Void, Never>?
    /// The colour of the page under the phone bar, which the bar's ground
    /// takes on (sampleFoot); nil until it has been looked at.
    private(set) var footColor: SiteColor?
    /// How much of the view's bottom the phone bar covers: none where
    /// there is no such bar, and then nothing is looked at.
    var footBand: CGFloat = 0 {
        didSet { if footBand != oldValue { sampleFootSoon() } }
    }
    /// The iPhone Duo's strip over the page, while the page runs on under it
    /// to the window's edge (Browser.placeUnderStrip): strip.js moves what
    /// can be pressed out from under the strip's items. Nil, and the page is
    /// left as it lays itself out. The scroll bar keeps beside the strip by
    /// itself: UIKit insets it by the safe area, which the strip is.
    var strip: DuoLayout.Strip? {
        didSet {
            guard strip != oldValue else { return }
            view.stripSide = strip.map { $0.side == .right ? .maxXEdge : .minXEdge }
            // The documents to come get it with their scripts (prepare); the one up now, here.
            tellStrip()
        }
    }
    private var footSampling: Task<Void, Never>?
    /// Whether what is under the bar has moved since it was last looked at (sampleFootSoon).
    private var footMoved = false

    /// The question about a link for another app, while it is up, and how
    /// often this page has been told no (openElsewhere).
    private weak var askingElsewhere: UIAlertController?
    private var refusedElsewhere = 0
    /// The link held unasked that the host has been told of: said once, not
    /// again for every time the page tries it (a timer can, many times a second).
    private var toldHeld: URL?
    /// What the document on screen was last told about a site's own menus
    /// (settingsChanged): nil until one has been.
    private var toldOwnMenus: Bool?
    /// A page another page opened (window.open, a link to a new window),
    /// and the site that opened it.
    private var wasOpened = false
    private var openerHost: String?

    /// Wheel events on their way into the page, one at a time (wheel(at:)).
    private var wheels = WheelLine<Wheeling>()

    private(set) var pointer: Pointer?
    /// Back and forward by a swipe, where WebKit's own is off (applyScrolling).
    private(set) var backSwipe: BackSwipe?
    private var zoom: ZoomHold?
    private var observations: [NSKeyValueObservation] = []

    /// What Diagnostics shows.
    struct Stats {
        var pinchSteps = 0
        var commandZoomSteps = 0
        var bridgedWheels = 0
        var standAside = 0
        var webKitWheels = 0
        var relayedKeys = 0
        var processEnds = 0
        var userAgent: String?
        var lastOutcome = ""
    }
    var stats = Stats()

    /// `configuration`: WebKit's, for a page opened by another page; a new
    /// one in the space's store otherwise. Either way the page gets a script
    /// controller of its own, so the scripts swapped for one page (none at
    /// all on a hands-off host) never touch another's.
    /// `keyboardByWindow`: the window lays the page out above the keyboard
    /// (Browser.pageRoom); a pop-up's doesn't, and leaves it to WebKit (PageView).
    init(tab: UUID, space: UUID, configuration: WKWebViewConfiguration? = nil, keyboardByWindow: Bool = true) {
        self.tab = tab
        self.space = space
        let config = configuration ?? Page.configuration(space: space)
        let controller = WKUserContentController()
        config.userContentController = controller
        self.controller = controller
        view = PageView(frame: .zero, configuration: config, keyboardByWindow: keyboardByWindow)
        super.init()
        view.page = self
        view.navigationDelegate = self
        view.uiDelegate = self
        controller.add(Relay(self), contentWorld: Page.world, name: Page.handlerName)
        // Grammar checking's questions to the app, from the app's own
        // world (WritingHandler, writing.js).
        controller.addScriptMessageHandler(WritingHandler(page: self), contentWorld: Page.world,
                                           name: WritingHandler.name)
        controller.add(MeasureHandler(page: self), contentWorld: Page.world, name: MeasureHandler.name)
        setUp()
    }

    static func configuration(space: UUID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Stores.store(for: space)
        // Safari on a Mac, by name and by layout: desktop pages, and the end
        // of the user agent that WebKit leaves to the app (Identity.swift).
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.applicationNameForUserAgent = Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.preferences.isElementFullscreenEnabled = true
        // window.open only from a click or a key, as Safari's pop-up
        // blocking has it; a sign-in window opened by its button opens.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        return config
    }

    private func setUp() {
        // The page gets the trackpad and the keys; the system's own uses of
        // them in a web view are off.
        // On, so that WebKit asks for a link's menu (linkMenu); no preview of a page ever shows.
        view.allowsLinkPreview = true
        view.allowsBackForwardNavigationGestures = false
        // Off until asked for (find()): left on, ⌘F and ⌘G would be WebKit's, and they are the page's.
        view.isFindInteractionEnabled = false
        view.isInspectable = true
        let scroll = view.scrollView
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.isScrollEnabled = false
        scroll.bouncesZoom = false
        scroll.pinchGestureRecognizer?.isEnabled = false
        zoom = ZoomHold(scroll)
        pointer = Pointer(page: self)
        backSwipe = BackSwipe(page: self)
        observations = [
            view.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            view.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.changed()
                    // A page that changes its address without loading (Figma
                    // opening a file) may change its top too.
                    self?.sampleSoon()
                }
            },
            view.observe(\.themeColor) { [weak self] _, _ in MainActor.assumeIsolated { self?.sampleColor() } },
            // What is under the phone bar changes as the page scrolls.
            scroll.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.sampleFootSoon() } },
            // And whether the page only fills the window, as it grows and shrinks (weighFoot).
            scroll.observe(\.contentSize) { [weak self] _, _ in MainActor.assumeIsolated { self?.weighFoot() } },
            // How a load is going is the bars' to show and not the workspace's to keep.
            view.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressed() } },
            view.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.host?.pageDidAdvance(self)
                }
            },
            view.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressed() } },
            view.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressed() } },
            // Mixed content can arrive mid-load, which the progress no longer reports.
            view.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressed() } },
        ]
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

    /// Lets the page go: the view out of its window, its scripts and
    /// handler gone, its gestures stopped. WebKit ends the page's process
    /// once nothing holds the view.
    func tearDown() {
        // The tool's run holds the view until it ends: it ends first.
        stopMeasuring()
        cancelPendingDialog()
        observations.forEach { $0.invalidate() }
        observations = []
        findWatch?.invalidate()
        findWatch = nil
        sampling?.cancel()
        sampling = nil
        footSampling?.cancel()
        footSampling = nil
        pointer?.stop()
        pointer = nil
        backSwipe?.stop()
        backSwipe = nil
        // A link's menu still waiting to hear from the page gets its answer: WebKit
        // raises an exception for a completion handler let go without being called.
        answerContext(kept: true, record: false)
        dropWheels()
        zoom = nil
        controller.removeAllUserScripts()
        blocking.remove(from: controller)
        controller.removeScriptMessageHandler(forName: Page.handlerName, contentWorld: Page.world)
        controller.removeScriptMessageHandler(forName: WritingHandler.name, contentWorld: Page.world)
        controller.removeScriptMessageHandler(forName: MeasureHandler.name, contentWorld: Page.world)
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
        ownLoad = true
        view.load(URLRequest(url: url))
    }

    /// `byHand`: asked for, so the count of endings starts over; a reload
    /// after an ending keeps counting (CrashGuard).
    func reload(byHand: Bool = true) {
        let retry = loadState.failed
        beginNavigation(retry ?? view.url)
        exhausted = false
        if byHand { crashes.reset() }
        ownLoad = true
        if let retry {
            view.load(URLRequest(url: retry))
        } else if view.url == nil, let url = committed ?? Session.shared.workspace.tab(tab)?.url {
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    /// Whether the address bar has to show for this page (SignIn.swift).
    var isSignIn: Bool {
        passwordField || SignIn.isSignInPage(view.url)
    }

    var isHandsOff: Bool {
        HandsOff.covers(view.url) || HandsOff.covers(committed)
    }

    /// The site on screen keeps its own context menus (OwnMenus): asked as
    /// the menu is, so a choice made in Settings holds for a page already open.
    var keepsOwnMenus: Bool {
        Session.shared.preferences.keepsOwnMenus(onHost: view.url?.host)
    }

    var isHeavy: Bool {
        adapter.isHeavy(view.url)
    }

    /// Only a live page can keep these going: a call, a recording, a
    /// download. A hands-off page can't be asked whether it holds anything
    /// typed, so it stays too; sign-in pages are light anyway.
    var mustStay: Bool {
        hasPendingDialog || isHandsOff || view.cameraCaptureState != .none || view.microphoneCaptureState != .none
            || Downloads.shared.isDownloading(for: self)
    }

    /// Puts in the scripts for the page about to load at `url`: the bridge,
    /// the site's adapter, and nothing at all on a hands-off host. Called
    /// before each main-frame document is made, from the navigation's policy
    /// decisions, so the document starts with the right ones.
    private func prepare(for url: URL?) {
        let handsOff = HandsOff.covers(url)
        blocking.apply(for: url, to: controller)
        adapter = Adapters.adapter(for: url)
        bridges = Session.shared.preferences.bridges(for: adapter)
        if handsOff {
            view.customUserAgent = nil
        } else if mode == .mobile {
            // WebKit's own, in a mobile layout, lacks the "Mobile" sites look for.
            view.customUserAgent = Identity.mobileUserAgent(for: ProcessInfo.processInfo.operatingSystemVersion,
                                                            pad: UIDevice.current.userInterfaceIdiom == .pad)
        } else {
            view.customUserAgent = adapter.userAgent
        }
        let keys = bridges.keys.map(\.rawValue).sorted().joined(separator: ",")
        // A site that keeps its own context menus gets no callouts, and so no menu of the app's (OwnMenus).
        let ownMenus = Session.shared.preferences.keepsOwnMenus(onHost: url?.host)
        // What this site's filters ask for that WebKit's rules can't do
        // (ScriptedFilters): nothing on most sites, and never where blocking
        // is off or the host is hands-off.
        let filters = blocksContent ? ContentBlocker.shared.scriptedRules(for: url) : PageRules()
        let json = Session.shared.preferences.formatJSON && DeveloperMode.isJSON(mimeType: mimeType)
        let writing = checksWriting(on: url)
        let wanted = handsOff ? "hands-off"
            : "\(adapter.id)|\(bridges.wheel.rawValue)|\(keys)|\(bridges.cursors)|\(mode.rawValue)|\(ownMenus)"
                + (filters.isEmpty ? "" : "|\(filters.stamp)")
                + (writing ? Self.writingStamp : "") + (json ? "|json" : "")
                + (strip.map { "|strip" + Scripts.strip(set: $0) } ?? "")
        guard wanted != installed else { return }
        installed = wanted
        controller.removeAllUserScripts()
        guard !handsOff else { return }
        controller.addUserScript(WKUserScript(source: Scripts.ours(for: adapter, bridges: bridges, ownMenus: ownMenus),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Page.world))
        if let script = Scripts.page(for: adapter) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
        // English typed here is checked by Harper on this device, where
        // Settings › Writing is on and the site isn't off (writing.js).
        // Its strings are the String Catalog's, written in as data.
        if writing {
            controller.addUserScript(WKUserScript(source: Self.writingScript,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Page.world))
        }
        controller.addFilterScripts(for: filters)
        // Under the iPhone Duo's strip, what can be pressed moved out from under its items.
        if let strip {
            controller.addUserScript(WKUserScript(source: Scripts.strip + "\n" + Scripts.strip(set: strip),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Page.world))
            #if DEBUG
            if let touch = StripTour.earlyTouch {
                controller.addUserScript(WKUserScript(source: touch, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                                      in: Page.world))
            }
            #endif
        }
        // The JSON view, while Settings formats JSON and the response's type
        // says the document is (the stamp's |json re-prepares where the
        // answer only comes with the response).
        if json {
            controller.addUserScript(WKUserScript(source: Scripts.jsonView, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Page.world))
        }
    }

    /// Whether a navigation is a ⌘-click (or ⌘⇧, or a middle click) to open
    /// in a new tab (NewTabClick). WebKit says which keys and button made it
    /// from iPadOS 18.4; the pointer's own last press, a second ago at most,
    /// says it before then, and for a button whose script goes somewhere,
    /// which WebKit gives no keys for.
    func newTabChoice(for action: WKNavigationAction) -> NewTabClick.Choice {
        var flags: UIKeyModifierFlags = []
        var middle = false
        if #available(iOS 18.4, *) {
            flags = action.modifierFlags
            middle = action.buttonNumber.contains(.button(3))
        }
        if let press = pointer?.recentPress(within: 1) {
            flags.formUnion(press.flags)
            middle = middle || press.middle
        }
        return NewTabClick.choice(for: action, command: flags.contains(.command), shift: flags.contains(.shift),
                                  middleButton: middle)
    }

    /// Whether the page on screen has ads and trackers blocked, for its menus and Diagnostics.
    var blocksContent: Bool {
        blocking.isOn
    }

    /// The content blocker has new lists: this page's next load has them.
    func blockingChanged() {
        blocking.apply(for: committed ?? view.url, to: controller)
    }

    /// Whether English in this page's fields is checked, for Settings ›
    /// Writing being on, this site not being one it is off for (the
    /// never-checked sites in WritingSites always count as off), the
    /// document being one text is typed in, and not the iPhone's Desktop
    /// View, where the page is scaled and driven by a cursor (Decided 2).
    func checksWriting(on url: URL? = nil) -> Bool {
        let page = url ?? committed ?? view.url
        let readable = mimeType.map { $0 != "application/pdf" && !$0.hasPrefix("image/") } ?? true
        return Session.shared.preferences.writing && !desktopView && readable
            && !WritingSites.isOff(page, sites: Session.shared.preferences.writingOffSites)
    }

    /// What `installed` holds while writing.js is among the scripts.
    private static let writingStamp = "|writing"

    /// writing.js with the card's words. No key beside its first suggestion:
    /// most of these devices have no keyboard to press it on.
    private static let writingScript = WebKitScriptBridge.source + "\n" + WritingScript.source(acceptKey: nil, acceptShortcut: nil)

    /// ⌃⌥G takes the open card's first suggestion: the fix goes in the way
    /// the page's own Undo takes back (writing.js apply()).
    func writingAcceptFirst() async -> Bool {
        guard checksWriting(), !isHandsOff else { return false }
        // The async form, which answers with the script's value: written
        // with `in:` twice it was the completion-handler one, which answers
        // nothing, so ⌃⌥G always seemed to fail.
        let accepted = try? await view.callAsyncJavaScript(
            "return window.__egluWriting ? window.__egluWriting.acceptFirst() : false",
            contentWorld: Page.world)
        return accepted as? Bool == true
    }

    /// The checker's scripts taken out of the page that is up, where they
    /// went in: Settings turned writing off, or the page went to its
    /// Desktop View (Decided 16).
    func writingStop() {
        guard !isHandsOff else { return }
        view.callAsyncJavaScript(
            "window.__egluWriting && window.__egluWriting.stop(); return true;",
            arguments: [:], in: nil, in: Page.world) { _ in }
    }

    /// The scripts chosen again for the page that is up, and writing.js
    /// taken out of it or put into it at once where that changed: turned
    /// off (or this site, or the Desktop View) it leaves; turned on, it
    /// comes in, so the field being typed in is checked without a reload
    /// (Decided 16).
    private func followWriting() {
        let wasWriting = installed?.contains(Self.writingStamp) == true
        prepare(for: committed ?? view.url)
        let writing = installed?.contains(Self.writingStamp) == true
        if wasWriting, !writing { writingStop() }
        if writing, !wasWriting { writingStart() }
    }

    /// The field being typed in, brought into the view once the view has
    /// been cut short above the keyboard (Browser.pageRoom): WebKit doesn't
    /// hear the keyboard (PageView), so it doesn't move the page for it,
    /// and a field below where the keyboard's top came to stayed under it.
    /// Looked for now, and again when the page has its new height (it gets
    /// it a moment after its view does); moved only if it doesn't show, and
    /// by its caret where it is taller than half the view (an editor).
    /// Not yet: the caret of a tall textarea, which the page's selection
    /// doesn't place; a field in a frame; an editor in a panel that scrolls
    /// by itself or is fixed, which a scroll of the page doesn't move.
    func revealFocus() {
        guard editing, !isHandsOff, !HandsOff.covers(view.url) else { return }
        view.callAsyncJavaScript(Self.revealScript, arguments: [:], in: nil, in: Page.world) { _ in }
    }

    private static let revealScript = """
        const reveal = () => {
            const field = document.activeElement;
            if (!field || field === document.body || field === document.documentElement) return;
            const height = window.visualViewport ? window.visualViewport.height : window.innerHeight;
            const margin = 16;
            let rect = field.getBoundingClientRect();
            if (rect.height > height / 2) {
                const selection = getSelection();
                const caret = selection && selection.rangeCount ? selection.getRangeAt(0).getBoundingClientRect() : null;
                if (!caret || !caret.height) return;
                if (caret.bottom > height - margin) window.scrollBy(0, caret.bottom - height + margin * 3);
                else if (caret.top < margin) window.scrollBy(0, caret.top - margin * 3);
                return;
            }
            if (rect.bottom > height - margin || rect.top < margin) field.scrollIntoView({ block: 'center', inline: 'nearest' });
        };
        reveal();
        const viewport = window.visualViewport;
        if (!viewport) return;
        const again = () => { viewport.removeEventListener('resize', again); reveal(); };
        viewport.addEventListener('resize', again);
        setTimeout(() => viewport.removeEventListener('resize', again), 800);
        """

    /// Writing's script put into the document that is up, for checking
    /// turned on while it was open: user scripts reach only the next one,
    /// and a reload would lose what is typed. One already there, stopped,
    /// starts again instead.
    private func writingStart() {
        guard !isHandsOff else { return }
        view.callAsyncJavaScript(Self.writingScript, arguments: [:], in: nil, in: Page.world) { _ in }
    }

    /// After Settings changed: the bridges at once, the scripts from the next page.
    func settingsChanged() {
        bridges = Session.shared.preferences.bridges(for: adapter)
        // The scripts go in again only if a setting they are made from is
        // another one: prepare() knows by what it last put in. Settings
        // change for many other reasons, and for every live page at once.
        followWriting()
        if !bridges.cursors { pointer?.show(.system) }
        // A site's own menus, turned on or off for the page that is up: the
        // rule that keeps callouts away went in as the page loaded, so it is
        // given or taken away now, and a web app needn't load again for it.
        let keeps = keepsOwnMenus
        if keeps != toldOwnMenus {
            toldOwnMenus = keeps
            call("if (window.__eglu) window.__eglu.callouts(css);", ["css": keeps ? Scripts.noCallout : ""])
        }
    }

    /// WebKit's own scrolling, for a finger on the glass only unless no
    /// bridge can run (Scrolling.swift): on a desktop page the trackpad's
    /// and the mouse's scrolling stay bridged (Pointer), so a canvas still
    /// gets its wheel events, and a finger scrolls the page as in Safari
    /// (asked for on 3 November 2026). On a phone, and for a mobile site, a
    /// finger is what there is: the page scrolls and pinches as in Safari,
    /// its zoom free.
    private func applyScrolling() {
        // WebKit's own swipe back and forward goes with WebKit's own
        // scrolling: only then can it tell a swipe the page has no use for
        // from one the page pans with. Where the wheel is bridged the swipe
        // is the app's, which asks the page first (BackSwipe).
        let native = Scrolling.isNative(url: view.url, mimeType: mimeType)
        view.allowsBackForwardNavigationGestures = touchFirst || native
        backSwipe?.isEnabled = !touchFirst && !native && !desktopView
        // A pull down to load the page again, where a finger is the way in.
        let pull = touchFirst ? refresher : nil
        if view.scrollView.refreshControl !== pull { view.scrollView.refreshControl = pull }
        let pan = view.scrollView.panGestureRecognizer
        if allTouchTypes == nil { allTouchTypes = pan.allowedTouchTypes }
        let fingersOnly = !touchFirst && !native
        pan.allowedScrollTypesMask = fingersOnly ? [] : .all
        pan.allowedTouchTypes = fingersOnly ? [NSNumber(value: UITouch.TouchType.direct.rawValue)] : allTouchTypes ?? pan.allowedTouchTypes
        // The iPhone's desktop view is a trackpad over the page, which scrolls it itself (DesktopPad).
        view.scrollView.isScrollEnabled = native || !desktopView
        if touchFirst {
            zoom?.release()
            return
        }
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        zoom?.hold()
    }

    /// What the scroll view's own pan takes as WebKit made it: every kind of touch.
    private var allTouchTypes: [NSNumber]?

    #if DEBUG
    /// A test run's look at the page (StripTour): `script` in the app's own
    /// world, its answer as text or the error's message. Never on a hands-off page.
    func tourLook(_ script: String) async -> String? {
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed) else { return "hands-off" }
        return await withCheckedContinuation { done in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: Page.world) { result in
                switch result {
                case .success(let value): done.resume(returning: value as? String)
                case .failure(let error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error.localizedDescription
                    done.resume(returning: "error \(message)")
                }
            }
        }
    }
    #endif

    // MARK: A pull down to load again

    private lazy var refresher: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        return control
    }()

    private func pulled() {
        reload()
        // The spinner goes when the page answers (endPull), or after a while if it never does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.endPull() }
    }

    private func endPull() {
        guard view.scrollView.refreshControl != nil || refresher.isRefreshing else { return }
        if refresher.isRefreshing { refresher.endRefreshing() }
    }

    // MARK: Back and forward

    func canGo(_ way: HistorySwipe.Way) -> Bool {
        way == .back ? view.canGoBack : view.canGoForward
    }

    func go(_ way: HistorySwipe.Way) {
        if way == .back { view.goBack() } else { view.goForward() }
    }

    // MARK: Find on page

    /// WebKit's own find bar. Its interaction is on only while the bar
    /// shows: left on, ⌘F and ⌘G would be WebKit's, and they are the page's
    /// (a web app's own search).
    func find() {
        view.isFindInteractionEnabled = true
        view.findInteraction?.presentFindNavigator(showingReplace: false)
        findWatch?.invalidate()
        let began = CACurrentMediaTime()
        findWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            // The timer is stopped out here; only the page is gone into on the main actor.
            let over = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                // The bar takes a moment to show; then it is watched until it has gone.
                guard CACurrentMediaTime() - began > 1, self.view.findInteraction?.isFindNavigatorVisible != true else { return false }
                self.findWatch = nil
                self.view.isFindInteractionEnabled = false
                return true
            }
            if over { timer.invalidate() }
        }
    }

    /// Loads the page again as its desktop or its mobile site, the user
    /// agent set first, so the reload goes with it.
    func reload(as wanted: SiteMode) {
        mode = wanted
        prepare(for: view.url)
        view.reload()
    }

    /// Touch is the way in: an iPhone (no trackpad reaches it), or a mobile
    /// site. Not in the desktop view, where the cursor is.
    var touchFirst: Bool {
        (UIDevice.current.userInterfaceIdiom == .phone && !desktopView) || mode == .mobile
    }

    /// The mode for a page at `url` in this page's window, as it is now.
    private func chooseMode(for url: URL?) -> SiteMode {
        if desktopView { return .desktop }
        var size = view.window?.bounds.size ?? host?.presenter?.view.window?.bounds.size ?? view.bounds.size
        if size.width < 1 || size.height < 1 {
            // Not on screen yet: the size of the window it will be shown in, near enough.
            let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
            size = windows.first?.bounds.size ?? size
        }
        return SiteMode.choose(host: url?.host, width: Double(size.width), height: Double(size.height),
                               overrides: Session.shared.preferences.siteModes)
    }

    // MARK: Calls into the page

    /// Calls bridge.js, and nothing else, in the app's own world. Never on a
    /// hands-off page, and never on a page that got no bridge.
    private func call(_ body: String, _ arguments: [String: Any], done: ((Any?) -> Void)? = nil) {
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed),
              let installed, installed != "hands-off"
        else {
            done?(nil)
            return
        }
        view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Page.world) { result in
            if case .success(let value) = result { done?(value) } else { done?(nil) }
        }
    }

    /// One wheel event at `point`, in the page view's points. `guarded`
    /// names which of WebKit's own events make it stand aside: "scroll" for
    /// plain ones, "pinch" for ctrl ones. The outcome is bridge.js's.
    ///
    /// One at a time: while the page is still answering one, those that come
    /// are added up into the next, which goes when the answer is in, and
    /// each caller hears the outcome of the event its own went in. The
    /// trackpad sends over a hundred a second; a page slower than that would
    /// otherwise have them pile up, and go on scrolling after the fingers
    /// had stopped.
    ///
    /// `reaching` is the phone's desktop view's: a scroll up or down with
    /// nothing under the cursor to move goes to what can take it further
    /// along the cursor's column (bridge.js reach). The cursor there is
    /// where the finger's last move left it, on a bar at the view's edge
    /// as often as not.
    func wheel(at point: CGPoint, dx: Double, dy: Double, modifiers: UIKeyModifierFlags,
               zoom: Bool, guarded: String, reaching: Bool = false, done: ((String?) -> Void)? = nil) {
        let event = Wheeling(point: point, dx: dx, dy: dy, modifiers: modifiers, zoom: zoom, guarded: guarded,
                             reaching: reaching, done: done.map { [$0] } ?? [])
        if let now = wheels.take(event) { send(now) }
    }

    /// The page's own view scrolled by so much, as far as it goes: for a
    /// page in the phone's desktop view that the bridge is not in (a PDF),
    /// which nothing else there could scroll. In the page's own points.
    func nudge(dx: Double, dy: Double) {
        let scroll = view.scrollView
        let scale = Double(scroll.zoomScale)
        let inset = scroll.adjustedContentInset
        let furthest = CGPoint(x: max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right),
                               y: max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom))
        var to = scroll.contentOffset
        to.x = min(max(-inset.left, to.x + dx * scale), furthest.x)
        to.y = min(max(-inset.top, to.y + dy * scale), furthest.y)
        if to != scroll.contentOffset { scroll.setContentOffset(to, animated: false) }
    }

    /// The page's process ended, or the page is going: what it had yet to
    /// answer no longer keeps the next from going, and those held hear that
    /// nothing came of them.
    private func dropWheels() {
        for done in wheels.drop().flatMap(\.done) { done(nil) }
    }

    private func send(_ wheel: Wheeling) {
        let run = wheels.run
        // A bridged scroll moves the page without the scroll view hearing of it.
        sampleFootSoon()
        let message: [String: Any] = [
            "x": Double(wheel.point.x), "y": Double(wheel.point.y), "width": Double(view.bounds.width),
            "dx": wheel.dx, "dy": wheel.dy,
            "ctrl": wheel.zoom || wheel.modifiers.contains(.control),
            "alt": wheel.modifiers.contains(.alternate),
            "shift": wheel.modifiers.contains(.shift),
            "meta": !wheel.zoom && wheel.modifiers.contains(.command),
            "guard": wheel.guarded,
            "force": bridges.wheel == .always && wheel.guarded == "scroll",
            "reach": wheel.reaching,
        ]
        call("return window.__eglu ? window.__eglu.wheel(m) : 'absent';", ["m": message]) { [weak self] value in
            let outcome = value as? String
            if let self, let outcome {
                self.stats.lastOutcome = outcome
                if outcome == "native" { self.stats.standAside += 1 } else { self.stats.bridgedWheels += 1 }
            }
            for done in wheel.done { done(outcome) }
            // The next goes on this run's own answer, never on one left over.
            if let self, let next = self.wheels.answered(in: run) { self.send(next) }
        }
    }

    /// Tab or an arrow, taken from the system, for the page (PageView).
    func relay(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        let key: String
        switch input {
        case "\t": key = "Tab"
        case UIKeyCommand.inputUpArrow: key = "ArrowUp"
        case UIKeyCommand.inputDownArrow: key = "ArrowDown"
        case UIKeyCommand.inputLeftArrow: key = "ArrowLeft"
        case UIKeyCommand.inputRightArrow: key = "ArrowRight"
        default: return
        }
        let flags = command.modifierFlags
        let message: [String: Any] = [
            "key": key, "code": key,
            "shift": flags.contains(.shift), "alt": flags.contains(.alternate),
            "ctrl": flags.contains(.control), "meta": flags.contains(.command),
        ]
        stats.relayedKeys += 1
        call("return window.__eglu ? window.__eglu.key(m) : 'absent';", ["m": message])
    }

    // MARK: The iPhone's desktop view

    /// The desktop view's cursor at `point`, in the page view's points (the
    /// desktop's): "move", "down", "up", "click" (`detail` 2 for the second
    /// of a double click) or "context". A move waits for the one before.
    func pointer(_ type: String, at point: CGPoint, button: Int = 0, buttons: Int = 0, detail: Int = 0) {
        let message: [String: Any] = [
            "type": type, "x": Double(point.x), "y": Double(point.y), "width": Double(view.bounds.width),
            "button": button, "buttons": buttons, "detail": detail,
        ]
        guard type == "move" else {
            // A press or a click comes after the moves before it.
            if let next = nextMove { nextMove = nil; send(move: next) }
            call("return window.__eglu ? window.__eglu.pointer(m) : 'absent';", ["m": message])
            return
        }
        if moving { nextMove = message } else { send(move: message) }
    }

    private func send(move message: [String: Any]) {
        moving = true
        call("return window.__eglu ? window.__eglu.pointer(m) : 'absent';", ["m": message]) { [weak self] _ in
            guard let self else { return }
            self.moving = false
            if let next = self.nextMove {
                self.nextMove = nil
                self.send(move: next)
            }
        }
    }

    /// What the phone's keyboard did in the desktop view: `back` characters
    /// taken away, then `text` (bridge.js type()).
    func type(_ text: String, back: Int) {
        call("return window.__eglu ? window.__eglu.type(m) : 'absent';", ["m": ["text": text, "back": back]])
    }

    /// A key from the keys over the phone's keyboard: Return, Escape, Tab,
    /// Backspace or an arrow.
    func press(_ key: String) {
        call("return window.__eglu ? window.__eglu.key(m) : 'absent';", ["m": ["key": key, "code": key]])
    }

    /// How much of the page's bottom the phone bar covers: the page lays out
    /// above it, its own bottom bars sitting clear of it, and scrolls its
    /// end clear of it, while what is under the bar shows through its blur.
    ///
    /// Three things are told, and WebKit does none of them for another:
    ///
    /// - What is covered (`obscuredContentInsets`, from iOS 26), by which
    ///   it lays the page out in what shows: a bar the page fixes to its
    ///   bottom sits over the phone's bar, and `window.innerHeight` and
    ///   `100dvh` are what shows.
    /// - Room to scroll by, which is the scroll view's own inset. Told
    ///   only what is covered, WebKit still stops a page at the view's
    ///   bottom: the last 138 points of every page stayed under the bar
    ///   on an iPhone, its last line and whatever it ends on (a form's
    ///   button, a list's "more", the links at its foot).
    /// - The heights a page measures in its own units, `100svh` and
    ///   `100lvh`, which WebKit otherwise gives as the whole view's, bar
    ///   and all. The smallest and the largest are the same here: the bar
    ///   does not go away as the page scrolls, so the window never grows.
    ///   `100vh` stays the whole view's whatever is told, and there is no
    ///   setting for it: a page built to that height is laid out in the
    ///   window less the bar instead (standsClear).
    func obscure(bottom: CGFloat) {
        let scroll = view.scrollView
        if #available(iOS 26.0, *), view.obscuredContentInsets.bottom != bottom {
            view.obscuredContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        }
        if scroll.contentInset.bottom != bottom { scroll.contentInset.bottom = bottom }
        if scroll.verticalScrollIndicatorInsets.bottom != bottom { scroll.verticalScrollIndicatorInsets.bottom = bottom }
        // Only once the view has a size the bar leaves something of: WebKit takes an inset as
        // large as the view for a mistake and stops the app. Asked again at the next layout.
        guard viewportFoot != bottom, view.bounds.width > 0, view.bounds.height > bottom, view.frame.height > bottom else { return }
        viewportFoot = bottom
        let inset = UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        view.setMinimumViewportInset(inset, maximumViewportInset: inset)
    }

    /// How much of the view's bottom the page's own units of height were last told to leave out (obscure).
    private var viewportFoot: CGFloat = 0

    // MARK: Standing clear of the phone bar

    /// Whether the page is laid out in the window less the phone bar,
    /// standing clear of it, where it would otherwise have its foot under
    /// the bar with nothing to scroll it out by (FootRoom). The window lays
    /// the page out by this (Browser.layoutPanes).
    private(set) var standsClear = false
    /// The window's room for the page, bar and all, and how much of it the bar covers (room).
    private var footWindow: CGFloat = 0
    private var footCovered: CGFloat = 0
    private var footWait: Task<Void, Never>?
    /// When the page last ran under the bar again after standing clear, the latest last (weighFoot).
    private var footReturns: [Date] = []

    /// The window's room for the page and how much of it the bar covers, as
    /// the window lays its pages out. None covered where there is no such
    /// bar, and then the page never stands clear.
    func room(window: CGFloat, covered: CGFloat) {
        guard footWindow != window || footCovered != covered else { return }
        footWindow = window
        footCovered = covered
        weighFoot()
    }

    /// After the page's height may have changed. A page that has grown
    /// past the window runs under the bar again at once, so that none of a
    /// page to scroll is ever cut off. One that only fills the window
    /// stands clear once it has done so for a moment: a page on its way in
    /// is every height on the way, and the window is not to jump for each.
    private func weighFoot() {
        let clear = fitsWindow
        guard clear != standsClear else {
            footWait?.cancel()
            footWait = nil
            return
        }
        guard clear else {
            footWait?.cancel()
            footWait = nil
            standsClear = false
            footReturns = (footReturns + [Date()]).suffix(3)
            sampleFootSoon()
            host?.pageDidChange(self)
            return
        }
        // A page whose height goes by the window's in some way of its own could grow past the
        // window each time it is given the smaller one, and go back and forth for ever: after
        // three returns in ten seconds it is left under the bar, where it can at least be scrolled.
        if footReturns.count >= 3, let first = footReturns.first, Date().timeIntervalSince(first) < 10 { return }
        guard footWait == nil else { return }
        footWait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.footWait = nil
            guard self.fitsWindow, !self.standsClear else { return }
            self.standsClear = true
            self.sampleFootSoon()
            self.host?.pageDidChange(self)
        }
    }

    /// Whether the page, as tall as it is laid out now, is one to stand clear of the bar (FootRoom).
    private var fitsWindow: Bool {
        let scroll = view.scrollView
        guard scroll.zoomScale > 0, !desktopView else { return false }
        // As tall as it shows at the smallest it zooms to: a page laid out wide and shown small is as tall as it shows.
        let content = scroll.contentSize.height * scroll.minimumZoomScale / scroll.zoomScale
        return FootRoom.standsClear(content: content, window: footWindow, covered: footCovered, standing: standsClear)
    }

    /// Whether freezing would lose something typed: nil when the page can't
    /// be asked, which counts as yes.
    func holdsTyping(_ done: @escaping (Bool?) -> Void) {
        call("return window.__eglu ? window.__eglu.unsaved() : null;", [:]) { value in
            done(value as? Bool)
        }
    }

    /// A picture of the page as it is now.
    func picture(_ done: @escaping (UIImage?) -> Void) {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            done(nil)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        view.takeSnapshot(with: configuration) { image, _ in done(image) }
    }

    // MARK: Developer mode

    /// An element picked on the page, as the Mac's developer bar has it:
    /// the part of the view it covers, with 16 points round it, or nil for
    /// a page with nothing to pick or a hands-off host (element-pick.js in
    /// the app's own world). Its CSS pixels become the view's points by the
    /// visual viewport, as the bridge's points become CSS pixels: a desktop
    /// page scaled to fit and a pinch are in it (DeveloperMode.pickedRect).
    func pickElement() async -> CGRect? {
        guard !isHandsOff else { return nil }
        let value = try? await view.callAsyncJavaScript(Scripts.elementPick, arguments: [:],
                                                        in: nil, contentWorld: Page.world)
        return DeveloperMode.pickedRect(value, view: view.bounds.size)
    }

    /// The part of the view in `rect` (pickElement's) as a picture.
    func picture(of rect: CGRect) async -> UIImage? {
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
        guard measure == nil, !isHandsOff else { return }
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
            _ = try? await view.callAsyncJavaScript(WebKitScriptBridge.source + "\n" + Scripts.measure, arguments: ["guides": model.argument.merging(["notes": notes]) { _, new in new }],
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

    /// A colour from the page, the iPad's way (Decided 5): the next tap
    /// says where it is (measure.js), and the pixel there is read from a
    /// one-point snapshot.
    func pickColour() {
        guard let model = measure, !model.colourBusy else { return }
        model.colourBusy = true
        measureCall("if (window.__egluMeasure) window.__egluMeasure.sampleNext();", [:])
    }

    /// The tapped point's pixel, as sRGB, taken while measure.js has its
    /// overlay put away, which comes back once the picture is taken.
    private func sampled(at body: [String: Any]) {
        guard let model = measure else { return }
        let again = "if (window.__egluMeasure) window.__egluMeasure.sampled();"
        guard view.window != nil, let point = DeveloperMode.viewPoint(body, view: view.bounds.size) else {
            model.colourBusy = false
            measureCall(again, [:])
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1)
        view.takeSnapshot(with: configuration) { [weak self] image, _ in
            self?.measureCall(again, [:])
            guard let model = self?.measure else { return }
            model.colourBusy = false
            if let colour = image.flatMap(Self.colour(of:)) { model.colour = colour }
        }
    }

    /// A picture's colour, drawn into one pixel of sRGB, 8 bits a channel,
    /// whatever the snapshot's own order and space (a P3 screen's).
    static func colour(of image: UIImage) -> MeasureColour? {
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return MeasureColour(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }

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

    /// A small picture of the page as it shows, `width` points wide, for a
    /// card in the tab overview. Nil off screen, where WebKit draws nothing.
    func preview(width: CGFloat, _ done: @escaping (UIImage?) -> Void) {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
            done(nil)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(width))
        if desktopView, let shown = desktopShown, shown.width > 0, shown.height > 0 { configuration.rect = shown }
        view.takeSnapshot(with: configuration) { image, _ in done(image) }
    }

    /// The same, waited for.
    func preview(width: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            // Told once whichever way it goes: off screen at once, or by WebKit with the picture or without.
            preview(width: width) { continuation.resume(returning: $0) }
        }
    }

    // MARK: The colour along the top

    /// The colour the page's top edge shows, so the bars run on into it;
    /// the page's theme-color when there is nothing to see yet, or the page
    /// is off screen. A theme-color can differ from what is drawn (GitHub's
    /// is grey over a navy top), so what is drawn comes first: the page's
    /// own style where it says for sure (askGround), and otherwise a
    /// picture, as on a hands-off page.
    private func sampleColor() {
        // A picture holds the main thread: not while a finger is on the page
        // or it glides on (held), but once it is still.
        guard !held else {
            lookWhenStill()
            return
        }
        // The looks a scroll is getting end with an exact one of their own (sampleFootSoon).
        if footSampling == nil { sampleFoot(exact: true) }
        let theme = view.themeColor.flatMap { SiteColor($0) }
        guard view.bounds.width > 0, view.window != nil else {
            if let theme { setSiteColor(theme) }
            return
        }
        askGround(top: true, from: 0.1, to: 0.9) { [weak self] color, sure in
            guard let self else { return }
            if sure, let color {
                self.setSiteColor(color)
            } else if self.held {
                self.lookWhenStill()
            } else {
                self.pictureTop(theme: theme)
            }
        }
    }

    /// The page's top edge as a picture: its first two points, across.
    private func pictureTop(theme: SiteColor?) {
        guard view.bounds.width > 0, view.window != nil else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: view.bounds.width, height: 2)
        configuration.snapshotWidth = 64
        configuration.afterScreenUpdates = false
        view.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let color = image.flatMap({ SiteColor(picture: $0) }) ?? theme {
                self?.setSiteColor(color)
            }
        }
    }

    /// The colours looked at again once no finger is on the page and it has stopped (held).
    private func lookWhenStill() {
        heldLook?.cancel()
        heldLook = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.sampleColor()
        }
    }

    /// Soon after a change, and twice more for pages that draw their top
    /// after they have loaded (Figma's file view takes seconds).
    private func sampleSoon() {
        sampling?.cancel()
        sampling = sampleColor(after: [0.3, 1.5, 4.0])
    }

    /// The colours looked at after each of `waits`, in seconds, one after another.
    private func sampleColor(after waits: [Double]) -> Task<Void, Never> {
        Task { [weak self] in
            for delay in waits {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.sampleColor()
            }
        }
    }

    private func setSiteColor(_ color: SiteColor) {
        guard color != siteColor else { return }
        siteColor = color
        host?.pageDidChange(self)
    }

    // MARK: The colour under the phone bar

    /// The colour of what the page shows under the phone bar, so the bar's
    /// ground is the page's own, light on a light page and dark on a dark
    /// one whatever the system's appearance, and what the bar draws reads
    /// on it.
    ///
    /// The page's own style says first (askGround), just above the bar:
    /// asked in the page's process, nothing here waits for it, and it is
    /// all a scroll gets. Where it can't say for sure (a photo, a canvas,
    /// a gradient there) the exact look, once the page is still and no
    /// finger is on it (held), draws the view as it is on screen, under the
    /// bar and all; WebKit's own snapshot leaves out what the bar covers.
    /// Both pictures hold the main thread: four snapshots a second while a
    /// page scrolled, and three looks after every touch, held up the
    /// scroll and the finger put down to stop it.
    private func sampleFoot(exact: Bool) {
        guard let band = coveredBand() else { return }
        let width = max(view.bounds.width, 1)
        askGround(top: false, from: (band.minX + band.width * 0.1) / width,
                  to: (band.maxX - band.width * 0.1) / width) { [weak self] color, sure in
            guard let self else { return }
            if let color { self.setFootColor(color) }
            if exact, !sure, !self.held, let band = self.coveredBand() { self.pictureFoot(band) }
        }
    }

    /// The part of the view under the bar, in the view's own points: the
    /// desktop view lays the page out larger and moves it about. Nil where
    /// there is none to look at.
    private func coveredBand() -> CGRect? {
        guard footBand > 0, view.bounds.width > 0, view.window != nil, let stage = view.superview else { return nil }
        let covered = CGRect(x: 0, y: stage.bounds.height - footBand, width: stage.bounds.width, height: footBand)
        var band = view.convert(covered, from: stage).intersection(view.bounds)
        // A page that stands clear of the bar has nothing under it: the bar goes on from the page's last points.
        if standsClear, view.bounds.height >= 12 {
            band = CGRect(x: 0, y: view.bounds.height - 12, width: view.bounds.width, height: 12)
        }
        guard !band.isNull, band.width >= 1, band.height >= 1 else {
            // Past the page's edge there, in the desktop view: the page's own colour shows.
            if let color = view.underPageBackgroundColor.flatMap({ SiteColor($0) }) { setFootColor(color) }
            return nil
        }
        return band
    }

    /// What is under the bar as a picture: drawn small from the start, the
    /// view at a thirty-second of its width, placed so the band is what
    /// lands on the picture; WebKit's snapshot of the strip just above the
    /// bar where that comes out empty.
    private func pictureFoot(_ band: CGRect) {
        let scale = 32 / band.width
        let size = CGSize(width: 32, height: max(1, (band.height * scale).rounded()))
        let whole = CGRect(x: -band.minX * scale, y: -band.minY * scale,
                           width: view.bounds.width * scale, height: view.bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            view.drawHierarchy(in: whole, afterScreenUpdates: false)
        }
        if let color = SiteColor(picture: picture) {
            setFootColor(color)
            return
        }
        let strip = min(band.minY, 16 * band.height / footBand)
        guard strip >= 1 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: band.minX, y: band.minY - strip, width: band.width, height: strip)
        configuration.snapshotWidth = 32
        configuration.afterScreenUpdates = false
        view.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let color = image.flatMap({ SiteColor(picture: $0) }) { self?.setFootColor(color) }
        }
    }

    /// The colour the page paints along its top edge (`top`) or just above
    /// the phone bar, by its own style, at three places across, from `from`
    /// to `to` of its width: the ground of what is there, or of the nearest
    /// box round it that has one. `sure` where that is what shows at all
    /// three: one colour, of boxes with no picture in them or over them (a
    /// photo, a canvas, a gradient) and nothing half see-through. Nil and
    /// not sure on a hands-off page, which is never asked.
    private func askGround(top: Bool, from: CGFloat, to: CGFloat, done: @escaping (SiteColor?, Bool) -> Void) {
        guard !isHandsOff else {
            done(nil, false)
            return
        }
        view.callAsyncJavaScript(Self.ground, arguments: ["atTop": top, "from": Double(from), "to": Double(to)],
                                 in: nil, in: Page.world) { result in
            guard case .success(let value) = result, let found = value as? [Double], found.count == 4 else {
                done(nil, false)
                return
            }
            done(SiteColor(red: found[0] / 255, green: found[1] / 255, blue: found[2] / 255), found[3] == 1)
        }
    }

    private static let ground = """
        const view = window.visualViewport;
        const y = atTop ? 1 : (view ? view.offsetTop + view.height : innerHeight) - 2;
        const drawn = /^(img|video|canvas|iframe|embed|object|picture|svg)$/i;
        const at = (x) => {
            let sure = true;
            for (let node = document.elementFromPoint(x, y), first = true; node; node = node.parentElement, first = false) {
                if (first && drawn.test(node.tagName)) sure = false;
                const style = getComputedStyle(node);
                if (Number(style.opacity) < 1) sure = false;
                if (style.backgroundImage !== 'none') sure = false;
                const parts = /^rgba?\\(([^)]*)\\)$/.exec(style.backgroundColor);
                if (!parts) {
                    if (style.backgroundColor !== 'transparent') sure = false;
                    continue;
                }
                const [r, g, b, a = 1] = parts[1].split(/[\\s,\\/]+/).filter(Boolean).map(Number);
                if (a >= 0.99) {
                    // Under a box faded by its opacity, it shows mixed with what is behind.
                    for (let up = node.parentElement; up; up = up.parentElement) {
                        if (Number(getComputedStyle(up).opacity) < 1) sure = false;
                    }
                    return { rgb: [r, g, b], sure };
                }
                if (a > 0.01) sure = false;
            }
            return null;
        };
        const across = [from, (from + to) / 2, to].map((f) => at(Math.min(innerWidth - 1, Math.max(0, innerWidth * f))));
        if (across.some((one) => !one)) return null;
        const same = across.every((one) => one.rgb.every((v, i) => Math.abs(v - across[0].rgb[i]) < 3));
        const rgb = [0, 1, 2].map((i) => across.reduce((sum, one) => sum + one.rgb[i], 0) / across.length);
        return [...rgb, same && across.every((one) => one.sure) ? 1 : 0];
        """

    private func setFootColor(_ color: SiteColor) {
        // A shade's difference draws nothing again: this comes several times a second while the page scrolls.
        if let footColor, footColor.isNear(color) { return }
        footColor = color
        host?.pageDidChange(self)
    }

    /// Tells the document up now where the strip is (strip.js), putting the
    /// script in first if it came without it: the window learnt of the strip
    /// after the page's scripts were put in, or the document came before
    /// they changed. Never on a hands-off page, which gets no scripts.
    private func tellStrip() {
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed), view.url != nil else { return }
        // The strip alone where the script is in already: the script's
        // whole source again would be parsed again for nothing.
        let told = "if (!window.__egluStrip) return false;\n" + Scripts.strip(set: strip) + "\nreturn true;"
        view.callAsyncJavaScript(told, arguments: [:], in: nil, in: Page.world) { [weak self] result in
            guard let self, let strip = self.strip, case .success(let done) = result, done as? Bool == false else { return }
            self.view.callAsyncJavaScript(Scripts.strip + "\n" + Scripts.strip(set: strip), arguments: [:], in: nil,
                                          in: Page.world) { _ in }
        }
    }

    /// After what is under the bar may have changed.
    /// A scroll says so at every frame: while it goes on the page gets the
    /// quick look four times a second, and the exact one once it has been
    /// still a moment and no finger is on it.
    private func sampleFootSoon() {
        guard footBand > 0 else { return }
        footMoved = true
        guard footSampling == nil else { return }
        footSampling = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                if self.footMoved {
                    self.footMoved = false
                    self.sampleFoot(exact: false)
                } else if !self.held {
                    self.footSampling = nil
                    self.sampleFoot(exact: true)
                    return
                }
            }
        }
    }

    /// A finger on the page, or the page still gliding after one. No
    /// picture of the page is taken then: WebKit's snapshot and the drawn
    /// look both hold the main thread for milliseconds each (2 to 12 for a
    /// snapshot on a Mac's simulator, more on a phone), and the main thread
    /// is what moves the page and hears a finger put down to stop it.
    private var held: Bool {
        let scroll = view.scrollView
        return scroll.isTracking || scroll.isDecelerating
    }

    /// A touch on the page, which may open or close something the page draws
    /// over itself (a menu, a dialog, a sheet of its own): the colours along
    /// its top and under the phone bar are looked at again, as it comes in
    /// and once it has settled: a menu slides in over a few tenths of a
    /// second.
    func touched() {
        // Apart from a load's looks, which a touch must not cut short.
        touchSampling?.cancel()
        touchSampling = sampleColor(after: [0.15, 0.35, 1.0])
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

    // MARK: Messages from the bridge

    fileprivate func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, !isHandsOff,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String
        else { return }
        switch kind {
        case "focus":
            editing = body["editing"] as? Bool ?? false
        case "password":
            passwordField = body["present"] as? Bool ?? false
            // A sign-in page after all: none of it is kept in history.
            if passwordField { history.signInFound() } else { history.signInGone() }
            host?.pageDidChange(self)
        case "wheel":
            stats.webKitWheels = body["trusted"] as? Int ?? stats.webKitWheels
        case "hello":
            stats.userAgent = body["userAgent"] as? String
        case "cursor":
            pointer?.show(bridges.cursors ? PageCursor(message: body) : .system)
        case "context":
            let kept = body["kept"] as? Bool ?? true
            answerContext(kept: kept)
            if desktopView { desktopContextResult?(kept) }
        case "icons":
            let urls = (body["urls"] as? [String] ?? []).compactMap(URL.init(string:))
            SiteIcons.shared.learn(urls, for: view.url)
        default:
            break
        }
    }

    // MARK: When the page's process ends

    /// The page's content process ended (out of memory, most often), and
    /// the page is blank. On screen it loads again by itself, unless it has
    /// kept ending (CrashGuard); off screen it freezes, to load when opened.
    fileprivate func processEnded() {
        stats.processEnds += 1
        dropWheels()
        guard let host, host.isShowing(self) else {
            Session.shared.pages.processEnded(self)
            return
        }
        if crashes.shouldReload(at: Date()) {
            reload(byHand: false)
        } else {
            exhausted = true
            host.pageDidChange(self)
        }
    }
}

/// The bridge's messages, held weakly: the script controller keeps its
/// handlers for as long as it lives, and the page owns the controller.
private final class Relay: NSObject, WKScriptMessageHandler {
    weak var page: Page?

    init(_ page: Page) {
        self.page = page
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { page?.received(message) }
    }
}

// MARK: - WebKit's questions

extension Page: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // ⌘-click: where it goes opens in a tab of its own, and this page stays.
        var own = false
        if navigationAction.targetFrame?.isMainFrame == true {
            own = ownLoad
            ownLoad = false
        }
        let click = own ? .here : newTabChoice(for: navigationAction)
        if click != .here, let url = navigationAction.request.url,
           host?.page(self, openInNewTab: url, inFront: click == .inFront) == true {
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            beginNavigation(navigationAction.request.url)
            history.decided(navigationAction.navigationType, url: navigationAction.request.url)
            let chosen = chooseMode(for: navigationAction.request.url)
            // The user agent goes with the request as it was made: a page
            // that changes mode is asked for again, with the new one. Only a
            // plain load; a form sent or a step back isn't sent twice.
            if chosen != mode, let url = navigationAction.request.url, !HandsOff.covers(url),
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
               ![.backForward, .formSubmitted, .formResubmitted, .reload].contains(navigationAction.navigationType) {
                mode = chosen
                prepare(for: url)
                decisionHandler(.cancel, preferences)
                // Without the old request's user agent, so WebKit puts in the new one.
                var request = navigationAction.request
                request.setValue(nil, forHTTPHeaderField: "User-Agent")
                ownLoad = true
                webView.load(request)
                return
            }
            mode = chosen
        }
        preferences.preferredContentMode = mode == .desktop ? .desktop : .mobile
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        if let url = navigationAction.request.url, AppLink.isOne(scheme: url.scheme) {
            // mailto:, tel:, another app's link: theirs to open (AppLink).
            // A request for a new window has no frame to go in: it is the
            // page's own when the page itself asked, and not a frame in it.
            openElsewhere(url, clicked: navigationAction.navigationType == .linkActivated,
                          mainFrame: navigationAction.targetFrame?.isMainFrame ?? Self.pageAsked(navigationAction))
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            if let request = askingInLightOrDark(navigationAction) {
                decisionHandler(.cancel, preferences)
                ownLoad = true
                webView.load(request)
                return
            }
            prepare(for: navigationAction.request.url)
        }
        decisionHandler(.allow, preferences)
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
        view.traitCollection.userInterfaceStyle == .dark
    }

    /// Whether the page itself asked for a new window, and not a frame in
    /// it. WebKit's header promises the frame that asked and sometimes has
    /// none, which read as promised would stop the app.
    fileprivate static func pageAsked(_ action: WKNavigationAction) -> Bool {
        (action.value(forKey: "sourceFrame") as? WKFrameInfo)?.isMainFrame ?? false
    }

    /// A link for another app (AppLink): opened at once when the person
    /// clicked it; asked about first when the page went there by itself,
    /// which is how a site's "Open in app" button goes, and how an ad would.
    /// Named in the question is the site that asks, as in a page's alert.
    func reviewExternalRequest() {
        guard host?.isShowing(self) == true, let url = refusedAppLink else { return }
        refusedElsewhere = 0
        toldHeld = nil
        openElsewhere(url, clicked: false, mainFrame: true)
    }

    fileprivate func openElsewhere(_ url: URL, clicked: Bool, mainFrame: Bool) {
        switch AppLink.answer(clicked: clicked, mainFrame: mainFrame, showing: host?.isShowing(self) == true,
                              asking: askingElsewhere != nil, refusals: refusedElsewhere) {
        case .leave:
            if mainFrame, refusedElsewhere >= AppLink.refusalsHeard {
                refusedAppLink = url
                host?.pageDidChange(self)
                if toldHeld != url {
                    toldHeld = url
                    host?.page(self, held: url)
                }
            }
            closeIfOpenedForThis()
        case .open:
            hand(url)
        case .ask:
            guard let presenter = host?.presenter, presenter.presentedViewController == nil else { return }
            let asker = (committed ?? view.url)?.host ?? openerHost ?? String(localized: "This page")
            // An app eGlu knows by name; another by its kind of link, in the first line, which is what is read.
            let named = AppLink.applicationName(for: url.scheme)
            let opens = named.map { String(localized: "\(asker) wants to open \($0).") }
                ?? url.scheme.map { String(localized: "\(asker) wants to open the app for “\($0)” links.") }
                ?? String(localized: "\(asker) wants to open the app registered for this link.")
            let kind = named == nil ? nil : url.scheme.map { String(localized: "Link type: \($0)") }
            let alert = UIAlertController(title: String(localized: "Open in Another App?"),
                                          message: [opens, kind].compactMap { $0 }.joined(separator: "\n"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
                self?.refusedElsewhere += 1
                self?.refusedAppLink = url
                if let self { self.host?.pageDidChange(self) }
                self?.closeIfOpenedForThis()
            })
            alert.addAction(UIAlertAction(title: String(localized: "Open"), style: .default) { [weak self] _ in self?.hand(url) })
            askingElsewhere = alert
            presenter.present(alert, animated: true)
        }
    }

    /// To whichever app opens it; when none does, saying so, where a link
    /// that did nothing would look broken.
    private func hand(_ url: URL) {
        refusedAppLink = nil
        host?.pageDidChange(self)
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard let self else { return }
            let presenter = self.host?.isShowing(self) == true ? self.host?.presenter : nil
            self.closeIfOpenedForThis()
            guard !opened, let presenter else { return }
            let alert = UIAlertController(title: String(localized: "No App Opens This Link"),
                                          message: url.scheme.map { String(localized: "Nothing on this \(Device.name) opens \($0): links.") }
                                              ?? String(localized: "Nothing on this \(Device.name) opens these links."),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            presenter.present(alert, animated: true)
        }
    }

    /// A window a page opened only to go to another app has nothing to
    /// show, and goes, as one that closed itself would.
    private func closeIfOpenedForThis() {
        guard wasOpened, committed == nil else { return }
        host?.pageDidClose(self)
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
            ownLoad = true
            webView.load(again)
            return
        }
        // What WebKit can't show (a ZIP, an installer) and what the server says to save is a download.
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        let shows = navigationResponse.canShowMIMEType && !attachment
        if navigationResponse.isForMainFrame {
            // After any redirects: the host whose document this will be, and what it is, first known here
            // before the document commits, for the scripts prepare() chooses (a JSON page's view among them)
            // and for Handoff. A download leaves the kind of the page as it was.
            if shows { mimeType = navigationResponse.response.mimeType }
            prepare(for: navigationResponse.response.url)
            if shows { status.answered(navigationResponse.response) } else { status.dropped() }
        }
        decisionHandler(shows ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        host?.pageDidChange(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Session.shared.pages.navigationChanged(self, committed: true)
        cancelPendingDialog()
        loadState.commit()
        refusedAppLink = nil
        committed = webView.url
        status.committed(webView.backForwardList.currentItem)
        jsonView = nil
        history.committed(url: webView.url, title: webView.title, entry: webView.backForwardList.currentItem,
                          space: space, tab: tab)
        passwordField = false
        editing = false
        refusedElsewhere = 0
        toldHeld = nil
        // The old document's card went with it, unannounced.
        writingCardOpen = false
        // The scripts this document started with had the setting as it is now (prepare).
        toldOwnMenus = keepsOwnMenus
        // The last page's cursor goes with it; this one says its own.
        pointer?.show(.system)
        googleRefused = SignIn.googleRefused(webView.url)
        applyScrolling()
        endPull()
        // A document whose scripts were put in before the window knew of the strip.
        if strip != nil { tellStrip() }
        host?.pageDidChange(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        learnAbout()
        applyScrolling()
        learnJSONView()
        host?.pageDidChange(self)
        sampleSoon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let error = error as NSError
        // Stopped, replaced by another load, or turned into a download.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return }
        history.failed()
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorUserCancelledAuthentication, failure != nil {
            endPull()
            host?.pageDidChange(self)
            return
        }
        let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        loadState.fail(failedURL)
        status.failed()
        let reason = PageLoadFailure.message(domain: error.domain, code: error.code)
        failure = loadState.failed?.host.map { "\($0): \(reason)" } ?? reason
        endPull()
        host?.pageDidChange(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processEnded()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // A server's own sign-in (Basic, Digest, NTLM): a company's single
        // sign-on behind it is one way in when Google's isn't.
        let method = challenge.protectionSpace.authenticationMethod
        let asks = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                    NSURLAuthenticationMethodNTLM].contains(method)
        guard asks else { return completionHandler(.performDefaultHandling, nil) }
        guard challenge.previousFailureCount < 3 else {
            failure = String(localized: "The website did not accept the name or password after three attempts. Reload to try another sign-in.")
            loadState.fail(nil)
            host?.pageDidChange(self)
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        guard host?.isShowing(self) == true, let presenter = host?.presenter,
              presenter.presentedViewController == nil else {
            failure = String(localized: "This website needs you to sign in. Open this tab and reload to sign in.")
            loadState.fail(nil)
            host?.pageDidChange(self)
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        Dialogs.credentials(for: challenge.protectionSpace, previousFailures: challenge.previousFailureCount, on: presenter) { credential in
            if let credential {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.adopt(download, for: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.adopt(download, for: self)
    }
}

extension Page: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Another app's link asked for in a window of its own (window.open,
        // which WebKit doesn't ask about first): theirs to open, from this
        // page, with no tab made for a page that will never be.
        if let url = navigationAction.request.url, AppLink.isOne(scheme: url.scheme) {
            openElsewhere(url, clicked: navigationAction.navigationType == .linkActivated,
                          mainFrame: Self.pageAsked(navigationAction))
            return nil
        }
        let made = host?.page(self, open: configuration, for: navigationAction, features: windowFeatures)
        // The new page knows it was opened and by whom, should it turn out
        // to be for another app: a window opened empty, then sent there.
        if let child = (made as? PageView)?.page, child !== self {
            child.wasOpened = true
            child.openerHost = (committed ?? view.url)?.host
        }
        return made
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.pageDidClose(self)
    }

    /// A link's menu on a long press or a secondary click is the app's, as
    /// Safari's is its own: the link in a tab of its own, in front or
    /// behind, and its address to copy or share. WebKit asks about links
    /// and nothing else: a picture that isn't one gets WebKit's own menu
    /// (share, save to Photos, copy), which the app has no say in. The
    /// link's menu never shows on a hands-off page, and never over a menu of
    /// the page's own:
    ///
    /// - A page that wants no callout says so in its style
    ///   (-webkit-touch-callout), and WebKit then never asks.
    /// - A site in the list of those that keep their own menus (OwnMenus:
    ///   Figma and its like, and whatever Settings adds) gets none, by a
    ///   finger or a click.
    /// - A secondary click is also the page's, as a contextmenu event. The
    ///   bridge says whether the page kept that event (answerContext), and
    ///   the menu shows only if it didn't. After a secondary click it waits
    ///   for that answer, and none in time is taken as kept: no menu rather
    ///   than two. After a finger held down, which sends the page no such
    ///   event, it waits only a moment, in case the press was a click after
    ///   all that the pointer's watcher didn't hear.
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        guard !isHandsOff, !keepsOwnMenus, let url = elementInfo.linkURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            completionHandler(nil)
            return
        }
        // No preview of the page behind the link: it would load it, cookies and all, for a look.
        let menu = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            self?.linkMenu(for: url, suggested: suggested)
        }
        // No pointer reaches an iPhone's page: nothing to wait for.
        guard UIDevice.current.userInterfaceIdiom != .phone else {
            completionHandler(menu)
            return
        }
        // Whoever was still waiting from a click before gets no menu.
        answerContext(kept: true, record: false)
        let now = CACurrentMediaTime()
        let clicked = pointer?.secondaryClick(within: 1)
        if let answer = contextAnswer, answer.time >= (clicked ?? now - 0.3) {
            completionHandler(answer.kept ? nil : menu)
            return
        }
        contextWaiting = (menu, now, completionHandler)
        DispatchQueue.main.asyncAfter(deadline: .now() + (clicked != nil ? 0.4 : 0.12)) { [weak self] in
            // Still this press's, not a later one's that has its own wait.
            guard self?.contextWaiting?.since == now else { return }
            self?.answerContext(kept: clicked != nil, record: false)
        }
    }

    /// The page's answer to a secondary click, from the bridge: it kept the
    /// context menu to itself, or left it. Whichever of the two comes first,
    /// this or WebKit asking for the link's menu, waits for the other.
    private func answerContext(kept: Bool, record: Bool = true) {
        if record { contextAnswer = (CACurrentMediaTime(), kept) }
        guard let waiting = contextWaiting else { return }
        contextWaiting = nil
        waiting.done(kept ? nil : waiting.menu)
    }

    /// A tap on the lifted link goes there, as a tap on the link would.
    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating) {
        guard let url = elementInfo.linkURL else { return }
        animator.addCompletion { [weak self] in self?.load(url) }
    }

    /// `suggested` is what WebKit would have shown. One of its actions is
    /// kept, where the link is a picture: the picture into Photos, which is
    /// WebKit's to do. It is found by the name WebKit gives it, and a
    /// WebKit that names it otherwise leaves the menu without it.
    private func linkMenu(for url: URL, suggested: [UIMenuElement]) -> UIMenu {
        let savePicture = suggested.first { ($0 as? UIAction)?.identifier.rawValue == "WKElementActionTypeSaveImage" }
        let front = UIAction(title: String(localized: "Open in New Tab"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            guard let self else { return }
            _ = self.host?.page(self, openInNewTab: url, inFront: true)
        }
        let behind = UIAction(title: String(localized: "Open in Background"), image: UIImage(systemName: "square.on.square")) { [weak self] _ in
            guard let self, self.host?.page(self, openInNewTab: url, inFront: false) == true else { return }
            // Nothing on screen moves for a tab opened behind but the tabs' count: a tap says it went.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        // Copied or shared without the tags that follow whoever opens it (Tracking.clean): it is going to someone.
        let copy = UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self, let host = self.host else { return UIPasteboard.general.url = Tracking.clean(url) }
            host.page(self, copy: url)
        }
        let share = UIAction(title: String(localized: "Share…"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            self.host?.page(self, share: url)
        }
        // A link to a file eGlu reads offers it to Handoff too ("Handoff
        // Linked File"), where the window's Handoff is on.
        let off = UIAction(title: String(localized: "Handoff Linked File"),
                           image: UIImage(systemName: "arrowshape.turn.up.right")) { [weak self] _ in
            guard let self else { return }
            self.host?.page(self, handOffFileAt: url)
        }
        // Never from a hands-off page: nothing is fetched through its view.
        let files = DocumentSource.linkExtensions.contains(url.pathExtension.lowercased())
            && host?.takesHandoffFiles == true && !isHandsOff ? [off] : []
        // A pop-up window has no tabs to offer.
        let tabs = host?.opensTabs == true ? [front, behind] : []
        return UIMenu(title: Destination.pretty(url), children: [
            UIMenu(options: .displayInline, children: tabs),
            UIMenu(options: .displayInline, children: [copy, share]),
            UIMenu(options: .displayInline, children: files),
            UIMenu(options: .displayInline, children: savePicture.map { [$0] } ?? []),
        ])
    }

    private func pageDialog(show: @escaping () -> Void, cancel: @escaping () -> Void) {
        cancelPendingDialog()
        pendingDialog = (show, cancel)
        host?.pageDidChange(self)
        reviewPendingDialog()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        pageDialog(show: { [weak self] in
            guard let presenter = self?.host?.presenter else { return completionHandler() }
            Dialogs.alert(message, from: frame, on: presenter, done: completionHandler)
        }, cancel: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        pageDialog(show: { [weak self] in
            guard let presenter = self?.host?.presenter else { return completionHandler(false) }
            Dialogs.confirm(message, from: frame, on: presenter, done: completionHandler)
        }, cancel: { completionHandler(false) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        pageDialog(show: { [weak self] in
            guard let presenter = self?.host?.presenter else { return completionHandler(nil) }
            Dialogs.prompt(prompt, defaultText: defaultText, from: frame, on: presenter, done: completionHandler)
        }, cancel: { completionHandler(nil) })
    }

}

/// A wheel event for the page: one step of a scroll or a pinch, or several
/// of the same kind added up while the page was busy with the one before.
private struct Wheeling: WheelStep {
    var point: CGPoint
    var dx: Double
    var dy: Double
    let modifiers: UIKeyModifierFlags
    let zoom: Bool
    let guarded: String
    /// Whether it may go to what is further along the cursor's column (Page.wheel).
    let reaching: Bool
    /// Who hears what the page did with it.
    var done: [(String?) -> Void]

    /// The same kind of event, so the two add up to one: a pinch's steps
    /// add as a scroll's do (Pinch.wheelDelta).
    func joins(_ other: Wheeling) -> Bool {
        modifiers == other.modifiers && zoom == other.zoom && guarded == other.guarded && reaching == other.reaching
    }

    /// At the later one's place, with both to tell.
    mutating func add(_ other: Wheeling) {
        point = other.point
        dx += other.dx
        dy += other.dy
        done += other.done
    }
}

