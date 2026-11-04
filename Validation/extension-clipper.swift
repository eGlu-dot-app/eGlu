// Isolated Are.na-style clipper runtime check. No account or network posts.
// Compile with production ExtensionPreparation, ExtensionManifest, ExtensionStore,
// ZipFile, Hosts, HandsOff, ExtensionPolicy and Mac ExtensionLanguage sources.
// Link AppKit, WebKit and NaturalLanguage. Pass the repository root as argv[1].
import AppKit
import Foundation
import WebKit

@MainActor
private final class FixtureTab: NSObject, WKWebExtensionTab {
    var view: WKWebView!
    weak var owner: FixtureWindow?
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    func title(for context: WKWebExtensionContext) -> String? { view.title }
    func url(for context: WKWebExtensionContext) -> URL? { view.url }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !view.isLoading }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        ExtensionPolicy.grantsOnClick(view.url)
    }
}

@MainActor
private final class FixtureWindow: NSObject, WKWebExtensionWindow {
    let tab = FixtureTab()
    override init() { super.init(); tab.owner = self }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 800, height: 600) }
}

@MainActor
private final class Fixture: NSObject, WKWebExtensionControllerDelegate, WKNavigationDelegate {
    let window = FixtureWindow()
    var reports: [String: [String: Any]] = [:]
    var pageLoaded = false
    var checks = 0

    func check(_ name: String, _ passed: Bool) throws {
        guard passed else { throw NSError(domain: "ClipperFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        checks += 1
        print("PASS", name)
    }

    func waitFor(_ ready: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "ClipperFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "timed out"])
    }

    func run(root: URL) async throws {
        let room = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-clipper-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: room) }
        try FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        let shim = try String(contentsOf: root.appendingPathComponent("PadCore/Sources/PadCore/Scripts/extension-shim.js"), encoding: .utf8)
        let raw = Data(#"{"manifest_version":3,"name":"Synthetic Clipper","description":"Local synthetic clipper compatibility fixture.","version":"1","permissions":["activeTab","contextMenus","scripting","storage"],"action":{},"background":{"service_worker":"worker.js"},"web_accessible_resources":[{"resources":["panel.html","panel.js"],"matches":["<all_urls>"]}]}"#.utf8)
        let edited = try ExtensionPreparation.manifest(raw)
        let filled = ExtensionPreparation.filled(shim, scripts: ["/worker.js", "/content.js", "/panel.js"], added: edited.added)
        let files: [String: Data] = [
            "manifest.json": edited.manifest,
            ExtensionPreparation.shimFile: Data(filled.utf8),
            "worker.js": ExtensionPreparation.worker(Data(Self.worker.utf8), shim: filled, module: false),
            "content.js": Data(Self.content.utf8),
            "panel.html": Data(ExtensionPreparation.page("<!doctype html><html><head><script src=\"panel.js\"></script></head><body>Local test panel</body></html>").utf8),
            "panel.js": Data(Self.panel.utf8)
        ]
        for (path, bytes) in files {
            let file = room.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let package = try await WKWebExtension(resourceBaseURL: room)
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.defaultWebsiteDataStore = store
        let pageConfiguration = WKWebViewConfiguration()
        pageConfiguration.websiteDataStore = store
        configuration.webViewConfiguration = pageConfiguration
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "abcdefghijklmnopabcdefghijklmnop"
        context.baseURL = URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/")!
        for permission in package.requestedPermissions where !ExtensionPolicy.heldPermissions.contains(permission.rawValue) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for permission in ExtensionPolicy.heldPermissions {
            context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        for site in ExtensionPolicy.deniedSites {
            if let pattern = try? WKWebExtension.MatchPattern(string: site) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
        }
        pageConfiguration.webExtensionController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: pageConfiguration)
        window.tab.view = view
        view.navigationDelegate = self
        try controller.load(context)
        defer { try? controller.unload(context) }
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        controller.didOpenTab(window.tab)
        controller.didActivateTab(window.tab, previousActiveTab: nil)
        try await context.loadBackgroundContent()
        try await waitFor { self.reports["ready"] != nil }
        try check("clipper worker registers its action and context menu", reports["ready"]?["menu"] as? Bool == true)
        let detection = reports["ready"]?["language"] as? [String: Any]
        let languages = detection?["languages"] as? [[String: Any]]
        try check("native language helper returns Chrome shape to the worker",
                  detection?["isReliable"] as? Bool == true && languages?.first?["language"] as? String == "en" && languages?.first?["percentage"] as? Int == 100)
        view.loadHTMLString("<!doctype html><title>Synthetic Clipper Page</title><p id=quote>Selected test quote</p>",
                            baseURL: URL(string: "https://fixture.eglu.invalid/clip"))
        try await waitFor { self.pageLoaded }
        controller.didChangeTabProperties([.URL, .title, .loading], for: window.tab)
        print("STEP synthetic page loaded", view.url?.absoluteString ?? "nil")
        _ = try await view.evaluateJavaScript("getSelection().selectAllChildren(document.getElementById('quote')); true;")
        context.performAction(for: window.tab)
        do { try await waitFor { self.reports["clip"] != nil } }
        catch {
            for error in context.errors {
                let error = error as NSError
                print("CONTEXT ERROR", error.domain, error.code, error.localizedDescription, error.userInfo)
            }
            throw error
        }
        let clip = reports["clip"]
        try check("action injects a content script and receives selected text through messaging",
                  clip?["title"] as? String == "Synthetic Clipper Page" && clip?["text"] as? String == "Selected test quote")
        try check("clipper storage retains the selected synthetic address", clip?["url"] as? String == "https://fixture.eglu.invalid/clip")
        try await waitFor { self.reports["panel"] != nil }
        try check("embedded extension panel exchanges messages through its worker", reports["panel"]?["echo"] as? String == "local panel")
        try check("cookie and Google sign-in boundaries remain denied",
                  context.permissionStatus(for: .cookies) == .deniedExplicitly && !ExtensionPolicy.grantsOnClick(URL(string: "https://accounts.google.com/signin")))
        for error in context.errors {
            let error = error as NSError
            print("FINAL ERROR", error.domain, error.code, error.localizedDescription, error.userInfo)
        }
        try check("native fixture has no extension runtime errors", context.errors.isEmpty)
        print("clipper:", checks, "passed, 0 failed")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded = true }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [window] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window }
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for context: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        if applicationIdentifier == "eglu.fixture", let report = message as? [String: Any], let stage = report["stage"] as? String {
            reports[stage] = report
            if stage == "failed" { print("WORKER ERROR", report["error"] ?? "unknown") }
        }
        if let call = message as? [String: Any], call["api"] as? String == "report" { print("SHIM REPORT", call["args"] ?? []) }
        if let call = message as? [String: Any], call["api"] as? String == "i18n.detectLanguage", let text = (call["args"] as? [Any])?.first as? String {
            replyHandler(["value": ExtensionLanguage.detect(text).json], nil)
        } else {
            replyHandler(["value": NSNull()], nil)
        }
    }

