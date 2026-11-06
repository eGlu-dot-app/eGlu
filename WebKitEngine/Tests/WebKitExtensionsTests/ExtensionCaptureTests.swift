#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

@MainActor
private final class CaptureHost: ExtensionCaptureHost {
    var stop: ((String) -> Void)?
    var allowed = true
    var consent = true
    var events: [String] = []
    var lent: [NSView] = []
    var returned: [NSView] = []
    var lines: [ExtensionCaptureState] = []

    func setExtensionCaptureStop(_ stop: @escaping (String) -> Void) { self.stop = stop }
    func extensionCaptureAllowed(_ id: String) -> Bool { allowed }
    func requestExtensionCapture(_ id: String, in space: UUID, used: () -> Bool, name: () -> String) async -> Bool {
        events.append("consent")
        return consent
    }
    func bringExtensionCaptureForward(_ view: NSView) { events.append("forward") }
    func lendExtensionCaptureView(_ view: NSView) { events.append("lend"); lent.append(view) }
    func giveBackExtensionCaptureView(_ view: NSView) { events.append("give back"); returned.append(view) }
    func extensionCaptureName(_ id: String) -> String { "Fixture" }
    func updateExtensionCapture(_ lines: [ExtensionCaptureState]) {
        events.append(lines.isEmpty ? "empty" : "lines")
        self.lines = lines
    }
}

/// No loads or JavaScript execute. The private display state is a fake
/// KVO property; the camera and microphone remain WebKit's idle devices.
@MainActor
private final class CaptureView: AuxiliaryPageView {
    var address: URL? = URL(string: "chrome-extension://fixture/page.html")
    override var url: URL? { address }
    @objc dynamic var _displayCaptureState = 0
    var observed: [String] = []
    var removed: [String] = []
    var ended: [Int] = []
    var scripts: [String] = []
    var arguments: [[String: Any]] = []
    var result: Any = ["ok": true]
    var failure: Error?
    var onScript: (() -> Void)?

    override func addObserver(_ observer: NSObject, forKeyPath keyPath: String,
                              options: NSKeyValueObservingOptions = [], context: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated { observed.append(keyPath) }
        super.addObserver(observer, forKeyPath: keyPath, options: options, context: context)
    }

    override func removeObserver(_ observer: NSObject, forKeyPath keyPath: String) {
        MainActor.assumeIsolated { removed.append(keyPath) }
        super.removeObserver(observer, forKeyPath: keyPath)
    }

    @objc(_setDisplayCaptureState:completionHandler:)
    func endDisplay(_ state: Int, completionHandler: (() -> Void)?) {
        ended.append(state)
        _displayCaptureState = state
        completionHandler?()
    }

    override func __callAsyncJavaScript(_ functionBody: String, arguments: [String: Any]?,
                                       inFrame frame: WKFrameInfo?, in contentWorld: WKContentWorld,
                                       completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)?) {
        scripts.append(functionBody)
        self.arguments.append(arguments ?? [:])
        XCTAssertNil(frame)
        XCTAssertTrue(contentWorld === WKContentWorld.page)
        onScript?()
        if let failure { completionHandler?(nil, failure) }
        else { completionHandler?(result, nil) }
    }
}

private final class CaptureForwarder: NSObject, WKUIDelegate {
    var calls = 0
    @objc func captureForwardingProbe() { calls += 1 }
}

