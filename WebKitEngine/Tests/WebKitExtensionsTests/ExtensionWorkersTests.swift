#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import XCTest
@testable import WebKitExtensions

// Every preference operation stays in memory, including all three worker keys.
private final class WorkerDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    var writes: [String] = []
    init() { super.init(suiteName: nil)! }
    override func dictionary(forKey name: String) -> [String: Any]? { values[name] as? [String: Any] }
    override func bool(forKey name: String) -> Bool { values[name] as? Bool ?? false }
    override func set(_ value: Any?, forKey name: String) { values[name] = value; writes.append(name) }
    override func removeObject(forKey name: String) { values[name] = nil; writes.append("remove:" + name) }
}

// No WebKit objects, windows, data stores, downloads or network operations.
@MainActor
private final class WorkerFixture: ExtensionWorkerHost, ExtensionWorkerBackend, ExtensionWorkerClock {
    let space = UUID()
    let contextObject = NSObject()
    let controllerObject = NSObject()
    let defaults = WorkerDefaults()
    var extensionWorkerSpaces: [UUID] = []
    var extensionWorkerInstallations: [WebExtensionWorkerInstallation] = []
    weak var observedRuntime: ExtensionWorkers?
    weak var observedContext: AnyObject?
    var current: AnyObject?
    var hasController = true
    var time = Date(timeIntervalSince1970: 1000)
    var timers: [(Date, () -> Void)] = []
    var completions: [(Error?) -> Void] = []
    var events: [WebExtensionWorkerEvent] = []
    var log: [String] = []
    var cleared: [UUID] = []
    var pendingClears: [UUID: CheckedContinuation<Void, Never>] = [:]
    var holdClears = false
    var throwOnUnload = false
    var throwOnLoad = false
    var duringLoad: (() -> Void)?
    var onMark: (() -> Void)?
    var start = "checking"
    var publications: [String] = []

    init() {
        current = contextObject
        extensionWorkerSpaces = [space]
        extensionWorkerInstallations = [.init(id: "fixture", version: "1", spaces: [space])]
    }
    var item: WebExtensionWorkerInstallation { extensionWorkerInstallations[0] }
    var key: String { "\(space.uuidString)/fixture" }
    var error: Error { NSError(domain: "worker-fixture", code: 1) }
    func runtime() -> ExtensionWorkers {
        ExtensionWorkers(host: self, backend: self, clock: self, defaults: defaults, shimStamp: { "shim" })
    }
    func context(_ id: String, in space: UUID) -> AnyObject? { current }
    func controller(in space: UUID) -> AnyObject? { hasController ? controllerObject : nil }
    func clearWorkers(in space: UUID) async {
        cleared.append(space)
        log.append("clear:\(space)")
        if holdClears { await withCheckedContinuation { pendingClears[space] = $0 } }
        log.append("cleared:\(space)")
    }
    func loadBackground(_ context: AnyObject, completion: @escaping (Error?) -> Void) {
        XCTAssertTrue(context === current)
        log.append("background")
        completions.append(completion)
    }
    func unload(_ context: AnyObject, from controller: AnyObject) throws {
        XCTAssertTrue(context === current)
        XCTAssertTrue(controller === controllerObject)
        log.append("unload")
        if throwOnUnload { throw error }
    }
    func load(_ context: AnyObject, into controller: AnyObject) throws {
        XCTAssertTrue(context === current)
        XCTAssertTrue(controller === controllerObject)
        log.append("load")
        duringLoad?()
        if throwOnLoad { throw error }
    }
    func closeOffscreen(_ id: String, in space: UUID) { log.append("offscreen") }
    func now() -> Date { time }
    func after(_ seconds: TimeInterval, perform: @escaping () -> Void) { timers.append((time.addingTimeInterval(seconds), perform)) }
    func advance(_ seconds: TimeInterval) {
        let end = time.addingTimeInterval(seconds)
        while let next = timers.enumerated().filter({ $0.element.0 <= end }).min(by: { $0.element.0 < $1.element.0 }) {
            let timer = timers.remove(at: next.offset)
            time = timer.0
            timer.1()
        }
        time = end
    }
    func extensionWorkerCheckStamp(_ version: String) -> String { "stamp " + version }
    func resetExtensionWorkerCompatibility(_ id: String) { log.append("reset:" + id) }
    func markExtensionWorkerIncompatible(_ id: String, version: String) {
        log.append("incompatible:" + id + ":" + version)
        onMark?()
    }
    func updateExtensionWorker(_ id: String, in space: UUID, event: WebExtensionWorkerEvent) {
        events.append(event)
        switch event {
        case .started: start = "started"
        case .failed: start = "failed"
        case .timedOutIfChecking: if start == "checking" { start = "timedOut" }
        }
        // The original update publishes even when its mutation is a no-op.
        publications.append(start)
    }
    func releaseExtensionWorkerPower(_ key: String) { log.append("power:" + key) }
    func noteExtensionWorker(_ line: String) { log.append("note:" + line) }

