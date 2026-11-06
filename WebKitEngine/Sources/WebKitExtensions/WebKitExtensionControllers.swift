#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import WebKitSupport

/// The registry and grants, on the original hub's actor. Concrete callbacks
/// temporarily connect the hub members owned by later slices.
@MainActor
public final class WebKitExtensionControllers: WebExtensionControllers {
    public static let scheme = "chrome-extension"
    private let host: any ExtensionControllerHost
    private let storage: any WebExtensionStorage
    private let delegate: () -> any WKWebExtensionControllerDelegate
    private let capture: () -> ExtensionCaptureRuntime
    private let watch: (WKWebExtensionContext, WebExtensionInstallation, UUID) -> Void
    private let unwatch: (String, UUID) -> Void
    private let applyKeys: (WKWebExtensionContext) -> Void
    private let firstLook: (WKWebExtensionContext, WKWebExtension, URL, String) -> WebExtensionEvidence
    private let record: (WebExtensionEvidence, String, UUID) -> Void
    private let readCode: (WebExtensionInstallation) -> Void
    private let startBackground: (WKWebExtensionContext, WebExtensionInstallation, UUID) -> Void
    private let checkCopy: (WebExtensionInstallation) -> Void
    private let tableMissing: () -> Bool
    private let measureTable: () async -> Void
    private let resetRecovery: (String) -> Void
    private let clearEvidence: (String, UUID) -> Void

    public private(set) var controllers: [UUID: WKWebExtensionController] = [:]
    public var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
    /// A late failed load cannot disable a replacement at the same version.
    private var loadAttempts: [String: UUID] = [:]

    public init(host: any ExtensionControllerHost, storage: any WebExtensionStorage,
                delegate: @escaping () -> any WKWebExtensionControllerDelegate,
                capture: @escaping () -> ExtensionCaptureRuntime,
                watch: @escaping (WKWebExtensionContext, WebExtensionInstallation, UUID) -> Void,
                unwatch: @escaping (String, UUID) -> Void, applyKeys: @escaping (WKWebExtensionContext) -> Void,
                firstLook: @escaping (WKWebExtensionContext, WKWebExtension, URL, String) -> WebExtensionEvidence,
                record: @escaping (WebExtensionEvidence, String, UUID) -> Void,
                readCode: @escaping (WebExtensionInstallation) -> Void,
                startBackground: @escaping (WKWebExtensionContext, WebExtensionInstallation, UUID) -> Void,
                checkCopy: @escaping (WebExtensionInstallation) -> Void, tableMissing: @escaping () -> Bool,
                measureTable: @escaping () async -> Void, resetRecovery: @escaping (String) -> Void,
                clearEvidence: @escaping (String, UUID) -> Void) {
        self.host = host
        self.storage = storage
        self.delegate = delegate
        self.capture = capture
        self.watch = watch
        self.unwatch = unwatch
        self.applyKeys = applyKeys
        self.firstLook = firstLook
        self.record = record
        self.readCode = readCode
        self.startBackground = startBackground
        self.checkCopy = checkCopy
        self.tableMissing = tableMissing
        self.measureTable = measureTable
        self.resetRecovery = resetRecovery
        self.clearEvidence = clearEvidence
    }

    // Fixtures supply non-persistent configurations and intercept execution.
    var configurationForTesting: ((UUID) -> WKWebExtensionController.Configuration)?
    var loadForTesting: ((WKWebExtensionController, WKWebExtensionContext) throws -> Void)?
    var unloadForTesting: ((WKWebExtensionController, WKWebExtensionContext) throws -> Void)?
    var releaseForTesting: ((String) -> Void)?
    var preparedForTesting: ((URL, URL) async throws -> Void)?