final class ExtensionCaptureTests: XCTestCase {
    @MainActor private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    @MainActor private func context(_ id: String = "fixture") async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Capture fixture","version":"1","permissions":["desktopCapture"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let package = try await WKWebExtension(resourceBaseURL: folder)
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = id
        context.baseURL = URL(string: "chrome-extension://\(id)/")!
        XCTAssertFalse(context.isLoaded)
        return context
    }

    @MainActor private func runtime(_ host: CaptureHost, space: UUID = UUID(),
                                     context: WKWebExtensionContext? = nil, declares: Bool = true) -> ExtensionCaptureRuntime {
        ExtensionCaptureRuntime(scheme: "chrome-extension", host: host, space: { _ in space },
            context: { id, _ in id == context?.uniqueIdentifier ? context : nil },
            declares: { _ in declares }, watchEvents: false)
    }

    @MainActor
    func testSenderChecksFrameOriginsControllerSpaceAndContext() async throws {
        let context = try await context()
        let space = UUID()
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let config = configuration()
        config.webExtensionController = controller
        let web = CaptureView(frame: .zero, configuration: config)
        let host = CaptureHost()
        var knownController = true
        var lookups: [String] = []
        var exactCase = false
        let capture = ExtensionCaptureRuntime(scheme: "chrome-extension", host: host,
            space: { candidate in knownController && candidate === controller ? space : nil },
            context: { id, askedSpace in
                lookups.append(id)
                return askedSpace == space && id == (exactCase ? "FIXTURE" : "fixture") ? context : nil
            }, declares: { _ in true }, watchEvents: false)
        func sender(_ main: Bool = true, _ scheme: String = "chrome-extension", _ id: String = "fixture")
            -> (WKWebExtensionContext, UUID, WKWebView)? {
            capture.sender(isMainFrame: main, originProtocol: scheme, originHost: id, web: web)
        }
        let accepted = try XCTUnwrap(sender())
        XCTAssertTrue(accepted.0 === context)
        XCTAssertEqual(accepted.1, space)
        XCTAssertTrue(accepted.2 === web)
        XCTAssertNil(capture.sender(isMainFrame: true, originProtocol: "chrome-extension", originHost: "fixture", web: nil))
        XCTAssertNil(sender(false))
        XCTAssertNil(sender(true, "https"))
        XCTAssertNil(sender(true, "chrome-extension", "other"))
        for address in [nil, "https://fixture/", "chrome-extension://other/"] as [String?] {
            web.address = address.flatMap(URL.init(string:))
            XCTAssertNil(sender())
        }
        web.address = URL(string: "CHROME-EXTENSION://FIXTURE/page")
        XCTAssertNotNil(sender(true, "CHROME-EXTENSION", "FIXTURE"))
        exactCase = true
        lookups = []
        XCTAssertNotNil(sender(true, "chrome-extension", "FIXTURE"))
        XCTAssertEqual(lookups, ["fixture", "FIXTURE"])
        XCTAssertNil(sender())
        knownController = false
        lookups = []
        XCTAssertNil(sender(true, "chrome-extension", "FIXTURE"))
        XCTAssertTrue(lookups.isEmpty)
        XCTAssertNil(web.window)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
    }

    @MainActor
    func testMessageErrorsAndLendRepliesStaySynchronous() async throws {
        let host = CaptureHost()
        let context = try await context()
        let capture = runtime(host, context: context)
        let web = CaptureView(frame: .zero, configuration: configuration())
        var reply: Any?
        var error: String?
        var calls = 0
        func receive(_ body: Any, valid: Bool = true) {
            capture.receive(body, sender: { valid ? (context, UUID(), web) : nil }) {
                reply = $0; error = $1; calls += 1
            }
        }
        receive("bad")
        XCTAssertEqual(calls, 1)
        XCTAssertNil(reply)
        XCTAssertEqual(error, "Not a request")
        receive(["op": "lend"], valid: false)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual((reply as? [String: String])?["message"], "Not allowed here")
        XCTAssertNil(error)
        receive(["op": "lend"])
        XCTAssertEqual(calls, 3)
        XCTAssertEqual((reply as? [String: Bool])?["ok"], true)
        XCTAssertTrue(host.lent.isEmpty)
    }

    @MainActor
    func testOffscreenWithoutMediaReasonsRefusesBeforeConsent() async throws {
        let context = try await context()
        let host = CaptureHost()
        let space = UUID()
        let capture = runtime(host, space: space, context: context)
        let config = configuration()
        let web = CaptureView(frame: .zero, configuration: config)
        let document = try ExtensionOffscreen.make("offscreen.html", reasons: ["DOM_PARSER"], for: context, in: space,
            scheme: "chrome-extension", host: AuxiliaryPageHost(), configuration: { config }, makeView: { _, _ in web })
        defer { ExtensionOffscreen.close("fixture", in: space); _ = document }
        var reply: [String: String]?
        capture.receive(["op": "lend"], sender: { (context, space, web) }) { reply = $0 as? [String: String]; XCTAssertNil($1) }
        XCTAssertEqual(reply?["message"], "This offscreen document wasn't made to record")
        let display = await capture.answer("display", [:], context: context, space: space, in: web)
        XCTAssertEqual(display["message"] as? String, reply?["message"])
        XCTAssertTrue(host.events.isEmpty)
        XCTAssertTrue(web.scripts.isEmpty)
    }

    @MainActor
    func testPurgeStopsOnlyItsSpaceAndPillStopEndsEverySpace() {
        let host = CaptureHost()
        let firstSpace = UUID(), secondSpace = UUID()
        let firstController = WKWebExtensionController(configuration: .nonPersistent())
        let secondController = WKWebExtensionController(configuration: .nonPersistent())
        let firstConfig = configuration(), secondConfig = configuration()
        firstConfig.webExtensionController = firstController
        secondConfig.webExtensionController = secondController
        let first = CaptureView(frame: .zero, configuration: firstConfig)
        let second = CaptureView(frame: .zero, configuration: secondConfig)
        let other = CaptureView(frame: .zero, configuration: firstConfig)
        let capture = ExtensionCaptureRuntime(scheme: "chrome-extension", host: host,
            space: { $0 === firstController ? firstSpace : $0 === secondController ? secondSpace : nil },
            context: { _, _ in nil }, declares: { _ in true }, watchEvents: false)
        defer { capture.release(first); capture.release(second); capture.release(other) }
        first._displayCaptureState = 1
        second._displayCaptureState = 2
        other._displayCaptureState = 1
        capture.watch(first, id: "fixture")
        capture.watch(second, id: "fixture")
        capture.watch(other, id: "other")
        capture.purge("fixture", in: firstSpace)
        XCTAssertEqual(first.ended, [0])
        XCTAssertTrue(second.ended.isEmpty)
        XCTAssertTrue(other.ended.isEmpty)
        host.stop?("fixture")
        XCTAssertEqual(first.ended, [0, 0])
        XCTAssertEqual(second.ended, [0])
        XCTAssertTrue(other.ended.isEmpty)
        XCTAssertFalse(ExtensionCaptureRuntime.capturing(first))
        XCTAssertTrue(ExtensionCaptureRuntime.screen(other))
    }

    @MainActor
    func testGrantsSourcesExpiryOwnershipSingleUseAndPurge() async throws {
        let context = try await context()
        let host = CaptureHost()
        let space = UUID(), otherSpace = UUID()
        let capture = runtime(host, space: space, context: context)
        let web = CaptureView(frame: .zero, configuration: configuration())
        let token = await capture.grant(for: context, in: space, sources: ["audio", "window"])
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(capture.grants[token]?.sources, ["audio", "window"])
        XCTAssertEqual(capture.grants[token]?.extensionID, "fixture")
        XCTAssertEqual(capture.grants[token]?.space, space)
        XCTAssertEqual(capture.displayDecision(for: web), 0)
        for (id, location, age, allowed) in [("other", space, 0.0, true), ("fixture", otherSpace, 0, true),
                                             ("fixture", space, 60, true), ("fixture", space, 0, false)] {
            capture.grants["invalid"] = .init(extensionID: id, space: location, made: Date().addingTimeInterval(-age), sources: ["screen"])
            host.allowed = allowed
            let reply = await capture.answer("consume", ["token": "invalid"], context: context, space: space, in: web)
            XCTAssertEqual(reply["message"] as? String, "Invalid state")
            XCTAssertNil(capture.grants["invalid"])
        }
        host.allowed = true
        capture.grants["expired"] = .init(extensionID: "fixture", space: space, made: Date().addingTimeInterval(-61), sources: [])
        _ = await capture.grant(for: context, in: space, sources: [])
        XCTAssertNil(capture.grants["expired"])
        capture.grants["elsewhere"] = .init(extensionID: "fixture", space: otherSpace, made: Date(), sources: [])
        capture.grants["another"] = .init(extensionID: "other", space: space, made: Date(), sources: [])
        capture.purge("fixture", in: space)
        XCTAssertNil(capture.grants[token])
        XCTAssertNotNil(capture.grants["elsewhere"])
        capture.forget("fixture")
        XCTAssertNil(capture.grants["elsewhere"])
        XCTAssertNotNil(capture.grants["another"])
        XCTAssertTrue(web.scripts.isEmpty)
        host.consent = false
        let refused = await capture.grant(for: context, in: space, sources: [])
        XCTAssertEqual(refused, "")
        let undeclared = runtime(host, declares: false)
        host.events = []
        let missing = await undeclared.grant(for: context, in: space, sources: [])
        XCTAssertEqual(missing, "")
        XCTAssertTrue(host.events.isEmpty)
    }

    @MainActor
    func testDisplayDecisionsSourcesAndRecordingAnswersWithoutCapture() async throws {
        let context = try await context()
        let host = CaptureHost()
        let space = UUID()
        let capture = runtime(host, space: space, context: context)
        let web = CaptureView(frame: .zero, configuration: configuration())
        let other = CaptureView(frame: .zero, configuration: configuration())
        defer { capture.release(web) }
        for (sources, surface, expected) in [(["window", "screen"], "", 2), (["screen", "window"], "", 1),
                                             (["tab"], "", 2), ([], "browser", 2), ([], "window", 2)] {
            let token = await capture.grant(for: context, in: space, sources: sources)
            web.onScript = {
                XCTAssertEqual(capture.displayDecision(for: web), expected)
                XCTAssertEqual(capture.displayDecision(for: other), 0)
            }
            let reply = await capture.answer("consume", ["token": token, "surface": surface, "video": false],
                                             context: context, space: space, in: web)
            XCTAssertEqual(reply["ok"] as? Bool, true)
            XCTAssertEqual(reply["token"] as? String, token)
            XCTAssertEqual(web.arguments.last?["video"] as? Bool, false)
            XCTAssertEqual(capture.displayDecision(for: web), 0)
            XCTAssertNil(capture.grants[token])
            let again = await capture.answer("consume", ["token": token], context: context, space: space, in: web)
            XCTAssertEqual(again["message"] as? String, "Invalid state")
        }
        let overridden = await capture.grant(for: context, in: space, sources: ["screen"])
        web.onScript = { XCTAssertEqual(capture.displayDecision(for: web), 2) }
        let overrideReply = await capture.answer("consume", ["token": overridden, "sources": ["window"]],
                                                 context: context, space: space, in: web)
        XCTAssertEqual(overrideReply["ok"] as? Bool, true)
        web.onScript = nil
        let chosen = await capture.answer("choose", ["sources": ["window"]], context: context, space: space, in: web)
        let chosenToken = try XCTUnwrap(chosen["token"] as? String)
        XCTAssertEqual(capture.grants[chosenToken]?.sources, ["window"])
        capture.forget("fixture")
        let direct = runtime(host, space: space, context: context, declares: false)
        defer { direct.release(web) }
        let missing = await direct.answer("choose", [:], context: context, space: space, in: web)
        XCTAssertEqual(missing["message"] as? String, "It didn't ask to record your screen")
        let display = await direct.answer("display", [:], context: context, space: space, in: web)
        XCTAssertEqual(display["ok"] as? Bool, true)
        web.onScript = nil
        web.result = ["error": "NotAllowedError", "message": "Picker cancelled"]
        let cancelled = await capture.answer("choose", [:], context: context, space: space, in: web)
        XCTAssertEqual(cancelled["message"] as? String, "Picker cancelled")
        XCTAssertTrue(capture.grants.isEmpty)
        web.result = "bad"
        let bad = await capture.answer("display", [:], context: context, space: space, in: web)
        XCTAssertEqual(bad["message"] as? String, "No answer")
        web.failure = NSError(domain: "fixture", code: 1)
        let failed = await capture.answer("display", [:], context: context, space: space, in: web)
        XCTAssertEqual(failed["error"] as? String, "AbortError")
        XCTAssertEqual(capture.displayDecision(for: web), 0)
        host.consent = false
        let denied = await capture.answer("display", [:], context: context, space: space, in: web)
        XCTAssertEqual(denied["message"] as? String, "Permission denied")
        let unknown = await capture.answer("unknown", [:], context: context, space: space, in: web)
        XCTAssertEqual(unknown["error"] as? String, "NotSupportedError")
        XCTAssertTrue(web.scripts.allSatisfy { $0 == "return await globalThis[Symbol.for('eglu.capture')](token, video);" })
        XCTAssertNil(web.window)
    }

    @MainActor
    func testOffscreenLendLinesGiveBackAndObserverLifetime() async throws {
        let context = try await context()
        let host = CaptureHost()
        let space = UUID()
        let capture = runtime(host, space: space, context: context)
        let config = configuration()
        let web = CaptureView(frame: .zero, configuration: config)
        let document = try ExtensionOffscreen.make("offscreen.html", reasons: ["USER_MEDIA"], for: context, in: space,
            scheme: "chrome-extension", host: AuxiliaryPageHost(), configuration: { config }, makeView: { _, _ in web })
        defer { capture.release(web); ExtensionOffscreen.close("fixture", in: space); _ = document }
        var reply: Any?
        capture.receive(["op": "lend"], sender: { (context, space, web) }) { reply = $0; XCTAssertNil($1) }
        XCTAssertEqual((reply as? [String: Bool])?["ok"], true)
        XCTAssertEqual(host.events, ["lend", "empty"])
        XCTAssertTrue(host.lent.first === web)
        XCTAssertEqual(web.observed, ["cameraCaptureState", "microphoneCaptureState", "_displayCaptureState"])
        capture.watch(web, id: "fixture")
        XCTAssertEqual(web.observed.count, 3)
        host.events = []
        web._displayCaptureState = 1
        // KVO queues the update, never delivering inline.
        XCTAssertTrue(host.events.isEmpty)
        await drain()
        XCTAssertEqual(host.events, ["lines"])
        XCTAssertEqual(host.lines.first?.name, "Fixture")
        XCTAssertEqual(host.lines.first?.screen, true)
        XCTAssertEqual(host.lines.first?.camera, false)
        XCTAssertEqual(host.lines.first?.microphone, false)
        host.events = []
        web._displayCaptureState = 0
        await drain()
        XCTAssertEqual(host.events, ["give back", "empty"])
        XCTAssertTrue(host.returned.first === web)
        capture.release(web)
        XCTAssertEqual(web.removed, web.observed)
        XCTAssertEqual(web.ended, [0])
        capture.release(web)
        XCTAssertEqual(web.removed.count, 3)
        XCTAssertEqual(web.ended, [0])
        XCTAssertNil(web.window)
    }

    @MainActor private func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @MainActor
    func testPrivatePreferenceOnNonPersistentConfiguration() throws {
        let config = configuration()
        let preferences = config.preferences
        let getter = NSSelectorFromString("_getUserMediaRequiresFocus")
        guard preferences.responds(to: getter), let method = class_getMethodImplementation(type(of: preferences), getter) else {
            throw XCTSkip("This WebKit has no private focus getter")
        }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        let get = unsafeBitCast(method, to: Get.self)
        ExtensionCaptureRuntime.set("_setGetUserMediaRequiresFocus:", true, in: preferences)
        XCTAssertTrue(get(preferences, getter))
        ExtensionCaptureRuntime.set("_setGetUserMediaRequiresFocus:", false, in: preferences)
        XCTAssertFalse(get(preferences, getter))
        ExtensionCaptureRuntime.set("_egluNonexistentPreference:", true, in: preferences)
        ExtensionCaptureRuntime.set("_setGetUserMediaRequiresFocus:", true, in: preferences)
        ExtensionCaptureRuntime.mockDevices(preferences, enabled: false)
        XCTAssertTrue(get(preferences, getter))
        ExtensionCaptureRuntime.mockDevices(preferences, enabled: true)
        XCTAssertFalse(get(preferences, getter))
        XCTAssertFalse(config.websiteDataStore.isPersistent)
    }

    @MainActor
    func testPageDelegateForwardsWeaklyAndKeepsDisplayRefusalAndMediaPrompt() throws {
        let capture = runtime(CaptureHost())
        var captureLookups = 0
        weak var lifetime: CaptureForwarder?
        let selector = #selector(CaptureForwarder.captureForwardingProbe)
        let delegate = autoreleasepool {
            let next = CaptureForwarder()
            lifetime = next
            let delegate = ExtensionPageDelegate(next: next, capture: { captureLookups += 1; return capture })
            XCTAssertTrue(delegate.responds(to: selector))
            XCTAssertTrue(delegate.forwardingTarget(for: selector) as? CaptureForwarder === next)
            _ = delegate.perform(selector)
            XCTAssertEqual(next.calls, 1)
            return delegate
        }
        XCTAssertEqual(captureLookups, 0)
        XCTAssertNil(lifetime)
        XCTAssertFalse(delegate.responds(to: selector))
        XCTAssertNil(delegate.forwardingTarget(for: selector))
        let web = CaptureView(frame: .zero, configuration: configuration())
        defer { capture.release(web) }
        // WKSecurityOrigin has no initializer. These arguments are never
        // inspected by either callback, so use Objective-C stand-ins.
        let origin = NSObject(), frame = NSObject()
        let display = NSSelectorFromString("_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:")
        let displayMethod = try XCTUnwrap(class_getMethodImplementation(type(of: delegate), display))
        typealias Display = @convention(c) (AnyObject, Selector, WKWebView, AnyObject, AnyObject, Bool, @convention(block) (Int) -> Void) -> Void
        var decision = -1
        unsafeBitCast(displayMethod, to: Display.self)(delegate, display, web, origin, frame, true) { decision = $0 }
        XCTAssertEqual(decision, 0)
        XCTAssertEqual(captureLookups, 1)
        let media = NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")
        let mediaMethod = try XCTUnwrap(class_getMethodImplementation(type(of: delegate), media))
        typealias Media = @convention(c) (AnyObject, Selector, WKWebView, AnyObject, AnyObject, Int, @convention(block) (Int) -> Void) -> Void
        for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
            unsafeBitCast(mediaMethod, to: Media.self)(delegate, media, web, origin, frame, type.rawValue) { decision = $0 }
            XCTAssertEqual(decision, WKPermissionDecision.prompt.rawValue)
        }
        XCTAssertEqual(web.observed.count, 3)
        XCTAssertEqual(captureLookups, 4)
        XCTAssertNil(web.window)
    }
}
#endif
