#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit

/// The plugin's composition. Parts keep the hub's actor, lazy lifetime and
/// synchronous callbacks; catalog and presentation decisions use the host.
@MainActor
public final class WebKitExtensionRuntime: WebExtensionRuntime {
    let host: any ExtensionRuntimeHost
    nonisolated let storage: any WebExtensionStorage
    let configuration: (UUID) -> WKWebViewConfiguration
    let browserFactory: (() -> WebKitExtensionBrowserAnswers)?
    let scriptFactory: (() -> WebKitExtensionScriptAnswers)?
    let unanswered: (String) -> any Error
    var manifests: [String: ExtensionManifest] = [:]

    public init(host: any ExtensionRuntimeHost, storage: any WebExtensionStorage,
                configuration: @escaping (UUID) -> WKWebViewConfiguration,
                unanswered: @escaping (String) -> any Error,
                browserAnswers: (() -> WebKitExtensionBrowserAnswers)? = nil,
                scriptAnswers: (() -> WebKitExtensionScriptAnswers)? = nil) {
        self.host = host; self.storage = storage; self.configuration = configuration; self.unanswered = unanswered
        self.browserFactory = browserAnswers; self.scriptFactory = scriptAnswers
        _ = tabs
    }

    /// Sign-in asks the selected page factory for the configuration inline.
    public convenience init(host: any ExtensionRuntimeHost, storage: any WebExtensionStorage,
                            pageFactory: @escaping () -> WebKitMacPageFactory,
                            unanswered: @escaping (String) -> any Error,
                            browserAnswers: (() -> WebKitExtensionBrowserAnswers)? = nil,
                            scriptAnswers: (() -> WebKitExtensionScriptAnswers)? = nil) {
        self.init(host: host, storage: storage,
            configuration: { pageFactory().configuration(space: $0) }, unanswered: unanswered,
            browserAnswers: browserAnswers, scriptAnswers: scriptAnswers)
    }

