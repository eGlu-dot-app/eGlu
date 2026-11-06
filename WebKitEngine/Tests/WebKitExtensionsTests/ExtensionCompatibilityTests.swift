#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

@MainActor
private final class CompatibilityHost: ExtensionCompatibilityHost {
    var items: [WebExtensionCompatibilityInstallation] = [.init(id: "fixture", version: "1")]
    var events: [(UUID, WebExtensionCompatibilityEvidence)] = []
    var problems: [(WebExtensionCompatibilityInstallation, WebExtensionCompatibilityResult.Problem)] = []
    var order: [String] = []
    var extensionCompatibilityInstallations: [WebExtensionCompatibilityInstallation] { items }
    func extensionCompatibilityInstallation(_ id: String) -> WebExtensionCompatibilityInstallation? { items.first { $0.id == id } }
    func extensionCompatibilityEvidence(_ evidence: WebExtensionCompatibilityEvidence, id: String, in space: UUID) {
        events.append((space, evidence))
        order.append("evidence")
    }
    func extensionCompatibilityProblem(_ problem: WebExtensionCompatibilityResult.Problem,
                                       of item: WebExtensionCompatibilityInstallation) {
        problems.append((item, problem))
        order.append("problem")
    }
}

// All preferences stay in memory, including the original persistence keys.
private final class CompatibilityDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func dictionary(forKey name: String) -> [String: Any]? { lock.withLock { values[name] as? [String: Any] } }
    override func set(_ value: Any?, forKey name: String) { lock.withLock { values[name] = value } }
}

@MainActor
private final class CompatibilityGate<Value> {
    var pending: [CheckedContinuation<Value, Never>] = []
    var returned = 0
    func next() async -> Value {
        let value = await withCheckedContinuation { pending.append($0) }
        returned += 1
        return value
    }
}

@MainActor
private final class CompatibilityFixture {
    let host = CompatibilityHost()
    let defaults = CompatibilityDefaults(suiteName: nil)!
    let room: URL
    let manifest: ExtensionManifest
    var contexts: [UUID: [String: WKWebExtensionContext]]
    var missing: Set<String> = ["proxy"]
    var errors: [WKWebExtensionContext] = []
    var table: ExtensionAPITable? = ExtensionAPITable(answers: [:])
    lazy var runtime = makeRuntime()
    var item: WebExtensionCompatibilityInstallation { host.items[0] }

    init(room: URL, manifest: ExtensionManifest, package: WKWebExtension) {
        self.room = room
        self.manifest = manifest
        contexts = [UUID(): ["fixture": WKWebExtensionContext(for: package)],
                    UUID(): ["fixture": WKWebExtensionContext(for: package)]]
    }

    func makeRuntime() -> WebKitExtensionCompatibility {
        let runtime = WebKitExtensionCompatibility(host: host,
            contexts: { [unowned self] in self.contexts }, manifests: { [unowned self] in ["fixture": self.manifest] },
            lacking: { [unowned self] in ["fixture": self.missing] }, setMissing: { [unowned self] missing, _ in self.missing = missing },
            errorsChanged: { [unowned self] context, _, _ in self.errors.append(context); self.host.order.append("errors") },
            package: { [unowned self] _, version in self.room.appendingPathComponent("\(version).zip") },
            prepared: { [unowned self] _, version in self.room.appendingPathComponent(version) },
            application: { "fixture-app" }, scheme: "chrome-extension", shimApplication: "fixture-shim",
            letRulesRedirect: { _, _ in XCTFail("A test must not grant permissions") },
            sites: { _ in XCTFail("A test must not grant sites"); return [] },
            fence: { _ in XCTFail("A test must not change grants") }, defaults: defaults)
        runtime.tableForTesting = { [unowned self] in self.table }
        runtime.measureForTesting = { XCTFail("A test must inject measurement"); return nil }
        runtime.delayForTesting = {}
        runtime.trialForTesting = { _, _, _, _ in XCTFail("A test must inject a trial"); return .init() }
        runtime.scanForTesting = { _, _, _ in XCTFail("A test must inject a scan"); return [] }
        runtime.environmentForTesting = .init(system: "fixture-os", application: "fixture-app", shim: "fixture-shim")
        return runtime
    }
}

