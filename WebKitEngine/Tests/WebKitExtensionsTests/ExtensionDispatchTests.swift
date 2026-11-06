#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

private struct DispatchError: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

@MainActor
private struct TabOpening: ExtensionTabOpening {
    var url: URL?
    var shouldBeActive = false
    var shouldBePinned = true
}

@MainActor
private struct WindowOpening: ExtensionWindowOpening {
    var shouldBePrivate = false
    var tabURLs: [URL] = []
    var windowType: WKWebExtension.WindowType = .normal
    var frame: CGRect = .null
    var shouldBeFocused = true
}

@MainActor
private final class PopupAddressView: WKWebView {
    var address: URL?
    override var url: URL? { address }
}

@MainActor
private final class PopupAction: ExtensionActionPresenting {
    var popupWebView: WKWebView?
    var associatedTab: (any WKWebExtensionTab)?
    var closed = false
    var onClose: (() -> Void)?
    func closePopup() { closed = true; popupWebView = nil; onClose?() }
}

@MainActor
private final class DispatchServices: ExtensionRuntimeServices {
    var calls: [String] = []
    func session() -> [String: Any]? { calls.append("session"); return nil }
    func quiet() -> Double { calls.append("quiet"); return 20 }
    func createAssertion(_ kind: CFString, why: CFString) -> IOPMAssertionID? { calls.append("create"); return 1 }
    func release(_ assertion: IOPMAssertionID) { calls.append("release \(assertion)") }
    func activity() { calls.append("activity") }
    func loadBackground(_ context: WKWebExtensionContext, completion: @escaping (Error?) -> Void) {
        fatalError("No background load in this fixture")
    }
    func after(_ seconds: TimeInterval, perform: @escaping () -> Void) { fatalError("No deadline in this fixture") }
    func pause() async throws { fatalError("No pause in this fixture") }
    func createOffscreen(_ path: String, reasons: Set<String>, for context: WKWebExtensionContext, in space: UUID,
                         scheme: String, host: any ExtensionAuxiliaryPageHost) async throws {
        fatalError("No offscreen page in this fixture")
    }
    func closeOffscreen(_ id: String, in space: UUID) { calls.append("close offscreen") }
    func hasOffscreen(_ id: String, in space: UUID) -> Bool { calls.append("has offscreen"); return false }
}

final class ExtensionDispatchTests: XCTestCase {
    @MainActor private func fixture() async throws -> (WebKitExtensionRuntime, DispatchFixtureHost, WKWebExtensionContext, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let json = #"{"manifest_version":3,"name":"Dispatch fixture","version":"1","permissions":["identity","userScripts","desktopCapture","idle","power","tabs"],"action":{"default_popup":"popup.html"},"options_page":"options.html"}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("manifest.json"))
        WebKitExtensionControllers.registerScheme()
        let package = try await WKWebExtension(resourceBaseURL: root)
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "fixture"
        context.baseURL = URL(string: "chrome-extension://fixture/")!
        let host = DispatchFixtureHost(root: root)
        let storage = ExtensionStorage(environment: { host.extensionStorageEnvironment }, withoutShim: { false })
        let runtime = WebKitExtensionRuntime(host: host, storage: storage,
            configuration: { _ in XCTFail("No quiet auth page in this fixture"); return WKWebViewConfiguration() },
            unanswered: { DispatchError(why: $0) })
        runtime.capture = ExtensionCaptureRuntime(scheme: "chrome-extension", host: host,
            space: { [weak runtime] in runtime?.controllers.space(of: $0) },
            context: { [weak runtime] in runtime?.controllers.context($0, in: $1) },
            declares: { _ in true }, watchEvents: false)
        runtime.controllers.configurationForTesting = { _ in ExtensionTrial.throwaway() }
        let space = UUID()
        runtime.controllers.contexts[space] = ["fixture": context]
        host.browser.published = .init(spaces: [.init(id: space, tabs: [], selected: nil)])
        XCTAssertFalse(context.isLoaded)
        return (runtime, host, context, space)
    }

