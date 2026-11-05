#if os(macOS)
import AppKit
import CryptoKit
import PadCore
import WebEngineAppKit
import WebKit

/// Files, verification and sequential loading. Catalog decisions stay in the app.
@MainActor
public final class WebKitExtensionInstallExecution: WebExtensionInstallExecution {
    private let host: any ExtensionInstallHost
    private let storage: any WebExtensionStorage
    private let controllers: any WebExtensionControllers
    private let forgetChecks: (String) -> Void
    private let forgetIcon: (String) -> Void
    private let workersChanged: () -> Void
    private let scheme: String

    public init(host: any ExtensionInstallHost, storage: any WebExtensionStorage,
                controllers: any WebExtensionControllers, forgetChecks: @escaping (String) -> Void,
                forgetIcon: @escaping (String) -> Void, workersChanged: @escaping () -> Void, scheme: String) {
        self.host = host
        self.storage = storage
        self.controllers = controllers
        self.forgetChecks = forgetChecks
        self.forgetIcon = forgetIcon
        self.workersChanged = workersChanged
        self.scheme = scheme
    }

    // Fixtures replace external execution without a connection or a loaded extension.
    var downloadForTesting: ((URLRequest) async throws -> (Data, URLResponse))?
    var trialForTesting: ((Data, String) async throws -> Void)?

    private func refused(_ refusal: WebExtensionInstallRefusal) -> any Error {
        host.extensionInstallRefusal(refusal)
    }

