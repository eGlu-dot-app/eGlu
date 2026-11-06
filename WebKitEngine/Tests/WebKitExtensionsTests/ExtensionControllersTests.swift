#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

@MainActor
private final class GrantContext: WKWebExtensionContext {
    var writes: [(String, PermissionStatus)] = []
    override func setPermissionStatus(_ status: PermissionStatus, for pattern: WKWebExtension.MatchPattern) {
        writes.append((pattern.string, status))
        super.setPermissionStatus(status, for: pattern)
    }
}

private final class ControllerDelegate: NSObject, WKWebExtensionControllerDelegate {}

/// Every path is under a temporary fixture; prepare never reads a real archive.
private final class ControllerStorage: WebExtensionStorage, @unchecked Sendable {
    let root: URL
    init(_ root: URL) { self.root = root }
    @MainActor var recordsFile: URL { root.appendingPathComponent("records.json") }
    @MainActor func package(_ id: String, _ version: String) -> URL { root.appendingPathComponent("\(id)-\(version).zip") }
    @MainActor func prepared(_ id: String, _ version: String) -> URL { root }
    nonisolated func prepare(_ package: URL, into folder: URL) throws { fatalError("Fixture must intercept preparation") }
}

@MainActor
private final class ControllerHost: ExtensionControllerHost {
    let browser = BrowserHost()
    let delegate = ControllerDelegate()
    let space = UUID()
    var item: WebExtensionInstallation?
    var exists = true
    var incompatible = false
    var cleared = true
    var log: [String] = []
    var installationQueries = 0
    var clearWait: CheckedContinuation<Bool, Never>?
    var holdClear = false
    var duringPopupClose: (() -> Void)?
    var captures: ExtensionCaptureRuntime!

    init() {
        item = .init(id: "fixture", name: "Original name", version: "1", source: .file,
                     siteAccess: .onClick, spaces: [space])
        captures = ExtensionCaptureRuntime(scheme: "chrome-extension", host: ControllerCaptureHost(), space: { _ in nil },
                                          context: { _, _ in nil }, declares: { _ in false }, watchEvents: false)
    }

    func runtime(_ root: URL) -> WebKitExtensionControllers {
        let runtime = WebKitExtensionControllers(host: self, storage: ControllerStorage(root),
            delegate: { [unowned self] in self.delegate }, capture: { [unowned self] in self.captures },
            watch: { [unowned self] _, _, _ in self.log.append("watch") },
            unwatch: { [unowned self] _, _ in self.log.append("unwatch") },
            applyKeys: { [unowned self] _ in self.log.append("keys") },
            firstLook: { [unowned self] _, _, _, _ in
                self.log.append("first look")
                var seen = WebExtensionEvidence()
                seen.start = .checking
                return seen
            },
            record: { [unowned self] _, _, _ in self.log.append("record") },
            readCode: { [unowned self] _ in self.log.append("read code") },
            startBackground: { [unowned self] _, _, _ in self.log.append("background") },
            checkCopy: { [unowned self] _ in self.log.append("check copy") }, tableMissing: { false },
            measureTable: { XCTFail("No table measurement in fixture") },
            resetRecovery: { [unowned self] _ in self.log.append("reset recovery") },
            clearEvidence: { [unowned self] _, _ in self.log.append("clear evidence") })
        runtime.configurationForTesting = { _ in ExtensionTrial.throwaway() }
        runtime.preparedForTesting = { _, _ in }
        runtime.loadForTesting = { [unowned self] _, context in
            XCTAssertFalse(context.isLoaded)
            self.log.append("load")
        }
        runtime.unloadForTesting = { [unowned self] _, context in
            XCTAssertFalse(context.isLoaded)
            self.log.append("unload")
        }
        runtime.releaseForTesting = { [unowned self] in self.log.append($0) }
        return runtime
    }

    func extensionInstallation(_ id: String) -> WebExtensionInstallation? { installationQueries += 1; return item }
    func extensionSpaceExists(_ space: UUID) -> Bool { exists }
    func extensionIsIncompatible(_ id: String) -> Bool { incompatible }
    func extensionCleared(_ id: String, in space: UUID) async -> Bool {
        if holdClear { return await withCheckedContinuation { clearWait = $0 } }
        return cleared
    }
    func markExtensionLoadIncompatible(_ id: String, version: String) { log.append("incompatible") }
    func releaseExtensionLoadPower(_ key: String) { log.append("power") }
    func closeExtensionLoadPopup(_ id: String, in space: UUID) { log.append("popup"); duringPopupClose?() }
    func closeExtensionLoadSidePanel(_ id: String, in space: UUID) { log.append("side panel") }
    func clearExtensionLoadVerdict(_ id: String, in space: UUID) { log.append("verdict") }
    func noteExtensionLoadFailure(_ error: any Error) { log.append("failure note") }
    var extensionControllerMockCapture: Bool { false }