    var workspace: ExtensionBrowserWorkspace { .init(spaces: []) }
    func observe(workspace: @escaping @MainActor (ExtensionBrowserWorkspace) -> Void, focus: @escaping @MainActor (ExtensionBrowserFocus) -> Void) {}
    func record(_ tab: UUID) -> ExtensionBrowserTab? { nil }
    func livePage(_ tab: UUID) -> ExtensionBrowserPage? { nil }
    func window(in space: UUID) -> ExtensionBrowserWindow { fatalError("Unused fixture window") }
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
    func privateWindowRefusal() -> any Error { error }
    func openPopup(in space: UUID, configuration: (any ExtensionPageConfiguration)?, frame: CGRect, closed: @escaping @MainActor () -> Void) -> UUID { UUID() }
    func startPopup(_ popup: UUID, url: URL) {}
    func popupPage(_ popup: UUID) -> ExtensionBrowserPage? { nil }
    func popupWindow(_ popup: UUID) -> ExtensionBrowserWindow { fatalError("Unused fixture popup") }
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

final class ExtensionWorkersTests: XCTestCase {
    @MainActor
    func testFirstLaunchStampsSortAndRetainDisabledWorkers() async {
        let f = WorkerFixture(), other = UUID(), empty = UUID()
        f.extensionWorkerSpaces += [other, empty]
        f.extensionWorkerInstallations += [.init(id: "aaa", version: "2", spaces: [f.space])]
        let runtime = f.runtime()
        await runtime.forgetWorkersIfChanged()
        XCTAssertEqual(f.cleared, [f.space])
        XCTAssertEqual(f.defaults.values["extensionWorkers"] as? [String: String], [f.space.uuidString: "shim\naaa 2\nfixture 1"])
        XCTAssertEqual(f.defaults.writes, ["extensionWorkers", "remove:extensionWorkersForced", "extensionsWorkerFailed"])
        f.extensionWorkerInstallations = [.init(id: "fixture", version: "1", spaces: []), .init(id: "aaa", version: "2", spaces: [])]
        await runtime.forgetWorkersIfChanged()
        XCTAssertEqual(f.cleared, [f.space])
        f.extensionWorkerInstallations[0] = .init(id: "fixture", version: "2", spaces: [])
        await runtime.forgetWorkersIfChanged()
        XCTAssertEqual(f.cleared, [f.space, f.space])
        XCTAssertEqual((f.defaults.values["extensionWorkers"] as? [String: String])?[f.space.uuidString], "shim\naaa 2\nfixture 2")
    }

    @MainActor
    func testOnlyAddedAndRemovedExtensionsDoNotClearWebsiteWorkers() async {
        let f = WorkerFixture(), runtime = f.runtime()
        f.defaults.values["extensionWorkers"] = [f.space.uuidString: "shim\nfixture 1"]
        f.extensionWorkerInstallations.append(.init(id: "added", version: "1", spaces: [f.space]))
        await runtime.forgetWorkersIfChanged()
        XCTAssertTrue(f.cleared.isEmpty)
        f.extensionWorkerInstallations = []
        await runtime.forgetWorkersIfChanged()
        XCTAssertTrue(f.cleared.isEmpty)
        XCTAssertEqual(f.defaults.values["extensionWorkers"] as? [String: String], [:])
    }

    @MainActor
    func testChangedShimAndForcedClearingUseSameKeys() async {
        let f = WorkerFixture(), runtime = f.runtime()
        f.defaults.values["extensionWorkers"] = [f.space.uuidString: "old shim\nfixture 1"]
        await runtime.forgetWorkersIfChanged()
        XCTAssertEqual(f.cleared, [f.space])
        runtime.workersChanged()
        XCTAssertEqual(f.defaults.values["extensionWorkersForced"] as? Bool, true)
        await runtime.forgetWorkersIfChanged()
        XCTAssertEqual(f.cleared, [f.space, f.space])
        XCTAssertNil(f.defaults.values["extensionWorkersForced"])
    }

