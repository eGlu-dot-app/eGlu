import AppKit
import Combine
import IOKit.pwr_mgt
import PadCore
import UniformTypeIdentifiers
import WebKit
import WebKitExtensions
import WebKitSupport

/// Chrome extensions, run by WebKit's own extension engine
/// (`WKWebExtension`), the one Safari uses (Docs/ExtensionsDesign.md).
///
/// Each space has an extension controller of its own, on the space's
/// website store, so an extension turned on in two spaces is two of it:
/// its storage, its sign-ins and what it was allowed are each space's. An
/// extension's files are kept once, for every space.
///
/// Google's sign-in stays out of every extension's reach (ExtensionPolicy):
/// each context denies its hosts, whatever the extension asked for, and the
/// `cookies` permission until the person allows it for that extension.
@MainActor
final class Extensions: NSObject, ObservableObject {
    static let shared = Extensions()

    /// What is installed, and where it is on.
    @Published private(set) var installed: [Installed] = []
    /// What the checks after install found, by space and extension.
    @Published private(set) var verdicts: [UUID: [String: ExtensionVerdict]] = [:]
    /// The store extension being fetched and offered, for the store page's button.
    @Published private(set) var busy: String?
    /// Counts WebKit's word that an extension's button changed: its icon,
    /// its badge, its title (ExtensionActionButton reads them again).
    @Published private(set) var actionsChanged = 0
    /// What a check found that hasn't been read yet, by "space/id": the
    /// puzzle button's dot.
    @Published private(set) var unseen: Set<String> = []
    /// Those whose manifest offers cookies as an optional permission, by
    /// id: read from each package at launch, as it loads and as it is kept,
    /// so its settings give the cookie switch while it is on in no space.
    @Published private(set) var offersCookies: Set<String> = []
    @Published private(set) var justInstalled: JustInstalled?
    /// Each extension's icon, read once.
    private var icons: [String: NSImage] = [:]
    /// Packages with no icon, not read again for one each time Settings draws.
    private var iconless: Set<String> = []
    /// The popup an extension set for itself (action.setPopup), by
    /// "space/id"; "" for none. One set for a single tab isn't followed
    /// yet: WebKit doesn't say which of its tab numbers is which tab.
    var popupPaths: [String: String] = [:]
    private var storeWatch: AnyCancellable?
    private var updateClock: Timer?
    /// An update check under way (ExtensionUpdates).
    var checkingUpdates = false
    @Published var updateReport: ExtensionUpdateReport?
    @Published private(set) var listSaveProblem: String?

    struct Installed: Codable, Equatable, Identifiable {
        enum Source: String, Codable {
            /// From the Chrome Web Store, with Google's signature.
            case store
            /// A CRX the person chose, signed by its developer.
            case file
            /// A ZIP the person chose: no signature, so a random id of its own.
            case unsigned
            /// A developer's folder, Load Unpacked: its id is its path's, as
            /// Chrome makes it, so it can never be a store extension.
            case unpacked
        }

        enum SiteAccess: String, Codable {
            /// Every site it asked for.
            case allSites
            /// The page it was clicked on, each time.
            case onClick
        }

        var id: String
        var name: String
        var version: String
        var source: Source
        var siteAccess: SiteAccess
        /// The spaces it is on in.
        var spaces: [UUID]
        /// What it was allowed when installed or last asked
        /// (ExtensionManifest.grants): an update that wants more asks again.
        var granted: [String]?
        /// An unpacked extension's folder, which Reload reads again.
        var folder: String?
        /// The version whose warnings the person said look wrong (This
        /// Looks Wrong): not shown for it, and back with an update.
        var looksWrong: String?
        /// The person let it read cookies (its settings, or its own
        /// request): kept through updates, on this Mac only.
        var readsCookies: Bool?
    }

    /// The list has opened for the one just installed: not again.
    func tookJustInstalled() { justInstalled = nil }

    /// An extension just installed in a space: the puzzle button's list
    /// opens there by itself, with its check.
    struct JustInstalled: Equatable {
        var id: String
        var space: UUID
    }

    private var controllers: [UUID: WKWebExtensionController] = [:]
    /// A late failed load cannot disable a replacement at the same version.
    private var loadAttempts: [String: UUID] = [:]
    private var workerRecovery: [String: ExtensionWorkerRecovery] = [:]
    private(set) var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
    /// Extensions being asked about new tabs now.
    private var askingNewTab: Set<String> = []
    private var evidence: [UUID: [String: ExtensionEvidence]] = [:]
    /// What each extension asked for that nothing here answers: what its
    /// errors are read against.
    private(set) var lacking: [String: Set<String>] = [:]
    /// Each extension's manifest, as read at its first look.
    private var manifests: [String: ExtensionManifest] = [:]
    /// What trying a version's pages on a copy found, by id, once a version
    /// (ExtensionTrial.check); kept across launches.
    private var checked: [String: (version: String, result: ExtensionTrial.Checked)] = [:]
    /// The version being tried, by id.
    private var checking: [String: String] = [:]
    /// What reading each extension's code found (notes), by id, for the
    /// version and the APIs missing it was read against; and the reading
    /// under way. A password manager's scripts run to megabytes, and read
    /// on the main thread, once a space, they held the browser for
    /// seconds as it loaded.
    private var scanned: [String: (key: String, notes: [String])] = [:]
    private var scanning: [String: (key: String, attempt: UUID)] = [:]
    /// The errors already put in the records, by "space/id": a short
    /// fingerprint of each, never its words, until the context unloads.
    private var recorded: [String: Set<String>] = [:]
    /// The problems each extension ran into, kept on this Mac (ExtensionRecords).
    private var records = ExtensionRecords()
    /// When each extension was last taken up afresh, by space and id: once a
    /// minute at most, so one that can never start doesn't go round.
    private var revived: [String: Date] = [:]
    /// The extensions whose own manifest asks for native messaging, and
    /// those that ask for it only as an optional permission, which reach a
    /// desktop app once the person has said yes, as Chrome asks. Every
    /// prepared one has the permission, for the shim's way to eGlu.
    private var nativeRequired: Set<String> = []
    private var nativeOptional: Set<String> = []
    static let nativeConsentKey = "extensionNativeConsent"

    /// Whether an extension may reach a desktop app's host.
    func reachesApps(_ id: String) -> Bool {
        nativeRequired.contains(id)
            || (nativeOptional.contains(id) && (UserDefaults.standard.stringArray(forKey: Self.nativeConsentKey) ?? []).contains(id))
    }