    var workspace: ExtensionBrowserWorkspace { browser.workspace }
    func observe(workspace: @escaping @MainActor (ExtensionBrowserWorkspace) -> Void, focus: @escaping @MainActor (ExtensionBrowserFocus) -> Void) {}
    func record(_ tab: UUID) -> ExtensionBrowserTab? { nil }
    func livePage(_ tab: UUID) -> ExtensionBrowserPage? { nil }
    func window(in space: UUID) -> ExtensionBrowserWindow { browser.window(in: space) }
    func isFocused(in space: UUID) -> Bool { false }
    func openTab(_ url: URL?, in space: UUID, active: Bool, pinned: Bool, extensionID: () -> String, configuration: () -> (any ExtensionPageConfiguration)?) -> UUID? { nil }
    func activateTab(_ tab: UUID, in space: UUID) {}
    func closeTab(_ tab: UUID) {}
    func loadTab(_ tab: UUID, in space: UUID, url: URL) {}
    func reloadTab(_ tab: UUID, fromOrigin: Bool) {}
    func goBack(_ tab: UUID) {}
    func goForward(_ tab: UUID) {}
    func detectLocale(_ tab: UUID, in space: UUID, hasAccess: @escaping @MainActor (URL) -> Bool, completionHandler: @escaping (Locale?, (any Error)?) -> Void) {}
    func setWindowFrame(_ frame: CGRect, in space: UUID) {}
    func focusWindow(in space: UUID) {}
    func closeWindow(in space: UUID) -> (any Error)? { nil }
    func ensureWindow(in space: UUID) {}
    func privateWindowRefusal() -> any Error { NSError(domain: "fixture", code: 1) }
    func openPopup(in space: UUID, configuration: (any ExtensionPageConfiguration)?, frame: CGRect, closed: @escaping @MainActor () -> Void) -> UUID { UUID() }
    func startPopup(_ popup: UUID, url: URL) {}
    func popupPage(_ popup: UUID) -> ExtensionBrowserPage? { nil }
    func popupWindow(_ popup: UUID) -> ExtensionBrowserWindow { browser.window(in: popup) }
    func loadPopup(_ popup: UUID, url: URL) -> (any Error)? { nil }
    func reloadPopup(_ popup: UUID, fromOrigin: Bool) {}
    func goBackInPopup(_ popup: UUID) {}
    func goForwardInPopup(_ popup: UUID) {}
    func setPopupFrame(_ frame: CGRect, popup: UUID) {}
    func focusPopup(_ popup: UUID) {}
    func closePopup(_ popup: UUID) {}
    func refocusFrontWindow() {}
    func releaseExtensionPage(_ view: NSView) {}
    func extensionDisplayDecision(for view: NSView) -> Int { 0 }
    func watchExtensionPage(_ view: NSView, id: String) {}
    func requestExtensionMedia(_ media: ExtensionPageMedia, name: String, reply: @escaping @MainActor (Bool) -> Void) { reply(false) }
}

@MainActor
private final class ControllerCaptureHost: ExtensionCaptureHost {
    func setExtensionCaptureStop(_ stop: @escaping (String) -> Void) {}
    func extensionCaptureAllowed(_ id: String) -> Bool { false }
    func requestExtensionCapture(_ id: String, in space: UUID, used: () -> Bool, name: () -> String) async -> Bool { false }
    func bringExtensionCaptureForward(_ view: NSView) {}
    func lendExtensionCaptureView(_ view: NSView) {}
    func giveBackExtensionCaptureView(_ view: NSView) {}
    func extensionCaptureName(_ id: String) -> String { "Fixture" }
    func updateExtensionCapture(_ lines: [ExtensionCaptureState]) {}
}

final class ExtensionControllersTests: XCTestCase {
    @MainActor private func folder(_ manifest: String = #"{"manifest_version":3,"name":"Fixture","version":"1"}"#) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controller-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))
        WebKitExtensionControllers.registerScheme()
        return root
    }

