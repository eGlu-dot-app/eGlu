import AppKit
import Combine
import PadCore
import UniformTypeIdentifiers
import WebEngineAppKit
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
    private lazy var metadata: any WebExtensionMetadata = WebKitExtensionMetadata(host: ExtensionHost.shared,
        contexts: { [unowned self] in self.contexts }, package: { Self.package($0, $1) })
    private lazy var compatibility = WebKitExtensionCompatibility(host: ExtensionHost.shared,
        contexts: { [unowned self] in self.contexts }, manifests: { [unowned self] in self.manifests },
        lacking: { [unowned self] in self.lacking }, setMissing: { [unowned self] in self.lacking[$1] = $0 },
        errorsChanged: { [unowned self] in self.errorsChanged($0, $1, in: $2) },
        package: { Self.package($0, $1) }, prepared: { Self.prepared($0, $1) },
        application: { Self.egluVersion }, scheme: Self.scheme, shimApplication: Self.shimApplication,
        letRulesRedirect: Self.letRulesRedirect, sites: Self.sites, fence: Self.fence)
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

    lazy var permissionPrompts = WebKitExtensionPermissions(host: ExtensionHost.shared,
        space: { [unowned self] in self.space(of: $0) }, unanswered: { Unanswered(why: $0) }, fence: Self.fence)

    private var controllers: [UUID: WKWebExtensionController] { controllerRuntime.controllers }
    private lazy var controllerRuntime = WebKitExtensionControllers(host: ExtensionHost.shared, storage: Self.storage,
        delegate: { [unowned self] in self }, capture: { ExtensionCapture.shared.runtime },
        watch: { [unowned self] in self.watch($0, Installed($1), in: $2) },
        unwatch: { [unowned self] in self.unwatch($0, in: $1) },
        applyKeys: { [unowned self] in self.applyKeys(to: $0) },
        firstLook: { [unowned self] in WebExtensionEvidence(self.firstLook(at: $0, $1, archive: $2, id: $3)) },
        record: { [unowned self] in self.record($0.policyEvidence, $1, in: $2) },
        readCode: { [unowned self] in self.readCode(of: Installed($0)) },
        startBackground: { [unowned self] in self.startBackground(of: $0, Installed($1), in: $2) },
        checkCopy: { [unowned self] in self.checkCopy(of: Installed($0)) },
        tableMissing: { Self.apiTable.table == nil }, measureTable: { [unowned self] in await self.measureTable() },
        resetRecovery: { [unowned self] in self.workerRecovery[$0] = nil },
        clearEvidence: { [unowned self] id, space in
            self.evidence[space]?[id] = nil
            ExtensionHost.shared.clearExtensionLoadVerdict(id, in: space)
            self.recorded["\(space.uuidString)/\(id)"] = nil
        })
    private lazy var workerRuntime = ExtensionWorkers(host: ExtensionHost.shared,
        contexts: { [unowned self] in self.contexts }, controllers: { [unowned self] in self.controllers })
    private var workerRecovery: [String: ExtensionWorkerRecovery] {
        get { workerRuntime.workerRecovery }
        set { workerRuntime.workerRecovery = newValue }
    }
    private(set) var contexts: [UUID: [String: WKWebExtensionContext]] {
        get { controllerRuntime.contexts }
        set { controllerRuntime.contexts = newValue }
    }
    /// Extensions being asked about new tabs now.
    private var askingNewTab: Set<String> = []
    private lazy var errorEvidence = WebKitExtensionEvidence(host: ExtensionHost.shared,
        contexts: { [unowned self] in self.contexts }, manifests: { [unowned self] in self.manifests },
        folder: { Self.folder }, recordsFile: { Self.storage.recordsFile }, debugError: { api, text in
            #if DEBUG
            Self.note("webkit error: \(api)" + Self.words(text()))
            #endif
        })
    private var evidence: [UUID: [String: WebExtensionEvidence]] {
        get { errorEvidence.evidence }
        set { errorEvidence.evidence = newValue }
    }
    /// What each extension asked for that nothing here answers: what its
    /// errors are read against.
    private(set) var lacking: [String: Set<String>] {
        get { errorEvidence.lacking }
        set { errorEvidence.lacking = newValue }
    }
    /// Each extension's manifest, as read at its first look.
    private var manifests: [String: ExtensionManifest] = [:]
    // Temporary forwarding for firstLook and keep until their hub slices move.
    private var checked: [String: (version: String, result: ExtensionTrial.Checked)] { compatibility.checked }
    private var scanned: [String: (key: String, notes: [String])] {
        get { compatibility.scanned }
        set { compatibility.scanned = newValue }
    }
    private var scanning: [String: (key: String, attempt: UUID)] {
        get { compatibility.scanning }
        set { compatibility.scanning = newValue }
    }
    /// The errors already put in the records, by "space/id": a short
    /// fingerprint of each, never its words, until the context unloads.
    private var recorded: [String: Set<String>] {
        get { errorEvidence.recorded }
        set { errorEvidence.recorded = newValue }
    }
    /// The problems each extension ran into, kept on this Mac (ExtensionRecords).
    private var records: ExtensionRecords {
        get { errorEvidence.recordCollection }
        set { errorEvidence.recordCollection = newValue }
    }
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
        note(facts: metadata.manifestFacts(permissions: manifest.permissions, optionalPermissions: manifest.optionalPermissions), of: id)
    }

    private func note(facts: WebExtensionManifestFacts?, of id: String) {
        guard let facts else { return }
        if facts.offersCookies { offersCookies.insert(id) } else { offersCookies.remove(id) }
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
        controllerRuntime.setReadsCookies(id, on) { space in
            update(id, in: space) { $0.cookiesKeptBack = !on && self.manifests[id]?.permissions.contains("cookies") == true }
            // Started again on the same context, which keeps what it was
            // granted while it ran and its open pages working.
            if restarting { restart(id, in: space, because: on ? "cookies allowed" : "cookies taken back") }
        }
    }
    /// The shim's runtime answers and keep-awake assertions, by "space/id".
    lazy var runtimeAnswers = WebKitExtensionRuntimeAnswers(host: ExtensionHost.shared,
        evidence: { [unowned self] in self.errorEvidence }, contexts: { [unowned self] in self.contexts },
        space: { [unowned self] in self.space(of: $0) },
        revive: { [unowned self] in self.revive($0, in: $1, because: $2) },
        answer: { [unowned self] in try await self.answer($0, $1, context: $2, in: $3) },
        unanswered: { Unanswered(why: $0) }, scheme: Extensions.scheme, shimApplication: Extensions.shimApplication)

    func releaseRuntimePower(_ key: String) { runtimeAnswers.releaseKeepAwake(key) }
    /// Each loaded context's errors watch, removed when it unloads.
    private var watches: [UUID: [String: NSObjectProtocol]] {
        get { errorEvidence.watches }
        set { errorEvidence.watches = newValue }
    }
    let tabs = ExtensionTabs(host: ExtensionHost.shared,
                             enabled: { !Extensions.shared.on(in: $0).isEmpty },
                             controller: { Extensions.shared.controller(for: $0) },
                             othersPage: { Extensions.othersPage($0, for: $1) },
                             refusal: { Extensions.refusal(opening: $0, by: $1) },
                             heldOwner: { ExtensionAuth.owner(of: $0) })

    /// The scheme of extensions' own pages, as Chrome's.
    static let scheme = WebKitExtensionControllers.scheme
    private static var apiTable: ExtensionTable { WebKitExtensionCompatibility.apiTable }

    private override init() {
        super.init()
        // Before any context takes a base address in it: WebKit refuses one
        // in a scheme it wasn't told of, with an exception, not an error
        // (WKWebExtensionContext's setBaseURL:), and AppKit, catching it,
        // leaves Swift's tasks broken behind it.
        WebKitExtensionControllers.registerScheme()
    }

    static var folder: URL {
        Session.folder.appendingPathComponent("Extensions", isDirectory: true)
    }

    private static var listFile: URL {
        folder.appendingPathComponent("installed.json")
    }

    private nonisolated static let storage: any WebExtensionStorage = ExtensionStorage(environment: {
        ExtensionHost.shared.extensionStorageEnvironment
    }, withoutShim: {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "extensionsWithoutShim")
        #else
        false
        #endif
    })

    /// The verified package of a version, kept as it came.
    static func package(_ id: String, _ version: String) -> URL {
        storage.package(id, version)
    }

    /// The folder WebKit loads a version from: its package unpacked, with
    /// the shim put in (ExtensionPreparation).
    static func prepared(_ id: String, _ version: String) -> URL {
        storage.prepared(id, version)
    }

    /// Makes the prepared folder off the main thread, under the runtime's lock.
    nonisolated static func prepare(_ package: URL, into folder: URL) throws {
        try storage.prepare(package, into: folder)
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

    static let workersKey = ExtensionWorkers.workersKey

    private func forgetWorkersIfChanged() async {
        await workerRuntime.forgetWorkersIfChanged()
    }

    static func workersChanged() { ExtensionWorkers.markWorkersChanged() }

    /// Names kept by older releases may be an ID or an unresolved message.
    /// Read packages after the first frame, off the main actor, including
    /// extensions disabled in every space. A missing package keeps its name.
    /// Whether each offers cookies is read with it.
    private func refreshInstalledNames() async {
        let candidates = installed.map { (id: $0.id, version: $0.version, name: $0.name) }
        var changed = false
        for candidate in candidates {
            let file = Self.package(candidate.id, candidate.version)
            let metadata = self.metadata
            let result = await Task.detached(priority: .utility) {
                metadata.packageName(at: file, fallback: candidate.name)
            }.value
            let name = result.name
            if installed.contains(where: { $0.id == candidate.id && $0.version == candidate.version }) { note(facts: result.facts, of: candidate.id) }
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

    /// Temporary WebKit forwards for the delegates and adapters still in the app.
    func controller(for space: UUID) -> WKWebExtensionController { controllerRuntime.controller(for: space) }
    func space(of controller: WKWebExtensionController?) -> UUID? { controllerRuntime.space(of: controller) }
    func context(_ id: String, in space: UUID) -> WKWebExtensionContext? { controllerRuntime.context(id, in: space) }

    /// The extensions on in a space, in the order they were installed.
    func on(in space: UUID) -> [Installed] {
        installed.filter { $0.spaces.contains(space) && controllerRuntime.isLoaded($0.id, in: space) }
    }

    /// Whether a URL is one of the extensions' own pages.
    func isExtensionPage(_ url: URL?) -> Bool {
        guard let id = controllerRuntime.extensionID(for: url) else { return false }
        return installed.contains { $0.id == id }
    }

    // MARK: Loading

    func markLoadIncompatible(_ id: String, version: String) { markIncompatible(id, version: version) }
    func clearLoadVerdict(_ id: String, in space: UUID) { verdicts[space]?[id] = nil }


    /// Whether it is loaded there now.
    @discardableResult
    private func load(_ item: Installed, in space: UUID) async -> Bool {
        await controllerRuntime.load(WebExtensionInstallation(item), in: space)
    }

    private func unload(_ id: String, in space: UUID) { controllerRuntime.unload(id, in: space) }

    @discardableResult
    func revive(_ id: String, in space: UUID, because reason: String) -> Bool {
        workerRuntime.revive(id, in: space, because: reason)
    }

    @discardableResult
    private func restart(_ id: String, in space: UUID, because reason: String) -> Bool {
        workerRuntime.restart(id, in: space, because: reason)
    }

    // Temporary forwards for compatibility trials and permission callbacks.
    static func holdCookies(_ context: WKWebExtensionContext, letting cookies: Bool) {
        WebKitExtensionControllers.holdCookies(context, letting: cookies)
    }
    static func letRulesRedirect(_ context: WKWebExtensionContext, _ package: WKWebExtension) {
        WebKitExtensionControllers.letRulesRedirect(context, package)
    }
    static func sites(of package: WKWebExtension) -> [WKWebExtension.MatchPattern] { WebKitExtensionControllers.sites(of: package) }
    nonisolated static func withheld(_ pattern: WKWebExtension.MatchPattern) -> Bool { WebKitExtensionControllers.withheld(pattern) }
    nonisolated static func othersPage(_ url: URL?, for context: WKWebExtensionContext) -> Bool {
        WebKitExtensionControllers.othersPage(url, for: context)
    }
    static func fence(_ context: WKWebExtensionContext) { WebKitExtensionControllers.fence(context) }

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
        let facts = metadata.manifestFacts(permissions: manifest.permissions, optionalPermissions: manifest.optionalPermissions)
        if facts.nativeRequired { nativeRequired.insert(id) } else { nativeRequired.remove(id) }
        if facts.nativeOptional {
            nativeOptional.insert(id)
        } else {
            nativeOptional.remove(id)
        }
        manifests[id] = manifest
        note(facts: facts, of: id)
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

    private func missing(for manifest: ExtensionManifest, _ package: WKWebExtension) -> Set<String> {
        compatibility.missing(for: manifest, package)
    }

    private static func scanKey(_ version: String, _ missing: Set<String>) -> String {
        WebKitExtensionCompatibility.scanKey(version, missing)
    }

    private func readCode(of item: Installed) {
        compatibility.readCode(of: .init(id: item.id, version: item.version))
    }

    private func measureTable() async { await compatibility.measureTable() }

    private static func apply(_ result: ExtensionTrial.Checked, to seen: inout ExtensionEvidence) {
        WebKitExtensionCompatibility.apply(result, to: &seen)
    }

    private func checkStamp(_ version: String) -> String { compatibility.checkStamp(version) }

    private func discardStaleIncompatibilities() {
        let held = UserDefaults.standard.dictionary(forKey: Self.incompatibleKey) as? [String: String] ?? [:]
        let versions = Dictionary(installed.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let current = compatibility.currentFailures(held, installed: versions)
        if current != held { UserDefaults.standard.set(current, forKey: Self.incompatibleKey) }
    }

    private func checkCopy(of item: Installed) {
        compatibility.checkCopy(of: .init(id: item.id, version: item.version))
    }

    /// Whether an error is new to the records for "space/id"; at most 500
    /// remembered, which is past what the records keep.
    func recordOnce(_ key: String, _ text: String) -> Bool {
        errorEvidence.recordOnce(key, text)
    }

    private func forgetCheck(_ id: String) { compatibility.forgetCheck(id) }

    /// An error's fingerprint, to know it again without keeping its words.
    static func fingerprint(_ text: String) -> String {
        WebKitExtensionEvidence.fingerprint(text)
    }

    private func startBackground(of context: WKWebExtensionContext, _ item: Installed, in space: UUID, attempt: UUID? = nil) {
        workerRuntime.startBackground(of: context, workerInstallation(item), in: space, attempt: attempt)
    }

    private func recover(_ action: ExtensionWorkerRecovery.Action, context: WKWebExtensionContext, item: Installed, in space: UUID) {
        workerRuntime.recover(action, context: context, item: workerInstallation(item), in: space)
    }

    func workerInstallation(_ item: Installed) -> WebExtensionWorkerInstallation {
        WebExtensionWorkerInstallation(id: item.id, version: item.version, spaces: item.spaces)
    }

    func workerCheckStamp(_ version: String) -> String { checkStamp(version) }

    func resetWorkerCompatibility(_ id: String) {
        var marked = UserDefaults.standard.dictionary(forKey: Self.incompatibleKey) as? [String: String] ?? [:]
        marked[id] = nil
        UserDefaults.standard.set(marked, forKey: Self.incompatibleKey)
    }

    func markWorkerIncompatible(_ id: String, version: String) { markIncompatible(id, version: version) }

    func updateWorker(_ id: String, in space: UUID, event: WebExtensionWorkerEvent) {
        switch event {
        case .started: update(id, in: space) { $0.start = .started }
        case .failed: update(id, in: space) { $0.start = .failed }
        case .timedOutIfChecking: update(id, in: space) { if $0.start == .checking { $0.start = .timedOut } }
        }
    }

    private func watch(_ context: WKWebExtensionContext, _ item: Installed, in space: UUID) {
        errorEvidence.watch(context, item.id, in: space)
    }

    private func unwatch(_ id: String, in space: UUID) {
        errorEvidence.unwatch(id, in: space)
    }

    private func errorsChanged(_ context: WKWebExtensionContext, _ id: String, in space: UUID) {
        errorEvidence.errorsChanged(context, id, in: space)
    }

    /// The worker slice still owns recovery. Called inline after the
    /// runtime has checked that this is the current context.
    func errorRecovery(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery {
        let key = "\(space.uuidString)/\(id)"
        let item = installed.first { $0.id == id }
        let action = failed ? workerRecovery[key, default: ExtensionWorkerRecovery()].noticedHistoricalFailure() : .ignore
        if let item, let context = contexts[space]?[id] { recover(action, context: context, item: item, in: space) }
        return WebExtensionErrorRecovery(installation: item.map { .init(id: $0.id, version: $0.version) }, restarting: action == .restart)
    }

    // MARK: The records

    private func readRecords() { errorEvidence.readRecords() }

    /// Past 30 days, gone from the file too.
    private func pruneRecords() { errorEvidence.pruneRecords() }

    private func saveRecords() { errorEvidence.saveRecords() }

    /// A problem it ran into, kept: where in it and what, never the error's words.
    func note(_ problem: ExtensionError.Problem, file: String?, of item: Installed) {
        errorEvidence.note(WebExtensionEvidence.Problem(problem), file: file, of: .init(id: item.id, version: item.version))
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
        errorEvidence.records(of: id).map { .init(id: $0.id, version: $0.version, eglu: $0.eglu, macOS: $0.macOS,
            shim: $0.shim, place: $0.place, api: $0.api, kind: $0.kind, count: $0.count, first: $0.first, last: $0.last) }
    }

    func update(_ id: String, in space: UUID, _ change: (inout ExtensionEvidence) -> Void) {
        errorEvidence.update(id, in: space) { value in
            var seen = value.policyEvidence
            change(&seen)
            value = WebExtensionEvidence(seen)
        }
    }

    private func record(_ seen: ExtensionEvidence, _ id: String, in space: UUID) {
        errorEvidence.record(WebExtensionEvidence(seen), id, in: space)
    }

    func evidenceChanged(_ seen: ExtensionEvidence, _ id: String, in space: UUID) {
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
        on(in: space).filter { metadata.newTabPageURL($0.id, in: space) != nil }
    }

    /// Those that ask, in any space, for Settings › General.
    var newTabChoices: [Installed] {
        installed.filter { item in metadata.hasNewTabPage(item.id) }
    }

    /// The page new tabs show in the space: the one you said yes to, the
    /// one added last if more than one; nil for eGlu's own command bar.
    func newTabPage(in space: UUID) -> URL? {
        let answers = newTabAnswers
        guard let item = newTabAskers(in: space).last(where: { answers[$0.id] == true }) else { return nil }
        return metadata.newTabPageURL(item.id, in: space)
    }

    /// Whether `url` is the new-tab page of an extension on in the space.
    func isNewTabPage(_ url: URL?, in space: UUID) -> Bool {
        guard let url else { return false }
        return metadata.isNewTabPage(url, in: space)
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
    func commands(in space: UUID) -> [(name: String, id: String, commands: [WebExtensionCommand])] {
        on(in: space).compactMap { item in
            guard let context = contexts[space]?[item.id], !context.commands.isEmpty else { return nil }
            return (item.name, item.id, WebKitExtensionCommands.commands(in: context))
        }
    }

    func perform(_ command: WebExtensionCommand.Identity, of id: String, in space: UUID) {
        guard let context = contexts[space]?[id] else { return }
        WebKitExtensionCommands.perform(command, in: context)
    }

    /// Settings uses the first loaded context, even when it has no commands.
    func commands(of id: String) -> [WebExtensionCommand]? {
        contexts.values.compactMap { $0[id] }.first.map { WebKitExtensionCommands.commands(in: $0) }
    }

    func isLoaded(_ id: String) -> Bool {
        contexts.values.contains { $0[id] != nil }
    }

    func applyKeys(of id: String) {
        for context in contexts.values.compactMap({ $0[id] }) { applyKeys(to: context) }
    }

    private func applyKeys(to context: WKWebExtensionContext) {
        let keys = ExtensionKeys.shared
        WebKitExtensionKeys.apply(to: context, given: { keys.given[$0] }) { name, suggestion in
            keys.suggest(suggestion, for: name)
        }
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

    func action(for id: String, in window: WindowModel, iconSize: CGSize? = nil) -> WebExtensionAction? {
        guard let context = contexts[window.spaceID]?[id],
              let action = context.action(for: window.tabID.map { tabs.tab($0, in: window.spaceID) }) else { return nil }
        return WebKitExtensionActions.look(of: action, iconSize: iconSize)
    }

    /// Its icon wherever it is loaded, or from its package when it is on
    /// in no space: for Settings, which lists every one.
    func icon(of id: String) -> NSImage? { metadata.icon(of: id) }

    func icon(of id: String, in space: UUID) -> NSImage? { metadata.icon(of: id, in: space) }

    func optionsPageURL(_ id: String, in space: UUID) -> URL? { metadata.optionsPageURL(id, in: space) }

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
        guard let context = contexts[window.spaceID]?[id], let url = WebKitExtensionMetadata.optionsPageURL(for: context) else { return }
        _ = tabs.open(url, in: window.spaceID, active: true, pinned: false, context: context)
    }

    /// What it may read: every site it asks for, or the page it is clicked
    /// on, each time. Changed in every space it is loaded in at once.
    func setSiteAccess(_ id: String, _ access: Installed.SiteAccess) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].siteAccess != access else { return }
        installed[index].siteAccess = access
        saveList()
        controllerRuntime.setSiteAccess(id, WebExtensionInstallation.SiteAccess(rawValue: access.rawValue)!)
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
        let name = Self.name(in: archive, manifest: manifest, fallback: id)
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
        metadata.forgetIcon(id)
        Self.workersChanged()
        let file = Self.package(id, version)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: file, options: .atomic)
        let manifest = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }).flatMap { try? ExtensionManifest(json: $0) }
        let resolvedName = manifest.map { Self.name(in: archive, manifest: $0, fallback: name) } ?? name
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
        cleanupRuntime.remove(id, from: space)
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
        cleanupRuntime.removePackages(id, afterClearing: spaces)
    }

    // MARK: Forgetting what it kept

    private lazy var cleanupRuntime: any WebExtensionCleanup = WebKitExtensionCleanup(host: ExtensionHost.shared,
        controllers: controllerRuntime, kept: { Self.kept($0, of: $1, in: $2) }, folder: { Self.folder },
        clearWatches: { [unowned self] in self.watches[$0] = nil },
        clearEvidence: { [unowned self] in self.evidence[$0] = nil })

    private func forgetLeftOver() { cleanupRuntime.forgetLeftOver() }

    @discardableResult
    func cleared(_ id: String, in space: UUID) async -> Bool { await cleanupRuntime.cleared(id, in: space) }

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
    func removeSpace(_ space: UUID) { cleanupRuntime.removeSpace(space) }

    // The catalog and its published changes remain the app's, at the same
    // points between runtime teardown and controller release.
    func removeCleanupMembership(in space: UUID) {
        for index in installed.indices { installed[index].spaces.removeAll { $0 == space } }
        saveList()
    }

    func clearCleanupVerdicts(in space: UUID) { verdicts[space] = nil }

    /// The name the shim sends its native messages to.
    static let shimApplication = WebKitExtensionRuntimeAnswers.applicationIdentifier

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
        guard let space = space(of: controller), let url = WebKitExtensionMetadata.optionsPageURL(for: extensionContext) else { return completionHandler(nil) }
        _ = tabs.open(url, in: space, active: true, pinned: false, context: extensionContext)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        permissionPrompts.promptForPermissions(permissions, controller: controller, tab: tab, context: extensionContext,
                                               completionHandler: completionHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        permissionPrompts.promptForPermissionToAccess(urls, completionHandler: completionHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        permissionPrompts.promptForPermissionMatchPatterns(matchPatterns, controller: controller, tab: tab, context: extensionContext,
                                                          completionHandler: completionHandler)
    }

    func sidePanelDefaultPath(_ id: String, in space: UUID) -> String? {
        metadata.sidePanelDefaultPath(id, in: space)
    }

    func sidePanelSource(_ id: String, in space: UUID) -> ExtensionPaneSource? {
        guard let context = context(id, in: space) else { return nil }
        return ExtensionPaneSource(entry: { ExtensionSurface.sidePanelEntry($0, for: context) },
                                   makePage: { ExtensionSurface.page($0, for: context, in: $1, scheme: Self.scheme,
                                                                     tabs: self.tabs, host: ExtensionHost.shared, fallbackID: id) })
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
        ExtensionPopups.shared.show(in: window) {
            ExtensionSurface.page(url, for: context, in: window.spaceID, scheme: Self.scheme,
                                  tabs: tabs, host: ExtensionHost.shared)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    /// The delegate keeps forwarding until the hub's composition moves.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        runtimeAnswers.webExtensionController(controller, sendMessage: message, toApplicationWithIdentifier: applicationIdentifier,
                                             for: extensionContext, replyHandler: replyHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtimeAnswers.webExtensionController(controller, connectUsing: port, for: extensionContext, completionHandler: completionHandler)
    }
}
