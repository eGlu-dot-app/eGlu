import Combine
import GameController
import PadCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The tab a sideways drag on the phone bar brings in: from the right (1)
/// or the left (-1), and whether the bar will say its name or its address.
struct SlideNeighbour: Equatable {
    let tab: TabRecord
    let side: CGFloat
    let titled: Bool
}

/// How far the page on screen has loaded. Kept apart from the window's
/// model: a load says so dozens of times, and only the loading line needs
/// to hear each one.
@MainActor
final class LoadProgress: ObservableObject {
    @Published var fraction = 0.0
}

/// A sideways drag on the phone bar (PageSlide.drag): how far the address
/// has gone with the finger, and the tab coming in beside it. Kept apart
/// from the window's model: it changes with every move of the finger, and
/// only the bar's address row follows it.
@MainActor
final class BarSlide: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var coming: SlideNeighbour?
}

/// The side the system's vertical bar stands on, on the iPhone Duo.
enum StripEdge: Equatable {
    case leading
    case trailing

    /// The side the traits name; nil where there is no vertical bar (every
    /// device before iOS 27.1, every iPhone and iPad, the Duo open upright).
    init?(of traits: UITraitCollection) {
        guard #available(iOS 27.1, *) else { return nil }
        switch traits.verticalBarEdge {
        case .leading: self = .leading
        case .trailing: self = .trailing
        default: return nil
        }
    }
}

/// What a window's bars show, kept up to date from its page.
@MainActor
@Observable
final class WindowModel {
    var spaceID: UUID {
        // Another space's bookmarks are not the ones asked for: they go.
        didSet { if spaceID != oldValue, bookmarksOpen { bookmarksOpen = false } }
    }
    var tabID: UUID?
    var url: URL?
    var title = ""
    var loading = false
    let load = LoadProgress()
    var canGoBack = false
    var canGoForward = false
    var secure = false
    var signIn = false
    /// The address must show, whatever Settings says: a sign-in page, a page
    /// that failed, a new tab (AddressVisibility).
    var addressRequired = false
    /// The tab on screen along the top says where it is rather than what it
    /// is called (Settings, and always on a sign-in page).
    var showsAddress = false
    var editingAddress = false {
        // However typing ends (Return, Escape, another tab), what the Browser
        // keeps for it goes too (typingEnded).
        didSet { if !editingAddress { typingEnded?() } }
    }
    /// Told whenever typing an address ends, or is set to have ended.
    @ObservationIgnored var typingEnded: (() -> Void)?
    /// The pinned tab's button's panel, for the buttons on the phone bar and the strip (PinnedControl).
    @ObservationIgnored weak var pinned: PinnedControl?
    /// A phone's bar has made room for the keyboard: only the address, over
    /// it. True with editingAddress but for the keyboard's first coming in a
    /// run of the app, when the bar waits for it (Browser.keyboardHasStarted)
    /// and keeps its tools until then.
    var barRidesKeyboard = false
    /// Counts the turns at the address field: each one starts the field
    /// over, a second ⌘T while it is already open included, which
    /// editingAddress alone, true before and after, would not say.
    var addressTurn = 0
    /// What was typed in one field, for the other to start from: the window
    /// changed layout while it was typed (Browser.refreshChrome). Taken, and
    /// cleared, by the field that begins next.
    var carriedAddress: String?
    /// The address field was opened to list everything (a new tab, or
    /// Command.everything): it starts empty, over every tab, space, command
    /// and setting, where it otherwise starts with the page's address and
    /// nothing under it.
    var listsEverything = false
    /// What the address bar offers under the address being typed.
    let suggestions = Suggestions()
    var banner: Banner?
    /// The colour along the top of the page, which the bars take on.
    var siteColor: SiteColor?
    /// The colour under a phone's bar, which that bar and the rows over it
    /// take on; nil where the page has none to give (a new tab).
    var footColor: SiteColor?
    /// The page is one of the space's bookmarks (the star in the address).
    var bookmarked = false
    /// A phone-width window: the bars at the bottom, as on an iPhone (PhoneBar).
    var phone = false
    /// A phone-width window with the system's vertical bar beside it, the
    /// side it stands on: the iPhone Duo closed, or one of two apps side by
    /// side on it (Docs/iPhoneDuoDesign.md §3). Nil anywhere else.
    var strip: StripEdge?
    /// The window can open another (Device.makesWindows): New Window and
    /// Open in New Window show only where it can.
    var makesWindows = false
    /// The page on screen is its mobile site (SiteMode).
    var mobileSite = false
    /// The page is in the iPhone's desktop view (DesktopPad), or could be.
    var desktopView = false
    var canDesktopView = false
    /// Handoff is on in Settings and the page on screen can be handed off:
    /// it has an address, and it is not a hands-off page.
    var canHandoff = false
    /// Ads and trackers blocked on the page on screen: true or false where
    /// its site's switch applies, nil where it doesn't (no page, a hands-off
    /// page, blocking off in Settings).
    var blocking: Bool?
    /// The site on screen keeps its own context menus, the app's link menu
    /// off there (OwnMenus); nil where there is no site to say it of.
    var ownMenus: Bool?
    /// Grammar checking on for the site on screen, or off for it
    /// (Settings › Writing › Sites); nil where there is no site it
    /// applies to (no page, a hands-off page, checking off in Settings).
    var writing: Bool?
    /// A tab of the row along the top or of the sidebar, while it is
    /// dragged (iOS 27): the page shows where it can go beside it (SplitDrop).
    var draggedTab: UUID?
    /// The split exists but the window is too narrow to show both pages.
    var narrowSplit = false
    /// The page on screen's JSON view, for the page's menu where the bar
    /// has no Raw: drawn, put away by Raw, or none (Page.jsonView).
    var jsonView: Bool?
    /// The measuring tool runs on the page on screen: its command says Stop.
    var measuring = false
    var pendingPageDialog = false
    var refusedExternalLink = false
    /// Writing's card is open on the page on screen: ⌃⌥G takes its first
    /// suggestion then (Command.acceptWritingSuggestion).
    var writingCardOpen = false
    /// The space's bookmarks are out over the sidebar's list, as a popover
    /// is (SideBookmarksPanel), till one is chosen or they are put away.
    var bookmarksOpen = false
    /// Where the bookmarks are in the window (SideBookmarksPanel): a touch
    /// or a click anywhere else puts them away (KeyedPress).
    @ObservationIgnored var bookmarksFrame = CGRect.null
    /// The keys held as the last touch or click in the window began, and
    /// when (KeyedPress): a ⌘-click on a bookmark opens it in a new tab.
    @ObservationIgnored var lastPress: (keys: UIKeyModifierFlags, at: Date) = ([], .distantPast)
    /// What a command just did that leaves nothing to see, said for a
    /// moment over the page's top right (ActionToast, WindowToast).
    var toast: ActionToast?
    let slide = BarSlide()

    /// The touch or click that is ending now began with ⌘ held.
    var commandClick: Bool {
        lastPress.keys.contains(.command) && Date().timeIntervalSince(lastPress.at) < 2
    }

    init(spaceID: UUID) {
        self.spaceID = spaceID
    }

    /// Sets a value only when it is another. A page says the same things
    /// many times over as it loads, and an assignment, changed or not,
    /// draws again whatever watches the model.
    func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<WindowModel, Value>, to value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    /// The page, or something on it, came over a connection anyone on the
    /// way can read. An http address says so at once; for the rest, WebKit
    /// knows only once the page has loaded, so a page still loading isn't
    /// marked, rather than marked and then unmarked a moment later.
    /// The words, when the page is a search with the chosen engine: the
    /// address shows them in its place (Destination.searchWords).
    var searchWords: String? {
        url.flatMap { Destination.searchWords(in: $0, engine: Session.shared.preferences.engine) }
    }

    var insecure: Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "http" || (!loading && !secure)
    }
}

/// A line under the address bar that something needs saying.
enum Banner: Equatable {
    /// Google refused to sign in here (SignIn.googleRefused).
    case googleRefused
    /// The page's process kept ending (CrashGuard).
    case exhausted
    case failed(String)
}

/// One window: a row of tabs, an address bar when it is wanted, and a page.
///
/// The page gets everything it can: the window's whole width, the trackpad
/// (Pointer), the keys (PageView, Menus), the focus whenever the window
/// becomes active. The browser's own shortcuts are ⌃⌥ ones (Menus), out of
/// the way of any page's, but for the keys every browser keeps (⌘T and the like).
/// Calls `changed` a turn after anything `read` reads of an @Observable
/// model has changed, and after every change from then on, for as long as
/// `owner` is there: what a Combine sink on a @Published value did.
@MainActor
func watch<Owner: AnyObject & Sendable>(_ owner: Owner, read: @escaping @MainActor @Sendable (Owner) -> Void,
                                        changed: @escaping @MainActor @Sendable (Owner) -> Void) {
    withObservationTracking {
        read(owner)
    } onChange: { [weak owner] in
        // Told as the value is about to change: read once it has. Held from
        // here to then, and not before: the model keeps this until it changes.
        let held = owner
        DispatchQueue.main.async {
            guard let held else { return }
            changed(held)
            watch(held, read: read, changed: changed)
        }
    }
}

