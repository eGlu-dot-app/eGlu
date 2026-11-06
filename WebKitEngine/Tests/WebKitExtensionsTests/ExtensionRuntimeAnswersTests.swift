#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

private struct RuntimeRefusal: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

@MainActor
private final class AnswerContext: WKWebExtensionContext {
    var statuses: [String: PermissionStatus] = [:]
    override func permissionStatus(for permission: WKWebExtension.Permission) -> PermissionStatus {
        statuses[permission.rawValue] ?? super.permissionStatus(for: permission)
    }
}

@MainActor
private final class AnswerEvidence: WebExtensionEvidenceRuntime {
    var evidence: [UUID: [String: WebExtensionEvidence]] = [:]
    var lacking: [String: Set<String>] = [:]
    var recorded: [String: Set<String>] = [:]
    var log: [String] = []
    var notes: [(WebExtensionEvidence.Problem, String?, WebExtensionEvidenceInstallation)] = []
    func recordOnce(_ key: String, _ text: String) -> Bool {
        log.append("deduplicate")
        return recorded[key, default: []].insert(text).inserted
    }
    func note(_ problem: WebExtensionEvidence.Problem, file: String?, of item: WebExtensionEvidenceInstallation) {
        log.append("note"); notes.append((problem, file, item))
    }
    func readRecords() {}
    func pruneRecords() {}
    func saveRecords() {}
    func records(of id: String) -> [WebExtensionErrorRecord] { [] }
    func update(_ id: String, in space: UUID, _ change: (inout WebExtensionEvidence) -> Void) {}
    func record(_ seen: WebExtensionEvidence, _ id: String, in space: UUID) {}
}

@MainActor
private final class AnswerHost: ExtensionRuntimeAnswerHost {
    let evidence = AnswerEvidence()
    var optional = true
    var reaches = false
    var consent = false
    var prompts: [(String, UUID)] = []
    var texts: [String] = []
    var colour: NSColor? = NSColor(srgbRed: 0.5, green: 0.25, blue: 1, alpha: 0.2)
    var colourCalls = 0
    var events: [(String, UUID, WebExtensionRuntimeAnswerEvent)] = []
    var item: WebExtensionEvidenceInstallation? = .init(id: "fixture", version: "1")
    func extensionRuntimeInstallation(_ id: String) -> WebExtensionEvidenceInstallation? {
        evidence.log.append("installation"); return item
    }
    func updateExtensionRuntimeAnswer(_ id: String, in space: UUID, event: WebExtensionRuntimeAnswerEvent) {
        evidence.log.append("update"); events.append((id, space, event))
    }
    func extensionNativeIsOptional(_ id: String) -> Bool { optional }
    func extensionReachesApps(_ id: String) -> Bool { reaches }
    func setExtensionNativeConsent(_ id: String, _ on: Bool) { evidence.log.append("consent \(on)"); reaches = on }
    func requestExtensionNative(title: String, in space: UUID, icon: () -> NSImage?) async -> Bool {
        evidence.log.append("prompt"); prompts.append((title, space)); _ = icon(); return consent
    }
    func detectExtensionLanguage(_ text: String) -> [String: Any] {
        texts.append(text); return ["isReliable": true, "languages": [["language": "en", "percentage": 100]]]
    }
    func sampleExtensionColour() async -> NSColor? { colourCalls += 1; return colour }
    func noteExtensionRuntimeReport(_ api: String?, words: () -> String?) { evidence.log.append("debug \(api ?? "none")") }
    func releaseExtensionPage(_ view: NSView) { XCTFail("No real page") }
    func extensionDisplayDecision(for view: NSView) -> Int { XCTFail("No recording"); return 0 }
    func watchExtensionPage(_ view: NSView, id: String) { XCTFail("No real page") }
    func requestExtensionMedia(_ media: ExtensionPageMedia, name: String, reply: @escaping @MainActor (Bool) -> Void) {
        XCTFail("No media prompt")
    }
}

