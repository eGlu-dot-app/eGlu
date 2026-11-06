#if os(macOS)
import AppKit
import Foundation
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

private struct PermissionRefusal: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

@MainActor
private final class PromptTarget: ExtensionPermissionTarget {}

@MainActor
private final class PermissionHost: ExtensionPermissionHost {
    let target = PromptTarget()
    var hasWindow = true
    var answer = false
    var requests: [ExtensionPermissionRequest] = []
    var titles: [ExtensionPermissionPromptKind] = []
    var selections: [(UUID, UUID?, ExtensionPermissionPromptKind)] = []
    var log: [String] = []
    var onPrompt: (() -> Void)?
    var waiting: CheckedContinuation<Bool, Never>?
    var holdAnswer = false

    func extensionPermissionTarget(in space: UUID, tab: UUID?, kind: ExtensionPermissionPromptKind) -> (any ExtensionPermissionTarget)? {
        selections.append((space, tab, kind))
        log.append("target")
        return hasWindow ? target : nil
    }
    func extensionPermissionTitle(name: String?, kind: ExtensionPermissionPromptKind) -> String {
        titles.append(kind)
        return "Fixture title"
    }
    func requestExtensionPermission(_ request: ExtensionPermissionRequest, target: any ExtensionPermissionTarget) async -> Bool {
        XCTAssertTrue(target === self.target)
        XCTAssertTrue(Thread.isMainThread)
        requests.append(request)
        log.append("prompt")
        onPrompt?()
        if holdAnswer { return await withCheckedContinuation { waiting = $0 } }
        return answer
    }
    func allowExtensionPermissionCookies(_ id: String) { log.append("cookies:\(id)") }
}

@MainActor
private final class PermissionContext: WKWebExtensionContext {
    var onWrite: ((String) -> Void)?
    override func setPermissionStatus(_ status: PermissionStatus, for permission: WKWebExtension.Permission) {
        onWrite?("permission:\(permission.rawValue)")
        super.setPermissionStatus(status, for: permission)
    }
    override func setPermissionStatus(_ status: PermissionStatus, for pattern: WKWebExtension.MatchPattern) {
        onWrite?("pattern:\(pattern.string)")
        super.setPermissionStatus(status, for: pattern)
    }
}