    static let worker = #"""
    chrome.runtime.onMessage.addListener(async (message) => {
      if (message.kind === 'panel') return { echo: 'local panel' };
      if (message.kind === 'panelAck') {
        await chrome.runtime.sendNativeMessage('eglu.fixture', { stage: 'panel', echo: message.echo });
      }
    });
    chrome.action.onClicked.addListener(async (tab) => {
      try {
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['content.js'] });
      const captured = await chrome.tabs.sendMessage(tab.id, { kind: 'read' });
      await chrome.storage.local.set({ captured });
      const stored = await chrome.storage.local.get('captured');
      await chrome.runtime.sendNativeMessage('eglu.fixture', { stage: 'clip', ...stored.captured });
      } catch (error) {
        await chrome.runtime.sendNativeMessage('eglu.fixture', { stage: 'failed', error: String(error) });
      }
    });
    (async () => {
      await chrome.contextMenus.removeAll();
      chrome.contextMenus.create({ id: 'clip', title: 'Save Test Quote', contexts: ['selection'] });
      const language = await chrome.i18n.detectLanguage('This is a clear English sentence about a browser extension.');
      await chrome.runtime.sendNativeMessage('eglu.fixture', { stage: 'ready', menu: true, language });
    })();
    """#

    static let content = #"""
    chrome.runtime.onMessage.addListener(async (message) => {
      if (message.kind !== 'read') return;
      const frame = document.createElement('iframe');
      frame.src = chrome.runtime.getURL('panel.html');
      document.body.appendChild(frame);
      return { title: document.title, text: getSelection().toString(), url: location.href };
    });
    """#

    static let panel = #"""
    (async () => {
      const reply = await chrome.runtime.sendMessage({ kind: 'panel' });
      await chrome.runtime.sendMessage({ kind: 'panelAck', echo: reply.echo });
    })();
    """#
}

@main
struct ClipperCheck {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fixture = Fixture()
        Task { @MainActor in
            do {
                try await fixture.run(root: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
                exit(0)
            } catch { print("FAIL", error); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { print("FAIL fixture timeout"); exit(2) }
        withExtendedLifetime(fixture) { RunLoop.main.run() }
    }
}
