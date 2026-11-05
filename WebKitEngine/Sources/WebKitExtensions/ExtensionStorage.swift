#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit

/// The runtime's files. Path queries ask for the current roots, and
/// preparation keeps one process-wide lock, also across runtime instances.
/// The stored closures and preferences are read only; preparation reads
/// them under that lock. Path queries stay on the app's main actor.
public final class ExtensionStorage: WebExtensionStorage, @unchecked Sendable {
    private let environment: @MainActor @Sendable () -> WebExtensionStorageEnvironment
    private let defaults: UserDefaults
    private let readShim: @Sendable () -> String
    private let debugSwitches: Bool

    /// `debugSwitches`: the app's DEBUG builds' own switches (as
    /// `-extensionsWithoutShim YES`) are honoured. The app decides, as the
    /// app's Test configuration defines DEBUG for the app but not for its
    /// packages.
    public convenience init(environment: @escaping @MainActor @Sendable () -> WebExtensionStorageEnvironment,
                            defaults: UserDefaults = .standard, debugSwitches: Bool = false) {
        self.init(environment: environment, defaults: defaults, readShim: { Scripts.extensionShim }, debugSwitches: debugSwitches)
    }

    // Tests supply shim text without changing the shipped resource.
    init(environment: @escaping @MainActor @Sendable () -> WebExtensionStorageEnvironment,
         defaults: UserDefaults, readShim: @escaping @Sendable () -> String, debugSwitches: Bool = false) {
        self.environment = environment
        self.defaults = defaults
        self.readShim = readShim
        self.debugSwitches = debugSwitches
    }

    @MainActor
    private var folder: URL { environment().root }

    @MainActor
    public var recordsFile: URL { folder.appendingPathComponent("records.json") }

    /// The verified package of a version, kept as it came.
    @MainActor
    public func package(_ id: String, _ version: String) -> URL {
        folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent("\(version).zip")
    }

    /// The folder WebKit loads a version from: its package unpacked, with
    /// the shim put in (ExtensionPreparation).
    @MainActor
    public func prepared(_ id: String, _ version: String) -> URL {
        folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent(version, isDirectory: true)
    }

    /// Makes the prepared folder from the package, unless it is there and
    /// was made from this package with this shim. Off the main thread: a large extension
    /// takes a moment. Into a folder of its own first, so a folder that is
    /// there is always a whole one; and one at a time, so a load in another
    /// space, which may be reading it, finds it made rather than replaced.
    /// Only a folder made with another shim is replaced, and nothing loads
    /// one of those.
    nonisolated public func prepare(_ package: URL, into folder: URL) throws {
        try Self.preparing.withLock { try prepareNow(package, into: folder) }
    }

    private nonisolated static let preparing = NSLock()

    private nonisolated func prepareNow(_ package: URL, into folder: URL) throws {
        var shim = readShim()
        // To see what WebKit does without it (`-extensionsWithoutShim YES`),
        // in the app's DEBUG builds only.
        if debugSwitches, defaults.bool(forKey: "extensionsWithoutShim") { shim = "" }
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
}
#endif
