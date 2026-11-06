#if os(macOS)
import AppKit
import WebEngineAppKit
import XCTest
@testable import WebKitExtensions

/// Restart fixtures share these values without writing real preferences.
private final class CleanupPreferencesStore {
    let lock = NSLock()
    var values: [String: Any] = [:]
}

private final class CleanupDefaults: UserDefaults {
    let store: CleanupPreferencesStore
    init(store: CleanupPreferencesStore = CleanupPreferencesStore()) {
        self.store = store
        super.init(suiteName: "extension-cleanup-fixture")!
    }
    override func stringArray(forKey name: String) -> [String]? {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.values[name] as? [String]
    }
    override func set(_ value: Any?, forKey name: String) {
        store.lock.lock()
        defer { store.lock.unlock() }
        store.values[name] = value
    }
}

@MainActor
private final class CleanupLog {
    var calls: [String] = []
}

@MainActor
private final class CleanupHost: ExtensionCleanupHost {
    let browser = BrowserHost()
    let log: CleanupLog
    var spaces: Set<UUID> = []
    var installed = false
    var enabled: [String] = []
    var catalogChecked: (() -> Void)?
    var swept: (() -> Void)?
    init(_ log: CleanupLog) { self.log = log }
    func extensionSpaceExists(_ space: UUID) -> Bool { spaces.contains(space) }
    func extensionCleanupIsInstalled(_ id: String) -> Bool {
        log.calls.append("catalog check")
        catalogChecked?()
        return installed
    }
    func extensionCleanupIDs(in space: UUID) -> [String] { enabled }
    func removeExtensionCleanupMembership(in space: UUID) {
        log.calls.append("membership and save")
        enabled = []
    }
    func clearExtensionCleanupVerdicts(in space: UUID) { log.calls.append("verdicts") }
    func closeExtensionCleanupPages(of id: String, in space: UUID) { log.calls.append("tabs and popup:\(id)") }
    func closeExtensionCleanupPopups(in space: UUID) { log.calls.append("popups") }
    func closeExtensionCleanupSidePanels(in space: UUID) { log.calls.append("panels") }
    func scheduleExtensionCleanupStoreSweep() { log.calls.append("schedule sweep"); swept?() }
    func noteExtensionCleanup(_ message: () -> String) {}
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

/// No WebKit objects, stores, files, network connections or native hosts.
@MainActor
private final class CleanupBackend: ExtensionCleanupBackend {
    let log: CleanupLog
    var results: [Bool] = []
    var hold = false
    var waiting: [CheckedContinuation<Bool, Never>] = []
    var began: (() -> Void)?
    var loaded: [String] = []
    var deletion: CleanupSpaceDeletion?
    var removedPackage: (() -> Void)?
    init(_ log: CleanupLog) { self.log = log }
    func removeGeneratedFiles(_ id: String, in space: UUID) { log.calls.append("generated:\(id)") }
    func clear(_ id: String, in space: UUID) async -> Bool {
        log.calls.append("clear:\(id)")
        if hold {
            return await withCheckedContinuation {
                waiting.append($0)
                began?()
            }
        }
        began?()
        return results.isEmpty ? true : results.removeFirst()
    }
    func unload(_ id: String, in space: UUID) { log.calls.append("unload:\(id)") }
    func loadedIDs(in space: UUID) -> [String] { loaded }
    func closeOffscreen(_ id: String, in space: UUID) { log.calls.append("offscreen:\(id)") }
    func closeAllOffscreen(in space: UUID) { log.calls.append("offscreen all") }
    func closeSockets(in space: UUID) { log.calls.append("sockets") }
    func clearWatches(in space: UUID) { log.calls.append("watches") }
    func removeController(for space: UUID) -> (any ExtensionSpaceDeletion)? {
        log.calls.append("remove controller")
        defer { deletion = nil }
        return deletion
    }
    func clearContexts(in space: UUID) { log.calls.append("contexts") }
    func clearEvidence(in space: UUID) { log.calls.append("evidence") }
    func removePackage(_ id: String) { log.calls.append("package:\(id)"); removedPackage?() }
}

@MainActor
private final class CleanupSpaceDeletion: ExtensionSpaceDeletion {
    let log: CleanupLog
    var waiting: CheckedContinuation<Void, Never>?
    var began: (() -> Void)?
    init(_ log: CleanupLog) { self.log = log }
    func removeData() async {
        log.calls.append("data records")
        await withCheckedContinuation { waiting = $0; began?() }
        log.calls.append("remove data done")
    }
}

private final class CleanupWeak<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

final class ExtensionCleanupTests: XCTestCase {
    private let id = String(repeating: "a", count: 32)


