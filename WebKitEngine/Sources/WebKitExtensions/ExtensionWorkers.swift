#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit
import WebKit
import WebKitSupport

/// The backend borrows the current registry. It never makes a controller or
/// context. Tests use plain objects and controlled completions instead.
@MainActor
protocol ExtensionWorkerBackend: AnyObject {
    func context(_ id: String, in space: UUID) -> AnyObject?
    func controller(in space: UUID) -> AnyObject?
    func clearWorkers(in space: UUID) async
    func loadBackground(_ context: AnyObject, completion: @escaping (Error?) -> Void)
    func unload(_ context: AnyObject, from controller: AnyObject) throws
    func load(_ context: AnyObject, into controller: AnyObject) throws
    func closeOffscreen(_ id: String, in space: UUID)
}

@MainActor
protocol ExtensionWorkerClock: AnyObject {
    func now() -> Date
    func after(_ seconds: TimeInterval, perform: @escaping () -> Void)
}

@MainActor
private final class WorkerClock: ExtensionWorkerClock {
    func now() -> Date { Date() }
    func after(_ seconds: TimeInterval, perform: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { perform() }
    }
}

@MainActor
private final class WorkerBackend: ExtensionWorkerBackend {
    let contexts: () -> [UUID: [String: WKWebExtensionContext]]
    let controllers: () -> [UUID: WKWebExtensionController]

    init(contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
         controllers: @escaping () -> [UUID: WKWebExtensionController]) {
        self.contexts = contexts
        self.controllers = controllers
    }

    func context(_ id: String, in space: UUID) -> AnyObject? { contexts()[space]?[id] }
    func controller(in space: UUID) -> AnyObject? { controllers()[space] }
    func clearWorkers(in space: UUID) async {
        await WebKitStores.store(for: space).removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast)
    }
    func loadBackground(_ context: AnyObject, completion: @escaping (Error?) -> Void) {
        (context as! WKWebExtensionContext).loadBackgroundContent(completionHandler: completion)
    }
    func unload(_ context: AnyObject, from controller: AnyObject) throws {
        try (controller as! WKWebExtensionController).unload(context as! WKWebExtensionContext)
    }
    func load(_ context: AnyObject, into controller: AnyObject) throws {
        try (controller as! WKWebExtensionController).load(context as! WKWebExtensionContext)
    }
    func closeOffscreen(_ id: String, in space: UUID) { ExtensionOffscreen.close(id, in: space) }
}

/// The worker part of the runtime. Its actor is the original hub's actor;
/// callbacks keep their weak context and attempt checks and queue turns.
@MainActor
public final class ExtensionWorkers: WebExtensionWorkers {
    private let host: any ExtensionWorkerHost
    private let backend: any ExtensionWorkerBackend
    private let clock: any ExtensionWorkerClock
    private let defaults: UserDefaults
    private let shimStamp: () -> String

    // Forwarded by the hub until its error observer and unload move too.
    public var workerRecovery: [String: ExtensionWorkerRecovery] = [:]
    /// When each extension was last taken up afresh, by space and id: once a
    /// minute at most, so one that can never start doesn't go round.
    private var revived: [String: Date] = [:]

    public static func markWorkersChanged() {
        UserDefaults.standard.set(true, forKey: workersForcedKey)
    }

    public convenience init(host: any ExtensionWorkerHost,
                            contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
                            controllers: @escaping () -> [UUID: WKWebExtensionController]) {
        self.init(host: host, backend: WorkerBackend(contexts: contexts, controllers: controllers),
                  clock: WorkerClock(), defaults: .standard,
                  shimStamp: { ExtensionPreparation.stamp(for: Scripts.extensionShim) })
    }

    init(host: any ExtensionWorkerHost, backend: any ExtensionWorkerBackend,
         clock: any ExtensionWorkerClock, defaults: UserDefaults, shimStamp: @escaping () -> String) {
        self.host = host
        self.backend = backend
        self.clock = clock
        self.defaults = defaults
        self.shimStamp = shimStamp
    }

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
    public static let workersKey = "extensionWorkers"

    /// What a space's workers would run: the shim, and the extensions on there.
    /// Those on there now, and those on there before (`was`) that are still
    /// installed: one turned off keeps its worker registered in the space's
    /// store, and an update or a new shim can make that one stale too.
    private func workers(in space: UUID, keeping was: String?) -> String {
        let before = Set((was ?? "").split(separator: "\n").dropFirst().compactMap { $0.split(separator: " ").first.map(String.init) })
        let tracked = host.extensionWorkerInstallations.filter { $0.spaces.contains(space) || before.contains($0.id) }
        return ([shimStamp()] + tracked.map { "\($0.id) \($0.version)" }.sorted())
            .joined(separator: "\n")
    }

    /// Cleared when the shim changed or an extension there before (on, or
    /// turned off since) has another version now: one only added has no
    /// worker kept yet, and one removed from eGlu has its data removed
    /// with it. On the first launch, or after workersChanged, every space
    /// with extensions on or had is cleared.
    public func forgetWorkersIfChanged() async {
        let stored = defaults.dictionary(forKey: Self.workersKey) as? [String: String]
        let forced = stored == nil || defaults.bool(forKey: Self.workersForcedKey)
        var kept = stored ?? [:]
        var failed = defaults.dictionary(forKey: Self.workerFailedKey) as? [String: String] ?? [:]
        for space in host.extensionWorkerSpaces {
            let on = host.extensionWorkerInstallations.filter { $0.spaces.contains(space) }
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
            await backend.clearWorkers(in: space)
            // One found incompatible only because its worker wouldn't start
            // gets one more go, now its stale copy is gone: once a version.
            for item in on where failed[item.id] == host.extensionWorkerCheckStamp(item.version) {
                failed[item.id] = host.extensionWorkerCheckStamp(item.version) + " retried"
                host.resetExtensionWorkerCompatibility(item.id)
            }
        }
        defaults.set(kept, forKey: Self.workersKey)
        defaults.removeObject(forKey: Self.workersForcedKey)
        defaults.set(failed, forKey: Self.workerFailedKey)
    }