@MainActor
private final class AnswerServices: ExtensionRuntimeServices {
    var locked = false
    var seconds = 20.0
    var log: [String] = []
    var next: IOPMAssertionID? = 1
    var created: [(String, String)] = []
    var backgrounds: [WKWebExtensionContext] = []
    var background: ((@escaping (Error?) -> Void) -> Void) = { $0(nil) }
    var deadlines: [() -> Void] = []
    var pauses = 0
    var offscreen: (String, Set<String>, WKWebExtensionContext, UUID, String, any ExtensionAuxiliaryPageHost)?
    var hasPage = false
    func session() -> [String: Any]? { log.append("session"); return ["CGSSessionScreenIsLocked": locked] }
    func quiet() -> Double { log.append("quiet"); return seconds }
    func createAssertion(_ kind: CFString, why: CFString) -> IOPMAssertionID? {
        log.append("create"); created.append((kind as String, why as String)); return next
    }
    func release(_ assertion: IOPMAssertionID) { log.append("release \(assertion)") }
    func activity() { log.append("activity") }
    func loadBackground(_ context: WKWebExtensionContext, completion: @escaping (Error?) -> Void) {
        backgrounds.append(context); background(completion)
    }
    func after(_ seconds: TimeInterval, perform: @escaping () -> Void) { XCTAssertEqual(seconds, 8); deadlines.append(perform) }
    func pause() async throws { pauses += 1 }
    func createOffscreen(_ path: String, reasons: Set<String>, for context: WKWebExtensionContext, in space: UUID,
                         scheme: String, host: any ExtensionAuxiliaryPageHost) async throws {
        offscreen = (path, reasons, context, space, scheme, host); hasPage = true
    }
    func closeOffscreen(_ id: String, in space: UUID) { log.append("close \(space)/\(id)"); hasPage = false }
    func hasOffscreen(_ id: String, in space: UUID) -> Bool { log.append("has \(space)/\(id)"); return hasPage }
}

@MainActor
private final class AnswerPort: ExtensionRuntimePort {
    var applicationIdentifier: String?
    init(_ name: String?) { applicationIdentifier = name }
}

@MainActor
private final class AnswerTransports: ExtensionRuntimeTransports {
    var messages: [(Any, String, String)] = []
    var native: [(any ExtensionRuntimePort, String)] = []
    var sockets: [(any ExtensionRuntimePort, String, UUID, String?, String)] = []
    var failure: RuntimeRefusal?
    func send(_ message: Any, to name: String, from id: String) async throws -> Any? {
        messages.append((message, name, id)); if let failure { throw failure }; return ["answer": 7]
    }
    func connectNative(_ port: any ExtensionRuntimePort, from id: String) throws {
        native.append((port, id)); if let failure { throw failure }
    }
    func connectSocket(_ port: any ExtensionRuntimePort, from id: String, in space: UUID, policy: String?, scheme: String) {
        sockets.append((port, id, space, policy, scheme))
    }
}

@MainActor
private final class AnswerFixture {
    let host = AnswerHost(), services = AnswerServices(), transports = AnswerTransports()
    let space = UUID()
    let context: WKWebExtensionContext
    let controller: WKWebExtensionController
    var current: WKWebExtensionContext?
    var knownController = true
    var revivals: [(String, UUID, String)] = []
    var calls: [(String, [Any], WKWebExtensionContext, UUID)] = []
    var shimResult: Any?
    var shimError: RuntimeRefusal?
    lazy var runtime = WebKitExtensionRuntimeAnswers(host: host, evidence: { [unowned self] in self.host.evidence },
        contexts: { [unowned self] in self.current.map { [self.space: ["fixture": $0]] } ?? [:] },
        space: { [unowned self] in self.knownController && $0 === self.controller ? self.space : nil },
        revive: { [unowned self] in self.revivals.append(($0, $1, $2)); return true },
        answer: { [unowned self] in self.calls.append(($0, $1, $2, $3)); if let error = self.shimError { throw error }; return self.shimResult },
        unanswered: { RuntimeRefusal(why: $0) }, scheme: "chrome-extension", shimApplication: "eglu",
        services: services, transports: transports)