@MainActor
final class Browser: UIViewController, PageHost, UIAdaptivePresentationControllerDelegate, UIDocumentPickerDelegate,
    UIGestureRecognizerDelegate {
    let model: WindowModel
    /// The page on screen; with two side by side, the one with the keys,
    /// which the bars show and act on.
    private(set) var page: Page?
    /// The other pane, when the tab on screen is split with another tab.
    private(set) var partner: Page?
    private var firstTab: UUID?
    private var connected = true

    private let stack = UIStackView()
    private let stage = Stage()
    private let picture = UIImageView()
    private let partnerPicture = UIImageView()
    private let divider = SplitDivider()
    /// A line of the space's colour round the card with the keys, while
    /// there are two, as the Mac's.
    private let focusRing = UIView()
    /// The developer bar across each pane's page, as the Mac's: one for
    /// the page on screen and one for the page beside it (Decided 2).
    private let developerBar = DeveloperBar()
    private let partnerBar = DeveloperBar()
    /// The measuring tool's card at the bottom of its page's area, while it
    /// runs (MeasurePanel); the model it shows, to know when another's begun.
    private var measureCard: UIHostingController<MeasurePanel>?
    private var measureModel: MeasureModel?
    /// Whether each pane's page was developer mode's at the last layout.
    private var laidDeveloper = false
    private var laidPartnerDeveloper = false
    /// Where a tab dragged from the row or the sidebar can go beside the
    /// page, over the pages while one is; and the tab it is (SplitDrop).
    private let splitDrop = SplitDrop()
    private var droppingTab: UUID?
    /// Where the divider is while it is dragged, before the workspace hears;
    /// and whether even has taken it (dragDivider).
    private var dragRatio: Double?
    private var dragSnapped = false
    private let evenTap = UIImpactFeedbackGenerator(style: .light)
    private var topBar: UIHostingController<TopBar>?
    /// The tabs down the window's side, in place of the row along the top
    /// and the address bar (Settings › Tabs).
    private var sideTabs: UIHostingController<SideTabs>?
    /// What moves the stack, the sidebar and the phone bar between layouts.
    private let chromeConstraints = ChromeConstraints()
    /// Wider than a phone, the window is the Mac's, with the tabs along the
    /// top or in the sidebar: the page a card a bezel in from the window's
    /// edges and from the sidebar, with round corners and a soft shadow,
    /// standing on the space's colour (the window's ground, WindowGround)
    /// as the sidebar and the row along the top do.
    private var carded = false
    /// The space's colour the window's views were last given (SpaceColorTrait).
    private var shownColour: SpaceColor?
    private var windowGround: UIHostingController<WindowGround>?
    /// The card's shadows, as the Mac's: a soft one under it and a tight one
    /// at its edge, each a view of its own behind the page, which is cut to its corners.
    private let cardShadow = UIView()
    private let cardEdge = UIView()
    private var phoneBar: UIHostingController<PhoneBar>?
    /// The iPhone Duo strip's tools, made the first time the window has a strip (showStrip).
    private var stripItems: StripItems?
    /// The bars as they were last put on screen (show(_:)).
    private var shownLayout: ChromeLayout?
    /// The cursor and the trackpad over a page in the iPhone's desktop view.
    private var desktopPad: DesktopPad?
    /// The last tab a ⌘-click opened behind, and the tab it came from.
    private var openedBehind: (from: UUID, opened: UUID)?
    /// Whether the page on screen is bookmarked, as last worked out, and
    /// what it was worked out from (refreshChrome).
    private var starCheck: (url: URL?, bookmarks: [Bookmark], found: Bool)?
    private weak var barSwipe: BarSwipe?
    /// The bar's swipe, and the page sliding to the tab beside with it.
    private lazy var pageSlide = PageSlide(model: model, stage: stage, stack: stack) { [weak self] tab in
        guard let self else { return }
        show(tab: tab, inSpace: model.spaceID)
    }
    /// The phone's tabs, while they show or the bar is turning into them.
    private var tabSheet: TabSheet?
    /// What the tabs were left for, done once they have gone: a new tab's
    /// typing waits for the bar to be back.
    private var afterTabs: BarAction?
    /// Behind the phone bar: the page through it, blurred more the lower it is (BarBackdrop).
    private let barBackdrop = BarBackdrop()
    /// Behind the iPhone Duo's strip, beside the page: the page's edge on
    /// that side drawn on across it (placeStripGround).
    private let stripGround = UIImageView()
    private var addressBar: UIHostingController<AddressBar>?
    /// The space's bookmarks under the bars, where the tabs are along the top (BookmarksStrip).
    private var bookmarksStrip: UIHostingController<BookmarksStrip>?
    private var bannerBar: UIHostingController<BannerBar>?
    private var empty: UIHostingController<EmptySpace>?
    private var start: UIHostingController<StartPage>?
    private var diagnostics: UIHostingController<DiagnosticsView>?
    private var pendingBookmarkImport: BookmarkImportOutcome?
    /// The hinge, heard while the diagnostics panel shows (iPhone Duo).
    private var hingeWatch: UIInteraction?
    /// The address bar's suggestions on a phone, over the bar
    /// (placeSuggestions). On iPad they are part of the command bar.
    private var suggestionList: UIHostingController<SuggestionList>?
    private var suggestionHeight: NSLayoutConstraint?
    /// The handoff under way, from Handoff being asked for until its share
    /// sheet closes (handoff), and the model asked what kind of page it is:
    /// the browser's own, made when the first handoff is.
    private var handingOff: HandoffJob?
    /// A handoff was asked for and is not yet on screen: a second ask meanwhile is the same one.
    private var startsHandoff = false
    /// What to do if the handoff's guide is put away without a button.
    private var guideClosed: (() -> Void)?

    /// The command bar, on iPad: the address field and its rows, floating
    /// over the page while an address is typed (placeCommandBar).
    private var commandBar: UIHostingController<CommandBar>?
    private var commandBarTop: NSLayoutConstraint?
    private var commandBarShown = false
    private weak var addressDismissTap: UITapGestureRecognizer?
    private var topBarHeight: NSLayoutConstraint?
    private var addressBarHeight: NSLayoutConstraint?
    private var bookmarksBarHeight: NSLayoutConstraint?
    /// The new tab the command bar is open for (⌘T, +) and the tab it was
    /// opened from, until typing ends: the new tab goes again if the row
    /// taken wasn't an address for it (leave).
    private var madeForBar: MadeTab?

    /// A tab made to type an address in, and where the window was before.
    struct MadeTab {
        let tab: UUID
        let from: UUID?
    }
    private var subscriptions: Set<AnyCancellable> = []
    /// Each download's phase as last seen (downloadsChanged); nil before the first look.
    private var downloadPhases: [UUID: DownloadRecord.Phase]?

    var isConnected: Bool { connected }

    /// The tabs this window has on screen: one, or a split's two.
    var shownTabs: [UUID] {
        [model.tabID, partner?.tab].compactMap { $0 }
    }

    func shows(_ tab: UUID) -> Bool {
        model.tabID == tab || partner?.tab == tab
    }

    init(state: WindowState) {
        let workspace = Session.shared.workspace
        let space = state.space.flatMap { workspace.space($0) } ?? workspace.firstSpace
        model = WindowModel(spaceID: space.id)
        // The tab the window had, if the space still has it: one closed since
        // (the system keeps a window's state a while behind) would leave
        // the window showing nothing, with tabs to show.
        firstTab = state.tab.flatMap { workspace.tab($0) == nil ? nil : $0 } ?? space.selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var state: WindowState {
        WindowState(space: model.spaceID, tab: model.tabID)
    }

    override func loadView() {
        let root = BrowserView()
        root.constraintsUpdated = { [weak self] in self?.placeSidebar(animated: true) }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.UI.ground
        Session.shared.register(self)
        build()
        watch(self, read: { _ = $0.model.draggedTab }, changed: { $0.armSplitDrop() })
        Session.shared.$workspace
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.workspaceChanged() }
            .store(in: &subscriptions)
        Session.shared.$preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChrome() }
            .store(in: &subscriptions)
        // Handoff is in the menus only while the device has Apple Intelligence.
        Session.shared.$hasIntelligence
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChrome() }
            .store(in: &subscriptions)
        // A download starting or finishing, said in a toast on a phone, whose bar has no downloads button.
        Downloads.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.downloadsChanged(items) }
            .store(in: &subscriptions)
        // The keyboard's first coming in a run of the app (keyboardHasStarted).
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .sink { [weak self] _ in self?.keyboardStarted() }
            .store(in: &subscriptions)
        for notification in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            NotificationCenter.default.publisher(for: notification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.desktopAccessibilityChanged() }
                .store(in: &subscriptions)
        }
        // A turn later, once the rows have changed rather than as they are about to.
        model.suggestions.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.placeSuggestions() }
            .store(in: &subscriptions)
        // However typing ends (Return, Escape, another tab), its rows go with
        // it, and the next turn at the field starts with the page's address.
        model.typingEnded = { [weak self] in
            guard let self else { return }
            keyboardWait?.cancel()
            keyboardWait = nil
            keyboardWaitOver = false
            model.suggestions.end()
            if model.listsEverything { model.listsEverything = false }
            madeForBar = nil
        }
        // A window that turns phone-width (an iPhone, the Duo folding, a narrow
        // iPad window) moves its bars to the bottom, and back.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.topBarHeight?.constant = Metrics.bar
            self.addressBarHeight?.constant = Metrics.bar
            self.bookmarksBarHeight?.constant = BookmarksStrip.height
            self.shownLayout = nil
            self.refreshChrome()
        }
        // And one that gains or loses the iPhone Duo's vertical bar, or has it on the other side.
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (self: Self, _: UITraitCollection) in
                self.refreshChrome()
            }
        }
        show(tab: firstTab, inSpace: model.spaceID, userInitiated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resumeWelcomeIfNeeded()
        askAboutWritingIfNeeded()
        if let pendingBookmarkImport { showBookmarkImport(pendingBookmarkImport) }
    }

    /// Only one window welcomes, however many open at a first launch.
    private static weak var welcomeOwner: Browser?

    /// The first launch's welcome (Welcome.swift), over the first window. It
    /// can't be swiped away by accident; Skip and its last button end it.
    func resumeWelcomeIfNeeded() {
        if !Session.shared.needsWelcome { page?.reviewPendingDialog() }
        guard connected, Session.shared.needsWelcome, Browser.welcomeOwner == nil,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              presentedViewController == nil else { return }
        Browser.welcomeOwner = self
        let welcome = UIHostingController(rootView: Welcome(session: Session.shared, spaceID: model.spaceID) { [weak self] in
            guard let self, Browser.welcomeOwner === self else { return }
            Task { [weak self] in
                guard let self else { return }
                guard await Session.shared.finishWelcome(), Browser.welcomeOwner === self else { return }
                self.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    if Browser.welcomeOwner === self { Browser.welcomeOwner = nil }
                    self.focusPage()
                    self.page?.reviewPendingDialog()
                }
            }
        }.safeAreaInset(edge: .top, spacing: 0) { WorkspaceSaveStatusView() })
        welcome.modalPresentationStyle = .formSheet
        welcome.preferredContentSize = CGSize(width: 520, height: 680)
        welcome.isModalInPresentation = true
        present(welcome, animated: true)
    }

    /// The once-only ask about grammar checking (WritingQuestion): where
    /// the welcome is over without having asked (an existing workspace's
    /// update), the question was never answered, this window owns the
    /// welcome's role, and the device can check (Decided 7). It can't be
    /// swiped away by accident; Not Now and Check My Writing end it.
    func askAboutWritingIfNeeded() {
        guard connected, presentedViewController == nil,
              WritingAsk.decision(welcomePending: Session.shared.needsWelcome,
                                  asked: WritingAsked.wasAsked) == .sheet,
              WritingChecker.canCheck,
              Browser.welcomeOwner === self || Browser.welcomeOwner == nil,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        Browser.welcomeOwner = self
        // The view's buttons mark WritingAsked themselves, either answer.
        let question = UIHostingController(rootView: WritingQuestion(offersOtherApps: false) { [weak self] _ in
            Session.shared.preferences.writing = true
            self?.dismiss(animated: true)
        } notNow: { [weak self] in
            self?.dismiss(animated: true)
        }
        // Room at its sides, as the Mac's sheet has: on a phone the sheet is the screen's width.
        .padding(.horizontal, 28))
        question.modalPresentationStyle = .formSheet
        question.preferredContentSize = CGSize(width: 460, height: 420)
        question.isModalInPresentation = true
        present(question, animated: true)
    }

    /// The window is gone (its scene was closed): its page stays, off
    /// screen now, for the Freezer to decide about.
    func disconnect() {
        connected = false
        let ownedWelcome = Browser.welcomeOwner === self
        if ownedWelcome { Browser.welcomeOwner = nil }
        detach()
        Session.shared.unregister(self)
        Session.shared.pages.enforce()
        if ownedWelcome {
            DispatchQueue.main.async {
                for browser in Session.shared.allBrowsers { browser.resumeWelcomeIfNeeded() }
            }
        }
    }

    // MARK: Layout

    private func build() {
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        chromeConstraints.pinStack(stack, in: view)

        let session = Session.shared
        // Behind everything: the window's ground, shown with the sidebar.
        let ground = embed(WindowGround(session: session, window: model), inStack: false)
        ground.view.translatesAutoresizingMaskIntoConstraints = false
        ground.view.isHidden = true
        view.sendSubviewToBack(ground.view)
        NSLayoutConstraint.activate([
            ground.view.topAnchor.constraint(equalTo: view.topAnchor),
            ground.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ground.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ground.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        windowGround = ground
        // Stretched across from a picture one point wide, smoothly (Page.stripEdge).
        stripGround.contentMode = .scaleToFill
        stripGround.isUserInteractionEnabled = false
        stripGround.isHidden = true
        stripGround.accessibilityElementsHidden = true
        view.insertSubview(stripGround, aboveSubview: ground.view)
        for (shadow, opacity, radius, drop) in [(cardShadow, Float(0.08), CGFloat(14), CGFloat(6)), (cardEdge, 0.16, 1, 0.5)] {
            shadow.isUserInteractionEnabled = false
            shadow.isHidden = true
            shadow.layer.shadowColor = UIColor.black.cgColor
            shadow.layer.shadowOpacity = opacity
            shadow.layer.shadowRadius = radius
            shadow.layer.shadowOffset = CGSize(width: 0, height: drop)
            view.insertSubview(shadow, belowSubview: stack)
        }
        let side = embed(SideTabs(session: session, window: model) { [weak self] in self?.act($0) }, inStack: false)
        side.view.translatesAutoresizingMaskIntoConstraints = false
        side.view.isHidden = true
        chromeConstraints.pinSidebar(side.view, to: safe, stack: stack)
        sideTabs = side
        let saveStatus = embed(WorkspaceSaveStatusView())
        saveStatus.sizingOptions = .intrinsicContentSize
        saveStatus.view.isHidden = session.persistence.state.failure == nil
        session.persistence.$state.sink { [weak saveStatus] state in
            saveStatus?.view.isHidden = state.failure == nil
        }.store(in: &subscriptions)
        let top = embed(TopBar(session: session, window: model) { [weak self] in self?.act($0) })
        topBarHeight = top.view.heightAnchor.constraint(equalToConstant: Metrics.bar)
        topBarHeight?.isActive = true
        topBar = top

        let address = embed(AddressBar(session: session, window: model) { [weak self] in self?.act($0) })
        addressBarHeight = address.view.heightAnchor.constraint(equalToConstant: Metrics.bar)
        addressBarHeight?.isActive = true
        addressBar = address

        let strip = embed(BookmarksStrip(session: session, window: model) { [weak self] in self?.act($0) })
        bookmarksBarHeight = strip.view.heightAnchor.constraint(equalToConstant: BookmarksStrip.height)
        bookmarksBarHeight?.isActive = true
        strip.view.isHidden = true
        bookmarksStrip = strip

        let splitStatus = embed(NarrowSplitControls(window: model) { [weak self] in self?.act($0) })
        splitStatus.sizingOptions = .intrinsicContentSize
        splitStatus.view.setContentHuggingPriority(.required, for: .vertical)

        let banner = embed(BannerBar(window: model) { [weak self] in self?.act($0) })
        banner.sizingOptions = .intrinsicContentSize
        bannerBar = banner

        stage.clipsToBounds = true
        stage.backgroundColor = Palette.UI.ground
        stage.laidOut = { [weak self] in self?.stageLaidOut() }
        stack.addArrangedSubview(stage)

        // Over the page rather than under it, as Safari's: the page runs on
        // beneath, seen through the bar's blur.
        model.pinned = pinnedControl
        let phone = embed(PhoneBar(session: session, window: model) { [weak self] in self?.act($0) }, inStack: false)
        phone.view.translatesAutoresizingMaskIntoConstraints = false
        barBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(barBackdrop, belowSubview: phone.view)
        chromeConstraints.pinPhoneBar(phone.view, to: safe, keyboard: view.keyboardLayoutGuide)
        NSLayoutConstraint.activate([
            // A little above the bar, so the page fades into the blur rather than meeting an edge.
            barBackdrop.topAnchor.constraint(equalTo: phone.view.topAnchor, constant: -24),
            barBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            barBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        phoneBar = phone
        // A swipe up on the bar shows the tabs, and one sideways goes to the
        // tab beside (PageSlide). UIKit's, on the bar's view: SwiftUI's buttons
        // keep a drag that starts on them to themselves.
        let swipe = BarSwipe(target: self, action: #selector(swipedBar(_:)))
        // A second finger doesn't join a swipe already going.
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = self
        swipe.finished = { [weak self] in
            // After its action has had the swipe's end, if it began.
            DispatchQueue.main.async { self?.barSwipeLetGo() }
        }
        phone.view.addGestureRecognizer(swipe)
        barSwipe = swipe
        // A touch on the page while an address is typed puts the typing
        // away, as in Safari, and is only that: it never also presses what
        // is under it on the page (the command bar has its own Cancel).
        let away = UITapGestureRecognizer(target: self, action: #selector(touchedPage))
        away.cancelsTouchesInView = true
        away.delaysTouchesBegan = false
        away.delaysTouchesEnded = false
        away.delegate = self
        stage.addGestureRecognizer(away)
        addressDismissTap = away

        // A click in the pane beside gives it the keys, and the bars.
        let landing = TouchDown(target: nil, action: nil)
        landing.delegate = self
        landing.landed = { [weak self] point in self?.landed(at: point) }
        stage.addGestureRecognizer(landing)
        // Which keys each touch or click began with, anywhere in the window.
        let keyed = KeyedPress(target: nil, action: nil)
        keyed.pressed = { [weak self] keys, point in self?.pressed(keys, at: point) }
        view.addGestureRecognizer(keyed)

        for frozen in [picture, partnerPicture] {
            frozen.contentMode = .scaleAspectFill
            frozen.clipsToBounds = true
            frozen.isUserInteractionEnabled = false
            frozen.isHidden = true
            frozen.frame = stage.bounds
            stage.addSubview(frozen)
        }

        let blank = UIHostingController(rootView: EmptySpace(session: session, window: model) { [weak self] in self?.act($0) })
        addChild(blank)
        blank.view.frame = stage.bounds
        blank.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blank.view.backgroundColor = .clear
        blank.view.isHidden = true
        stage.addSubview(blank.view)
        blank.didMove(toParent: self)
        empty = blank

        // A new tab's page: the space's bookmarks, until it goes somewhere.
        let start = UIHostingController(rootView: StartPage(session: session, window: model) { [weak self] in self?.act($0) })
        addChild(start)
        start.view.frame = stage.bounds
        start.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        start.view.backgroundColor = Palette.UI.ground
        start.view.isHidden = true
        stage.addSubview(start.view)
        start.didMove(toParent: self)
        self.start = start

        divider.moved = { [weak self] x in self?.dragDivider(to: x) }
        divider.ended = { [weak self] in self?.dropDivider() }
        divider.centered = { [weak self] in
            guard let tab = self?.model.tabID else { return }
            Session.shared.change { $0.setSplitRatio(tab, to: 0.5) }
        }
        divider.adjusted = { [weak self] direction in
            guard let self, let tab = model.tabID, let split = Session.shared.workspace.split(containing: tab) else { return }
            Session.shared.change { $0.setSplitRatio(tab, to: split.ratio + Double(direction) * 0.1) }
            layoutPanes()
        }
        stage.addSubview(divider)
        focusRing.isUserInteractionEnabled = false
        focusRing.isHidden = true
        focusRing.layer.borderWidth = 1.5
        focusRing.layer.cornerRadius = Side.card
        focusRing.layer.cornerCurve = .continuous
        stage.addSubview(focusRing)

        // Over the page's top right corner, on top of all but the command bar's
        // lists, as big as the toast is: it takes a touch only while its toast
        // has a button (an element picture's Share), so the page and the bars
        // under it get theirs.
        let toast = embed(WindowToast(window: model), inStack: false)
        toast.sizingOptions = [.intrinsicContentSize]
        toast.view.translatesAutoresizingMaskIntoConstraints = false
        toast.view.isUserInteractionEnabled = false
        toastHost = toast.view
        // The page's top, or the safe area's where a phone's page runs on under the status bar.
        let toastTop = toast.view.topAnchor.constraint(equalTo: stage.topAnchor)
        toastTop.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toastTop,
            toast.view.topAnchor.constraint(greaterThanOrEqualTo: stage.topAnchor),
            toast.view.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
            toast.view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            toast.view.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor),
            toast.view.bottomAnchor.constraint(lessThanOrEqualTo: stage.bottomAnchor),
        ])
        // The developer bars over the panes' pages, above every page view.
        developerBar.isHidden = true
        partnerBar.isHidden = true
        developerBar.onAddress = { [weak self] in self?.act(.editAddress) }
        partnerBar.onAddress = { [weak self] in self?.act(.switchPane); self?.act(.editAddress) }
        developerBar.onElementPicture = { [weak self] in self?.elementPicture() }
        developerBar.onMeasure = { [weak self] in self?.page?.toggleMeasuring() }
        partnerBar.onElementPicture = { [weak self] in self?.elementPicture(on: self?.partner) }
        partnerBar.onMeasure = { [weak self] in self?.partner?.toggleMeasuring() }
        developerBar.onInspect = { [weak self] in self?.inspectNote() }
        partnerBar.onInspect = { [weak self] in self?.inspectNote() }
        developerBar.onTurnOff = { [weak self] in self?.setDeveloperMode(false, on: self?.page) }
        partnerBar.onTurnOff = { [weak self] in self?.setDeveloperMode(false, on: self?.partner) }
        stage.addSubview(developerBar)
        stage.addSubview(partnerBar)
        splitDrop.dropped = { [weak self] half in self?.dropTab(on: half) }
        splitDrop.ended = { [weak self] in self?.model.draggedTab = nil }
        stage.addSubview(splitDrop)

        // Over everything else, the bars included: a phone's rows, over its bar.
        let list = embed(SuggestionList(window: model) { [weak self] row in self?.act(.suggestion(row)) },
                         inStack: false)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        list.view.isHidden = true
        // As tall as its rows, as far as the room goes.
        let height = list.view.heightAnchor.constraint(equalToConstant: 0)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            list.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            list.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            list.view.bottomAnchor.constraint(equalTo: phone.view.topAnchor, constant: -4),
            list.view.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 8),
            height,
        ])
        suggestionHeight = height
        suggestionList = list

        // And an iPad's command bar: in the middle of the page's column (beside
        // the sidebar, when the tabs are there), a little down from the top,
        // as tall as its field and rows as far as the keyboard leaves room.
        let bar = embed(CommandBar(window: model) { [weak self] in self?.act($0) }, inStack: false)
        bar.view.translatesAutoresizingMaskIntoConstraints = false
        bar.sizingOptions = .intrinsicContentSize
        bar.view.isHidden = true
        let barWidth = bar.view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        barWidth.priority = .defaultHigh
        let barTop = bar.view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 96)
        NSLayoutConstraint.activate([
            bar.view.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            bar.view.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            barWidth,
            barTop,
            bar.view.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
        commandBarTop = barTop
        commandBar = bar

        refreshChrome()
    }

    /// Shown for the iPhone Duo's strip, the navigation bar puts a band
    /// across the window's top that has nothing in it: its items are in the
    /// strip. The page goes on to the top under it, the band taken back out
    /// of the safe area (Docs/iPhoneDuoDesign.md §3).
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let given = view.safeAreaInsets.top - additionalSafeAreaInsets.top
        let outside = navigationController?.view.safeAreaInsets.top ?? given
        let band = navigationController?.isNavigationBarHidden == false ? max(0, given - outside) : 0
        if additionalSafeAreaInsets.top != -band { additionalSafeAreaInsets.top = -band }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The stack places the stage later in this pass, so the stage's frame
        // here is the last pass's: what follows it waits for the stage's own
        // layout, in this same pass (stageLaidOut).
        stage.setNeedsLayout()
        // A sixth of the way down, as Spotlight's sits, and clear of the bars in a short window.
        let down = max(72, (view.bounds.height * 0.16).rounded())
        if let commandBarTop, commandBarTop.constant != down { commandBarTop.constant = down }
    }

    /// The stage has this pass's frame: the panes go in it, and the cards'
    /// shadows behind them (placeCardShadows), once a pass.
    private func stageLaidOut() {
        layoutPanes()
    }

    /// The card's two shadows, behind the stage: round the window's one card,
    /// or round each of a split's two, which stand apart on the ground as the
    /// one does, with or without a sidebar.
    private func placeCardShadows(around panes: [CGRect]?) {
        let shown = carded || panes != nil
        for shadow in [cardShadow, cardEdge] where shadow.isHidden == shown {
            shadow.isHidden = !shown
        }
        guard shown else { return }
        let frame = stage.convert(stage.bounds, to: view)
        let outline = UIBezierPath()
        for card in panes ?? [stage.bounds] {
            outline.append(UIBezierPath(roundedRect: card, cornerRadius: Side.card))
        }
        for shadow in [cardShadow, cardEdge] {
            if shadow.frame != frame { shadow.frame = frame }
            shadow.layer.shadowPath = outline.cgPath
        }
    }

    private func embed<V: View>(_ root: V, inStack: Bool = true) -> UIHostingController<V> {
        let host = UIHostingController(rootView: root)
        // The stack already keeps the bars inside the safe area. Left to
        // SwiftUI, the keyboard's arrival moved what they draw up out of
        // sight, .ignoresSafeArea(.keyboard) or not: both bars went blank
        // whenever a field had the focus (iPadOS 27).
        host.safeAreaRegions = []
        // The window's own colour shows through: the site's (siteColor).
        host.view.backgroundColor = .clear
        addChild(host)
        if inStack { stack.addArrangedSubview(host.view) } else { view.addSubview(host.view) }
        host.didMove(toParent: self)
        return host
    }

    /// Which bars show, from Settings and the page. In the compact layout
    /// the address is in the tab on screen, so the row of tabs shows
    /// whenever an address must: on sign-in pages, while one is typed, when
    /// a page failed, on a new tab, even with the tab bar turned off.
    private func refreshChrome() {
        let session = Session.shared
        let preferences = session.preferences
        // A site's letter, until its icon comes, on the space's colour, in
        // UIKit and SwiftUI alike (SiteIconView).
        let colour = session.workspace.space(model.spaceID)?.color ?? .blue
        if shownColour != colour {
            shownColour = colour
            traitOverrides.spaceColor = colour
        }
        let url = page?.displayURL ?? model.tabID.flatMap { session.workspace.tab($0)?.url }
        model.set(\.pendingPageDialog, to: page?.hasPendingDialog ?? false)
        model.set(\.refusedExternalLink, to: page?.refusedAppLink != nil)
        let signIn = page?.passwordField ?? false
        let failed = page?.failure != nil
        // Typing an address brings no bar out on iPad: it is typed in the
        // command bar, over the page, and the bars keep saying what they said.
        let required = AddressVisibility.shows(mode: .automatic, url: url, passwordField: signIn,
                                               editing: false, failed: failed)
        if model.addressRequired != required { model.addressRequired = required }
        let phone = traitCollection.horizontalSizeClass == .compact
        let strip = phone ? StripEdge(of: traitCollection) : nil
        if model.strip != strip {
            model.strip = strip
            // The bar covers less of the page beside a strip (phoneCovered).
            stage.setNeedsLayout()
        }
        // The strip's tools in any window the system's strip stands beside:
        // the Duo closed, and open too, where the iPad's bars are along the top.
        showStrip(StripEdge(of: traitCollection) != nil)
        // Beside a sidebar of tabs the strip has no tabs item: the tabs are there.
        stripItems?.showsTabs(phone || preferences.tabsPlacement != .sidebar)
        let makesWindows = Device.makesWindows(on: view.window?.windowScene?.screen.bounds.size ?? view.bounds.size)
        if model.makesWindows != makesWindows { model.makesWindows = makesWindows }
        // Whether a change of width ended an address being typed (below).
        var endedTyping = false
        if model.phone != phone {
            // A window that turns phone-width or back while an address is
            // typed has another field to type it in (the bar at the bottom,
            // the command bar). On an iPad, resized, the typing ends rather
            // than being handed from one to the other with the keys. On a
            // phone (the iPhone Duo opening or closing, a large iPhone
            // turning) it is the same moment for the person typing: what is
            // typed goes over to the other field, the cursor at its end.
            if model.editingAddress {
                if Device.phone {
                    model.carriedAddress = model.suggestions.lastTyped
                    model.addressTurn += 1
                } else {
                    model.editingAddress = false
                    endedTyping = true
                }
            }
            model.phone = phone
        }
        let showsAddress = AddressVisibility.shows(
            mode: preferences.address, url: url, passwordField: signIn, editing: false, failed: failed
        )
        if model.showsAddress != showsAddress { model.showsAddress = showsAddress }
        // Not before the keyboard is on its way, the first time: see keyboardHasStarted.
        let typing = phone && model.editingAddress && (Self.keyboardHasStarted || keyboardWaitOver)
        let layout = ChromeLayout(compact: phone, strip: strip != nil, placement: preferences.tabsPlacement,
                                  tabBar: preferences.tabBar, bookmarksBar: preferences.bookmarksBar,
                                  addressRequired: required, typing: typing)
        // Asked many times as a page loads; the bars move only when it changes.
        if layout != shownLayout {
            shownLayout = layout
            show(layout)
        }
        // The desktop view is the phone's, and never on a hands-off page,
        // where nothing may reach the page but the finger.
        if let page, page.desktopView, !Device.phone || page.isHandsOff { leaveDesktopView() }
        let desktop = page?.desktopView ?? false
        if model.desktopView != desktop { model.desktopView = desktop }
        // Any phone's, whichever bars its window has: a large iPhone turned keeps it.
        let canDesktop = Device.phone && page?.view.url != nil && page?.isHandsOff == false
        if model.canDesktopView != canDesktop { model.canDesktopView = canDesktop }
        let canHandoff = preferences.handoff && session.hasIntelligence && page?.view.url != nil && page?.isHandsOff == false
        if model.canHandoff != canHandoff { model.canHandoff = canHandoff }
        if model.jsonView != page?.jsonView { model.jsonView = page?.jsonView }
        if model.measuring != (page?.measure != nil) { model.measuring = page?.measure != nil }
        if desktop { showDesktopPad() } else if desktopPad != nil { hideDesktopPad() }
        bannerBar?.view.isHidden = model.banner == nil
        start?.view.isHidden = !(page != nil && model.url == nil)
        // Looked up only when the address or the space's bookmarks are other
        // ones: this runs many times as a page loads, and the answer reads
        // every bookmark. (The same array compares at once.)
        let bookmarks = session.workspace.space(model.spaceID)?.bookmarks ?? []
        let bookmarked: Bool
        if let last = starCheck, last.url == url, last.bookmarks == bookmarks {
            bookmarked = last.found
        } else {
            bookmarked = url.flatMap { Bookmarks.find($0, in: bookmarks) } != nil
            starCheck = (url, bookmarks, bookmarked)
        }
        if model.bookmarked != bookmarked { model.bookmarked = bookmarked }
        var blocking: Bool?
        if let host = url?.host, let page, !page.isHandsOff, preferences.blocksContent {
            blocking = preferences.blocksContent(onHost: host)
        }
        if model.blocking != blocking { model.blocking = blocking }
        var ownMenus: Bool?
        if let host = url?.host, let page, !page.isHandsOff { ownMenus = preferences.keepsOwnMenus(onHost: host) }
        if model.ownMenus != ownMenus { model.ownMenus = ownMenus }
        // Not on a site the app never checks (WritingSites.never), where
        // the row could do nothing.
        var writing: Bool?
        if url?.host != nil, let page, !page.isHandsOff, preferences.writing, !WritingSites.isOff(url, sites: []) {
            writing = !WritingSites.isOff(url, sites: preferences.writingOffSites)
        }
        if model.writing != writing { model.writing = writing }
        showDiagnostics(Device.diagnostics && preferences.diagnostics)
        applySiteColor()
        placeSuggestions()
        placeCommandBar()
        // The keys go back to the page, as they do however else typing ends
        // (cancelAddress): the field that had them is put away, and with no
        // one holding them a keyboard's keys would go nowhere until the page
        // was tapped. Last, once the bars are where they belong.
        if endedTyping { focusPage() }
    }

    /// The bars as `layout` has them (ChromeLayout): the sidebar or the
    /// rows along the top on a wide window, the bar at the bottom on a
    /// phone-width one, as tall as its form.
    private func show(_ layout: ChromeLayout) {
        let phone = layout.phoneBar != nil
        if sideTabs?.view.isHidden == layout.sidebar {
            sideTabs?.view.isHidden = !layout.sidebar
            if !layout.sidebar, model.bookmarksOpen { model.bookmarksOpen = false }
            chromeConstraints.placeStack(besideSidebar: layout.sidebar)
        }
        // Wider than a phone, the window is the Mac's whichever way the tabs are.
        card(!phone)
        topBar?.view.isHidden = !layout.topBar
        addressBar?.view.isHidden = !layout.addressBar
        bookmarksStrip?.view.isHidden = !layout.bookmarksBar
        phoneBar?.view.isHidden = !phone
        // The tabs grow out of the phone's bar; with the bar gone, they go too.
        if !phone { tabSheet?.closeNow() }
        let typing = layout.phoneBar == .typing
        if model.barRidesKeyboard != typing { model.barRidesKeyboard = typing }
        // Only the address rides over the keyboard, as in Safari; the page
        // takes the room the tools leave, at the speed the tools go.
        let height: CGFloat? = switch layout.phoneBar {
        case .twoRows: PhoneBar.height
        case .oneRow: PhoneBar.stripHeight
        case .typing: PhoneBar.typingHeight
        case nil: nil
        }
        if let height, chromeConstraints.setPhoneHeight(height) {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) { self.view.layoutIfNeeded() }
        }
        chromeConstraints.rideKeyboard(typing)
    }

    /// A phone's suggestions, over its bar, while there are any and an
    /// address is typed.
    private func placeSuggestions() {
        guard let list = suggestionList else { return }
        let height = SuggestionRows.height(of: model.suggestions)
        let shows = model.phone && model.editingAddress && height > 0
        if list.view.isHidden == shows { list.view.isHidden = !shows }
        if shows { suggestionHeight?.constant = height }
    }

    /// An iPad's command bar, while an address is typed: it comes up out of
    /// the page a little smaller and fades in, and fades out faster than it
    /// came, so the page is back at once.
    private func placeCommandBar() {
        guard let bar = commandBar?.view else { return }
        let shows = model.editingAddress && !model.phone
        guard shows != commandBarShown else { return }
        commandBarShown = shows
        bar.accessibilityViewIsModal = shows
        for background in [stage, topBar?.view, addressBar?.view, sideTabs?.view, bookmarksStrip?.view].compactMap({ $0 }) {
            background.accessibilityElementsHidden = shows
        }
        if shows {
            // From where it is when it was still going (⌘T with the bar
            // already open puts it away and brings it back in one turn).
            if bar.isHidden {
                bar.isHidden = false
                bar.alpha = 0
                // Only the fade under Reduce Motion.
                bar.transform = UIAccessibility.isReduceMotionEnabled ? .identity
                    : CGAffineTransform(translationX: 0, y: -8).scaledBy(x: 0.97, y: 0.97)
            }
            UIView.animate(springDuration: 0.28, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                bar.alpha = 1
                bar.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                bar.alpha = 0
            } completion: { [weak self] _ in
                if self?.commandBarShown == false { bar.isHidden = true }
            }
        }
    }

    /// The bars and the strip under the status bar in the colour along the
    /// top of the page, so page and bars read as one, as in Safari. What
    /// they draw turns light on a dark colour and dark on a light one; a
    /// change of colour eases in rather than flashing.
    ///
    /// The phone bar is at the page's foot, and goes by the colour there
    /// (Page.footColor): its ground fades to it, and what it draws turns
    /// light or dark to read on it. Until the page has been looked at, the
    /// colour of its top is the best guess; over the start page, which is
    /// the app's own, the system's appearance stands.
    private func applySiteColor() {
        let color = model.siteColor
        // On the space's colour the bars are light or dark as the system is,
        // as the sidebar and the command bar always are (both left out).
        let style: UIUserInterfaceStyle = carded ? .unspecified : color.map { $0.isDark ? .dark : .light } ?? .unspecified
        for bar in [topBar, addressBar, bookmarksStrip, bannerBar] as [UIViewController?]
        where bar?.overrideUserInterfaceStyle != style {
            bar?.overrideUserInterfaceStyle = style
        }
        let foot = model.url == nil ? nil : (page?.footColor ?? color)
        if model.footColor != foot { model.footColor = foot }
        let footStyle: UIUserInterfaceStyle = foot.map { $0.isDark ? .dark : .light } ?? .unspecified
        // And a phone's rows over its bar, as that bar.
        for bar in [phoneBar, suggestionList] as [UIViewController?] where bar?.overrideUserInterfaceStyle != footStyle {
            bar?.overrideUserInterfaceStyle = footStyle
        }
        if barBackdrop.overrideUserInterfaceStyle != footStyle { barBackdrop.overrideUserInterfaceStyle = footStyle }
        barBackdrop.tint = foot?.uiColor
        // The iPhone Duo strip's items read on what is behind them: the page's
        // edge drawn on across it (placeStripGround), else the window's colour;
        // at its foot on a phone, the bar's ground, which runs on under the strip.
        if let navigation = navigationController {
            let column = stripGround.isHidden ? nil : page?.stripColumn
            let top = column.map { $0.top.isDark ? UIUserInterfaceStyle.dark : .light } ?? style
            let bottom = model.phone ? footStyle : column.map { $0.foot.isDark ? UIUserInterfaceStyle.dark : .light } ?? style
            if navigation.navigationBar.overrideUserInterfaceStyle != top { navigation.navigationBar.overrideUserInterfaceStyle = top }
            if navigation.toolbar.overrideUserInterfaceStyle != bottom { navigation.toolbar.overrideUserInterfaceStyle = bottom }
        }
        let ground = carded ? Palette.UI.ground : color?.uiColor ?? Palette.UI.ground
        if view.backgroundColor != ground {
            UIView.animate(withDuration: 0.25) { self.view.backgroundColor = ground }
        }
        // Only when it would change: this runs for every step of a page's
        // loading, and asking is a pass through UIKit whatever the answer.
        let status = preferredStatusBarStyle
        if statusStyle != status {
            statusStyle = status
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// The status bar's style as it was last asked for (applySiteColor).
    private var statusStyle: UIStatusBarStyle?

    /// The page as a card on the window's ground, or edge to edge.
    private func card(_ on: Bool) {
        guard on != carded else { return }
        carded = on
        let bezel = on ? Side.bezel : 0
        chromeConstraints.inset(by: bezel)
        placeSidebar(animated: false)
        stage.layer.cornerRadius = on ? Side.card : 0
        stage.layer.cornerCurve = .continuous
        windowGround?.view.isHidden = !on
        view.setNeedsLayout()
        applySiteColor()
    }

    /// The sidebar's width and the page's start beside it: the sidebar's own
    /// width a bezel from the page; or, on an iPhone Duo folded like a book,
    /// as far as the fold, the page starting past it, so each half of the
    /// display is one of the two (DuoLayout.sidebar). Asked from the root
    /// view's updateConstraints(), where reading the fold makes UIKit ask
    /// again when the fold comes or goes, and as the card comes and goes.
    private func placeSidebar(animated: Bool) {
        guard let shown = chromeConstraints.sidebar else { return }
        var fold: CGRect?
        if #available(iOS 27.1, *), carded {
            fold = view.reservedRegions(kind: .division).first?.frame
        }
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let start = rightToLeft ? view.bounds.width - view.safeAreaInsets.right : view.safeAreaInsets.left
        let sidebar = DuoLayout.sidebar(start: start, fold: fold, rightToLeft: rightToLeft, standard: SideTabs.width,
                                        minimum: SideTabs.width, gap: carded ? Side.bezel : 0)
        guard shown.width != sidebar.width || shown.gap != sidebar.gap else { return }
        guard animated, !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            chromeConstraints.placeSidebar(width: sidebar.width, gap: sidebar.gap)
            return
        }
        // Not inside the constraints pass that read the fold: the next turn,
        // growing into the half (or back) as the device folds.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            chromeConstraints.placeSidebar(width: sidebar.width, gap: sidebar.gap)
            UIView.animate(springDuration: 0.35, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.view.layoutIfNeeded()
            }
        }
    }

    // MARK: The keyboard's first coming

    /// Whether the keyboard has come up in this run of the app. The first
    /// time it takes the system a moment to start it, a second and more in
    /// the simulator, and nothing the app draws shows until it is there.
    /// A phone's bar that had already shrunk to ride over it sat at the foot
    /// of the screen for that moment, its tools cut off, looking broken. So
    /// the first time the bar keeps its place until the keyboard says it is
    /// coming, and goes up with it; after that it is quick, and the bar
    /// makes room at the tap as before.
    private static var keyboardHasStarted = false

    /// Every window hears of the keyboard, in no order: the one being typed
    /// in makes room whichever heard first.
    private func keyboardStarted() {
        Self.keyboardHasStarted = true
        if model.phone, model.editingAddress, !model.barRidesKeyboard { refreshChrome() }
    }

    /// With no keyboard to come (a keyboard with keys is attached), the bar
    /// makes room a moment after the tap all the same: for this turn at the
    /// address only, since no keyboard has started. One wait at a time, and
    /// none left over once the typing ends.
    private func awaitKeyboard() {
        guard !Self.keyboardHasStarted, keyboardWait == nil else { return }
        keyboardWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            keyboardWait = nil
            keyboardWaitOver = true
            if model.phone, model.editingAddress, !model.barRidesKeyboard { refreshChrome() }
        }
    }

    /// The first keyboard's wait for this turn at the address (awaitKeyboard).
    private var keyboardWait: Task<Void, Never>?
    private var keyboardWaitOver = false

    override var preferredStatusBarStyle: UIStatusBarStyle {
        // Over the space's colour, with the sidebar, as the system's look has it.
        guard !carded, let color = model.siteColor else { return .default }
        return color.isDark ? .lightContent : .darkContent
    }

    private func showDiagnostics(_ on: Bool) {
        if !on {
            diagnostics?.willMove(toParent: nil)
            diagnostics?.view.removeFromSuperview()
            diagnostics?.removeFromParent()
            diagnostics = nil
            if let hingeWatch { view.removeInteraction(hingeWatch) }
            hingeWatch = nil
            return
        }
        guard diagnostics == nil else { return }
        // The iPhone Duo's hinge, for the panel to show.
        if #available(iOS 27.1, *) {
            let watch = UIHingeInteraction { _, update in
                guard let hinge = update.hinge else {
                    Diagnostics.hinge = "none"
                    return
                }
                let status = switch hinge.status {
                case .closed: "closed"
                case .partiallyOpen: "partly open"
                case .fullyOpen: "open"
                default: "unknown"
                }
                Diagnostics.hinge = "\(status) \(Int((hinge.angle * 180 / .pi).rounded()))°"
            }
            view.addInteraction(watch)
            hingeWatch = watch
        }
        let hud = UIHostingController(rootView: DiagnosticsView(page: { [weak self] in self?.page },
                                                                window: { [weak self] in self?.view },
                                                                close: { Session.shared.preferences.diagnostics = false }))
        hud.view.backgroundColor = .clear
        hud.view.isUserInteractionEnabled = true
        hud.sizingOptions = .intrinsicContentSize
        addChild(hud)
        hud.view.translatesAutoresizingMaskIntoConstraints = false
        // Under a phone's rows and an iPad's command bar, which are what is being used.
        if let rows = suggestionList?.view { view.insertSubview(hud.view, belowSubview: rows) } else { view.addSubview(hud.view) }
        // On a phone, above the bar at the bottom rather than under it.
        let bottom = model.phone ? phoneBar.map { hud.view.bottomAnchor.constraint(equalTo: $0.view.topAnchor, constant: -12) } : nil
        NSLayoutConstraint.activate([
            hud.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            // Clear of a side the system keeps, as the iPhone Duo's status bar strip.
            hud.view.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bottom ?? hud.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        hud.didMove(toParent: self)
        diagnostics = hud
    }

    // MARK: Showing a tab

    /// Shows a tab in this window. One another window shows is brought
    /// forward there instead when you asked for it; a window coming back
    /// takes another tab of its space, or none.
    func show(tab id: UUID?, inSpace space: UUID, userInitiated: Bool = true) {
        pinnedControl.close()
        let session = Session.shared
        guard let id, let record = session.workspace.tab(id), let owner = session.workspace.spaceID(of: id) else {
            showEmpty(space: session.workspace.space(space) == nil ? session.workspace.firstSpace.id : space)
            return
        }
        if let other = session.browser(showing: id), other !== self {
            if userInitiated {
                session.bringForward(other)
            } else if let free = session.workspace.space(owner)?.tabs.first(where: { session.browser(showing: $0.id) == nil }) {
                show(tab: free.id, inSpace: owner, userInitiated: false)
            } else {
                showEmpty(space: owner)
            }
            return
        }
        // Already here, and still live: a tab moved to another space has a
        // new page to load in that space's store.
        if model.tabID == id, let page, session.pages.live[id] === page {
            focusPage()
            return
        }
        let pairedWith = session.workspace.split(containing: id)?.partner(of: id)
        // The pane beside, still split with the tab on screen: it takes the keys.
        if let partner, partner.tab == id, session.pages.live[id] === partner, let page, pairedWith == page.tab {
            swapPanes()
            return
        }
        // The tab on screen split with the one asked for stays up, as the other pane.
        if let page, pairedWith == page.tab, session.pages.live[page.tab] === page {
            detachPartner()
            self.page = nil
            partner = page
            partnerPicture.image = picture.image
            partnerPicture.alpha = picture.alpha
            partnerPicture.isHidden = picture.isHidden
            picture.isHidden = true
            picture.image = nil
        } else {
            detach()
        }
        let made = session.pages.page(for: record, in: owner)
        attach(made.page, thawed: made.thawed)
        // Going to another tab ends typing an address, as in Safari.
        model.editingAddress = false
        model.spaceID = owner
        model.tabID = id
        session.change { $0.select(id) }
        syncSplit()
        pageDidChange(made.page)
        focusPage()
        session.pages.enforce()
    }

    /// The other pane takes the keys: the bars show its page from now on.
    private func swapPanes() {
        guard let partner, let page else { return }
        self.page = partner
        self.partner = page
        let frozen = (picture.image, picture.alpha, picture.isHidden)
        picture.image = partnerPicture.image
        picture.alpha = partnerPicture.alpha
        picture.isHidden = partnerPicture.isHidden
        (partnerPicture.image, partnerPicture.alpha, partnerPicture.isHidden) = frozen
        model.editingAddress = false
        model.tabID = partner.tab
        Session.shared.change { $0.select(partner.tab) }
        layoutPanes()
        pageDidChange(partner)
        focusPage()
    }

    /// A touch or a click began somewhere in the window, with these keys
    /// held: kept for a ⌘-click on a bookmark; and off the bookmarks, on the
    /// page, the address or a pinned tab, it puts them away, as one outside a
    /// popover does, and still goes where it was meant to.
    private func pressed(_ keys: UIKeyModifierFlags, at point: CGPoint) {
        model.lastPress = (keys, Date())
        // The touch is the window's; the bookmarks' frame the sidebar's (SideTabs.space).
        guard model.bookmarksOpen, let side = sideTabs?.view,
              !model.bookmarksFrame.contains(side.convert(point, from: nil))
        else { return }
        withAnimation(.bar) { model.bookmarksOpen = false }
    }

    /// A touch or a click landed on the stage: in the pane beside, that pane
    /// gets the keys. The touch itself goes on to the page, which may open
    /// or close something of its own over itself (a menu, a dialog): what its
    /// edges show is looked at again, for the bars beside them.
    private func landed(at point: CGPoint) {
        page?.touched()
        guard !model.editingAddress else { return }
        guard let partner, !partner.view.isHidden, partner.view.frame.contains(point) else { return }
        show(tab: partner.tab, inSpace: model.spaceID)
    }

    /// The tab split with the one on screen, up in its pane beside it; or
    /// taken down, when their split has ended or another window shows that
    /// tab.
    func syncSplit() {
        let session = Session.shared
        let workspace = session.workspace
        guard connected, let tab = model.tabID, page != nil, let other = workspace.split(containing: tab)?.partner(of: tab),
              let record = workspace.tab(other), let space = workspace.spaceID(of: other),
              !session.allBrowsers.contains(where: { $0 !== self && $0.isConnected && $0.shows(other) })
        else {
            if partner != nil {
                detachPartner()
                session.pages.enforce()
            }
            layoutPanes()
            return
        }
        if partner?.tab != other || session.pages.live[other] !== partner {
            detachPartner()
            let made = session.pages.page(for: record, in: space)
            made.page.host = self
            stage.insertSubview(made.page.view, at: 0)
            partner = made.page
            if made.thawed, let image = session.pages.picture(for: other) {
                partnerPicture.image = image
                partnerPicture.alpha = 1
                partnerPicture.isHidden = false
            }
            session.pages.enforce()
        }
        layoutPanes()
    }

    private func detachPartner() {
        guard let partner else { return }
        if partner.view.superview === stage { partner.view.removeFromSuperview() }
        if partner.host === self { partner.host = nil }
        self.partner = nil
        partnerPicture.isHidden = true
        partnerPicture.image = nil
    }

    /// The narrowest a window shows a split in: two pages each wide enough
    /// to read. Narrower, only the pane with the keys shows, and a click on
    /// the other half of the split's tab goes over to the other.
    private static let splitWidth: CGFloat = 2 * 360 + SplitDivider.width
    /// The developer bar's height: 28 points, 24 on a phone-width window.
    private var developerHeight: CGFloat { model.phone ? 24 : 28 }

    /// The tab on screen across the stage; or a split's two side by side,
    /// each a card of its own as the window's one card is: round at every
    /// corner, with the card's shadows, the window's ground between them and
    /// round them, the grip in the gap and a line of the space's colour round
    /// the one with the keys, as the Mac's.
    private func layoutPanes() {
        let bounds = pageRoom
        var main = bounds
        var cards: [CGRect]?
        let split = model.tabID.flatMap { Session.shared.workspace.split(containing: $0) }
        let area = splitArea(in: bounds)
        let narrow = split != nil && area.width < Self.splitWidth
        if model.narrowSplit != narrow { model.narrowSplit = narrow }
        if let split { divider.ratio = split.ratio }
        if let page, let partner, let split, split.contains(partner.tab), area.width >= Self.splitWidth {
            let (left, right) = halves(of: area, ratio: dragRatio ?? split.ratio)
            let onLeft = split.left == page.tab
            main = onLeft ? left : right
            var pane = onLeft ? right : left
            // The page beside's developer bar: its pane a bar shorter.
            laidPartnerDeveloper = DeveloperBar.isOn(partner)
            if laidPartnerDeveloper {
                partnerBar.show(partner, compact: model.phone)
                partnerBar.frame = CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: developerHeight)
                partnerBar.isHidden = false
                pane.origin.y += developerHeight
                pane.size.height -= developerHeight
            } else {
                partnerBar.isHidden = true
            }
            partner.view.frame = pane
            partner.view.isHidden = false
            partnerPicture.frame = pane
            partnerPicture.isHidden = partnerPicture.image == nil
            divider.frame = CGRect(x: left.maxX, y: area.minY, width: SplitDivider.width, height: area.height)
            divider.isHidden = false
            let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            // The start page over a new tab's pane too: it is opaque, and would square the card's corners.
            for view in [page.view, picture, partner.view, partnerPicture, start?.view].compactMap({ $0 }) { round(view, corners) }
            focusRing.frame = main
            focusRing.layer.borderColor = (Session.shared.workspace.space(model.spaceID)?.color.uiColor ?? .tintColor)
                .resolvedColor(with: traitCollection).cgColor
            focusRing.isHidden = false
            cards = [left, right]
        } else {
            partner?.view.isHidden = true
            partnerPicture.isHidden = true
            partnerBar.isHidden = true
            laidPartnerDeveloper = false
            divider.isHidden = true
            focusRing.isHidden = true
            for view in [page?.view, picture, partner?.view, partnerPicture, start?.view].compactMap({ $0 }) { round(view, []) }
        }
        placeCardShadows(around: cards)
        // Under the phone bar and the home indicator: the page goes on
        // there, told it is covered so its end scrolls clear of the bar and
        // its own bottom bars sit above it. The desktop view's page too, the
        // cursor and the view kept above the bar; past the desktop's own
        // edge, the page's own colour rather than the window's, so the bar
        // sits on the page.
        let covered = phoneCovered
        if let page, let pad = desktopPad, pad.page === page {
            laidClear = false
            laidDeveloper = false
            developerBar.isHidden = true
            pad.layout(in: main, covered: covered)
            page.obscure(bottom: 0)
            page.footBand = covered
            stage.backgroundColor = page.view.underPageBackgroundColor
        } else {
            page?.view.transform = .identity
            // The page's developer bar across its top: the page that much
            // shorter, on iPad with its buttons, on a phone's width without.
            laidDeveloper = page.map(DeveloperBar.isOn) ?? false
            // A page that only fills the window stands clear of the bar: laid out in the window
            // less the bar, with its own colour under the bar in place of its foot (FootRoom).
            // The window it fills is what the developer bar leaves of it.
            page?.room(window: main.height - (laidDeveloper ? developerHeight : 0), covered: covered)
            let clear = covered > 0 && page?.standsClear == true
            laidClear = clear
            var room = main
            if clear { room.size.height -= covered }
            if laidDeveloper, let page {
                developerBar.show(page, compact: model.phone)
                developerBar.frame = CGRect(x: room.minX, y: room.minY, width: room.width, height: developerHeight)
                developerBar.isHidden = false
                developerBar.refresh()
                room.origin.y += developerHeight
                room.size.height -= developerHeight
            } else {
                developerBar.isHidden = true
            }
            page?.view.frame = room
            page?.obscure(bottom: clear ? 0 : covered)
            page?.footBand = covered
            // A split's cards stand on the window's ground: the stage shows it through.
            let ground = divider.isHidden ? Palette.UI.ground : .clear
            stage.backgroundColor = clear ? (page?.footColor?.uiColor ?? page?.view.underPageBackgroundColor ?? ground) : ground
        }
        placeStripGround()
        layoutMeasureCard()
        picture.frame = main
        // The start page runs on under the bar too, its own ground behind
        // the bar's blur rather than whatever the window has there; its
        // tiles keep clear of the bar, as a page's end does.
        start?.view.frame = main
        let bar = covered > 0 ? PhoneBar.resting(strip: model.strip != nil) : 0
        if start?.additionalSafeAreaInsets.bottom != bar { start?.additionalSafeAreaInsets.bottom = bar }
        barBackdrop.isHidden = !model.phone
        if !splitDrop.isHidden { placeSplitDrop() }
    }

    /// The measuring tool's card at the bottom of the page's area it runs
    /// on (Decided 1: the drawn parts are the page's, this card the app's):
    /// made when a page's measure starts, laid over that page's foot, gone
    /// when it ends.
    private func layoutMeasureCard() {
        let measuring = [page, partner].compactMap { $0 }.first { $0.measure != nil }
        guard let model = measuring?.measure else {
            if let card = measureCard {
                card.willMove(toParent: nil)
                card.view.removeFromSuperview()
                card.removeFromParent()
                measureCard = nil
                measureModel = nil
            }
            return
        }
        let card: UIHostingController<MeasurePanel>
        if let kept = measureCard {
            if measureModel !== model { kept.rootView = MeasurePanel(model: model) }
            card = kept
        } else {
            card = UIHostingController(rootView: MeasurePanel(model: model))
            card.view.backgroundColor = .clear
            // Its size as it changes (a selection's rows, a note's), told to
            // preferredContentSizeDidChange, which lays it out again.
            card.sizingOptions = [.preferredContentSize]
            addChild(card)
            stage.addSubview(card.view)
            card.didMove(toParent: self)
            measureCard = card
        }
        measureModel = model
        var room = measuring?.view.frame ?? .zero
        // Clear of the phone's bar where the page runs on under it.
        if measuring === page, !laidClear { room.size.height -= phoneCovered }
        let wanted = card.preferredContentSize
        let size = wanted.width > 0 && wanted.height > 0 ? wanted : card.sizeThatFits(in: room.size)
        card.view.frame = CGRect(x: room.midX - size.width / 2, y: room.maxY - size.height - 16,
                                 width: size.width, height: size.height)
        stage.bringSubviewToFront(card.view)
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        if container === measureCard { layoutMeasureCard() }
    }

    /// A split's two cards in `area`: the left one `ratio` of it less the gap.
    private func halves(of area: CGRect, ratio: Double) -> (left: CGRect, right: CGRect) {
        let gap = SplitDivider.width
        let left = CGRect(x: area.minX, y: area.minY, width: ((area.width - gap) * ratio).rounded(), height: area.height)
        return (left, CGRect(x: left.maxX + gap, y: area.minY, width: area.maxX - left.maxX - gap, height: area.height))
    }

    // MARK: A tab dragged onto the page

    /// A tab is dragged, or has been let go: the page shows where it can go
    /// beside it, over the pages, or takes that away. Not in a phone's
    /// window, for a pinned tab, for the tab on screen itself or another
    /// space's.
    private func armSplitDrop() {
        let workspace = Session.shared.workspace
        guard !model.phone, let dragged = model.draggedTab, let shown = model.tabID, dragged != shown,
              workspace.tab(shown)?.isPinned == false, workspace.tab(dragged)?.isPinned == false,
              workspace.spaceID(of: dragged) == workspace.spaceID(of: shown)
        else { return splitDrop.arm(false) }
        droppingTab = dragged
        stage.bringSubviewToFront(splitDrop)
        placeSplitDrop()
        splitDrop.arm(true)
    }

    /// The pane the dragged tab would open as on each half, as layoutPanes
    /// will lay it: half the split's area, or for the other pane's tab
    /// carried across, its share kept; all of the area in a window too
    /// narrow for two, where the dragged tab is the one that shows.
    private func placeSplitDrop() {
        let workspace = Session.shared.workspace
        let area = splitArea(in: stage.bounds)
        splitDrop.frame = stage.bounds
        splitDrop.area = area
        if area.width < Self.splitWidth {
            splitDrop.panes = (area, area)
        } else {
            let pair = model.tabID.flatMap { workspace.split(containing: $0) }
            // The left pane's share with the dragged tab on each half.
            let shares: (left: Double, right: Double) = if let pair, let dragged = droppingTab, pair.contains(dragged) {
                pair.left == dragged ? (pair.ratio, 1 - pair.ratio) : (1 - pair.ratio, pair.ratio)
            } else {
                (0.5, 0.5)
            }
            splitDrop.panes = (halves(of: area, ratio: shares.left).left, halves(of: area, ratio: shares.right).right)
        }
        splitDrop.tint = (workspace.space(model.spaceID)?.color.uiColor ?? .tintColor).resolvedColor(with: traitCollection)
        splitDrop.setNeedsLayout()
    }

    /// The dragged tab let go over a half of the page (SplitDrop): it opens
    /// there, with the keys, beside the page on screen, or in place of the
    /// split's pane on that half, the other pane staying. The other pane's
    /// own tab carried across swaps the two.
    private func dropTab(on half: SplitDrop.Half) {
        let session = Session.shared
        guard let dropped = droppingTab, let shown = model.tabID, dropped != shown else { return }
        let pair = session.workspace.split(containing: shown)
        let done = session.change { (workspace: inout Workspace) -> Bool in
            if let pair, pair.contains(dropped) {
                if (half == .left) != (pair.left == dropped) { workspace.swapSides(dropped) }
                return true
            }
            let staying = pair.map { half == .left ? $0.right : $0.left } ?? shown
            guard workspace.split(staying, with: dropped) else { return false }
            if half == .left { workspace.swapSides(dropped) }
            return true
        }
        guard done else { return }
        show(tab: dropped, inSpace: model.spaceID)
    }

    /// Whether the page on screen was last laid out clear of the phone bar (Page.standsClear).
    private var laidClear = false

    private var pageRoom: CGRect {
        FootRoom.aboveKeyboard(stage.bounds,
                               keyboard: stage.convert(view.keyboardLayoutGuide.layoutFrame, from: view),
                               bottomSafeArea: view.safeAreaInsets.bottom,
                               avoiding: !model.editingAddress && desktopPad == nil)
    }

    /// How much of the stage's bottom the phone bar covers, with the home
    /// indicator under it: always the bar's resting height, so typing an
    /// address doesn't move the page. Above the keyboard, the bar is
    /// below the page rather than over it: no second inset for it.
    private var phoneCovered: CGFloat {
        guard model.phone, phoneBar?.view.isHidden == false, pageRoom == stage.bounds else { return 0 }
        return view.safeAreaInsets.bottom + PhoneBar.resting(strip: model.strip != nil)
    }

    /// The side the iPhone Duo's strip stands on, as an edge of the page:
    /// where the safe area stops short of the window's edge, which the strip
    /// is what does. Nil where no strip stands beside the window.
    private var stripSide: CGRectEdge? {
        guard StripEdge(of: traitCollection) != nil else { return nil }
        return view.safeAreaInsets.right >= view.safeAreaInsets.left ? .maxXEdge : .minXEdge
    }

    /// Behind the iPhone Duo's strip, beside the page, the page's edge on
    /// that side drawn on across it (Page.stripColumn): a header's colour
    /// beside the header, a gradient going on, the page's ground beside the
    /// ground, as if the page reached the window's edge. Only where the page
    /// is edge to edge and meets the strip: on a card, beside a split or a
    /// sidebar, in the desktop view and on the start page the window's own
    /// colour stands behind the strip.
    private func placeStripGround() {
        // From the safe area's edge to the window's. Measured by the stack,
        // which never moves: a sideways swipe moves the stage.
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let meets: (CGRectEdge) -> Bool = { [stack] side in
            side == .maxXEdge ? abs(stack.frame.maxX - safe.maxX) < 1 : abs(stack.frame.minX - safe.minX) < 1
        }
        let edgeToEdge = model.url != nil && !carded && divider.isHidden && page.map { desktopPad?.page !== $0 } == true
        let side = edgeToEdge ? stripSide.flatMap { meets($0) ? $0 : nil } : nil
        // Looked at only while it is drawn on.
        page?.stripEdge = side
        guard let side, let page, let column = page.stripColumn else {
            stripGround.isHidden = true
            return
        }
        let start = side == .maxXEdge ? safe.maxX : view.bounds.minX
        let end = side == .maxXEdge ? view.bounds.maxX : safe.minX
        // As high as the page's edge it was drawn from (to the phone bar, whose
        // blur goes on under the strip), in the stage, which the swipe moves only sideways.
        let shown = stack.convert(stage.frame, to: view)
        let frame = CGRect(x: start, y: shown.minY + page.view.frame.minY, width: max(0, end - start), height: column.height)
        if stripGround.frame != frame { stripGround.frame = frame }
        if stripGround.image !== column.picture {
            if stripGround.isHidden || stripGround.image == nil {
                stripGround.image = column.picture
            } else {
                // The page scrolled or changed under it: eased, as the bar's ground is.
                UIView.transition(with: stripGround, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.stripGround.image = column.picture
                }
            }
        }
        stripGround.isHidden = frame.width < 1 || frame.height < 1
    }

    /// The strip's tools stay in reach where the phone bar's go (an address
    /// typed, the tabs out), so what one does first puts those away: the
    /// typing ends, as a touch on the page ends it; the tabs go, and Tabs
    /// again only puts them away, as the overview's own buttons do. In a
    /// wide window, where the tabs are along the top or in the sidebar and
    /// have no sheet, Tabs shows or hides them (Show or Hide Tab Bar).
    private func fromStrip(_ action: BarAction) {
        if tabSheet != nil {
            if case .showTabs = action { closeTabs(then: nil) } else { closeTabs(then: action) }
            return
        }
        if model.editingAddress { act(.cancelAddress) }
        if case .showTabs = action, !model.phone {
            act(.command(.tabBar))
            return
        }
        act(action)
    }

    /// The system's bars, which stand in the iPhone Duo's strip, shown only
    /// while the window has one (StripItems); a phone-width window's bar is
    /// one row then.
    private func showStrip(_ shown: Bool) {
        guard let navigation = navigationController else { return }
        if shown, stripItems == nil {
            stripItems = StripItems(in: self, session: .shared, window: model) { [weak self] in self?.fromStrip($0) }
        }
        // The page beside, slid in from the side on the phone bar, comes from
        // the strip's edge, not from under it.
        let clips = shown && model.strip != nil
        if stack.clipsToBounds != clips { stack.clipsToBounds = clips }
        guard navigation.isNavigationBarHidden == shown else { return }
        navigation.setNavigationBarHidden(!shown, animated: false)
        navigation.setToolbarHidden(!shown, animated: false)
        // The navigation bar's band at the top, taken back for the page (viewSafeAreaInsetsDidChange).
        if !shown, additionalSafeAreaInsets.top != 0 { additionalSafeAreaInsets.top = 0 }
    }


    /// A split's card's corners, rounded as the window's card's; none outside a split.
    private func round(_ view: UIView, _ corners: CACornerMask) {
        let radius = corners.isEmpty ? 0 : Side.card
        guard view.layer.cornerRadius != radius || view.layer.maskedCorners != corners else { return }
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.layer.maskedCorners = corners.isEmpty ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] : corners
        // A frozen page's picture always clips, to crop it; a page only for its corners.
        view.layer.masksToBounds = !corners.isEmpty || view is UIImageView
    }

    /// Where a split's cards go in the stage: all of it on the window's card,
    /// which has the frame round it already; with the tabs along the top, a
    /// bezel in from its edges, so the two stand on the frame as cards do.
    private func splitArea(in bounds: CGRect) -> CGRect {
        carded ? bounds : bounds.insetBy(dx: Side.bezel, dy: Side.bezel)
    }

    /// The divider dragged to `x` across the stage: the pages follow it, and
    /// even takes it, with a tap, when it comes within 15 points, holding it
    /// until it is pulled 20 away, as the Mac's.
    private func dragDivider(to x: CGFloat) {
        let area = splitArea(in: stage.bounds)
        let width = area.width - SplitDivider.width
        guard width > 0 else { return }
        var ratio = Double((x - area.minX - SplitDivider.width / 2) / width)
        let fromEven = abs(ratio - 0.5) * width
        if dragSnapped {
            if fromEven > 20 { dragSnapped = false } else { ratio = 0.5 }
        } else if fromEven <= 15 {
            dragSnapped = true
            ratio = 0.5
            evenTap.impactOccurred()
        }
        dragRatio = min(max(ratio, Split.ratios.lowerBound), Split.ratios.upperBound)
        layoutPanes()
    }

    private func dropDivider() {
        dragSnapped = false
        guard let ratio = dragRatio, let tab = model.tabID else { return }
        Session.shared.change { $0.setSplitRatio(tab, to: ratio) }
        dragRatio = nil
        layoutPanes()
    }

    func showSpace(_ space: UUID) {
        let session = Session.shared
        guard let target = session.workspace.space(space) else { return }
        // A tab this window has beside the one on screen is free for it.
        let free = { (tab: UUID) -> Bool in
            let shower = session.browser(showing: tab)
            return shower == nil || shower === self
        }
        let choice = [target.selected].compactMap { $0 }.first(where: free) ?? target.tabs.first { free($0.id) }?.id
        if let choice {
            show(tab: choice, inSpace: space, userInitiated: false)
        } else {
            showEmpty(space: space)
        }
    }

    private func showEmpty(space: UUID) {
        detach()
        model.spaceID = space
        model.tabID = nil
        model.url = nil
        model.title = ""
        model.banner = nil
        model.loading = false
        model.siteColor = nil
        empty?.view.isHidden = false
        refreshChrome()
        updateSceneTitle()
    }

    private func attach(_ page: Page, thawed: Bool) {
        // Another tab on screen: the next ⌘-click starts again right after
        // its own tab, as in Safari and Chrome.
        if openedBehind?.from != page.tab { openedBehind = nil }
        page.host = self
        page.view.frame = stage.bounds
        page.view.autoresizingMask = []
        page.view.isHidden = false
        stage.insertSubview(page.view, at: 0)
        empty?.view.isHidden = true
        self.page = page
        page.reviewPendingDialog()
        if thawed, let image = Session.shared.pages.picture(for: page.tab) {
            picture.image = image
            picture.alpha = 1
            picture.isHidden = false
        }
    }

    private func detach() {
        detachPartner()
        guard let page else { return }
        // While it still shows: the tab overview's picture of it.
        if model.phone { Session.shared.pages.keepPreview(of: page) }
        if page.view.superview === stage { page.view.removeFromSuperview() }
        if page.host === self { page.host = nil }
        self.page = nil
        picture.isHidden = true
        picture.image = nil
    }

    /// The picture of a frozen tab, taken away once its page has loaded.
    private func fadePicture() {
        guard !picture.isHidden, let page, !page.view.isLoading else { return }
        // Its page is back: the picture, a whole screen's, has done its work.
        Session.shared.pages.forgetPicture(of: page.tab)
        UIView.animate(withDuration: 0.2, animations: { self.picture.alpha = 0 }) { _ in
            self.picture.isHidden = true
            self.picture.image = nil
        }
    }

    private func workspaceChanged() {
        defer { refreshChrome() }
        let workspace = Session.shared.workspace
        if workspace.space(model.spaceID) == nil {
            showSpace(workspace.firstSpace.id)
            return
        }
        if let tab = model.tabID {
            if workspace.tab(tab) == nil {
                showSpace(model.spaceID)
                return
            }
            if let owner = workspace.spaceID(of: tab), owner != model.spaceID { model.spaceID = owner }
        }
        syncSplit()
        updateSceneTitle()
    }

    private func updateSceneTitle() {
        let space = Session.shared.workspace.space(model.spaceID)?.name ?? ""
        let title = model.title.isEmpty ? space : "\(model.title) · \(space)"
        // Asked after every change to the page; the system hears only a new one.
        if let scene = view.window?.windowScene, scene.title != title { scene.title = title }
    }

    /// The keys back to the page: whenever the window becomes active, and
    /// after anything that took them (the address bar, a sheet).
    func focusPage() {
        guard let page, presentedViewController == nil, tabSheet == nil, !model.editingAddress else { return }
        _ = page.view.becomeFirstResponder()
    }

    // MARK: PageHost

    func pageDidChange(_ page: Page) {
        if page === partner, !partnerPicture.isHidden, !page.view.isLoading {
            Session.shared.pages.forgetPicture(of: page.tab)
            UIView.animate(withDuration: 0.2, animations: { self.partnerPicture.alpha = 0 }) { _ in
                self.partnerPicture.isHidden = true
                self.partnerPicture.image = nil
            }
        }
        if page === partner {
            partnerBar.refresh()
            if DeveloperBar.isOn(page) != laidPartnerDeveloper { layoutPanes() }
            layoutMeasureCard()
        }
        guard page === self.page else { return }
        developerBar.refresh()
        if DeveloperBar.isOn(page) != laidDeveloper { layoutPanes() }
        layoutMeasureCard()
        let view = page.view
        // The page's colour behind the desktop view, as it loads and changes.
        if desktopPad?.page === page { stage.backgroundColor = view.underPageBackgroundColor }
        // A page that has come to stand clear of the phone bar, or to run under it again, is laid out anew.
        let clear = page.standsClear && desktopPad?.page !== page && phoneCovered > 0
        if clear != laidClear { layoutPanes() }
        if laidClear { stage.backgroundColor = page.footColor?.uiColor ?? view.underPageBackgroundColor }
        model.set(\.url, to: page.displayURL ?? Session.shared.workspace.tab(page.tab)?.url)
        // The page's edge beside the strip, as it loads and scrolls.
        placeStripGround()
        model.set(\.title, to: view.title ?? "")
        model.set(\.loading, to: view.isLoading)
        if model.load.fraction != view.estimatedProgress { model.load.fraction = view.estimatedProgress }
        model.set(\.canGoBack, to: view.canGoBack)
        model.set(\.canGoForward, to: view.canGoForward)
        model.set(\.secure, to: page.failure == nil && page.displayURL?.scheme?.lowercased() == "https" && view.hasOnlySecureContent)
        model.set(\.signIn, to: page.isSignIn)
        model.set(\.siteColor, to: page.siteColor)
        model.set(\.mobileSite, to: page.mode == .mobile)
        model.set(\.writingCardOpen, to: page.writingCardOpen)
        if page.googleRefused {
            model.set(\.banner, to: .googleRefused)
        } else if page.exhausted {
            model.set(\.banner, to: .exhausted)
        } else {
            model.set(\.banner, to: page.failure.map(Banner.failed))
        }
        refreshChrome()
        updateSceneTitle()
        fadePicture()
    }

    func pageDidAdvance(_ page: Page) {
        guard page === self.page else { return }
        let fraction = page.view.estimatedProgress
        if model.load.fraction != fraction { model.load.fraction = fraction }
    }

    func isShowing(_ page: Page) -> Bool {
        connected && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive &&
            !page.view.isHidden && (page === self.page || page === partner)
    }

    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView? {
        // A window with a size asked for is a pop-up: a sign-in, a share
        // dialog. It opens over this window and closes by itself when done.
        if features.width != nil || features.height != nil {
            let popup = Popup(opener: page, configuration: configuration)
            popup.closed = { [weak self] in self?.focusPage() }
            present(popup, animated: true)
            return popup.page.view
        }
        // Anything else is a tab, right after the one it came from; behind
        // this one when a ⌘-click asked for it (a page that answers ⌘-click
        // with window.open), live there with its tie to this page.
        let session = Session.shared
        let behind = page.newTabChoice(for: action) == .behind
        guard let id = session.change({ $0.openTab(action.request.url, in: page.space,
                                                   after: behind ? behindAfter(page) : page.tab) }) else {
            return nil
        }
        let child = session.pages.adopt(tab: id, space: page.space, configuration: configuration)
        if behind {
            openedBehind = (page.tab, id)
            session.pages.enforce()
            return child.view
        }
        openedBehind = nil
        detach()
        attach(child, thawed: false)
        model.tabID = id
        model.spaceID = page.space
        syncSplit()
        pageDidChange(child)
        focusPage()
        session.pages.enforce()
        return child.view
    }

    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool {
        let session = Session.shared
        let after = inFront ? page.tab : behindAfter(page)
        guard let id = session.change({ workspace -> UUID? in
            let id = workspace.openTab(url, in: page.space, after: after)
            // Opened behind: the tab on screen stays the one the space opens on next time.
            if !inFront, id != nil { workspace.select(page.tab) }
            return id
        }) else {
            return false
        }
        if inFront {
            openedBehind = nil
            show(tab: id, inSpace: page.space)
        } else {
            // It loads when it is first shown, as every tab not on screen does.
            openedBehind = (page.tab, id)
        }
        return true
    }

    /// Where a tab opened behind goes: after the last one opened behind
    /// from the same tab, so several ⌘-clicks keep their order, as in Safari.
    private func behindAfter(_ page: Page) -> UUID {
        if let last = openedBehind, last.from == page.tab, Session.shared.workspace.tab(last.opened) != nil {
            return last.opened
        }
        return page.tab
    }

    func pageDidClose(_ page: Page) {
        guard page === self.page || page === partner else { return }
        Session.shared.closeTab(page.tab)
    }

    var presenter: UIViewController? {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        return top
    }

    // MARK: Commands

    override var keyCommands: [UIKeyCommand]? {
        if tabSheet != nil {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeTabsKey))
            escape.wantsPriorityOverSystemBehavior = true
            return (super.keyCommands ?? []) + [escape]
        }
        guard model.editingAddress else { return (super.keyCommands ?? []) + phoneKeys }
        var keys = [(UIKeyCommand.inputEscape, #selector(cancelAddress))]
        // ↑ and ↓ through the suggestions, ahead of the field's own start and end of line.
        if !model.suggestions.rows.isEmpty {
            keys += [(UIKeyCommand.inputUpArrow, #selector(suggestionUp)), (UIKeyCommand.inputDownArrow, #selector(suggestionDown))]
        }
        // A phone's browser keys stay while an address is typed, as the
        // menu's do where there is one: ⌘T again, a tab by its number.
        return (super.keyCommands ?? []) + keys.map { input, action in
            let key = UIKeyCommand(input: input, modifierFlags: [], action: action)
            key.wantsPriorityOverSystemBehavior = true
            return key
        } + phoneKeys
    }

    /// The browser's keys on a phone with a keyboard attached, where UIKit
    /// hasn't built the main menu that carries them (Menus.built): every
    /// command this window has, and Tab 1 to 9.
    private var phoneKeys: [UIKeyCommand] {
        guard Device.phone, !Menus.built, GCKeyboard.coalesced != nil else { return [] }
        let commands = ShortcutGroup.allCases.flatMap(\.commands).filter { Device.offers($0, in: model) }
        return commands.compactMap { Menus.keyCommand($0) } + Menus.tabNumbers()
    }

    /// The main menu has every command a window of this device can have:
    /// those this window can't (an iPhone Duo closed has no tab bar) are
    /// hidden while it has the keys, and do nothing. Shown again when it
    /// can: the menu isn't built again as a window turns wide, or as
    /// another window takes the keys.
    override func validate(_ command: UICommand) {
        super.validate(command)
        guard command.action == #selector(browserCommand(_:)), let raw = command.propertyList as? String,
              let browserCommand = Command(rawValue: raw)
        else { return }
        command.title = model.title(for: browserCommand)
        if Device.offers(browserCommand, in: model) {
            command.attributes.remove(.hidden)
        } else {
            command.attributes.insert(.hidden)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(browserCommand(_:)), let command = sender as? UICommand,
           let raw = command.propertyList as? String, let browserCommand = Command(rawValue: raw) {
            return Device.offers(browserCommand, in: model)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func browserCommand(_ sender: UICommand) {
        guard let raw = sender.propertyList as? String, let command = Command(rawValue: raw) else { return }
        perform(command)
    }

    @objc func browserTab(_ sender: UICommand) {
        guard let number = sender.propertyList as? Int else { return }
        selectTab(number: number)
    }

    @objc private func cancelAddress() {
        act(.cancelAddress)
    }

    @objc private func suggestionUp() {
        model.suggestions.move(-1)
    }

    @objc private func suggestionDown() {
        model.suggestions.move(1)
    }

    /// Escape: the tabs go at once, as anything the keys do goes, unanimated.
    @objc private func closeTabsKey() {
        afterTabs = nil
        tabSheet?.closeNow()
    }

    @objc private func touchedPage() {
        if model.editingAddress { act(.cancelAddress) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === addressDismissTap { return model.editingAddress }
        guard let swipe = barSwipe, gestureRecognizer === swipe else { return true }
        // A swipe about to begin has none before it still going.
        endBarGesture()
        // A press on the pinned button is the button's: up or down, or held,
        // it goes through the pinned tabs (PinnedPress); only sideways, before
        // that, is the bar's, to the pinned tab beside.
        let (now, moved) = (swipe.location(in: swipe.view), swipe.translation(in: swipe.view))
        if let press = pinnedPress(at: CGPoint(x: now.x - moved.x, y: now.y - moved.y), in: swipe.view),
           press.holding || abs(moved.x) <= abs(moved.y) {
            return false
        }
        // Never while an address is typed, where drags are the text field's.
        guard !model.editingAddress else { return false }
        let velocity = swipe.velocity(in: swipe.view)
        // More up than across: the tabs, drawn up out of the bar. Not while
        // a slide settles, with the page still between two tabs.
        if abs(velocity.x) <= abs(velocity.y) {
            guard velocity.y < 0, pageSlide.gesture == .idle else { return false }
            pageSlide.gesture = .tabs
            return true
        }
        // More across than up: the tab beside, where the space has one. Not
        // in the desktop view, whose page is laid out by its own trackpad,
        // nor while the tabs are out or sinking back into the bar. A slide
        // still settling is caught where it is, and the finger goes on with it.
        if desktopPad != nil {
            toast(ActionToast(symbol: "square.on.square", text: String(localized: "Use Tabs to switch in Trackpad View")))
            return false
        }
        guard model.phone, tabSheet == nil, presentedViewController == nil,
              pageSlide.gesture == .idle || pageSlide.gesture == .settling
        else { return false }
        return pageSlide.begin()
    }

    /// The bar's swipe has let go of its touches. Its action had the end,
    /// unless the swipe never began: let through above, then failed or
    /// cancelled before it began, as the system can do to a touch, it told
    /// its action nothing, and the bar would go on thinking a swipe was
    /// under way, turning every other one down until the app was quit.
    private func barSwipeLetGo() {
        guard barSwipe?.state == .possible else { return }
        endBarGesture()
    }

    /// Ends a swipe the bar thinks is under way, as a cancelled one ends:
    /// the tabs back into the bar, the page back where it was. Nothing for
    /// a slide settling, which ends by itself.
    private func endBarGesture() {
        switch pageSlide.gesture {
        case .tabs:
            tabSheet?.release(up: 0)
            pageSlide.gesture = .idle
        case .sliding:
            pageSlide.cancel()
        case .idle, .settling:
            break
        }
    }

    /// The pinned button's press under `point` in `view`, if the point is on it.
    private func pinnedPress(at point: CGPoint, in view: UIView?) -> PinnedPress? {
        var hit = view?.hitTest(point, with: nil)
        while let shown = hit {
            if let touch = shown as? PinnedTouchView { return touch.press }
            hit = shown.superview
        }
        return nil
    }

    /// A swipe up on the bar draws the tabs up out of it, under the finger
    /// (TabSheet). Measured against the window's view: the bar moves with
    /// the finger, so against the bar a drag would seem to go nowhere.
    @objc private func swipedBar(_ swipe: UIPanGestureRecognizer) {
        if pageSlide.gesture == .sliding {
            pageSlide.drag(swipe, in: view)
            return
        }
        switch swipe.state {
        case .began:
            guard presentedViewController == nil, let sheet = makeTabSheet() else { return }
            sheet.beginDrag()
        case .changed:
            tabSheet?.drag(up: -swipe.translation(in: view).y)
        case .ended:
            tabSheet?.release(up: -swipe.velocity(in: view).y)
            pageSlide.gesture = .idle
        case .cancelled, .failed:
            tabSheet?.release(up: 0)
            pageSlide.gesture = .idle
        default:
            break
        }
    }

    func perform(_ command: Command) {
        let session = Session.shared
        switch command {
        case .everything:
            model.listsEverything = true
            act(.editAddress)
        case .address:
            // Back to the page's address, if everything was listed.
            if model.listsEverything { model.listsEverything = false }
            act(.editAddress)
        case .newTab: newTab()
        case .closeTab:
            if let tab = model.tabID { closeTab(tab) }
        case .reopenTab:
            if let tab = session.change({ $0.reopen() }) { show(tab: tab, inSpace: model.spaceID) }
        case .reload: page?.reload()
        case .stop: page?.view.stopLoading()
        case .back: page?.view.goBack()
        case .forward: page?.view.goForward()
        case .nextTab: stepTab(1)
        case .previousTab: stepTab(-1)
        case .nextSpace: stepSpace(1)
        case .previousSpace: stepSpace(-1)
        case .newSpace: newSpace()
        case .newWindow:
            let tab = session.change { $0.openTab(nil, in: model.spaceID) }
            // Where no window can be made after all, the new tab comes up here.
            session.openWindow(space: model.spaceID, tab: tab) { [weak self] in
                guard let self, let tab else { return }
                show(tab: tab, inSpace: model.spaceID)
            }
        case .closeWindow:
            if let scene = view.window?.windowScene {
                UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil, errorHandler: nil)
            }
        case .tabBar: session.preferences.tabBar.toggle()
        case .diagnostics: session.preferences.diagnostics.toggle()
        case .settings: openSettings()
        case .focusPage:
            model.editingAddress = false
            refreshChrome()
            focusPage()
        case .pinTab:
            guard let tab = model.tabID, let record = session.workspace.tab(tab) else { return }
            session.change { record.isPinned ? $0.unpin(tab) : $0.pin(tab) }
        case .splitTab:
            guard let tab = model.tabID else { return }
            if session.workspace.split(containing: tab) != nil {
                session.change { $0.separate(tab) }
            } else {
                splitWithNewTab()
            }
        case .bookmark: toggleBookmark()
        case .share: sharePage()
        case .copyLink: if let url = model.url { copy(url) }
        case .siteMode: switchSiteMode()
        case .contentBlocking: switchBlocking()
        case .linkMenu: switchOwnMenus()
        case .find: page?.find()
        case .handoff: handoff()
        case .handoffFile: chooseHandoffFile()
        case .history: openHistory()
        case .spaceSettings: openSpaceSettings(model.spaceID)
        case .importBookmarks: chooseBookmarksFile()
        // ⌃⌥G takes the open card's first suggestion, and does nothing
        // while no card is up (writing.js acceptFirst).
        case .acceptWritingSuggestion:
            if page?.writingCardOpen == true { Task { _ = await page?.writingAcceptFirst() } }
        case .reloadOrigin: page?.view.reloadFromOrigin()
        case .elementPicture: elementPicture()
        case .measure: page?.toggleMeasuring()
        case .developerMode: switchDeveloperMode()
        // No Web Inspector in an iOS app: the Mac's three do nothing here.
        case .inspector, .console, .selectElement: break
        }
    }

    /// A new tab beside the one on screen, typed into, as Dia's split.
    private func splitWithNewTab() {
        guard let tab = model.tabID, let new = Session.shared.change({ $0.splitWithNewTab(tab) }) else { return }
        show(tab: new, inSpace: model.spaceID)
        act(.editAddress)
    }

    /// `other` beside the tab on screen, on its right.
    private func split(with other: UUID) {
        let session = Session.shared
        guard let tab = model.tabID, session.change({ $0.split(tab, with: other) }) else { return }
        syncSplit()
        focusPage()
    }

    /// A new tab, and the command bar open for it with everything listed:
    /// an address or a search typed there goes in the new tab. A tab chosen
    /// is gone to instead, and a command runs on the page the bar was opened
    /// over, the new tab put away again either way (leave).
    private func newTab() {
        // Asked for again in the new tab's own bar (⌘T twice): the tab is
        // there already, still empty, so the bar only starts over.
        if let made = madeForBar, made.tab == model.tabID, Session.shared.workspace.tab(made.tab)?.url == nil {
            model.listsEverything = true
            act(.editAddress)
            return
        }
        let from = model.tabID
        guard let tab = Session.shared.change({ $0.openTab(nil, in: model.spaceID, after: from) }) else { return }
        show(tab: tab, inSpace: model.spaceID)
        model.listsEverything = true
        act(.editAddress)
        madeForBar = MadeTab(tab: tab, from: from)
    }

    /// The next tab along that no other window shows, going round; past
    /// the pinned tabs this device hides, as its row is.
    private func stepTab(_ direction: Int) {
        let session = Session.shared
        let shows = session.preferences.shows
        guard let current = model.tabID, let tabs = session.workspace.space(model.spaceID)?.tabs.filter(shows),
              tabs.count > 1 else { return }
        for offset in 1..<tabs.count {
            guard let next = session.workspace.neighbour(of: current, by: direction * offset, among: shows) else { return }
            // The pane beside is a step like any tab: it takes the keys.
            let shower = session.browser(showing: next)
            if shower == nil || shower === self {
                show(tab: next, inSpace: model.spaceID)
                return
            }
        }
    }

    private func stepSpace(_ direction: Int) {
        guard let next = Session.shared.workspace.spaceNeighbour(of: model.spaceID, by: direction),
              next != model.spaceID else { return }
        showSpace(next)
    }

    /// ⌃⌥1 to ⌃⌥8 the tab in that place in the row, ⌃⌥9 the last.
    private func selectTab(number: Int) {
        let session = Session.shared
        guard let tabs = session.workspace.space(model.spaceID)?.tabs.filter(session.preferences.shows), !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        show(tab: tabs[index].id, inSpace: model.spaceID)
    }

    private func newSpace() {
        let number = Session.shared.workspace.spaces.count + 1
        Dialogs.name(title: String(localized: "New Space"), message: String(localized: "A space has its own tabs and its own sign-ins."),
                     placeholder: String(localized: "Space \(number)"), initial: "", on: presenter ?? self) { [weak self] name in
            guard let self, let name else { return }
            let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let space = Session.shared.change { $0.addSpace(named: chosen.isEmpty ? String(localized: "Space \(number)") : chosen) }
            self.showSpace(space)
            self.act(.editAddress)
        }
    }

    private func removeSpace(_ id: UUID) {
        guard let space = Session.shared.workspace.space(id), Session.shared.workspace.spaces.count > 1 else { return }
        Dialogs.confirmRemoval(of: space, on: presenter ?? self) { sure in
            if sure { Session.shared.removeSpace(id) }
        }
    }

    /// Everything the bars and the empty space can ask for.
    func act(_ action: BarAction) {
        let session = Session.shared
        switch action {
        case .select(let tab): show(tab: tab, inSpace: session.workspace.spaceID(of: tab) ?? model.spaceID)
        case .close(let tab): closeTab(tab)
        case .closeTabs(let tabs): requestCloseTabs(tabs)
        case .arrangeTabs(let arrangement): session.change { $0.arrangeTabs(in: model.spaceID, by: arrangement) }
        case .command(let command): perform(command)
        case .switchSpace(let space): showSpace(space)
        case .spaceInNewWindow(let space): session.openWindow(space: space, tab: nil)
        case .spaceSettings(let space): openSpaceSettings(space)
        case .removeSpace(let space): removeSpace(space)
        case .moveTab(let tab, let space): session.moveTab(tab, to: space, from: self)
        case .placeTab(let tab, let target):
            let destination = model.spaceID
            guard session.workspace.spaceID(of: target) == destination else { return }
            if let from = session.workspace.spaceID(of: tab), from != destination {
                session.moveTab(tab, to: destination, from: self, before: target) { [weak self] moved in
                    guard let self, let moved, self.model.spaceID == destination else { return }
                    self.placeMovedTab(moved, before: target, in: destination)
                }
            } else {
                placeMovedTab(tab, before: target, in: destination)
            }
        case .tabInNewWindow(let tab):
            // A tab goes to a window of its own alone; the pane beside it stays here.
            let beside = session.workspace.split(containing: tab)?.partner(of: tab)
            session.change { $0.separate(tab) }
            if model.tabID == tab {
                let next = beside ?? session.workspace.neighbour(of: tab, by: 1)
                let shower = next.flatMap { session.browser(showing: $0) }
                if let next, next != tab, shower == nil || shower === self {
                    show(tab: next, inSpace: model.spaceID)
                } else {
                    showEmpty(space: model.spaceID)
                }
            }
            // Where no window can be made after all, the tab comes back to this one.
            session.openWindow(space: session.workspace.spaceID(of: tab), tab: tab) { [weak self] in
                guard let self, let space = Session.shared.workspace.spaceID(of: tab) else { return }
                show(tab: tab, inSpace: space)
            }
        case .editAddress:
            model.editingAddress = true
            model.addressTurn += 1
            refreshChrome()
            awaitKeyboard()
        case .cancelAddress:
            model.editingAddress = false
            refreshChrome()
            focusPage()
        case .go(let text):
            // Read before typing ends, which lets the rows go.
            let chosen = model.suggestions.selected
            let made = madeForBar
            model.editingAddress = false
            if let chosen { take(chosen, leaving: made) } else { go(text) }
        case .suggestion(let row):
            let made = madeForBar
            model.editingAddress = false
            take(row, leaving: made)
        case .goDirect(let text):
            model.editingAddress = false
            go(text)
        case .open(let url):
            open(url)
        case .back: page?.view.goBack()
        case .forward: page?.view.goForward()
        case .reload: page?.reload()
        case .stop: page?.view.stopLoading()
        case .dismissBanner:
            model.banner = nil
            refreshChrome()
        case .pin(let tab): session.change { _ = $0.pin(tab) }
        case .unpin(let tab): session.change { _ = $0.unpin(tab) }
        case .repin(let tab): session.change { _ = $0.repin(tab) }
        case .backToPinned(let tab): backToPinned(tab)
        case .openInNewTab(let url):
            guard let tab = session.change({ $0.openTab(url, in: model.spaceID, after: model.tabID) }) else { return }
            show(tab: tab, inSpace: model.spaceID)
        case .toggleBookmark: toggleBookmark()
        case .removeBookmark(let id): session.change { $0.removeBookmark(id, in: model.spaceID) }
        case .newFolder(let name, let parent): session.change { _ = $0.addFolder(named: name, in: parent, of: model.spaceID) }
        case .renameBookmark(let id, let name): session.change { $0.renameBookmark(id, to: name, in: model.spaceID) }
        case .moveBookmark(let id, let folder): session.change { $0.moveBookmark(id, into: folder, in: model.spaceID) }
        case .importBookmarks: chooseBookmarksFile()
        case .showTabs: showTabs()
        case .downloads: Downloads.shared.present(on: presenter ?? self) { [weak self] item in
            self?.handOff(downloaded: item)
        }
        case .switchPane:
            if let tab = model.tabID, let other = session.workspace.split(containing: tab)?.partner(of: tab) {
                show(tab: other, inSpace: model.spaceID)
            }
        case .reviewPageDialog: page?.reviewPendingDialog()
        case .reviewExternalRequest: page?.reviewExternalRequest()
        case .desktopView: toggleDesktopView()
        case .writingSite: switchWriting()
        case .rawJSON: page?.toggleJSONView()
        case .inspectFromMac: inspectNote()
        case .splitWith(let other): split(with: other)
        case .splitWithNewTab: splitWithNewTab()
        case .separate(let tab): session.change { $0.separate(tab) }
        case .copy(let url): copy(url)
        case .swapSides(let tab): session.change { $0.swapSides(tab) }
        }
    }

    // MARK: Pinned tabs and bookmarks

    func moveRequestChanged() {
        toast(ActionToast(symbol: "exclamationmark.triangle", text: BrowserText.localized("The tab or space changed. Try moving it again.")))
    }

    private func placeMovedTab(_ tab: UUID, before target: UUID, in destination: UUID) {
        let session = Session.shared
        guard session.workspace.spaceID(of: tab) == destination,
              session.workspace.spaceID(of: target) == destination,
              let space = session.workspace.space(destination) else { return }
        let moving = space.split(containing: tab).map { [$0.left, $0.right] } ?? [tab]
        guard !moving.contains(target),
              let index = space.tabs.filter({ !moving.contains($0.id) }).firstIndex(where: { $0.id == target }) else { return }
        session.change { $0.moveTab(tab, toIndex: index) }
    }

    private func closeTab(_ id: UUID) {
        Session.shared.closeTab(id)
    }

    private func requestCloseTabs(_ ids: [UUID]) {
        let plan = TabClosePlan(workspace: Session.shared.workspace, requested: ids)
        guard !plan.ids.isEmpty else { return }
        guard plan.needsConfirmation else { Session.shared.closeTabs(plan.ids); return }
        let alert = UIAlertController(title: plan.title, message: plan.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: plan.actionTitle, style: .destructive) { _ in Session.shared.closeTabs(plan.ids) })
        (presenter ?? self).present(alert, animated: true)
    }

    /// A pinned tab at the page it was pinned with: loaded there when it is
    /// live, its frozen picture of where it had gone let go when it isn't.
    private func backToPinned(_ tab: UUID) {
        let session = Session.shared
        guard let url = session.change({ $0.backToPinned(tab) }) else { return }
        HistoryRecorder.shared.expect(.bookmark, url)
        if let live = session.pages.live[tab] {
            live.load(url)
        } else {
            session.pages.close(tab)
        }
    }

    /// The page on screen as its desktop site, or its mobile one: kept for
    /// the site, and loaded again. A choice the window's size would make
    /// anyway isn't kept.
    private func switchSiteMode() {
        guard let page, let url = page.view.url, let key = SiteMode.siteKey(url.host) else { return }
        let wanted: SiteMode = page.mode == .desktop ? .mobile : .desktop
        let size = view.window?.bounds.size ?? view.bounds.size
        let natural = SiteMode.choose(host: nil, width: Double(size.width), height: Double(size.height), overrides: [:])
        Session.shared.preferences.siteModes[key] = wanted == natural ? nil : wanted
        page.reload(as: wanted)
    }

    /// Ads and trackers allowed or blocked on the site on screen, kept for
    /// the site, and the page loaded again with it. Not on a hands-off page,
    /// which the blocker never touches, nor with blocking off in Settings.
    private func switchBlocking() {
        guard let page, let host = page.view.url?.host, !page.isHandsOff, Session.shared.preferences.blocksContent else { return }
        let on = Session.shared.preferences.blocksContent(onHost: host)
        Session.shared.preferences.setBlocksContent(!on, onHost: host)
        page.reload()
        refreshChrome()
        toast(.ads(blocked: !on))
    }

    /// The site on screen keeps its own context menus, or gets the app's
    /// link menu: kept for the site. No reload: the app's menu asks as it
    /// opens, and the page that is up is told to keep callouts away or to
    /// let them be (Page.settingsChanged).
    /// A picture of the element picked on the page (Page.pickElement,
    /// Page.picture(of:)): on the pasteboard, and a toast offering the
    /// share sheet for it.
    private func elementPicture(on target: Page? = nil) {
        // Developer mode's, which an iPhone has none of.
        guard !Device.phone, let page = target ?? self.page else { return }
        Task { @MainActor [weak self, page] in
            guard let self, let picked = await page.pickElement(),
                  let image = await page.picture(of: picked) else { return }
            UIPasteboard.general.image = image
            toast(ActionToast(symbol: "camera.viewfinder", text: String(localized: "Picture copied"),
                              action: (title: String(localized: "Share"), run: { [weak self] in self?.sharePicture(image) })))
        }
    }

    /// The share sheet for a copied element picture.
    private func sharePicture(_ image: UIImage) {
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.minY, width: 0, height: 0)
        }
        (presentedViewController ?? self).present(sheet, animated: true)
    }

    /// The developer bar's info button, where WebKit has no inspector on
    /// iOS: the page is looked at from a Mac's Safari instead.
    private func inspectNote() {
        toast(ActionToast(symbol: "info.circle",
                          text: String(localized: "To inspect this page, open Safari on a Mac and choose Develop › \(UIDevice.current.name).")))
    }

    /// Developer mode on or off for the site on screen, remembered for it
    /// either way, so the choice stands while the local-sites setting moves.
    private func switchDeveloperMode() {
        let preferences = Session.shared.preferences
        let on = !DeveloperMode.isOn(page?.view.url, choices: preferences.developerSites, local: preferences.developerLocal)
        setDeveloperMode(on, on: page)
    }

    /// Developer mode on or off for `target`'s site, kept for it: the page
    /// menu's switch, or a bar's address menu for its own pane's page.
    private func setDeveloperMode(_ on: Bool, on target: Page?) {
        guard !Device.phone, let target, let key = DeveloperMode.siteKey(target.view.url) else { return }
        Session.shared.preferences.developerSites[key] = on
        refreshChrome()
        layoutPanes()
        toast(ActionToast(symbol: "chevron.left.forwardslash.chevron.right",
                          text: on ? String(localized: "Developer Mode on for this site")
                                   : String(localized: "Developer Mode off for this site")))
    }

    private func switchOwnMenus() {
        guard let page, let host = page.view.url?.host, !page.isHandsOff else { return }
        let keeps = Session.shared.preferences.keepsOwnMenus(onHost: host)
        Session.shared.preferences.setKeepsOwnMenus(!keeps, onHost: host)
        refreshChrome()
    }

    /// Grammar checking on or off for the site on screen (Settings ›
    /// Writing › Sites): kept for the site, and the page that is up follows
    /// without loading again (Page.settingsChanged), so nothing typed in it
    /// is lost.
    private func switchWriting() {
        guard let page, let url = page.view.url, url.host != nil, !page.isHandsOff,
              Session.shared.preferences.writing else { return }
        let on = !WritingSites.isOff(url, sites: Session.shared.preferences.writingOffSites)
        Session.shared.preferences.setWritingChecks(!on, onHost: url.host)
        refreshChrome()
    }

    // MARK: The iPhone's desktop view

    /// In: the page laid out at an iPad's size as its desktop site, the
    /// cursor over it (DesktopPad). Out: the page as the window's size has it.
    private func toggleDesktopView() {
        guard let page else { return }
        if page.desktopView {
            leaveDesktopView()
            return
        }
        guard Device.phone, page.view.url != nil, !page.isHandsOff else { return }
        guard DesktopView.supportsTrackpad(voiceOver: UIAccessibility.isVoiceOverRunning, switchControl: UIAccessibility.isSwitchControlRunning) else {
            showTrackpadAlternative()
            return
        }
        page.desktopView = true
        if page.mode != .desktop { page.reload(as: .desktop) }
        showDesktopPad()
        refreshChrome()
        if !UserDefaults.standard.bool(forKey: "desktopHelpSeen") {
            UserDefaults.standard.set(true, forKey: "desktopHelpSeen")
            showDesktopHelp()
        }
    }

    private func desktopAccessibilityChanged() {
        guard page?.desktopView == true,
              !DesktopView.supportsTrackpad(voiceOver: UIAccessibility.isVoiceOverRunning, switchControl: UIAccessibility.isSwitchControlRunning) else { return }
        leaveDesktopView()
        showTrackpadAlternative()
    }

    private func showTrackpadAlternative() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: String(localized: "Use Normal Browsing"), message: String(localized: "Trackpad View does not support VoiceOver or Switch Control. Normal browsing keeps the page's native accessible controls available."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Continue Browsing"), style: .default))
        present(alert, animated: true)
    }

    /// The gestures, a row each with its sign, on a sheet as high as they
    /// are: the first time, and from the bar's … menu.
    private func showDesktopHelp() {
        guard presentedViewController == nil else { return }
        let help = UIHostingController(rootView: DesktopHelp(done: { [weak self] in self?.dismiss(animated: true) },
                                                             leave: { [weak self] in
            self?.dismiss(animated: true)
            self?.leaveDesktopView()
        }))
        help.view.backgroundColor = Palette.UI.ground
        help.modalPresentationStyle = .formSheet
        let width = min(view.bounds.width, 480)
        let height = help.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        help.preferredContentSize = CGSize(width: width, height: height)
        if let sheet = help.sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("desktopHelp")) { context in min(height, context.maximumDetentValue) }]
            sheet.prefersGrabberVisible = true
        }
        present(help, animated: true)
    }

    private func leaveDesktopView() {
        guard let page, page.desktopView else { return }
        page.desktopView = false
        hideDesktopPad()
        let size = view.window?.bounds.size ?? view.bounds.size
        let natural = SiteMode.choose(host: page.view.url?.host, width: Double(size.width), height: Double(size.height),
                                      overrides: Session.shared.preferences.siteModes)
        if natural != page.mode { page.reload(as: natural) }
        refreshChrome()
    }

    /// The pad for the page on screen when it is in the desktop view; none otherwise.
    private func showDesktopPad() {
        guard let page, page.desktopView else { return hideDesktopPad() }
        if desktopPad?.page === page { return }
        hideDesktopPad()
        let pad = DesktopPad(page: page, size: stage.bounds.size)
        pad.exitRequested = { [weak self] in self?.leaveDesktopView() }
        pad.helpRequested = { [weak self] in self?.showDesktopHelp() }
        stage.addSubview(pad)
        desktopPad = pad
        layoutPanes()
    }

    private func hideDesktopPad() {
        guard let pad = desktopPad else { return }
        desktopPad = nil
        pad.leave()
        layoutPanes()
    }

    /// Shows the space's tabs as a grid, from the phone bar's Tabs button:
    /// the bar turns into them, as a swipe up on it does.
    private func showTabs() {
        guard presentedViewController == nil else { return }
        if !model.phone {
            let overview = TabOverviewController(session: .shared, window: model, act: { [weak self] in self?.act($0) }, done: { [weak self] action in
                self?.dismiss(animated: true) { [weak self] in
                    if let action { self?.act(action) } else { self?.focusPage() }
                }
            })
            overview.modalPresentationStyle = .formSheet
            overview.preferredContentSize = CGSize(width: 800, height: 700)
            present(overview, animated: true)
            return
        }
        makeTabSheet()?.open()
    }

    /// The sheet of tabs over the page, under the bar it grows out of; the
    /// one there already when the bar is caught on its way.
    /// The pinned tab's button's panel, over the whole window, the strip too.
    private lazy var pinnedControl = PinnedControl(window: model, host: { [weak self] in
        self?.navigationController?.view ?? self?.view
    }, act: { [weak self] in self?.act($0) })

    private func makeTabSheet() -> TabSheet? {
        pinnedControl.close(animated: false)
        if let tabSheet { return tabSheet }
        guard model.phone, let bar = phoneBar?.view, !bar.isHidden else { return nil }
        let overview = TabOverviewController(session: Session.shared, window: model, act: { [weak self] action in
            self?.act(action)
        }, done: { [weak self] action in
            self?.closeTabs(then: action)
        })
        let sheet = TabSheet(content: overview, bar: bar)
        sheet.closed = { [weak self] in self?.tabSheetClosed() }
        addChild(sheet)
        sheet.view.frame = view.bounds
        sheet.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(sheet.view, belowSubview: bar)
        sheet.didMove(toParent: self)
        tabSheet = sheet
        return sheet
    }

    /// Done with the tabs. A tab goes on screen as the sheet goes, so the
    /// bar sinks back onto it; anything else waits until the bar is back.
    private func closeTabs(then action: BarAction?) {
        if let action, case .select = action { act(action) } else { afterTabs = action }
        tabSheet?.close()
    }

    private func tabSheetClosed() {
        guard let sheet = tabSheet else { return }
        sheet.willMove(toParent: nil)
        sheet.view.removeFromSuperview()
        sheet.removeFromParent()
        tabSheet = nil
        if let bar = phoneBar?.view {
            bar.transform = .identity
            bar.alpha = 1
            bar.isUserInteractionEnabled = true
        }
        if let action = afterTabs {
            afterTabs = nil
            act(action)
        } else {
            focusPage()
        }
    }

    /// The page on screen, through the system's share sheet. The web view
    /// goes in with its address: for a browser with Apple's entitlement, that
    /// is what puts Add to Home Screen in the sheet, so a web app gets its
    /// own icon on the Home Screen.
    /// The page's address goes without the tags that follow whoever opens
    /// it (Tracking.clean); the page itself goes too, for Add to Home Screen.
    private func sharePage() {
        guard let page, let url = page.view.url else { return }
        share([Tracking.clean(url), page.view])
    }

    func page(_ page: Page, copy url: URL) {
        copy(url)
    }

    /// An address to the clipboard, without the tags that follow whoever
    /// opens it (Tracking.clean), and a toast to say so: nothing else shows it.
    private func copy(_ url: URL) {
        UIPasteboard.general.url = Tracking.clean(url)
        toast(.linkCopied)
    }

    private var toastWait: Task<Void, Never>?
    /// The toast's own view, which takes touches while its toast has a button.
    private weak var toastHost: UIView?

    /// A link for another app the page went to unasked, again: held, said in
    /// a toast, since nothing else on screen changes; the page's menu reviews it.
    /// The menu is the focused pane's, so a split's other pane says to tap it first.
    func page(_ page: Page, held appLink: URL) {
        guard page === self.page || page === partner, isShowing(page) else { return }
        let name = AppLink.applicationName(for: appLink.scheme)
        let text = page === self.page
            ? name.map { String(localized: "Held a link to \($0). Review it in the … menu.") }
                ?? String(localized: "Held a link to another app. Review it in the … menu.")
            : name.map { String(localized: "The other pane held a link to \($0). Tap it, then review the link in the … menu.") }
                ?? String(localized: "The other pane held a link to another app. Tap it, then review the link in the … menu.")
        toast(ActionToast(symbol: "arrow.up.forward.app", text: text))
    }

    /// A download that has started or finished since the last look, said in
    /// a toast in a phone-width window in front: the phone bar has no
    /// downloads button (its … menu has Downloads and the … disc a count).
    /// What was there already at the first look is not news.
    private func downloadsChanged(_ items: [DownloadRecord]) {
        let before = downloadPhases
        downloadPhases = Dictionary(items.map { ($0.id, $0.phase) }, uniquingKeysWith: { first, _ in first })
        guard let before, model.phone, view.window?.isKeyWindow == true else { return }
        for item in items {
            switch (before[item.id], item.phase) {
            case (nil, .downloading):
                toast(ActionToast(symbol: "arrow.down.circle", text: String(localized: "Downloading \(item.name)")))
            case (.downloading?, .finished):
                toast(ActionToast(symbol: "checkmark.circle", text: String(localized: "Downloaded. It's in … › Downloads")))
            default:
                continue
            }
        }
    }

    /// What a command did that leaves nothing to see, said for a moment over
    /// the page and to VoiceOver; a new one takes the last one's place.
    func toast(_ toast: ActionToast) {
        model.toast = toast
        toastHost?.isUserInteractionEnabled = toast.action != nil
        UIAccessibility.post(notification: .announcement, argument: toast.text)
        toastWait?.cancel()
        toastWait = Task { [weak self] in
            try? await Task.sleep(for: toast.duration)
            guard !Task.isCancelled, let self, self.model.toast?.id == toast.id else { return }
            self.model.toast = nil
            self.toastHost?.isUserInteractionEnabled = false
        }
    }

    func page(_ page: Page, share url: URL) {
        share([Tracking.clean(url)])
    }

    var opensTabs: Bool {
        true
    }

    /// Handoff: the page on screen as a Markdown file, with the question
    /// and the page's address beside it, through the share sheet, where the
    /// app to read them is picked (Handoff.swift). Nothing of the page goes
    /// anywhere before that. A page with nothing to read as text (a
    /// picture, a PDF) goes as the words alone, which say where it is.
    ///
    /// A sheet says what Handoff does and how far it is (HandoffGuide),
    /// while the page is read, its file written and, where Apple
    /// Intelligence's model is there, the model asked (HandoffJob). The
    /// share sheet comes only at the sheet's own button, which is to be
    /// had once the file is as it will go.
    private func handoff() {
        guard let page, !page.isHandsOff, page.view.url != nil else { return }
        handoff(source: page)
    }

    /// The page or a file on it handed to another app: a link's file, a
    /// download, or one the person chose (DocumentSource).
    private func handoff(source: any HandoffSource) {
        guard Session.shared.preferences.handoff, Session.shared.hasIntelligence, presentedViewController == nil, !startsHandoff else { return }
        let page = source as? Page
        if let page, page.isHandsOff || page.view.url == nil { return }
        // A file is held until its job has it; a page is the tab's, and may go meanwhile.
        let file = page == nil ? source : nil
        handingOff?.finish(taken: false)
        handingOff = nil
        startsHandoff = true
        Task { [weak self, weak page] in
            // Whether the model is there to ask, known before the sheet says who organises the page.
            let mind = await PageMinds.mind()
            guard let self else { return }
            self.startsHandoff = false
            // Asked after the wait: the page may have gone, or something come up over it.
            guard self.presentedViewController == nil else { return }
            let chosen: any HandoffSource
            if let file {
                chosen = file
            } else {
                guard let page, self.page === page, !page.isHandsOff, page.view.url != nil else { return }
                chosen = page
            }
            let job = HandoffJob(source: chosen, mind: mind, space: self.model.spaceID)
            self.handingOff = job
            self.explain(job)
        }
    }

    /// Whether a page's menus offer to hand off a linked file: Handoff on
    /// and Apple Intelligence there, whatever the page on screen is.
    var takesHandoffFiles: Bool {
        Session.shared.preferences.handoff && Session.shared.hasIntelligence
    }

    /// "Handoff Linked File" in a link's menu: fetched through the tab's
    /// own view and read as the document it is.
    func page(_ page: Page, handOffFileAt url: URL) {
        handoff(source: DocumentSource(link: url, view: page.view))
    }

    /// "Handoff" beside a finished download: the sheet goes first, since
    /// the guide can't come up over it (explain needs nothing presented).
    private func handOff(downloaded item: DownloadRecord) {
        guard let file = item.file else { return }
        let source = DocumentSource(file: file, name: item.name, address: item.source)
        dismiss(animated: true) { [weak self] in self?.handoff(source: source) }
    }

    /// "Handoff File": the guide with no job yet, whose "Choose File…"
    /// is the Files picker (fileImporter).
    private func chooseHandoffFile() {
        guard Session.shared.preferences.handoff, Session.shared.hasIntelligence,
              presentedViewController == nil else { return }
        let colour = Session.shared.workspace.space(model.spaceID)?.color ?? .blue
        let controller = UIHostingController(rootView: HandoffChoosingView(colour: colour) { [weak self] url in
            self?.dismiss(animated: true) { [weak self] in
                self?.handoff(source: DocumentSource(file: url))
            }
        })
        controller.modalPresentationStyle = .formSheet
        present(controller, animated: true)
    }

    /// The share sheet for a handoff: the file (HandoffFile) and the words beside it.
    private func share(_ job: HandoffJob) {
        guard handingOff === job else { return }
        share(job.stage.hasFile ? [HandoffFile(job), job.prompt] : [job.prompt]) { [weak self] taken in
            // Not taken by any app: nothing is left behind.
            job.finish(taken: taken)
            if self?.handingOff === job { self?.handingOff = nil }
        }
    }

    /// What Handoff does, as a sheet over the page while it is made ready
    /// (HandoffGuide). Its button goes on to the share sheet; put away any
    /// other way, the handoff is off.
    private func explain(_ job: HandoffJob) {
        guard presentedViewController == nil else {
            // Something else came up over the page meanwhile: the handoff is off.
            job.finish(taken: false)
            handingOff = nil
            return
        }
        let colour = Session.shared.workspace.space(model.spaceID)?.color ?? .blue
        // From the bottom edge on a phone-width window, over the home indicator's room where the device has one.
        let stands = traitCollection.horizontalSizeClass == .compact && (view.window?.safeAreaInsets.bottom ?? 0) > 0
        var went = false
        let guide = UIHostingController(rootView: HandoffGuide(job: job, colour: colour, foot: stands ? 0 : HandoffGuide.edge) { [weak self] in
            guard !went else { return }
            went = true
            self?.guideClosed = nil
            self?.dismiss(animated: true) { self?.share(job) }
        })
        guide.view.backgroundColor = Palette.UI.ground
        guide.modalPresentationStyle = .formSheet
        // As high as what it says, on a phone from the bottom edge.
        let width = min(view.bounds.width, 480)
        let height = guide.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        guide.preferredContentSize = CGSize(width: width, height: height)
        if let sheet = guide.sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("guide")) { context in min(height, context.maximumDetentValue) }]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = HandoffGuide.corner
        }
        guideClosed = { [weak self] in
            guard !went else { return }
            went = true
            job.finish(taken: false)
            if self?.handingOff === job { self?.handingOff = nil }
        }
        guide.presentationController?.delegate = self
        present(guide, animated: true)
    }

    /// `done` hears whether the sheet ended with something taken.
    private func share(_ items: [Any], done: ((Bool) -> Void)? = nil) {
        guard presentedViewController == nil else {
            done?(false)
            return
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // From the bar the address is in: the address bar, or the row of tabs,
        // or the sidebar, under its page menu (SideTabs).
        if let popover = sheet.popoverPresentationController,
           let anchor = [phoneBar?.view, addressBar?.view, topBar?.view, sideTabs?.view, view].compactMap({ $0 })
               .first(where: { !$0.isHidden }) {
            popover.sourceView = anchor
            // Under a bar at the top; over the one at the bottom on a phone-width window.
            let below = anchor !== phoneBar?.view
            popover.sourceRect = anchor === sideTabs?.view
                ? CGRect(x: anchor.bounds.maxX - 28, y: Metrics.target - 4, width: 1, height: 1)
                : CGRect(x: anchor.bounds.midX, y: below ? anchor.bounds.maxY - 6 : anchor.bounds.minY + 6,
                         width: 1, height: 1)
            popover.permittedArrowDirections = below ? .up : .down
        }
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            done?(completed)
            self?.focusPage()
        }
        present(sheet, animated: true)
    }

    /// The page on screen into the space's bookmarks, or out of them.
    private func toggleBookmark() {
        guard let page, let url = page.view.url else { return }
        let session = Session.shared
        let space = model.spaceID
        let known = session.workspace.bookmark(for: url, in: space)
        if let known {
            session.change { $0.removeBookmark(known.id, in: space) }
        } else {
            session.change { $0.addBookmark(url, title: page.view.title ?? "", in: space) }
        }
        refreshChrome()
        // The star says so only where the address shows it.
        toast(.bookmark(added: known == nil))
    }

    /// A bookmarks file for this window's space, from Files: Chrome's or
    /// Firefox's export, Safari's Bookmarks.html, or the ZIP Safari's
    /// Export Browsing Data saves to Downloads.
    func chooseBookmarksFile() {
        guard presentedViewController == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.html, .zip], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let file = urls.first else { return }
        controller.dismiss(animated: true) { [weak self] in
            if let pending = self?.pendingBookmarkImport { self?.showBookmarkImport(pending) }
        }
        Session.shared.importBookmarks(from: file, into: model.spaceID) { [weak self] outcome in
            // The picker's copy, done with once it has been read.
            try? FileManager.default.removeItem(at: file)
            guard let self else { return }
            self.showBookmarkImport(outcome)
        }
    }

    private func showBookmarkImport(_ outcome: BookmarkImportOutcome) {
        pendingBookmarkImport = outcome
        guard presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        pendingBookmarkImport = nil
        let alert = UIAlertController(title: outcome.title, message: outcome.message, preferredStyle: .alert)
        if let parsed = outcome.parsed {
            for space in Session.shared.workspace.spaces {
                alert.addAction(UIAlertAction(title: String(localized: "Import into \(space.name)"), style: .default) { [weak self] _ in
                    self?.afterBookmarkAlert {
                        Session.shared.importBookmarks(parsed, into: space.id) { [weak self] next in self?.showBookmarkImport(next) }
                    }
                })
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        } else if outcome.needsSave {
            alert.addAction(UIAlertAction(title: String(localized: "Retry Saving"), style: .default) { [weak self] _ in
                self?.afterBookmarkAlert {
                    Session.shared.retryBookmarkImport(outcome) { [weak self] next in
                        self?.showBookmarkImport(next)
                    }
                }
            })
            alert.addAction(UIAlertAction(title: String(localized: "Keep Open"), style: .cancel))
        } else {
            if outcome.canChooseFile || outcome.isComplete {
                alert.addAction(UIAlertAction(title: outcome.isComplete ? String(localized: "Import Another File…") : String(localized: "Choose Another File…"), style: .default) { [weak self] _ in self?.afterBookmarkAlert { self?.chooseBookmarksFile() } })
            }
            alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .cancel) { [weak self] _ in self?.focusPage() })
        }
        present(alert, animated: true)
    }

    private func afterBookmarkAlert(_ action: @escaping () -> Void) {
        if presentedViewController != nil { dismiss(animated: true, completion: action) }
        else { action() }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        focusPage()
    }

    /// The space's history (HistoryView), as a sheet; a page chosen there opens here.
    func openHistory() {
        guard presentedViewController == nil else { return }
        let history = UIHostingController(rootView: HistoryView(spaceID: model.spaceID) { [weak self] url, newTab in
            guard let self else { return }
            if newTab, let tab = Session.shared.change({ $0.openTab(url, in: self.model.spaceID) }) {
                self.show(tab: tab, inSpace: self.model.spaceID)
            } else {
                self.open(url)
            }
        } done: { [weak self] in
            self?.dismiss(animated: true) { self?.focusPage() }
        })
        history.modalPresentationStyle = .formSheet
        history.presentationController?.delegate = self
        present(history, animated: true)
    }

    func openSpaceSettings(_ space: UUID) {
        guard presentedViewController == nil else { return }
        let editor = UIHostingController(rootView: NavigationStack {
            SpaceEditor(session: Session.shared, spaceID: space) { [weak self] in
                self?.dismiss(animated: true) { self?.focusPage() }
            }
        })
        editor.modalPresentationStyle = .formSheet
        editor.presentationController?.delegate = self
        present(editor, animated: true)
    }

    /// A row the address bar offered, chosen with Return or a tap. `made`
    /// is the new tab the bar was opened for, if it was.
    private func take(_ row: Suggestion, leaving made: MadeTab? = nil) {
        switch row.action {
        case .tab(let tab):
            refreshChrome()
            act(.select(tab))
            leave(made)
            focusPage()
        case .open(let url):
            HistoryRecorder.shared.expect(.typed, url)
            open(url)
        case .space(let space):
            refreshChrome()
            showSpace(space)
            leave(made)
            focusPage()
        case .command(let command):
            // New Tab taken in a new tab's own bar: the tab is there already.
            if command == .newTab, made != nil {
                refreshChrome()
                focusPage()
                return
            }
            // A command is for the page the bar was opened over (Reload Page,
            // Pin or Unpin Tab), not for the empty tab made to type in.
            leave(made)
            // The field is put away first: a command may open one again (New Tab).
            refreshChrome()
            perform(command)
            focusPage()
        case .setting(let anchor):
            leave(made)
            refreshChrome()
            openSettings(at: anchor)
        case .go(let text):
            go(text)
        }
    }

    /// The new tab the command bar was opened for is closed again when the
    /// row taken wasn't an address for it: nothing was ever asked of it,
    /// and it would be left behind empty. A window still on it (a command
    /// was taken, or a tab that another window has up) goes back first to
    /// the tab the bar was opened from.
    private func leave(_ made: MadeTab?) {
        let session = Session.shared
        guard let made, session.workspace.tab(made.tab)?.url == nil else { return }
        if model.tabID == made.tab, let from = made.from, session.workspace.tab(from) != nil {
            show(tab: from, inSpace: model.spaceID)
        }
        // With nowhere to go back to, closing it takes the window to its neighbour.
        session.closeTab(made.tab)
    }

    /// A typed line: an address, or a search with the chosen engine.
    private func go(_ text: String) {
        guard let url = Destination.url(for: text, engine: Session.shared.preferences.engine) else {
            refreshChrome()
            focusPage()
            return
        }
        HistoryRecorder.shared.expect(.typed, url)
        open(url)
    }

    /// A link from another app, or from any app once eGlu is the default
    /// browser: a tab of its own after this one, so the page it lands on top
    /// of (a Figma file, a message half written) stays as it was.
    func openLink(_ url: URL) {
        guard let tab = Session.shared.change({ $0.openTab(url, in: model.spaceID, after: model.tabID ?? firstTab) }) else { return }
        // A link that launched the app, or brought its window back after the
        // system let it go: the window isn't built yet, and building it shows
        // the tab it had (viewDidLoad), which would take this one's place.
        // This is the tab it comes up with instead.
        guard isViewLoaded else {
            firstTab = tab
            return
        }
        uncoverPage()
        // What the tabs were left for, as the + in them, would come after
        // and take the link's place: the link is what was asked for last.
        afterTabs = nil
        if tabSheet != nil {
            // As a tab chosen there: the tabs go as the page comes, the bar sinking back onto it.
            closeTabs(then: .select(tab))
        } else {
            show(tab: tab, inSpace: model.spaceID)
        }
    }

    /// The app's own sheets over the page go, Settings and the tabs among
    /// them, so a page from another app is seen at once rather than found
    /// later in the tabs. What waits on an answer stays: a page's dialog or
    /// sign-in window, the welcome; the page comes up under it.
    private func uncoverPage() {
        guard let presented = presentedViewController, !presented.isBeingDismissed else { return }
        var shown: UIViewController? = presented
        while let each = shown {
            if each.isModalInPresentation || each is UIAlertController || each is Popup { return }
            shown = each.presentedViewController
        }
        dismiss(animated: true) { [weak self] in self?.focusPage() }
        // As when it is swiped away: a handoff waiting on its guide is off.
        guideClosed?()
        guideClosed = nil
    }

    /// An address, in this window's tab, or in a new tab when there is none.
    func open(_ url: URL) {
        if let page {
            page.load(url)
        } else if let tab = Session.shared.change({ $0.openTab(url, in: model.spaceID) }) {
            show(tab: tab, inSpace: model.spaceID)
        }
        model.editingAddress = false
        refreshChrome()
        focusPage()
    }

    // MARK: Settings

    /// Settings, from its top; or at one of its parts, which the address
    /// bar finds by name ("change icon" for App Icon).
    func openSettings(at anchor: SettingsAnchor? = nil) {
        guard presentedViewController == nil else { return }
        let layouts = Device.settingsLayouts(compact: model.phone)
        let settings = UIHostingController(rootView: SettingsView(session: Session.shared, spaceID: model.spaceID,
                                                                  anchor: anchor, phoneLayout: layouts.phone,
                                                                  padLayout: layouts.pad) { [weak self] in
            self?.dismiss(animated: true) { self?.focusPage() }
        })
        settings.modalPresentationStyle = .formSheet
        settings.presentationController?.delegate = self
        present(settings, animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // Swiped away, or tapped outside of: the handoff's guide says so.
        guideClosed?()
        guideClosed = nil
        focusPage()
    }
}