final class ExtensionCompatibilityTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> CompatibilityFixture {
        let room = FileManager.default.temporaryDirectory.appendingPathComponent("compatibility-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: room) }
        let json = Data(#"{"manifest_version":3,"name":"Compatibility fixture","version":"1","permissions":["proxy"],"action":{"default_popup":"popup.html"},"options_page":"options.html","content_scripts":[{"matches":["<all_urls>"],"js":["content.js"]}]}"#.utf8)
        try json.write(to: room.appendingPathComponent("manifest.json"))
        for file in ["popup.html", "options.html", "content.js"] { try Data().write(to: room.appendingPathComponent(file)) }
        // Parsed only. No controller, website store, window or worker is made.
        let package = try await WKWebExtension(resourceBaseURL: room)
        return CompatibilityFixture(room: room, manifest: try ExtensionManifest(json: json), package: package)
    }

    @MainActor
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("The injected operation did not finish", file: file, line: line)
    }

    @MainActor
    func testScanCacheIsSynchronousAcrossSpacesAndChangesWithVersionAndMissingAPIs() async throws {
        let f = try await fixture()
        let gate = CompatibilityGate<[String]>()
        var files: [String] = []
        f.runtime.scanForTesting = { file, _, _ in files.append(file.lastPathComponent); return await gate.next() }
        f.runtime.readCode(of: f.item)
        f.runtime.readCode(of: f.item)
        await until { gate.pending.count == 1 }
        XCTAssertTrue(f.host.events.isEmpty)
        gate.pending[0].resume(returning: ["proxy.settings"])
        await until { f.host.events.count == 2 }
        XCTAssertEqual(Set(f.host.events.map(\.0)), Set(f.contexts.keys))
        XCTAssertTrue(f.host.events.allSatisfy { $0.1 == .notes(["proxy.settings"]) })
        f.runtime.readCode(of: f.item)
        XCTAssertEqual(f.host.events.count, 4)
        XCTAssertEqual(files, ["1.zip"])
        f.host.items = [.init(id: "fixture", version: "2")]
        f.runtime.readCode(of: f.item)
        await until { gate.pending.count == 2 }
        gate.pending[1].resume(returning: ["proxy"])
        await until { f.host.events.count == 6 }
        f.missing.insert("bookmarks")
        f.runtime.readCode(of: f.item)
        await until { gate.pending.count == 3 }
        gate.pending[2].resume(returning: ["bookmarks"])
        await until { f.host.events.count == 8 }
        XCTAssertEqual(files, ["1.zip", "2.zip", "2.zip"])
        XCTAssertEqual(f.runtime.scanned["fixture"]?.key, "2|bookmarks,proxy")
    }

