#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import XCTest
@testable import WebKitExtensions

@MainActor
private final class InstallLog {
    var calls: [String] = []
}

@MainActor
private final class InstallHost: ExtensionInstallHost {
    let browser = BrowserHost()
    let root: URL
    let log: InstallLog
    var noted: (() -> Void)?
    var facts: WebExtensionManifestFacts?
    var refusalAnswer: ((WebExtensionInstallRefusal) -> any Error)?
    init(_ root: URL, _ log: InstallLog) { self.root = root; self.log = log }
    var extensionStorageEnvironment: WebExtensionStorageEnvironment { .init(root: root, temporaryRoot: root) }
    func extensionInstallRefusal(_ refusal: WebExtensionInstallRefusal) -> any Error { refusalAnswer?(refusal) ?? refusal }
    func noteExtensionInstallFacts(_ facts: WebExtensionManifestFacts?, of id: String) {
        log.calls.append("facts")
        self.facts = facts
        noted?()
    }
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

/// No controller, store, context, view or extension is created by these loads.
@MainActor
private final class InstallControllers: WebExtensionControllers {
    let log: InstallLog
    var results: [Bool] = []
    var loaded: Set<UUID> = []
    var loading: ((WebExtensionInstallation, UUID) async -> Bool)?
    init(_ log: InstallLog) { self.log = log }
    func isLoaded(_ id: String, in space: UUID) -> Bool {
        log.calls.append("membership")
        return loaded.contains(space)
    }
    func extensionID(for url: URL?) -> String? { nil }
    func load(_ item: WebExtensionInstallation, in space: UUID) async -> Bool {
        log.calls.append("load:\(item.version):\(space)")
        let result = if let loading { await loading(item, space) } else { results.removeFirst() }
        if result { loaded.insert(space) }
        return result
    }
    func unload(_ id: String, in space: UUID) { log.calls.append("unload:\(space)"); loaded.remove(space) }
    func setSiteAccess(_ id: String, _ access: WebExtensionInstallation.SiteAccess) { XCTFail("Unexpected grant change") }
    func setReadsCookies(_ id: String, _ on: Bool, changed: (UUID) -> Void) { XCTFail("Unexpected cookie change") }
}

final class ExtensionInstallExecutionTests: XCTestCase {
    private let id = String(repeating: "a", count: 32)

