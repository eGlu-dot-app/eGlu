#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit
import XCTest
@testable import WebKitExtensions

final class ExtensionStorageTests: XCTestCase {
    @MainActor
    func testPathsUseTheCurrentSuppliedRootWithoutCreatingIt() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let roots = Roots(fixture.environment)
        let storage: any WebExtensionStorage = ExtensionStorage(environment: { roots.value }, defaults: FixtureDefaults())
        for root in [fixture.root, fixture.root.appendingPathComponent("another", isDirectory: true)] {
            roots.value = WebExtensionStorageEnvironment(root: root, temporaryRoot: fixture.temporaryRoot)
            XCTAssertEqual(storage.package("fixture", "1.2.3"), root.appendingPathComponent("fixture/1.2.3.zip"))
            XCTAssertEqual(storage.prepared("fixture", "1.2.3"), root.appendingPathComponent("fixture/1.2.3", isDirectory: true))
            XCTAssertEqual(storage.recordsFile, root.appendingPathComponent("records.json"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.room.path))
    }

    @MainActor
    func testPreparesThePackageAndLeavesTheOriginalAlone() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let storage: any WebExtensionStorage = fixture.storage()
        let archive = Self.archive()
        let file = storage.package("fixture", "1")
        let folder = storage.prepared("fixture", "1")
        try fixture.write(archive, to: file)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertEqual(try Data(contentsOf: file), archive)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(ExtensionPreparation.shimFile), encoding: .utf8), "/* fixture shim */")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("icons/icon.bin"), encoding: .utf8), "icon")
        let worker = try String(contentsOf: folder.appendingPathComponent("bg.js"), encoding: .utf8)
        XCTAssertTrue(worker.contains("/* fixture shim */"))
        XCTAssertTrue(worker.hasSuffix("self.fixture = 1;"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["permissions"] as? [String], ["nativeMessaging"])
        XCTAssertEqual(try fixture.stamp(in: folder), try Self.stamp(for: file, shim: "/* fixture shim */"))
        XCTAssertEqual(try fixture.children(of: file.deletingLastPathComponent()), ["1", "1.zip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporaryRoot.path))
    }

    @MainActor
    func testTheDefaultShimComesFromTheShippedResource() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let storage = ExtensionStorage(environment: { fixture.environment }, defaults: FixtureDefaults())
        let file = storage.package("fixture", "1"), folder = storage.prepared("fixture", "1")
        try fixture.write(Self.archive(), to: file)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertEqual(try fixture.stamp(in: folder), try Self.stamp(for: file, shim: Scripts.extensionShim))
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent(ExtensionPreparation.shimFile), encoding: .utf8).contains("__egluShim"))
    }

    @MainActor
    func testTheSamePreparedCopyIsReusedIncludingGeneratedFiles() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let storage = fixture.storage()
        let file = storage.package("fixture", "1"), folder = storage.prepared("fixture", "1")
        try fixture.write(Self.archive(), to: file)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        let stamp = try fixture.stamp(in: folder)
        let marker = folder.appendingPathComponent("_eglu/script-kept.js")
        try Data("generated".utf8).write(to: marker)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: marker.path)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertEqual(try Data(contentsOf: marker), Data("generated".utf8))
        XCTAssertEqual(try marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        XCTAssertEqual(try fixture.stamp(in: folder), stamp)
        XCTAssertEqual(try fixture.children(of: file.deletingLastPathComponent()), ["1", "1.zip"])
    }

    @MainActor
    func testAChangedShimReplacesThePreparedCopy() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = fixture.storage(shim: "first"), second = fixture.storage(shim: "second")
        let file = first.package("fixture", "1"), folder = first.prepared("fixture", "1")
        try fixture.write(Self.archive(), to: file)
        try first.prepare(URL(fileURLWithPath: file.path), into: folder)
        let before = try fixture.stamp(in: folder)
        let marker = folder.appendingPathComponent("old")
        try Data().write(to: marker)
        try second.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNotEqual(try fixture.stamp(in: folder), before)
        XCTAssertEqual(try fixture.stamp(in: folder), try Self.stamp(for: file, shim: "second"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(ExtensionPreparation.shimFile), encoding: .utf8), "second")
    }

    @MainActor
    func testAChangedPackageSizeOrTimeReplacesTheSameVersion() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let storage = fixture.storage()
        let file = storage.package("fixture", "1"), folder = storage.prepared("fixture", "1")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.write(Self.archive(), to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        let first = try fixture.stamp(in: folder)
        let marker = folder.appendingPathComponent("old")
        try Data().write(to: marker)
        // Each new call gets a fresh URL, as the app's package path query
        // does. Reusing a URL can reuse Foundation's cached resource values.
        // Size alone changes, with exactly the same modification time.
        try fixture.write(Self.archive(worker: "self.fixture = 222;"), to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        let second = try fixture.stamp(in: folder)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("bg.js"), encoding: .utf8).hasSuffix("self.fixture = 222;"))
        try Data().write(to: marker)
        // Time alone changes, with exactly the same archive bytes and size.
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(10)], ofItemAtPath: file.path)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertNotEqual(try fixture.stamp(in: folder), second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try fixture.children(of: file.deletingLastPathComponent()), ["1", "1.zip"])
    }

    // The app hands in whether its own DEBUG switches count (Extensions.debugSwitches).
    @MainActor
    func testWithoutShimPreferenceKeepsTheSameKeyAndStamp() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = fixture.storage(), second = fixture.storage(withoutShim: true)
        let file = first.package("fixture", "1"), folder = first.prepared("fixture", "1")
        try fixture.write(Self.archive(), to: file)
        try first.prepare(URL(fileURLWithPath: file.path), into: folder)
        let before = try fixture.stamp(in: folder)
        try second.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(ExtensionPreparation.shimFile)), Data())
        XCTAssertEqual(try fixture.stamp(in: folder), try Self.stamp(for: file, shim: ""))
        XCTAssertNotEqual(try fixture.stamp(in: folder), before)
    }

    @MainActor
    func testWithoutShimPreferenceCountsOnlyWhenTheAppSaysSo() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let storage = fixture.storage(withoutShim: true, debugSwitches: false)
        let file = storage.package("fixture", "1"), folder = storage.prepared("fixture", "1")
        try fixture.write(Self.archive(), to: file)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertEqual(try fixture.stamp(in: folder), try Self.stamp(for: file, shim: "/* fixture shim */"))
        XCTAssertNotEqual(try Data(contentsOf: folder.appendingPathComponent(ExtensionPreparation.shimFile)), Data())
    }

    @MainActor
    func testTwoCallersShareTheLockAndTheFinishedCopy() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let entered = expectation(description: "first caller holds the lock")
        let attempted = expectation(description: "second caller starts preparation")
        let release = DispatchSemaphore(value: 0)
        let probe = PreparationProbe()
        let folder = fixture.root.appendingPathComponent("fixture/1", isDirectory: true)
        let marker = folder.appendingPathComponent("_eglu/script-kept.js")
        let first = ExtensionStorage(environment: { fixture.environment }, defaults: FixtureDefaults(), readShim: {
            probe.enter()
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return "same"
        })
        let second = ExtensionStorage(environment: { fixture.environment }, defaults: FixtureDefaults(), readShim: {
            probe.enter()
            // This runs only after the first call has finished its copy.
            // Reusing that copy must also preserve a generated script.
            try? Data("generated".utf8).write(to: marker)
            return "same"
        })
        let file = first.package("fixture", "1")
        try fixture.write(Self.archive(), to: file)
        let one = Task.detached { try first.prepare(URL(fileURLWithPath: file.path), into: folder) }
        await fulfillment(of: [entered], timeout: 3)
        // No destination is visible before the first caller is released.
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let two = Task.detached {
            attempted.fulfill()
            try second.prepare(URL(fileURLWithPath: file.path), into: folder)
        }
        await fulfillment(of: [attempted], timeout: 3)
        XCTAssertEqual(probe.count, 1)
        release.signal()
        try await one.value
        try await two.value
        XCTAssertEqual(probe.count, 2)
        XCTAssertEqual(try Data(contentsOf: marker), Data("generated".utf8))
        XCTAssertEqual(try fixture.stamp(in: folder), try Self.stamp(for: file, shim: "same"))
        XCTAssertEqual(try fixture.children(of: file.deletingLastPathComponent()), ["1", "1.zip"])
    }

    @MainActor
    func testAFailedWriteCleansTheSiblingAndKeepsTheOldCopy() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let storage = fixture.storage()
        let file = storage.package("fixture", "1"), folder = storage.prepared("fixture", "1")
        try fixture.write(Self.archive(), to: file)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        let before = try fixture.stamp(in: folder)
        let marker = folder.appendingPathComponent("old")
        try Data("kept".utf8).write(to: marker)
        // The manifest and worker write first, then this valid ZIP name
        // exceeds the filesystem's per-component limit and the write fails.
        let broken = Self.archive(extra: [(String(repeating: "x", count: 300), Data("fail".utf8))])
        try fixture.write(broken, to: file)
        XCTAssertThrowsError(try storage.prepare(URL(fileURLWithPath: file.path), into: folder))
        XCTAssertEqual(try fixture.stamp(in: folder), before)
        XCTAssertEqual(try Data(contentsOf: marker), Data("kept".utf8))
        XCTAssertEqual(try fixture.children(of: file.deletingLastPathComponent()), ["1", "1.zip"])
        // The failed call released the lock and did not poison the stamp.
        try fixture.write(Self.archive(worker: "self.fixture = 2;"), to: file)
        try storage.prepare(URL(fileURLWithPath: file.path), into: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("bg.js"), encoding: .utf8).hasSuffix("self.fixture = 2;"))
    }

    @MainActor
    func testABadPackageLeavesNoPreparedFolderOrTemporarySibling() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let storage = fixture.storage()
        let file = storage.package("fixture", "1"), folder = storage.prepared("fixture", "1")
        try fixture.write(Data("not a ZIP".utf8), to: file)
        XCTAssertThrowsError(try storage.prepare(URL(fileURLWithPath: file.path), into: folder)) {
            XCTAssertEqual($0 as? ExtensionPreparation.Problem, .noManifest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try fixture.children(of: file.deletingLastPathComponent()), ["1.zip"])
    }

    private static func stamp(for file: URL, shim: String) throws -> String {
        let values = try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(ExtensionPreparation.stamp(for: shim)) \(values.fileSize ?? 0) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private static func archive(worker: String = "self.fixture = 1;", extra: [(String, Data)] = []) -> Data {
        let manifest = #"{"manifest_version":3,"name":"Fixture","version":"1","background":{"service_worker":"bg.js"}}"#
        return zip([("manifest.json", Data(manifest.utf8)), ("bg.js", Data(worker.utf8)),
                    ("icons/icon.bin", Data("icon".utf8))] + extra)
    }

    // Stored ZIP entries with a central directory, all made by the test.
    private static func zip(_ files: [(String, Data)]) -> Data {
        var out: [UInt8] = [], central: [UInt8] = []
        func u16(_ value: Int, _ to: inout [UInt8]) { to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func u32(_ value: Int, _ to: inout [UInt8]) {
            to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
        }
        for (name, data) in files {
            let bytes = Array(name.utf8), offset = out.count
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out); u32(0, &out)
            u32(data.count, &out); u32(data.count, &out); u16(bytes.count, &out); u16(0, &out)
            out += bytes; out += data
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(data.count, &central); u32(data.count, &central)
            u16(bytes.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central)
            central += bytes
        }
        let start = out.count
        out += central
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(central.count, &out); u32(start, &out); u16(0, &out)
        return Data(out)
    }
}

