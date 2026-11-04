import Combine
import PadCore
import WebEngineCore
import WebKitSupport
import UIKit
import os

/// What every window shares: the spaces and their tabs, the settings, the
/// pages, and the windows themselves.
///
/// Windows (one per scene, Stage Manager's or Split View's) each show one
/// tab. A tab is on screen in one window at a time; choosing a tab that
/// another window shows brings that window forward instead.
@MainActor
final class Session: ObservableObject {
    static let shared = Session()
    /// What went wrong where nothing is shown for it, for Console.
    nonisolated private static let log = Logger(subsystem: "net.taehee.safience", category: "Session")

    @Published private(set) var workspace: Workspace
    @Published private(set) var workspaceProblem: WorkspaceFile.Failure?
    var canUseWorkspace: Bool { workspaceProblem == nil }
    @Published var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            let changes = preferencesChanged(from: oldValue)
            if changes.contains(.limits) { pages.enforce() }
            // The menu bar lists Handoff only while it is on.
            if changes.contains(.handoff) { UIMenuSystem.main.setNeedsRebuild() }
        }
    }

    /// Every build of the iPhone and iPad app is signed with the app's iCloud container.
    static let canSync = true

    /// Whether the device has Apple Intelligence to ask (PageMinds.intelligence),
    /// without which Handoff is in no menu, not in the command bar and not
    /// in Settings. What the last look found, kept across launches so that
    /// the menus are right from the first; looked at again whenever the
    /// app comes to the front, where it may have been turned on or off in
    /// the Settings app, or its model may have come.
    @Published private(set) var hasIntelligence = UserDefaults.standard.bool(forKey: Session.intelligenceKey) {
        didSet {
            guard hasIntelligence != oldValue else { return }
            UserDefaults.standard.set(hasIntelligence, forKey: Session.intelligenceKey)
            UIMenuSystem.main.setNeedsRebuild()
        }
    }
    private static let intelligenceKey = "hasIntelligence"
    private var intelligenceWatch: NSObjectProtocol?
    private var lookingForIntelligence = false

    let pages = Pages()
    private let browsers = NSHashTable<Browser>.weakObjects()
    /// Opens, retries and restores the workspace's file; its writes are persistence's.
    private let store = WorkspaceStore(folder: Session.folder, snapshots: Snapshots.folder)
    lazy var persistence = WorkspacePersistence(file: Session.workspaceFile)
    private var finishingWelcome = false
    private var leavingWatch: NSObjectProtocol?

    static let preferencesKey = "preferences"

    /// Asked from any thread: the filter lists are read and written away from the main one.
    nonisolated static var folder: URL {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["EGLU_ISOLATED_QA"] == "1",
           let path = ProcessInfo.processInfo.environment["EGLU_DATA_ROOT"], !path.isEmpty, path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Safience", isDirectory: true)
    }

    static var workspaceFile: URL {
        WorkspaceStore.file(in: folder)
    }

    private init() {
        let opened = store.open()
        workspace = opened.workspace
        workspaceProblem = opened.problem
        if opened.created { Session.welcomeIfNew() }
        preferences = Preferences.stored(in: .standard, key: Session.preferencesKey)
    }

    /// Once, at launch, before the first window.
    func start() {
        startWorkspaceServices()
        // Checking turned on before this launch: Harper is made now, not at
        // the next change to the settings, or no field would be checked.
        WritingChecker.shared.preferencesChanged(preferences)
        // Coming to the front includes the launch's own.
        intelligenceWatch = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForIntelligence() }
        }
        // Leaving the screen may be the last the app sees before it is
        // stopped: the change still waiting its half second is written now.
        leavingWatch = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    private func startWorkspaceServices() {
        guard canUseWorkspace else { return }
        Stores.sweep(in: WebKitSpaceStores.shared)
        HistoryRecorder.shared.prune()
        Snapshots.prune(keeping: Set(workspace.spaces.flatMap { $0.tabs.map(\.id) }))
        pages.watchMemory()
        ContentBlocker.shared.start()
        if preferences.iCloudSync { Sync.shared.start(join: false) }
    }

    /// Retry never creates replacement identities after a failed read.
    @discardableResult
    func retryWorkspace() -> Bool {
        guard !canUseWorkspace else { return true }
        guard let opened = try? store.retry(workspace) else { return false }
        if opened.created { Session.welcomeIfNew() }
        workspace = opened.workspace
        workspaceProblem = nil
        startWorkspaceServices()
        return true
    }

    func restoreWorkspace(from file: URL) throws {
        guard !canUseWorkspace else { return }
        // No history writes or snapshot writes run while recovery is showing.
        workspace = try store.restore(from: file)
        workspaceProblem = nil
        startWorkspaceServices()
    }

    private func lookForIntelligence() {
        guard !lookingForIntelligence else { return }
        lookingForIntelligence = true
        Task {
            let has = await PageMinds.intelligence()
            lookingForIntelligence = false
            if hasIntelligence != has { hasIntelligence = has }
        }
    }

    // MARK: The welcome

    private static let welcomeKey = "welcome"

    /// A first launch whose welcome hasn't been finished or skipped yet: kept
    /// across launches, so quitting halfway brings it back.
    var needsWelcome: Bool {
        canUseWorkspace && UserDefaults.standard.string(forKey: Session.welcomeKey) == "pending"
    }

    /// A workspace just made for a first launch: its welcome, unless one was seen already.
    private static func welcomeIfNew() {
        if UserDefaults.standard.string(forKey: Session.welcomeKey) == nil {
            UserDefaults.standard.set("pending", forKey: Session.welcomeKey)
        }
    }

    func finishWelcome() async -> Bool {
        guard !finishingWelcome else { return false }
        finishingWelcome = true
        defer { finishingWelcome = false }
        guard await saveWorkspaceNow(), !persistence.state.isDirty else { return false }
        UserDefaults.standard.set("done", forKey: Session.welcomeKey)
        return true
    }

    // MARK: The workspace

    /// Every change to the workspace goes through here: saved a moment
    /// later, and every window hears of it.
    @discardableResult
    func change<T>(_ edit: (inout Workspace) -> T) -> T {
        var copy = workspace
        let result = edit(&copy)
        if Sync.shared.assigns { SyncPlan.assignIDs(&copy) }
        if canUseWorkspace, copy != workspace {
            let old = workspace
            workspace = copy
            save()
            Sync.shared.changed(from: old, to: copy)
        }
        return result
    }

    private func save() {
        guard canUseWorkspace else { return }
        persistence.changed(workspace)
    }

    func retryWorkspaceSave() {
        guard canUseWorkspace else { return }
        persistence.flush(workspace) { _ in }
    }

    /// A caller may proceed only after the current local revision is saved.
    func saveWorkspaceNow() async -> Bool {
        guard canUseWorkspace else { return false }
        return await withCheckedContinuation { continuation in
            persistence.flush(workspace) { continuation.resume(returning: $0) }
        }
    }

    /// The waiting write, at once, with the time the system gives an app
    /// leaving the screen to finish it.
    private func saveNow() {
        guard canUseWorkspace, persistence.state.isDirty else { return }
        let finishing = UIApplication.shared.beginBackgroundTask(withName: "eGlu.workspace")
        persistence.flush(workspace) { _ in
            UIApplication.shared.endBackgroundTask(finishing)
        }
    }

    /// What a page says about itself, its address and title, saved with
    /// everything else half a second after the last change.
    func record(_ tab: UUID, url: URL?, title: String?) {
        // A page says both many times over; only news is a change to make and to tell.
        if let known = workspace.tab(tab), url == nil || known.url == url, title == nil || known.title == title { return }
        change { $0.record(tab, url: url, title: title) }
    }

    /// A tab closed: gone, or, when it is pinned, unloaded and back at its
    /// pinned page (Workspace.closeTab), when it may be the one to show.
    func closeTab(_ id: UUID) {
        let next = change { $0.closeTab(id) }
        // A pane beside a tab on screen goes before its page does.
        for window in allBrowsers where window.partner?.tab == id { window.syncSplit() }
        for window in allBrowsers where window.model.tabID == id {
            // The tab beside it in a split is this window's already: it stays.
            let shown = next.flatMap { tab -> UUID? in
                let shower = browser(showing: tab)
                return tab == id || shower == nil || shower === window ? tab : nil
            }
            // A pinned tab closed is the one selected still when it is the
            // space's only tab: unloaded, not shown, as on the Mac. Shown, its
            // window would keep the page it is about to lose.
            window.show(tab: shown == id ? nil : shown, inSpace: window.model.spaceID)
        }
        // Its page goes once no window has it up.
        pages.close(id)
    }

    /// Several tabs closed: the ones no window shows first, so no window
    /// goes to a tab about to go, then the ones on screen.
    func closeTabs(_ ids: [UUID]) {
        let shown = Set(allBrowsers.compactMap(\.model.tabID))
        // Those no window shows go in one change to the workspace: one at
        // a time, every window heard of each, and went over its whole
        // chrome for each.
        let off = ids.filter { !shown.contains($0) }
        if !off.isEmpty {
            change { workspace in
                for id in off { workspace.closeTab(id) }
            }
            // A pane beside a tab on screen goes before its page does.
            let gone = Set(off)
            for window in allBrowsers where window.partner.map({ gone.contains($0.tab) }) == true { window.syncSplit() }
            for id in off { pages.close(id) }
        }
        for id in ids where shown.contains(id) {
            closeTab(id)
        }
    }

    func removeSpace(_ id: UUID) {
        guard workspace.spaces.count > 1, let space = workspace.space(id) else { return }
        for tab in space.tabs { pages.close(tab.id) }
        change { _ = $0.removeSpace(id) }
        Stores.erase(id, in: WebKitSpaceStores.shared)
        HistoryRecorder.shared.removeSpace(id)
        for window in allBrowsers where window.model.spaceID == id {
            window.showSpace(workspace.firstSpace.id)
        }
    }

    func moveTab(_ id: UUID, to space: UUID, from owner: Browser, before target: UUID? = nil,
                 completion: @escaping @MainActor (UUID?) -> Void = { _ in }) {
        guard canUseWorkspace, owner.isConnected,
              let originalWindow = owner.viewIfLoaded?.window, !originalWindow.isHidden,
              let presenter = owner.presenter, !(presenter is UIAlertController),
              presenter.viewIfLoaded?.window === originalWindow, !presenter.isBeingDismissed,
              let plan = TabMovePlan(workspace: workspace, tab: id, destination: space, before: target)
        else { return completion(nil) }
        let originalOwnerSpace = owner.model.spaceID
        let live = pages.live[id]
        let finish: @MainActor (TabMovePlan.Choice) -> Void = { [weak self, weak owner, weak originalWindow] choice in
            guard let self else { return completion(nil) }
            guard choice != .cancel else { return completion(nil) }
            guard let owner, let originalWindow, owner.isConnected,
                  owner.viewIfLoaded?.window === originalWindow,
                  owner.model.spaceID == originalOwnerSpace else { return completion(nil) }
            guard self.canUseWorkspace, plan.isValid(in: self.workspace), self.pages.live[id] === live else {
                owner.moveRequestChanged()
                return completion(nil)
            }
            guard let result = self.change({ plan.apply(choice, to: &$0) }) else { return completion(nil) }
            if choice == .move {
                // PR50 isolation: only the confirmed move discards the old space's page and snapshots.
                self.pages.moved(id)
                for window in self.allBrowsers where window.model.tabID == id {
                    window.show(tab: id, inSpace: space)
                }
            } else {
                owner.show(tab: result, inSpace: space)
            }
            completion(result)
        }
        let alert = UIAlertController(title: plan.title, message: plan.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: BrowserText.localized("Move Tab"), style: .destructive) { _ in finish(.move) })
        let copy = UIAlertAction(title: BrowserText.localized("Open a Copy"), style: .default) { _ in finish(.copy) }
        alert.addAction(copy)
        alert.addAction(UIAlertAction(title: BrowserText.localized("Cancel"), style: .cancel) { _ in finish(.cancel) })
        alert.preferredAction = copy
        presenter.present(alert, animated: true)
    }

    // MARK: Windows

    func register(_ browser: Browser) {
        browsers.add(browser)
    }

    func unregister(_ browser: Browser) {
        browsers.remove(browser)
    }

    var allBrowsers: [Browser] {
        browsers.allObjects
    }

    /// The window with `tab` on screen, alone or as one of a split's panes.
    func browser(showing tab: UUID) -> Browser? {
        allBrowsers.first { $0.shows(tab) && $0.isConnected }
    }

    /// The tabs on screen: one per window, two in a split.
    var shownTabs: Set<UUID> {
        Set(allBrowsers.filter(\.isConnected).flatMap(\.shownTabs))
    }

    /// A new window, through the system, showing `space` and `tab`; or,
    /// where the system makes none (the iPhone Duo's outer display), what
    /// `failed` does in its place.
    func openWindow(space: UUID?, tab: UUID?, failed: (() -> Void)? = nil) {
        var request = UISceneSessionActivationRequest(role: .windowApplication)
        request.userActivity = WindowState(space: space, tab: tab).activity
        UIApplication.shared.activateSceneSession(for: request) { error in
            Self.log.error("No new window: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { failed?() }
        }
    }

    func bringForward(_ browser: Browser) {
        guard let session = browser.view.window?.windowScene?.session else { return }
        let request = UISceneSessionActivationRequest(session: session)
        UIApplication.shared.activateSceneSession(for: request) { _ in }
    }
}