    private func room() throws -> URL {
        let room = FileManager.default.temporaryDirectory.appendingPathComponent("install-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: room) }
        return room
    }

    @MainActor
    private func runtime(_ root: URL, _ log: InstallLog, _ controllers: InstallControllers) -> (WebKitExtensionInstallExecution, InstallHost) {
        let host = InstallHost(root, log)
        // Preparation is never reached by these tests; trial execution is injected.
        let storage = ExtensionStorage(environment: { host.extensionStorageEnvironment })
        let runtime = WebKitExtensionInstallExecution(host: host, storage: storage, controllers: controllers,
            forgetChecks: { _ in log.calls.append("checks") }, forgetIcon: { _ in log.calls.append("icon") },
            workersChanged: { log.calls.append("workers") }, scheme: "chrome-extension")
        return (runtime, host)
    }

    private func item(_ version: String, _ spaces: [UUID]) -> WebExtensionInstallation {
        .init(id: id, name: "Install fixture", version: version, source: .store, siteAccess: .allSites, spaces: spaces)
    }

    @MainActor
    func testChecksumMismatchAfterInjectedDownloadWritesNothing() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        let bytes = Data("fixture bytes".utf8)
        runtime.downloadForTesting = { request in
            XCTAssertEqual(request.timeoutInterval, 60)
            XCTAssertEqual(request.url, ExtensionStore.packageURL(for: self.id))
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let downloaded = try await runtime.download(id, from: URL(string: "http://untrusted.invalid/update"))
        XCTAssertEqual(downloaded, bytes)
        XCTAssertThrowsError(try runtime.verifyUpdate(downloaded, id: id, size: bytes.count, sha256: "00", version: "2")) {
            XCTAssertEqual($0.localizedDescription, "The downloaded update did not match the store's checksum.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertEqual(runtime.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @MainActor
    func testDownloadChecksFinalHostStatusAndEmptyReply() async throws {
        let log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(try room(), log, controllers)
        for (url, code, bytes, expected) in [
            ("https://untrusted.invalid/file", 200, Data([1]), "That isn't a Chrome extension."),
            ("https://clients2.google.com/file", 404, Data([1]), "The Chrome Web Store answered 404."),
            ("https://clients2.google.com/file", 200, Data(), "The Chrome Web Store has nothing for that extension. It may have been taken down.")
        ] {
            runtime.downloadForTesting = { _ in
                (bytes, HTTPURLResponse(url: URL(string: url)!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await runtime.download(id); XCTFail("Expected refusal") }
            catch { XCTAssertEqual(error.localizedDescription, expected) }
        }
    }

    @MainActor
    func testRefusalsUseTheExactHostErrorIncludingStaticFolderForwarding() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, host) = runtime(root, log, controllers)
        let failure = NSError(domain: "app refusal fixture", code: 51)
        host.refusalAnswer = { _ in failure }
        XCTAssertThrowsError(try runtime.describeOffer(Data(), id: id)) {
            XCTAssertTrue($0 as NSError === failure)
        }
        let badVersion = Self.zip([("manifest.json", Data(#"{"name":"Fixture","version":"invalid"}"#.utf8))])
        let parsed = try runtime.readArchive(badVersion)
        XCTAssertThrowsError(try parsed.checkedVersion()) { XCTAssertTrue($0 as NSError === failure) }
        do {
            _ = try await WebKitExtensionInstallExecution.zipFolder(root, refused: { _ in failure })
            XCTFail("Expected missing manifest")
        } catch { XCTAssertTrue(error as NSError === failure) }
    }

    @MainActor
    func testKeepPublishesFactsAfterWritingAndBeforeCatalogWork() throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, host) = runtime(root, log, controllers)
        let archive = Self.zip([("manifest.json", Data(#"{"manifest_version":3,"name":"New name","version":"2","optional_permissions":["cookies"]}"#.utf8))])
        host.noted = {
            XCTAssertEqual(log.calls, ["checks", "icon", "workers", "facts"])
            XCTAssertEqual(try? Data(contentsOf: root.appendingPathComponent("\(self.id)/2.zip")), archive)
        }
        let name = try runtime.keepArchive(archive, id: id, name: "Old name", version: "2")
        XCTAssertEqual(name, "New name")
        XCTAssertEqual(host.facts, .init(offersCookies: true, nativeRequired: false, nativeOptional: false))
        XCTAssertEqual(log.calls, ["checks", "icon", "workers", "facts"])
    }

    @MainActor
    func testChangedInstallationAfterSuspendedLoadDoesNotPruneOrRestore() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        let space = UUID(), candidate = item("2", [space])
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("1.zip"))
        var installed = candidate
        let began = expectation(description: "load suspended")
        var waiting: CheckedContinuation<Bool, Never>?
        controllers.loading = { _, _ in await withCheckedContinuation { waiting = $0; began.fulfill() } }
        let task = Task {
            await runtime.loadReplacement(candidate) { loaded in
                XCTAssertTrue(loaded)
                guard installed == candidate else { return .finished(false, keeping: nil) }
                XCTFail("The changed catalog must reject the completion")
                return .finished(true, keeping: "2")
            }
        }
        await fulfillment(of: [began], timeout: 2)
        installed = item("3", [space])
        waiting!.resume(returning: true)
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1.zip").path))
        XCTAssertEqual(log.calls, ["load:2:\(space)"])
    }

    @MainActor
    func testSomeSpacesSucceedAndPruningWaitsForTheCatalogAnswer() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        let first = UUID(), second = UUID(), folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["1.zip", "2.zip", "2", "_eglu", ".making"] { try Data().write(to: folder.appendingPathComponent(name)) }
        controllers.results = [false, true]
        let result = await runtime.loadReplacement(item("2", [first, second])) { loaded in
            XCTAssertTrue(loaded)
            XCTAssertEqual(log.calls, ["load:2:\(first)", "load:2:\(second)"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1.zip").path))
            log.calls.append("catalog check")
            return .finished(loaded, keeping: "2")
        }
        XCTAssertTrue(result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), [".making", "2", "2.zip", "_eglu"])
    }

    @MainActor
    func testRollbackLoadsThePreviousSpacesAfterItsCatalogIsRestored() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        let first = UUID(), second = UUID(), previous = item("1", [second, first])
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["1.zip", "2.zip"] { try Data().write(to: folder.appendingPathComponent(name)) }
        runtime.unload(previous)
        controllers.results = [false, false, true, true]
        let result = await runtime.loadReplacement(item("2", [first, second])) { loaded in
            XCTAssertFalse(loaded)
            log.calls.append("restore catalog and save")
            return .restore(previous)
        }
        XCTAssertFalse(result)
        XCTAssertEqual(log.calls, ["unload:\(second)", "unload:\(first)", "load:2:\(first)", "load:2:\(second)",
                                   "restore catalog and save", "load:1:\(second)", "load:1:\(first)"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["1.zip"])
    }

    @MainActor
    func testNewInstallPublishesBeforeFinalMembershipQueryAndKeepsAllAttempts() async throws {
        let log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(try room(), log, controllers)
        let first = UUID(), second = UUID()
        controllers.results = [true, false]
        let result = await runtime.loadNew(item("2", [first, second])) { log.calls.append("just installed") }
        XCTAssertTrue(result)
        XCTAssertEqual(log.calls, ["load:2:\(first)", "load:2:\(second)", "just installed", "membership"])
        log.calls = []
        let empty = await runtime.loadNew(item("2", [])) { log.calls.append("empty completion") }
        XCTAssertTrue(empty)
        XCTAssertEqual(log.calls, ["empty completion"])
    }

    @MainActor
    func testInjectedTrialReceivesExactBytesAndError() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        let archive = Data([4, 5, 6]), failure = NSError(domain: "install fixture", code: 71)
        runtime.trialForTesting = { bytes, id in
            XCTAssertEqual(bytes, archive)
            XCTAssertEqual(id, self.id)
            throw failure
        }
        do { try await runtime.trial(archive, id: id); XCTFail("Expected fixture error") }
        catch { XCTAssertTrue(error as NSError === failure) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    @MainActor
    func testSnapshotUsesResolvedIdentityButZipsTheChosenFolderContents() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        let folder = root.appendingPathComponent("source"), link = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = Data(#"{"manifest_version":3,"name":"Snapshot","version":"1"}"#.utf8)
        try manifest.write(to: folder.appendingPathComponent("manifest.json"))
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("own.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let snapshot = try await runtime.snapshot(link)
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(snapshot.path, path)
        XCTAssertEqual(snapshot.id, ExtensionID.id(forUnpackedPath: path))
        XCTAssertEqual(ZipFile.file(in: snapshot.archive, matching: { $0 == "manifest.json" }), manifest)
        XCTAssertEqual(ZipFile.file(in: snapshot.archive, matching: { $0 == "own.txt" }), Data("fixture".utf8))
        let (description, version) = try runtime.describeOffer(snapshot.archive, id: snapshot.id)
        XCTAssertEqual(description.name(fallback: "fallback"), "Snapshot")
        XCTAssertEqual(version, "1")
    }

    @MainActor
    func testFolderByteLimitRejectsASparseFixtureBeforeDitto() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        try Data("{}".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let large = root.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: UInt64(WebKitExtensionInstallExecution.largestFolder) + 1)
        try file.close()
        do { _ = try await runtime.zipped(root); XCTFail("Expected size limit") }
        catch { XCTAssertEqual(error.localizedDescription, "That folder is larger than an extension can be.") }
    }

    @MainActor
    func testFolderFileLimitCountsDirectoriesToo() async throws {
        let root = try room(), log = InstallLog(), controllers = InstallControllers(log)
        let (runtime, _) = runtime(root, log, controllers)
        try Data("{}".utf8).write(to: root.appendingPathComponent("manifest.json"))
        // Empty directories count in the original enumerator, just like files.
        for index in 0..<WebKitExtensionInstallExecution.mostFiles {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(String(index)), withIntermediateDirectories: false)
        }
        do { _ = try await runtime.zipped(root); XCTFail("Expected file count limit") }
        catch { XCTAssertEqual(error.localizedDescription, "That folder is larger than an extension can be.") }
    }

    private static func zip(_ files: [(String, Data)]) -> Data {
        var out: [UInt8] = [], central: [UInt8] = []
        func u16(_ value: Int, _ to: inout [UInt8]) { to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func u32(_ value: Int, _ to: inout [UInt8]) {
            to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
        }
        for (name, data) in files {
            let nameBytes = Array(name.utf8), offset = out.count
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out); u32(0, &out)
            u32(data.count, &out); u32(data.count, &out); u16(nameBytes.count, &out); u16(0, &out)
            out += nameBytes; out += data
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(data.count, &central); u32(data.count, &central)
            u16(nameBytes.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central); central += nameBytes
        }
        let start = out.count
        out += central
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(central.count, &out); u32(start, &out); u16(0, &out)
        return Data(out)
    }
}
#endif