final class ExtensionPermissionsTests: XCTestCase {
    @MainActor private func fixture() async throws -> PermissionContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manifest = #"{"manifest_version":3,"name":"Permission fixture","version":"1","optional_permissions":["cookies","tabs","clipboardRead"],"optional_host_permissions":["https://*/*","file:///*","chrome-extension://*/*","webkit-extension://*/*"]}"#
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))
        WebKitExtensionControllers.registerScheme()
        let package = try await WKWebExtension(resourceBaseURL: root)
        let context = PermissionContext(for: package)
        context.uniqueIdentifier = "permission-fixture"
        context.baseURL = URL(string: "chrome-extension://permission-fixture/")!
        XCTAssertFalse(context.isLoaded)
        return context
    }

    @MainActor private func runtime(_ host: PermissionHost, space: UUID, now: Date = Date()) -> WebKitExtensionPermissions {
        WebKitExtensionPermissions(host: host, space: { _ in space }, unanswered: { PermissionRefusal(why: $0) },
            fence: { _ in host.log.append("fence") }, now: { now })
    }

    @MainActor private func press(_ runtime: any WebExtensionPermissions, _ context: WKWebExtensionContext, _ space: UUID, at date: Date = Date()) {
        runtime.permissionPresses["\(space.uuidString)/\(context.uniqueIdentifier)"] = date
    }

    @MainActor private func refusal(_ words: String, _ body: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("Expected refusal", file: file, line: line) }
        catch { XCTAssertEqual((error as? PermissionRefusal)?.why, words, file: file, line: line) }
    }

    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @MainActor func testNoWindowAndEmptyOrURLRequestsRefuseInline() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let runtime = runtime(host, space: space)
        let controller = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
        host.hasWindow = false
        var replies = 0
        runtime.promptForPermissions([.cookies], controller: controller, tab: nil, context: context) { given, expiry in
            XCTAssertTrue(given.isEmpty); XCTAssertNil(expiry); replies += 1
        }
        runtime.promptForPermissionMatchPatterns([try WKWebExtension.MatchPattern(string: "https://example.invalid/*")],
            controller: controller, tab: nil, context: context) { given, expiry in
            XCTAssertTrue(given.isEmpty); XCTAssertNil(expiry); replies += 1
        }
        runtime.promptForPermissions([], controller: controller, tab: nil, context: context) { given, expiry in
            XCTAssertTrue(given.isEmpty); XCTAssertNil(expiry); replies += 1
        }
        runtime.promptForPermissionToAccess([URL(string: "https://example.invalid/")!]) { given, expiry in
            XCTAssertTrue(given.isEmpty); XCTAssertNil(expiry); replies += 1
        }
        XCTAssertEqual(replies, 4)
        XCTAssertEqual(host.selections.count, 2)
        press(runtime, context, space)
        let yes = try await runtime.requestAfterClick(["cookies"], origins: [], context: context, in: space)
        XCTAssertFalse(yes)
        XCTAssertTrue(host.requests.isEmpty)
        XCTAssertEqual(host.selections.last?.2, .afterClick)
        XCTAssertNil(runtime.permissionPresses["\(space.uuidString)/\(context.uniqueIdentifier)"])
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testUnknownControllerRefusesBeforeHostAndKnownTabCrossesAsItsID() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let controller = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
        let unknown = WebKitExtensionPermissions(host: host, space: { _ in nil }, unanswered: { PermissionRefusal(why: $0) })
        var replied = false
        unknown.promptForPermissions([.cookies], controller: controller, tab: nil, context: context) { given, _ in
            XCTAssertTrue(given.isEmpty); replied = true
        }
        XCTAssertTrue(replied)
        XCTAssertTrue(host.selections.isEmpty)
        let browser = BrowserHost()
        let tabs = ExtensionTabs(host: browser, enabled: { _ in false }, controller: { _ in controller },
            othersPage: { _, _ in false }, refusal: { _, _ in nil }, heldOwner: { _ in nil })
        let tabID = UUID()
        let selected = tabs.tab(tabID, in: space)
        let runtime = runtime(host, space: space)
        host.answer = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            runtime.promptForPermissions([.cookies], controller: controller, tab: selected, context: context) { given, _ in
                XCTAssertTrue(given.isEmpty)
                done.resume()
            }
            XCTAssertEqual(host.selections.last?.1, tabID)
        }
        XCTAssertEqual(host.requests.last?.tab, tabID)
        host.log = []
        let pattern = try WKWebExtension.MatchPattern(string: "https://example.invalid/*")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            runtime.promptForPermissionMatchPatterns([pattern], controller: controller, tab: selected, context: context) { given, _ in
                XCTAssertTrue(given.isEmpty)
                host.log.append("reply")
                done.resume()
            }
        }
        await drainMainQueue()
        XCTAssertEqual(host.log, ["target", "prompt", "reply"])
    }

    @MainActor func testAllowanceIsOneUseAndStrictlyLessThanTenSeconds() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let now = Date(), runtime = runtime(host, space: space, now: now)
        let gesture = "Invalid call to permissions.request(). Must be called during a user gesture."
        let key = "\(space.uuidString)/\(context.uniqueIdentifier)"
        runtime.permissionPresses[key] = nil
        await refusal(gesture) { try await runtime.requestAfterClick([], origins: [], context: context, in: space) }
        press(runtime, context, space, at: now.addingTimeInterval(-10))
        await refusal(gesture) { try await runtime.requestAfterClick([], origins: [], context: context, in: space) }
        // Expired dates stay present, as before; only an eligible call consumes one.
        XCTAssertNotNil(runtime.permissionPresses[key])
        press(runtime, context, space, at: now.addingTimeInterval(-9.999))
        let yes = try await runtime.requestAfterClick([], origins: [], context: context, in: space)
        XCTAssertTrue(yes)
        XCTAssertNil(runtime.permissionPresses[key])
        await refusal(gesture) { try await runtime.requestAfterClick([], origins: [], context: context, in: space) }
        let otherSpace = UUID()
        press(runtime, context, space, at: now)
        await refusal(gesture) { try await runtime.requestAfterClick([], origins: [], context: context, in: otherSpace) }
        XCTAssertTrue(host.requests.isEmpty)
    }

    @MainActor func testInvalidAndUndeclaredRequestsConsumeAllowanceAndKeepErrorWords() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let now = Date(), runtime = runtime(host, space: space, now: now)
        for (names, origins, words) in [
            ([], ["not a pattern"], "Invalid value for origin pattern."),
            (["bookmarks"], [], "Only permissions specified in the manifest may be requested."),
            ([], ["http://example.invalid/*"], "Only permissions specified in the manifest may be requested.")
        ] {
            press(runtime, context, space, at: now)
            await refusal(words) { try await runtime.requestAfterClick(names, origins: origins, context: context, in: space) }
            XCTAssertNil(runtime.permissionPresses["\(space.uuidString)/\(context.uniqueIdentifier)"])
        }
        XCTAssertTrue(host.requests.isEmpty)
    }

    @MainActor func testBlockedAfterClickPatternsRefuseWholeRequestAndDelegateFiltersThem() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let now = Date(), runtime = runtime(host, space: space, now: now)
        let blocked = ["file:///*", "chrome-extension://*/*", "webkit-extension://*/*", "https://accounts.google.com/*", "https://*.accounts.google.com/*"]
        for origin in blocked {
            press(runtime, context, space, at: now)
            let yes = try await runtime.requestAfterClick(["cookies"], origins: [origin, "https://example.invalid/*"], context: context, in: space)
            XCTAssertFalse(yes, origin)
        }
        XCTAssertTrue(host.selections.isEmpty)
        host.answer = true
        let controller = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
        let patterns = try Set(blocked.map { try WKWebExtension.MatchPattern(string: $0) })
        var replied = false
        runtime.promptForPermissionMatchPatterns(patterns, controller: controller, tab: nil, context: context) { given, _ in
            XCTAssertTrue(given.isEmpty); replied = true
        }
        XCTAssertTrue(replied)
        XCTAssertTrue(host.selections.isEmpty)
        let allowed = try WKWebExtension.MatchPattern(string: "https://example.invalid/*")
        await withCheckedContinuation { done in
            runtime.promptForPermissionMatchPatterns(patterns.union([allowed]), controller: controller, tab: nil, context: context) { given, expiry in
                XCTAssertEqual(given, [allowed]); XCTAssertNil(expiry)
                XCTAssertFalse(host.log.contains("fence"))
                host.log.append("reply")
                done.resume()
            }
        }
        await drainMainQueue()
        XCTAssertEqual(host.requests.last?.sites, [allowed.string])
        XCTAssertEqual(host.log, ["target", "prompt", "reply", "fence"])
    }

    @MainActor func testDelegateConsentRepliesBeforeSavingCookiesAndDenialDoesNeither() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let runtime = runtime(host, space: space)
        let controller = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
        let permissions: Set<WKWebExtension.Permission> = [.cookies, .init(rawValue: "tabs")]
        for yes in [false, true] {
            host.answer = yes
            host.log = []
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                runtime.promptForPermissions(permissions, controller: controller, tab: nil, context: context) { given, expiry in
                    XCTAssertEqual(given, yes ? permissions : [])
                    XCTAssertNil(expiry)
                    host.log.append("reply")
                    done.resume()
                }
                // The target is selected now, while the question has not started.
                XCTAssertEqual(host.log, ["target"])
                XCTAssertEqual(host.titles.count, host.requests.count + 1)
                XCTAssertEqual(host.titles.last, .permissions)
            }
            XCTAssertEqual(host.log, yes ? ["target", "prompt", "reply", "cookies:permission-fixture"] : ["target", "prompt", "reply"])
            let request = try XCTUnwrap(host.requests.last)
            XCTAssertEqual(request.extensionID, context.uniqueIdentifier)
            XCTAssertEqual(request.space, space)
            XCTAssertEqual(request.name, "Permission fixture")
            XCTAssertEqual(Set(request.permissions), ["cookies", "tabs"])
            XCTAssertTrue(request.sites.isEmpty)
            XCTAssertEqual(request.kind, .permissions)
            XCTAssertEqual(request.title, "Fixture title")
        }
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testAfterClickConsentGrantsInInputOrderThenFencesSavesAndReturns() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let now = Date(), runtime = runtime(host, space: space, now: now)
        context.onWrite = { host.log.append($0) }
        let origins = ["https://one.invalid/*", "https://two.invalid/*"]
        host.onPrompt = {
            XCTAssertNotEqual(context.permissionStatus(for: .cookies), .grantedExplicitly)
            XCTAssertNotEqual(context.permissionStatus(for: try! WKWebExtension.MatchPattern(string: origins[0])), .grantedExplicitly)
        }
        for yes in [false, true] {
            host.answer = yes
            host.log = []
            press(runtime, context, space, at: now)
            let allowed = try await runtime.requestAfterClick(["tabs", "cookies"], origins: origins, context: context, in: space)
            host.log.append("return")
            XCTAssertEqual(allowed, yes)
            XCTAssertEqual(host.log, yes ? ["target", "prompt", "permission:tabs", "permission:cookies",
                "pattern:\(origins[0])", "pattern:\(origins[1])", "fence", "cookies:permission-fixture", "return"] : ["target", "prompt", "return"])
        }
        host.onPrompt = nil
        XCTAssertEqual(context.permissionStatus(for: .cookies), .grantedExplicitly)
        for origin in origins {
            XCTAssertEqual(context.permissionStatus(for: try WKWebExtension.MatchPattern(string: origin)), .grantedExplicitly)
        }
        XCTAssertEqual(host.requests.last?.permissions, ["tabs", "cookies"])
        XCTAssertEqual(host.requests.last?.sites, origins)
        XCTAssertEqual(host.requests.last?.kind, .afterClick)
        XCTAssertNil(host.requests.last?.image)
        host.log = []
        press(runtime, context, space, at: now)
        let alreadyAllowed = try await runtime.requestAfterClick(["tabs", "cookies"], origins: origins, context: context, in: space)
        XCTAssertTrue(alreadyAllowed)
        XCTAssertTrue(host.log.isEmpty)
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testPendingAnswerConsumesGestureAndDoesNotGrantEarly() async throws {
        let context = try await fixture(), host = PermissionHost(), space = UUID()
        let now = Date(), runtime = runtime(host, space: space, now: now)
        host.holdAnswer = true
        press(runtime, context, space, at: now)
        let task = Task { try await runtime.requestAfterClick(["cookies"], origins: [], context: context, in: space) }
        for _ in 0..<1000 where host.waiting == nil { await Task.yield() }
        let waiting = try XCTUnwrap(host.waiting)
        XCTAssertNil(runtime.permissionPresses["\(space.uuidString)/\(context.uniqueIdentifier)"])
        XCTAssertNotEqual(context.permissionStatus(for: .cookies), .grantedExplicitly)
        await refusal("Invalid call to permissions.request(). Must be called during a user gesture.") {
            try await runtime.requestAfterClick(["cookies"], origins: [], context: context, in: space)
        }
        waiting.resume(returning: true)
        let yes = try await task.value
        XCTAssertTrue(yes)
        XCTAssertEqual(host.log, ["target", "prompt", "fence", "cookies:permission-fixture"])
        host.waiting = nil
    }
}
#endif
