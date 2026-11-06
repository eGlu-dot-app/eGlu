#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

@MainActor
private final class EvidenceHost: ExtensionEvidenceHost {
    var extensionEvidenceAppVersion: String { "fixture.1" }
    var extensionEvidenceOSVersion: String { "26.0.1" }
    var installation: WebExtensionEvidenceInstallation? = .init(id: "fixture", version: "1")
    var restarting = false
    var events: [String] = []
    var received: [WebExtensionEvidence] = []
    var onRecovery: ((Bool) -> Void)?
    var onEvidence: ((WebExtensionEvidence) -> Void)?

    func extensionErrorsChanged(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery {
        events.append("recovery \(failed)")
        onRecovery?(failed)
        return .init(installation: installation, restarting: restarting)
    }

    func extensionEvidenceChanged(_ seen: WebExtensionEvidence, _ id: String, in space: UUID) {
        events.append("evidence")
        received.append(seen)
        onEvidence?(seen)
    }
}

final class ExtensionEvidenceTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let space = UUID()
        let host = EvidenceHost()
        let context: WKWebExtensionContext
        let manifest: ExtensionManifest
        let defaults: UserDefaults
        var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
        var errors: [any Error] = []
        var reads = 0
        var debugError: ((String, () -> String) -> Void)?
        var recordsFile: URL { root.appendingPathComponent("records/records.json") }
        lazy var runtime = WebKitExtensionEvidence(host: host,
            contexts: { [unowned self] in self.contexts }, manifests: { [unowned self] in ["fixture": self.manifest] },
            folder: { [unowned self] in self.recordsFile.deletingLastPathComponent() },
            recordsFile: { [unowned self] in self.recordsFile }, defaults: defaults,
            readErrors: { [unowned self] _ in
                self.reads += 1
                return self.errors
            }, debugError: { [unowned self] in self.debugError?($0, $1) })

        init(root: URL, context: WKWebExtensionContext, manifest: ExtensionManifest, defaults: UserDefaults) {
            self.root = root; self.context = context; self.manifest = manifest; self.defaults = defaults
            contexts[space] = ["fixture": context]
        }

        func error(_ text: String, worker: Bool = false) -> NSError {
            NSError(domain: worker ? WKWebExtensionContext.errorDomain : "fixture",
                    code: worker ? WKWebExtensionContext.Error.Code.backgroundContentFailedToLoad.rawValue : 1,
                    userInfo: [NSLocalizedDescriptionKey: text])
        }