    public func download(_ id: String, from address: URL? = nil) async throws -> Data {
        let url = address.flatMap { $0.scheme == "https" && (ExtensionStore.isPackageHost($0) || $0.host() == "clients2.google.com") ? $0 : nil }
        var request = URLRequest(url: url ?? ExtensionStore.packageURL(for: id))
        request.timeoutInterval = 60
        let data: Data, response: URLResponse
        if let downloadForTesting { (data, response) = try await downloadForTesting(request) }
        else { (data, response) = try await URLSession.shared.data(for: request) }
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else { throw refused(.download(http.statusCode)) }
            guard let final = http.url, ExtensionStore.isPackageHost(final) || final.host() == "clients2.google.com" else {
                throw refused(.notAPackage)
            }
        }
        guard !data.isEmpty else { throw refused(.nothing) }
        return data
    }

    public func readArchive(_ archive: Data) throws -> any WebExtensionInstallArchive {
        try InstallArchive(archive, refused: host.extensionInstallRefusal)
    }

    public func describeOffer(_ archive: Data, id: String) throws -> (any WebExtensionInstallArchive, String) {
        let manifest = try InstallArchive(archive, refused: host.extensionInstallRefusal)
        // Both name files: only what Chrome itself takes, 32 letters and a
        // version of numbers and dots, so neither can lead out of the folder.
        guard ExtensionID.isValid(id) else { throw refused(.notAPackage) }
        let version = try manifest.checkedVersion()
        return (manifest, version)
    }

    public func verifyUpdate(_ crx: Data, id: String, size: Int?, sha256 hash: String?, version offered: String) throws -> (Data, any WebExtensionInstallArchive, String) {
        if let size, size != crx.count { throw refused(.notChecked(String(localized: "The downloaded size did not match the store's reply."))) }
        if let hash, hash.lowercased() != sha256(crx) { throw refused(.notChecked(String(localized: "The downloaded update did not match the store's checksum."))) }
        let archive = try CRXFile.archive(of: crx, id: id, fromStore: true)
        let manifest = try InstallArchive(archive, refused: host.extensionInstallRefusal)
        guard let version = ExtensionVersion(manifest.version), version == ExtensionVersion(offered) else { throw refused(.badVersion) }
        return (archive, manifest, version.description)
    }

    public func keepArchive(_ archive: Data, id: String, name: String, version: String) throws -> String {
        // A new package, even at the same version (Reload): its code read
        // and pages tried afresh, and its worker too at the next launch.
        forgetChecks(id)
        // And its icon read again, which a new version may have changed.
        forgetIcon(id)
        workersChanged()
        let file = storage.package(id, version)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: file, options: .atomic)
        let manifest = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }).flatMap { try? ExtensionManifest(json: $0) }
        let resolvedName = manifest.map { WebKitExtensionMetadata.name(in: archive, manifest: $0, fallback: name) } ?? name
        host.noteExtensionInstallFacts(manifest.map {
            WebExtensionManifestFacts(offersCookies: $0.optionalPermissions.contains("cookies"),
                                     nativeRequired: $0.permissions.contains("nativeMessaging"),
                                     nativeOptional: !$0.permissions.contains("nativeMessaging") && $0.optionalPermissions.contains("nativeMessaging"))
        }, of: id)
        return resolvedName
    }

    public func unload(_ item: WebExtensionInstallation) {
        for space in item.spaces { controllers.unload(item.id, in: space) }
    }

    public func loadReplacement(_ item: WebExtensionInstallation,
                                completion: (Bool) -> WebExtensionInstallCompletion) async -> Bool {
        var loaded = item.spaces.isEmpty
        for space in item.spaces where await controllers.load(item, in: space) { loaded = true }
        switch completion(loaded) {
        case .finished(let result, let version):
            if let version { removeOtherVersions(of: item.id, keeping: version) }
            return result
        case .restore(let previous):
            for space in previous.spaces { await controllers.load(previous, in: space) }
            removeOtherVersions(of: item.id, keeping: previous.version)
            return false
        }
    }

    public func loadNew(_ item: WebExtensionInstallation, didLoad: () -> Void) async -> Bool {
        for space in item.spaces { await controllers.load(item, in: space) }
        didLoad()
        return item.spaces.isEmpty || item.spaces.contains { controllers.isLoaded(item.id, in: $0) }
    }

    public func removeOtherVersions(of id: String, keeping version: String) {
        let here = host.extensionStorageEnvironment.root.appendingPathComponent(id, isDirectory: true)
        let kept = ["\(version).zip", version, "_eglu"]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: here.path)) ?? []
        where !kept.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: here.appendingPathComponent(name))
        }
    }

    public func trial(_ archive: Data, id: String) async throws {
        if let trialForTesting { try await trialForTesting(archive, id); return }
        let room = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-trial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: room) }
        let file = room.appendingPathComponent("package.zip")
        let folder = room.appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        try archive.write(to: file)
        try await Task.detached(priority: .utility) { [storage] in try storage.prepare(file, into: folder) }.value
        try await ExtensionTrial.start(try await WKWebExtension(resourceBaseURL: folder), id: id, scheme: scheme)
    }

    public func sha256(_ data: Data) -> String { Self.checksum(data) }

    public static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func snapshot(_ folder: URL) async throws -> WebExtensionFolderSnapshot {
        // Its real path, links resolved, as Chrome makes the id from.
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let id = ExtensionID.id(forUnpackedPath: path)
        return WebExtensionFolderSnapshot(path: path, id: id, archive: try await zipped(folder))
    }

    /// The most a folder may hold, measured before it is zipped: as much as
    /// a package may unpack to (ExtensionPreparation), in at most as many
    /// files as a ZIP can list.
    public static let largestFolder = 512 * 1024 * 1024
    public static let mostFiles = 65_000

    /// A folder as a ZIP with its contents at the top, by ditto, the Mac's
    /// own; measured first, and read off the main thread.
    public func zipped(_ folder: URL) async throws -> Data {
        try await Self.zipFolder(folder, refused: host.extensionInstallRefusal)
    }

    public static func zipFolder(_ folder: URL, refused: (WebExtensionInstallRefusal) -> any Error = { $0 }) async throws -> Data {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            throw refused(.noManifest)
        }
        let fits = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return false }
            var total = 0, count = 0
            for case let file as URL in walk {
                count += 1
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if count > Self.mostFiles || total > Self.largestFolder { return false }
            }
            return true
        }.value
        guard fits else { throw refused(.notChecked(String(localized: "That folder is larger than an extension can be."))) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-unpacked-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", folder.path, out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(throwing: error) }
            // A minute at most: a folder of special files could hold it for ever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
        }
        guard status == 0 else { throw refused(.notChecked(String(localized: "The folder couldn't be read."))) }
        return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: out) }.value
    }
}

extension WebKitExtensionCompatibility {
    /// A new package, including a same-version reload, invalidates both caches.
    public func forgetInstallChecks(_ id: String) {
        forgetCheck(id)
        scanned[id] = nil
        scanning[id] = nil
    }
}

@MainActor
private final class InstallArchive: WebExtensionInstallArchive {
    private let archive: Data
    private let manifest: ExtensionManifest
    private let refused: (WebExtensionInstallRefusal) -> any Error
    init(_ archive: Data, refused: @escaping (WebExtensionInstallRefusal) -> any Error) throws {
        guard let manifestData = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }) else { throw refused(.noManifest) }
        self.manifest = try ExtensionManifest(json: manifestData)
        self.archive = archive
        self.refused = refused
    }
    var version: String { manifest.version }
    var grants: [String] { manifest.grants }
    var permissions: [String] { manifest.permissions }
    var sites: [String] { manifest.hostPermissions + manifest.contentScripts.flatMap(\.matches) }
    func checkedVersion() throws -> String {
        guard let version = ExtensionVersion(manifest.version)?.description else { throw refused(.badVersion) }
        return version
    }
    func name(fallback: String) -> String { WebKitExtensionMetadata.name(in: archive, manifest: manifest, fallback: fallback) }
    func icon() -> NSImage? { WebKitExtensionMetadata.icon(in: archive, manifest: manifest) }
}
#endif
