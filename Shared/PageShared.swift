import PadCore
import WebKit

// The half of Page.swift both apps share: the iPad's (App/Sources/Page.swift)
// and the Mac's (Mac/Sources/Page.swift) call into pages the same way here,
// each asking HandsOff first (PolicyTests keeps it that way).

/// A page of a site loaded out of sight, read once by the site's own reader
/// and let go: for what the page on screen does not have and another page
/// of the same site does (Page.transcript).
///
/// It is the site as a computer is served it, in the same store as the
/// page on screen, so the site knows the person as it does there and asks
/// no consent twice. It plays nothing: no media starts without a touch,
/// and none can be given. It goes nowhere but the site: a step to any
/// other host ends it, a hands-off host above all. It gets none of the
/// app's scripts, only the reader's one call, and the content blocker's
/// lists where the page on screen has them. It stands in the window under
/// the page on screen, where WebKit runs it as a page that shows; out of a
/// window its timers are slowed and it may never be drawn. It is asked as
/// soon as it has begun to load, and the reader waits in it for what it
/// looks for: all of a video's page takes seconds longer to come.
@MainActor
final class Unseen: NSObject, WKNavigationDelegate {
    /// How long the page on screen is given to show its way to what is looked for, in milliseconds.
    static let patienceHere = 1_500
    /// How long a page out of sight is given to begin (its first bytes, after any redirect), and then to
    /// show the way, in milliseconds. It is asked as soon as it has begun, not when all of it has
    /// loaded: a video's page goes on loading for seconds after what is looked for is there.
    private static let start: Duration = .seconds(6)
    private static let patienceThere = 9_000

    private let view: WKWebView
    /// The site it is a page of, and may not leave.
    private let site: SiteAdapter
    private var loaded: ((Bool) -> Void)?

    init(beside page: Page, of site: SiteAdapter) {
        self.site = site
        let config = WKWebViewConfiguration()
        config.websiteDataStore = page.view.configuration.websiteDataStore
        #if os(iOS)
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        #endif
        config.applicationNameForUserAgent = page.view.configuration.applicationNameForUserAgent
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        config.allowsPictureInPictureMediaPlayback = false
        #endif
        config.allowsAirPlayForMediaPlayback = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = WKUserContentController()
        if page.blocksContent {
            for list in ContentBlocker.shared.lists { controller.add(list) }
        }
        config.userContentController = controller
        view = WKWebView(frame: page.view.frame, configuration: config)
        super.init()
        #if os(iOS)
        view.customUserAgent = Identity.macUserAgent(applicationName: config.applicationNameForUserAgent ?? "")
        #endif
        view.navigationDelegate = self
        #if os(macOS)
        view.alphaValue = 0
        view.setAccessibilityElement(false)
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        page.view.superview?.addSubview(view, positioned: .below, relativeTo: page.view)
        #else
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.scrollView.scrollsToTop = false
        view.alpha = 0
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        page.view.superview?.insertSubview(view, belowSubview: page.view)
        #endif
    }

    /// Loads the page, has the reader called on it, and lets the page go, whatever came of it.
    func transcript(at url: URL, call: String, limit: Int) async -> Transcript? {
        defer { stop() }
        guard !HandsOff.covers(url), await begin(url), !Task.isCancelled else { return nil }
        let said = try? await view.callAsyncJavaScript(call, arguments: ["limit": limit, "patience": Self.patienceThere], in: nil,
                                                       contentWorld: Page.world)
        if case .read(let transcript) = Transcript.answer(said) { return transcript }
        return nil
    }

    /// Whether the page began to load, in the time it is given.
    private func begin(_ url: URL) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            loaded = { done.resume(returning: $0) }
            view.load(URLRequest(url: url))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.start)
                self?.finish(false)
            }
        }
    }

    /// The one answer to whether it began, from whichever comes first: the page, a failure, or the time running out.
    private func finish(_ ok: Bool) {
        loaded?(ok)
        loaded = nil
    }

    /// The page goes, and whoever waits on its load hears that nothing came of it.
    func stop() {
        finish(false)
        view.navigationDelegate = nil
        view.stopLoading()
        view.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The page itself may go only to its own site, and to a page of the web: a step anywhere else ends the reading.
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
        let url = navigationAction.request.url
        let own = ["http", "https"].contains(url?.scheme?.lowercased() ?? "") && site.covers(url)
        guard own, !HandsOff.covers(url), !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            finish(false)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        finish(true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(false)
    }
}