    @MainActor
    func testLateScanCannotReplaceANewerAttemptAtTheSameVersionOrANewerVersion() async throws {
        let f = try await fixture()
        let gate = CompatibilityGate<[String]>()
        f.runtime.scanForTesting = { _, _, _ in await gate.next() }
        f.runtime.readCode(of: f.item)
        await until { gate.pending.count == 1 }
        // keep's same-version invalidation, kept in exactly this order.
        f.runtime.forgetCheck("fixture")
        f.runtime.scanned["fixture"] = nil
        f.runtime.scanning["fixture"] = nil
        f.runtime.readCode(of: f.item)
        await until { gate.pending.count == 2 }
        gate.pending[1].resume(returning: ["fresh same version"])
        await until { f.host.events.count == 2 }
        gate.pending[0].resume(returning: ["old attempt"])
        await until { gate.returned == 2 }
        XCTAssertEqual(f.host.events.count, 2)
        XCTAssertEqual(f.runtime.scanned["fixture"]?.notes, ["fresh same version"])
        // Another scan is overtaken by a version change.
        f.runtime.scanned["fixture"] = nil
        f.runtime.readCode(of: f.item)
        await until { gate.pending.count == 3 }
        f.host.items = [.init(id: "fixture", version: "2")]
        f.runtime.readCode(of: f.item)
        await until { gate.pending.count == 4 }
        gate.pending[3].resume(returning: ["current"])
        await until { f.host.events.count == 4 }
        gate.pending[2].resume(returning: ["old version"])
        await until { gate.returned == 4 }
        XCTAssertEqual(f.host.events.count, 4)
        XCTAssertEqual(f.runtime.scanned["fixture"]?.notes, ["current"])
        XCTAssertEqual(f.runtime.scanned["fixture"]?.key, "2|proxy")
        XCTAssertNil(f.runtime.scanning["fixture"])
    }

    @MainActor
    func testTrialPublishesCheckingInlineThenRecordsBeforeEvidenceAndReusesPersistence() async throws {
        let f = try await fixture()
        let gate = CompatibilityGate<ExtensionTrial.Checked>()
        let problem = ExtensionError.Problem(kind: .notAFunction, api: "proxy.settings")
        let result = ExtensionTrial.Checked(testPage: .passed, popup: .failed, optionsPage: .timedOut,
                                            problems: [(problem, "popup.html")])
        f.runtime.trialForTesting = { [unowned f] folder, id, manifest, missing in
            XCTAssertEqual(folder.lastPathComponent, "1")
            XCTAssertEqual(id, "fixture")
            XCTAssertEqual(manifest, f.manifest)
            XCTAssertEqual(missing, ["proxy"])
            return await gate.next()
        }
        f.runtime.checkCopy(of: f.item)
        XCTAssertEqual(f.host.events.count, 2)
        XCTAssertTrue(f.host.events.allSatisfy { $0.1 == .checking(testPage: true, popup: true, optionsPage: true) })
        f.runtime.checkCopy(of: f.item)
        await until { gate.pending.count == 1 }
        gate.pending[0].resume(returning: result)
        await until { f.host.events.count == 4 }
        XCTAssertEqual(f.host.order, ["evidence", "evidence", "problem", "evidence", "evidence"])
        let expected = WebExtensionCompatibilityResult(testPage: .passed, popup: .failed, optionsPage: .timedOut,
            problems: [.init(kind: .notAFunction, api: "proxy.settings", file: "popup.html")])
        XCTAssertEqual(f.host.events.last?.1, .checked(expected))
        XCTAssertEqual(f.host.problems.first?.0, f.item)
        XCTAssertEqual(f.host.problems.first?.1, expected.problems[0])
        let kept = try XCTUnwrap(f.defaults.dictionary(forKey: "extensionsPagesTried")?["fixture"] as? [String: Any])
        XCTAssertEqual(kept["stamp"] as? String, "1|fixture-os|fixture-app|fixture-shim")
        XCTAssertEqual(kept["problems"] as? [String], ["notAFunction proxy.settings"])
        f.runtime.checkCopy(of: f.item)
        XCTAssertEqual(f.host.events.count, 6)
        XCTAssertEqual(f.host.problems.count, 1)
        // A new runtime reads the persisted result inline, with no file retained.
        f.runtime = f.makeRuntime()
        f.runtime.checkCopy(of: f.item)
        XCTAssertEqual(f.host.events.count, 8)
        let restored = WebExtensionCompatibilityResult(testPage: .passed, popup: .failed, optionsPage: .timedOut,
            problems: [.init(kind: .notAFunction, api: "proxy.settings", file: nil)])
        XCTAssertEqual(f.host.events.last?.1, .checked(restored))
        f.runtime.forgetCheck("fixture")
        XCTAssertNil(f.runtime.checked["fixture"])
        XCTAssertNil(f.defaults.dictionary(forKey: "extensionsPagesTried")?["fixture"])
    }