    /// Extensions found incompatible because their worker wouldn't start,
    /// by id: the version's stamp, and whether it has had its retry.
    static let workerFailedKey = "extensionsWorkerFailed"

    /// An extension put in again, reloaded or found with its worker dead:
    /// its version alone doesn't tell, so the next launch clears every space
    /// that has had extensions, its record of which is kept for that.
    public func workersChanged() {
        defaults.set(true, forKey: Self.workersForcedKey)
    }

    static let workersForcedKey = "extensionWorkersForced"

    /// An extension whose worker won't start again, taken up afresh as a
    /// relaunch would: unloaded and loaded, the same context, since the
    /// objects its open pages hold name this one. At most once a minute in
    /// a space. (Search's revive)
    @discardableResult
    public func revive(_ id: String, in space: UUID, because reason: String) -> Bool {
        let key = "\(space.uuidString)/\(id)"
        guard backend.context(id, in: space) != nil, backend.controller(in: space) != nil,
              clock.now().timeIntervalSince(revived[key] ?? .distantPast) > 60 else { return false }
        revived[key] = clock.now()
        return restart(id, in: space, because: reason)
    }

    /// Unloaded and loaded again, the same context, and its worker started:
    /// what it was granted while it ran (permissions.request) stays, and its
    /// open pages keep working, as they would not with a new context.
    @discardableResult
    public func restart(_ id: String, in space: UUID, because reason: String) -> Bool {
        let key = "\(space.uuidString)/\(id)"
        guard let context = backend.context(id, in: space), let controller = backend.controller(in: space) else { return false }
        workersChanged()
        NSLog("eGlu: restarting extension \(id): \(reason)")
        host.noteExtensionWorker("revived: \(reason)")
        backend.closeOffscreen(id, in: space)
        // A keep-awake the worker asked for (power) goes with it; the new
        // worker asks again if it still wants one.
        host.releaseExtensionWorkerPower(key)
        let attempt = workerRecovery[key, default: ExtensionWorkerRecovery()].beganAttempt(restarting: true)
        do {
            try backend.unload(context, from: controller)
            try backend.load(context, into: controller)
        } catch {
            NSLog("eGlu: extension \(id) couldn't be loaded again: \(error.localizedDescription)")
            host.updateExtensionWorker(id, in: space, event: .failed)
            if let item = host.extensionWorkerInstallations.first(where: { $0.id == id }) {
                let action = workerRecovery[key, default: ExtensionWorkerRecovery()].finished(attempt, failed: true)
                recover(action, context: context, item: item, in: space)
            }
            return true
        }
        if let item = host.extensionWorkerInstallations.first(where: { $0.id == id }) { startBackground(of: context, item, in: space, attempt: attempt) }
        return true
    }

    /// Starts the background, and gives it five seconds. WebKit doesn't
    /// always answer when a worker throws as it starts; its errors say so
    /// instead (code 6), and are watched apart from this.
    public func startBackground(of context: AnyObject, _ item: WebExtensionWorkerInstallation, in space: UUID, attempt: UUID? = nil) {
        let key = "\(space.uuidString)/\(item.id)"
        let attempt = attempt ?? workerRecovery[key, default: ExtensionWorkerRecovery()].beganAttempt(restarting: false)
        var answered = false
        backend.loadBackground(context) { [weak self, weak context] error in
            MainActor.assumeIsolated {
                answered = true
                guard let self, let context, self.backend.context(item.id, in: space) === context,
                      self.workerRecovery[key]?.attempt == attempt else { return }
                self.host.updateExtensionWorker(item.id, in: space, event: error == nil ? .started : .failed)
                let action = self.workerRecovery[key, default: ExtensionWorkerRecovery()].finished(attempt, failed: error != nil)
                self.recover(action, context: context, item: item, in: space)
            }
        }
        clock.after(5) { [weak self, weak context] in
            guard !answered, let self, let context, self.backend.context(item.id, in: space) === context,
                  self.workerRecovery[key]?.attempt == attempt else { return }
            self.host.updateExtensionWorker(item.id, in: space, event: .timedOutIfChecking)
        }
    }

    public func recover(_ action: ExtensionWorkerRecovery.Action, context: AnyObject, item: WebExtensionWorkerInstallation, in space: UUID) {
        guard backend.context(item.id, in: space) === context else { return }
        switch action {
        case .ignore: break
        case .incompatible:
            host.markExtensionWorkerIncompatible(item.id, version: item.version)
            // Its worker, not WebKit's verdict: the next launch clears it and
            // tries once more (forgetWorkersIfChanged), unless it has.
            var failed = defaults.dictionary(forKey: Self.workerFailedKey) as? [String: String] ?? [:]
            if failed[item.id] != host.extensionWorkerCheckStamp(item.version) + " retried" {
                failed[item.id] = host.extensionWorkerCheckStamp(item.version)
                defaults.set(failed, forKey: Self.workerFailedKey)
                workersChanged()
            }
        case .restart:
            let key = "\(space.uuidString)/\(item.id)"
            let attempt = workerRecovery[key]?.attempt
            clock.after(2) { [weak self, weak context] in
                guard let self, let context, self.backend.context(item.id, in: space) === context,
                      self.workerRecovery[key]?.attempt == attempt else { return }
                // Cooldown, a removed context or a deferred restart is never
                // proof that the extension failed to restart.
                self.revive(item.id, in: space, because: "its worker failed to start")
            }
        }
    }

}
#endif