    @MainActor func testControllerOwnsTheMovedDelegateAndWindowAnswersKeepIdentity() async throws {
        let (runtime, host, context, space) = try await fixture()
        let controller = runtime.controllers.controller(for: space)
        let delegate = runtime.controllerDelegate
        XCTAssertTrue(controller.delegate === delegate)
        XCTAssertFalse(controller.configuration.isPersistent)
        let windows = delegate.webExtensionController(controller, openWindowsFor: context)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows.first === runtime.tabs.window(for: space))
        XCTAssertNil(delegate.webExtensionController(controller, focusedWindowFor: context))
        host.browser.focusedSpace = space
        XCTAssertTrue(delegate.webExtensionController(controller, focusedWindowFor: context) === windows.first)
        let other = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
        XCTAssertTrue(delegate.webExtensionController(other, openWindowsFor: context).isEmpty)
        XCTAssertNil(delegate.webExtensionController(other, focusedWindowFor: context))
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testNewTabAndWindowKeepArgumentsRefusalsAndOneSpaceAsOneWindow() async throws {
        let (runtime, host, context, space) = try await fixture()
        let controller = runtime.controllers.controller(for: space)
        host.browser.opened = UUID()
        let url = URL(string: "https://example.invalid/one")!
        var completed = false
        runtime.controllerDelegate.openNewTab(controller, using: TabOpening(url: url), for: context) { tab, error in
            XCTAssertEqual((tab as? ExtensionTab)?.id, host.browser.opened)
            XCTAssertNil(error)
            completed = true
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(host.browser.calls.last, "open:\(space):\(url):false:true:fixture")
        host.browser.calls = []
        runtime.controllerDelegate.openNewWindow(controller, using: WindowOpening(tabURLs: [url, URL(string: "https://example.invalid/two")!]), for: context) { window, error in
            XCTAssertTrue(window === runtime.tabs.window(for: space))
            XCTAssertNil(error)
        }
        XCTAssertEqual(host.browser.calls, ["open:\(space):\(url):true:false:fixture", "ensureWindow:\(space)"])
        host.browser.calls = []
        runtime.controllerDelegate.openNewWindow(controller, using: WindowOpening(shouldBePrivate: true, tabURLs: [url]), for: context) { window, error in
            XCTAssertNil(window)
            XCTAssertEqual((error as NSError?)?.code, 3)
        }
        XCTAssertTrue(host.browser.calls.isEmpty)
        for address in ["file:///fixture", "javascript:alert(1)", "chrome-extension://another/page.html"] {
            runtime.controllerDelegate.openNewTab(controller, using: TabOpening(url: URL(string: address)), for: context) { tab, error in
                XCTAssertNil(tab)
                XCTAssertTrue(error is DispatchError)
            }
        }
        XCTAssertTrue(host.browser.calls.isEmpty)
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testOptionsPopupAddressAndActionEventStaySynchronous() async throws {
        let (runtime, host, context, space) = try await fixture()
        let controller = runtime.controllers.controller(for: space)
        runtime.controllerDelegate.webExtensionController(controller, openOptionsPageFor: context) { error in XCTAssertNil(error) }
        XCTAssertEqual(host.browser.calls.last, "open:\(space):chrome-extension://fixture/options.html:true:false:fixture")
        let action = PopupAction()
        action.onClose = { XCTAssertTrue(host.log.isEmpty) }
        runtime.controllerDelegate.presentPopup(controller, action: action, for: context) { error in
            XCTAssertNil(error)
            XCTAssertEqual(host.log, ["popup"])
            XCTAssertEqual(host.popupAddress?.absoluteString, "chrome-extension://fixture/popup.html")
            XCTAssertTrue(host.hasPageMaker)
        }
        XCTAssertTrue(action.closed)
        runtime.controllerDelegate.webExtensionController(controller, didUpdate: try XCTUnwrap(context.action(for: nil)), forExtensionContext: context)
        XCTAssertEqual(host.log, ["popup", "action"])
        runtime.popupPaths["\(space)/fixture"] = "changed.html?query=1"
        action.onClose = nil
        runtime.controllerDelegate.presentPopup(controller, action: action, for: context) { _ in }
        XCTAssertEqual(host.popupAddress?.absoluteString, "chrome-extension://fixture/changed.html?query=1")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = PopupAddressView(frame: .zero, configuration: configuration)
        view.address = URL(string: "chrome-extension://fixture/tab-specific.html")
        action.popupWebView = view
        action.associatedTab = runtime.tabs.tab(UUID(), in: space)
        action.closed = false
        runtime.controllerDelegate.presentPopup(controller, action: action, for: context) { _ in
            XCTAssertTrue(action.closed)
            XCTAssertNil(action.popupWebView)
        }
        XCTAssertEqual(host.popupAddress, view.address)
        view.address = URL(string: "https://example.invalid")
        action.popupWebView = view
        runtime.controllerDelegate.presentPopup(controller, action: action, for: context) { _ in }
        XCTAssertEqual(host.popupAddress?.absoluteString, "chrome-extension://fixture/changed.html?query=1")
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testDispatcherRoutesRuntimeBrowserScriptsPermissionsCaptureAndAuth() async throws {
        let (runtime, host, context, space) = try await fixture()
        let services = DispatchServices()
        runtime.answers = WebKitExtensionRuntimeAnswers(host: host,
            evidence: { [unowned runtime] in runtime.errors },
            contexts: { [unowned runtime] in runtime.controllers.contexts },
            space: { [unowned runtime] in runtime.controllers.space(of: $0) },
            revive: { [unowned runtime] in runtime.workers.revive($0, in: $1, because: $2) },
            answer: { [unowned runtime] in try await runtime.dispatcher.answer($0, $1, context: $2, in: $3) },
            unanswered: { DispatchError(why: $0) }, scheme: "chrome-extension", shimApplication: "eglu",
            services: services, transports: RuntimeTransports())
        let dispatch = runtime.dispatcher
        for api in ["report", "background.wake", "background.revive", "offscreen.closeDocument", "offscreen.hasDocument"] {
            _ = try await dispatch.answer(api, [], context: context, in: space)
        }
        _ = try await dispatch.answer("i18n.detectLanguage", ["hello"], context: context, in: space)
        do { _ = try await dispatch.answer("eyeDropper.open", [], context: context, in: space); XCTFail("Cancel") }
        catch { XCTAssertEqual(error.localizedDescription, "AbortError") }
        let native = try await dispatch.answer("permissions.native", ["has"], context: context, in: space)
        XCTAssertEqual(native as? Bool, false)
        do { _ = try await dispatch.answer("offscreen.createDocument", [], context: context, in: space); XCTFail("Missing URL") }
        catch { XCTAssertEqual(error.localizedDescription, "No page for the offscreen document") }
        do { _ = try await dispatch.answer("identity.launchWebAuthFlow", [], context: context, in: space); XCTFail("Missing authorization URL") }
        catch { XCTAssertEqual(error.localizedDescription, "No authorization url.") }
        do {
            _ = try await dispatch.answer("identity.launchWebAuthFlow", [["url": "file:///fixture"]], context: context, in: space)
            XCTFail("Insecure quiet flow")
        } catch { XCTAssertEqual(error.localizedDescription, WebKitExtensionAuth.notLoaded) }
        for api in ["clients.pages", "runtime.getContexts", "sidePanel.setOptions", "sidePanel.getOptions", "sidePanel.setPanelBehavior", "sidePanel.getPanelBehavior", "sidePanel.open", "sidePanel.close", "surface.kind", "action.popup"] {
            _ = try await dispatch.answer(api, [], context: context, in: space)
        }
        for api in ["management.getSelf", "management.get"] {
            let result = try await dispatch.answer(api, ["fixture"], context: context, in: space) as? [String: Any]
            XCTAssertEqual(result?["id"] as? String, "fixture")
        }
        for (api, refusal) in [
            ("scripting.file", "The extension never asked for \u{201C}scripting\u{201D}"),
            ("permissions.afterClick", "Invalid call to permissions.request(). Must be called during a user gesture.")
        ] {
            do { _ = try await dispatch.answer(api, [], context: context, in: space); XCTFail("Expected refusal for \(api)") }
            catch { XCTAssertEqual(error.localizedDescription, refusal, api) }
        }
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        let tabs = try await dispatch.answer("tabs.describe", [[0]], context: context, in: space) as? [Any]
        XCTAssertEqual(tabs?.count, 1)
        XCTAssertTrue(tabs?.first is NSNull)
        let idle = try await dispatch.answer("idle.queryState", [15.0], context: context, in: space)
        XCTAssertEqual(idle as? String, "idle")
        let delay = try await dispatch.answer("idle.getAutoLockDelay", [], context: context, in: space)
        XCTAssertEqual(delay as? Int, 0)
        for api in ["power.requestKeepAwake", "power.releaseKeepAwake", "power.reportActivity"] {
            let result = try await dispatch.answer(api, [], context: context, in: space)
            XCTAssertNil(result, api)
        }
        XCTAssertEqual(services.calls, ["close offscreen", "has offscreen", "session", "quiet", "create", "release 1", "activity"])
        do { _ = try await dispatch.answer("unknown", [], context: context, in: space); XCTFail("Expected default refusal") }
        catch { XCTAssertEqual(error.localizedDescription, "eGlu doesn't answer unknown.") }
        for api in ["userScripts.list", "userScripts.change", "userScripts.world", "userScripts.worlds"] {
            _ = try await dispatch.answer(api, [], context: context, in: space)
        }
        let scriptFile = try await dispatch.answer("userScripts.file", [], context: context, in: space)
        XCTAssertNotNil(scriptFile as? String)
        _ = try await dispatch.answer("capture.grant", [], context: context, in: space)
        let result = try await dispatch.answer("identity.launchWebAuthFlow", [["url": "https://example.invalid", "interactive": true]], context: context, in: space)
        XCTAssertEqual(result as? String, "https://fixture.chromiumapp.org/done")
        XCTAssertEqual(host.log.filter { ["report", "language", "colour", "capture", "auth"].contains($0) }, ["report", "language", "colour", "capture", "auth"])
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor func testDelegateAndPartsDoNotKeepTheRuntimeAlive() async throws {
        var fixture: (WebKitExtensionRuntime, DispatchFixtureHost, WKWebExtensionContext, UUID)? = try await self.fixture()
        weak let runtime = fixture?.0
        let controller = fixture!.0.controllers.controller(for: fixture!.3)
        _ = fixture!.0.dispatcher
        XCTAssertNotNil(controller.delegate)
        fixture = nil
        XCTAssertNil(runtime)
        XCTAssertNil(controller.delegate)
    }

    @MainActor func testPermissionDelegateForwardsImmediateRefusals() async throws {
        let (runtime, _, context, space) = try await fixture()
        let controller = runtime.controllers.controller(for: space)
        var replies = 0
        runtime.controllerDelegate.webExtensionController(controller, promptForPermissions: [], in: nil, for: context) { permissions, expiry in
            XCTAssertTrue(permissions.isEmpty); XCTAssertNil(expiry); replies += 1
        }
        runtime.controllerDelegate.webExtensionController(controller, promptForPermissionToAccess: [URL(string: "https://example.invalid")!], in: nil, for: context) { urls, expiry in
            XCTAssertTrue(urls.isEmpty); XCTAssertNil(expiry); replies += 1
        }
        runtime.controllerDelegate.webExtensionController(controller, promptForPermissionMatchPatterns: [], in: nil, for: context) { patterns, expiry in
            XCTAssertTrue(patterns.isEmpty); XCTAssertNil(expiry); replies += 1
        }
        XCTAssertEqual(replies, 3)
    }

    @MainActor func testChannelRefusesASenderOutsideAnExtensionsOwnPage() async throws {
        let (runtime, _, context, space) = try await fixture()
        let controller = runtime.controllers.controller(for: space)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.webExtensionController = controller
        let web = PopupAddressView(frame: .zero, configuration: configuration)
        // Keep the controller and context resolvable while varying only the page and origin.
        for (address, scheme, host, allowed) in [
            ("https://fixture/page.html", "https", "fixture", false),
            ("https://fixture/page.html", "chrome-extension", "fixture", false),
            ("chrome-extension://fixture/page.html", "https", "fixture", false),
            ("chrome-extension://other/page.html", "chrome-extension", "fixture", false),
            ("chrome-extension://other/page.html", "chrome-extension", "other", false),
            ("chrome-extension://fixture/page.html", "chrome-extension", "fixture", true)
        ] {
            web.address = URL(string: address)
            func sender() -> (WKWebExtensionContext, UUID, WKWebView)? {
                runtime.capture.sender(isMainFrame: true, originProtocol: scheme, originHost: host, web: web)
            }
            if allowed {
                let resolved = try XCTUnwrap(sender())
                XCTAssertTrue(resolved.0 === context)
                XCTAssertEqual(resolved.1, space)
                XCTAssertTrue(resolved.2 === web)
            } else {
                XCTAssertNil(sender(), "\(scheme)://\(host) in \(address)")
            }
            var replies = 0
            runtime.capture.receive(["op": "lend"], sender: sender) { answer, error in
                XCTAssertNil(error)
                if allowed {
                    XCTAssertEqual((answer as? [String: Bool])?["ok"], true)
                    XCTAssertNil((answer as? [String: Any])?["error"])
                } else {
                    XCTAssertEqual((answer as? [String: String])?["error"], "NotAllowedError")
                    XCTAssertEqual((answer as? [String: String])?["message"], "Not allowed here")
                    XCTAssertNil((answer as? [String: Any])?["ok"])
                }
                replies += 1
            }
            XCTAssertEqual(replies, 1, address)
        }
        XCTAssertNil(web.window)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(context.isLoaded)
        let replacement = WKWebExtensionContext(for: context.webExtension)
        replacement.uniqueIdentifier = "fixture"
        runtime.controllerDelegate.webExtensionController(controller, sendMessage: ["api": "report"], toApplicationWithIdentifier: "eglu", for: replacement) { answer, error in
            XCTAssertNil(answer)
            XCTAssertEqual(error?.localizedDescription, "Specified native messaging host not found.")
        }
    }
}
#endif