/// Which space and tab a window shows, kept by the system with the window
/// so each comes back as it was.
struct WindowState {
    var space: UUID?
    var tab: UUID?

    static var activityType: String {
        (Bundle.main.bundleIdentifier ?? "Safience") + ".window"
    }

    init(space: UUID?, tab: UUID?) {
        self.space = space
        self.tab = tab
    }

    init(activity: NSUserActivity?) {
        let info = activity?.activityType == WindowState.activityType ? activity?.userInfo : nil
        space = (info?["space"] as? String).flatMap(UUID.init(uuidString:))
        tab = (info?["tab"] as? String).flatMap(UUID.init(uuidString:))
    }

    var activity: NSUserActivity {
        let activity = NSUserActivity(activityType: WindowState.activityType)
        var info: [String: String] = [:]
        if let space { info["space"] = space.uuidString }
        if let tab { info["tab"] = tab.uuidString }
        activity.addUserInfoEntries(from: info)
        return activity
    }
}

extension SiteIcons {
    /// The app's icons, kept with its other data; the Caches folder they
    /// were kept in before is this app's own.
    static let shared = SiteIcons(data: Session.folder, caches: .cachesDirectory, rasterizer: WebKitSVGRaster.shared)
}

extension Downloads {
    static func retryStarter(space: UUID) -> any WebDownloadStarting {
        WebKitDownloadStarter(store: WebKitStores.store(for: space))
    }
}

extension ContentBlocker {
    static func makeRuleStore() -> (any WebRuleListStore)? {
        WebKitRuleListStore.makeDefault()
    }
}
