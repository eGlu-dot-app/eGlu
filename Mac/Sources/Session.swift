import AppKit
import Combine
import PadCore
import Security
import UniformTypeIdentifiers

/// What every window shares: the spaces and their tabs, the settings, the
/// pages, and the windows themselves. The iPad's Session, for a Mac.
///
/// Each window shows one space and one tab of it. A tab is on screen in one
/// window at a time; choosing a tab that another window shows brings that
/// window forward instead.
@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published private(set) var workspace: Workspace
    @Published private(set) var workspaceProblem: WorkspaceFile.Failure?
    var canUseWorkspace: Bool { workspaceProblem == nil }
    @Published var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            preferencesChanged(from: oldValue)
        }
    }

    /// Whether this Mac has Apple Intelligence to ask (PageMinds.intelligence),
    /// without which Handoff is in no menu and not in Settings. What the
    /// last look found, kept across launches so the menus are right from
    /// the first; looked at again whenever the app comes to the front.
    @Published private(set) var hasIntelligence = UserDefaults.standard.bool(forKey: Session.intelligenceKey) {
        didSet { UserDefaults.standard.set(hasIntelligence, forKey: Session.intelligenceKey) }
    }
    private static let intelligenceKey = "hasIntelligence"
    private var intelligenceWatch: NSObjectProtocol?

    let pages = Pages()
    private let windows = NSHashTable<WindowModel>.weakObjects()
    /// Opens, retries and restores the workspace's file; its writes are persistence's.
    private let store = WorkspaceStore(folder: Session.folder, snapshots: Snapshots.folder)
    lazy var persistence = WorkspacePersistence(file: Session.workspaceFile)
    private var terminationPending = false
    private var quitWarningShown = false
    private var allowUnsavedTermination = false
    /// Addresses another app asked to open before any window was there to take them.
    private var waiting: [URL] = []
    /// A new window showing a space, through SwiftUI (LaunchState.openWindow).
    var openWindow: ((UUID?) -> Void)? { LaunchState.shared.openWindow }
    /// The Settings window, through SwiftUI: set by the first window that appears.
    var openSettings: (() -> Void)?

    static let preferencesKey = "preferences"

    /// Whether this build may use iCloud: signed with the app's iCloud
    /// container. A build signed only to run on this Mac isn't, and CloudKit
    /// would stop it at the first call; Settings says so instead.
    static let canSync: Bool = {
        guard dataRootOverride == nil else { return false }
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return ((value as? [String]) ?? []).isEmpty == false
    }()

    nonisolated static var dataRootOverride: URL? {
        for path in [ProcessInfo.processInfo.environment["EGLU_DATA_ROOT"],
                     Bundle.main.object(forInfoDictionaryKey: "EGLU_DATA_ROOT") as? String].compactMap({ $0 }) {
            if !path.isEmpty, path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return nil
    }

    nonisolated static var folder: URL {
        if let dataRootOverride { return dataRootOverride }
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
        preferences = Preferences.stored(in: .standard, key: Session.preferencesKey)
    }

    /// Once, at launch, before the first window.
    func start(afterLaunch: Bool = false) {
        startWorkspaceServices(afterLaunch: afterLaunch)
        // Checking turned on before this launch: Harper is made now, not at
        // the next change to the settings, or no field would be checked.
        WritingChecker.shared.preferencesChanged(preferences)
        WritingMenu.shared.start()
        lookForIntelligence()
        // Coming to the front includes the launch's own.
        intelligenceWatch = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForIntelligence() }
        }
        appWatch = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWentBehind() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appCameBack() }
            },
        ]
    }

    // MARK: Picture in picture as eGlu goes behind

    private var appWatch: [NSObjectProtocol] = []
    private var goingBehind: Task<Void, Never>?

    /// The pages on screen, in every window: each tab's and the one beside it.
    private var pagesOnScreen: [Page] {
        allWindows.flatMap { [$0.page, $0.partner].compactMap { $0 } }
    }

    /// Another app came in front: once it has stayed there a moment, each
    /// page on screen floats its call or its video (Page.appWentBehind). A
    /// quick ⌘-Tab out and back floats nothing.
    private func appWentBehind() {
        guard preferences.automaticPictureInPicture else { return }
        goingBehind?.cancel()
        goingBehind = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !NSApp.isActive else { return }
            for page in self.pagesOnScreen { page.appWentBehind() }
        }
    }

    /// Only visible pages return from PiP. A background tab's picture
    /// stays afloat until that tab comes back on screen.
    private func appCameBack() {
        goingBehind?.cancel()
        goingBehind = nil
        let shown = pagesOnScreen
        for page in shown { page.appCameBack() }
        pages.enforce()
    }

    func automaticPictureChanged() {
        guard !preferences.automaticPictureInPicture else { return }
        goingBehind?.cancel()
        goingBehind = nil
        for page in pages.live.values { page.cameOnScreen() }
        pages.enforce()
    }

    private func startWorkspaceServices(afterLaunch: Bool = false) {
        guard canUseWorkspace else { return }
        Stores.sweep()
        HistoryRecorder.shared.prune()
        Snapshots.prune(keeping: Set(workspace.spaces.flatMap { $0.tabs.map(\.id) }))
        pages.watchMemory()
        ContentBlocker.shared.start()
        Extensions.shared.start(afterLaunch: afterLaunch)
        ElsewhereChecker.shared.start()
        if preferences.iCloudSync, Session.canSync { Sync.shared.start(join: false) }
    }

    /// Retry never creates replacement identities after a failed read.
    @discardableResult
    func retryWorkspace() -> Bool {
        guard !canUseWorkspace else { return true }
        let retried: WorkspaceStore.Opened?
        do {
            retried = try store.retry(workspace)
        } catch {
            NSLog("eGlu: the workspace couldn't be written on retry: \(error.localizedDescription)")
            return false
        }
        guard let opened = retried else { return false }
        workspace = opened.workspace
        workspaceProblem = nil
        startWorkspaceServices(afterLaunch: true)
        return true
    }

    func restoreWorkspace(from file: URL) throws {
        guard !canUseWorkspace else { return }
        // No history writes or snapshot writes run while recovery is showing.
        workspace = try store.restore(from: file)
        workspaceProblem = nil
        startWorkspaceServices(afterLaunch: true)
    }

    private func lookForIntelligence() {
        Task {
            let has = await PageMinds.intelligence()
            if hasIntelligence != has { hasIntelligence = has }
        }
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
            // A split begun, ended or changed: each window's page beside, as it now is.
            for window in allWindows { window.workspaceChanged() }
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

    func saveWorkspaceNow() async -> Bool {
        guard canUseWorkspace else { return false }
        return await withCheckedContinuation { continuation in
            persistence.flush(workspace) { continuation.resume(returning: $0) }
        }
    }

    /// Whatever is waiting to be saved, now: the app is quitting.
    @discardableResult
    func saveNow() -> Bool {
        guard canUseWorkspace else { return true }
        return persistence.flushNow(workspace)
    }

    /// AppKit waits for the latest durable acknowledgement before ending the process.
    func requestTermination(_ app: NSApplication) -> NSApplication.TerminateReply {
        if allowUnsavedTermination {
            allowUnsavedTermination = false
            return .terminateNow
        }
        guard canUseWorkspace, persistence.state.isDirty else { return .terminateNow }
        guard !terminationPending, !quitWarningShown else { return .terminateCancel }
        terminationPending = true
        Task {
            let saved = await saveWorkspaceNow()
            terminationPending = false
            app.reply(toApplicationShouldTerminate: saved)
            if !saved { showQuitWarning(app) }
        }
        return .terminateLater
    }

    private func showQuitWarning(_ app: NSApplication) {
        guard persistence.state.isDirty, !quitWarningShown else { return }
        quitWarningShown = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Workspace Changes Haven't Been Saved")
        alert.informativeText = String(localized: "Keep eGlu open to retry saving or export a workspace backup. Quitting without saving can lose changes to spaces, tabs and bookmarks. Unsaved website content is not included in a backup.")
        alert.addButton(withTitle: String(localized: "Keep Open")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Retry Save"))
        alert.addButton(withTitle: String(localized: "Export Workspace Backup"))
        alert.addButton(withTitle: String(localized: "Quit Without Saving")).hasDestructiveAction = true
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            quitWarningShown = false
            switch response.rawValue {
            case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
                retryWorkspaceSave()
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                exportWorkspaceBeforeQuit()
            case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3:
                allowUnsavedTermination = true
                app.terminate(nil)
            default: break
            }
        }
        if let window = app.keyWindow ?? app.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window, completionHandler: finished)
        } else {
            // Quit is an app-level action and still needs a choice with no windows open.
            finished(alert.runModal())
        }
    }

    private func exportWorkspaceBeforeQuit() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "eGlu Workspace Backup.json")
        panel.message = String(localized: "The backup includes spaces, tab addresses and bookmarks. Sign-ins and unsaved website content are not included.")
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            do {
                try WorkspaceFile.exportData(workspace).write(to: destination, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "The Workspace Backup Wasn't Exported")
                alert.informativeText = String(localized: "Keep eGlu open, check available storage and choose another location to export the backup.")
                alert.addButton(withTitle: String(localized: "OK"))
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }

    /// What a page says about itself, its address and title, saved with
    /// everything else half a second after the last change.
    func record(_ tab: UUID, url: URL?, title: String?) {
        // A page says both many times over; only news is a change to make and to tell.
        guard let known = workspace.tab(tab) else { return }
        if url == nil || known.url == url, title == nil || known.title == title { return }
        change { $0.record(tab, url: url, title: title) }
    }

    /// A tab closed: gone, or, when it is pinned, unloaded and back at its
    /// pinned page (Workspace.closeTab). Each window that showed it shows
    /// what its space has selected now.
    func closeTab(_ id: UUID) {
        let next = change { $0.closeTab(id) }
        for window in allWindows where window.tabID == id {
            // The next tab may be on screen in another window already: this one shows its space's start instead.
            let shown = next.flatMap { tab -> UUID? in
                let shower = self.window(showing: tab)
                return tab == id || shower == nil || shower === window ? tab : nil
            }
            // A pinned tab closed is the one selected still when it is the space's only tab: unloaded, not shown.
            window.show(tab: shown == id ? nil : shown, inSpace: window.spaceID)
        }
        pages.close(id)
        replaced[id] = nil
    }

    /// A tab's page made afresh at `url`, of the other kind: a website's
    /// page and an extension's need different views. Where a window shows
    /// the tab, the new page takes the old one's place; off screen, it
    /// loads all the same. The old page's history goes with its view, so
    /// it is kept for Back (wentBackPastReplacement), unless `keepingOld`
    /// says the old page is nothing to go back to.
    func replacePage(of tab: UUID, in space: UUID, with url: URL, keepingOld: Bool = true) {
        guard workspace.spaceID(of: tab) == space else { return }
        let old = keepingOld ? pages.live[tab] : nil
        let kept = old.flatMap { page in
            page.view.url.flatMap { address in page.view.interactionState.map { Replaced(space: space, url: address, state: $0) } }
        }
        // The old site's name goes too: the new page names itself.
        change { $0.record(tab, url: url, title: "") }
        pages.close(tab)
        replaced[tab] = kept
        show(tab, in: space)
    }

    /// A tab's page, as it was before a rule put an extension's page in its
    /// place: the extension's page has no history of its own to go back in.
    private struct Replaced {
        let space: UUID
        let url: URL
        let state: Any
    }
    private var replaced: [UUID: Replaced] = [:]

    /// Whether Back, with nothing left in the page's own history, can take
    /// the tab to the page a rule replaced.
    func canGoBackPastReplacement(_ tab: UUID) -> Bool {
        replaced[tab].map { workspace.spaceID(of: tab) == $0.space } ?? false
    }

    /// Back past an extension's page that replaced the tab's: the page it
    /// replaced, its history as it was.
    func wentBackPastReplacement(_ tab: UUID) -> Bool {
        guard canGoBackPastReplacement(tab), let kept = replaced.removeValue(forKey: tab) else { return false }
        change { $0.record(tab, url: kept.url, title: "") }
        pages.close(tab)
        pages.keep(kept.state, url: kept.url, for: tab, in: kept.space)
        show(tab, in: kept.space)
        return true
    }

    /// The tab's new page, in the windows that show it, or loaded off screen.
    private func show(_ tab: UUID, in space: UUID) {
        for window in allWindows where window.spaceID == space {
            if window.tabID == tab { window.show(tab: tab, inSpace: space) } else { window.syncSplit() }
        }
        if !pages.isLive(tab), let record = workspace.tab(tab) { _ = pages.page(for: record, in: space) }
    }

    /// Several tabs closed at once: the space's Clear, or Close Other Tabs.
    func closeTabs(_ ids: [UUID]) {
        for id in ids { closeTab(id) }
    }

    /// The windows on the space go to another first, so no page goes from under a window still showing it.
    func removeSpace(_ id: UUID) {
        guard workspace.spaces.count > 1, let space = workspace.space(id),
              let other = workspace.spaces.first(where: { $0.id != id }) else { return }
        for window in allWindows where window.spaceID == id {
            window.showSpace(other.id)
        }
        for tab in space.tabs {
            pages.close(tab.id)
            replaced[tab.id] = nil
        }
        change { _ = $0.removeSpace(id) }
        // Its extensions and their data first: WebKit won't remove a store
        // that an extension controller still holds.
        Extensions.shared.removeSpace(id)
        Stores.erase(id)
        HistoryRecorder.shared.removeSpace(id)
    }

    /// A tab into another space. A window that showed it shows what its own
    /// space has selected now, unless another window has that on screen.
    func moveTab(_ id: UUID, to space: UUID, from owner: WindowModel, before target: UUID? = nil,
                 completion: @escaping @MainActor (UUID?) -> Void = { _ in }) {
        guard canUseWorkspace, let window = owner.window,
              window.isVisible, window.attachedSheet == nil,
              let plan = TabMovePlan(workspace: workspace, tab: id, destination: space, before: target)
        else { return completion(nil) }
        let originalOwnerSpace = owner.spaceID
        let live = pages.live[id]
        let alert = NSAlert()
        alert.messageText = plan.title
        alert.informativeText = plan.message
        alert.addButton(withTitle: BrowserText.localized("Move Tab"))
        alert.addButton(withTitle: BrowserText.localized("Open a Copy"))
        alert.addButton(withTitle: BrowserText.localized("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[2].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self, weak owner, weak window] answer in
            guard let self else { return completion(nil) }
            let choice: TabMovePlan.Choice
            switch answer {
            case .alertFirstButtonReturn: choice = .move
            case .alertSecondButtonReturn: choice = .copy
            default: return completion(nil)
            }
            guard let owner, let window, owner.window === window, window.isVisible,
                  owner.spaceID == originalOwnerSpace else { return completion(nil) }
            guard self.canUseWorkspace, plan.isValid(in: self.workspace), self.pages.live[id] === live else {
                owner.show(ActionToast(symbol: "exclamationmark.triangle", text: BrowserText.localized("The tab or space changed. Try moving it again.")))
                return completion(nil)
            }
            guard let result = self.change({ plan.apply(choice, to: &$0) }) else { return completion(nil) }
            if choice == .move {
                for window in self.allWindows where window.tabID == id {
                    let next = self.workspace.space(plan.source)?.selected
                    let shower = next.flatMap { self.window(showing: $0) }
                    window.show(tab: shower == nil || shower === window ? next : nil, inSpace: window.spaceID)
                }
                // PR50 isolation is unchanged; a copy never releases the original page.
                self.pages.moved(id)
            } else {
                owner.show(tab: result, inSpace: space)
            }
            completion(result)
        }
    }

    // MARK: Windows

    func register(_ window: WindowModel) {
        windows.add(window)
        guard !waiting.isEmpty else { return }
        let urls = waiting
        waiting = []
        for url in urls { window.open(url, newTab: true) }
    }

    func unregister(_ window: WindowModel) {
        windows.remove(window)
    }

    var allWindows: [WindowModel] {
        windows.allObjects
    }

    /// The window with `tab` on screen, with the keys or beside them.
    func window(showing tab: UUID) -> WindowModel? {
        allWindows.first { $0.shows(tab) }
    }

    /// The tabs on screen: one per window, two where a split is.
    var shownTabs: Set<UUID> {
        Set(allWindows.flatMap { [$0.page == nil ? nil : $0.tabID, $0.partner?.tab].compactMap { $0 } })
    }

    /// The window in front, or the one used last.
    var frontWindow: WindowModel? {
        allWindows.first { $0.window?.isKeyWindow == true }
            ?? allWindows.first { $0.window?.isMainWindow == true }
            ?? allWindows.first
    }

    /// Links from other apps (`fromOtherApp`), each in a little window of
    /// its own, as Arc's Little Arc, unless Settings › General › Links says
    /// a tab (Preferences.linksFromApps). Files from Finder, the app's own
    /// links and links from other apps otherwise, each in a new tab of the
    /// window in front; a new window for them when there is none.
    func open(_ urls: [URL], fromOtherApp: Bool = false) {
        guard canUseWorkspace else {
            waiting += urls
            // A window to say why the workspace can't be read and offer Retry
            // (WorkspaceRecoveryView), since nothing else would show. It takes
            // the links as tabs once the workspace is back (register).
            if !NSApp.windows.contains(where: \.isVisible) { openWindow?(nil) }
            return
        }
        let pages = urls.filter { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
        guard !pages.isEmpty else { return }
        pages.filter(\.isFileURL).forEach { FileAccess.keep($0) }
        if fromOtherApp, preferences.linksFromApps == .littleWindow {
            let links = pages.filter { !$0.isFileURL }
            if !links.isEmpty { LittleWindows.shared.putBackWindowsRaisedForLink() }
            for url in links { LittleWindow.open(url) }
            let files = pages.filter(\.isFileURL)
            guard !files.isEmpty else { return }
            return open(files)
        }
        if let window = frontWindow {
            for url in pages { window.open(url, newTab: true) }
            window.window?.makeKeyAndOrderFront(nil)
        } else {
            waiting += pages
            openWindow?(nil)
        }
    }
}

/// Web pages opened from Finder. The sandbox lets the app read such a file
/// only until it quits, and its tab keeps no more than the file's address:
/// each is kept as a security-scoped bookmark, so the tab still opens it
/// after a relaunch (Page.load).
@MainActor
enum FileAccess {
    private static let key = "fileBookmarks"
    /// The files read through their bookmarks since launch, which stay readable until the app quits.
    private static var opened: Set<URL> = []

    /// A bookmark to `url` while the app may read it, under `address`, the tab's.
    static func keep(_ url: URL, as address: URL? = nil) {
        guard url.isFileURL,
              let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        kept[(address ?? url).absoluteString] = data
        UserDefaults.standard.set(kept, forKey: key)
    }

    /// The file at `url` readable again through its bookmark, before a tab
    /// loads it; nothing for a file never opened from Finder, or a site.
    static func open(_ url: URL) {
        guard url.isFileURL, !opened.contains(url),
              let data = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[url.absoluteString]
        else { return }
        var stale = false
        guard let found = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                   bookmarkDataIsStale: &stale),
              found.startAccessingSecurityScopedResource()
        else { return }
        opened.insert(url)
        // A file moved or renamed since: its bookmark made again, for the next launch.
        if stale { keep(found, as: url) }
    }
}