/// The phone bar's swipe, up or sideways. SwiftUI's buttons would otherwise prevent it
/// whenever it starts on one of them, which on the bar is nearly always.
private final class BarSwipe: UIPanGestureRecognizer {
    /// Each time it is made ready for the next touch: after it ended or
    /// was cancelled, and after it failed, which its action never hears of.
    var finished: (() -> Void)?

    override func reset() {
        super.reset()
        finished?()
    }

    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool {
        false
    }

    override func shouldRequireFailure(of other: UIGestureRecognizer) -> Bool {
        false
    }
}

/// Where the pages are. It lays them out itself when its size changes: the
/// window's own layout comes before the stack has given it its new size,
/// and a page sized then kept the height it had over the keyboard.
/// The window's own view. UIKit runs a view's updateConstraints() again
/// when the reserved regions read in it change, as the iPhone Duo folds
/// and opens: the Browser lays its sidebar out to the fold from there.
private final class BrowserView: UIView {
    var constraintsUpdated: (() -> Void)?

    override func updateConstraints() {
        constraintsUpdated?()
        super.updateConstraints()
    }
}

private final class Stage: UIView {
    var laidOut: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        laidOut?()
    }
}

/// The window's toast (ActionToast), at the top right of the page under it.
private struct WindowToast: View {
    let window: WindowModel

    var body: some View {
        ToastView(toast: window.toast)
            .padding(12)
    }
}
