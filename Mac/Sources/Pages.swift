import AppKit
import PadCore
import WebEngineCore
import WebKit

/// Every tab's page: live, or let go until it is opened again.
///
/// A live page keeps its WebKit content process. One let go keeps only what
/// WebKit needs to load it back where it was (its back and forward list and
/// where it was scrolled to), in memory and in Caches (Snapshots); opening
/// the tab loads it again from there. A Mac has room for more live pages
/// than an iPad, so the Freezer (Memory.swift in PadCore) is given more.
@MainActor
final class Pages {
    private let engine: any MacPageEngine
    private(set) var live: [UUID: Page] = [:]
    private struct KeptState {
        let space: UUID
        let url: URL?
        let value: Any
    }
    private var states: [UUID: KeptState] = [:]
    private var addresses: [UUID: URL] = [:]
    private var freezing: Set<UUID> = []
    private var pressure: DispatchSourceMemoryPressure?

    init(engine: any MacPageEngine) {
        self.engine = engine
    }

    /// What stays live off screen on a Mac: a few heavy web apps, and the
    /// light pages last looked at.
    static let limits = LiveLimits(heavy: 3, lightOffScreen: 12)

    /// The tab's page, made and loaded when it was let go or never opened.
    func page(for tab: TabRecord, in space: UUID) -> Page {
        if let page = live[tab.id], page.space == space { return page }
        if live[tab.id] != nil { moved(tab.id) }
        // An extension's own page is made from the extension's configuration,
        // as WebKit needs, while the extension is on in the space.
        let page = engine.makePage(tab: tab.id, space: space, source: .tab(tab.url))
        live[tab.id] = page
        addresses[tab.id] = tab.url
        let token = Snapshots.token(for: tab.id, in: space)
        let disk = Snapshots.takeState(url: tab.url, using: token)
        let kept = states.removeValue(forKey: tab.id)
        let state: Any? = kept.flatMap { $0.space == space && $0.url == tab.url ? $0.value : nil } ?? disk
        // A tab that had a page before (a new tab has no name yet) comes
        // back as it was: no new visit in its history.
        if state != nil || !tab.title.isEmpty { page.restoring() }
        if let state {
            page.view.interactionState = state
        }
        // No state, or one WebKit couldn't use: the tab's address.
        if page.view.url == nil, let url = tab.url {
            page.load(url)
        }
        return page
    }

    /// A page's history and place, for the tab's page when it is next made
    /// at `url`.
    func keep(_ state: Any, url: URL, for tab: UUID, in space: UUID) {
        states[tab] = KeptState(space: space, url: url, value: state)
    }

    /// A page WebKit made for a tab, opened by another page.
    func adopt(tab: UUID, space: UUID, configuration: WKWebViewConfiguration, extensionPage: Bool = false) -> Page {
        close(tab)
        let page = engine.makePage(tab: tab, space: space, source: .supplied(configuration, extensionPage: extensionPage))
        live[tab] = page
        return page
    }

    /// A child made from its request before the call that asked returns.
    func adopt(tab: UUID, space: UUID, child: any WebChildRequest) -> Page {
        close(tab)
        let page = engine.makePage(tab: tab, space: space, source: .child(child))
        live[tab] = page
        return page
    }

    /// A page made before its tab, a Peek's or a little window's: the tab's
    /// page from now on, as it is.
    func adopt(_ page: Page) {
        live[page.tab] = page
        addresses[page.tab] = page.view.url
    }

    func isLive(_ tab: UUID) -> Bool {
        live[tab] != nil
    }

    /// A tab closed for good: its page and everything kept for it.
    func close(_ tab: UUID) {
        live.removeValue(forKey: tab)?.tearDown()
        addresses[tab] = nil
        invalidate(tab)
    }

    /// Takes a tab's page down when the tab moves to another space, whose
    /// store is not the one the page was signed in with.
    func moved(_ tab: UUID) {
        close(tab)
    }

    /// A pinned tab put back: its page goes, and it loads at its pinned address when next opened.
    func unload(_ tab: UUID) {
        close(tab)
    }

    /// Lets go of what the Freezer says should go now.
    func enforce(pressure: Bool = false) {
        let session = Session.shared
        let shown = session.shownTabs
        var loads: [TabLoad] = []
        for space in session.workspace.spaces {
            for tab in space.tabs {
                let page = live[tab.id]
                loads.append(TabLoad(
                    id: tab.id,
                    heavy: page?.isHeavy ?? Adapters.adapter(for: tab.url).isHeavy(tab.url),
                    onScreen: shown.contains(tab.id),
                    live: page != nil,
                    lastShown: tab.shown,
                    mustStay: page?.mustStay ?? false
                ))
            }
        }
        for tab in Freezer.plan(loads, limits: Self.limits, pressure: pressure) {
            freeze(tab, force: pressure)
        }
    }

    /// Asks the page whether it holds anything typed, then lets it go, as
    /// the iPad's does; for want of memory (`force`) it goes whatever it holds.
    private func freeze(_ tab: UUID, force: Bool = false) {
        guard let page = live[tab], !freezing.contains(tab) else { return }
        let token = Snapshots.token(for: tab, in: page.space)
        freezing.insert(tab)
        page.holdsTyping { [weak self] typed in
            guard let self, Snapshots.isCurrent(token) else { return }
            self.freezing.remove(tab)
            guard force || typed == false, !page.mustStay, !Session.shared.shownTabs.contains(tab), self.live[tab] === page else { return }
            self.release(page, token: token)
        }
    }

    private func invalidate(_ tab: UUID) {
        freezing.remove(tab)
        states[tab] = nil
        Snapshots.remove(tab)
    }

    func navigationChanged(_ page: Page, committed: Bool = false) {
        guard live[page.tab] === page else { return }
        guard committed || addresses[page.tab] != page.view.url else { return }
        addresses[page.tab] = page.view.url
        invalidate(page.tab)
    }

    private func release(_ page: Page, token: PageSnapshotFiles.Token) {
        guard live[page.tab] === page, Snapshots.isCurrent(token) else { return }
        if let state = page.view.interactionState {
            states[page.tab] = KeptState(space: page.space, url: page.view.url, value: state)
            // Never a sign-in page's on disk: it can hold an email address;
            // nor an extension's own, which can show a password vault.
            if !page.isSignIn, !page.isExtensionPage { Snapshots.save(state: state, url: page.view.url, using: token) }
        }
        live[page.tab] = nil
        page.tearDown()
    }

    /// Memory pressure, from the system: every tab off screen that can go, goes.
    func watchMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.enforce(pressure: true) }
        }
        source.resume()
        pressure = source
    }
}
