import AppKit
import WritingServiceKit
import PadCore
import SwiftUI
import WebEngineCore

/// What the command bar was opened for.
enum CommandBarPurpose: Equatable {
    /// ⌘T: what is chosen opens in a new tab, as in Arc.
    case newTab
    /// ⌘L, or a click on the address: the page on screen goes there.
    case here
}

/// One window: the space it shows, the tab of it on screen, and everything
/// the window's sidebar, command bar and find bar show about that tab.
@MainActor
final class WindowModel: ObservableObject, PageHost {
    @Published private(set) var spaceID: UUID {
        // Another space's bookmarks are not the ones asked for: they go. The
        // panel's own watch is in the sidebar's space, which goes with it.
        didSet { if spaceID != oldValue, bookmarksOpen { bookmarksOpen = false } }
    }
    @Published private(set) var tabID: UUID?
    /// The tab's page on screen; nil for a tab that has gone nowhere yet,
    /// and for a window whose space has no tab to show.
    @Published private(set) var page: Page?
    /// The page beside it while the tab on screen is in a split (Split View,
    /// the iPad's, shown as the Mac's Search shows two pages): the bars, the
    /// menus and the keys act on the tab on screen, and a click in this one
    /// gives it them (`focus(pane:)`).
    @Published private(set) var partner: Page?
    /// Moves on as the page beside says something new, for its card to draw again.
    @Published private(set) var partnerRevision = 0
    /// The Peek over the pages (PeekPage): the one of the page with the
    /// keys, or of the page beside.
    @Published private(set) var peek: PeekPage?

    // The page as the sidebar and the card show it.
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var secure = false
    @Published private(set) var failure: String?
    /// The page's HTTP status, for the developer bar; nil before the first answer.
    @Published private(set) var statusCode: Int?
    /// The page's zoom, 1 at actual size, for the page menu's (…) field.
    @Published private(set) var zoom = 1.0

    /// The words, when the page is a search with the chosen engine: the
    /// address shows them in its place (Destination.searchWords).
    var searchWords: String? {
        url.flatMap { Destination.searchWords(in: $0, engine: Session.shared.preferences.engine) }
    }