    /// The person's yes or no to an optional native messaging, kept.
    func setNativeConsent(_ id: String, _ yes: Bool) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.nativeConsentKey) ?? [])
        if yes { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: Self.nativeConsentKey)
    }

    func asksForNativeOnlyOptionally(_ id: String) -> Bool { nativeOptional.contains(id) }

    /// Whether it asks for cookies, outright or as an optional permission:
    /// a choice its settings give. Once allowed, the choice shows even
    /// before its manifest is read (on in no space), so it can be taken back.
    func asksForCookies(_ item: Installed) -> Bool {
        item.granted?.contains("cookies") == true || item.readsCookies == true || offersCookies.contains(item.id)
    }

    private func note(_ manifest: ExtensionManifest?, of id: String) {
        guard let manifest else { return }
        if manifest.optionalPermissions.contains("cookies") { offersCookies.insert(id) } else { offersCookies.remove(id) }
    }

    /// Whether the person let it read cookies: not until they do.
    func readsCookies(_ id: String) -> Bool {
        installed.first { $0.id == id }?.readsCookies == true
    }

    /// Lets it read cookies, or takes that back, in every space it is on
    /// in. There it starts again, unless it just asked for them itself, so
    /// its worker starts knowing what it may do: Grammarly tries its
    /// cookies as it starts.
    func setReadsCookies(_ id: String, _ on: Bool, restarting: Bool = true) {
        guard let index = installed.firstIndex(where: { $0.id == id }), (installed[index].readsCookies == true) != on else { return }
        installed[index].readsCookies = on
        saveList()
        for (space, loaded) in contexts {
            guard let context = loaded[id] else { continue }
            Self.holdCookies(context, letting: on)
            update(id, in: space) { $0.cookiesKeptBack = !on && self.manifests[id]?.permissions.contains("cookies") == true }
            // Started again on the same context, which keeps what it was
            // granted while it ran and its open pages working.
            if restarting { restart(id, in: space, because: on ? "cookies allowed" : "cookies taken back") }
        }
    }
    /// Keep-awake assertions an extension asked for (power), by "space/id".
    var keptAwake: [String: IOPMAssertionID] = [:]
    /// Each loaded context's errors watch, removed when it unloads.
    private var watches: [UUID: [String: NSObjectProtocol]] = [:]
    let tabs = ExtensionTabs(host: ExtensionHost.shared,
                             enabled: { !Extensions.shared.on(in: $0).isEmpty },
                             controller: { Extensions.shared.controller(for: $0) },
                             othersPage: { Extensions.othersPage($0, for: $1) },
                             refusal: { Extensions.refusal(opening: $0, by: $1) },
                             heldOwner: { ExtensionAuth.owner(of: $0) })

    /// The scheme of extensions' own pages, as Chrome's.
    static let scheme = "chrome-extension"
    private static let apiTable = ExtensionTable(scheme: scheme)

    private override init() {
        super.init()
        // Before any context takes a base address in it: WebKit refuses one
        // in a scheme it wasn't told of, with an exception, not an error
        // (WKWebExtensionContext's setBaseURL:), and AppKit, catching it,
        // leaves Swift's tasks broken behind it.
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.scheme)
    }

    static var folder: URL {
        Session.folder.appendingPathComponent("Extensions", isDirectory: true)
    }

    private static var listFile: URL {
        folder.appendingPathComponent("installed.json")
    }

    /// The verified package of a version, kept as it came.
    static func package(_ id: String, _ version: String) -> URL {
        folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent("\(version).zip")
    }

    /// The folder WebKit loads a version from: its package unpacked, with
    /// the shim put in (ExtensionPreparation).
    static func prepared(_ id: String, _ version: String) -> URL {
        folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent(version, isDirectory: true)
    }

    /// Makes the prepared folder from the package, unless it is there and
    /// was made from this package with this shim. Off the main thread: a large extension
    /// takes a moment. Into a folder of its own first, so a folder that is
    /// there is always a whole one; and one at a time, so a load in another
    /// space, which may be reading it, finds it made rather than replaced.
    /// Only a folder made with another shim is replaced, and nothing loads
    /// one of those.
    nonisolated static func prepare(_ package: URL, into folder: URL) throws {
        try preparing.withLock { try prepareNow(package, into: folder) }
    }

    private nonisolated static let preparing = NSLock()

    private nonisolated static func prepareNow(_ package: URL, into folder: URL) throws {
        var shim = Scripts.extensionShim
        #if DEBUG
        // To see what WebKit does without it (`-extensionsWithoutShim YES`).
        if UserDefaults.standard.bool(forKey: "extensionsWithoutShim") { shim = "" }
        #endif
        // The package's size and time, taken before it is read: one put in
        // its place, of the same version, is told apart.
        let kept = try package.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = [ExtensionPreparation.stamp(for: shim), String(kept.fileSize ?? 0),
                     String(kept.contentModificationDate?.timeIntervalSince1970 ?? 0)].joined(separator: " ")
        let stampFile = folder.appendingPathComponent(ExtensionPreparation.stampFile)
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp { return }
        let archive = try Data(contentsOf: package)
        let files = FileManager.default
        let making = folder.deletingLastPathComponent()
            .appendingPathComponent(".\(folder.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: making, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: making) }
        // Every name was checked to stay inside the folder before the
        // first is written, and only plain files are made: no link in a
        // package can lead a later file elsewhere.
        try ExtensionPreparation.prepare(archive, shim: shim, stamp: stamp) { path, data in
            let file = making.appendingPathComponent(path)
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
        try files.moveItem(at: making, to: folder)
    }

    // MARK: Starting

    /// At launch: what is installed, loaded where it is on, one after
    /// another, as starting them all at once leaves some workers unstarted.
    func start(afterLaunch: Bool = false) {
        #if DEBUG
        // To tell the extensions' part of a launch from the rest (`-noExtensions YES`).
        if UserDefaults.standard.bool(forKey: "noExtensions") { return }
        #endif
        if let data = try? Data(contentsOf: Self.listFile),
           let list = try? JSONDecoder().decode([Installed].self, from: data) {
            installed = list
        }
        discardStaleIncompatibilities()
        readRecords()
        tabs.start()
        storeWatch = StoreButton.follow()
        forgetLeftOver()
        updateClock = startUpdates()
        // Loaded once the app has finished launching, and the turn after: a
        // load holds the main thread long enough to hold up the first frame,
        // as Search found (its Extensions.swift, start(for:)).
        if afterLaunch {
            DispatchQueue.main.async { [weak self] in self?.loadAll() }
        } else {
            launched = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.loadAll() } }
            }
        }
    }

    private var launched: NSObjectProtocol?

    private func loadAll() {
        if let launched { NotificationCenter.default.removeObserver(launched) }
        launched = nil
        #if DEBUG
        checkFromTheCommandLine()
        askFromTheCommandLine()
        #endif
        Task {
            await refreshInstalledNames()
            await forgetWorkersIfChanged()
            for item in installed {
                for space in item.spaces where Session.shared.workspace.space(space) != nil {
                    await load(item, in: space)
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            // Measured once a macOS build, when there is something to read against it.
            if !installed.isEmpty { await measureTable() }
        }
    }

    // MARK: Workers WebKit remembers (Search's 0386648)

    /// WebKit keeps each extension's service worker registered from one
    /// launch to the next, with the scripts it fetched then, and may start
    /// that copy rather than what is on disk now. A copy from another build
    /// of the shim or another version of the extension can leave the worker
    /// dead for good: reinstalling, reloading and restarting all bring the
    /// same stale copy back (Vimium's keys stopped working, for Search).
    /// WebKit lists no records for extension origins, so there is no
    /// clearing one extension's alone; clearing a space's stops the workers
    /// that run there. So it is done at launch, before any extension loads,
    /// in each space whose extensions or shim changed since. Websites'
    /// workers there go with them, and are registered again on the next
    /// visit; nothing else of theirs is touched.
    static let workersKey = "extensionWorkers"

    /// What a space's workers would run: the shim, and the extensions on there.
    /// Those on there now, and those on there before (`was`) that are still
    /// installed: one turned off keeps its worker registered in the space's
    /// store, and an update or a new shim can make that one stale too.
    private func workers(in space: UUID, keeping was: String?) -> String {
        let before = Set((was ?? "").split(separator: "\n").dropFirst().compactMap { $0.split(separator: " ").first.map(String.init) })
        let tracked = installed.filter { $0.spaces.contains(space) || before.contains($0.id) }
        return ([ExtensionPreparation.stamp(for: Scripts.extensionShim)] + tracked.map { "\($0.id) \($0.version)" }.sorted())
            .joined(separator: "\n")
    }

    /// Cleared when the shim changed or an extension there before (on, or
    /// turned off since) has another version now: one only added has no
    /// worker kept yet, and one removed from eGlu has its data removed
    /// with it. On the first launch, or after workersChanged, every space
    /// with extensions on or had is cleared.
    private func forgetWorkersIfChanged() async {
        let stored = UserDefaults.standard.dictionary(forKey: Self.workersKey) as? [String: String]
        let forced = stored == nil || UserDefaults.standard.bool(forKey: Self.workersForcedKey)
        var kept = stored ?? [:]
        var failed = UserDefaults.standard.dictionary(forKey: Self.workerFailedKey) as? [String: String] ?? [:]
        for space in Session.shared.workspace.spaces.map(\.id) {
            let on = installed.filter { $0.spaces.contains(space) }
            let was = kept[space.uuidString]
            // A space no extension has been on in has no worker to clear.
            guard !on.isEmpty || was != nil else { continue }
            let now = workers(in: space, keeping: was)
            // None left there at all, their data gone with them: nothing to
            // keep, and websites' workers no reason to go.
            guard now.contains("\n") else { kept[space.uuidString] = nil; continue }
            guard was != now || forced else { continue }
            kept[space.uuidString] = now
            guard forced || was.map({ ExtensionWorkerRecovery.stale(was: $0, now: now) }) == true else { continue }
            await WebKitStores.store(for: space).removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast)
            // One found incompatible only because its worker wouldn't start
            // gets one more go, now its stale copy is gone: once a version.
            for item in on where failed[item.id] == checkStamp(item.version) {
                failed[item.id] = checkStamp(item.version) + " retried"
                var marked = UserDefaults.standard.dictionary(forKey: Self.incompatibleKey) as? [String: String] ?? [:]
                marked[item.id] = nil
                UserDefaults.standard.set(marked, forKey: Self.incompatibleKey)
            }
        }
        UserDefaults.standard.set(kept, forKey: Self.workersKey)
        UserDefaults.standard.removeObject(forKey: Self.workersForcedKey)
        UserDefaults.standard.set(failed, forKey: Self.workerFailedKey)
    }

    /// Extensions found incompatible because their worker wouldn't start,
    /// by id: the version's stamp, and whether it has had its retry.
    private static let workerFailedKey = "extensionsWorkerFailed"

    /// An extension put in again, reloaded or found with its worker dead:
    /// its version alone doesn't tell, so the next launch clears every space
    /// that has had extensions, its record of which is kept for that.
    static func workersChanged() {
        UserDefaults.standard.set(true, forKey: workersForcedKey)
    }

    private static let workersForcedKey = "extensionWorkersForced"

    /// Names kept by older releases may be an ID or an unresolved message.
    /// Read packages after the first frame, off the main actor, including
    /// extensions disabled in every space. A missing package keeps its name.
    /// Whether each offers cookies is read with it.
    private func refreshInstalledNames() async {
        let candidates = installed.map { (id: $0.id, version: $0.version, name: $0.name) }
        var changed = false
        for candidate in candidates {
            let file = Self.package(candidate.id, candidate.version)
            let (name, manifest) = await Task.detached(priority: .utility) { () -> (String, ExtensionManifest?) in
                guard let archive = try? Data(contentsOf: file),
                      let data = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }),
                      let manifest = try? ExtensionManifest(json: data) else { return (candidate.name, nil) }
                return (manifest.displayName(in: archive, fallback: candidate.name), manifest)
            }.value
            if installed.contains(where: { $0.id == candidate.id && $0.version == candidate.version }) { note(manifest, of: candidate.id) }
            guard let index = installed.firstIndex(where: { $0.id == candidate.id && $0.version == candidate.version }),
                  installed[index].name == candidate.name, installed[index].name != name else { continue }
            installed[index].name = name
            changed = true
        }
        if changed { saveList() }
    }

    private func saveList() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(installed).write(to: Self.listFile, options: .atomic)
            listSaveProblem = nil
            Sync.shared.extensionsChanged()
        } catch {
            NSLog("eGlu: couldn't save the extension list: \(error.localizedDescription)")
            listSaveProblem = BrowserText.localized("Extension changes could not be saved. Check available storage and retry.")
        }
    }

    func retryListSave() { saveList() }

    // MARK: Between Macs (iCloud)

    /// What iCloud's list says of this Mac's extensions: those from the
    /// Chrome Web Store (a file or a folder has nowhere to come from on
    /// another Mac), with the synced spaces each is on in.
    var syncList: [SyncPlan.LocalExtension] {
        let clouds = Dictionary(Session.shared.workspace.spaces.compactMap { space in space.cloudID.map { (space.id, $0.uuidString) } },
                                uniquingKeysWith: { first, _ in first })
        return installed.filter { $0.source == .store }.map {
            .init(storeID: $0.id, title: $0.name, siteAccess: $0.siteAccess.rawValue, spaces: Set($0.spaces.compactMap { clouds[$0] }))
        }
    }

    /// Another Mac's change, followed here: removed there, removed here
    /// with what it kept, as Chrome's sync does; turned on or off in a
    /// space there, the same here.
    /// Returns what it couldn't place yet, a space that hasn't arrived.
    @discardableResult
    func follow(removed: [String], on: [SyncPlan.ExtensionInSpace], off: [SyncPlan.ExtensionInSpace])
        -> (on: [SyncPlan.ExtensionInSpace], off: [SyncPlan.ExtensionInSpace]) {
        let spaces = Session.shared.workspace.spaces
        let local = { (cloud: String) in spaces.first { $0.cloudID?.uuidString == cloud }?.id }
        for id in removed where installed.contains(where: { $0.id == id && $0.source == .store }) { remove(id) }
        var waiting: (on: [SyncPlan.ExtensionInSpace], off: [SyncPlan.ExtensionInSpace]) = ([], [])
        for change in on {
            if let space = local(change.space) { turn(change.storeID, on: true, in: space) } else { waiting.on.append(change) }
        }
        for change in off {
            if let space = local(change.space) { turn(change.storeID, on: false, in: space) } else { waiting.off.append(change) }
        }
        return waiting
    }

    /// Another Mac's extension the person doesn't want here: not offered again.
    private static let declinedKey = "extensionsDeclined"

    func decline(_ storeID: String) {
        var declined = Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? [])
        declined.insert(storeID)
        UserDefaults.standard.set(declined.sorted(), forKey: Self.declinedKey)
        objectWillChange.send()
    }

    /// Other Macs' extensions to offer here.
    func offers(from sync: Sync) -> [SyncExtension] {
        let declined = Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? [])
        let here = Set(installed.map(\.id))
        return sync.extensionOffers.filter { !declined.contains($0.storeID) && !here.contains($0.storeID) }
    }

    /// The space's controller, made the first time a page in the space is.
    /// Every page gets it before its view exists, as WebKit needs, whether
    /// or not anything is on in the space yet.
    func controller(for space: UUID) -> WKWebExtensionController {
        if let controller = controllers[space] { return controller }
        let configuration = WKWebExtensionController.Configuration(identifier: space)
        configuration.defaultWebsiteDataStore = WebKitStores.store(for: space)
        // The extensions' own pages reach eGlu's recording channel
        // (ExtensionCapture), in their own world; websites never do.
        let pages = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        pages.userContentController.addScriptMessageHandler(ExtensionCapture.shared, contentWorld: .page, name: ExtensionCapture.channel)
        #if DEBUG
        ExtensionCapture.mockDevices(pages.preferences)
        #endif
        configuration.webViewConfiguration = pages
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        controllers[space] = controller
        return controller
    }

    func space(of controller: WKWebExtensionController?) -> UUID? {
        controllers.first { $0.value === controller }?.key
    }

    func context(_ id: String, in space: UUID) -> WKWebExtensionContext? {
        contexts[space]?[id]
    }

    /// The extensions on in a space, in the order they were installed.
    func on(in space: UUID) -> [Installed] {
        installed.filter { $0.spaces.contains(space) && contexts[space]?[$0.id] != nil }
    }

    /// Whether a URL is one of the extensions' own pages.
    func isExtensionPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == Self.scheme, let host = url.host() else { return false }
        return installed.contains { $0.id == host }
    }

    // MARK: Loading

    /// Whether it is loaded there now.
    @discardableResult
    private func load(_ item: Installed, in space: UUID) async -> Bool {
        // Not on this Mac, for this version (markIncompatible).
        guard !isIncompatible(item.id) else { return false }
        guard await cleared(item.id, in: space) else {
            NSLog("eGlu: extension \(item.id) waits for what was kept before to be cleared in a space")
            return false
        }
        guard contexts[space]?[item.id] == nil else { return true }
        let key = "\(space.uuidString)/\(item.id)"
        let attempt = UUID()
        loadAttempts[key] = attempt
        var seen = ExtensionEvidence()
        do {
            let (file, folder) = (Self.package(item.id, item.version), Self.prepared(item.id, item.version))
            try await Task.detached(priority: .userInitiated) { try Self.prepare(file, into: folder) }.value
            let package = try await WKWebExtension(resourceBaseURL: folder)
            // Turned off here, removed, updated, or its space gone, while the
            // package was read: not loaded after all. Another space's turning
            // on or off is no reason.
            guard loadAttempts[key] == attempt,
                  let now = installed.first(where: { $0.id == item.id }), now.version == item.version,
                  now.source == item.source, now.spaces.contains(space),
                  Session.shared.workspace.space(space) != nil, contexts[space]?[item.id] == nil
            else { return contexts[space]?[item.id] != nil }
            let context = WKWebExtensionContext(for: package)
            context.uniqueIdentifier = item.id
            // chrome-extension://, as Chrome's own addresses are: an
            // extension that checks where its pages are finds them there.
            context.baseURL = URL(string: "\(Self.scheme)://\(item.id)/")!
            context.isInspectable = true
            context.inspectionName = item.name
            // The cookie choice as it is now: it may have changed while the package was read.
            allow(context, package, access: item.siteAccess, cookies: now.readsCookies == true)
            watch(context, item, in: space)
            try controller(for: space).load(context)
            // Its commands' keys: the person's, or none (ExtensionKeys).
            ExtensionKeys.shared.apply(to: context)
            contexts[space, default: [:]][item.id] = context
            seen = firstLook(at: context, package, archive: Self.package(item.id, item.version), id: item.id)
        } catch {
            guard loadAttempts[key] == attempt else { return contexts[space]?[item.id] != nil }
            seen.start = .failed
            unwatch(item.id, in: space)
            // WebKit wouldn't take it at all.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadAttempts[key] == attempt, self.contexts[space]?[item.id] == nil else { return }
                self.markIncompatible(item.id, version: item.version)
            }
            NSLog("eGlu: extension \(item.id) didn't load in a space: \(error.localizedDescription)")
            #if DEBUG
            Self.note("load failed: \(error)")
            #endif
        }
        record(seen, item.id, in: space)
        if contexts[space]?[item.id] != nil { readCode(of: item) }
        if seen.start == .checking, let context = contexts[space]?[item.id] {
            startBackground(of: context, item, in: space)
        }
        if contexts[space]?[item.id] != nil {
            checkCopy(of: item)
            // The first extension on a new macOS build: this Mac's table.
            if Self.apiTable.table == nil { Task { await measureTable() } }
        }
        return contexts[space]?[item.id] != nil
    }

    private func unload(_ id: String, in space: UUID) {
        let key = "\(space.uuidString)/\(id)"
        loadAttempts[key] = nil
        workerRecovery[key] = nil
        unwatch(id, in: space)
        guard let context = contexts[space]?.removeValue(forKey: id) else { return }
        // A keep-awake it asked for (power) goes with it.
        if let assertion = keptAwake.removeValue(forKey: key) { IOPMAssertionRelease(assertion) }
        // Its popup and panel first, while WebKit can still be told they
        // close, as it was told they opened.
        ExtensionPopups.shared.closeAll(of: id, in: space)
        ExtensionSidePanels.shared.closeAll(of: id, in: space)
        ExtensionPopupWindow.closeAll(of: id, in: space)
        ExtensionCapture.shared.purge(id, in: space)
        try? controllers[space]?.unload(context)
        evidence[space]?[id] = nil
        verdicts[space]?[id] = nil
        recorded["\(space.uuidString)/\(id)"] = nil
        // What it kept going outside WebKit goes with it: its offscreen
        // page; and its hosts once WebKit has had a turn to let its ports go.
        ExtensionOffscreen.close(id, in: space)
        ExtensionSocket.close(id, in: space)
        DispatchQueue.main.async { ExtensionNative.stopOrphans() }
    }

    /// An extension whose worker won't start again, taken up afresh as a
    /// relaunch would: unloaded and loaded, the same context, since the
    /// objects its open pages hold name this one. At most once a minute in
    /// a space. (Search's revive)
    @discardableResult
    func revive(_ id: String, in space: UUID, because reason: String) -> Bool {
        let key = "\(space.uuidString)/\(id)"
        guard contexts[space]?[id] != nil, controllers[space] != nil,
              Date().timeIntervalSince(revived[key] ?? .distantPast) > 60 else { return false }
        revived[key] = Date()
        return restart(id, in: space, because: reason)
    }

    /// Unloaded and loaded again, the same context, and its worker started:
    /// what it was granted while it ran (permissions.request) stays, and its
    /// open pages keep working, as they would not with a new context.
    @discardableResult
    private func restart(_ id: String, in space: UUID, because reason: String) -> Bool {
        let key = "\(space.uuidString)/\(id)"
        guard let context = contexts[space]?[id], let controller = controllers[space] else { return false }
        Self.workersChanged()
        NSLog("eGlu: restarting extension \(id): \(reason)")
        #if DEBUG
        Self.note("revived: \(reason)")
        #endif
        ExtensionOffscreen.close(id, in: space)
        // A keep-awake the worker asked for (power) goes with it; the new
        // worker asks again if it still wants one.
        if let assertion = keptAwake.removeValue(forKey: key) { IOPMAssertionRelease(assertion) }
        let attempt = workerRecovery[key, default: ExtensionWorkerRecovery()].beganAttempt(restarting: true)
        do {
            try controller.unload(context)
            try controller.load(context)
        } catch {
            NSLog("eGlu: extension \(id) couldn't be loaded again: \(error.localizedDescription)")
            update(id, in: space) { $0.start = .failed }
            if let item = installed.first(where: { $0.id == id }) {
                let action = workerRecovery[key, default: ExtensionWorkerRecovery()].finished(attempt, failed: true)
                recover(action, context: context, item: item, in: space)
            }
            return true
        }
        if let item = installed.first(where: { $0.id == id }) { startBackground(of: context, item, in: space, attempt: attempt) }
        return true
    }

    /// What the extension may do: what it asked for, less cookies unless
    /// the person allowed them; its sites when the person chose all of
    /// them; never Google's sign-in.
    private func allow(_ context: WKWebExtensionContext, _ package: WKWebExtension, access: Installed.SiteAccess, cookies: Bool) {
        for permission in package.requestedPermissions where !ExtensionPolicy.heldPermissions.contains(permission.rawValue) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        Self.holdCookies(context, letting: cookies)
        Self.letRulesRedirect(context, package)
        if access == .allSites {
            for pattern in Self.sites(of: package) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        }
        Self.fence(context)
    }

    /// Cookies denied, or granted when the person let this extension have
    /// them and it asks for them, outright or as an optional permission.
    /// Granted, it reads them on the sites it may read, Google's sign-in
    /// cookies included (set for .google.com): the person was told so.
    static func holdCookies(_ context: WKWebExtensionContext, letting cookies: Bool) {
        let package = context.webExtension
        let asked = package.requestedPermissions.union(package.optionalPermissions).contains(.cookies)
        context.setPermissionStatus(cookies && asked ? .grantedExplicitly : .deniedExplicitly, for: .cookies)
    }

    /// Chrome lets "declarativeNetRequest" redirect a request or change its
    /// headers on the sites the extension has access to. WebKit does that
    /// only with "declarativeNetRequestWithHostAccess", and otherwise drops
    /// those rules without a word: Norma's redirect of a blocked site to its
    /// own page never happened, and the site loaded instead. WebKit still
    /// holds the rules to the sites granted. (Search)
    static func letRulesRedirect(_ context: WKWebExtensionContext, _ package: WKWebExtension) {
        guard package.requestedPermissions.contains(.declarativeNetRequest) else { return }
        context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
    }

    /// The sites to grant of those an extension names: none withheld, and
    /// none a wildcard of the same scheme and path already covers. WebKit
    /// copies an extension's injected scripts for each pattern granted, so
    /// one naming many hosts beside a wildcard took that much more memory.
    /// (Search's d24ceca)
    static func sites(of package: WKWebExtension) -> [WKWebExtension.MatchPattern] {
        let patterns = package.allRequestedMatchPatterns.filter { !withheld($0) }
        return patterns.filter { pattern in
            !patterns.contains { other in
                other.string != pattern.string && other.scheme == pattern.scheme && other.path == pattern.path
                    && other.matches(pattern) && (!pattern.matches(other) || other.string < pattern.string)
            }
        }
    }

    // MARK: What no extension reaches

    /// Extension pages, another's or every one's, and files on this Mac, as
    /// a pattern names them: never given, from a manifest or a question.
    /// With chrome-extension registered as a scheme, WebKit counts other
    /// extensions' pages in <all_urls>, which Chrome doesn't (a password
    /// manager's vault among them; seen on macOS 27.0.1). Chrome keeps files
    /// from an extension until "Allow access to file URLs" is turned on for
    /// it, a switch eGlu doesn't have. Its own pages are its own. (Search)
    nonisolated static func withheld(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        guard let scheme = pattern.scheme?.lowercased() else { return false }
        return [Self.scheme, "webkit-extension", "file"].contains(scheme)
    }

    /// Whether an address is a page of an extension other than this one,
    /// which it never sees into.
    nonisolated static func othersPage(_ url: URL?, for context: WKWebExtensionContext) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), [Self.scheme, "webkit-extension"].contains(scheme) else { return false }
        return url.host()?.lowercased() != context.uniqueIdentifier.lowercased()
    }

    /// The refusals, set again after anything is granted, since WebKit
    /// weighs a grant naming a site before a refusal of all of them:
    /// extension pages, files, and the hands-off sites. Refusing extension
    /// pages takes back a grant of <all_urls> too, so what it meant for
    /// websites is kept as *://*/*, given before the hands-off sites are
    /// refused, which takes them out of it again. (Search's fence)
    ///
    /// An extension that asks for identity keeps its own sign-in address,
    /// https://<id>.chromiumapp.org, never loaded (ExtensionAuth.handOver):
    /// WebKit shows an extension a tab's address only where it has access,
    /// and one watching its sign-in tab for that address has to see it.
    static func fence(_ context: WKWebExtensionContext) {
        let everything = context.grantedPermissionMatchPatterns.keys.contains { $0.matchesAllURLs }
        for string in ["\(scheme)://*/*", "webkit-extension://*/*", "file:///*", "file://*/*"] {
            if let pattern = try? WKWebExtension.MatchPattern(string: string) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
        }
        if everything, let web = try? WKWebExtension.MatchPattern(string: "*://*/*") {
            context.setPermissionStatus(.grantedExplicitly, for: web)
        }
        for site in ExtensionPolicy.deniedSites {
            if let pattern = try? WKWebExtension.MatchPattern(string: site) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
        }
        if asks(context, for: "identity"),
           let own = try? WKWebExtension.MatchPattern(string: "https://\(context.uniqueIdentifier.lowercased()).chromiumapp.org/*") {
            context.setPermissionStatus(.grantedExplicitly, for: own)
        }
    }

    // MARK: Checking (Docs/ExtensionsDesign.md, section 4)

    /// What can be told before the background has started: what WebKit
    /// dropped from what it asked for, and what its code reaches for that
    /// nothing here answers.
    private func firstLook(at context: WKWebExtensionContext, _ package: WKWebExtension, archive file: URL, id: String) -> ExtensionEvidence {
        var seen = ExtensionEvidence()
        seen.start = package.hasBackgroundContent ? .checking : .started
        guard let archive = try? Data(contentsOf: file),
              let manifestData = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }),
              let manifest = try? ExtensionManifest(json: manifestData)
        else { return seen }
        if manifest.permissions.contains("nativeMessaging") { nativeRequired.insert(id) } else { nativeRequired.remove(id) }
        if !manifest.permissions.contains("nativeMessaging"), manifest.optionalPermissions.contains("nativeMessaging") {
            nativeOptional.insert(id)
        } else {
            nativeOptional.remove(id)
        }
        manifests[id] = manifest
        note(manifest, of: id)
        seen.cookiesKeptBack = manifest.permissions.contains("cookies") && !readsCookies(id)
        let missing = missing(for: manifest, package)
        lacking[id] = missing
        // Read away from the main thread once it has loaded (readCode).
        if let version = installed.first(where: { $0.id == id })?.version, let done = scanned[id],
           done.key == Self.scanKey(version, missing) {
            seen.mayNotWork = done.notes
        }
        // On the list of those tried by hand, for its version.
        if let item = installed.first(where: { $0.id == id }), item.source == .store,
           let tried = ExtensionTried.shipped.entry(for: id, version: item.version) {
            seen.tried = .init(release: tried.release, works: tried.works, what: tried.what)
            if !tried.works { DispatchQueue.main.async { [weak self] in self?.markIncompatible(id, version: item.version) } }
        }
        // What its copy's pages showed, for this version, if they were tried.
        if let done = checked[id], done.version == installed.first(where: { $0.id == id })?.version {
            Self.apply(done.result, to: &seen)
        }
        return seen
    }

    /// What it asks for that nothing on this Mac answers: against this
    /// Mac's measured table (ExtensionTable) once there is one; before,
    /// what WebKit dropped and no shim answers. A permission's name is its
    /// namespace's.
    private func missing(for manifest: ExtensionManifest, _ package: WKWebExtension) -> Set<String> {
        let kept = Set((package.requestedPermissions.union(package.optionalPermissions)).map(\.rawValue))
        let asked = manifest.permissions + manifest.optionalPermissions
        var missing: Set<String>
        if let table = Self.apiTable.table {
            missing = table.missing(asked: asked, kept: kept)
            if manifest.usesChromeSignIn, !table.works("identity.getAuthToken") { missing.insert("identity.getAuthToken") }
        } else {
            let shims = ExtensionAPITable(answers: ExtensionAPITable.shims)
            missing = Set(manifest.dropped(kept: kept).filter { $0 != "cookies" && !shims.works($0) }
                + (manifest.usesChromeSignIn ? ["identity.getAuthToken"] : []))
        }
        // EyeDropper is a web API no permission names, so neither list holds
        // it; the shim answers it through the Mac's colour sampler. Should
        // the shim stop doing so, it goes back to being missing.
        if !Scripts.extensionShim.contains("eyeDropper") { missing.insert("EyeDropper") }
        return missing
    }

    private static func scanKey(_ version: String, _ missing: Set<String>) -> String {
        version + "|" + missing.sorted().joined(separator: ",")
    }

    /// Its code read for what it reaches for (notes), off the main thread,
    /// once for its version and what it lacks; what was found goes to every
    /// space it is loaded in.
    private func readCode(of item: Installed) {
        guard let manifest = manifests[item.id], let missing = lacking[item.id] else { return }
        let key = Self.scanKey(item.version, missing)
        let found = { [weak self] (notes: [String]) in
            guard let self else { return }
            for space in self.contexts.keys where self.contexts[space]?[item.id] != nil {
                self.update(item.id, in: space) { $0.mayNotWork = notes }
            }
        }
        if let done = scanned[item.id], done.key == key { return found(done.notes) }
        guard scanning[item.id]?.key != key else { return }
        let attempt = UUID()
        scanning[item.id] = (key, attempt)
        let file = Self.package(item.id, item.version)
        Task {
            let notes = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: file)).map { Self.notes(in: $0, manifest, missing: missing) } ?? []
            }.value
            // Updated, or read against a newer table, meanwhile: that reading wins.
            guard scanning[item.id]?.attempt == attempt else { return }
            scanning[item.id] = nil
            scanned[item.id] = (key, notes)
            found(notes)
        }
    }

    /// What its code reaches for, untested, that nothing here answers.
    nonisolated private static func notes(in archive: Data, _ manifest: ExtensionManifest, missing: Set<String>) -> [String] {
        var notes: [String] = []
        for file in manifest.files.map(ExtensionPreparation.normalized) where file.hasSuffix(".js") {
            guard let source = ZipFile.file(in: archive, matching: { ExtensionPreparation.normalized($0) == file }) else { continue }
            let uses = ExtensionScan.uses(in: String(decoding: source, as: UTF8.self), file: file, of: missing)
            for use in uses where !use.tested && !notes.contains(use.path) { notes.append(use.path) }
        }
        return notes
    }

    /// This Mac's table measured, the first time on a macOS build: what
    /// each loaded extension lacks read again against it.
    private func measureTable() async {
        guard Self.apiTable.table == nil, await Self.apiTable.measured() != nil else { return }
        for item in installed {
            guard let space = contexts.first(where: { $0.value[item.id] != nil })?.key, let context = contexts[space]?[item.id],
                  let manifest = manifests[item.id]
            else { continue }
            let missing = missing(for: manifest, context.webExtension)
            lacking[item.id] = missing
            readCode(of: item)
            for space in contexts.keys where contexts[space]?[item.id] != nil {
                // Its errors so far, read again against what it lacks now.
                if let context = contexts[space]?[item.id] { errorsChanged(context, item.id, in: space) }
            }
        }
    }

    // MARK: Its pages, tried on a copy

    private static let checkedKey = "extensionsPagesTried"

    private static func probe(_ probe: ExtensionEvidence.Probe) -> String {
        switch probe {
        case .notApplicable: return "none"
        case .checking: return "checking"
        case .passed: return "passed"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .timedOut: return "timedOut"
        }
    }

    private static func probe(_ word: String?) -> ExtensionEvidence.Probe {
        ["passed": .passed, "failed": .failed, "skipped": .skipped, "timedOut": .timedOut][word ?? ""] ?? .notApplicable
    }

    private static func apply(_ result: ExtensionTrial.Checked, to seen: inout ExtensionEvidence) {
        seen.testPage = result.testPage
        seen.popup = result.popup
        seen.optionsPage = result.optionsPage
        seen.problems.formUnion(result.problems.map(\.problem))
    }

    /// What a check's result holds for: the extension's version on this
    /// macOS build, eGlu and shim. Any of them new, it is tried again.
    private static let checkEnvironment = ExtensionCheckEnvironment(
        system: ExtensionTable.build, application: egluVersion,
        shim: ExtensionPreparation.stamp(for: Scripts.extensionShim))

    private func checkStamp(_ version: String) -> String { Self.checkEnvironment.stamp(for: version) }

    private func discardStaleIncompatibilities() {
        let held = UserDefaults.standard.dictionary(forKey: Self.incompatibleKey) as? [String: String] ?? [:]
        let versions = Dictionary(installed.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let current = Self.checkEnvironment.currentFailures(held, installed: versions)
        if current != held { UserDefaults.standard.set(current, forKey: Self.incompatibleKey) }
    }

    /// Its content scripts, popup and settings page tried on a copy, once a
    /// version, a few seconds after it first loads; what was found goes to
    /// every space it is on in. Kept, so a relaunch doesn't try them again.
    private func checkCopy(of item: Installed) {
        let stamp = checkStamp(item.version)
        if checked.isEmpty, let kept = UserDefaults.standard.dictionary(forKey: Self.checkedKey) as? [String: [String: Any]] {
            for (id, entry) in kept {
                guard let held = entry["stamp"] as? String else { continue }
                let problems = (entry["problems"] as? [String] ?? []).compactMap { line -> (ExtensionError.Problem, String?)? in
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2, ExtensionError.isAPIPath(parts[1]),
                          let kind = ["missing": ExtensionError.Kind.missing, "notAFunction": .notAFunction, "wrongArguments": .wrongArguments][parts[0]]
                    else { return nil }
                    return (ExtensionError.Problem(kind: kind, api: parts[1]), nil)
                }
                checked[id] = (held, ExtensionTrial.Checked(testPage: Self.probe(entry["testPage"] as? String), popup: Self.probe(entry["popup"] as? String),
                                                            optionsPage: Self.probe(entry["optionsPage"] as? String), problems: problems))
            }
        }
        let apply = { [weak self] (result: ExtensionTrial.Checked) in
            guard let self else { return }
            for space in self.contexts.keys where self.contexts[space]?[item.id] != nil {
                self.update(item.id, in: space) { Self.apply(result, to: &$0) }
            }
        }
        if let done = checked[item.id], done.version == stamp { return apply(done.result) }
        guard let manifest = manifests[item.id], checking[item.id] == nil else { return }
        checking[item.id] = item.version
        for space in contexts.keys where contexts[space]?[item.id] != nil {
            update(item.id, in: space) { seen in
                if manifest.popup != nil { seen.popup = .checking }
                if manifest.optionsPage != nil { seen.optionsPage = .checking }
                if !manifest.contentScripts.isEmpty { seen.testPage = .checking }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Read against this Mac's table, measured first on a new build.
            if Self.apiTable.table == nil { await measureTable() }
            let result = await ExtensionTrial.check(Self.prepared(item.id, item.version), id: item.id, manifest: manifest,
                                                    missing: lacking[item.id] ?? [], scheme: Self.scheme, shimApplication: Self.shimApplication,
                                                    letRulesRedirect: Self.letRulesRedirect, sites: Self.sites, fence: Self.fence)
            checking[item.id] = nil
            // Updated meanwhile: the version now on is tried instead; removed, nothing.
            guard let now = installed.first(where: { $0.id == item.id }) else { return }
            guard now.version == item.version else {
                if contexts.values.contains(where: { $0[item.id] != nil }) { checkCopy(of: now) }
                return
            }
            checked[item.id] = (stamp, result)
            var kept = UserDefaults.standard.dictionary(forKey: Self.checkedKey) ?? [:]
            kept[item.id] = ["stamp": stamp, "testPage": Self.probe(result.testPage), "popup": Self.probe(result.popup),
                             "optionsPage": Self.probe(result.optionsPage),
                             "problems": result.problems.map { "\($0.problem.kind) \($0.problem.api)" }] as [String: Any]
            UserDefaults.standard.set(kept, forKey: Self.checkedKey)
            for found in result.problems { note(found.problem, file: found.file, of: item) }
            apply(result)
        }
    }

    /// Whether an error is new to the records for "space/id"; at most 500
    /// remembered, which is past what the records keep.
    func recordOnce(_ key: String, _ text: String) -> Bool {
        guard recorded[key, default: []].count < 500 else { return false }
        return recorded[key, default: []].insert(Self.fingerprint(text)).inserted
    }

    private func forgetCheck(_ id: String) {
        checked[id] = nil
        var kept = UserDefaults.standard.dictionary(forKey: Self.checkedKey) ?? [:]
        kept[id] = nil
        UserDefaults.standard.set(kept, forKey: Self.checkedKey)
    }

    /// An error's fingerprint, to know it again without keeping its words.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    /// Starts the background, and gives it five seconds. WebKit doesn't
    /// always answer when a worker throws as it starts; its errors say so
    /// instead (code 6), and are watched apart from this.
    private func startBackground(of context: WKWebExtensionContext, _ item: Installed, in space: UUID, attempt: UUID? = nil) {
        let key = "\(space.uuidString)/\(item.id)"
        let attempt = attempt ?? workerRecovery[key, default: ExtensionWorkerRecovery()].beganAttempt(restarting: false)
        var answered = false
        context.loadBackgroundContent { [weak self, weak context] error in
            MainActor.assumeIsolated {
                answered = true
                guard let self, let context, self.contexts[space]?[item.id] === context,
                      self.workerRecovery[key]?.attempt == attempt else { return }
                self.update(item.id, in: space) { $0.start = error == nil ? .started : .failed }
                let action = self.workerRecovery[key, default: ExtensionWorkerRecovery()].finished(attempt, failed: error != nil)
                self.recover(action, context: context, item: item, in: space)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak context] in
            guard !answered, let self, let context, self.contexts[space]?[item.id] === context,
                  self.workerRecovery[key]?.attempt == attempt else { return }
            self.update(item.id, in: space) { if $0.start == .checking { $0.start = .timedOut } }
        }
    }

    private func recover(_ action: ExtensionWorkerRecovery.Action, context: WKWebExtensionContext, item: Installed, in space: UUID) {
        guard contexts[space]?[item.id] === context else { return }
        switch action {
        case .ignore: break
        case .incompatible:
            markIncompatible(item.id, version: item.version)
            // Its worker, not WebKit's verdict: the next launch clears it and
            // tries once more (forgetWorkersIfChanged), unless it has.
            var failed = UserDefaults.standard.dictionary(forKey: Self.workerFailedKey) as? [String: String] ?? [:]
            if failed[item.id] != checkStamp(item.version) + " retried" {
                failed[item.id] = checkStamp(item.version)
                UserDefaults.standard.set(failed, forKey: Self.workerFailedKey)
                Self.workersChanged()
            }
        case .restart:
            let key = "\(space.uuidString)/\(item.id)"
            let attempt = workerRecovery[key]?.attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak context] in
                guard let self, let context, self.contexts[space]?[item.id] === context,
                      self.workerRecovery[key]?.attempt == attempt else { return }
                // Cooldown, a removed context or a deferred restart is never
                // proof that the extension failed to restart.
                self.revive(item.id, in: space, because: "its worker failed to start")
            }
        }
    }

    private func watch(_ context: WKWebExtensionContext, _ item: Installed, in space: UUID) {
        let id = item.id
        watches[space, default: [:]][id] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main
        ) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context else { return }
                self.errorsChanged(context, id, in: space)
            }
        }
    }

    private func unwatch(_ id: String, in space: UUID) {
        if let token = watches[space]?.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
    }

    private func errorsChanged(_ context: WKWebExtensionContext, _ id: String, in space: UUID) {
        guard contexts[space]?[id] === context else { return }
        let missing = lacking[id] ?? []
        // WebKit records a worker that failed to start as an error, and
        // doesn't try again: the extension would be dead until someone
        // noticed. It is taken up afresh two seconds after. (Search)
        let failed = context.errors.contains {
            let error = $0 as NSError
            return error.domain == WKWebExtensionContext.errorDomain
                && error.code == WKWebExtensionContext.Error.Code.backgroundContentFailedToLoad.rawValue
        }
        let key = "\(space.uuidString)/\(id)"
        let item = installed.first { $0.id == id }
        let action = failed ? workerRecovery[key, default: ExtensionWorkerRecovery()].noticedHistoricalFailure() : .ignore
        if let item { recover(action, context: context, item: item, in: space) }
        update(id, in: space) { seen in
            for error in context.errors {
                let nsError = error as NSError
                if nsError.domain == WKWebExtensionContext.errorDomain,
                   nsError.code == WKWebExtensionContext.Error.Code.backgroundContentFailedToLoad.rawValue, action == .restart {
                    seen.start = .failed
                }
                if let problem = ExtensionError.problem(in: nsError.localizedDescription, missing: missing) {
                    seen.problems.insert(problem)
                    // Once each error into the records: the list is whole each time.
                    if let item, recordOnce(key, nsError.localizedDescription) {
                        #if DEBUG
                        Self.note("webkit error: \(problem.api)" + Self.words(nsError.localizedDescription))
                        #endif
                        note(problem, file: ExtensionError.place(in: nsError.localizedDescription)?.file, of: item)
                    }
                }
            }
        }
    }

    // MARK: The records

    private static var recordsFile: URL { folder.appendingPathComponent("records.json") }

    private func readRecords() {
        guard let data = try? Data(contentsOf: Self.recordsFile), let kept = try? JSONDecoder().decode(ExtensionRecords.self, from: data) else { return }
        records = kept
        pruneRecords()
    }

    /// Past 30 days, gone from the file too.
    private func pruneRecords() {
        let before = records
        records.prune()
        if records != before { saveRecords() }
    }

    private func saveRecords() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: Self.recordsFile, options: .atomic)
        } catch {
            NSLog("eGlu: couldn't save the extension records: \(error.localizedDescription)")
        }
    }

    /// A problem it ran into, kept: where in it and what, never the error's words.
    func note(_ problem: ExtensionError.Problem, file: String?, of item: Installed) {
        let place = file.flatMap { file in manifests[item.id].map { ExtensionRecords.place(of: file, in: $0) } } ?? "page"
        let now = Date()
        records.note(.init(id: item.id, version: item.version, eglu: Self.egluVersion, macOS: Self.macOSVersion,
                           shim: ExtensionPreparation.stamp(for: Scripts.extensionShim), place: place, api: problem.api,
                           kind: "\(problem.kind)", first: now, last: now))
        saveRecords()
    }

    static var egluVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?").\(info["CFBundleVersion"] as? String ?? "?")"
    }

    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    func records(of id: String) -> [ExtensionRecords.Record] {
        pruneRecords()
        return records.of(id)
    }

    func update(_ id: String, in space: UUID, _ change: (inout ExtensionEvidence) -> Void) {
        guard var seen = evidence[space]?[id] else { return }
        change(&seen)
        record(seen, id, in: space)
    }

    private func record(_ seen: ExtensionEvidence, _ id: String, in space: UUID) {
        evidence[space, default: [:]][id] = seen
        let verdict = ExtensionVerdict(seen)
        // News to read: something that doesn't work, or no longer starts, it
        // didn't have before.
        let bad: Set<ExtensionVerdict.Status> = [.someFeaturesDontWork, .couldntStart]
        if bad.contains(verdict.status), verdicts[space]?[id] != verdict, !saidLooksWrong(id) {
            unseen.insert("\(space.uuidString)/\(id)")
        }
        verdicts[space, default: [:]][id] = verdict
    }

    // MARK: New tab pages (Search's 92f7c3a)

    /// What you said to each extension that asked to show its page in new
    /// tabs (chrome_url_overrides.newtab): yes or no, by its id.
    static let newTabKey = "extensionNewTabPages"

    private var newTabAnswers: [String: Bool] {
        UserDefaults.standard.dictionary(forKey: Self.newTabKey) as? [String: Bool] ?? [:]
    }

    /// The extensions on in the space that ask to show their page in new
    /// tabs, in the order they were added.
    func newTabAskers(in space: UUID) -> [Installed] {
        on(in: space).filter { contexts[space]?[$0.id]?.overrideNewTabPageURL != nil }
    }

    /// Those that ask, in any space, for Settings › General.
    var newTabChoices: [Installed] {
        installed.filter { item in contexts.values.contains { $0[item.id]?.overrideNewTabPageURL != nil } }
    }

    /// The page new tabs show in the space: the one you said yes to, the
    /// one added last if more than one; nil for eGlu's own command bar.
    func newTabPage(in space: UUID) -> URL? {
        let answers = newTabAnswers
        guard let item = newTabAskers(in: space).last(where: { answers[$0.id] == true }) else { return nil }
        return contexts[space]?[item.id]?.overrideNewTabPageURL
    }

    /// Whether `url` is the new-tab page of an extension on in the space.
    func isNewTabPage(_ url: URL?, in space: UUID) -> Bool {
        guard let url else { return false }
        return contexts[space]?.values.contains { $0.overrideNewTabPageURL == url } ?? false
    }

    /// The extension new tabs show, nil for eGlu's own.
    var newTabPageID: String? {
        let answers = newTabAnswers
        return newTabChoices.last { answers[$0.id] == true }?.id
    }

    /// Settings › General › New tabs: one extension's page, or nil for
    /// eGlu's command bar. Every other one that asks is answered no, so
    /// none puts its page back by asking again.
    func setNewTabPage(_ id: String?) {
        var answers = newTabAnswers
        for item in newTabChoices { answers[item.id] = item.id == id }
        UserDefaults.standard.set(answers, forKey: Self.newTabKey)
        objectWillChange.send()
    }

    /// Chrome asks the first time an extension's page would take the new
    /// tab's place: an extension that did it quietly could be anything. So
    /// does eGlu, as ⌘T opens the command bar, about the last one added it
    /// hasn't asked about, naming the one that has new tabs now; yes shows
    /// its page in a new tab at once.
    func offerNewTabPage(in window: WindowModel) {
        let answers = newTabAnswers
        // Asked on a window you can see, or not at all: with none, the
        // question would read as no and be kept.
        guard window.window?.isVisible == true,
              let item = newTabAskers(in: window.spaceID).last(where: { answers[$0.id] == nil }),
              !askingNewTab.contains(item.id) else { return }
        askingNewTab.insert(item.id)
        let holder = newTabPageID.flatMap { id in installed.first { $0.id == id } }
        let alert = NSAlert()
        alert.messageText = String(localized: "Show \u{201C}\(item.name)\u{201D} in new tabs?")
        alert.informativeText = (holder.map { String(localized: "It asks to show its page in new tabs, which \u{201C}\($0.name)\u{201D} shows now.") }
            ?? String(localized: "It asks to show its page in new tabs, in place of the command bar.")) + " "
            + String(localized: "You can change this in Settings › General.")
        alert.addButton(withTitle: String(localized: "Keep It"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        Task {
            let yes = await present(alert, in: window) == .alertFirstButtonReturn
            askingNewTab.remove(item.id)
            if yes {
                setNewTabPage(item.id)
                if let url = newTabPage(in: window.spaceID) { window.openNewTabPage(url, replacing: true) }
            } else {
                var answers = newTabAnswers
                answers[item.id] = false
                UserDefaults.standard.set(answers, forKey: Self.newTabKey)
                objectWillChange.send()
            }
        }
    }

    /// The commands each extension on in the space offers, for the menu bar.
    func commands(in space: UUID) -> [(name: String, id: String, commands: [WKWebExtension.Command])] {
        on(in: space).compactMap { item in
            guard let context = contexts[space]?[item.id], !context.commands.isEmpty else { return nil }
            return (item.name, item.id, context.commands)
        }
    }

    func perform(_ command: WKWebExtension.Command, of id: String, in space: UUID) {
        contexts[space]?[id]?.performCommand(command)
    }

    /// One that can't run on this Mac: it couldn't start, or the tried list
    /// says it doesn't work. Shown as Incompatible, with no switch to turn
    /// it on; the same in every space, as it is the Mac's WebKit it can't
    /// run on.
    func isIncompatible(_ id: String) -> Bool {
        guard !saidLooksWrong(id), let item = installed.first(where: { $0.id == id }) else { return false }
        return (UserDefaults.standard.dictionary(forKey: Self.incompatibleKey) as? [String: String])?[id] == checkStamp(item.version)
    }

    private static let incompatibleKey = "extensionsIncompatible"

    /// Found unable to run here: its worker failed again after eGlu
    /// started it afresh, WebKit wouldn't load it, or the tried list says
    /// so. Kept for this version: it is unloaded wherever it is on, keeping
    /// what it stored, and isn't loaded again until an update or the
    /// person's This Looks Wrong. Its spaces stay as they were, since this
    /// Mac's failing is no reason to turn it off on another (iCloud).
    /// `version`: the one that failed; nothing is marked if another has
    /// taken its place since (an update that didn't load, the old one back).
    private func markIncompatible(_ id: String, version: String) {
        guard let item = installed.first(where: { $0.id == id }), item.version == version, !saidLooksWrong(id) else { return }
        var marked = UserDefaults.standard.dictionary(forKey: Self.incompatibleKey) as? [String: String] ?? [:]
        let stamp = checkStamp(item.version)
        guard marked[id] != stamp else { return }
        marked[id] = stamp
        UserDefaults.standard.set(marked, forKey: Self.incompatibleKey)
        if let verdict = verdicts.values.lazy.compactMap({ $0[id] }).first { incompatibilities[id] = ([verdict.title + "."] + verdict.lines).joined(separator: " ") }
        for space in item.spaces { unload(id, in: space) }
    }

    /// What was found when it was marked, for the triangle's help.
    private var incompatibilities: [String: String] = [:]

    /// What its row warns of in a space: nothing while it works, and
    /// nothing once the person said the warnings look wrong, for this version.
    func warning(_ id: String, in space: UUID) -> ExtensionVerdict? {
        guard !saidLooksWrong(id), let verdict = verdicts[space]?[id],
              [.someFeaturesDontWork, .couldntStart].contains(verdict.status) else { return nil }
        return verdict
    }

    /// Whether it has a warning or can't run here, which the person may say looks wrong.
    func isWarned(_ id: String) -> Bool {
        isIncompatible(id) || verdicts.keys.contains { warning(id, in: $0) != nil }
    }

    /// The person said its warnings look wrong (This Looks Wrong), for
    /// the version it is now; an update brings them back.
    func saidLooksWrong(_ id: String) -> Bool {
        guard let item = installed.first(where: { $0.id == id }) else { return false }
        return item.looksWrong == item.version
    }

    func setLooksWrong(_ id: String, _ wrong: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].looksWrong = wrong ? installed[index].version : nil
        saveList()
        if wrong { unseen = unseen.filter { !$0.hasSuffix("/\(id)") } }
        // Tried again where it is on, or put away again.
        let item = installed[index]
        for space in item.spaces where Session.shared.workspace.space(space) != nil {
            if isIncompatible(id) { unload(id, in: space) } else if contexts[space]?[id] == nil { Task { await load(item, in: space) } }
        }
    }

    /// What was found, for the warning's help: the verdict's words.
    func incompatibility(_ id: String) -> String {
        (incompatibilities[id] ?? String(localized: "It could not start after eGlu retried it.")) + " " + String(localized: "Check for an update, try this version again, or report the problem. Its saved data is retained.")
    }

    /// The puzzle button's list was opened in a space: nothing new there now.
    func seen(in space: UUID) {
        unseen = unseen.filter { !$0.hasPrefix(space.uuidString) }
    }

    // MARK: What the bars show

    /// The extension's button, for the tab on screen in the window.
    func unavailableReason(_ id: String, in window: WindowModel) -> String? {
        if isIncompatible(id) { return String(localized: "Incompatible with eGlu on this Mac. Open its settings to retry or check for an update.") }
        if context(id, in: window.spaceID) == nil { return String(localized: "Not ready in this space. Open its settings to turn it on or retry.") }
        if action(for: id, in: window)?.isEnabled == false { return String(localized: "The extension turned off its action on this page. Its options are still available.") }
        return nil
    }

    func accessDescriptions(_ id: String) -> [String] {
        ExtensionAccessDescription.lines(for: installed.first { $0.id == id }?.granted ?? [])
    }

    func action(for id: String, in window: WindowModel) -> WKWebExtension.Action? {
        guard let context = contexts[window.spaceID]?[id] else { return nil }
        return context.action(for: window.tabID.map { tabs.tab($0, in: window.spaceID) })
    }

    /// Its icon wherever it is loaded, or from its package when it is on
    /// in no space: for Settings, which lists every one.
    func icon(of id: String) -> NSImage? {
        if let icon = icons[id] { return icon }
        guard !iconless.contains(id), let item = installed.first(where: { $0.id == id }) else { return nil }
        let loaded = contexts.values.lazy.compactMap { $0[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)) }.first
        let icon = loaded ?? (try? Data(contentsOf: Self.package(item.id, item.version))).flatMap { archive in
            ZipFile.file(in: archive, matching: { $0 == "manifest.json" })
                .flatMap { try? ExtensionManifest(json: $0) }
                .flatMap { Self.icon(in: archive, manifest: $0) }
        }
        if let icon { icons[id] = icon } else { iconless.insert(id) }
        return icon
    }

    func icon(of id: String, in space: UUID) -> NSImage? {
        if let icon = icons[id] { return icon }
        guard let icon = contexts[space]?[id]?.webExtension.icon(for: CGSize(width: 32, height: 32)) else { return nil }
        icons[id] = icon
        return icon
    }

    /// Moved to where another is in the list, as the person drags it.
    func move(_ id: String, to target: String) {
        guard let from = installed.firstIndex(where: { $0.id == id }), let to = installed.firstIndex(where: { $0.id == target }),
              from != to else { return }
        installed.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        saveList()
    }

    /// Where Settings' list was dragged to.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        installed.move(fromOffsets: offsets, toOffset: destination)
        saveList()
    }

    /// One place up or down (the list's Move Up and Move Down, for VoiceOver).
    func move(_ id: String, by step: Int) {
        guard let from = installed.firstIndex(where: { $0.id == id }), installed.indices.contains(from + step) else { return }
        move(id, to: installed[from + step].id)
    }

    func openOptions(_ id: String, in window: WindowModel) {
        guard let context = contexts[window.spaceID]?[id], let url = context.optionsPageURL else { return }
        _ = tabs.open(url, in: window.spaceID, active: true, pinned: false, context: context)
    }

    /// What it may read: every site it asks for, or the page it is clicked
    /// on, each time. Changed in every space it is loaded in at once.
    func setSiteAccess(_ id: String, _ access: Installed.SiteAccess) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].siteAccess != access else { return }
        installed[index].siteAccess = access
        saveList()
        for (_, loaded) in contexts {
            guard let context = loaded[id] else { continue }
            // Given: the sites that count (sites(of:)). Taken back to
            // asking, the one status besides granted and denied WebKit lets
            // an app set: every one it names.
            if access == .allSites {
                for pattern in Self.sites(of: context.webExtension) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            } else {
                for pattern in context.webExtension.allRequestedMatchPatterns where !Self.withheld(pattern) {
                    context.setPermissionStatus(.unknown, for: pattern)
                }
            }
            // When I Click It takes back the *://*/* that stands for a grant
            // of <all_urls> (fence) too, or it would keep every site.
            if access != .allSites, let web = try? WKWebExtension.MatchPattern(string: "*://*/*") {
                context.setPermissionStatus(.unknown, for: web)
            }
            // Google's sign-in, extension pages and files stay denied
            // whatever was chosen.
            Self.fence(context)
        }
    }

    /// The popup an extension's button opens: the one it set, or its manifest's.
    func popupURL(for context: WKWebExtensionContext, in space: UUID) -> URL? {
        let key = "\(space.uuidString)/\(context.uniqueIdentifier)"
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        let path = popupPaths[key] ?? action?["default_popup"] as? String
        guard let path, !path.isEmpty else { return nil }
        // Relative to the extension, keeping a query it may carry.
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    // MARK: Installing

    enum Refused: LocalizedError {
        case download(Int)
        case nothing
        case notAPackage
        case noManifest
        case badVersion
        case notChecked(String)

        var errorDescription: String? {
            switch self {
            case .download(let code): return String(localized: "The Chrome Web Store answered \(code).")
            case .nothing: return String(localized: "The Chrome Web Store has nothing for that extension. It may have been taken down.")
            case .notAPackage: return String(localized: "That isn't a Chrome extension.")
            case .noManifest: return String(localized: "The extension has no manifest.json.")
            case .badVersion: return String(localized: "The extension's version isn't one Chrome would take.")
            case .notChecked(let reason): return reason
            }
        }
    }

    /// The extension a Chrome Web Store page is about, fetched from the store,
    /// checked, and offered to the person.
    /// `space`: where the click was, kept from the moment it was made.
    func add(fromStorePage url: URL, in window: WindowModel?, space: UUID? = nil) {
        guard let id = ExtensionStore.id(ofPage: url) else { return }
        add(storeID: id, in: window, space: space)
    }

    /// From the Chrome Web Store by its id: downloaded, Google's signature
    /// checked, and offered in this Mac's own sheet, which starts from
    /// `access` (another Mac's choice, for one it has).
    func add(storeID id: String, in window: WindowModel?, space: UUID? = nil, access: Installed.SiteAccess = .allSites) {
        guard ExtensionID.isValid(id), busy == nil else { return }
        busy = id
        let space = space ?? window?.spaceID
        Task {
            defer { busy = nil }
            do {
                let crx = try await download(id)
                // Its signature checked over every byte: off the main thread.
                let archive = try await Task.detached(priority: .userInitiated) { try CRXFile.archive(of: crx, id: id, fromStore: true) }.value
                try await offer(archive, id: id, source: .store, in: window, space: space, startingAccess: access)
            } catch {
                tell(error, in: window)
            }
        }
    }

    /// A CRX or ZIP the person chose: Install from File.
    func addFromFile(in window: WindowModel?, host: NSWindow? = nil) {
        let host = host ?? window?.window ?? NSApp.keyWindow
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "crx") ?? .data, .zip]
        panel.message = String(localized: "Choose a Chrome extension: a .crx file, or a .zip with its manifest.json.")
        Task {
            guard await choose(panel, host: host) == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                if CRXFile.isCRX(data) {
                    let header = try CRXFile.header(of: data)
                    guard let id = header.declaredID else { throw CRXFile.Refusal.noDeveloperKey }
                    try await offer(try CRXFile.archive(of: data, id: id, fromStore: false), id: id, source: .file, in: window, host: host)
                } else if ZipFile.isArchive(data) {
                    // No key to make an id from: a random one, which can't
                    // be any store extension's.
                    let id = ExtensionID.letters((0..<16).map { _ in UInt8.random(in: 0...255) })
                    try await offer(data, id: id, source: .unsigned, in: window, host: host)
                } else {
                    throw Refused.notAPackage
                }
            } catch {
                tell(error, in: window, host: host)
            }
        }
    }

    /// `from`: an update reply's address, used only when it is Google's own.
    func download(_ id: String, from address: URL? = nil) async throws -> Data {
        let url = address.flatMap { $0.scheme == "https" && (ExtensionStore.isPackageHost($0) || $0.host() == "clients2.google.com") ? $0 : nil }
        var request = URLRequest(url: url ?? ExtensionStore.packageURL(for: id))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else { throw Refused.download(http.statusCode) }
            guard let final = http.url, ExtensionStore.isPackageHost(final) || final.host() == "clients2.google.com" else {
                throw Refused.notAPackage
            }
        }
        guard !data.isEmpty else { throw Refused.nothing }
        return data
    }

    /// The install sheet: what it is, what it asks for, where it goes and
    /// what it may read; then the files kept and the extension loaded.
    func offer(_ archive: Data, id: String, source: Installed.Source, in window: WindowModel?, asking: Bool = true,
                       folder: String? = nil, space: UUID? = nil, startingAccess: Installed.SiteAccess = .allSites,
                       host: NSWindow? = nil) async throws {
        guard let manifestData = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }) else { throw Refused.noManifest }
        let manifest = try ExtensionManifest(json: manifestData)
        // Both name files: only what Chrome itself takes, 32 letters and a
        // version of numbers and dots, so neither can lead out of the folder.
        guard ExtensionID.isValid(id) else { throw Refused.notAPackage }
        guard let version = ExtensionVersion(manifest.version)?.description else { throw Refused.badVersion }
        if let there = installed.first(where: { $0.id == id }) {
            // A store extension's place is the store's, with Google's proof:
            // a file signed by its developer's key could be an older one, or
            // one never published.
            if there.source == .store, source != .store {
                throw Refused.notChecked(String(localized: "\u{201C}\(there.name)\u{201D} is from the Chrome Web Store; it can only be updated from there."))
            }
            if source != .unpacked, let had = ExtensionVersion(there.version), let new = ExtensionVersion(version), new < had {
                throw Refused.notChecked(String(localized: "\u{201C}\(there.name)\u{201D} \(there.version) is installed; this is an older version, \(version)."))
            }
        }
        let name = manifest.displayName(in: archive, fallback: id)
        let space = space ?? window?.spaceID ?? Session.shared.workspace.spaces[0].id
        guard asking else {
            try keep(archive, id: id, name: name, version: version, source: source, access: .allSites, spaces: [space],
                     granted: manifest.grants, folder: folder)
            return
        }
        let summary = ExtensionAccessSummary(permissions: manifest.permissions,
                                             sites: manifest.hostPermissions + manifest.contentScripts.flatMap(\.matches))
        let image = Self.icon(in: archive, manifest: manifest)
        let choice: ExtensionInstallSheet.Choice? = await ask(in: window, host: host) { answer in
            ExtensionInstallSheet(name: name, image: image, source: source, summary: summary,
                                  spaces: Session.shared.workspace.spaces, access: startingAccess, in: space, answer: answer)
        }
        guard let choice else { return }
        let spaces = choice.spaces.filter { Session.shared.workspace.space($0) != nil }
        guard !spaces.isEmpty else { throw Refused.notChecked(String(localized: "The selected space was removed. Choose a space and add the extension again.")) }
        try keep(archive, id: id, name: name, version: version, source: source, access: choice.access, spaces: spaces,
                 granted: manifest.grants, folder: folder)
    }

    /// The files kept, the extension listed and loaded where it goes.
    @discardableResult
    func keep(_ archive: Data, id: String, name: String, version: String, source: Installed.Source,
                      access: Installed.SiteAccess, spaces: [UUID], granted: [String]?, folder: String? = nil) throws -> Task<Bool, Never> {
        // A new package, even at the same version (Reload): its code read
        // and pages tried afresh, and its worker too at the next launch.
        forgetCheck(id)
        scanned[id] = nil
        scanning[id] = nil
        // And its icon read again, which a new version may have changed.
        icons[id] = nil
        iconless.remove(id)
        Self.workersChanged()
        let file = Self.package(id, version)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: file, options: .atomic)
        let manifest = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }).flatMap { try? ExtensionManifest(json: $0) }
        let resolvedName = manifest?.displayName(in: archive, fallback: name) ?? name
        note(manifest, of: id)
        // Its cookies, as the person chose them for the version there was.
        let item = Installed(id: id, name: resolvedName, version: version, source: source, siteAccess: access, spaces: spaces,
                             granted: granted, folder: folder, readsCookies: installed.first { $0.id == id }?.readsCookies)
        // A newer version of one already here: the same id, so the same
        // developer's key. An unsigned one has a random id of its own and
        // never takes another's place.
        if let old = installed.firstIndex(where: { $0.id == id }) {
            let previous = installed[old]
            for space in previous.spaces { unload(id, in: space) }
            installed[old] = item
            saveList()
            return Task {
                var loaded = spaces.isEmpty
                for space in spaces where await load(item, in: space) { loaded = true }
                guard installed.first(where: { $0.id == id }) == item else { return false }
                if loaded || previous.version == version {
                    removeOtherVersions(of: id, keeping: version)
                    return loaded
                } else if let index = installed.firstIndex(where: { $0.id == id }) {
                    // Loaded nowhere: the version there was, back as it was.
                    NSLog("eGlu: extension \(id) \(version) didn't load; \(previous.version) is back")
                    installed[index] = previous
                    saveList()
                    for space in previous.spaces { await load(previous, in: space) }
                    removeOtherVersions(of: id, keeping: previous.version)
                }
                return false
            }
        }
        installed.append(item)
        saveList()
        // One the list between Macs has: on in the spaces it is on in there too.
        if source == .store { Sync.shared.adopt(id) }
        return Task {
            // The sheet's spaces; those adopted from the list load as they are turned on.
            for space in spaces { await load(item, in: space) }
            // The list opens by itself where it was added, with its check.
            if let space = spaces.first { justInstalled = JustInstalled(id: id, space: space) }
            return spaces.isEmpty || spaces.contains { contexts[$0]?[id] != nil }
        }
    }

    /// A version's package and folder kept, every other gone: not a folder
    /// being made (its name starts with a dot), which goes when it is done.
    private func removeOtherVersions(of id: String, keeping version: String) {
        let here = Self.folder.appendingPathComponent(id, isDirectory: true)
        let kept = ["\(version).zip", version, "_eglu"]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: here.path)) ?? []
        where !kept.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: here.appendingPathComponent(name))
        }
    }

    /// A question as a sheet on the window. Never as a modal run of its
    /// own: that spins a run loop inside a task, which Swift's main-actor
    /// checks don't survive. With no window to put it on, the answer is no.
    func present(_ alert: NSAlert, in window: WindowModel?, host owner: NSWindow? = nil) async -> NSApplication.ModalResponse {
        guard let host = owner ?? window?.window ?? NSApp.keyWindow ?? Session.shared.frontWindow?.window,
              host.isVisible else {
            return .alertSecondButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: host) { continuation.resume(returning: $0) }
        }
    }

    func choose(_ panel: NSOpenPanel, host: NSWindow?) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            if let host {
                panel.beginSheetModal(for: host) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
    }

    func tell(_ error: Error, in window: WindowModel?, host owner: NSWindow? = nil,
              title: String = String(localized: "The extension could not be added.")) {
        let reason = (error as? CRXFile.Refusal)?.reason ?? error.localizedDescription
        guard let host = owner ?? window?.window ?? NSApp.keyWindow ?? Session.shared.frontWindow?.window else {
            NSLog("eGlu: an extension couldn't be added: \(reason)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = reason
        alert.beginSheetModal(for: host)
    }

    // MARK: Turning off, removing

    func turn(_ id: String, on: Bool, in space: UUID) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        if on {
            // One that can't run here isn't turned on anywhere else either.
            guard !isIncompatible(id) else { return }
            guard !installed[index].spaces.contains(space) else { return }
            installed[index].spaces.append(space)
            saveList()
            let item = installed[index]
            Task { await load(item, in: space) }
        } else {
            installed[index].spaces.removeAll { $0 == space }
            saveList()
            unload(id, in: space)
        }
    }

    /// Off in a space, and its data there deleted, unlike turning it off.
    /// It stays installed, on in no space if this was its last.
    func remove(_ id: String, from space: UUID) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].spaces.removeAll { $0 == space }
        saveList()
        unload(id, in: space)
        closePages(of: id, in: space)
        forget(id, in: space)
    }

    /// Asked first, as Chrome asks: it takes what it kept in every space.
    func confirmRemoval(of id: String, from space: UUID? = nil, in window: WindowModel?, host: NSWindow? = nil) {
        guard let item = installed.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        let scope = space.flatMap { Session.shared.workspace.space($0)?.name }
        alert.messageText = String(localized: "Remove \u{201C}\(item.name)\u{201D} from \(scope ?? "eGlu")?")
        alert.informativeText = space == nil
            ? String(localized: "Deletes this extension and its settings, sign-ins, and saved data from every space on this Mac. This cannot be undone.")
            : String(localized: "Deletes this extension's settings, sign-ins, and saved data in \(scope ?? String(localized: "this space")) on this Mac. Other spaces keep their data. This cannot be undone. Turn Off keeps its data instead.")
        if item.source == .store {
            alert.informativeText += " " + (space == nil
                ? String(localized: "If extension sync is enabled, removal also applies on your other Macs.")
                : String(localized: "If extension sync is enabled, it also turns off in this space on your other Macs; their extension data is retained."))
        }
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        Task {
            if await present(alert, in: window, host: host) == .alertFirstButtonReturn {
                if let space { remove(id, from: space) } else { remove(id) }
            }
        }
    }

    /// Gone from every space, its data with it, then its files. Every
    /// space's: one it was turned off in kept its data, for when it is
    /// turned on again.
    func remove(_ id: String) {
        guard installed.contains(where: { $0.id == id }) else { return }
        setNativeConsent(id, false)
        var declined = UserDefaults.standard.dictionary(forKey: "extensionDeclinedUpdates") as? [String: String] ?? [:]
        declined[id] = nil
        UserDefaults.standard.set(declined, forKey: "extensionDeclinedUpdates")
        let spaces = Session.shared.workspace.spaces.map(\.id)
        for space in spaces { unload(id, in: space) }
        installed.removeAll { $0.id == id }
        saveList()
        records.forget(id)
        saveRecords()
        forgetCheck(id)
        recorded = recorded.filter { !$0.key.hasSuffix("/\(id)") }
        // What it set for its button and its side panel goes too: installed
        // again, it starts from its manifest.
        popupPaths = popupPaths.filter { !$0.key.hasSuffix("/\(id)") }
        ExtensionSidePanels.shared.forget(id)
        ExtensionKeys.shared.forget(id)
        ExtensionCapture.forget(id)
        // Its answer about new tabs too: installed again, it is asked again.
        var answers = newTabAnswers
        answers[id] = nil
        UserDefaults.standard.set(answers, forKey: Self.newTabKey)
        var marked = UserDefaults.standard.dictionary(forKey: Self.incompatibleKey) ?? [:]
        marked[id] = nil
        UserDefaults.standard.set(marked, forKey: Self.incompatibleKey)
        let clearing = spaces.map { forget(id, in: $0) }
        Task {
            for task in clearing { await task.value }
            // Unless it was installed again meanwhile.
            guard !installed.contains(where: { $0.id == id }) else { return }
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(id, isDirectory: true))
        }
    }

    // MARK: Forgetting what it kept

    /// What a removal is still clearing, by space and extension ("space/id"),
    /// kept until it is done: a quit or a crash in the middle would leave it
    /// for the next extension of the same id in that space. (Search)
    private static let forgettingKey = "extensionsForgetting"
    private var forgetting: [String: Task<Void, Never>] = [:]

    /// Its storage, which WebKit keeps by id, and what its pages kept at
    /// chrome-extension://<id> (localStorage, IndexedDB, caches), which
    /// removeData doesn't reach: cleared from a blank page at that address,
    /// in a stand-in with no worker, scripts or pages of its own, so nothing
    /// of the removed extension runs again. (Search's forgetData)
    @discardableResult
    private func forget(_ id: String, in space: UUID) -> Task<Void, Never> {
        let key = "\(space.uuidString)/\(id)"
        if let running = forgetting[key] { return running }
        var left = UserDefaults.standard.stringArray(forKey: Self.forgettingKey) ?? []
        if !left.contains(key) { left.append(key) }
        UserDefaults.standard.set(left, forKey: Self.forgettingKey)
        let task = Task { [weak self] in
            guard let self else { return }
            let done = await self.clear(id, in: space)
            self.forgetting[key] = nil
            if done {
                let rest = (UserDefaults.standard.stringArray(forKey: Self.forgettingKey) ?? []).filter { $0 != key }
                UserDefaults.standard.set(rest, forKey: Self.forgettingKey)
            }
        }
        forgetting[key] = task
        return task
    }

    /// At launch, before anything loads: what a removal didn't finish.
    private func forgetLeftOver() {
        for key in UserDefaults.standard.stringArray(forKey: Self.forgettingKey) ?? [] {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let space = UUID(uuidString: parts[0]), ExtensionID.isValid(parts[1]) else { continue }
            guard Session.shared.workspace.space(space) != nil else {
                // The space is gone, and its store with it.
                let rest = (UserDefaults.standard.stringArray(forKey: Self.forgettingKey) ?? []).filter { $0 != key }
                UserDefaults.standard.set(rest, forKey: Self.forgettingKey)
                continue
            }
            forget(parts[1], in: space)
        }
    }

    /// Waits for what a removal of this extension in this space is clearing:
    /// the same id loaded again starts with nothing of the one before.
    /// Whether nothing is left to clear: a clearing that failed is tried
    /// again first, and one that fails again keeps the extension out.
    @discardableResult
    func cleared(_ id: String, in space: UUID) async -> Bool {
        let key = "\(space.uuidString)/\(id)"
        let pending = { (UserDefaults.standard.stringArray(forKey: Self.forgettingKey) ?? []).contains(key) }
        if let running = forgetting[key] { await running.value }
        if pending() { await forget(id, in: space).value }
        return !pending()
    }

    private func clear(_ id: String, in space: UUID) async -> Bool {
        for name in ["userscripts", "worlds"] { try? FileManager.default.removeItem(at: Self.kept(name, of: id, in: space)) }
        guard Session.shared.workspace.space(space) != nil else { return true }
        // Its pages there closed first: an open one holds its databases.
        closePages(of: id, in: space)
        let controller = controller(for: space)
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
        if !records.isEmpty {
            await controller.removeData(ofTypes: types, from: records)
            // WebKit says what it couldn't delete on the records themselves.
            // Not session storage: it is in memory, gone with the unloaded
            // context, and WebKit says it can't reach it then (code 3).
            let failures = records.flatMap(\.errors).filter {
                let error = $0 as NSError
                return !(error.domain == WKWebExtension.DataRecord.errorDomain
                    && error.code == WKWebExtension.DataRecord.Error.Code.sessionStorageFailed.rawValue)
            }
            if !failures.isEmpty {
                #if DEBUG
                Self.note("clear: record errors \(records.flatMap(\.errors).map(\.localizedDescription))")
                #endif
                return false
            }
        }
        guard contexts[space]?[id] == nil, let base = URL(string: "\(Self.scheme)://\(id)/") else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-forget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"manifest_version": 3, "name": "eGlu", "version": "1"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
            let standIn = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
            standIn.uniqueIdentifier = id
            standIn.baseURL = base
            // Turned on again meanwhile: it is its own, not a stand-in's.
            guard contexts[space]?[id] == nil else { return false }
            try controller.load(standIn)
            defer { try? controller.unload(standIn) }
            guard let configuration = standIn.webViewConfiguration else { return false }
            let done = try await ExtensionBlankPage(configuration, scheme: Self.scheme).clear(at: base)
            #if DEBUG
            Self.note("clear: blank page \(done)")
            #endif
            return done
        } catch {
            #if DEBUG
            Self.note("clear: failed \(error)")
            #endif
            NSLog("eGlu: couldn't clear what extension \(id) kept: \(error.localizedDescription)")
            return false
        }
    }


    /// Whether a website at `source` may send its tab to `url`, a page of
    /// an extension loaded in `space` (ExtensionPolicy.webAccessible).
    func webAccessible(_ url: URL, from source: URL, in space: UUID, fromRule: Bool = false) -> Bool {
        guard isExtensionPage(url), let id = url.host(), let context = contexts[space]?[id] else { return false }
        // WebKit doesn't say whose rule it was: only an extension that can
        // make rules gets what its own rule would, so another's rule naming
        // its page gets no more than a site's link.
        let own = fromRule && ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"].contains { Self.asks(context, for: $0) }
        return ExtensionPolicy.webAccessible(url, from: source, manifest: context.webExtension.manifest, scheme: Self.scheme, fromRule: own)
    }

    /// The websites each extension on in the space lists under
    /// externally_connectable, as Chrome would take them, by its id.
    func externalListings(in space: UUID) -> [String: [String]] {
        (contexts[space] ?? [:]).compactMapValues { context in
            let listed = ExtensionExternal.listed(in: context.webExtension.manifest)
            return listed.isEmpty ? nil : listed
        }
    }

    /// The configuration an extension's own page needs, in a space where
    /// the extension is loaded.
    func configuration(for url: URL, in space: UUID) -> WKWebViewConfiguration? {
        guard isExtensionPage(url), let id = url.host() else { return nil }
        return contexts[space]?[id]?.webViewConfiguration
    }

    /// A space going: its extensions unload and their data goes, and its
    /// controller is let go before its website store is erased, which
    /// WebKit won't do while anything holds the store.
    func removeSpace(_ space: UUID) {
        for id in Array((contexts[space] ?? [:]).keys) { unload(id, in: space) }
        ExtensionOffscreen.closeAll(in: space)
        ExtensionSocket.close(in: space)
        ExtensionPopups.shared.closeAll(in: space)
        ExtensionSidePanels.shared.closeAll(in: space)
        watches[space] = nil
        // What eGlu kept for each extension in the space (user scripts,
        // their worlds) goes with it.
        for item in installed where item.spaces.contains(space) {
            for name in ["userscripts", "worlds"] { try? FileManager.default.removeItem(at: Self.kept(name, of: item.id, in: space)) }
        }
        for index in installed.indices { installed[index].spaces.removeAll { $0 == space } }
        saveList()
        let controller = controllers.removeValue(forKey: space)
        contexts[space] = nil
        verdicts[space] = nil
        evidence[space] = nil
        // Its extensions' storage, which WebKit keeps apart from the space's
        // website store: deleted through the controller before it is let
        // go, and the store swept again after, which waits for that.
        guard let controller else { return }
        Task {
            let types = WKWebExtensionController.allExtensionDataTypes
            let records = await controller.dataRecords(ofTypes: types)
            if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
            withExtendedLifetime(controller) {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Stores.sweep(in: WebKitSpaceStores.shared) }
        }
    }

    /// An extension's own pages in a space put away: its tabs there, its
    /// popup and its offscreen page.
    private func closePages(of id: String, in space: UUID) {
        let session = Session.shared
        for tab in session.workspace.space(space)?.tabs ?? [] {
            guard let url = session.pages.live[tab.id]?.view.url ?? tab.url, url.scheme == Self.scheme, url.host() == id else { continue }
            session.change { _ = $0.closeTab(tab.id) }
            session.pages.close(tab.id)
        }
        ExtensionPopups.shared.closeAll(of: id, in: space)
        ExtensionOffscreen.close(id, in: space)
    }

    /// The name the shim sends its native messages to.
    static let shimApplication = "eglu"

    // MARK: Running one

    /// What a click on the extension's button does: its popup, or its own
    /// handler; never a grant of the page on a hands-off one.
    func run(_ id: String, in window: WindowModel) {
        guard let context = contexts[window.spaceID]?[id] else { return }
        // A press on the button of a popup that is up closes it, as in Chrome.
        if ExtensionPopups.shared.isUp(id, in: window) {
            ExtensionPopups.shared.close(in: window)
            return
        }
        let tab = window.tabID.map { tabs.tab($0, in: window.spaceID) }
        Self.pressed["\(window.spaceID.uuidString)/\(id)"] = Date()
        // One that asked for its side panel to open on its button's press:
        // the press grants it the page as performAction would (activeTab),
        // never a hands-off one.
        if ExtensionSidePanels.shared.opensOnAction(id, in: window.spaceID) {
            if let tab, ExtensionPolicy.grantsOnClick(window.page?.view.url) { context.userGesturePerformed(in: tab) }
            ExtensionSidePanels.shared.toggle(id, in: window)
            return
        }
        context.performAction(for: tab)
    }
}