    lazy var metadata: WebKitExtensionMetadata = WebKitExtensionMetadata(host: host,
        contexts: { [unowned self] in self.controllers.contexts }, package: { [unowned self] in self.storage.package($0, $1) })
    lazy var compatibility: WebKitExtensionCompatibility = WebKitExtensionCompatibility(host: host,
        contexts: { [unowned self] in self.controllers.contexts }, manifests: { [unowned self] in self.manifests },
        lacking: { [unowned self] in self.errors.lacking }, setMissing: { [unowned self] in self.errors.lacking[$1] = $0 },
        errorsChanged: { [unowned self] in self.errors.errorsChanged($0, $1, in: $2) },
        package: { [unowned self] in self.storage.package($0, $1) }, prepared: { [unowned self] in self.storage.prepared($0, $1) },
        application: { [unowned self] in self.host.extensionEvidenceAppVersion }, scheme: WebKitExtensionControllers.scheme,
        shimApplication: WebKitExtensionRuntimeAnswers.applicationIdentifier,
        letRulesRedirect: WebKitExtensionControllers.letRulesRedirect,
        sites: WebKitExtensionControllers.sites, fence: WebKitExtensionControllers.fence)
    public lazy var controllers: WebKitExtensionControllers = WebKitExtensionControllers(host: host, storage: storage,
        delegate: { [unowned self] in self.controllerDelegate }, capture: { [unowned self] in self.capture },
        watch: { [unowned self] in self.errors.watch($0, $1.id, in: $2) },
        unwatch: { [unowned self] in self.errors.unwatch($0, in: $1) },
        applyKeys: { [unowned self] in self.applyKeys(to: $0) },
        firstLook: { [unowned self] in self.firstLook(at: $0, $1, archive: $2, id: $3) },
        record: { [unowned self] in self.errors.record($0, $1, in: $2) },
        readCode: { [unowned self] in self.compatibility.readCode(of: .init(id: $0.id, version: $0.version)) },
        startBackground: { [unowned self] in self.workers.startBackground(of: $0, .init(id: $1.id, version: $1.version, spaces: $1.spaces), in: $2) },
        checkCopy: { [unowned self] in self.compatibility.checkCopy(of: .init(id: $0.id, version: $0.version)) },
        tableMissing: { WebKitExtensionCompatibility.apiTable.table == nil },
        measureTable: { [unowned self] in await self.compatibility.measureTable() },
        resetRecovery: { [unowned self] in self.workers.workerRecovery[$0] = nil },
        clearEvidence: { [unowned self] id, space in
            self.errors.evidence[space]?[id] = nil
            self.host.clearExtensionLoadVerdict(id, in: space)
            self.errors.recorded["\(space.uuidString)/\(id)"] = nil
        })
    lazy var workers: ExtensionWorkers = ExtensionWorkers(host: host,
        contexts: { [unowned self] in self.controllers.contexts }, controllers: { [unowned self] in self.controllers.controllers })
    lazy var errors: WebKitExtensionEvidence = WebKitExtensionEvidence(host: host,
        contexts: { [unowned self] in self.controllers.contexts }, manifests: { [unowned self] in self.manifests },
        folder: { [unowned self] in self.host.extensionStorageEnvironment.root },
        recordsFile: { [unowned self] in self.storage.recordsFile },
        debugError: { [unowned self] api, text in self.host.noteExtensionError(api, words: text) })
    lazy var permissions: WebKitExtensionPermissions = WebKitExtensionPermissions(host: host,
        space: { [unowned self] in self.controllers.space(of: $0) }, unanswered: unanswered)
    lazy var answers: WebKitExtensionRuntimeAnswers = WebKitExtensionRuntimeAnswers(host: host,
        evidence: { [unowned self] in self.errors }, contexts: { [unowned self] in self.controllers.contexts },
        space: { [unowned self] in self.controllers.space(of: $0) },
        revive: { [unowned self] in self.workers.revive($0, in: $1, because: $2) },
        answer: { [unowned self] in try await self.dispatcher.answer($0, $1, context: $2, in: $3) },
        unanswered: unanswered, scheme: WebKitExtensionControllers.scheme,
        shimApplication: WebKitExtensionRuntimeAnswers.applicationIdentifier)
    lazy var tabs: ExtensionTabs = ExtensionTabs(host: host,
        enabled: { [unowned self] in self.host.extensionHasEnabledItems(in: $0) },
        controller: { [unowned self] in self.controllers.controller(for: $0) },
        othersPage: { WebKitExtensionControllers.othersPage($0, for: $1) },
        refusal: { [unowned self] in WebKitExtensionControllerDelegate.refusal(opening: $0, by: $1, unanswered: self.unanswered) },
        heldOwner: { WebKitExtensionAuth.owner(of: $0) })
    lazy var adapters: WebKitExtensionAdapters = WebKitExtensionAdapters(tabs: tabs)
    lazy var diagnostics: WebKitExtensionDiagnostics = WebKitExtensionDiagnostics(host: host,
        table: { WebKitExtensionCompatibility.apiTable.table }, contexts: { [unowned self] in self.controllers.contexts },
        prepared: { [unowned self] in self.storage.prepared($0, $1) }, records: { [unowned self] in self.errors.records(of: $0) },
        scheme: WebKitExtensionControllers.scheme)
    lazy var install: WebKitExtensionInstallExecution = WebKitExtensionInstallExecution(host: host, storage: storage, controllers: controllers,
        forgetChecks: { [unowned self] in self.compatibility.forgetInstallChecks($0) },
        forgetIcon: { [unowned self] in self.metadata.forgetIcon($0) }, workersChanged: { ExtensionWorkers.markWorkersChanged() },
        scheme: WebKitExtensionControllers.scheme)
    lazy var cleanup: WebKitExtensionCleanup = WebKitExtensionCleanup(host: host, controllers: controllers,
        kept: { [unowned self] in self.scripts.kept($0, of: $1, in: $2) },
        folder: { [unowned self] in self.host.extensionStorageEnvironment.root },
        clearWatches: { [unowned self] in self.errors.watches[$0] = nil },
        clearEvidence: { [unowned self] in self.errors.evidence[$0] = nil })
    lazy var browser: WebKitExtensionBrowserAnswers = browserFactory?() ?? WebKitExtensionBrowserAnswers(host: host, unanswered: unanswered, scheme: WebKitExtensionControllers.scheme)
    lazy var scripts: WebKitExtensionScriptAnswers = scriptFactory?() ?? WebKitExtensionScriptAnswers(host: host,
        prepared: { [unowned self] in self.storage.prepared($0, $1) }, unanswered: unanswered)
    public lazy var capture: ExtensionCaptureRuntime = ExtensionCaptureRuntime(scheme: WebKitExtensionControllers.scheme, host: host,
        space: { [unowned self] in self.controllers.space(of: $0) },
        context: { [unowned self] in self.controllers.context($0, in: $1) },
        declares: { WebKitExtensionRuntimeAnswers.asks($0, for: "desktopCapture") })
    lazy var controllerDelegate: WebKitExtensionControllerDelegate = WebKitExtensionControllerDelegate(tabs: tabs, host: host, auxiliaryHost: host,
        space: { [unowned self] in self.controllers.space(of: $0) }, permissions: { [unowned self] in self.permissions },
        answers: { [unowned self] in self.answers }, browser: { [unowned self] in self.browser }, unanswered: unanswered)
    lazy var dispatcher: WebKitExtensionDispatcher = WebKitExtensionDispatcher(host: host, tabs: tabs,
        runtime: { [unowned self] in self.answers }, browser: { [unowned self] in self.browser },
        scripts: { [unowned self] in self.scripts }, permissions: { [unowned self] in self.permissions },
        capture: { [unowned self] in self.capture }, configuration: configuration, unanswered: unanswered)

