#if os(macOS)
import AppKit
import PadCore
import WebKit

/// An extension started on its own, before it is given a place: in a
/// controller that keeps nothing (non-persistent), with nothing granted,
/// no tab, no window and no answer to anything it asks of the app, so
/// nothing it does lands in a space. What an update is tried in before it
/// takes the old version's place (Docs/ExtensionsDesign.md, sections 3 and 4).
@MainActor
public enum ExtensionTrial {
    struct Failed: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Loads it and starts its background; throws if WebKit refuses it or
    /// says its background failed to load. A background that doesn't answer
    /// within eight seconds isn't taken for a failure: WebKit doesn't always
    /// call back, and only its error says it failed.
    public static func start(_ package: WKWebExtension, id: String, scheme: String) async throws {
        let controller = WKWebExtensionController(configuration: throwaway())
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = id
        context.baseURL = URL(string: "\(scheme)://\(id)/")!
        try controller.load(context)
        defer { try? controller.unload(context) }
        guard package.hasBackgroundContent else { return }
        let error: Error? = await withCheckedContinuation { done in
            var finished = false
            let finish: (Error?) -> Void = { result in
                guard !finished else { return }
                finished = true
                done.resume(returning: result)
            }
            context.loadBackgroundContent { error in MainActor.assumeIsolated { finish(error) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(nil) }
        }
        let failed = context.errors.contains {
            let error = $0 as NSError
            return error.domain == WKWebExtensionContext.errorDomain
                && error.code == WKWebExtensionContext.Error.Code.backgroundContentFailedToLoad.rawValue
        }
        if let error { throw error }
        if failed { throw Failed(why: String(localized: "Its background failed to start.")) }
    }
}

// MARK: Its first seconds, tried on a copy

extension ExtensionTrial {
    /// A controller that keeps nothing: neither the extensions' storage nor
    /// what their pages store, in one website store of its own that goes
    /// with it.
    public static func throwaway() -> WKWebExtensionController.Configuration {
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.defaultWebsiteDataStore = store
        let pages = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        pages.websiteDataStore = store
        configuration.webViewConfiguration = pages
        return configuration
    }

    /// What trying its pages on a copy found (Docs/ExtensionsDesign.md,
    /// section 4, "In the first seconds").
    public struct Checked: Equatable {
        public var testPage: ExtensionEvidence.Probe = .notApplicable
        public var popup: ExtensionEvidence.Probe = .notApplicable
        public var optionsPage: ExtensionEvidence.Probe = .notApplicable
        /// Errors of a known kind, with the file each came from.
        public var problems: [(problem: ExtensionError.Problem, file: String?)] = []

        public init(testPage: ExtensionEvidence.Probe = .notApplicable, popup: ExtensionEvidence.Probe = .notApplicable,
                    optionsPage: ExtensionEvidence.Probe = .notApplicable,
                    problems: [(problem: ExtensionError.Problem, file: String?)] = []) {
            self.testPage = testPage
            self.popup = popup
            self.optionsPage = optionsPage
            self.problems = problems
        }

        public static func == (a: Checked, b: Checked) -> Bool {
            a.testPage == b.testPage && a.popup == b.popup && a.optionsPage == b.optionsPage
                && a.problems.map(\.problem) == b.problems.map(\.problem)
        }
    }

    /// The page its content scripts are tried on: an empty one, at an
    /// address that can never be a site's (.invalid is reserved, RFC 2606),
    /// so nothing goes to the network for it.
    static let testPage = URL(string: "https://test.eglu.invalid/")!

    /// Patterns that match most sites: an extension whose scripts go
    /// only on some has them skipped, as a test page would only fail them.
    static let everywhere: Set<String> = ["<all_urls>", "*://*/*", "https://*/*", "http://*/*"]

    /// Its copy, from its prepared folder, in a controller that keeps
    /// nothing, granted what it asks for but Google's sign-in and cookies,
    /// as every extension is until the person allows it cookies: its content scripts on the test page, then
    /// its popup and its settings page, each given five seconds. The
    /// copy's own requests (a tab, a window, the app) go unanswered, and
    /// nothing it does lands in a space.
    /// An error that comes of the copy having no tab and no window: its
    /// pages are in none, and WebKit carries a page's messages only when it
    /// can name its tab ("Tab not found"); a window asked for isn't there
    /// ("Window not found"). The copy's, never the extension's: in use, its
    /// popup is a tab (ExtensionPopups). They read as Bitwarden's popup and
    /// 1Password's failing.
    static func copysOwn(_ words: String) -> Bool {
        words.localizedCaseInsensitiveContains("Tab not found") || words.localizedCaseInsensitiveContains("Window not found")
    }