        func post() {
            NotificationCenter.default.post(name: WKWebExtensionContext.errorsDidUpdateNotification, object: context)
        }
    }

    @MainActor
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let data = Data(#"{"manifest_version":3,"name":"Evidence fixture","version":"1","background":{"service_worker":"bg.js"},"action":{"default_popup":"popup/index.html"},"content_scripts":[{"matches":["https://example.invalid/*"],"js":["content.js"]}]}"#.utf8)
        try data.write(to: root.appendingPathComponent("manifest.json"))
        for name in ["bg.js", "content.js", "popup/index.html"] {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        // Parsed only. No controller, website store, window or worker is made.
        let package = try await WKWebExtension(resourceBaseURL: root)
        let context = WKWebExtensionContext(for: package)
        let suite = "eglu-evidence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // This private suite is only read, never written.
        return Fixture(root: root, context: context, manifest: try ExtensionManifest(json: data), defaults: defaults)
    }

    @MainActor
    func testRepeatedErrorsAreRecordedOnceWithoutKeepingPageWords() async throws {
        let f = try await fixture()
        f.runtime.record(WebExtensionEvidence(), "fixture", in: f.space)
        f.runtime.lacking["fixture"] = ["sidePanel"]
        f.runtime.watch(f.context, "fixture", in: f.space)
        defer { f.runtime.unwatch("fixture", in: f.space) }
        let first = "TypeError: chrome.sidePanel.open is not a function alice@example.invalid https://private.invalid/secret (bg.js:12:5)"
        let second = "TypeError: chrome.sidePanel.open is not a function bob@example.invalid (bg.js:13:5)"
        f.errors = [f.error(first), f.error("private page words without an API")]
        f.post()
        f.post()
        XCTAssertEqual(f.runtime.records(of: "fixture").first?.count, 1)
        f.errors.append(f.error(second))
        f.post()
        let records = f.runtime.records(of: "fixture")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.count, 2)
        XCTAssertEqual(records.first?.place, "worker")
        XCTAssertEqual(records.first?.api, "sidePanel.open")
        XCTAssertEqual(records.first?.kind, "notAFunction")
        let data = try String(contentsOf: f.recordsFile, encoding: .utf8)
        for secret in ["alice", "bob", "private", "secret", "bg.js", "12:5", "page words"] {
            XCTAssertFalse(data.contains(secret), secret)
            XCTAssertFalse(String(describing: f.runtime.recorded).contains(secret), secret)
            XCTAssertFalse(String(describing: f.host.received).contains(secret), secret)
        }
        XCTAssertEqual(f.runtime.recorded["\(f.space.uuidString)/fixture"]?.count, 2)
        XCTAssertFalse(f.context.isLoaded)
    }

    @MainActor
    func testAppDebugCallbackStaysInlineBeforeRecordingAndPublication() async throws {
        let f = try await fixture()
        f.runtime.record(WebExtensionEvidence(), "fixture", in: f.space)
        f.runtime.lacking["fixture"] = ["sidePanel"]
        f.host.events = []
        let words = "TypeError: chrome.sidePanel.open is not a function (bg.js:12:5)"
        f.errors = [f.error(words)]
        var calls = 0
        f.debugError = { api, text in
            calls += 1
            XCTAssertEqual(api, "sidePanel.open")
            XCTAssertEqual(text(), words)
            XCTAssertTrue(f.runtime.records(of: "fixture").isEmpty)
            XCTAssertEqual(f.host.events, ["recovery false"])
            f.host.events.append("debug")
        }
        f.runtime.errorsChanged(f.context, "fixture", in: f.space)
        XCTAssertEqual(f.host.events, ["recovery false", "debug", "evidence"])
        XCTAssertEqual(f.runtime.records(of: "fixture").first?.count, 1)
        f.runtime.errorsChanged(f.context, "fixture", in: f.space)
        XCTAssertEqual(calls, 1)
        f.debugError = nil
    }

    @MainActor
    func testFingerprintLimitIsPerContextAndResetsOnUnloadForward() async throws {
        let f = try await fixture()
        let runtime: any WebExtensionEvidenceRuntime = f.runtime
        for i in 0..<500 { XCTAssertTrue(runtime.recordOnce("one/fixture", "message \(i)")) }
        XCTAssertFalse(runtime.recordOnce("one/fixture", "message 499"))
        XCTAssertFalse(runtime.recordOnce("one/fixture", "message 500"))
        XCTAssertEqual(runtime.recorded["one/fixture"]?.count, 500)
        XCTAssertTrue(runtime.recordOnce("two/fixture", "message 500"))
        runtime.recorded["one/fixture"] = nil
        XCTAssertTrue(runtime.recordOnce("one/fixture", "message 0"))
        XCTAssertFalse(runtime.recordOnce("one/fixture", "message 0"))
        XCTAssertEqual(WebKitExtensionEvidence.fingerprint(""), String(UInt64(0xCBF2_9CE4_8422_2325), radix: 36))
        XCTAssertEqual(runtime.recorded["one/fixture"], [WebKitExtensionEvidence.fingerprint("message 0")])
    }

    @MainActor
    func testPruningOnReadAndQueryAlsoRewritesTheFile() async throws {
        let f = try await fixture()
        let old = Date().addingTimeInterval(-31 * 86_400)
        var kept = ExtensionRecords()
        kept.note(.init(id: "fixture", version: "1", eglu: "old", macOS: "old", shim: "old", place: "page",
                        api: "tabs.query", kind: "wrongArguments", first: old, last: old), now: old)
        f.runtime.recordCollection = kept
        f.runtime.saveRecords()
        f.runtime.recordCollection = ExtensionRecords()
        f.runtime.readRecords()
        XCTAssertTrue(f.runtime.recordCollection.records.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(ExtensionRecords.self, from: Data(contentsOf: f.recordsFile)).records.isEmpty)
        f.runtime.recordCollection = kept
        f.runtime.saveRecords()
        XCTAssertTrue(f.runtime.records(of: "fixture").isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(ExtensionRecords.self, from: Data(contentsOf: f.recordsFile)).records.isEmpty)
        // A missing or damaged file leaves the collection already held alone.
        let item = WebExtensionEvidenceInstallation(id: "fixture", version: "1")
        f.runtime.note(.init(kind: .missing, api: "sidePanel"), file: nil, of: item)
        let before = f.runtime.recordCollection
        try Data("broken".utf8).write(to: f.recordsFile)
        f.runtime.readRecords()
        XCTAssertEqual(f.runtime.recordCollection, before)
        try FileManager.default.removeItem(at: f.recordsFile)
        f.runtime.readRecords()
        XCTAssertEqual(f.runtime.recordCollection, before)
    }

    @MainActor
    func testRecordsKeepTwoHundredPerExtensionAndClassifyFiles() async throws {
        let f = try await fixture()
        let item = WebExtensionEvidenceInstallation(id: "fixture", version: "1")
        for (file, place) in [("bg.js", "worker"), ("content.js", "content script"), ("popup/a.js", "popup"), ("other.js", "page")] {
            f.runtime.note(.init(kind: .missing, api: "sidePanel"), file: file, of: item)
            XCTAssertTrue(f.runtime.records(of: "fixture").contains { $0.place == place })
        }
        for i in 0..<205 { f.runtime.note(.init(kind: .wrongArguments, api: "tabs.api\(i)"), file: nil, of: item) }
        let records = f.runtime.records(of: "fixture")
        XCTAssertEqual(records.count, 200)
        XCTAssertFalse(records.contains { $0.api == "tabs.api0" })
        XCTAssertTrue(records.contains { $0.api == "tabs.api204" })
        f.runtime.note(.init(kind: .missing, api: "sidePanel"), file: nil, of: .init(id: "other", version: "1"))
        XCTAssertEqual(f.runtime.records(of: "other").count, 1)
        XCTAssertEqual(f.runtime.records(of: "fixture").count, 200)
    }

    @MainActor
    func testAtomicReplacementInTemporaryRootKeepsOriginalOpenFileWhole() async throws {
        let f = try await fixture()
        let runtime: any WebExtensionEvidenceRuntime = f.runtime
        let item = WebExtensionEvidenceInstallation(id: "fixture", version: "1")
        runtime.note(.init(kind: .missing, api: "sidePanel"), file: "bg.js", of: item)
        let before = try Data(contentsOf: f.recordsFile)
        let open = try FileHandle(forReadingFrom: f.recordsFile)
        defer { try? open.close() }
        runtime.note(.init(kind: .notAFunction, api: "tabs.discard"), file: nil, of: item)
        XCTAssertEqual(try open.readToEnd(), before, "Atomic replacement leaves the old open file intact")
        let after = try Data(contentsOf: f.recordsFile)
        XCTAssertNotEqual(after, before)
        let records = try JSONDecoder().decode(ExtensionRecords.self, from: after).of("fixture")
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.eglu == "fixture.1" && $0.macOS == "26.0.1" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: [[String: Any]]])
        XCTAssertEqual(json["records"]?.first?["safience"] as? String, "fixture.1")
        XCTAssertNil(json["records"]?.first?["eglu"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.recordsFile.deletingLastPathComponent().path), ["records.json"])
    }

    @MainActor
    func testEvidenceEventsStayInlineInRecoverySaveAndPublicationOrder() async throws {
        let f = try await fixture()
        var inside = true
        f.host.onEvidence = { [weak f] seen in
            guard let f else { return XCTFail("Fixture was released") }
            XCTAssertTrue(inside)
            XCTAssertEqual(f.runtime.evidence[f.space]?["fixture"], seen, "Evidence is stored before publication")
        }
        f.runtime.record(WebExtensionEvidence(), "fixture", in: f.space)
        XCTAssertEqual(f.host.received.count, 1)
        f.host.restarting = true
        f.host.events = []
        f.errors = [f.error("chrome.tabs.discard is not a function (bg.js:1:1)", worker: true)]
        f.host.onEvidence = { seen in
            XCTAssertTrue(inside)
            XCTAssertEqual(f.host.events, ["recovery true", "evidence"])
            XCTAssertEqual(try? JSONDecoder().decode(ExtensionRecords.self, from: Data(contentsOf: f.recordsFile)).of("fixture").count, 1,
                           "The record is saved before the evidence callback")
            XCTAssertEqual(seen.start, .failed)
        }
        f.runtime.watch(f.context, "fixture", in: f.space)
        defer { f.runtime.unwatch("fixture", in: f.space) }
        f.post()
        XCTAssertEqual(f.host.received.count, 2)
        inside = false
        XCTAssertEqual(f.reads, 2, "The error list is read before recovery and again inside the evidence update")
        f.runtime.unwatch("fixture", in: f.space)
        f.post()
        XCTAssertEqual(f.host.received.count, 2)
        f.host.onEvidence = nil
        f.contexts = [:]
        f.runtime.errorsChanged(f.context, "fixture", in: f.space)
        XCTAssertEqual(f.host.received.count, 2, "An obsolete context cannot publish")
    }


    @MainActor
    func testRecoveryCanRemoveEvidenceBeforeTheSecondErrorRead() async throws {
        let f = try await fixture()
        f.runtime.record(WebExtensionEvidence(), "fixture", in: f.space)
        f.host.events = []
        f.errors = [f.error("chrome.tabs.discard is not a function (bg.js:1:1)", worker: true)]
        f.host.onRecovery = { [weak f] _ in
            guard let f else { return }
            // The app's recovery may synchronously unload the context.
            f.runtime.evidence[f.space]?["fixture"] = nil
            f.contexts[f.space]?["fixture"] = nil
        }
        f.runtime.errorsChanged(f.context, "fixture", in: f.space)
        XCTAssertEqual(f.host.events, ["recovery true"])
        XCTAssertEqual(f.reads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.recordsFile.path))
        XCTAssertEqual(f.host.received.count, 1)
    }

    @MainActor
    func testErrorListIsReadAgainAfterInlineRecoveryAndUpdatesStayInOrder() async throws {
        let f = try await fixture()
        var seen = WebExtensionEvidence()
        seen.start = .started
        f.runtime.record(seen, "fixture", in: f.space)
        f.host.events = []
        f.errors = [f.error("worker failed", worker: true)]
        f.host.onRecovery = { [weak f] _ in
            guard let f else { return }
            f.errors = [f.error("chrome.tabs.discard is not a function (content.js:2:3)")]
        }
        f.runtime.errorsChanged(f.context, "fixture", in: f.space)
        XCTAssertEqual(f.reads, 2)
        XCTAssertEqual(f.host.events, ["recovery true", "evidence"])
        XCTAssertEqual(f.host.received.last?.start, .started)
        XCTAssertEqual(f.runtime.records(of: "fixture").first?.place, "content script")
        var inside = true
        var order: [String] = []
        f.host.onEvidence = { _ in
            XCTAssertTrue(inside)
            order.append("published")
        }
        f.runtime.update("fixture", in: f.space) {
            order.append("changed")
            $0.cookiesKeptBack = true
        }
        order.append("returned")
        inside = false
        XCTAssertEqual(order, ["changed", "published", "returned"])
        XCTAssertEqual(f.runtime.evidence[f.space]?["fixture"]?.cookiesKeptBack, true)
    }

    @MainActor
    func testMissingEvidenceRecoversButDoesNotReadErrorsAgainOrPublish() async throws {
        let f = try await fixture()
        f.errors = [f.error("worker failed", worker: true)]
        f.runtime.errorsChanged(f.context, "fixture", in: f.space)
        XCTAssertEqual(f.host.events, ["recovery true"])
        XCTAssertEqual(f.reads, 1)
        f.runtime.update("missing", in: f.space) { _ in XCTFail("No evidence to update") }
        XCTAssertTrue(f.host.received.isEmpty)
    }
}
#endif