#if DEBUG
// MARK: Checking from the command line

extension Extensions {
    /// An error's own words for the steps file, only when the run asks for
    /// them (-extensionReportWords YES): they may hold what a page or an
    /// account said, which the records never keep.
    static func words(_ text: String?) -> String {
        guard UserDefaults.standard.bool(forKey: "extensionReportWords"), let text else { return "" }
        return ": " + text.prefix(240)
    }

    /// A line in the check's steps file, beside its report.
    static func note(_ line: String) {
        guard let out = UserDefaults.standard.string(forKey: "extensionReport") else { return }
        let text = ((try? String(contentsOfFile: out + ".steps", encoding: .utf8)) ?? "") + line + "\n"
        try? text.write(toFile: out + ".steps", atomically: true, encoding: .utf8)
    }

    /// For checking an extension without a window's sheet:
    /// `eGlu --args -installExtension x.zip -extensionPages https://a/,https://b/ -extensionSpaces 2 -extensionReport out.txt`
    /// (and `-extensionID <id>` for a zip that should have one)
    /// makes as many spaces as asked, installs the extension in every one,
    /// opens each page in each space, and after 15 seconds writes what was
    /// seen: each extension's verdict and errors, and each page's title.
    fileprivate func checkFromTheCommandLine() {
        let defaults = UserDefaults.standard
        // A file or a folder (as Load Unpacked); or, with -installFromStore, a store id.
        let path = defaults.string(forKey: "installExtension")
        let storeID = defaults.string(forKey: "installFromStore")
        guard path != nil || storeID != nil else { return }
        let note = Extensions.note
        note("hook")
        Task {
            note("task")
            try? await Task.sleep(for: .seconds(3))
            let session = Session.shared
            let wanted = max(1, defaults.integer(forKey: "extensionSpaces"))
            while session.workspace.spaces.count < wanted {
                session.change { _ = $0.addSpace(named: "Test \($0.spaces.count + 1)") }
            }
            let spaces = session.workspace.spaces.prefix(wanted).map(\.id)
            note("installing in \(spaces.count)")
            do {
                var folder: String?
                let data: Data
                if let storeID {
                    data = try await download(storeID)
                } else if let path, (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    folder = URL(fileURLWithPath: path).standardizedFileURL.path
                    data = try await Self.zipped(URL(fileURLWithPath: path, isDirectory: true))
                } else {
                    data = try Data(contentsOf: URL(fileURLWithPath: path ?? ""))
                }
                let (archive, id, source): (Data, String, Installed.Source)
                if let storeID {
                    (archive, id, source) = (try CRXFile.archive(of: data, id: storeID, fromStore: true), storeID, .store)
                } else if let folder {
                    (archive, id, source) = (data, ExtensionID.id(forUnpackedPath: folder), .unpacked)
                } else if CRXFile.isCRX(data) {
                    let declared = try CRXFile.header(of: data).declaredID ?? ""
                    (archive, id, source) = (try CRXFile.archive(of: data, id: declared, fromStore: false), declared, .file)
                } else {
                    // An archive under an id of its own (-extensionID), so a
                    // desktop app's host that names the store's id lets it in.
                    let named = defaults.string(forKey: "extensionID") ?? ExtensionID.letters([UInt8](repeating: 7, count: 16))
                    (archive, id, source) = (data, named, .unsigned)
                }
                guard let manifestData = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }),
                      let manifest = try? ExtensionManifest(json: manifestData),
                      let version = ExtensionVersion(manifest.version)?.description
                else { throw Refused.noManifest }
                try keep(archive, id: id, name: manifest.name, version: version, source: source, access: .allSites, spaces: spaces,
                         granted: manifest.grants, folder: folder)
            } catch {
                note("refused: \(error)")
            }
            // More, as unpacked folders, for a picture of a fuller list (-extensionAlso a,b,c).
            for extra in (defaults.string(forKey: "extensionAlso") ?? "").split(separator: ",").map(String.init) {
                guard let data = try? await Self.zipped(URL(fileURLWithPath: extra, isDirectory: true)),
                      let manifestData = ZipFile.file(in: data, matching: { $0 == "manifest.json" }),
                      let manifest = try? ExtensionManifest(json: manifestData) else { continue }
                let folder = URL(fileURLWithPath: extra).standardizedFileURL.path
                _ = try? keep(data, id: ExtensionID.id(forUnpackedPath: folder), name: manifest.name, version: manifest.version,
                          source: .unpacked, access: .allSites, spaces: spaces, granted: manifest.grants, folder: folder)
            }
            note("installed")
            try? await Task.sleep(for: .seconds(4))
            var opened: [(space: UUID, tab: UUID)] = []
            let pages = (defaults.string(forKey: "extensionPages") ?? "").split(separator: ",").compactMap { URL(string: String($0)) }
            for space in spaces {
                for url in pages {
                    guard let tab = session.change({ $0.openTab(url, in: space) }), let record = session.workspace.tab(tab) else { continue }
                    _ = session.pages.page(for: record, in: space)
                    opened.append((space, tab))
                }
            }
            note("pages opened")
            // The interface tried: its popup opened in
            // the first space's window, whose number is noted for a capture
            // of that window alone.
            // ⌘T in the first space's window (-extensionNewTabTest YES).
            if defaults.bool(forKey: "extensionNewTabTest"), let first = spaces.first,
               let window = session.allWindows.first(where: { $0.spaceID == first }) {
                window.perform(.newTab)
                note("new tab")
            }
            if defaults.bool(forKey: "extensionOfferTest") {
                Sync.shared.offerForChecking([SyncExtension(id: "x", storeID: "eimadpbcbfnmbkopoojfekhnkhdbieeh", title: "Dark Reader", siteAccess: "allSites")])
            }
            if defaults.bool(forKey: "extensionUITest"), let id = installed.first?.id, let first = spaces.first,
               let window = session.allWindows.first(where: { $0.spaceID == first }) ?? session.frontWindow {
                try? await Task.sleep(for: .seconds(3))
                if let tab = opened.first(where: { $0.space == first })?.tab { window.select(tab) }
                try? await Task.sleep(for: .seconds(1))
                if defaults.bool(forKey: "extensionTabsOnTop") { session.preferences.tabsPlacement = .top }
                if defaults.bool(forKey: "extensionShowList") {
                    justInstalled = JustInstalled(id: id, space: first)
                } else {
                    run(id, in: window)
                }
                try? await Task.sleep(for: .seconds(2))
                note("window \(window.window?.windowNumber ?? 0)")
            }
            try? await Task.sleep(for: .seconds(max(11, defaults.integer(forKey: "extensionWait"))))
            note("reporting")
            guard let out = defaults.string(forKey: "extensionReport") else { return }
            var lines = await report(spaces, opened)
            if defaults.bool(forKey: "checkUpdatesNow") {
                lines.append("updates \(await checkForUpdates(now: true))")
            }
            // Cookies allowed, as its settings' switch allows them: it starts
            // again with them, and its pages are loaded again.
            if defaults.bool(forKey: "extensionCookiesTest"), let id = installed.first?.id {
                setReadsCookies(id, true)
                note("cookies allowed")
                try? await Task.sleep(for: .seconds(4))
                for page in opened { session.pages.live[page.tab]?.reload() }
                try? await Task.sleep(for: .seconds(max(11, defaults.integer(forKey: "extensionWait"))))
                lines += await report(spaces, opened).map { "cookies " + $0 }
            }
            // Removed from the first space, its data there cleared, and on
            // again: its pages there start afresh, the other space's don't.
            if defaults.bool(forKey: "extensionRemoveTest"), let id = installed.first?.id, let first = spaces.first {
                remove(id, from: first)
                await cleared(id, in: first)
                note("removed from space 1, cleared")
                turn(id, on: true, in: first)
                try? await Task.sleep(for: .seconds(4))
                for page in opened { session.pages.live[page.tab]?.reload() }
                try? await Task.sleep(for: .seconds(max(11, defaults.integer(forKey: "extensionWait"))))
                lines += await report(spaces, opened).map { "after " + $0 }
            }
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    private func report(_ spaces: [UUID], _ opened: [(space: UUID, tab: UUID)]) async -> [String] {
            let session = Session.shared
            var lines: [String] = []
            for item in installed {
                lines.append("installed \(item.name) incompatible=\(isIncompatible(item.id)) on in \(item.spaces.count)")
            }
            // This Mac's table, once measured: its namespaces, WebKit's own.
            if let table = Self.apiTable.table {
                let namespaces = table.answers.filter { !$0.key.contains(".") && $0.value == .native }.keys.sorted()
                lines.append("table \(namespaces.count): \(namespaces.joined(separator: " "))")
                lines.append("table tabs: \(table.answers.keys.filter { $0.hasPrefix("tabs.") }.count) members")
            }
            for (number, space) in spaces.enumerated() {
                for item in installed where item.spaces.contains(space) {
                    let context = contexts[space]?[item.id]
                    lines.append("space \(number + 1) extension \(item.name) loaded=\(context?.isLoaded ?? false)")
                    if let verdict = verdicts[space]?[item.id] {
                        lines.append("space \(number + 1) verdict \(verdict.title)")
                        lines += verdict.lines.map { "space \(number + 1) line \($0)" }
                    }
                    lines += (context?.errors ?? []).map { "space \(number + 1) error \(($0 as NSError).code) \($0.localizedDescription)" }
                    lines.append("space \(number + 1) cookies \(context?.permissionStatus(for: .cookies).rawValue ?? 99)")
                    lines.append("space \(number + 1) permissions " + (context?.grantedPermissions.keys.map(\.rawValue).sorted() ?? []).joined(separator: " "))
                    lines += (context?.commands ?? []).map { "space \(number + 1) command \($0.id) key \($0.activationKey ?? "-") \($0.modifierFlags.rawValue)" }
                    // What it may reach, as WebKit answers for one address
                    // of each kind (a status's raw value: granted 2 or 3,
                    // unknown 0, denied -2 or -3).
                    let other = installed.first { $0.id != item.id }?.id ?? "abcdefghijklmnopabcdefghijklmnop"
                    let reaches = ["https://example.com/", "https://accounts.google.com/", "\(Self.scheme)://\(other)/page.html", "file:///tmp/page.html"]
                    lines.append("space \(number + 1) reaches " + reaches.map { "\($0)=\(context?.permissionStatus(for: URL(string: $0)!).rawValue ?? 99)" }.joined(separator: " "))
                    let stamp = Self.prepared(item.id, item.version).appendingPathComponent(ExtensionPreparation.stampFile)
                    lines.append("space \(number + 1) prepared \((try? String(contentsOf: stamp, encoding: .utf8)) ?? "-")")
                    lines += records(of: item.id).map { "space \(number + 1) record \($0.place) \($0.api) \($0.kind) x\($0.count)" }
                }
                // What the recording pill says (RecordingIndicator).
                if number == 0 {
                    lines += RecordingIndicator.shared.lines.map { "recording \($0.name) \($0.what)" }
                }
                // The menu bar's lines with keys for the extensions' commands.
                if number == 0, let menu = NSApp.mainMenu?.items.first(where: { $0.title == String(localized: "Extensions") })?.submenu {
                    lines += menu.items.filter { !$0.keyEquivalent.isEmpty }.map { "menu \($0.title) \($0.keyEquivalent) \($0.keyEquivalentModifierMask.rawValue)" }
                }
                // Every tab of the space, pages an extension or a site opened included.
                let addresses = session.workspace.space(space)?.tabs.map { $0.url?.absoluteString ?? "-" } ?? []
                lines.append("space \(number + 1) tabs " + addresses.joined(separator: " "))
                for page in opened where page.space == space {
                    let live = session.pages.live[page.tab]
                    lines.append("space \(number + 1) page \(live?.view.url?.host() ?? "-"): \(live?.view.title ?? "-")")
                    if let label = await live?.storeButtonLabel() { lines.append("space \(number + 1) store button: \(label)") }
                }
            }
            return lines
    }
}
#endif