extension Page {
    /// The page as Handoff reads it (PageReading): its blocks as Markdown,
    /// each with what the walk knew of it, what was counted for the kind
    /// of page it is, what it declares, and what the person had selected.
    /// markdown.js, run this once, in the app's own world, reading the
    /// page and changing nothing. Never on a hands-off page, bridge or no
    /// bridge. Says why there is nothing to read as text: a picture, a
    /// page that failed. A PDF is read as the document it is.
    func readingForHandoff(limit: Int, into folder: URL, telling: Handoff.Telling? = nil) async -> Handoff.ReadOutcome {
        // The document of an earlier handoff is not this one's: the tab may have gone on to an article since.
        handoffDocument = nil
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed) else { return .protectedPage() }
        if let mimeType, let declared = FileFormat(mimeType: mimeType) {
            // A file in the tab is a document — a PDF, or a text, CSV,
            // JSON or XML page: fetched through the tab's own web view
            // into the job's folder (its sign-ins come with it) and read
            // as a DocumentSource would read it, never through markdown.js.
            guard let url = view.url ?? committed else { return .failed() }
            do {
                let fetched = try await HandoffFetch.fetch(url, with: view, into: folder)
                let source = DocumentSource(file: fetched, name: (view.title ?? fetched.lastPathComponent),
                                            address: url, format: declared)
                handoffDocument = source
                return await source.reading(limit: limit, into: folder, telling: telling)
            } catch { return .failed(String(localized: "The file could not be fetched.")) }
        }
        do {
            let value = try await view.callAsyncJavaScript(Scripts.markdownCall, arguments: ["limit": limit], in: nil,
                                                           contentWorld: Page.world)
            guard let said = value as? [String: Any], let reading = PageReading(said) else { return .failed() }
            return reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noReadableContent : .content(reading)
        } catch { return .failed() }
    }

    /// What is said in the page's recording, where the site has a reader
    /// of its own that can get it (SiteAdapter.reader: YouTube's presses
    /// the site's "Show transcript" out of sight). Asked of the page on
    /// screen first. Where that page has no way to it and another of the
    /// site's has (the site as a phone is served it shows no transcript),
    /// that other page is loaded out of sight, read and let go (Unseen).
    /// Never on a hands-off page. Nil when there is none to be had in time.
    func transcript(limit: Int) async -> Transcript? {
        guard !HandsOff.covers(view.url), !HandsOff.covers(committed), let call = Scripts.readerCall(for: adapter) else { return nil }
        let said = try? await view.callAsyncJavaScript(call, arguments: ["limit": limit, "patience": Unseen.patienceHere], in: nil,
                                                       contentWorld: Page.world)
        let here = Transcript.answer(said)
        if case .read(let transcript) = here { return transcript }
        guard here.looksElsewhere, !Task.isCancelled, let url = adapter.readerPage(for: view.url), !HandsOff.covers(url) else { return nil }
        let unseen = Unseen(beside: self, of: adapter)
        return await withTaskCancellationHandler {
            await unseen.transcript(at: url, call: call, limit: limit)
        } onCancel: {
            Task { @MainActor in unseen.stop() }
        }
    }
}

/// The content blocker's lists in one page's controller, by identifier: none
/// on a hands-off page, or where Settings or the site's switch turns it off.
struct PageBlocking {
    private(set) var identifiers: [String] = []

    /// Whether the page has ads and trackers blocked.
    var isOn: Bool {
        !identifiers.isEmpty
    }

    /// The content blocker's lists for a document at `url` (ContentBlocker):
    /// WebKit blocks with them from the next load. Never on a hands-off
    /// host, where nothing of the app's may touch the page.
    @MainActor
    mutating func apply(for url: URL?, to controller: WKUserContentController) {
        let on = !HandsOff.covers(url) && Session.shared.preferences.blocksContent(onHost: url?.host)
        let lists = on ? ContentBlocker.shared.lists : []
        let ids = lists.compactMap(\.identifier)
        guard ids != identifiers else { return }
        controller.removeAllContentRuleLists()
        for list in lists { controller.add(list) }
        identifiers = ids
    }

    /// The page is closing: its lists go with it.
    @MainActor
    mutating func remove(from controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        identifiers = []
    }
}

/// The main frame's HTTP status, for the developer bar: the status of the
/// document on screen, not of the last answer. It changes when a document
/// commits, so a download keeps the status of the page it came from and a
/// failed load has none; and it is kept with its history item, since a page
/// WebKit brings back from its back-forward cache commits with no answer.
struct PageStatus {
    /// The status of the document on screen; nil for a file, a failed load or one not answered yet.
    private(set) var code: Int?
    /// The answer to the load under way, until it commits.
    private var pending: Int??
    private let byItem = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()

    /// The main frame's answer, which WebKit will show.
    mutating func answered(_ response: URLResponse) {
        pending = .some((response as? HTTPURLResponse)?.statusCode)
    }

    /// The answer won't be shown: a download, or a load asked again.
    mutating func dropped() {
        pending = nil
    }

    /// A document committed as `item`: its own answer, or, with none, the
    /// one it had when it was first shown.
    mutating func committed(_ item: AnyObject?) {
        if let answer = pending {
            code = answer
            if let item {
                if let answer { byItem.setObject(NSNumber(value: answer), forKey: item) } else { byItem.removeObject(forKey: item) }
            }
        } else {
            code = item.flatMap { byItem.object(forKey: $0)?.intValue }
        }
        pending = nil
    }

    /// The load failed: what is shown is the failure, which has no status.
    mutating func failed() {
        code = nil
        pending = nil
    }
}

extension WKUserContentController {
    /// What a site's filters ask for that WebKit's rules can't do
    /// (ScriptedFilters): the hiding in the app's own world, where the page
    /// can't reach it; the scriptlets in the page's, since what they change
    /// is the page's own. Only for a page prepare() has found is not hands-off.
    @MainActor
    func addFilterScripts(for filters: PageRules) {
        if let script = Scripts.blocker(for: filters) {
            addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true, in: Page.world))
        }
        if let script = Scripts.scriptlets(for: filters) {
            addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true, in: .page))
        }
    }
}

extension NewTabClick {
    /// Whether a navigation is a ⌘-click (or ⌘⇧, or a middle click) to open
    /// in a new tab, from what WebKit says started it and the keys and the
    /// button each app finds made it.
    @MainActor
    static func choice(for action: WKNavigationAction, command: Bool, shift: Bool, middleButton: Bool) -> Choice {
        let kind: Kind
        switch action.navigationType {
        case .linkActivated: kind = .link
        case .formSubmitted: kind = .form
        case .other: kind = .script
        default: kind = .history
        }
        return choice(kind: kind, command: command, shift: shift, middleButton: middleButton,
                      method: action.request.httpMethod, scheme: action.request.url?.scheme,
                      mainFrame: action.targetFrame?.isMainFrame ?? true)
    }
}
