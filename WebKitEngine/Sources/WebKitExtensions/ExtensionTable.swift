#if os(macOS)
import AppKit
import PadCore
import WebKit

/// What this Mac's WebKit gives an extension, measured rather than listed
/// (Docs/ExtensionsDesign.md, section 4): a test extension that asks for
/// every permission Chrome has, granted them all, lists every namespace
/// and member its worker gets, once a macOS build; the answer is kept.
/// With the shims' list on top (ExtensionAPITable.shims), it is the table
/// every check compares an extension against. It runs without the shim,
/// in a controller that keeps nothing, with no tab, window or site.
@MainActor
public final class ExtensionTable: NSObject, WKWebExtensionControllerDelegate {
    private let scheme: String
    private static let key = "extensionTable"

    /// This Mac's table; nil until measured on this macOS build.
    public private(set) var table: ExtensionAPITable?
    private var measuring: Task<Void, Never>?
    private var heard: CheckedContinuation<[String: [String]]?, Never>?

    public static var build: String { ProcessInfo.processInfo.operatingSystemVersionString }

    public init(scheme: String) {
        self.scheme = scheme
        super.init()
        if let kept = UserDefaults.standard.dictionary(forKey: Self.key), kept["build"] as? String == Self.build,
           let namespaces = kept["namespaces"] as? [String: [String]] {
            table = ExtensionAPITable(webKit: namespaces.mapValues(Set.init), shims: ExtensionAPITable.shims)
        }
    }

    /// The table, measured first if this build hasn't been; nil if the
    /// test extension couldn't say within ten seconds.
    public func measured() async -> ExtensionAPITable? {
        if let table { return table }
        if let measuring {
            await measuring.value
            return table
        }
        let task = Task { await measure() }
        measuring = task
        await task.value
        measuring = nil
        return table
    }

    private func measure() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eglu-table-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try Self.worker.write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
            let package = try await WKWebExtension(resourceBaseURL: folder)
            let controller = WKWebExtensionController(configuration: ExtensionTrial.throwaway())
            controller.delegate = self
            let context = WKWebExtensionContext(for: package)
            context.uniqueIdentifier = "eglu-table"
            context.baseURL = URL(string: "\(scheme)://eglu-table/")!
            for permission in package.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in package.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            defer { try? controller.unload(context) }
            let namespaces: [String: [String]]? = await withCheckedContinuation { done in
                heard = done
                context.loadBackgroundContent { _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.hear(nil) }
            }
            guard let namespaces, !namespaces.isEmpty else {
                NSLog("eGlu: the test extension didn't list what WebKit gives it")
                return
            }
            UserDefaults.standard.set(["build": Self.build, "namespaces": namespaces], forKey: Self.key)
            table = ExtensionAPITable(webKit: namespaces.mapValues(Set.init), shims: ExtensionAPITable.shims)
        } catch {
            NSLog("eGlu: the test extension didn't load: \(error.localizedDescription)")
        }
    }

    private func hear(_ namespaces: [String: [String]]?) {
        heard?.resume(returning: namespaces)
        heard = nil
    }

    /// The worker's list, its one message.
    public func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        hear((message as? [String: Any])?.compactMapValues { $0 as? [String] })
        replyHandler(nil, nil)
    }

    // MARK: The test extension

    /// Every permission Chrome documents (developer.chrome.com/docs/extensions/reference/permissions-list),
    /// and Safari's `menus`; with a button and a command, whose namespaces
    /// come only with them.
    static let permissions = [
        "activeTab", "alarms", "background", "bookmarks", "browsingData", "certificateProvider", "clipboardRead",
        "clipboardWrite", "contentSettings", "contextMenus", "cookies", "debugger", "declarativeContent",
        "declarativeNetRequest", "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess",
        "desktopCapture", "dns", "documentScan", "downloads", "downloads.open", "downloads.ui", "favicon",
        "fileBrowserHandler", "fileSystemProvider", "fontSettings", "gcm", "geolocation", "history", "identity",
        "identity.email", "idle", "loginState", "management", "menus", "nativeMessaging", "notifications", "offscreen",
        "pageCapture", "platformKeys", "power", "printerProvider", "printing", "printingMetrics", "privacy",
        "processes", "proxy", "readingList", "runtime", "scripting", "search", "sessions", "sidePanel", "storage",
        "system.cpu", "system.display", "system.memory", "system.storage", "tabCapture", "tabGroups", "tabs",
        "topSites", "tts", "ttsEngine", "unlimitedStorage", "userScripts", "webAuthenticationProxy",
        "webNavigation", "webRequest", "webRequestAuthProvider", "webRequestBlocking",
    ]

    static var manifest: String {
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {"manifest_version": 3, "name": "eGlu's table", "version": "1",
         "background": {"service_worker": "worker.js"},
         "action": {}, "commands": {"one": {"description": "One"}},
         "permissions": [\(list)], "host_permissions": ["<all_urls>"]}
        """
    }

    /// Each namespace on `chrome`, with its members and its own namespaces'
    /// ("system.display"), sent to the app.
    static let worker = """
    const table = {};
    const members = (value) => {
      const names = new Set();
      for (let o = value; o && o !== Object.prototype && o !== Function.prototype; o = Object.getPrototypeOf(o)) {
        for (const name of Object.getOwnPropertyNames(o)) if (name !== "constructor") names.add(name);
      }
      return [...names];
    };
    const list = (value, path, depth) => {
      const names = members(value);
      table[path] = names;
      if (depth > 0) for (const name of names) {
        let inner;
        try { inner = value[name]; } catch (e) { continue; }
        if (inner && typeof inner === "object" && !Array.isArray(inner) && typeof inner.addListener !== "function") list(inner, path + "." + name, depth - 1);
      }
    };
    for (const name of members(chrome)) {
      let value;
      try { value = chrome[name]; } catch (e) { continue; }
      if (value && typeof value === "object") list(value, name, 1);
    }
    chrome.runtime.sendNativeMessage("eglu.table", table);
    """
}
#endif