    public static func registerScheme() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(scheme)
    }

    /// The space's controller, made the first time a page in the space is.
    /// Every page gets it before its view exists, as WebKit needs, whether
    /// or not anything is on in the space yet.
    public func controller(for space: UUID) -> WKWebExtensionController {
        if let controller = controllers[space] { return controller }
        let configuration: WKWebExtensionController.Configuration
        if let configurationForTesting { configuration = configurationForTesting(space) }
        else {
            configuration = WKWebExtensionController.Configuration(identifier: space)
            configuration.defaultWebsiteDataStore = WebKitStores.store(for: space)
        }
        // The extensions' own pages reach eGlu's recording channel
        // (ExtensionCapture), in their own world; websites never do.
        let pages = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        pages.userContentController.addScriptMessageHandler(capture(), contentWorld: .page, name: ExtensionCaptureRuntime.channel)
        if host.extensionControllerMockCapture { ExtensionCaptureRuntime.mockDevices(pages.preferences) }
        configuration.webViewConfiguration = pages
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = delegate()
        controllers[space] = controller
        return controller
    }

    public func space(of controller: WKWebExtensionController?) -> UUID? {
        controllers.first { $0.value === controller }?.key
    }

    public func context(_ id: String, in space: UUID) -> WKWebExtensionContext? {
        contexts[space]?[id]
    }

    public func isLoaded(_ id: String, in space: UUID) -> Bool { contexts[space]?[id] != nil }

    /// The app checks this classified identity against its installed catalog.
    public func extensionID(for url: URL?) -> String? {
        guard let url, url.scheme == Self.scheme, let host = url.host() else { return nil }
        return host
    }

    /// Temporary cleanup bridge until the destructive-cleanup slice moves.
    public func removeController(for space: UUID) -> WKWebExtensionController? {
        controllers.removeValue(forKey: space)
    }

    /// Whether it is loaded there now.
    @discardableResult
    public func load(_ item: WebExtensionInstallation, in space: UUID) async -> Bool {
        // Not on this Mac, for this version (markIncompatible).
        guard !host.extensionIsIncompatible(item.id) else { return false }
        guard await host.extensionCleared(item.id, in: space) else {
            NSLog("eGlu: extension \(item.id) waits for what was kept before to be cleared in a space")
            return false
        }
        guard contexts[space]?[item.id] == nil else { return true }
        let key = "\(space.uuidString)/\(item.id)"
        let attempt = UUID()
        loadAttempts[key] = attempt
        var seen = WebExtensionEvidence()
        do {
            let (file, folder) = (storage.package(item.id, item.version), storage.prepared(item.id, item.version))
            if let preparedForTesting { try await preparedForTesting(file, folder) }
            else { try await Task.detached(priority: .userInitiated) { [storage] in try storage.prepare(file, into: folder) }.value }
            let package = try await WKWebExtension(resourceBaseURL: folder)
            // Turned off here, removed, updated, or its space gone, while the
            // package was read: not loaded after all. Another space's turning
            // on or off is no reason.
            guard loadAttempts[key] == attempt,
                  let now = host.extensionInstallation(item.id), now.version == item.version,
                  now.source == item.source, now.spaces.contains(space),
                  host.extensionSpaceExists(space), contexts[space]?[item.id] == nil
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
            watch(context, item, space)
            let controller = controller(for: space)
            if let loadForTesting { try loadForTesting(controller, context) }
            else { try controller.load(context) }
            // Its commands' keys: the person's, or none (ExtensionKeys).
            applyKeys(context)
            contexts[space, default: [:]][item.id] = context
            seen = firstLook(context, package, storage.package(item.id, item.version), item.id)
        } catch {
            guard loadAttempts[key] == attempt else { return contexts[space]?[item.id] != nil }
            seen.start = .failed
            unwatch(item.id, space)
            // WebKit wouldn't take it at all.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadAttempts[key] == attempt, self.contexts[space]?[item.id] == nil else { return }
                self.host.markExtensionLoadIncompatible(item.id, version: item.version)
            }
            NSLog("eGlu: extension \(item.id) didn't load in a space: \(error.localizedDescription)")
            host.noteExtensionLoadFailure(error)
        }
        record(seen, item.id, space)
        if contexts[space]?[item.id] != nil { readCode(item) }
        if seen.start == .checking, let context = contexts[space]?[item.id] {
            startBackground(context, item, space)
        }
        if contexts[space]?[item.id] != nil {
            checkCopy(item)
            // The first extension on a new macOS build: this Mac's table.
            if tableMissing() { Task { await measureTable() } }
        }
        return contexts[space]?[item.id] != nil
    }

    public func unload(_ id: String, in space: UUID) {
        let key = "\(space.uuidString)/\(id)"
        loadAttempts[key] = nil
        resetRecovery(key)
        unwatch(id, space)
        guard let context = contexts[space]?.removeValue(forKey: id) else { return }
        // A keep-awake it asked for (power) goes with it.
        host.releaseExtensionLoadPower(key)
        // Its popup and panel first, while WebKit can still be told they
        // close, as it was told they opened.
        host.closeExtensionLoadPopup(id, in: space)
        host.closeExtensionLoadSidePanel(id, in: space)
        release("popup windows") { ExtensionPopupWindow.closeAll(of: id, in: space) }
        release("capture") { capture().purge(id, in: space) }
        if let controller = controllers[space] {
            if let unloadForTesting { try? unloadForTesting(controller, context) }
            else { try? controller.unload(context) }
        }
        clearEvidence(id, space)
        // What it kept going outside WebKit goes with it: its offscreen
        // page; and its hosts once WebKit has had a turn to let its ports go.
        release("offscreen") { ExtensionOffscreen.close(id, in: space) }
        release("socket") { ExtensionSocket.close(id, in: space) }
        let releaseForTesting = releaseForTesting
        DispatchQueue.main.async {
            if let releaseForTesting { releaseForTesting("native") }
            else { ExtensionNative.stopOrphans() }
        }
    }

    private func release(_ resource: String, perform: () -> Void) {
        if let releaseForTesting { releaseForTesting(resource) }
        else { perform() }
    }

    /// What the extension may do: what it asked for, less cookies unless
    /// the person allowed them; its sites when the person chose all of
    /// them; never Google's sign-in.
    public func allow(_ context: WKWebExtensionContext, _ package: WKWebExtension, access: WebExtensionInstallation.SiteAccess, cookies: Bool) {
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
    public static func holdCookies(_ context: WKWebExtensionContext, letting cookies: Bool) {
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
    public static func letRulesRedirect(_ context: WKWebExtensionContext, _ package: WKWebExtension) {
        guard package.requestedPermissions.contains(.declarativeNetRequest) else { return }
        context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
    }

    /// The sites to grant of those an extension names: none withheld, and
    /// none a wildcard of the same scheme and path already covers. WebKit
    /// copies an extension's injected scripts for each pattern granted, so
    /// one naming many hosts beside a wildcard took that much more memory.
    /// (Search's d24ceca)
    public static func sites(of package: WKWebExtension) -> [WKWebExtension.MatchPattern] {
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
    nonisolated public static func withheld(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        guard let scheme = pattern.scheme?.lowercased() else { return false }
        return [Self.scheme, "webkit-extension", "file"].contains(scheme)
    }

    /// Whether an address is a page of an extension other than this one,
    /// which it never sees into.
    nonisolated public static func othersPage(_ url: URL?, for context: WKWebExtensionContext) -> Bool {
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
    public static func fence(_ context: WKWebExtensionContext) {
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
        if Self.asks(context, for: "identity"),
           let own = try? WKWebExtension.MatchPattern(string: "https://\(context.uniqueIdentifier.lowercased()).chromiumapp.org/*") {
            context.setPermissionStatus(.grantedExplicitly, for: own)
        }
    }

    private static func asks(_ context: WKWebExtensionContext, for permission: String) -> Bool {
        let manifest = context.webExtension.manifest
        if (manifest["permissions"] as? [String] ?? []).contains(permission) { return true }
        return (manifest["optional_permissions"] as? [String] ?? []).contains(permission)
            && context.permissionStatus(for: WKWebExtension.Permission(rawValue: permission)) == .grantedExplicitly
    }

    public func setSiteAccess(_ id: String, _ access: WebExtensionInstallation.SiteAccess) {
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

    public func setReadsCookies(_ id: String, _ on: Bool, changed: (UUID) -> Void) {
        for (space, loaded) in contexts {
            guard let context = loaded[id] else { continue }
            Self.holdCookies(context, letting: on)
            changed(space)
        }
    }
}
#endif