    @MainActor
    func testClearsWaitInSpaceOrderAndRetryOnlyOnceAfterCompletion() async throws {
        let f = WorkerFixture(), second = UUID(), runtime = f.runtime()
        f.extensionWorkerSpaces.append(second)
        f.extensionWorkerInstallations[0] = .init(id: "fixture", version: "1", spaces: [f.space, second])
        f.defaults.values["extensionsWorkerFailed"] = ["fixture": "stamp 1"]
        f.holdClears = true
        let task = Task { await runtime.forgetWorkersIfChanged() }
        for _ in 0..<1000 where f.pendingClears[f.space] == nil { await Task.yield() }
        let firstClear = try XCTUnwrap(f.pendingClears.removeValue(forKey: f.space))
        XCTAssertEqual(f.cleared, [f.space])
        XCTAssertFalse(f.log.contains("reset:fixture"))
        XCTAssertTrue(f.defaults.writes.isEmpty)
        // Keep the current space's original catalog snapshot across await,
        // but query the live catalog again for the next space. The ordered
        // space list itself was captured before the first clear.
        f.extensionWorkerInstallations[0] = .init(id: "fixture", version: "2", spaces: [second])
        f.extensionWorkerSpaces = []
        firstClear.resume()
        for _ in 0..<1000 where f.pendingClears[second] == nil { await Task.yield() }
        let secondClear = try XCTUnwrap(f.pendingClears.removeValue(forKey: second))
        XCTAssertEqual(f.cleared, [f.space, second])
        XCTAssertEqual(f.log, ["clear:\(f.space)", "cleared:\(f.space)", "reset:fixture", "clear:\(second)"])
        XCTAssertTrue(f.defaults.writes.isEmpty)
        secondClear.resume()
        await task.value
        XCTAssertEqual(f.defaults.values["extensionsWorkerFailed"] as? [String: String], ["fixture": "stamp 1 retried"])
        XCTAssertEqual(f.log.filter { $0 == "reset:fixture" }.count, 1)
        XCTAssertEqual(f.defaults.values["extensionWorkers"] as? [String: String],
                       [f.space.uuidString: "shim\nfixture 1", second.uuidString: "shim\nfixture 2"])
        f.extensionWorkerSpaces = [f.space, second]
        f.extensionWorkerInstallations[0] = .init(id: "fixture", version: "1", spaces: [f.space, second])
        runtime.workersChanged()
        f.holdClears = false
        await runtime.forgetWorkersIfChanged()
        XCTAssertEqual(f.log.filter { $0 == "reset:fixture" }.count, 1)
    }

    @MainActor
    func testTimeoutStillAllowsLateSuccessWithoutRetry() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.advance(4.999)
        XCTAssertTrue(f.events.isEmpty)
        f.advance(0.001)
        XCTAssertEqual(f.publications, ["timedOut"])
        f.advance(120)
        XCTAssertFalse(f.log.contains("unload"))
        f.completions[0](nil)
        XCTAssertEqual(f.publications, ["timedOut", "started"])
        f.advance(60)
        XCTAssertFalse(f.log.contains("unload"))
    }