    /// The sidebar down the window's side; hidden, it slides out over the
    /// page when the pointer reaches the window's left edge (peeking).
    @Published var sidebarShown: Bool {
        didSet {
            UserDefaults.standard.set(sidebarShown, forKey: Self.sidebarKey)
            // The bookmarks go with the sidebar, and don't come back out with it.
            if !sidebarShown, bookmarksOpen { bookmarksOpen = false }
        }
    }
    @Published var sidebarWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.widthKey) }
    }
    @Published var peeking = false
    /// The space's bookmarks are out over the sidebar's list, as a popover
    /// is (BookmarksPanel), till one is chosen or they are put away.
    @Published var bookmarksOpen = false {
        didSet {
            if !bookmarksOpen { bookmarksFrame = .null }
            watchBookmarkClicks()
        }
    }
    /// Where the bookmarks are, in the window's own coordinates from its
    /// top (BookmarksPanel): a click anywhere else puts them away.
    var bookmarksFrame = CGRect.null
    /// The bookmarks bar's rows are out under its button along the top
    /// (BarPanel): the button's frame in the window (BrowserView.place),
    /// while they are.
    @Published var barPanelButton: CGRect? {
        didSet {
            if barPanelButton == nil { barPanelFrame = .null }
            watchBookmarkClicks()
        }
    }
    /// Where the bar's rows are, as `bookmarksFrame`.
    var barPanelFrame = CGRect.null
    private var bookmarksWatch: Any?
    /// What a command just did that leaves nothing to see, said for a
    /// moment over the page's top right (ActionToast).
    @Published var toast: ActionToast?
    /// The card beside the pinned tile or bar bookmark the pointer rests on
    /// (PinnedCardView): its whole name, and going back or to a split.
    @Published private(set) var pinnedCard: PinnedCard?
    /// The sidebar's trailing edge in the window (BrowserView.place): a
    /// card beside a tile or a row stands past it, over the page.
    var sidebarEdge: CGFloat = 0
    /// The card's wait to come, or to go.
    private var cardWait: Task<Void, Never>?
    private var toastWait: Task<Void, Never>?
    /// The peeking sidebar going back in, a moment after the pointer left it.
    private var unpeeking: Task<Void, Never>?
    @Published var commandBar: CommandBarPurpose?
    @Published var finding = false
    /// Moves on with each ⌘F, so the find bar takes the keys again when it is already open.
    @Published private(set) var findRequests = 0
    @Published var findText = ""
    /// The words looked for are nowhere on the page.
    @Published var findMissed = false
    /// Space Settings, open at the sidebar's foot: the list of spaces, or one space's own.
    @Published var spacesPanel: SpacesPanel?
    @Published var downloadsShown = false
    /// The page's own commands, open by the share symbol beside the address (PageActions).
    @Published var pageActionsShown = false
    /// The space's history (HistoryView), and Clear History, as sheets over the window.
    @Published var historyShown = false
    @Published var historyClearing = false
    /// The puzzle button's list of extensions (ExtensionBar.swift).
    @Published var extensionsShown = false
    /// The handoff being made ready, its sheet over the window while it is (HandoffSheet).
    @Published private(set) var handoff: HandoffJob?
    /// The file picker standing in the pane instead of a job ("Handoff File…").
    @Published var handoffChoosing = false
    /// A handoff asked for, waiting to hear whether the model is there.
    private var startsHandoff = false
    let sharing = Sharing()

    let suggestions = Suggestions()
    weak var window: NSWindow?
    /// Tabs opened behind this one by ⌘-clicks, in a row: each next one goes after the last.
    private var openedBehind: (from: UUID, last: UUID)?

    /// Narrowest, the top row's buttons still fit beside the window's own.
    static let widths: ClosedRange<CGFloat> = 220...420
    private static let sidebarKey = "sidebarShown"
    private static let widthKey = "sidebarWidth"

    init(space: UUID?) {
        let workspace = Session.shared.workspace
        let space = space.flatMap(workspace.space) ?? workspace.spaces[0]
        spaceID = space.id
        tabID = space.selected
        let defaults = UserDefaults.standard
        sidebarShown = defaults.object(forKey: Self.sidebarKey) == nil || defaults.bool(forKey: Self.sidebarKey)
        let width = defaults.double(forKey: Self.widthKey)
        sidebarWidth = width > 0 ? min(max(CGFloat(width), Self.widths.lowerBound), Self.widths.upperBound) : 248
    }

    var space: Space? {
        Session.shared.workspace.space(spaceID)
    }

    /// The tabs down the window's side, as the Mac has them unless Settings
    /// puts them along the top.
    var tabsInSidebar: Bool {
        (Session.shared.preferences.tabsPlacement ?? .sidebar) == .sidebar
    }

    var tab: TabRecord? {
        tabID.flatMap(Session.shared.workspace.tab)
    }

    /// The window is on screen: it shows its tab, unless another window does already.
    func appear() {
        Session.shared.register(self)
        if let tabID, let other = Session.shared.window(showing: tabID), other !== self {
            show(tab: nil, inSpace: spaceID)
        } else {
            show(tab: tabID, inSpace: spaceID)
        }
        #if DEBUG
        // For pictures of the window in a given state: `open eGlu.app --args -showing peek`.
        switch UserDefaults.standard.string(forKey: "showing") {
        case "commandBar": commandBar = .newTab
        case "address": commandBar = .here
        case "peek": peeking = true
        case "top": Session.shared.preferences.tabsPlacement = .top
        case "sidebar": Session.shared.preferences.tabsPlacement = .sidebar
        case "space":
            spacesPanel = .list
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.spacesPanel = .edit(self.spaceID) }
        case "spaces": spacesPanel = .list
        // Popovers once the window is up: asked for as it appears, some never showed.
        case "actions": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.pageActionsShown = true }
        case "handoff":
            Session.shared.preferences.handoff = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.startHandoff() }
        case "find": startFinding()
        // Developer mode on for the page on screen, and the measuring tool on it.
        case "developer": DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.toggleDeveloperMode() }
        case "measure": DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.page?.toggleMeasuring() }
        // Harper's panel for other apps, as over a field, with a lint made up.
        case "writingPanel":
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let json = #"{"start":0,"end":4,"rule":"SpellCheck","kind":"Spelling","message":"Did you mean to spell `IPTV` this way?","priority":0,"suggestions":[],"context":"IPTV"}"#
                guard let lint = try? JSONDecoder().decode(WritingIssue.self, from: Data(json.utf8)),
                      let frame = self.window?.frame, let screen = self.window?.screen ?? NSScreen.main else { return }
                let rect = CGRect(x: frame.midX - 20, y: screen.frame.maxY - frame.midY, width: 40, height: 18)
                WritingPanel.shared.show(lint: lint, at: rect, suggestions: ["IP's", "Int", "Iota"],
                                         canAddToDictionary: true) { _, _ in }
            }
        case "settings": Session.shared.openSettings?()
        case "appIcon": DockIcon.shared.showInSettings()
        // The tab on screen beside the next of the space's own tabs.
        case "split":
            if let other = space?.tabs.first(where: { !$0.isPinned && $0.id != tabID && $0.url != nil })?.id {
                split(with: other)
            }
        default: break
        }
        // In front, as a window in use is: one behind shows its tinted glass grey (`-front YES`).
        if UserDefaults.standard.bool(forKey: "front") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.activate(ignoringOtherApps: true) }
        }
        // Over other apps' windows without being in front, for a picture of the
        // glass with what is behind it while another app is in use (`-floating YES`).
        if UserDefaults.standard.bool(forKey: "floating") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.window?.level = .floating }
        }
        #endif
    }

    /// The window closed: its page stays live a while, as another tab off screen.
    func disappear() {
        // Its watch on clicks goes with it: AppKit keeps a monitor for the app's life.
        bookmarksOpen = false
        barPanelButton = nil
        putCardAway()
        attach(nil)
        setPartner(nil)
        // At once: the window is going, and won't be here to look later.
        checkScreen()
        // Its extension popup and side panel go with it.
        ExtensionPopups.shared.close(in: self)
        ExtensionSidePanels.shared.close(in: self)
        Session.shared.unregister(self)
        Session.shared.pages.enforce()
    }

    // MARK: Showing a tab

    /// `tab` of `space` on screen; nil shows the space's start. A tab that
    /// has gone nowhere yet gets no page until it goes somewhere.
    func show(tab: UUID?, inSpace space: UUID) {
        let session = Session.shared
        spaceID = space
        showing = true
        defer {
            showing = false
            syncSplit()
        }
        guard let tab, let record = session.workspace.tab(tab), session.workspace.spaceID(of: tab) == space else {
            tabID = nil
            attach(nil)
            return
        }
        tabID = tab
        session.change { $0.select(tab) }
        let live = session.pages.isLive(tab)
        // A tab of a split gets its page even before it has gone anywhere: its pane is on screen.
        let paired = session.workspace.split(containing: tab) != nil
        attach(record.url == nil && !live && !paired ? nil : session.pages.page(for: record, in: space))
        session.pages.enforce()
    }

    /// Showing a tab: the workspace changes on the way, and the page beside
    /// is worked out once the tab is on screen, not halfway.
    private var showing = false

    private func attach(_ next: Page?) {
        if next !== page {
            let old = page
            page = next
            release(old)
            next?.host = self
            screenMayHaveChanged()
        }
        refresh()
    }

    /// The pages on screen when last looked at (`checkScreen`).
    private var lastOnScreen: [Page] = []
    private var screenCheckWaiting = false

    /// Which pages are on screen may have changed: looked at once the change
    /// has settled, since a tab and the page beside it in a split change one
    /// after the other (`show` syncs the split last), and a page passing
    /// from one to the other hasn't left the screen.
    private func screenMayHaveChanged() {
        guard !screenCheckWaiting else { return }
        screenCheckWaiting = true
        DispatchQueue.main.async { [weak self] in self?.checkScreen() }
    }

    /// Tells each page that left the screen, and isn't shown in another
    /// window, and each that came onto it (Page.leftScreen, cameOnScreen).
    private func checkScreen() {
        screenCheckWaiting = false
        let now = [page, partner].compactMap { $0 }
        for old in lastOnScreen where !now.contains(where: { $0 === old }) && Session.shared.window(showing: old.tab) == nil {
            old.leftScreen()
        }
        for new in now where !lastOnScreen.contains(where: { $0 === new }) {
            new.cameOnScreen()
            new.reviewPendingDialog()
        }
        lastOnScreen = now
    }

    /// A page this window no longer shows hears from it no more.
    private func release(_ old: Page?) {
        guard let old, old !== page, old !== partner, old.host === self else { return }
        old.host = nil
    }

    /// The page's state, read again for the sidebar and the card.
    func refresh() {
        let record = tab
        let state = page?.state
        url = page?.displayURL ?? record?.url
        title = state?.title.flatMap { $0.isEmpty ? nil : $0 } ?? record?.label ?? ""
        loading = state?.isLoading ?? false
        progress = state?.estimatedProgress ?? 0
        canGoBack = (state?.canGoBack ?? false) || record.map { Session.shared.canGoBackPastReplacement($0.id) } ?? false
        canGoForward = state?.canGoForward ?? false
        secure = page?.failure == nil && url?.scheme == "https" && (state?.hasOnlySecureContent ?? true)
        failure = page?.failure
        statusCode = page?.statusCode
        zoom = page?.pageZoom ?? 1
        window?.title = record == nil ? (space?.name ?? "eGlu") : title
        syncPeek()
    }

    /// The Peek on screen, as the pages on screen have it: its page takes
    /// the keys as it comes, and gives them back to the page as it goes.
    private func syncPeek() {
        let now = page?.peek ?? partner?.peek
        guard now !== peek else { return }
        peek = now
        focusPage()
    }

    /// The keys go to the page, as they do after a click on it; to the
    /// Peek's while one is up, since the page under it is out of reach.
    func focusPage() {
        guard let view = peek?.page.surface.view ?? page?.surface.view else { return }
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(view) }
    }

    /// A tab chosen in the sidebar or the command bar: shown here, or the
    /// window that shows it comes forward.
    func select(_ tab: UUID) {
        let session = Session.shared
        putCardAway()
        if let other = session.window(showing: tab), other !== self {
            other.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let space = session.workspace.spaceID(of: tab) else { return }
        show(tab: tab, inSpace: space)
        focusPage()
    }

    func showSpace(_ id: UUID) {
        guard let space = Session.shared.workspace.space(id), id != spaceID || tabID == nil else { return }
        putCardAway()
        barPanelButton = nil
        var tab = space.selected
        if let shown = tab, let other = Session.shared.window(showing: shown), other !== self { tab = nil }
        withAnimation(.bar) { show(tab: tab, inSpace: id) }
        focusPage()
    }

    func showSpace(by offset: Int) {
        guard let next = Session.shared.workspace.spaceNeighbour(of: spaceID, by: offset) else { return }
        showSpace(next)
    }

    func showSpace(number: Int) {
        let spaces = Session.shared.workspace.spaces
        guard spaces.indices.contains(number - 1) else { return }
        showSpace(spaces[number - 1].id)
    }

    // MARK: Split View

    /// The split the tab on screen is in.
    var split: Split? {
        tabID.flatMap { Session.shared.workspace.split(containing: $0) }
    }

    /// Whether `tab` is on screen in this window, with the keys or beside.
    func shows(_ tab: UUID) -> Bool {
        (tabID == tab && page != nil) || partner?.tab == tab
    }

    /// The workspace changed: the page beside, as the split now has it.
    func workspaceChanged() {
        guard !showing else { return }
        syncSplit()
    }

    /// The page beside, as the workspace's split has it: found or made when
    /// the tab on screen is in one, let go when it isn't, or when another
    /// window has that tab on screen.
    func syncSplit() {
        let session = Session.shared
        let workspace = session.workspace
        guard let tab = tabID, page != nil, let other = workspace.split(containing: tab)?.partner(of: tab),
              let record = workspace.tab(other), let space = workspace.spaceID(of: other),
              !session.allWindows.contains(where: { $0 !== self && $0.shows(other) })
        else {
            if partner != nil {
                setPartner(nil)
                session.pages.enforce()
            }
            return
        }
        if partner?.tab != other || session.pages.live[other] !== partner {
            setPartner(session.pages.page(for: record, in: space))
            session.pages.enforce()
        }
    }

    private func setPartner(_ next: Page?) {
        guard next !== partner else { return }
        let old = partner
        partner = next
        release(old)
        next?.host = self
        watchClicks()
        screenMayHaveChanged()
        syncPeek()
    }

    /// The page beside takes the keys, and the bars with them.
    func focus(pane tab: UUID) {
        guard tab != tabID, tab == partner?.tab else { return }
        show(tab: tab, inSpace: spaceID)
        focusPage()
    }

    /// `other` beside the tab on screen, on its right; the tab on screen keeps the keys.
    func split(with other: UUID) {
        guard let tab = tabID, Session.shared.change({ $0.split(tab, with: other) }) else { return }
        syncSplit()
        focusPage()
    }

    /// A new tab on an extension's page for new tabs, with the address
    /// open over it to type in, as Chrome's new tab has the keys in its
    /// address bar.
    func openNewTabPage(_ url: URL, replacing: Bool = false) {
        let session = Session.shared
        commandBar = nil
        // A tab that has gone nowhere yet takes it, made as an extension's
        // page is (Pages.page(for:)); otherwise a new one.
        if let record = tab, record.url == nil, !session.pages.isLive(record.id) {
            session.change { $0.record(record.id, url: url, title: nil) }
            withAnimation(.bar) { show(tab: record.id, inSpace: spaceID) }
            newTabOpened = record.id
        } else if replacing, let record = tab, record.id == newTabOpened, !record.isPinned, record.url != url,
                  Extensions.shared.isNewTabPage(record.url, in: spaceID), session.pages.live[record.id]?.view.canGoBack != true {
            // The new tab ⌘T just opened, another extension's page still
            // where it opened (a yes to the question as it opened): this
            // one's page in its place, not a second new tab. Any other tab
            // on such a page is left as it is.
            session.replacePage(of: record.id, in: spaceID, with: url, keepingOld: false)
        } else if let id = session.change({ $0.openTab(url, in: spaceID) }) {
            withAnimation(.bar) { show(tab: id, inSpace: spaceID) }
            newTabOpened = id
        }
        commandBar = .here
    }

    /// The tab the last new-tab page went into, which a yes to another
    /// extension's question as it opened (`replacing`) gives that one's
    /// page instead; any other New Tab opens one.
    private var newTabOpened: UUID?

    /// A new tab beside the one on screen, on its right, with the keys and
    /// the command bar open for it.
    func splitWithNewTab() {
        guard let tab = tabID, let new = Session.shared.change({ $0.splitWithNewTab(tab) }) else { return }
        withAnimation(.bar) { show(tab: new, inSpace: spaceID) }
        commandBar = .newTab
    }

    /// The tab on screen and the one beside go back to being tabs of their own.
    func separate(_ tab: UUID? = nil) {
        guard let tab = tab ?? tabID else { return }
        withAnimation(.bar) { Session.shared.change { $0.separate(tab) } }
    }

    func swapSides(_ tab: UUID? = nil) {
        guard let tab = tab ?? tabID else { return }
        withAnimation(.bar) { Session.shared.change { $0.swapSides(tab) } }
    }

    /// The left page's share of the room, once the divider is let go.
    func setSplitRatio(_ ratio: Double) {
        guard let tab = tabID else { return }
        Session.shared.change { $0.setSplitRatio(tab, to: ratio) }
    }

    /// Both tabs of the split close.
    func closeSplit() {
        guard let tab = tabID, let other = partner?.tab else { return }
        requestCloseTabs([other, tab])
    }

    /// With two pages up, a click in the one without the keys gives it them,
    /// and is still the page's click. Watched, not taken: the click is WebKit's.
    private var clickWatch: Any?

    private func watchClicks() {
        if partner != nil, clickWatch == nil {
            clickWatch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.clicked(event)
                return event
            }
        } else if partner == nil, let watch = clickWatch {
            NSEvent.removeMonitor(watch)
            clickWatch = nil
        }
    }

    /// While the bookmarks are out, every click in the window is watched, not
    /// taken, as clickWatch watches for the pane beside.
    private func watchBookmarkClicks() {
        let out = bookmarksOpen || barPanelButton != nil
        if out, bookmarksWatch == nil {
            bookmarksWatch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.clickedAway(event)
                return event
            }
        } else if !out, let watch = bookmarksWatch {
            NSEvent.removeMonitor(watch)
            bookmarksWatch = nil
        }
    }

    /// A click in the window off the bookmarks, on the page, the address or
    /// a pinned tab, puts them away, as one outside a popover does; the
    /// click still goes where it was meant to. The same for the bar's rows
    /// along the top, but for a click on their own button, which puts them
    /// away itself.
    private func clickedAway(_ event: NSEvent) {
        guard let window, event.window === window, let content = window.contentView else { return }
        let point = event.locationInWindow
        // The window counts from its foot, SwiftUI from its top.
        let spot = CGPoint(x: point.x, y: content.bounds.height - point.y)
        if bookmarksOpen, !bookmarksFrame.contains(spot) {
            DispatchQueue.main.async { [weak self] in withAnimation(.bar) { self?.bookmarksOpen = false } }
        }
        if let button = barPanelButton, !barPanelFrame.contains(spot), !button.contains(spot) {
            DispatchQueue.main.async { [weak self] in withAnimation(.bar) { self?.barPanelButton = nil } }
        }
    }

    private func clicked(_ event: NSEvent) {
        guard let partner, let window, event.window === window, partner.surface.view.window === window else { return }
        let view = partner.surface.view
        guard view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return }
        // What lies over the page (the command bar, the find bar) is not the page: a click there moves nothing.
        if let hit = window.contentView?.hitTest(event.locationInWindow), hit !== view, !hit.isDescendant(of: view) { return }
        let tab = partner.tab
        DispatchQueue.main.async { [weak self] in self?.focus(pane: tab) }
    }

    // MARK: Going places

    /// A line typed: an address when it is one, a search otherwise.
    func go(_ typed: String, newTab: Bool) {
        guard let url = Destination.url(for: typed, engine: Session.shared.preferences.engine) else { return }
        HistoryRecorder.shared.expect(.typed, url)
        open(url, newTab: newTab)
    }

    /// `url` in a new tab, or in the tab on screen. A tab that has gone
    /// nowhere yet takes it either way.
    func open(_ url: URL, newTab: Bool) {
        let session = Session.shared
        if let record = tab, !newTab || record.url == nil {
            // An extension's page (a new tab's) can't show a website in its
            // view: the website takes its place in the tab, Back going back
            // to it, rather than opening beside it.
            if let live = session.pages.live[record.id], live.isExtensionPage, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                session.replacePage(of: record.id, in: spaceID, with: url)
                focusPage()
                return
            }
            let page = session.pages.page(for: record, in: spaceID)
            attach(page)
            page.load(url)
            focusPage()
            return
        }
        guard let id = session.change({ $0.openTab(url, in: spaceID) }) else { return }
        withAnimation(.bar) { show(tab: id, inSpace: spaceID) }
        focusPage()
    }

    func back() {
        page?.goBack()
    }

    func forward() {
        page?.goForward()
    }

    func reload() {
        if let page {
            page.reload()
        } else if let tabID {
            show(tab: tabID, inSpace: spaceID)
        }
    }

    func stop() {
        page?.stopLoading()
    }

    // MARK: Tabs

    func closeTab(_ id: UUID? = nil) {
        // ⌘W with a Peek up puts the Peek away, as in Arc.
        if id == nil, peek != nil {
            closePeek()
            return
        }
        guard let id = id ?? tabID else { return }
        withAnimation(.bar) { Session.shared.closeTab(id) }
        focusPage()
    }

    /// Arc's Clear: every tab of the space that isn't pinned or in the bookmarks bar.
    func clearTabs() {
        let ids = space?.otherTabs.map(\.id) ?? []
        requestCloseTabs(ids)
    }

    func requestCloseTabs(_ ids: [UUID]) {
        let plan = TabClosePlan(workspace: Session.shared.workspace, requested: ids)
        guard !plan.ids.isEmpty else { return }
        guard plan.needsConfirmation else { Session.shared.closeTabs(plan.ids); return }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = plan.title
        alert.informativeText = plan.message
        alert.addButton(withTitle: plan.actionTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { answer in
            if answer == .alertFirstButtonReturn { Session.shared.closeTabs(plan.ids) }
        }
    }

    func reopenTab() {
        let session = Session.shared
        guard let id = session.change({ $0.reopen() }), let space = session.workspace.spaceID(of: id) else { return }
        withAnimation(.bar) { show(tab: id, inSpace: space) }
        focusPage()
    }

    /// The next tab along in the sidebar, going round: past the pinned tabs this Mac hides, as the sidebar is.
    func selectTab(by offset: Int) {
        let shows = Session.shared.preferences.shows
        guard let tabID, let next = Session.shared.workspace.neighbour(of: tabID, by: offset, among: shows) else {
            if let first = space?.tabs.first(where: shows) { select(first.id) }
            return
        }
        select(next)
    }

    /// ⌘1 to ⌘8, the tab in that place in the sidebar; ⌘9 the last, as in every browser.
    func selectTab(number: Int) {
        guard let tabs = space?.tabs.filter(Session.shared.preferences.shows), !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    func togglePin(_ id: UUID? = nil) {
        guard let id = id ?? tabID else { return }
        withAnimation(.bar) {
            Session.shared.change { workspace in
                if !workspace.pin(id) { workspace.unpin(id) }
            }
        }
    }

    /// A pinned tab pinned anew at the page it is on.
    func repin(_ id: UUID) {
        Session.shared.change { _ = $0.repin(id) }
    }

    /// A pinned tab back at the address it was pinned with.
    func backToPinned(_ id: UUID) {
        let session = Session.shared
        guard let url = session.change({ $0.backToPinned(id) }) else { return }
        HistoryRecorder.shared.expect(.bookmark, url)
        if id == tabID, let record = tab {
            let page = page ?? session.pages.page(for: record, in: spaceID)
            attach(page)
            page.load(url)
        } else {
            session.pages.unload(id)
        }
    }

    func duplicate(_ id: UUID? = nil) {
        guard let id = id ?? tabID, let url = Session.shared.workspace.tab(id)?.url,
              let space = Session.shared.workspace.spaceID(of: id),
              let copy = Session.shared.change({ $0.openTab(url, in: space, after: id) })
        else { return }
        withAnimation(.bar) { show(tab: copy, inSpace: space) }
    }

    func move(_ id: UUID, to space: UUID) {
        Session.shared.moveTab(id, to: space, from: self)
    }

    /// Same-space drops reorder immediately; cross-space drops wait for an explicit choice.
    func place(_ id: UUID, pinned: Bool, before target: UUID?) {
        let session = Session.shared
        let destination = spaceID
        guard let from = session.workspace.spaceID(of: id),
              target.map({ session.workspace.spaceID(of: $0) == destination }) ?? true else { return }
        if from != destination {
            session.moveTab(id, to: destination, from: self, before: target) { [weak self] moved in
                guard let self, let moved, self.spaceID == destination else { return }
                self.placeMovedTab(moved, pinned: pinned, before: target, in: destination)
            }
        } else {
            placeMovedTab(id, pinned: pinned, before: target, in: destination)
        }
    }

    private func placeMovedTab(_ id: UUID, pinned: Bool, before target: UUID?, in destination: UUID) {
        let session = Session.shared
        guard session.workspace.spaceID(of: id) == destination,
              target.map({ session.workspace.spaceID(of: $0) == destination }) ?? true else { return }
        withAnimation(.bar) {
            session.change { workspace in
                guard let isPinned = workspace.tab(id)?.isPinned else { return }
                // From the bar's row into the list: out of the bar, its bookmark staying.
                if !pinned { workspace.separateFromBar(id) }
                if pinned != isPinned, !(pinned ? workspace.pin(id) : workspace.unpin(id)) { return }
                guard let tabs = workspace.space(destination)?.tabs, target != id else { return }
                let others = tabs.filter { $0.id != id }
                let index = target.flatMap { t in others.firstIndex { $0.id == t } }
                    ?? (pinned ? others.filter(\.isPinned).count : others.count)
                workspace.moveTab(id, toIndex: index)
            }
        }
    }

    /// The address as Share sends it, without the tags that follow whoever opens it (Tracking.clean).
    func copyLink(_ id: UUID? = nil) {
        guard let link = id.flatMap({ Session.shared.workspace.tab($0)?.url }) ?? url else { return }
        copyAddress(link)
    }

    /// An address to the pasteboard, and a toast to say so: nothing else shows it.
    func copyAddress(_ address: URL) {
        Self.copy(address)
        show(.linkCopied)
    }

    /// What a command did that leaves nothing to see, said for a moment over
    /// the page and to VoiceOver; a new one takes the last one's place.
    func show(_ toast: ActionToast) {
        self.toast = toast
        if let window {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: toast.text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        toastWait?.cancel()
        toastWait = Task { [weak self] in
            try? await Task.sleep(for: toast.duration)
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
    }

    /// An address to the pasteboard, without the tags that follow whoever opens it (Tracking.clean).
    static func copy(_ address: URL) {
        let link = Tracking.clean(address)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([link as NSURL])
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    // MARK: The bookmarks bar

    /// A bookmark of the bar in its own tab, which stands in the bar's row:
    /// the one open for it already, or a new one. With ⌘ held, its page in an
    /// ordinary new tab instead, as a ⌘-click on a link does.
    func openFromBar(_ bookmark: UUID) {
        let session = Session.shared
        pinnedCard = nil
        guard let url = space.flatMap({ Bookmarks.find(bookmark, in: $0.bookmarks)?.url }) else { return }
        HistoryRecorder.shared.expect(.bookmark, url)
        if NSEvent.modifierFlags.contains(.command) {
            open(url, newTab: true)
            return
        }
        guard let tab = session.change({ $0.openFromBar(bookmark, in: spaceID) }) else { return }
        // As a tab chosen in the sidebar: the window that shows it already comes forward.
        withAnimation(.bar) { select(tab) }
    }

    /// A tab into the bar, at the end of `folder` (nil: the bar itself) or before `before` there.
    func addToBar(_ tab: UUID, into folder: UUID? = nil, before: UUID? = nil) {
        withAnimation(.bar) { _ = Session.shared.change { $0.addToBar(tab, into: folder, before: before) } }
    }

    /// One of the bar's bookmarks or folders to another place in it.
    func moveInBar(_ bookmark: UUID, into folder: UUID?, before: UUID?) {
        withAnimation(.bar) { Session.shared.change { $0.moveBookmark(bookmark, into: folder, before: before, in: spaceID) } }
    }

    /// A bar tab out of the bar's row, among the others; its bookmark stays.
    func separateFromBar(_ tab: UUID) {
        withAnimation(.bar) { _ = Session.shared.change { $0.separateFromBar(tab) } }
    }

    /// A bookmark or folder out of the bar; a tab open for it stays, among the others.
    func removeFromBar(_ bookmark: UUID) {
        withAnimation(.bar) { Session.shared.change { $0.removeBookmark(bookmark, in: spaceID) } }
    }

    /// A folder in the bar's `parent`, its name asked for at once.
    func newFolderInBar(in parent: UUID) {
        guard let id = Session.shared.change({ $0.addFolder(named: "", in: parent, of: spaceID) }) else { return }
        renameInBar(id)
    }

    /// A bookmark's or a folder's name in the bar, asked for in a sheet.
    func renameInBar(_ id: UUID) {
        guard let window, let item = space.flatMap({ Bookmarks.find(id, in: $0.bookmarks) }) else { return }
        let space = spaceID
        let field = NSTextField(string: item.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = item.isFolder ? String(localized: "Rename Folder") : String(localized: "Rename Bookmark")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { answer in
            guard answer == .alertFirstButtonReturn else { return }
            Session.shared.change { $0.renameBookmark(id, to: field.stringValue, in: space) }
        }
    }

    /// Whether a page can open beside the tab on screen: an ordinary tab.
    var canSplitBeside: Bool {
        guard let tabID else { return false }
        return space?.otherTabs.contains { $0.id == tabID } == true
    }

    /// `url` in a new tab beside the tab on screen, on its right, as Split
    /// View: a pinned tab's page or a bar bookmark's, the pinned tab itself
    /// staying where it is.
    func splitBeside(_ url: URL) {
        pinnedCard = nil
        guard canSplitBeside, let tab = tabID,
              let new = Session.shared.change({ $0.splitWithNewTab(tab, url: url) }) else { return }
        withAnimation(.bar) { show(tab: new, inSpace: spaceID) }
        focusPage()
    }

    // MARK: Pinned cards

    /// The pointer came onto a pinned tile or a bar row: its card comes
    /// after a moment, as a tooltip does, or at once while another's is out.
    func pointer(on card: PinnedCard) {
        cardWait?.cancel()
        if pinnedCard != nil {
            pinnedCard = card
            return
        }
        cardWait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.hover) { self.pinnedCard = card }
        }
    }

    /// The pointer left a tile, a row or the card (`inside` false), or came
    /// onto the card (true): it goes once the pointer is off both a moment,
    /// long enough to cross the gap between them.
    func pointerOnCard(_ inside: Bool) {
        cardWait?.cancel()
        guard !inside else { return }
        cardWait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.hover) { self.pinnedCard = nil }
        }
    }

    func putCardAway() {
        cardWait?.cancel()
        pinnedCard = nil
    }

    /// A bookmark's page: here, or in a new tab with ⌘ held, as a ⌘-click on a link does.
    func open(bookmark url: URL) {
        HistoryRecorder.shared.expect(.bookmark, url)
        open(url, newTab: NSEvent.modifierFlags.contains(.command))
    }

    func toggleBookmark() {
        guard let url, url.scheme?.hasPrefix("http") == true else { return }
        let session = Session.shared
        let known = session.workspace.bookmark(for: url, in: spaceID)
        if let known {
            session.change { $0.removeBookmark(known.id, in: spaceID) }
        } else {
            session.change { $0.addBookmark(url, title: title, in: spaceID) }
        }
        // The star says so only where the address shows it.
        show(.bookmark(added: known == nil))
    }

    var isBookmarked: Bool {
        url.flatMap { Session.shared.workspace.bookmark(for: $0, in: spaceID) } != nil
    }

    // MARK: Spaces

    func newSpace() {
        let session = Session.shared
        let id = session.change { $0.addSpace(named: String(localized: "Space \(session.workspace.spaces.count + 1)")) }
        showSpace(id)
        spacesPanel = .edit(id)
    }

    // MARK: The page

    func toggleSidebar() {
        guard tabsInSidebar else { return }
        unpeeking?.cancel()
        withAnimation(.bar) {
            sidebarShown.toggle()
            peeking = false
        }
    }

    /// The pointer came to the hidden sidebar's strip or pane, or left them both.
    func peek(_ inside: Bool) {
        unpeeking?.cancel()
        if inside {
            if !peeking { withAnimation(.bar) { peeking = true } }
            return
        }
        unpeeking = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            // Not from under a popover opened from it: the popover would lose what it stands on.
            guard !Task.isCancelled, let self, spacesPanel == nil, !downloadsShown, !pageActionsShown, !extensionsShown else { return }
            withAnimation(.bar) { self.peeking = false }
        }
    }

    // MARK: Peek

    func closePeek() {
        peek?.close()
    }

    /// Whether the Peek can open beside the tab it stands over: an ordinary
    /// tab (not pinned, not in the bookmarks bar), with the keys, in no split yet.
    var peekCanSplit: Bool {
        guard let opener = peek?.opener, opener === page else { return false }
        let workspace = Session.shared.workspace
        return workspace.spaceID(of: opener.tab).flatMap(workspace.space)?.otherTabs.contains { $0.id == opener.tab } == true
            && workspace.split(containing: opener.tab) == nil
    }

    /// The Peek's page in a tab of its own, as it is, right after the tab it
    /// stood over: in front, or beside that tab in a split.
    func openPeekInTab(split: Bool = false) {
        let session = Session.shared
        let beside = split && peekCanSplit
        guard let peek, let opener = peek.opener, let space = session.workspace.spaceID(of: opener.tab),
              let child = peek.handOver() else { return }
        let url = child.view.url ?? peek.url
        session.pages.adopt(child)
        let opened = session.change { workspace -> Bool in
            guard workspace.openTab(url, in: space, after: opener.tab, id: child.tab) != nil else { return false }
            workspace.record(child.tab, url: nil, title: child.view.title)
            if beside { workspace.split(opener.tab, with: child.tab) }
            return true
        }
        guard opened else {
            session.pages.close(child.tab)
            return
        }
        child.becameTab()
        withAnimation(.bar) { show(tab: child.tab, inSpace: space) }
        focusPage()
    }

    // MARK: Handoff

    /// Whether Handoff can be asked for here: on in Settings, on a Mac with
    /// Apple Intelligence, for a page that isn't hands-off.
    var canHandoff: Bool {
        canHandoffFiles && page?.view.url != nil && page?.isHandsOff == false
    }

    /// Whether a file can be handed off from here: a chosen or dropped one,
    /// a download's, a link's. The page on screen has no say, a new tab or
    /// Google's sign-in included: a file is no page.
    var canHandoffFiles: Bool {
        let session = Session.shared
        return session.preferences.handoff && session.hasIntelligence
    }

    /// The page on screen handed to another app (HandoffJob, the iPad's):
    /// its sheet comes up as soon as it is known whether Apple
    /// Intelligence's model is there to ask, and says how far it is.
    func startHandoff() {
        guard canHandoff, handoff == nil, !startsHandoff, let page else { return }
        startHandoff(source: page)
    }

    /// A file handed off: a link's, a download's, a chosen or dropped file's.
    /// Its source reads it; the guide says "file" where a page's said "page".
    func startHandoff(source: any HandoffSource) {
        let page = source as? Page
        guard page == nil ? canHandoffFiles : canHandoff, handoff == nil, !startsHandoff else { return }
        // A file is held until its job has it; a page is the tab's, and may go meanwhile.
        let file = page == nil ? source : nil
        startsHandoff = true
        Task { [weak self, weak page] in
            let mind = await PageMinds.mind()
            guard let self else { return }
            startsHandoff = false
            let chosen: any HandoffSource
            if let file {
                chosen = file
            } else {
                // Asked after the wait: the page may have gone, or another taken its place.
                guard let page, self.page === page, !page.isHandsOff, page.view.url != nil else { return }
                chosen = page
            }
            handoffChoosing = false
            handoff = HandoffJob(source: chosen, mind: mind, space: spaceID)
        }
    }

    /// "Handoff File…" opens the pane with no job yet: it then offers
    /// "Choose File…" and takes a dropped file (HandoffPanel).
    func startHandoffChoosing() {
        guard canHandoffFiles, handoff == nil, !startsHandoff else { return }
        handoffChoosing = true
    }

    /// The panel's "Choose File…" on the Mac: an open panel of the kinds
    /// eGlu reads (DocumentSource.contentTypes).
    func chooseHandoffFile() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = DocumentSource.contentTypes
        picker.allowsMultipleSelection = false
        picker.begin { [weak self] answer in
            guard answer == .OK, let url = picker.url else { return }
            Task { @MainActor in self?.startHandoff(source: DocumentSource(file: url)) }
        }
    }

    /// The share menu for the handoff, from its sheet's button: the file and
    /// the words beside it, or the words alone for a page with nothing to read.
    func shareHandoff(from view: NSView) {
        guard let job = handoff else { return }
        let items: [Any] = job.stage.hasFile ? [job.file as NSURL, job.prompt] : [job.prompt]
        sharing.show(items, from: view) { [weak self] service in
            guard service != nil else { return }
            // From now on the file stays as it is: an app is reading it.
            job.give()
            self?.endHandoff(taken: true)
        }
    }

    /// The handoff over: given to an app, or put away. What no app took is removed.
    func endHandoff(taken: Bool) {
        handoff?.finish(taken: taken)
        handoff = nil
        handoffChoosing = false
        focusPage()
    }

    func startFinding() {
        finding = true
        findRequests += 1
    }

    func find(backwards: Bool = false) {
        guard let page else { return }
        page.find(findText, backwards: backwards) { [weak self] found in
            self?.findMissed = !found && !(self?.findText.isEmpty ?? true)
        }
    }

    func endFinding() {
        finding = false
        findMissed = false
        focusPage()
    }

    var blocksContentHere: Bool {
        Session.shared.preferences.blocksContent(onHost: url?.host)
    }

    /// Developer mode on for the site on screen (DeveloperMode.isOn): by
    /// the site's own choice where it has one, else by the local-sites
    /// setting and the address's.
    var developerModeHere: Bool {
        let preferences = Session.shared.preferences
        return DeveloperMode.isOn(url, choices: preferences.developerSites, local: preferences.developerLocal)
    }

    /// The site's own choice, written either way so it stays while the
    /// local-sites setting changes.
    func toggleDeveloperMode() {
        setDeveloperMode(!developerModeHere, for: url)
    }

    /// Developer mode on or off for `url`'s site, kept for it, and said in
    /// a toast: a card's bar turns off its own page's site.
    func setDeveloperMode(_ on: Bool, for url: URL?) {
        guard let key = DeveloperMode.siteKey(url) else { return }
        Session.shared.preferences.developerSites[key] = on
        show(ActionToast(symbol: "chevron.left.forwardslash.chevron.right",
                         text: on ? String(localized: "Developer Mode on for this site")
                                  : String(localized: "Developer Mode off for this site")))
    }

    /// A developer tool's button or key. WebKit opens the inspector itself
    /// where it answers the private calls; where it doesn't, the way is
    /// Safari's Develop menu, said once in a toast.
    func showInspector(_ part: WebDeveloperTool) {
        guard let page = toolsPage else { return }
        if !page.showDeveloperTool(part) {
            show(ActionToast(symbol: "hammer", text: WebInspector.unavailable))
        }
    }

    /// ⌘+, ⌘− and ⌘0: the page's zoom a step, and a toast with the size it
    /// came to, as nothing else on screen says it; at either end, that it
    /// goes no further.
    func zoom(by step: Int) {
        guard let page else { return }
        let moved = page.zoom(by: step)
        let size = Self.percent(zoom)
        switch (step, moved) {
        case (0, _):
            show(ActionToast(symbol: "magnifyingglass", text: String(localized: "Zoom Reset to \(size)")))
        case (1..., true):
            show(ActionToast(symbol: "plus.magnifyingglass", text: String(localized: "Zoomed In to \(size)")))
        case (1..., false):
            show(ActionToast(symbol: "plus.magnifyingglass", text: String(localized: "Can't Zoom In Past \(size)")))
        case (_, true):
            show(ActionToast(symbol: "minus.magnifyingglass", text: String(localized: "Zoomed Out to \(size)")))
        case (_, false):
            show(ActionToast(symbol: "minus.magnifyingglass", text: String(localized: "Can't Zoom Out Past \(size)")))
        }
    }

    /// A zoom as the locale writes a percentage: 125%.
    static func percent(_ zoom: Double) -> String {
        zoom.formatted(.percent.precision(.fractionLength(0)))
    }

    /// The page the developer tools work on: a Peek's while one is up, as
    /// Reload Page has it, since the tab under it is out of reach.
    var toolsPage: Page? {
        peek?.page ?? page
    }

    /// A picture of the element picked on `page`, the tools' page unless
    /// a card's bar names its own: on the clipboard as PNG, and a toast
    /// offering to save it beside the downloads.
    func elementPicture(of page: Page? = nil) {
        guard let page = page ?? toolsPage else { return }
        Task { @MainActor [weak self, page] in
            guard let png = await Self.copyElementPicture(of: page), let self else { return }
            show(ActionToast(symbol: "camera.viewfinder", text: String(localized: "Picture copied"),
                             action: (title: String(localized: "Save"), run: { Self.saveElementPicture(png) })))
        }
    }

    /// The element picked on `page` (Page.pickElement, Page.picture(of:))
    /// as PNG, on the clipboard; nil for Escape or nothing to picture.
    static func copyElementPicture(of page: Page) async -> Data? {
        guard let picked = await page.pickElement(),
              let image = await page.picture(of: picked),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        return png
    }

    /// A copied element picture into ~/Downloads, as a file of its own name.
    static func saveElementPicture(_ png: Data) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let name = String(localized: "Element")
        var file = folder.appendingPathComponent("\(name).png")
        var count = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(name) \(count).png")
            count += 1
        }
        try? png.write(to: file)
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Whether this site's ads can be blocked or allowed: only while
    /// Settings blocks them at all, as the menu bar and the page's actions
    /// have it; otherwise blocking it here would change nothing.
    var offersBlocking: Bool {
        Session.shared.preferences.blocksContent && url?.host != nil
    }

    /// Ads blocked or allowed on this site, from its next load: loaded again now.
    func toggleBlocking() {
        guard offersBlocking, let host = url?.host else { return }
        let blocked = !blocksContentHere
        Session.shared.preferences.setBlocksContent(blocked, onHost: host)
        page?.blockingChanged()
        page?.reload()
        show(.ads(blocked: blocked))
    }

    /// A command from the menu bar or the command bar.
    func perform(_ command: Command) {
        switch command {
        case .everything: commandBar = .newTab
        case .newTab:
            // An extension's page, where you said it may show in new tabs
            // (Extensions.newTabPage); otherwise the command bar, and the
            // question to one that asks.
            if let url = Extensions.shared.newTabPage(in: spaceID) {
                openNewTabPage(url)
            } else {
                commandBar = .newTab
            }
            // One that asks and hasn't been answered is asked, whichever
            // shows new tabs now; no keeps that one.
            Extensions.shared.offerNewTabPage(in: self)
        case .address: commandBar = .here
        case .closeTab: closeTab()
        case .reopenTab: reopenTab()
        case .reload: reload()
        case .stop: stop()
        case .back: back()
        case .forward: forward()
        case .nextTab: selectTab(by: 1)
        case .previousTab: selectTab(by: -1)
        case .nextSpace: showSpace(by: 1)
        case .previousSpace: showSpace(by: -1)
        case .newSpace: newSpace()
        case .newWindow: Session.shared.openWindow?(spaceID)
        case .closeWindow: window?.performClose(nil)
        case .tabBar: toggleSidebar()
        case .settings: Session.shared.openSettings?()
        case .pinTab: togglePin()
        case .bookmark: toggleBookmark()
        case .spaceSettings: spacesPanel = .edit(spaceID)
        case .contentBlocking: toggleBlocking()
        case .find: startFinding()
        case .focusPage: focusPage()
        case .handoff: startHandoff()
        case .handoffFile: startHandoffChoosing()
        case .history: historyShown = true
        case .share: pageActionsShown = true
        case .copyLink: copyLink()
        case .acceptWritingSuggestion: Task { _ = await page?.writingAcceptFirst() }
        case .splitTab: if split != nil { separate() } else { splitWithNewTab() }
        case .importBookmarks:
            if let window { Session.shared.chooseBookmarksFile(into: spaceID, in: window) }
        case .inspector: showInspector(.inspector)
        case .console: showInspector(.console)
        case .selectElement: showInspector(.elementSelection)
        case .elementPicture: elementPicture()
        case .reloadOrigin: toolsPage?.reloadFromOrigin()
        case .measure: page?.toggleMeasuring()
        case .developerMode: toggleDeveloperMode()
        case .diagnostics, .siteMode, .linkMenu: break
        }
    }

    /// What the Mac offers of the browser's commands: the iPad's that a Mac has a use for.
    static let commands: [Command] = [
        .newTab, .closeTab, .reopenTab, .reload, .stop, .back, .forward, .nextTab, .previousTab,
        .nextSpace, .previousSpace, .newSpace, .newWindow, .closeWindow, .tabBar, .settings, .pinTab,
        .bookmark, .spaceSettings, .contentBlocking, .find, .handoff, .handoffFile, .splitTab, .history, .copyLink,
        .acceptWritingSuggestion,
        .inspector, .console, .selectElement, .elementPicture, .reloadOrigin, .measure, .developerMode,
    ]

    /// Each command's keys, as the menu bar has them.
    static func keys(for command: Command) -> String? {
        switch command {
        case .newTab: return "⌘T"
        case .closeTab: return "⌘W"
        case .reopenTab: return "⇧⌘T"
        case .address: return "⌘L"
        case .reload: return "⌘R"
        case .stop: return "⌘."
        case .back: return "⌘["
        case .forward: return "⌘]"
        case .nextTab: return "⌃⇥"
        case .previousTab: return "⌃⇧⇥"
        case .nextSpace: return "⌥⌘→"
        case .previousSpace: return "⌥⌘←"
        case .newWindow: return "⌘N"
        case .closeWindow: return "⇧⌘W"
        case .tabBar: return "⌃⌘S"
        case .settings: return "⌘,"
        case .pinTab: return "⇧⌘D"
        case .bookmark: return "⌘D"
        case .find: return "⌘F"
        case .history: return "⌘Y"
        case .copyLink: return "⇧⌘C"
        case .handoffFile: return "⌃⌥⇧H"
        case .acceptWritingSuggestion: return "⌃⌥G"
        case .inspector, .console, .selectElement, .elementPicture, .reloadOrigin, .measure, .developerMode:
            guard let chord = Shortcuts.chord(for: command) else { return nil }
            // The keys Settings picked: eGlu's own ⌃⌥, or Chrome's ⌥⌘,
            // where Reload from Origin loses the ⇧ to Chrome's ⌥⌘R and the
            // site's switch stays put on ⌃⌥⇧V.
            if Session.shared.preferences.developerKeys == .optionCommand,
               Shortcuts.developer.contains(command) {
                return "⌥⌘" + chord.caps[chord.caps.count - 1]
            }
            return chord.label
        default: return nil
        }
    }

    /// A row of the command bar, chosen.
    func run(_ suggestion: Suggestion, purpose: CommandBarPurpose) {
        commandBar = nil
        switch suggestion.action {
        case .tab(let id): select(id)
        case .open(let url):
            HistoryRecorder.shared.expect(.typed, url)
            open(url, newTab: purpose == .newTab)
        case .space(let id): showSpace(id)
        case .command(let command): perform(command)
        case .setting(.appIcon): DockIcon.shared.showInSettings()
        case .setting: Session.shared.openSettings?()
        case .go(let text): go(text, newTab: purpose == .newTab)
        }
    }

    var takesHandoffFiles: Bool { canHandoffFiles }

    /// "Handoff Linked File" in the page's menu: fetched through the
    /// tab's own view and read as the document it is.
    func page(_ page: Page, handOffFileAt url: URL) {
        startHandoff(source: DocumentSource(link: url, downloads: page.downloadStarter))
    }

    // MARK: PageHost

    var hostWindow: NSWindow? {
        window
    }

    func pageDidChange(_ page: Page) {
        if page === self.page {
            refresh()
        } else if page === partner {
            partnerRevision += 1
            syncPeek()
        }
    }

    func isShowing(_ page: Page) -> Bool {
        (page === self.page || page === partner) && window?.isVisible == true
            && page.surface.view.window === window && !page.surface.view.isHiddenOrHasHiddenAncestor
    }

    func page(_ page: Page, openChild request: any WebChildRequest) -> Page? {
        // A window with a size asked for is a pop-up: a sign-in, a share
        // dialog. It opens in a Peek over its page, and closes by itself
        // when done; from a page not on screen here, over this window.
        if request.features.width != nil || request.features.height != nil {
            if page.canPeek, page === self.page || page === partner {
                return page.openPeek(request.navigation.request.url, child: request,
                                     width: request.features.width, height: request.features.height).page
            }
            return Popup.open(from: page, child: request, over: window)
        }
        // Anything else is a tab, right after the one it came from; behind
        // this one when a ⌘-click asked for it, live there with its tie to this page.
        let session = Session.shared
        let behind = request.navigation.modifiers.contains(.command) && !request.navigation.modifiers.contains(.shift)
        guard let id = session.change({ $0.openTab(request.navigation.request.url, in: page.space, after: behind ? behindAfter(page) : page.tab) })
        else { return nil }
        let child = session.pages.adopt(tab: id, space: page.space, child: request)
        // Its tie to the page that opened it, as a pop-up's: a sign-in's
        // window, opened as a tab, may finish that page's flow (ExtensionAuth).
        child.openedFrom = page.tab
        if behind {
            session.change { $0.select(page.tab) }
            openedBehind = (page.tab, id)
            session.pages.enforce()
            return child
        }
        openedBehind = nil
        withAnimation(.bar) {
            tabID = id
            spaceID = page.space
            session.change { $0.select(id) }
            attach(child)
        }
        focusPage()
        session.pages.enforce()
        return child
    }

    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool {
        let session = Session.shared
        guard let id = session.change({ $0.openTab(url, in: page.space, after: inFront ? page.tab : behindAfter(page)) }) else {
            return false
        }
        if inFront {
            openedBehind = nil
            withAnimation(.bar) { show(tab: id, inSpace: page.space) }
            focusPage()
        } else {
            session.change { $0.select(page.tab) }
            openedBehind = (page.tab, id)
        }
        return true
    }

    /// Where a tab opened behind goes: after the last one opened behind
    /// from the same tab, so a row of ⌘-clicks keeps its order.
    private func behindAfter(_ page: Page) -> UUID {
        if let openedBehind, openedBehind.from == page.tab, Session.shared.workspace.tab(openedBehind.last) != nil {
            return openedBehind.last
        }
        return page.tab
    }

    func pageDidClose(_ page: Page) {
        guard Session.shared.workspace.tab(page.tab) != nil else { return }
        closeTab(page.tab)
    }
}