@MainActor private final class Roots {
    var value: WebExtensionStorageEnvironment
    init(_ value: WebExtensionStorageEnvironment) { self.value = value }
}

private struct Fixture: Sendable {
    let room = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-storage-test-\(UUID().uuidString)", isDirectory: true)
    var root: URL { room.appendingPathComponent("Extensions", isDirectory: true) }
    var temporaryRoot: URL { room.appendingPathComponent("temporary", isDirectory: true) }
    var environment: WebExtensionStorageEnvironment { .init(root: root, temporaryRoot: temporaryRoot) }

    func storage(shim: String = "/* fixture shim */", withoutShim: Bool = false, debugSwitches: Bool = true) -> ExtensionStorage {
        ExtensionStorage(environment: { self.environment }, defaults: FixtureDefaults(withoutShim: withoutShim), readShim: { shim },
                         debugSwitches: debugSwitches)
    }
    func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    func stamp(in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(ExtensionPreparation.stampFile), encoding: .utf8)
    }
    func children(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
    func remove() { try? FileManager.default.removeItem(at: room) }
}

// Reads only the preparation flag, without reading or writing app preferences.
private final class FixtureDefaults: UserDefaults, @unchecked Sendable {
    private let withoutShim: Bool
    init(withoutShim: Bool = false) {
        self.withoutShim = withoutShim
        super.init(suiteName: nil)!
    }
    override func bool(forKey name: String) -> Bool { name == "extensionsWithoutShim" && withoutShim }
}

private final class PreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    func enter() { lock.withLock { entered += 1 } }
    var count: Int { lock.withLock { entered } }
}
#endif
