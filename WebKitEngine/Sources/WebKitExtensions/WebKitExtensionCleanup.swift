#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit
import WebKit

/// Deletion keeps the hub's main actor and its original task boundaries.
/// The backend lets tests drive deletion without creating a website store.
@MainActor
public final class WebKitExtensionCleanup: WebExtensionCleanup {
    private let host: any ExtensionCleanupHost
    private let backend: any ExtensionCleanupBackend
    private let defaults: UserDefaults

    public convenience init(host: any ExtensionCleanupHost, controllers: WebKitExtensionControllers,
                            kept: @escaping (String, String, UUID) -> URL, folder: @escaping () -> URL,
                            clearWatches: @escaping (UUID) -> Void, clearEvidence: @escaping (UUID) -> Void) {
        self.init(host: host, backend: WebKitExtensionCleanupBackend(host: host, controllers: controllers,
            kept: kept, folder: folder, clearWatches: clearWatches, clearEvidence: clearEvidence), defaults: .standard)
    }

    init(host: any ExtensionCleanupHost, backend: any ExtensionCleanupBackend, defaults: UserDefaults) {
        self.host = host
        self.backend = backend
        self.defaults = defaults
    }

    public func remove(_ id: String, from space: UUID) {
        backend.unload(id, in: space)
        closePages(of: id, in: space)
        forget(id, in: space)
    }

    public func removePackages(_ id: String, afterClearing spaces: [UUID]) {
        let clearing = spaces.map { forget(id, in: $0) }
        Task {
            for task in clearing { await task.value }
            // Unless it was installed again meanwhile.
            guard !host.extensionCleanupIsInstalled(id) else { return }
            backend.removePackage(id)
        }
    }

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
    public func forget(_ id: String, in space: UUID) -> Task<Void, Never> {
        let key = "\(space.uuidString)/\(id)"
        if let running = forgetting[key] { return running }
        var left = defaults.stringArray(forKey: Self.forgettingKey) ?? []
        if !left.contains(key) { left.append(key) }
        defaults.set(left, forKey: Self.forgettingKey)
        let task = Task { [weak self] in
            guard let self else { return }
            let done = await self.clear(id, in: space)
            self.forgetting[key] = nil
            if done {
                let rest = (defaults.stringArray(forKey: Self.forgettingKey) ?? []).filter { $0 != key }
                defaults.set(rest, forKey: Self.forgettingKey)
            }
        }
        forgetting[key] = task
        return task
    }