// MARK: What WebKit asks of the app

extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let space = space(of: controller) else { return [] }
        return tabs.openWindows(in: space)
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let space = space(of: controller) else { return nil }
        return tabs.focusedWindow(in: space)
    }

    /// Where an extension may not send a tab: to javascript:, which would
    /// run its code in whatever page the tab shows, a site it may have no
    /// access to, nor to a file on this Mac. Chrome refuses both. (Search)
    nonisolated static func refusal(opening url: URL?) -> Error? {
        guard let scheme = url?.scheme?.lowercased(), ["javascript", "file"].contains(scheme) else { return nil }
        return Unanswered(why: "Cannot navigate to a \(scheme): URL.")
    }

    /// The same, for `context`, and never another extension's page: a
    /// tab it opened or sent there would load that page, a password
    /// manager's vault among them, and eGlu's own load of it passes the
    /// check websites are held to.
    static func refusal(opening url: URL?, by context: WKWebExtensionContext) -> Error? {
        if let refused = refusal(opening: url) { return refused }
        guard othersPage(url, for: context) else { return nil }
        return Unanswered(why: "Cannot navigate to another extension's page.")
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        if let refused = Self.refusal(opening: configuration.url, by: extensionContext) { return completionHandler(nil, refused) }
        guard let space = space(of: controller) else { return completionHandler(nil, nil) }
        let tab = tabs.open(configuration.url, in: space, active: configuration.shouldBeActive,
                            pinned: configuration.shouldBePinned, context: extensionContext)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // eGlu has no private windows: made as a normal one, its pages would
        // land in the space's store and History while the extension believed
        // them private. Refused, as Chrome refuses an extension not allowed
        // in incognito. (Search)
        if configuration.shouldBePrivate {
            return completionHandler(nil, tabs.host.privateWindowRefusal())
        }
        if let refused = configuration.tabURLs.lazy.compactMap({ Self.refusal(opening: $0, by: extensionContext) }).first { return completionHandler(nil, refused) }
        guard let space = space(of: controller) else { return completionHandler(nil, nil) }
        // A popup, as a password manager's vault or a sign-in opens: a small
        // window of its page (ExtensionPopupWindow), only a website or the
        // extension's own page.
        if configuration.windowType == .popup, let url = configuration.tabURLs.first ?? URL(string: "about:blank") {
            guard let made = ExtensionPopupWindow.open(url, for: extensionContext, in: space, controller: controller,
                                                       frame: configuration.frame, focused: configuration.shouldBeFocused, owner: tabs, scheme: Self.scheme)
            else { return completionHandler(nil, Unanswered(why: "Cannot open a popup window at that address.")) }
            return completionHandler(made, nil)
        }
        // A space is one window to extensions: a new one shows the same space,
        // with its first address in a tab.
        for url in configuration.tabURLs.prefix(1) {
            _ = tabs.open(url, in: space, active: true, pinned: false, context: extensionContext)
        }
        tabs.host.ensureWindow(in: space)
        completionHandler(tabs.window(for: space), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let space = space(of: controller), let url = extensionContext.optionsPageURL else { return completionHandler(nil) }
        _ = tabs.open(url, in: space, active: true, pinned: false, context: extensionContext)
        completionHandler(nil)
    }

    private func permissionWindow(in space: UUID, tab: (any WKWebExtensionTab)?) -> WindowModel? {
        let id = (tab as? ExtensionTab)?.id
        let candidates = Session.shared.allWindows.filter { $0.spaceID == space && $0.window?.isVisible == true }
        return candidates.first { id != nil && $0.tabID == id } ?? candidates.first { $0.window?.isKeyWindow == true } ?? candidates.first
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        // Cookies too, as Chrome asks for them: a yes is the person's
        // choice for the extension, in every space (setReadsCookies).
        let asked = permissions
        guard !asked.isEmpty else { return completionHandler([], nil) }
        guard let sourceSpace = space(of: controller),
              let owner = permissionWindow(in: sourceSpace, tab: tab) else { return completionHandler([], nil) }
        let summary = ExtensionAccessSummary(permissions: asked.map(\.rawValue), sites: [])
        let title = String(localized: "\u{201C}\(extensionContext.webExtension.displayName ?? String(localized: "An extension"))\u{201D} wants more access")
        let id = extensionContext.uniqueIdentifier
        Task {
            let yes = await askForMore(title: title, from: extensionContext, in: sourceSpace, window: owner,
                                       note: summary.cookies ? ExtensionAccessGroups.cookiesNote : nil) {
                ExtensionAccessGroups(summary: summary, everything: true, grantsCookies: true)
            }
            completionHandler(yes ? asked : [], nil)
            if yes, summary.cookies { setReadsCookies(id, true, restarting: false) }
        }
    }

    /// Chrome never asks site by site; a site the extension wants comes
    /// with its install, or with a click on its button.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        // Extension pages, files and the hands-off sites are never given,
        // so never asked about.
        let wanted = matchPatterns.filter { !Self.withheld($0) && !HandsOff.covers(host: $0.host.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }) }
        guard !wanted.isEmpty, let sourceSpace = space(of: controller),
              let owner = permissionWindow(in: sourceSpace, tab: tab) else { return completionHandler([], nil) }
        let summary = ExtensionAccessSummary(permissions: [], sites: wanted.map(\.string))
        let title = String(localized: "\u{201C}\(extensionContext.webExtension.displayName ?? String(localized: "An extension"))\u{201D} wants to read and change more sites")
        Task {
            let yes = await askForMore(title: title, from: extensionContext, in: sourceSpace, window: owner) {
                ExtensionAccessGroups(summary: summary, everything: true)
            }
            completionHandler(yes ? wanted : [], nil)
            // Given only once this has returned: fenced again after.
            if yes { DispatchQueue.main.async { Self.fence(extensionContext) } }
        }
    }

    /// The popup, in eGlu's own pane (ExtensionPopup), in the window
    /// showing the tab it was asked for, or the space's front window. At
    /// the page WebKit opened for it, which is the one set for that tab if
    /// there is one; WebKit's own is closed at once, as Search's is, so
    /// WebKit doesn't take it for open still and a second press works.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let opened = action.popupWebView?.url
        action.closePopup()
        guard let space = space(of: controller) else { return completionHandler(nil) }
        let tab = (action.associatedTab as? ExtensionTab)?.id
        let windows = Session.shared.allWindows.filter { $0.spaceID == space }
        guard let window = windows.first(where: { $0.tabID == tab && $0.window?.isKeyWindow == true })
                ?? windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first,
              let url = opened.flatMap({ $0.scheme == Self.scheme ? $0 : nil }) ?? popupURL(for: context, in: space)
        else { return completionHandler(nil) }
        ExtensionPopups.shared.show(url, for: context, in: window)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    /// Native messaging: to "eglu", the shim's questions
    /// (ExtensionAnswers); to any other name, the desktop app that
    /// registered it with Chrome (ExtensionNative), sent one and answered.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        let id = extensionContext.uniqueIdentifier
        guard let space = space(of: controller), contexts[space]?[id] === extensionContext, let name = applicationIdentifier else {
            return replyHandler(nil, Unanswered(why: "Specified native messaging host not found."))
        }
        if name == Self.shimApplication {
            guard let call = message as? [String: Any], let api = call["api"] as? String else {
                return replyHandler(nil, Unanswered(why: "Not a question eGlu knows."))
            }
            Task {
                do {
                    let value = try await answer(api, call["args"] as? [Any] ?? [], context: extensionContext, in: space)
                    replyHandler(["value": value ?? NSNull()], nil)
                } catch {
                    replyHandler(["error": error.localizedDescription], nil)
                }
            }
            return
        }
        guard reachesApps(id) else { return replyHandler(nil, Unanswered(why: "Specified native messaging host not found.")) }
        Task {
            do {
                replyHandler(try await ExtensionNative.send(message, to: name, from: id), nil)
            } catch {
                update(id, in: space) { $0.unreachableApp = Self.appName(ofHost: name) }
                replyHandler(nil, error)
            }
        }
    }

    /// A port: to "eglu.socket", a worker's WebSocket made here
    /// (ExtensionSocket); to any other name, a desktop app's host, kept
    /// talking until either end lets go.
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let id = extensionContext.uniqueIdentifier
        guard let space = space(of: controller), contexts[space]?[id] === extensionContext else {
            return completionHandler(Unanswered(why: "Specified native messaging host not found."))
        }
        if port.applicationIdentifier == ExtensionSocket.name(shimApplication: Self.shimApplication) {
            let security = extensionContext.webExtension.manifest["content_security_policy"]
            let policy = (security as? [String: Any])?["extension_pages"] as? String ?? security as? String
            ExtensionSocket.connect(port, from: id, in: space, policy: policy, scheme: Self.scheme)
            return completionHandler(nil)
        }
        // The shim's own, opened only to find what WebKit's ports are
        // made of, and let go at once.
        if port.applicationIdentifier == Self.shimApplication { return completionHandler(nil) }
        guard reachesApps(id) else { return completionHandler(Unanswered(why: "Specified native messaging host not found.")) }
        do {
            try ExtensionNative.connect(port, from: id)
            completionHandler(nil)
        } catch {
            update(id, in: space) { $0.unreachableApp = Self.appName(ofHost: port.applicationIdentifier ?? "") }
            completionHandler(error)
        }
    }
}