    init(_ context: WKWebExtensionContext) {
        self.context = context; current = context
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = .nonPersistent()
        controller = WKWebExtensionController(configuration: configuration)
    }
    func answer(_ api: String, _ args: [Any] = []) async throws -> Any? {
        let value = try await runtime.answer(api, args, id: "fixture", context: context, in: space)
        if ["report", "background.wake", "offscreen.createDocument", "offscreen.closeDocument",
            "power.requestKeepAwake", "power.releaseKeepAwake", "power.reportActivity"].contains(api) {
            XCTAssertNil(value)
        }
        return value
    }
    func message(_ name: String?, _ message: Any) async -> (Any?, (any Error)?) {
        var result: (Any?, (any Error)?) = (nil, nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            runtime.webExtensionController(controller, sendMessage: message, toApplicationWithIdentifier: name, for: context) {
                result = ($0, $1)
                done.resume()
            }
        }
        return result
    }
    func port(_ name: String?, _ completion: @escaping ((any Error)?) -> Void) -> AnswerPort {
        let port = AnswerPort(name)
        runtime.connect(controller, port: port, context: context, completionHandler: completion)
        return port
    }
}

final class ExtensionRuntimeAnswersTests: XCTestCase {
    @MainActor private func fixture(background: Bool = true, permissions: [String] = ["idle", "power"],
                                    optional: [String] = [], security: Any = ["extension_pages": "connect-src 'self'"]) async throws -> AnswerFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-answers-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Runtime fixture", "version": "1",
                                        "permissions": permissions, "optional_permissions": optional, "content_security_policy": security]
        if background { manifest["background"] = ["service_worker": "worker.js"] }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("// Fixture, never executed.\n".utf8).write(to: folder.appendingPathComponent("worker.js"))
        let package = try await WKWebExtension(resourceBaseURL: folder)
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let context = AnswerContext(for: package)
        context.uniqueIdentifier = "fixture"
        context.baseURL = URL(string: "chrome-extension://fixture/")!
        XCTAssertFalse(context.isLoaded)
        return AnswerFixture(context)
    }

    @MainActor private func refuses(_ f: AnswerFixture, _ api: String, _ args: [Any] = [], _ words: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await f.answer(api, args); XCTFail("Expected refusal", file: file, line: line) }
        catch { XCTAssertEqual(error.localizedDescription, words, file: file, line: line) }
    }

    @MainActor func testIdleThresholdLockAndPermissions() async throws {
        let f = try await fixture()
        let active = try await f.answer("idle.queryState")
        XCTAssertEqual(active as? String, "active")
        let idle = try await f.answer("idle.queryState", [1.0])
        XCTAssertEqual(idle as? String, "idle")
        f.services.seconds = 14
        let underMinimum = try await f.answer("idle.queryState", [1.0])
        XCTAssertEqual(underMinimum as? String, "active")
        f.services.locked = true; f.services.log = []
        let locked = try await f.answer("idle.queryState", [100.0])
        XCTAssertEqual(locked as? String, "locked"); XCTAssertEqual(f.services.log, ["session"])
        let delay = try await f.answer("idle.getAutoLockDelay")
        XCTAssertEqual(delay as? Int, 0)
        let denied = try await fixture(permissions: [], optional: ["idle", "power"])
        for api in ["idle.queryState", "idle.getAutoLockDelay", "power.requestKeepAwake", "power.releaseKeepAwake", "power.reportActivity"] {
            await refuses(denied, api, [], "eGlu doesn't answer \(api).")
        }
        XCTAssertTrue(denied.services.log.isEmpty)
        (denied.context as! AnswerContext).statuses["idle"] = .grantedExplicitly
        let allowed = try await denied.answer("idle.queryState", [15.0])
        XCTAssertEqual(allowed as? String, "idle")
    }

    @MainActor func testPowerReplacementReleaseFailureAndSpaceIsolation() async throws {
        let f = try await fixture()
        _ = try await f.answer("power.requestKeepAwake", ["display"])
        f.services.next = 2
        _ = try await f.answer("power.requestKeepAwake", ["system"])
        XCTAssertEqual(f.services.log, ["create", "release 1", "create"])
        XCTAssertEqual(f.services.created.map { $0.0 }, [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep])
        XCTAssertEqual(f.services.created.map { $0.1 }, Array(repeating: "An extension in eGlu: Runtime fixture", count: 2))
        f.runtime.releaseKeepAwake("\(UUID())/fixture")
        _ = try await f.answer("power.reportActivity")
        // Both unload and restart call this same lifetime operation inline.
        let lifetime: any WebExtensionRuntimeAnswers = f.runtime
        lifetime.releaseKeepAwake("\(f.space)/fixture")
        lifetime.releaseKeepAwake("\(f.space)/fixture")
        f.services.next = nil
        _ = try await f.answer("power.requestKeepAwake")
        _ = try await f.answer("power.releaseKeepAwake")
        XCTAssertEqual(f.services.log, ["create", "release 1", "create", "activity", "release 2", "create"])
        f.services.next = 3
        _ = try await f.answer("power.requestKeepAwake")
        _ = try await f.answer("power.releaseKeepAwake")
        XCTAssertEqual(f.services.log.suffix(2), ["create", "release 3"])
    }

    @MainActor func testOffscreenArgumentsAndServices() async throws {
        let f = try await fixture()
        await refuses(f, "offscreen.createDocument", [], "No page for the offscreen document")
        _ = try await f.answer("offscreen.createDocument", [["url": "page.html", "reasons": ["DOM_PARSER", "DOM_PARSER", 7]]])
        let made = try XCTUnwrap(f.services.offscreen)
        XCTAssertEqual(made.0, "page.html"); XCTAssertEqual(made.1, ["DOM_PARSER"])
        XCTAssertTrue(made.2 === f.context); XCTAssertEqual(made.3, f.space)
        XCTAssertEqual(made.4, "chrome-extension"); XCTAssertTrue(made.5 === f.host)
        let has = try await f.answer("offscreen.hasDocument")
        XCTAssertEqual(has as? Bool, true)
        _ = try await f.answer("offscreen.closeDocument")
        let gone = try await f.answer("offscreen.hasDocument")
        XCTAssertEqual(gone as? Bool, false)
    }

    @MainActor func testLanguageAndColourInputsResultsAndCancellation() async throws {
        let f = try await fixture()
        await refuses(f, "i18n.detectLanguage", [7], "Language detection requires text.")
        XCTAssertTrue(f.host.texts.isEmpty)
        let language = try await f.answer("i18n.detectLanguage", ["supplied text"])
        XCTAssertEqual(f.host.texts, ["supplied text"])
        let expected: NSDictionary = ["isReliable": true, "languages": [["language": "en", "percentage": 100]]]
        XCTAssertEqual(language as? NSDictionary, expected)
        let colour = try await f.answer("eyeDropper.open")
        XCTAssertEqual(colour as? String, "#8040ff")
        f.host.colour = nil
        await refuses(f, "eyeDropper.open", [], "AbortError")
        XCTAssertEqual(f.host.colourCalls, 2)
    }

    @MainActor func testNativeConsentPolicyAndPromptOrder() async throws {
        let f = try await fixture()
        f.host.optional = false
        let required = try await f.answer("permissions.native", ["remove"])
        XCTAssertEqual(required as? Bool, false); XCTAssertTrue(f.host.evidence.log.isEmpty)
        f.host.optional = true
        let has = try await f.answer("permissions.native", ["has"])
        XCTAssertEqual(has as? Bool, false); XCTAssertTrue(f.host.prompts.isEmpty)
        let no = try await f.answer("permissions.native", ["request"])
        XCTAssertEqual(no as? Bool, false); XCTAssertFalse(f.host.reaches)
        f.host.consent = true
        let yes = try await f.answer("permissions.native")
        XCTAssertEqual(yes as? Bool, true)
        XCTAssertEqual(f.host.evidence.log, ["prompt", "prompt", "consent true"])
        XCTAssertEqual(f.host.prompts.first?.0, "\u{201C}Runtime fixture\u{201D} wants to talk to apps on this Mac")
        XCTAssertEqual(f.host.prompts.first?.1, f.space)
        _ = try await f.answer("permissions.native", ["request"])
        XCTAssertEqual(f.host.prompts.count, 2)
        let removed = try await f.answer("permissions.native", ["remove"])
        XCTAssertEqual(removed as? Bool, true); XCTAssertFalse(f.host.reaches)
    }

    @MainActor func testBackgroundSuccessRetryTimeoutAndRevival() async throws {
        let none = try await fixture(background: false)
        _ = try await none.answer("background.wake")
        XCTAssertTrue(none.services.backgrounds.isEmpty)
        let f = try await fixture()
        var late: ((Error?) -> Void)?
        f.services.background = { completion in late = completion; completion(nil) }
        _ = try await f.answer("background.wake")
        XCTAssertTrue(f.services.backgrounds.first === f.context)
        XCTAssertEqual(f.services.backgrounds.count, 1)
        late?(RuntimeRefusal(why: "late failure")); f.services.deadlines.removeFirst()()
        XCTAssertTrue(f.revivals.isEmpty)
        f.services.background = { $0(RuntimeRefusal(why: "fixture failure")) }
        _ = try await f.answer("background.wake")
        XCTAssertEqual(f.services.backgrounds.count, 4); XCTAssertEqual(f.services.pauses, 2)
        XCTAssertEqual(f.revivals.first?.2, "its worker wouldn't start")
        // Fire each fake eight-second deadline without waiting or starting a worker.
        f.services.background = { _ in }
        let task = Task { _ = try await f.answer("background.wake") }
        for index in 3..<6 {
            for _ in 0..<1000 where f.services.deadlines.count <= index { await Task.yield() }
            XCTAssertGreaterThan(f.services.deadlines.count, index)
            guard f.services.deadlines.count > index else { task.cancel(); return }
            f.services.deadlines[index]()
        }
        _ = try await task.value
        XCTAssertEqual(f.revivals.count, 2); XCTAssertEqual(f.services.pauses, 4)
        let revived = try await f.answer("background.revive")
        XCTAssertEqual(revived as? Bool, true)
        XCTAssertEqual(f.revivals.last?.0, "fixture"); XCTAssertEqual(f.revivals.last?.1, f.space)
        XCTAssertEqual(f.revivals.last?.2, "its worker stopped answering")
    }

    @MainActor func testReportUpdateCatalogDeduplicationAndNoProblem() async throws {
        let f = try await fixture()
        let words = "browser.idle.queryState is not a function"
        _ = try await f.answer("report", ["error", words, "worker.js", 7])
        XCTAssertEqual(f.host.evidence.log, ["debug idle.queryState", "update", "installation", "deduplicate", "note"])
        let record = try XCTUnwrap(f.host.evidence.notes.first)
        XCTAssertEqual(record.0.api, "idle.queryState"); XCTAssertEqual(record.0.kind, .notAFunction)
        XCTAssertEqual(record.1, "worker.js"); XCTAssertEqual(record.2.id, "fixture"); XCTAssertEqual(record.2.version, "1")
        _ = try await f.answer("report", ["error", words])
        XCTAssertEqual(f.host.evidence.notes.count, 1); XCTAssertEqual(f.host.events.count, 2)
        f.host.item = nil
        _ = try await f.answer("report", ["error", "browser.power.other is not a function"])
        XCTAssertEqual(f.host.evidence.notes.count, 1)
        f.host.evidence.log = []
        _ = try await f.answer("report", ["error", "no API here"])
        XCTAssertEqual(f.host.evidence.log, ["debug none"])
    }

    @MainActor func testShimMessageIdentityEnvelopeAndDeferredDispatch() async throws {
        let f = try await fixture()
        for invalid in [false, true] {
            f.current = invalid ? nil : f.context; f.knownController = invalid
            var replied = false
            f.runtime.webExtensionController(f.controller, sendMessage: ["api": "report"], toApplicationWithIdentifier: "eglu", for: f.context) {
                XCTAssertNil($0); XCTAssertEqual($1?.localizedDescription, "Specified native messaging host not found."); replied = true
            }
            XCTAssertTrue(replied)
        }
        f.knownController = true
        f.current = try await fixture().context
        let stale = await f.message("eglu", ["api": "report"])
        XCTAssertEqual(stale.1?.localizedDescription, "Specified native messaging host not found.")
        XCTAssertTrue(f.calls.isEmpty)
        f.current = f.context
        let missing = await f.message(nil, [:])
        XCTAssertEqual(missing.1?.localizedDescription, "Specified native messaging host not found.")
        let malformed = await f.message("eglu", ["args": []])
        XCTAssertEqual(malformed.1?.localizedDescription, "Not a question eGlu knows.")
        var reply: Any?
        let done = expectation(description: "shim reply")
        f.runtime.webExtensionController(f.controller, sendMessage: ["api": "report", "args": ["input"]], toApplicationWithIdentifier: "eglu", for: f.context) {
            reply = $0; XCTAssertNil($1); done.fulfill()
        }
        XCTAssertTrue(f.calls.isEmpty)
        // As before, identity is checked before the Task, not checked again in it.
        f.current = nil
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue((reply as? [String: Any])?["value"] is NSNull)
        XCTAssertTrue(f.calls.first?.2 === f.context); XCTAssertEqual(f.calls.first?.0, "report")
        XCTAssertEqual(f.calls.first?.1 as? [String], ["input"]); XCTAssertEqual(f.calls.first?.3, f.space)
        f.current = f.context; f.shimError = RuntimeRefusal(why: "same words")
        let error = await f.message("eglu", ["api": "unknown", "args": 7])
        XCTAssertEqual((error.0 as? [String: String])?["error"], "same words"); XCTAssertNil(error.1)
        XCTAssertTrue(f.calls.last?.1.isEmpty == true)
        f.shimError = nil; f.shimResult = ["result": 8]
        let value = await f.message("eglu", ["api": "other"])
        XCTAssertEqual(((value.0 as? [String: Any])?["value"] as? [String: Int])?["result"], 8)
        XCTAssertTrue(f.transports.messages.isEmpty)
    }

    @MainActor func testNativeMessagesAndPortsOverFakeTransports() async throws {
        let f = try await fixture()
        let denied = await f.message("com.1password.fixture", ["input": 1])
        XCTAssertEqual(denied.1?.localizedDescription, "Specified native messaging host not found.")
        XCTAssertTrue(f.transports.messages.isEmpty)
        f.host.reaches = true
        let sent = await f.message("com.1password.fixture", ["input": 1])
        XCTAssertEqual(sent.0 as? [String: Int], ["answer": 7]); XCTAssertNil(sent.1)
        XCTAssertEqual(f.transports.messages.first?.0 as? [String: Int], ["input": 1])
        XCTAssertEqual(f.transports.messages.first?.1, "com.1password.fixture"); XCTAssertEqual(f.transports.messages.first?.2, "fixture")
        f.transports.failure = RuntimeRefusal(why: "host failed")
        let failed = await f.message("com.1password.fixture", [:])
        XCTAssertEqual(failed.1?.localizedDescription, "host failed")
        if case .unreachableApp(let name) = f.host.events.last?.2 { XCTAssertEqual(name, "1Password") } else { XCTFail("Missing evidence") }
        f.host.reaches = false
        let socket = f.port("eglu.socket") { XCTAssertNil($0); XCTAssertEqual(f.transports.sockets.count, 1) }
        let opened = try XCTUnwrap(f.transports.sockets.first)
        XCTAssertTrue(opened.0 === socket); XCTAssertEqual(opened.1, "fixture"); XCTAssertEqual(opened.2, f.space)
        XCTAssertEqual(opened.3, "connect-src 'self'"); XCTAssertEqual(opened.4, "chrome-extension")
        _ = f.port("eglu") { XCTAssertNil($0) }
        XCTAssertTrue(f.transports.native.isEmpty)
        _ = f.port("native.fixture") { XCTAssertEqual($0?.localizedDescription, "Specified native messaging host not found.") }
        f.host.reaches = true
        _ = f.port(nil) { XCTAssertEqual($0?.localizedDescription, "host failed") }
        f.transports.failure = nil
        var completed = false
        let native = f.port("native.fixture") { XCTAssertNil($0); completed = true }
        XCTAssertTrue(completed); XCTAssertTrue(f.transports.native.last?.0 === native)
        XCTAssertEqual(f.transports.native.last?.1, "fixture")
        f.current = try await fixture().context
        _ = f.port("eglu.socket") { XCTAssertEqual($0?.localizedDescription, "Specified native messaging host not found.") }
        XCTAssertEqual(f.transports.sockets.count, 1)
    }
}
#endif