    @MainActor
    func testOldTrialIsDroppedBeforeSavingAndStartsTheCurrentVersionOnlyWhenLoaded() async throws {
        let f = try await fixture()
        let gate = CompatibilityGate<ExtensionTrial.Checked>()
        var versions: [String] = []
        f.runtime.trialForTesting = { folder, _, _, _ in versions.append(folder.lastPathComponent); return await gate.next() }
        f.runtime.checkCopy(of: f.item)
        await until { gate.pending.count == 1 }
        f.host.items = [.init(id: "fixture", version: "2")]
        f.runtime.checkCopy(of: f.item)
        XCTAssertEqual(versions, ["1"])
        gate.pending[0].resume(returning: .init(testPage: .failed))
        await until { gate.pending.count == 2 }
        XCTAssertEqual(versions, ["1", "2"])
        XCTAssertNil(f.runtime.checked["fixture"])
        XCTAssertNil(f.defaults.dictionary(forKey: "extensionsPagesTried"))
        XCTAssertTrue(f.host.events.allSatisfy { if case .checking = $0.1 { return true }; return false })
        gate.pending[1].resume(returning: .init(testPage: .passed))
        await until { f.runtime.checked["fixture"] != nil }
        XCTAssertEqual(f.runtime.checked["fixture"]?.version, "2|fixture-os|fixture-app|fixture-shim")
        XCTAssertEqual(f.host.events.last?.1, .checked(.init(testPage: .passed, popup: .notApplicable, optionsPage: .notApplicable, problems: [])))
        // Removal while a trial runs neither saves nor publishes its result.
        f.runtime.forgetCheck("fixture")
        f.runtime.checkCopy(of: f.item)
        await until { gate.pending.count == 3 }
        f.host.items = []
        let count = f.host.events.count
        gate.pending[2].resume(returning: .init(testPage: .failed))
        await until { gate.returned == 3 }
        XCTAssertEqual(f.host.events.count, count)
        XCTAssertNil(f.runtime.checked["fixture"])
        XCTAssertNil(f.defaults.dictionary(forKey: "extensionsPagesTried")?["fixture"])
    }

    @MainActor
    func testStampsInvalidateEveryEnvironmentPartAndRejectLegacyAndRemovedFailures() async throws {
        let f = try await fixture()
        let stamp = f.runtime.checkStamp("1")
        XCTAssertEqual(stamp, "1|fixture-os|fixture-app|fixture-shim")
        let held = ["fixture": stamp, "legacy": "1", "removed": stamp]
        XCTAssertEqual(f.runtime.currentFailures(held, installed: ["fixture": "1", "legacy": "1"]), ["fixture": stamp])
        XCTAssertTrue(f.runtime.currentFailures(held, installed: ["fixture": "2"]).isEmpty)
        for changed in [ExtensionCheckEnvironment(system: "new", application: "fixture-app", shim: "fixture-shim"),
                        .init(system: "fixture-os", application: "new", shim: "fixture-shim"),
                        .init(system: "fixture-os", application: "fixture-app", shim: "new")] {
            f.runtime.environmentForTesting = changed
            XCTAssertNotEqual(f.runtime.checkStamp("1"), stamp)
            XCTAssertTrue(f.runtime.currentFailures(held, installed: ["fixture": "1"]).isEmpty)
        }
    }