    public static func check(_ folder: URL, id: String, manifest: ExtensionManifest, missing: Set<String>,
                             scheme: String, shimApplication: String,
                             letRulesRedirect: (WKWebExtensionContext, WKWebExtension) -> Void,
                             sites: (WKWebExtension) -> [WKWebExtension.MatchPattern],
                             fence: (WKWebExtensionContext) -> Void) async -> Checked {
        var checked = Checked()
        guard let package = try? await WKWebExtension(resourceBaseURL: folder) else { return checked }
        let configuration = throwaway()
        let controller = WKWebExtensionController(configuration: configuration)
        let quiet = Quiet(missing: missing, shimApplication: shimApplication)
        controller.delegate = quiet
        defer { withExtendedLifetime(quiet) {} }
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = id
        context.baseURL = URL(string: "\(scheme)://\(id)/")!
        for permission in package.requestedPermissions where !ExtensionPolicy.heldPermissions.contains(permission.rawValue) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        letRulesRedirect(context, package)
        for pattern in sites(package) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        fence(context)
        for permission in ExtensionPolicy.heldPermissions {
            context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        guard (try? controller.load(context)) != nil else { return checked }
        defer { try? controller.unload(context) }

        // A page's errors: those that arrived while it loaded, from its own files.
        func errors(since count: Int) -> [NSError] {
            Array(context.errors.dropFirst(count)).map { $0 as NSError }
        }

        let scripts = manifest.contentScripts.filter { !Set($0.matches).isDisjoint(with: everywhere) }
        if !scripts.isEmpty {
            let before = context.errors.count
            let page = WKWebViewConfiguration()
            page.webExtensionController = controller
            page.websiteDataStore = configuration.defaultWebsiteDataStore
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: page)
            let loaded = await Loading.page(in: web) { web.loadHTMLString("<!doctype html>", baseURL: testPage) }
            // WebKit says nothing when a content script has run: no error
            // about an API from one in the second after is the pass. Its
            // other errors (a console.error, an empty page's missing
            // element) are no failure of eGlu's.
            try? await Task.sleep(for: .milliseconds(1500))
            let files = Set(scripts.flatMap(\.scripts).map(ExtensionPreparation.normalized))
            // Not one that comes of the page being in no tab (copysOwn):
            // NordPass's content script connects to its worker, which a
            // page in no tab can't, and in use its pages are all in tabs.
            let theirs = errors(since: before).filter { error in
                !Self.copysOwn(error.localizedDescription)
                    && ExtensionError.place(in: error.localizedDescription).map { files.contains(ExtensionPreparation.normalized($0.file)) } ?? false
                    && ExtensionError.problem(in: error.localizedDescription, missing: missing) != nil
            }
            checked.testPage = loaded == nil ? .timedOut : theirs.isEmpty ? .passed : .failed
        } else if !manifest.contentScripts.isEmpty {
            checked.testPage = .skipped
        }

        for (page, keyPath) in [(manifest.popup, \Checked.popup), (manifest.optionsPage, \Checked.optionsPage)] {
            guard let page, let url = URL(string: page, relativeTo: context.baseURL)?.absoluteURL,
                  url.scheme == scheme, url.host() == id, let configuration = context.webViewConfiguration
            else { continue }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
            let loaded = await Loading.page(in: web) { web.load(URLRequest(url: url)) }
            checked[keyPath: keyPath] = loaded.map { $0 ? .passed : .failed } ?? .timedOut
            web.stopLoading()
        }

        // A second more for what the pages set going, then what was read
        // that isn't there.
        try? await Task.sleep(for: .seconds(1))
        for error in context.errors.map({ $0 as NSError }) {
            guard !Self.copysOwn(error.localizedDescription),
                  let problem = ExtensionError.problem(in: error.localizedDescription, missing: missing) else { continue }
            checked.problems.append((problem, ExtensionError.place(in: error.localizedDescription)?.file))
        }
        // And what its shim caught itself, where WebKit doesn't report errors (macOS 26).
        for report in quiet.reports where !checked.problems.contains(where: { $0.problem == report.problem }) {
            checked.problems.append(report)
        }
        return checked
    }
}

/// The copy's word to the app: its shim's questions answered with
/// nothing, so they don't read as its own failures; a desktop app never
/// reached.
@MainActor
private final class Quiet: NSObject, WKWebExtensionControllerDelegate {
    let missing: Set<String>
    /// The errors its shim reported, of a known kind.
    private(set) var reports: [(problem: ExtensionError.Problem, file: String?)] = []

    private let shimApplication: String

    init(missing: Set<String>, shimApplication: String) {
        self.shimApplication = shimApplication
        self.missing = missing
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        // [kind, its words, file, line], as Extensions' answer reads it.
        if let call = message as? [String: Any], call["api"] as? String == "report", let args = call["args"] as? [Any], args.count > 1,
           let words = args[1] as? String, !ExtensionTrial.copysOwn(words),
           let problem = ExtensionError.problem(in: words, missing: missing) {
            reports.append((problem, args.count > 2 ? args[2] as? String : nil))
        }
        replyHandler(nil, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(applicationIdentifierIsShims(port) ? nil : Refused())
    }

    private func applicationIdentifierIsShims(_ port: WKWebExtension.MessagePort) -> Bool {
        port.applicationIdentifier?.hasPrefix(shimApplication) == true
    }

    struct Refused: LocalizedError {
        var errorDescription: String? { "Specified native messaging host not found." }
    }
}

/// A page loading, waited for: true when it finished, false when it
/// failed, nil when five seconds went by first.
@MainActor
private final class Loading: NSObject, WKNavigationDelegate {
    private var done: CheckedContinuation<Bool?, Never>?

    static func page(in web: WKWebView, start: () -> Void) async -> Bool? {
        let loading = Loading()
        web.navigationDelegate = loading
        let result: Bool? = await withCheckedContinuation { done in
            loading.done = done
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { loading.finish(nil) }
        }
        web.navigationDelegate = nil
        return result
    }

    private func finish(_ result: Bool?) {
        done?.resume(returning: result)
        done = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }

    /// A load the page itself replaced (it went to another of its pages
    /// first thing) isn't a failure: the next one finishes or fails.
    private func failed(_ error: any Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        finish(false)
    }
}
#endif