    /// At launch, before anything loads: what a removal didn't finish.
    public func forgetLeftOver() {
        for key in defaults.stringArray(forKey: Self.forgettingKey) ?? [] {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let space = UUID(uuidString: parts[0]), ExtensionID.isValid(parts[1]) else { continue }
            guard host.extensionSpaceExists(space) else {
                // The space is gone, and its store with it.
                let rest = (defaults.stringArray(forKey: Self.forgettingKey) ?? []).filter { $0 != key }
                defaults.set(rest, forKey: Self.forgettingKey)
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
    public func cleared(_ id: String, in space: UUID) async -> Bool {
        let key = "\(space.uuidString)/\(id)"
        let pending = { (self.defaults.stringArray(forKey: Self.forgettingKey) ?? []).contains(key) }
        if let running = forgetting[key] { await running.value }
        if pending() { await forget(id, in: space).value }
        return !pending()
    }

    private func clear(_ id: String, in space: UUID) async -> Bool {
        backend.removeGeneratedFiles(id, in: space)
        guard host.extensionSpaceExists(space) else { return true }
        // Its pages there closed first: an open one holds its databases.
        closePages(of: id, in: space)
        return await backend.clear(id, in: space)
    }

    /// A space going: release its controller before the website store is
    /// swept, and keep it alive until its extension data has been deleted.
    public func removeSpace(_ space: UUID) {
        for id in backend.loadedIDs(in: space) { backend.unload(id, in: space) }
        backend.closeAllOffscreen(in: space)
        backend.closeSockets(in: space)
        host.closeExtensionCleanupPopups(in: space)
        host.closeExtensionCleanupSidePanels(in: space)
        backend.clearWatches(in: space)
        // What eGlu kept for each extension in the space (user scripts,
        // their worlds) goes with it.
        for id in host.extensionCleanupIDs(in: space) { backend.removeGeneratedFiles(id, in: space) }
        host.removeExtensionCleanupMembership(in: space)
        let controller = backend.removeController(for: space)
        backend.clearContexts(in: space)
        host.clearExtensionCleanupVerdicts(in: space)
        backend.clearEvidence(in: space)
        // Its extensions' storage, which WebKit keeps apart from the space's
        // website store: deleted through the controller before it is let
        // go, and the store swept again after, which waits for that.
        guard let controller else { return }
        Task {
            await controller.removeData()
            host.scheduleExtensionCleanupStoreSweep()
        }
    }

    /// App tabs and popup first, then the runtime's offscreen document.
    public func closePages(of id: String, in space: UUID) {
        host.closeExtensionCleanupPages(of: id, in: space)
        backend.closeOffscreen(id, in: space)
    }
}

/// Only the WebKit and file operations are replaced in deletion tests.
@MainActor
protocol ExtensionCleanupBackend: AnyObject {
    func removeGeneratedFiles(_ id: String, in space: UUID)
    func clear(_ id: String, in space: UUID) async -> Bool
    func unload(_ id: String, in space: UUID)
    func loadedIDs(in space: UUID) -> [String]
    func closeOffscreen(_ id: String, in space: UUID)
    func closeAllOffscreen(in space: UUID)
    func closeSockets(in space: UUID)
    func clearWatches(in space: UUID)
    func removeController(for space: UUID) -> (any ExtensionSpaceDeletion)?
    func clearContexts(in space: UUID)
    func clearEvidence(in space: UUID)
    func removePackage(_ id: String)
}

@MainActor
protocol ExtensionSpaceDeletion: AnyObject {
    func removeData() async
}

@MainActor
private final class WebKitExtensionSpaceDeletion: ExtensionSpaceDeletion {
    private let controller: WKWebExtensionController
    init(_ controller: WKWebExtensionController) { self.controller = controller }

    func removeData() async {
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types)
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
        withExtendedLifetime(controller) {}
    }
}

@MainActor
private final class WebKitExtensionCleanupBackend: ExtensionCleanupBackend {
    private static let scheme = WebKitExtensionControllers.scheme
    private let host: any ExtensionCleanupHost
    private let controllers: WebKitExtensionControllers
    private let kept: (String, String, UUID) -> URL
    private let folder: () -> URL
    private let clearWatches: (UUID) -> Void
    private let clearEvidence: (UUID) -> Void

    init(host: any ExtensionCleanupHost, controllers: WebKitExtensionControllers,
         kept: @escaping (String, String, UUID) -> URL, folder: @escaping () -> URL,
         clearWatches: @escaping (UUID) -> Void, clearEvidence: @escaping (UUID) -> Void) {
        self.host = host
        self.controllers = controllers
        self.kept = kept
        self.folder = folder
        self.clearWatches = clearWatches
        self.clearEvidence = clearEvidence
    }

    func removeGeneratedFiles(_ id: String, in space: UUID) {
        for name in ["userscripts", "worlds"] { try? FileManager.default.removeItem(at: kept(name, id, space)) }
    }

    func clear(_ id: String, in space: UUID) async -> Bool {
        let controller = controllers.controller(for: space)
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
                host.noteExtensionCleanup { "clear: record errors \(records.flatMap(\.errors).map(\.localizedDescription))" }
                return false
            }
        }
        guard controllers.contexts[space]?[id] == nil, let base = URL(string: "\(Self.scheme)://\(id)/") else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-forget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"manifest_version": 3, "name": "eGlu", "version": "1"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
            let standIn = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
            standIn.uniqueIdentifier = id
            standIn.baseURL = base
            // Turned on again meanwhile: it is its own, not a stand-in's.
            guard controllers.contexts[space]?[id] == nil else { return false }
            try controller.load(standIn)
            defer { try? controller.unload(standIn) }
            guard let configuration = standIn.webViewConfiguration else { return false }
            let done = try await ExtensionBlankPage(configuration, scheme: Self.scheme).clear(at: base)
            host.noteExtensionCleanup { "clear: blank page \(done)" }
            return done
        } catch {
            host.noteExtensionCleanup { "clear: failed \(error)" }
            NSLog("eGlu: couldn't clear what extension \(id) kept: \(error.localizedDescription)")
            return false
        }
    }

    func unload(_ id: String, in space: UUID) { controllers.unload(id, in: space) }
    func loadedIDs(in space: UUID) -> [String] { Array((controllers.contexts[space] ?? [:]).keys) }
    func closeOffscreen(_ id: String, in space: UUID) { ExtensionOffscreen.close(id, in: space) }
    func closeAllOffscreen(in space: UUID) { ExtensionOffscreen.closeAll(in: space) }
    func closeSockets(in space: UUID) { ExtensionSocket.close(in: space) }
    func clearWatches(in space: UUID) { clearWatches(space) }
    func removeController(for space: UUID) -> (any ExtensionSpaceDeletion)? {
        controllers.removeController(for: space).map(WebKitExtensionSpaceDeletion.init)
    }
    func clearContexts(in space: UUID) { controllers.contexts[space] = nil }
    func clearEvidence(in space: UUID) { clearEvidence(space) }
    func removePackage(_ id: String) {
        try? FileManager.default.removeItem(at: folder().appendingPathComponent(id, isDirectory: true))
    }
}
#endif