    @MainActor
    func testPersistedProbeWordsAndProblemsKeepTheirOriginalDecoding() async throws {
        let f = try await fixture()
        let words: [(String, WebExtensionCompatibilityResult.Probe)] = [
            ("none", .notApplicable), ("checking", .notApplicable), ("passed", .passed),
            ("failed", .failed), ("skipped", .skipped), ("timedOut", .timedOut), ("unknown", .notApplicable)
        ]
        for (word, probe) in words {
            f.defaults.set(["fixture": ["stamp": f.runtime.checkStamp("1"), "testPage": word,
                "popup": "skipped", "optionsPage": "passed", "problems": ["missing proxy", "notAFunction tabs.query",
                    "wrongArguments tabs.update", "missing alice@example.com", "unknown tabs", "missing"]]], forKey: "extensionsPagesTried")
            f.runtime = f.makeRuntime()
            let count = f.host.events.count
            f.runtime.checkCopy(of: f.item)
            XCTAssertEqual(f.host.events.count, count + 2)
            XCTAssertEqual(f.host.events.last?.1, .checked(.init(testPage: probe, popup: .skipped, optionsPage: .passed,
                problems: [.init(kind: .missing, api: "proxy", file: nil),
                           .init(kind: .notAFunction, api: "tabs.query", file: nil),
                           .init(kind: .wrongArguments, api: "tabs.update", file: nil)])))
            XCTAssertTrue(f.host.problems.isEmpty)
        }
    }

    @MainActor
    func testEnvironmentChangeAndExplicitInvalidationRetryACachedTrial() async throws {
        let f = try await fixture()
        f.defaults.set(["fixture": ["stamp": f.runtime.checkStamp("1"), "testPage": "failed"]], forKey: "extensionsPagesTried")
        f.runtime = f.makeRuntime()
        f.runtime.environmentForTesting = .init(system: "new-os", application: "fixture-app", shim: "fixture-shim")
        let gate = CompatibilityGate<ExtensionTrial.Checked>()
        f.runtime.trialForTesting = { _, _, _, _ in await gate.next() }
        f.runtime.checkCopy(of: f.item)
        XCTAssertEqual(f.host.events.count, 2)
        await until { gate.pending.count == 1 }
        gate.pending[0].resume(returning: .init(testPage: .skipped, popup: .checking))
        await until { f.host.events.count == 4 }
        XCTAssertEqual(f.runtime.checked["fixture"]?.version, "1|new-os|fixture-app|fixture-shim")
        XCTAssertEqual(f.host.events.last?.1, .checked(.init(testPage: .skipped, popup: .checking, optionsPage: .notApplicable, problems: [])))
        let kept = try XCTUnwrap(f.defaults.dictionary(forKey: "extensionsPagesTried")?["fixture"] as? [String: Any])
        XCTAssertEqual(kept["popup"] as? String, "checking")
        XCTAssertEqual(kept["optionsPage"] as? String, "none")
        f.runtime.forgetCheck("fixture")
        f.runtime.checkCopy(of: f.item)
        await until { gate.pending.count == 2 }
        gate.pending[1].resume(returning: .init(testPage: .passed))
        await until { f.host.events.count == 8 }
        XCTAssertEqual(f.runtime.checked["fixture"]?.result.testPage, .passed)
    }

    @MainActor
    func testMeasuredTableRechecksMissingAPIsThenScansThenErrorsWithoutChangingContextIdentity() async throws {
        let f = try await fixture()
        f.table = nil
        f.runtime.measureForTesting = { [unowned f] in
            f.host.order.append("measure")
            f.table = ExtensionAPITable(answers: ["proxy": .native])
            return f.table
        }
        // A cached scan makes its publication inline, before errors are reread.
        f.runtime.scanned["fixture"] = ("1|", ["cached"])
        await f.runtime.measureTable()
        XCTAssertTrue(f.missing.isEmpty)
        XCTAssertEqual(f.host.order, ["measure", "evidence", "evidence", "errors", "errors"])
        XCTAssertEqual(Set(f.errors.map(ObjectIdentifier.init)), Set(f.contexts.values.compactMap { $0["fixture"] }.map(ObjectIdentifier.init)))
        await f.runtime.measureTable()
        XCTAssertEqual(f.host.order.count, 5)
    }
}
#endif