    @MainActor private func context(_ root: URL, id: String = "fixture") async throws -> GrantContext {
        let package = try await WKWebExtension(resourceBaseURL: root)
        let context = GrantContext(for: package)
        context.uniqueIdentifier = id
        context.baseURL = URL(string: "chrome-extension://\(id)/")!
        XCTAssertFalse(context.isLoaded)
        return context
    }

    @MainActor func testOneControllerPerSpaceWithItsStoreDelegateAndRegistry() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ControllerHost(), runtime = host.runtime(root), second = UUID()
        var stores: [UUID: WKWebsiteDataStore] = [:]
        runtime.configurationForTesting = { space in
            let configuration = ExtensionTrial.throwaway()
            stores[space] = configuration.defaultWebsiteDataStore
            return configuration
        }
        let first = runtime.controller(for: host.space), other = runtime.controller(for: second)
        XCTAssertTrue(first === runtime.controller(for: host.space))
        XCTAssertFalse(first === other)
        XCTAssertFalse(first.configuration.isPersistent)
        XCTAssertFalse(other.configuration.isPersistent)
        XCTAssertTrue(first.configuration.defaultWebsiteDataStore === stores[host.space])
        XCTAssertTrue(other.configuration.defaultWebsiteDataStore === stores[second])
        XCTAssertFalse(stores[host.space] === stores[second])
        XCTAssertFalse(first.configuration.defaultWebsiteDataStore!.isPersistent)
        XCTAssertTrue(first.delegate === host.delegate)
        XCTAssertEqual(runtime.space(of: first), host.space)
        XCTAssertEqual(runtime.space(of: other), second)
        XCTAssertNil(runtime.space(of: nil))
        let a = try await context(root), b = try await context(root)
        runtime.contexts[host.space] = ["fixture": a]
        runtime.contexts[second] = ["fixture": b]
        XCTAssertTrue(runtime.context("fixture", in: host.space) === a)
        XCTAssertTrue(runtime.context("fixture", in: second) === b)
        XCTAssertTrue(runtime.isLoaded("fixture", in: host.space))
        XCTAssertFalse(runtime.isLoaded("missing", in: host.space))
        XCTAssertEqual(runtime.extensionID(for: a.baseURL), "fixture")
        XCTAssertNil(runtime.extensionID(for: URL(string: "https://fixture/")))
        XCTAssertNil(runtime.extensionID(for: nil))
        XCTAssertTrue(first.extensionContexts.isEmpty)
        XCTAssertTrue(other.extensionContexts.isEmpty)
    }

    @MainActor func testChangedInstallationDuringPreparationDropsLoad() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for change in ["removed", "version", "source", "disabled", "space gone", "unloaded"] {
            let host = ControllerHost(), runtime = host.runtime(root), original = try XCTUnwrap(host.item)
            var ready: CheckedContinuation<Void, Never>?
            runtime.preparedForTesting = { _, _ in await withCheckedContinuation { ready = $0 } }
            let task = Task { await runtime.load(original, in: host.space) }
            for _ in 0..<1000 where ready == nil { await Task.yield() }
            let resume = try XCTUnwrap(ready)
            XCTAssertEqual(host.installationQueries, 0)
            switch change {
            case "removed": host.item = nil
            case "version": host.item = .init(id: original.id, name: original.name, version: "2", source: .file, siteAccess: .onClick, spaces: [host.space])
            case "source": host.item = .init(id: original.id, name: original.name, version: "1", source: .unsigned, siteAccess: .onClick, spaces: [host.space])
            case "disabled": host.item = .init(id: original.id, name: original.name, version: "1", source: .file, siteAccess: .onClick, spaces: [])
            case "space gone": host.exists = false
            default: runtime.unload(original.id, in: host.space); host.log = []
            }
            resume.resume()
            let loaded = await task.value
            XCTAssertFalse(loaded, change)
            XCTAssertTrue(runtime.contexts.isEmpty, change)
            XCTAssertTrue(runtime.controllers.isEmpty, change)
            XCTAssertTrue(host.log.isEmpty, change)
        }
    }

    @MainActor func testLoadKeepsOriginalAccessButReadsCurrentCookiesAndRunsHooksInOrder() async throws {
        let root = try folder(#"{"manifest_version":3,"name":"Fixture","version":"1","permissions":["cookies"],"host_permissions":["https://example.invalid/*"]}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ControllerHost(), runtime = host.runtime(root), original = try XCTUnwrap(host.item)
        runtime.preparedForTesting = { _, _ in
            host.item = .init(id: original.id, name: "New name", version: original.version, source: original.source,
                              siteAccess: .allSites, spaces: [host.space, UUID()], readsCookies: true)
        }
        runtime.loadForTesting = { _, context in
            host.log.append("load")
            XCTAssertEqual(context.inspectionName, original.name)
            XCTAssertEqual(context.permissionStatus(for: .cookies), .grantedExplicitly)
            XCTAssertNotEqual(context.permissionStatus(for: URL(string: "https://example.invalid/page")!), .grantedExplicitly)
            XCTAssertNil(runtime.context(original.id, in: host.space))
        }
        let loaded = await runtime.load(original, in: host.space)
        XCTAssertTrue(loaded)
        XCTAssertEqual(host.log, ["watch", "load", "keys", "first look", "record", "read code", "background", "check copy"])
        XCTAssertEqual(host.installationQueries, 1)
        XCTAssertFalse(try XCTUnwrap(runtime.context(original.id, in: host.space)).isLoaded)
        runtime.loadForTesting = nil
    }

    @MainActor func testClearWaitKeepsOriginalCheckPointsAndFailedAttemptIsDroppedAfterUnload() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ControllerHost(), runtime = host.runtime(root), original = try XCTUnwrap(host.item)
        host.holdClear = true
        var preparations = 0
        runtime.preparedForTesting = { _, _ in preparations += 1 }
        let task = Task { await runtime.load(original, in: host.space) }
        for _ in 0..<1000 where host.clearWait == nil { await Task.yield() }
        let resume = try XCTUnwrap(host.clearWait)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(host.installationQueries, 0)
        host.item = nil
        resume.resume(returning: true)
        let dropped = await task.value
        XCTAssertFalse(dropped)
        // The original checks the catalog after both preparation and reading,
        // even when the catalog changed during the earlier clearing wait.
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(host.installationQueries, 1)
        host.item = original
        host.holdClear = false
        runtime.loadForTesting = { _, _ in throw NSError(domain: "fixture", code: 1) }
        let failed = await runtime.load(original, in: host.space)
        XCTAssertFalse(failed)
        XCTAssertEqual(host.log, ["watch", "unwatch", "failure note", "record"])
        runtime.unload(original.id, in: host.space)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertFalse(host.log.contains("incompatible"))
    }

    @MainActor func testUnloadRemovesRegistryBeforePanesAndUnloadsBeforeRuntimeResources() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ControllerHost(), runtime = host.runtime(root)
        let context = try await context(root)
        _ = runtime.controller(for: host.space)
        runtime.contexts[host.space] = ["fixture": context]
        host.duringPopupClose = { XCTAssertNil(runtime.context("fixture", in: host.space)) }
        runtime.unload("fixture", in: host.space)
        XCTAssertEqual(host.log, ["reset recovery", "unwatch", "power", "popup", "side panel", "popup windows", "capture", "unload", "clear evidence", "offscreen", "socket"])
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(host.log.last, "native")
        XCTAssertNotNil(runtime.controllers[host.space])
        XCTAssertFalse(context.isLoaded)
        host.duringPopupClose = nil
        host.log = []
        runtime.unload("fixture", in: host.space)
        XCTAssertEqual(host.log, ["reset recovery", "unwatch"])
    }

    @MainActor func testGrantsCookiesRedirectsWithheldPatternsOthersPagesAndFence() async throws {
        let root = try folder(#"{"manifest_version":3,"name":"Fixture","version":"1","permissions":["tabs","declarativeNetRequest","identity"],"optional_permissions":["cookies"],"host_permissions":["<all_urls>","https://*.example.invalid/*","https://a.example.invalid/*","file:///*","chrome-extension://*/*"]}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ControllerHost(), runtime = host.runtime(root)
        let context = try await context(root)
        let pattern: (String) throws -> WKWebExtension.MatchPattern = { try WKWebExtension.MatchPattern(string: $0) }
        for value in ["file:///*", "chrome-extension://*/*", "webkit-extension://*/*"] {
            XCTAssertTrue(WebKitExtensionControllers.withheld(try pattern(value)))
        }
        XCTAssertFalse(WebKitExtensionControllers.withheld(try pattern("https://*/*")))
        let sites = Set(WebKitExtensionControllers.sites(of: context.webExtension).map(\.string))
        XCTAssertTrue(sites.contains("<all_urls>"))
        XCTAssertFalse(sites.contains("https://a.example.invalid/*"))
        XCTAssertFalse(sites.contains("file:///*"))
        XCTAssertFalse(sites.contains("chrome-extension://*/*"))
        runtime.allow(context, context.webExtension, access: .allSites, cookies: false)
        XCTAssertEqual(context.permissionStatus(for: .tabs), .grantedExplicitly)
        XCTAssertEqual(context.permissionStatus(for: .cookies), .deniedExplicitly)
        XCTAssertEqual(context.permissionStatus(for: .declarativeNetRequestWithHostAccess), .grantedExplicitly)
        XCTAssertEqual(context.permissionStatus(for: URL(string: "https://example.invalid/page")!), .grantedExplicitly)
        for site in ExtensionPolicy.deniedSites {
            XCTAssertEqual(context.permissionStatus(for: try pattern(site)), .deniedExplicitly)
        }
        for site in ["chrome-extension://*/*", "webkit-extension://*/*", "file:///*", "file://*/*"] {
            XCTAssertTrue(context.writes.contains { $0.0 == site && $0.1 == .deniedExplicitly }, site)
        }
        XCTAssertEqual(context.permissionStatus(for: try pattern("https://fixture.chromiumapp.org/*")), .grantedExplicitly)
        XCTAssertTrue(WebKitExtensionControllers.othersPage(URL(string: "chrome-extension://other/page"), for: context))
        XCTAssertTrue(WebKitExtensionControllers.othersPage(URL(string: "webkit-extension://OTHER/page"), for: context))
        XCTAssertFalse(WebKitExtensionControllers.othersPage(URL(string: "chrome-extension://FIXTURE/page"), for: context))
        XCTAssertFalse(WebKitExtensionControllers.othersPage(URL(string: "https://other/page"), for: context))
        XCTAssertFalse(WebKitExtensionControllers.othersPage(nil, for: context))
        runtime.contexts[host.space] = ["fixture": context]
        runtime.setReadsCookies("fixture", true) { space in
            XCTAssertEqual(space, host.space)
            XCTAssertEqual(context.permissionStatus(for: .cookies), .grantedExplicitly)
            host.log.append("cookie callback")
        }
        XCTAssertEqual(host.log, ["cookie callback"])
        context.writes = []
        runtime.setSiteAccess("fixture", .onClick)
        XCTAssertNotEqual(context.permissionStatus(for: URL(string: "https://example.invalid/page")!), .grantedExplicitly)
        XCTAssertTrue(context.writes.contains { $0.0 == "chrome-extension://*/*" && $0.1 == .deniedExplicitly })
        runtime.setSiteAccess("fixture", .allSites)
        XCTAssertEqual(context.permissionStatus(for: URL(string: "https://example.invalid/page")!), .grantedExplicitly)
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testCookieCallbacksInterleaveAcrossSpacesAndNothingKeepsTheRuntimeAlive() async throws {
        let root = try folder(#"{"manifest_version":3,"name":"Fixture","version":"1","permissions":["cookies"]}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ControllerHost()
        var runtime: WebKitExtensionControllers? = host.runtime(root)
        weak var observed = runtime
        let first = try await context(root), second = try await context(root)
        runtime!.contexts = [host.space: ["fixture": first], UUID(): ["fixture": second]]
        for context in [first, second] { WebKitExtensionControllers.holdCookies(context, letting: false) }
        var callbacks = 0
        runtime!.setReadsCookies("fixture", true) { _ in
            callbacks += 1
            let granted = [first, second].filter { $0.permissionStatus(for: .cookies) == .grantedExplicitly }.count
            XCTAssertEqual(granted, callbacks)
        }
        XCTAssertEqual(callbacks, 2)
        runtime = nil
        XCTAssertNil(observed)
    }

    @MainActor func testUnrequestedCookiesAndRedirectsStayUngranted() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ControllerHost(), runtime = host.runtime(root)
        let context = try await context(root)
        runtime.allow(context, context.webExtension, access: .onClick, cookies: true)
        XCTAssertEqual(context.permissionStatus(for: .cookies), .deniedExplicitly)
        XCTAssertNotEqual(context.permissionStatus(for: .declarativeNetRequestWithHostAccess), .grantedExplicitly)
        XCTAssertNotEqual(context.permissionStatus(for: URL(string: "https://example.invalid/page")!), .grantedExplicitly)
        XCTAssertFalse(context.isLoaded)
    }
}
#endif