    @MainActor
    func testSuccessSuppressesTimeoutAndCompletionStaysInline() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.completions[0](nil)
        XCTAssertEqual(f.publications, ["started"])
        f.advance(5)
        XCTAssertEqual(f.publications, ["started"])
    }

    @MainActor
    func testRetryWaitsTwoSecondsUsesSameObjectsAndCooldownIsStrictlyOverMinute() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.completions[0](f.error)
        XCTAssertEqual(f.publications, ["failed"])
        f.advance(1.999)
        XCTAssertFalse(f.log.contains("unload"))
        f.advance(0.001)
        XCTAssertEqual(f.log.filter { !$0.hasPrefix("note:") }, ["background", "offscreen", "power:" + f.key, "unload", "load", "background"])
        XCTAssertEqual(f.defaults.values["extensionWorkersForced"] as? Bool, true)
        XCTAssertFalse(runtime.revive("fixture", in: f.space, because: "too soon"))
        f.advance(60)
        XCTAssertFalse(runtime.revive("fixture", in: f.space, because: "exactly a minute"))
        f.advance(0.001)
        XCTAssertTrue(runtime.revive("fixture", in: f.space, because: "over a minute"))
    }

    @MainActor
    func testEarlierFailureDuringRetryCannotScheduleAnotherRestart() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        // As in errorsChanged, report an older WebKit error while load is in flight.
        let action = runtime.workerRecovery[f.key, default: ExtensionWorkerRecovery()].noticedHistoricalFailure()
        XCTAssertEqual(action, .restart)
        runtime.recover(action, context: f.contextObject, item: f.item, in: f.space)
        f.duringLoad = {
            let repeated = runtime.workerRecovery[f.key, default: ExtensionWorkerRecovery()].noticedHistoricalFailure()
            XCTAssertEqual(repeated, .ignore)
            runtime.recover(repeated, context: f.contextObject, item: f.item, in: f.space)
        }
        f.advance(2)
        f.completions[1](nil)
        f.advance(120)
        XCTAssertEqual(f.log.filter { $0 == "unload" }.count, 1)
        XCTAssertEqual(f.publications, ["started"])
        XCTAssertFalse(f.log.contains { $0.hasPrefix("incompatible:") })
        f.duringLoad = nil
    }

    @MainActor
    func testRetryFailureMarksIncompatibleBeforePersistingAndKeepsRetriedStamp() {
        let f = WorkerFixture(), runtime = f.runtime()
        f.onMark = {
            XCTAssertNil(f.defaults.values["extensionsWorkerFailed"])
            runtime.workerRecovery[f.key] = nil
        }
        XCTAssertTrue(runtime.restart("fixture", in: f.space, because: "fixture"))
        f.completions[0](f.error)
        XCTAssertEqual(f.log.last, "incompatible:fixture:1")
        XCTAssertEqual(f.defaults.values["extensionsWorkerFailed"] as? [String: String], ["fixture": "stamp 1"])
        XCTAssertEqual(f.defaults.writes, ["extensionWorkersForced", "extensionsWorkerFailed", "extensionWorkersForced"])
        f.onMark = nil
        f.defaults.values["extensionsWorkerFailed"] = ["fixture": "stamp 1 retried"]
        f.defaults.writes = []
        runtime.recover(.incompatible, context: f.contextObject, item: f.item, in: f.space)
        XCTAssertTrue(f.defaults.writes.isEmpty)
    }

    @MainActor
    func testControllerThrowsAtEitherOperationKeepsFailurePath() {
        for unloading in [true, false] {
            let f = WorkerFixture(), runtime = f.runtime()
            f.throwOnUnload = unloading
            f.throwOnLoad = !unloading
            XCTAssertTrue(runtime.restart("fixture", in: f.space, because: "fixture"))
            XCTAssertTrue(f.completions.isEmpty)
            XCTAssertEqual(f.publications, ["failed"])
            XCTAssertTrue(f.log.contains("incompatible:fixture:1"))
            XCTAssertEqual(f.log.contains("load"), !unloading)
        }
    }

    @MainActor
    func testObsoleteAttemptDropsCompletionTimeoutAndScheduledRetry() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.completions[0](f.error)
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.completions[0](nil)
        f.advance(2)
        XCTAssertEqual(f.publications, ["failed"])
        XCTAssertFalse(f.log.contains("unload"))
        f.advance(3)
        // The old timeout is dropped. The current one still calls update,
        // whose conditional mutation preserves the earlier failed state.
        XCTAssertEqual(f.publications, ["failed", "failed"])
        f.completions[1](nil)
        XCTAssertEqual(f.publications, ["failed", "failed", "started"])
    }

    @MainActor
    func testOnlyTheCurrentUnansweredAttemptTimesOut() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.advance(5)
        // Neither start has answered: the first attempt's timeout is dropped
        // by its attempt check, and only the current one tells the app.
        XCTAssertEqual(f.events, [.timedOutIfChecking])
    }

    @MainActor
    func testAReplacedContextsUnansweredStartDoesNotTimeOut() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.current = NSObject()
        f.advance(5)
        // The context identity check drops it.
        XCTAssertTrue(f.events.isEmpty)
    }

    @MainActor
    func testReplacementContextDropsCompletionTimeoutAndRetry() {
        let f = WorkerFixture(), runtime = f.runtime()
        runtime.startBackground(of: f.contextObject, f.item, in: f.space)
        f.completions[0](f.error)
        f.current = NSObject()
        f.completions[0](nil)
        f.advance(10)
        XCTAssertEqual(f.publications, ["failed"])
        XCTAssertFalse(f.log.contains("unload"))
        runtime.recover(.incompatible, context: f.contextObject, item: f.item, in: f.space)
        XCTAssertFalse(f.log.contains { $0.hasPrefix("incompatible:") })
    }

    @MainActor
    func testPendingCompletionAndTimersDoNotRetainContext() {
        let f = WorkerFixture(), runtime = f.runtime()
        var context: NSObject? = NSObject()
        f.current = context
        f.observedContext = context
        runtime.startBackground(of: context!, f.item, in: f.space)
        runtime.recover(.restart, context: context!, item: f.item, in: f.space)
        f.current = nil
        context = nil
        XCTAssertNil(f.observedContext)
        f.completions[0](nil)
        f.advance(10)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertFalse(f.log.contains("unload"))
    }

    @MainActor
    func testMissingRegistryAndReleasedRuntimeLeaveNoWorkOrRetainCycle() {
        let f = WorkerFixture()
        var runtime: ExtensionWorkers? = f.runtime()
        f.observedRuntime = runtime
        f.current = nil
        XCTAssertFalse(runtime!.revive("fixture", in: f.space, because: "removed"))
        f.current = f.contextObject
        f.hasController = false
        XCTAssertFalse(runtime!.restart("fixture", in: f.space, because: "removed"))
        runtime!.startBackground(of: f.contextObject, f.item, in: f.space)
        runtime = nil
        XCTAssertNil(f.observedRuntime)
        f.completions[0](nil)
        f.advance(10)
        XCTAssertTrue(f.events.isEmpty)
    }
}
#endif