    @MainActor func testFailedMarkersSurviveNewRuntimeAndResumeBeforeLoading() async {
        let defaults = CleanupDefaults()
        let space = UUID(), key = "\(space.uuidString)/\(id)", log = CleanupLog(), host = CleanupHost(log)
        host.spaces = [space]
        let first = CleanupBackend(log)
        first.results = [false]
        var runtime: WebKitExtensionCleanup? = .init(host: host, backend: first, defaults: defaults)
        await runtime!.forget(id, in: space).value
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [key])
        let previous = CleanupWeak(runtime)
        runtime = nil
        XCTAssertNil(previous.value)
        let second = CleanupBackend(log)
        second.hold = true
        let resumed = WebKitExtensionCleanup(host: host, backend: second, defaults: CleanupDefaults(store: defaults.store))
        let began = expectation(description: "resumed deletion")
        second.began = { began.fulfill() }
        resumed.forgetLeftOver()
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [key])
        second.waiting.removeFirst().resume(returning: true)
        let cleared = await resumed.cleared(id, in: space)
        XCTAssertTrue(cleared)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [])
        XCTAssertEqual(log.calls.filter { $0 == "clear:\(id)" }.count, 2)
    }

    @MainActor func testLeftoversKeepMalformedMarkersAndDropOnlyGoneSpaces() async {
        let defaults = CleanupDefaults()
        let space = UUID(), gone = UUID(), log = CleanupLog(), host = CleanupHost(log), backend = CleanupBackend(log)
        host.spaces = [space]
        let valid = "\(space.uuidString)/\(id)", absent = "\(gone.uuidString)/\(id)"
        let malformed = ["bad", "not-a-space/\(id)", "\(space.uuidString)/invalid"]
        defaults.set(malformed + [absent, valid], forKey: "extensionsForgetting")
        backend.hold = true
        let runtime = WebKitExtensionCleanup(host: host, backend: backend, defaults: defaults)
        let began = expectation(description: "valid leftover")
        backend.began = { began.fulfill() }
        runtime.forgetLeftOver()
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), malformed + [valid])
        backend.waiting.removeFirst().resume(returning: true)
        let cleared = await runtime.cleared(id, in: space)
        XCTAssertTrue(cleared)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), malformed)
    }

    @MainActor func testClearedRetriesOnceAndKeepsFailedRetryOut() async {
        let defaults = CleanupDefaults()
        let space = UUID(), key = "\(space.uuidString)/\(id)", log = CleanupLog(), host = CleanupHost(log), backend = CleanupBackend(log)
        host.spaces = [space]
        backend.results = [false, false, true]
        let runtime = WebKitExtensionCleanup(host: host, backend: backend, defaults: defaults)
        await runtime.forget(id, in: space).value
        let failed = await runtime.cleared(id, in: space)
        XCTAssertFalse(failed)
        XCTAssertEqual(log.calls.filter { $0 == "clear:\(id)" }.count, 2)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [key])
        let retried = await runtime.cleared(id, in: space)
        XCTAssertTrue(retried)
        XCTAssertEqual(log.calls.filter { $0 == "clear:\(id)" }.count, 3)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [])
        let alreadyClear = await runtime.cleared(id, in: space)
        XCTAssertTrue(alreadyClear)
        XCTAssertEqual(log.calls.filter { $0 == "clear:\(id)" }.count, 3)
    }

    @MainActor func testReinstallWaitsForRunningClearAndKeepsPackage() async {
        let defaults = CleanupDefaults()
        let space = UUID(), key = "\(space.uuidString)/\(id)", log = CleanupLog(), host = CleanupHost(log), backend = CleanupBackend(log)
        host.spaces = [space]
        backend.hold = true
        let runtime = WebKitExtensionCleanup(host: host, backend: backend, defaults: defaults)
        let began = expectation(description: "clearing"), checked = expectation(description: "catalog rechecked")
        backend.began = { began.fulfill() }
        host.catalogChecked = { checked.fulfill() }
        runtime.removePackages(id, afterClearing: [space])
        await fulfillment(of: [began], timeout: 2)
        host.installed = true
        var mayLoad = false
        let loading = Task { mayLoad = await runtime.cleared(id, in: space) }
        // A second forget shares the running deletion and marker.
        let same = runtime.forget(id, in: space)
        await Task.yield()
        XCTAssertFalse(mayLoad)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [key])
        XCTAssertEqual(backend.waiting.count, 1)
        backend.waiting.removeFirst().resume(returning: true)
        await same.value
        await loading.value
        XCTAssertTrue(mayLoad)
        // Wait for the package-removal task to finish its catalog check.
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertFalse(log.calls.contains("package:\(id)"))
        XCTAssertEqual(log.calls.filter { $0 == "clear:\(id)" }.count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [])
    }

    @MainActor func testRemoveFromSpaceClosesBeforeRecordDeletionAndMarksSynchronously() async {
        let defaults = CleanupDefaults()
        let space = UUID(), log = CleanupLog(), host = CleanupHost(log), backend = CleanupBackend(log)
        host.spaces = [space]
        let runtime = WebKitExtensionCleanup(host: host, backend: backend, defaults: defaults)
        runtime.remove(id, from: space)
        XCTAssertEqual(log.calls, ["unload:\(id)", "tabs and popup:\(id)", "offscreen:\(id)"])
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), ["\(space.uuidString)/\(id)"])
        let cleared = await runtime.cleared(id, in: space)
        XCTAssertTrue(cleared)
        XCTAssertEqual(log.calls, ["unload:\(id)", "tabs and popup:\(id)", "offscreen:\(id)",
                                   "generated:\(id)", "tabs and popup:\(id)", "offscreen:\(id)", "clear:\(id)"])
    }

    @MainActor func testSpaceRemovalKeepsControllerUntilDeletionAndSchedulesSweepLast() async {
        let defaults = CleanupDefaults()
        let space = UUID(), log = CleanupLog(), host = CleanupHost(log), backend = CleanupBackend(log)
        host.enabled = [id, "disabled but kept"]
        backend.loaded = [id]
        var deletion: CleanupSpaceDeletion? = CleanupSpaceDeletion(log)
        let retained = CleanupWeak(deletion)
        let began = expectation(description: "store deletion"), swept = expectation(description: "sweep requested")
        deletion!.began = { began.fulfill() }
        backend.deletion = deletion
        host.swept = { swept.fulfill() }
        let runtime = WebKitExtensionCleanup(host: host, backend: backend, defaults: defaults)
        runtime.removeSpace(space)
        XCTAssertEqual(log.calls, ["unload:\(id)", "offscreen all", "sockets", "popups", "panels", "watches",
                                   "generated:\(id)", "generated:disabled but kept", "membership and save",
                                   "remove controller", "contexts", "verdicts", "evidence"])
        deletion = nil
        XCTAssertNotNil(retained.value)
        await fulfillment(of: [began], timeout: 2)
        XCTAssertFalse(log.calls.contains("schedule sweep"))
        retained.value!.waiting!.resume()
        await fulfillment(of: [swept], timeout: 2)
        for _ in 0..<1000 where retained.value != nil { await Task.yield() }
        XCTAssertNil(retained.value)
        XCTAssertEqual(Array(log.calls.suffix(3)), ["data records", "remove data done", "schedule sweep"])
    }

    @MainActor func testMissingControllerDoesNotScheduleSweepAndGoneSpaceOnlyClearsGeneratedFiles() async {
        let defaults = CleanupDefaults()
        let space = UUID(), log = CleanupLog(), host = CleanupHost(log), backend = CleanupBackend(log)
        let runtime = WebKitExtensionCleanup(host: host, backend: backend, defaults: defaults)
        runtime.removeSpace(space)
        XCTAssertEqual(log.calls, ["offscreen all", "sockets", "popups", "panels", "watches",
                                   "membership and save", "remove controller", "contexts", "verdicts", "evidence"])
        log.calls = []
        await runtime.forget(id, in: space).value
        XCTAssertEqual(log.calls, ["generated:\(id)"])
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting"), [])
    }

    @MainActor func testPackageDeletionWaitsForEverySpaceEvenWhenOneClearFailed() async {
        let defaults = CleanupDefaults()
        let first = UUID(), second = UUID(), log = CleanupLog(), host = CleanupHost(log), backend = CleanupBackend(log)
        host.spaces = [first, second]
        backend.hold = true
        let runtime = WebKitExtensionCleanup(host: host, backend: backend, defaults: defaults)
        let began = expectation(description: "both spaces"), removed = expectation(description: "package removed")
        began.expectedFulfillmentCount = 2
        backend.began = { began.fulfill() }
        backend.removedPackage = { removed.fulfill() }
        runtime.removePackages(id, afterClearing: [first, second])
        await fulfillment(of: [began], timeout: 2)
        backend.waiting.removeFirst().resume(returning: false)
        await Task.yield()
        XCTAssertFalse(log.calls.contains("catalog check"))
        backend.waiting.removeFirst().resume(returning: true)
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(defaults.stringArray(forKey: "extensionsForgetting")?.count, 1)
        XCTAssertEqual(Array(log.calls.suffix(2)), ["catalog check", "package:\(id)"])
    }
}
#endif