    private func firstLook(at context: WKWebExtensionContext, _ package: WKWebExtension, archive file: URL, id: String) -> WebExtensionEvidence {
        var seen = ExtensionEvidence()
        seen.start = package.hasBackgroundContent ? .checking : .started
        guard let archive = try? Data(contentsOf: file),
              let manifestData = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }),
              let manifest = try? ExtensionManifest(json: manifestData)
        else { return Self.value(seen) }
        let facts = metadata.manifestFacts(permissions: manifest.permissions, optionalPermissions: manifest.optionalPermissions)
        host.extensionFirstLookNativeFacts(facts, of: id)
        manifests[id] = manifest
        host.noteExtensionInstallFacts(facts, of: id)
        seen.cookiesKeptBack = manifest.permissions.contains("cookies") && !(host.extensionInstallation(id)?.readsCookies == true)
        let missing = compatibility.missing(for: manifest, package)
        errors.lacking[id] = missing
        // Read away from the main thread once it has loaded (readCode).
        if let version = host.extensionInstallation(id)?.version, let done = compatibility.scanned[id],
           done.key == WebKitExtensionCompatibility.scanKey(version, missing) {
            seen.mayNotWork = done.notes
        }
        let product = host.extensionFirstLookEvidence(Self.value(seen), id: id)
        seen.tried = product.tried.map { .init(release: $0.release, works: $0.works, what: $0.what) }
        // What its copy's pages showed, for this version, if they were tried.
        if let done = compatibility.checked[id], done.version == host.extensionInstallation(id)?.version {
            WebKitExtensionCompatibility.apply(done.result, to: &seen)
        }
        return Self.value(seen)
    }


    private static func value(_ value: ExtensionEvidence) -> WebExtensionEvidence {
        var result = WebExtensionEvidence()
        switch value.start {
        case .checking: result.start = .checking
        case .started: result.start = .started
        case .failed: result.start = .failed
        case .timedOut: result.start = .timedOut
        }
        switch value.testPage {
        case .notApplicable: result.testPage = .notApplicable
        case .checking: result.testPage = .checking
        case .passed: result.testPage = .passed
        case .failed: result.testPage = .failed
        case .skipped: result.testPage = .skipped
        case .timedOut: result.testPage = .timedOut
        }
        switch value.popup {
        case .notApplicable: result.popup = .notApplicable
        case .checking: result.popup = .checking
        case .passed: result.popup = .passed
        case .failed: result.popup = .failed
        case .skipped: result.popup = .skipped
        case .timedOut: result.popup = .timedOut
        }
        switch value.optionsPage {
        case .notApplicable: result.optionsPage = .notApplicable
        case .checking: result.optionsPage = .checking
        case .passed: result.optionsPage = .passed
        case .failed: result.optionsPage = .failed
        case .skipped: result.optionsPage = .skipped
        case .timedOut: result.optionsPage = .timedOut
        }
        result.problems = Set(value.problems.map { problem in
            let kind: WebExtensionEvidence.Problem.Kind
            switch problem.kind {
            case .missing: kind = .missing
            case .notAFunction: kind = .notAFunction
            case .wrongArguments: kind = .wrongArguments
            }
            return .init(kind: kind, api: problem.api)
        })
        result.unreachableApp = value.unreachableApp
        result.mayNotWork = value.mayNotWork
        result.cookiesKeptBack = value.cookiesKeptBack
        result.tried = value.tried.map { .init(release: $0.release, works: $0.works, what: $0.what) }
        return result
    }

    public var recordsFile: URL { storage.recordsFile }
    public func package(_ id: String, _ version: String) -> URL { storage.package(id, version) }
    public func prepared(_ id: String, _ version: String) -> URL { storage.prepared(id, version) }
    public nonisolated func prepare(_ package: URL, into folder: URL) throws { try storage.prepare(package, into: folder) }

    public func icon(of id: String) -> NSImage? {
        metadata.icon(of: id)
    }

    public func icon(of id: String, in space: UUID) -> NSImage? {
        metadata.icon(of: id, in: space)
    }

    public func forgetIcon(_ id: String) {
        metadata.forgetIcon(id)
    }

    public func manifestFacts(permissions: [String], optionalPermissions: [String]) -> WebExtensionManifestFacts {
        metadata.manifestFacts(permissions: permissions, optionalPermissions: optionalPermissions)
    }

    public func optionsPageURL(_ id: String, in space: UUID) -> URL? {
        metadata.optionsPageURL(id, in: space)
    }

    public func newTabPageURL(_ id: String, in space: UUID) -> URL? {
        metadata.newTabPageURL(id, in: space)
    }

    public func hasNewTabPage(_ id: String) -> Bool {
        metadata.hasNewTabPage(id)
    }

    public func isNewTabPage(_ url: URL, in space: UUID) -> Bool {
        metadata.isNewTabPage(url, in: space)
    }

    public func sidePanelDefaultPath(_ id: String, in space: UUID) -> String? {
        metadata.sidePanelDefaultPath(id, in: space)
    }

    public nonisolated func packageName(at file: URL, fallback: String) -> WebExtensionPackageName {
        WebKitExtensionMetadata.readPackageName(at: file, fallback: fallback)
    }

    public func readCode(of item: WebExtensionCompatibilityInstallation) {
        compatibility.readCode(of: item)
    }

    public func measureTable() async {
        await compatibility.measureTable()
    }

    public func checkCopy(of item: WebExtensionCompatibilityInstallation) {
        compatibility.checkCopy(of: item)
    }

    public func checkStamp(_ version: String) -> String {
        compatibility.checkStamp(version)
    }

    public func currentFailures(_ held: [String: String], installed: [String: String]) -> [String: String] {
        compatibility.currentFailures(held, installed: installed)
    }

    public func forgetCheck(_ id: String) {
        compatibility.forgetCheck(id)
    }

    public func isLoaded(_ id: String, in space: UUID) -> Bool {
        controllers.isLoaded(id, in: space)
    }

    public func extensionID(for url: URL?) -> String? {
        controllers.extensionID(for: url)
    }

    @discardableResult public func load(_ item: WebExtensionInstallation, in space: UUID) async -> Bool {
        await controllers.load(item, in: space)
    }

    public func unload(_ id: String, in space: UUID) {
        controllers.unload(id, in: space)
    }

    public func setSiteAccess(_ id: String, _ access: WebExtensionInstallation.SiteAccess) {
        controllers.setSiteAccess(id, access)
    }

    public func setReadsCookies(_ id: String, _ on: Bool, changed: (UUID) -> Void) {
        controllers.setReadsCookies(id, on, changed: changed)
    }

    public func forgetWorkersIfChanged() async {
        await workers.forgetWorkersIfChanged()
    }

    public func workersChanged() {
        workers.workersChanged()
    }

    @discardableResult public func revive(_ id: String, in space: UUID, because reason: String) -> Bool {
        workers.revive(id, in: space, because: reason)
    }

    @discardableResult public func restart(_ id: String, in space: UUID, because reason: String) -> Bool {
        workers.restart(id, in: space, because: reason)
    }

    public func recordOnce(_ key: String, _ text: String) -> Bool {
        errors.recordOnce(key, text)
    }

    public func readRecords() {
        errors.readRecords()
    }

    public func pruneRecords() {
        errors.pruneRecords()
    }

    public func saveRecords() {
        errors.saveRecords()
    }

    public func note(_ problem: WebExtensionEvidence.Problem, file: String?, of item: WebExtensionEvidenceInstallation) {
        errors.note(problem, file: file, of: item)
    }

    public func records(of id: String) -> [WebExtensionErrorRecord] {
        errors.records(of: id)
    }

    public func update(_ id: String, in space: UUID, _ change: (inout WebExtensionEvidence) -> Void) {
        errors.update(id, in: space, change)
    }

    public func record(_ seen: WebExtensionEvidence, _ id: String, in space: UUID) {
        errors.record(seen, id, in: space)
    }

    public func remove(_ id: String, from space: UUID) {
        cleanup.remove(id, from: space)
    }

    public func removePackages(_ id: String, afterClearing spaces: [UUID]) {
        cleanup.removePackages(id, afterClearing: spaces)
    }

    @discardableResult public func forget(_ id: String, in space: UUID) -> Task<Void, Never> {
        cleanup.forget(id, in: space)
    }

    public func forgetLeftOver() {
        cleanup.forgetLeftOver()
    }

    @discardableResult public func cleared(_ id: String, in space: UUID) async -> Bool {
        await cleanup.cleared(id, in: space)
    }

    public func removeSpace(_ space: UUID) {
        cleanup.removeSpace(space)
    }

    public func closePages(of id: String, in space: UUID) {
        cleanup.closePages(of: id, in: space)
    }

    public func download(_ id: String, from address: URL?) async throws -> Data {
        try await install.download(id, from: address)
    }

    public func readArchive(_ archive: Data) throws -> any WebExtensionInstallArchive {
        try install.readArchive(archive)
    }

    public func describeOffer(_ archive: Data, id: String) throws -> (any WebExtensionInstallArchive, String) {
        try install.describeOffer(archive, id: id)
    }

    public func verifyUpdate(_ crx: Data, id: String, size: Int?, sha256: String?, version: String) throws -> (Data, any WebExtensionInstallArchive, String) {
        try install.verifyUpdate(crx, id: id, size: size, sha256: sha256, version: version)
    }

    public func keepArchive(_ archive: Data, id: String, name: String, version: String) throws -> String {
        try install.keepArchive(archive, id: id, name: name, version: version)
    }

    public func unload(_ item: WebExtensionInstallation) {
        install.unload(item)
    }

    public func loadReplacement(_ item: WebExtensionInstallation,
                         completion: (Bool) -> WebExtensionInstallCompletion) async -> Bool {
        await install.loadReplacement(item, completion: completion)
    }

    public func loadNew(_ item: WebExtensionInstallation, didLoad: () -> Void) async -> Bool {
        await install.loadNew(item, didLoad: didLoad)
    }

    public func removeOtherVersions(of id: String, keeping version: String) {
        install.removeOtherVersions(of: id, keeping: version)
    }

    public func trial(_ archive: Data, id: String) async throws {
        try await install.trial(archive, id: id)
    }

    public func snapshot(_ folder: URL) async throws -> WebExtensionFolderSnapshot {
        try await install.snapshot(folder)
    }

    public func zipped(_ folder: URL) async throws -> Data {
        try await install.zipped(folder)
    }

    public func sha256(_ data: Data) -> String { install.sha256(data) }

    public func releaseKeepAwake(_ key: String) {
        answers.releaseKeepAwake(key)
    }

    public func kept(_ name: String, of id: String, in space: UUID) -> URL {
        scripts.kept(name, of: id, in: space)
    }

    public func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        try scripts.scriptingFile(function, arguments: arguments, in: folder)
    }

    public func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool) throws -> String {
        try scripts.userScriptFile(script, in: folder, writing: writing)
    }

    public func userScripts(of id: String, in space: UUID) -> Any {
        scripts.userScripts(of: id, in: space)
    }

    public func changeUserScripts(_ first: Any?, of id: String, in space: UUID) throws -> [[String: Any]] {
        try scripts.changeUserScripts(first, of: id, in: space)
    }

    public func userScriptWorlds(of id: String, in space: UUID) -> [[String: Any]] {
        scripts.userScriptWorlds(of: id, in: space)
    }

    public func setUserScriptWorld(_ first: Any?, of id: String, in space: UUID) throws {
        try scripts.setUserScriptWorld(first, of: id, in: space)
    }

    public func pruneUserScripts(of id: String, in folder: URL) {
        scripts.pruneUserScripts(of: id, in: folder)
    }

    public func tab(at place: Any?, in space: UUID) -> UUID? {
        browser.tab(at: place, in: space)
    }

    public func favIconURL(for url: URL?) -> String? {
        browser.favIconURL(for: url)
    }

    public func addressChanged(_ page: any WebMacPage, tab: UUID, in space: UUID) {
        adapters.addressChanged(page, tab: tab, in: space)
    }

    public func loadingChanged(tab: UUID, in space: UUID) {
        adapters.loadingChanged(tab: tab, in: space)
    }

    public func popupShows(_ page: any WebMacPage) -> Bool {
        adapters.popupShows(page)
    }

    public func diagnosticTableLines() -> [String] {
        diagnostics.diagnosticTableLines()
    }

    public func diagnosticLines(id: String, name: String, version: String, in space: UUID,
                         number: Int, otherExtension: () -> String) -> [String] {
        diagnostics.diagnosticLines(id: id, name: name, version: version, in: space, number: number, otherExtension: otherExtension)
    }

    public func diagnosticPageLine(_ page: (any WebMacPage)?, number: Int) -> String {
        diagnostics.diagnosticPageLine(page, number: number)
    }

    public static func words(_ text: String?, enabled: Bool) -> String {
        WebKitExtensionDiagnostics.words(text, enabled: enabled)
    }

    public static func note(_ line: String, outputPath: String?) {
        WebKitExtensionDiagnostics.note(line, outputPath: outputPath)
    }

    public var evidence: [UUID: [String: WebExtensionEvidence]] {
        get { errors.evidence }
        set { errors.evidence = newValue }
    }

    public var lacking: [String: Set<String>] {
        get { errors.lacking }
        set { errors.lacking = newValue }
    }

    public var recorded: [String: Set<String>] {
        get { errors.recorded }
        set { errors.recorded = newValue }
    }

    public var popupPaths: [String: String] {
        get { browser.popupPaths }
        set { browser.popupPaths = newValue }
    }

    public var permissionPresses: [String: Date] {
        get { WebKitExtensionPermissions.pressed }
        set { WebKitExtensionPermissions.pressed = newValue }
    }

    public func keepsCookiesBack(_ id: String, allowing on: Bool) -> Bool {
        !on && manifests[id]?.permissions.contains("cookies") == true
    }

    public func startTabs() { tabs.start() }
    public func isLoaded(_ id: String) -> Bool { controllers.contexts.values.contains { $0[id] != nil } }
    public func asks(_ id: String, in space: UUID, for permission: String) -> Bool {
        guard let context = controllers.context(id, in: space) else { return false }
        return WebKitExtensionRuntimeAnswers.asks(context, for: permission)
    }
    public func openTab(_ url: URL, extension id: String, in space: UUID) -> UUID? {
        guard let context = controllers.context(id, in: space) else { return nil }
        return tabs.open(url, in: space, active: true, pinned: false, context: context)?.id
    }
    public func openOptions(_ id: String, in space: UUID) {
        guard let context = controllers.contexts[space]?[id], let url = WebKitExtensionMetadata.optionsPageURL(for: context) else { return }
        _ = tabs.open(url, in: space, active: true, pinned: false, context: context)
    }
    public func permissionIcon(_ id: String, in space: UUID) -> NSImage? {
        guard let context = controllers.context(id, in: space) else { return nil }
        return WebKitExtensionMetadata.icon(of: context.webExtension, size: CGSize(width: 96, height: 96))
    }
    public func commands(of id: String) -> [WebExtensionCommand]? {
        controllers.contexts.values.compactMap { $0[id] }.first.map { WebKitExtensionCommands.commands(in: $0) }
    }
    public func commands(of id: String, in space: UUID) -> [WebExtensionCommand]? {
        guard let context = controllers.contexts[space]?[id], !context.commands.isEmpty else { return nil }
        return WebKitExtensionCommands.commands(in: context)
    }
    public func perform(_ command: WebExtensionCommand.Identity, of id: String, in space: UUID) {
        guard let context = controllers.contexts[space]?[id] else { return }
        WebKitExtensionCommands.perform(command, in: context)
    }
    public func applyKeys(of id: String) {
        for context in controllers.contexts.values.compactMap({ $0[id] }) { applyKeys(to: context) }
    }
    private func applyKeys(to context: WKWebExtensionContext) {
        WebKitExtensionKeys.apply(to: context, given: { host.extensionKey($0).flatMap(ExtensionKey.init(stored:)) }) { name, suggestion in
            host.suggestExtensionKey(suggestion?.stored, for: name)
        }
    }
    public func action(for id: String, tab: UUID?, in space: UUID, iconSize: CGSize?) -> WebExtensionAction? {
        guard let context = controllers.contexts[space]?[id],
              let action = context.action(for: tab.map { tabs.tab($0, in: space) }) else { return nil }
        return WebKitExtensionActions.look(of: action, iconSize: iconSize)
    }
    public func run(_ id: String, tab tabID: () -> UUID?, in space: UUID, popup: () -> Bool,
                    panel: () -> Bool, pageURL: () -> URL?, togglePanel: () -> Void) {
        guard let context = controllers.contexts[space]?[id] else { return }
        if popup() { return }
        let tab = tabID().map { tabs.tab($0, in: space) }
        WebKitExtensionPermissions.pressed["\(space.uuidString)/\(id)"] = Date()
        if panel() {
            if let tab, ExtensionPolicy.grantsOnClick(pageURL()) { context.userGesturePerformed(in: tab) }
            togglePanel()
            return
        }
        context.performAction(for: tab)
    }
    public func sidePanelSource(_ id: String, in space: UUID) -> ExtensionPaneSource? {
        guard let context = controllers.context(id, in: space) else { return nil }
        return ExtensionPaneSource(entry: { ExtensionSurface.sidePanelEntry($0, for: context) },
                                   makePage: { ExtensionSurface.page($0, for: context, in: $1, scheme: WebKitExtensionControllers.scheme,
                                                                     tabs: self.tabs, host: self.host, fallbackID: id) })
    }
    public func webAccessible(_ url: URL, from source: URL, in space: UUID, fromRule: Bool) -> Bool {
        guard let id = url.host(), let context = controllers.contexts[space]?[id] else { return false }
        let own = fromRule && ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"].contains { WebKitExtensionRuntimeAnswers.asks(context, for: $0) }
        return ExtensionPolicy.webAccessible(url, from: source, manifest: context.webExtension.manifest,
                                             scheme: WebKitExtensionControllers.scheme, fromRule: own)
    }
    public func externalListings(in space: UUID) -> [String: [String]] {
        (controllers.contexts[space] ?? [:]).compactMapValues { context in
            let listed = ExtensionExternal.listed(in: context.webExtension.manifest)
            return listed.isEmpty ? nil : listed
        }
    }
    public func forgetCapture(_ id: String) { capture.forget(id) }
    public func releaseCapture(_ view: NSView) { capture.release(view) }
    public func displayCaptureDecision(for view: NSView) -> Int { capture.displayDecision(for: view) }
    public func watchCapture(_ view: NSView, id: String) { capture.watch(view, id: id) }
    public func forgetRecords(_ id: String) { errors.recordCollection.forget(id) }
    public func errorRecovery(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery {
        let key = "\(space.uuidString)/\(id)"
        let item = host.extensionInstallation(id)
        let action = failed ? workers.workerRecovery[key, default: ExtensionWorkerRecovery()].noticedHistoricalFailure() : .ignore
        if let item, let context = controllers.contexts[space]?[id] {
            workers.recover(action, context: context, item: .init(id: item.id, version: item.version, spaces: item.spaces), in: space)
        }
        return WebExtensionErrorRecovery(installation: item.map { .init(id: $0.id, version: $0.version) }, restarting: action == .restart)
    }
}
#endif
