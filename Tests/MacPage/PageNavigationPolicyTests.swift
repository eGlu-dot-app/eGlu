import PadCore
import WebEngineCore
import WebKit
import WebKitMacPlugin
import XCTest
@testable import eGluMac

/// The page's answer to each navigation, asked with plain values
/// (`Page.decideNavigation`, Docs/EngineSplitPlan.md, 7, step 4a): one
/// answer, given before the call returns; a new tab where PadCore's rule
/// says (NewTabClick), on the side it says; a download before anything
/// else; a frame's own navigation leaving the page's address alone. And the
/// page as WebKit's navigation delegate through `WebKitNavigationAdapter`:
/// what the adapter doesn't decide still reaches the page.
///
/// Pages here are data: and about: pages, which need no network. The https
/// addresses are only ever decided on, never loaded, at `.invalid`, which
/// names no host anywhere.
///
/// Not here: a link for another app (AppLink: it asks a question or opens
/// the app), an extension's sign-in coming back (ExtensionAuth,
/// chromiumapp.org), extensions' pages and their rules' redirects, and a
/// website asked again in the screen's light or dark (ColorSchemeHint).
@MainActor
final class PageNavigationPolicyTests: PageTestCase {
    // MARK: New tabs

    /// ⌘-click behind, ⌘⇧ in front, the middle button behind and ⇧ with it
    /// in front, as PadCore's rule says of each: the host is asked for a tab
    /// at the link's address on that side, and the page itself goes nowhere.
    func testNewTabClicksAreTheHostsAndCancelled() {
        let page = makePage()
        let host = NewTabHost()
        page.host = host
        for click in Self.newTabClicks {
            host.newTabs.removeAll()
            let url = Self.web(click.slug)
            let navigation = Self.navigation(to: url, modifiers: click.modifiers, button: click.button)
            let rule = Self.newTabClick(navigation)
            XCTAssertEqual(rule, click.rule, "PadCore's rule for a \(click.name)")
            XCTAssertEqual(decide(page, navigation), .cancel, click.name)
            XCTAssertEqual(host.newTabs, [NewTab(url: url, inFront: rule == .inFront)], click.name)
        }
        XCTAssertNil(page.displayURL, "a click that went to a new tab began a navigation here")
        XCTAssertNil(page.view.url)
    }

    /// The same clicks where the host has no tabs (a little window's, a
    /// pop-up's): asked once each, it says no, and the page goes there itself.
    func testNewTabClicksTheHostCannotTakeAreAllowed() {
        for click in Self.newTabClicks {
            let page = makePage()
            let host = NewTabHost()
            host.takesNewTabs = false
            page.host = host
            let url = Self.web(click.slug)
            let navigation = Self.navigation(to: url, modifiers: click.modifiers, button: click.button)
            let rule = Self.newTabClick(navigation)
            XCTAssertEqual(rule, click.rule, "PadCore's rule for a \(click.name)")
            XCTAssertEqual(decide(page, navigation), .allow, click.name)
            XCTAssertEqual(host.newTabs, [NewTab(url: url, inFront: rule == .inFront)], click.name)
            XCTAssertEqual(page.displayURL, url, "the page didn't begin going there itself, \(click.name)")
        }
    }

    /// Every mix of kind, keys, button, method, address and frame, with a
    /// host that takes new tabs and one that doesn't: a new tab is asked for
    /// exactly where PadCore's rule says, on the side it says, and only a
    /// tab the host took is cancelled here.
    func testEveryNavigationFollowsNewTabClick() {
        let page = makePage()
        let host = NewTabHost()
        page.host = host
        let kinds: [WebNavigationKind] = [.link, .form, .other, .history, .reload, .formResubmission, .unknown(99)]
        let keys: [WebModifiers] = [[], [.command], [.command, .shift], [.shift]]
        let frames: [Bool?] = [true, false, nil]
        var asked = 0
        for takes in [true, false] {
            host.takesNewTabs = takes
            for kind in kinds {
                for modifiers in keys {
                    for button in [0, 2] {
                        for method in ["GET", "POST"] {
                            for url in [Self.web("every"), Self.address("Every")] {
                                for frame in frames {
                                    host.newTabs.removeAll()
                                    let navigation = Self.navigation(to: url, kind: kind, modifiers: modifiers,
                                                                     button: button, mainFrame: frame, method: method)
                                    let rule = Self.newTabClick(navigation)
                                    let what = Self.describe(navigation) + (takes ? ", the host takes tabs" : ", no tabs")
                                    let newTabs: [NewTab] = rule == .here ? [] : [NewTab(url: url, inFront: rule == .inFront)]
                                    let answer: WebNavigationDecision = rule != .here && takes ? .cancel : .allow
                                    XCTAssertEqual(decide(page, navigation), answer, what)
                                    XCTAssertEqual(host.newTabs, newTabs, what)
                                    if rule != .here { asked += 1 }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(asked, 0, "no case in the table was a new tab's")
    }

    // MARK: Plain navigations

    /// A plain click, a reload, a step back or forward and a form sent again,
    /// to a website or a data: page: no new tab, and allowed. With ⌘ or the
    /// middle button held, the last three still stay here, as PadCore says.
    func testPlainNavigationsAreAllowedHere() {
        let page = makePage()
        let host = NewTabHost()
        page.host = host
        let plain: [(String, WebNavigationKind, String)] = [
            ("click", .link, "GET"), ("reload", .reload, "GET"),
            ("step back or forward", .history, "GET"), ("form sent again", .formResubmission, "POST"),
        ]
        for (name, kind, method) in plain {
            for url in [Self.web("plain"), Self.address("Plain")] {
                let navigation = Self.navigation(to: url, kind: kind, method: method)
                XCTAssertEqual(Self.newTabClick(navigation), .here, "PadCore's rule for a \(name)")
                XCTAssertEqual(decide(page, navigation), .allow, "\(name) to \(url.scheme ?? "")")
            }
        }
        for (name, kind, method) in plain.dropFirst() {
            for (modifiers, button) in [([.command], 0), ([.command, .shift], 0), ([], 2)] as [(WebModifiers, Int)] {
                let navigation = Self.navigation(to: Self.web("held"), kind: kind, modifiers: modifiers,
                                                 button: button, method: method)
                XCTAssertEqual(Self.newTabClick(navigation), .here, "PadCore's rule for a \(name), keys or button held")
                XCTAssertEqual(decide(page, navigation), .allow, "\(name), keys or button held")
            }
        }
        XCTAssertEqual(host.newTabs, [], "a plain navigation asked for a new tab")
        XCTAssertNil(page.view.url, "the answers went to WebKit")
    }

    // MARK: Frames

    /// A frame's own navigation, on a page that hasn't been anywhere: no new
    /// tab where PadCore's rule keeps it in the frame (a frame's script
    /// moving it, ⌘ held or not), allowed, and the page's address and state
    /// as they were.
    func testASubframeNavigationLeavesTheMainFrameAlone() {
        let page = makePage()
        let host = NewTabHost()
        page.host = host
        let before = page.state
        let frameOwn: [(String, WebNavigationKind, WebModifiers)] = [
            ("link", .link, []), ("form", .form, []), ("script", .other, []), ("script, ⌘ held", .other, [.command]),
        ]
        for (name, kind, modifiers) in frameOwn {
            for url in [Self.web("frame"), Self.address("Frame")] {
                let navigation = Self.navigation(to: url, kind: kind, modifiers: modifiers, mainFrame: false)
                XCTAssertEqual(Self.newTabClick(navigation), .here, "PadCore's rule for a frame's \(name)")
                XCTAssertEqual(decide(page, navigation), .allow, "a frame's \(name) to \(url.scheme ?? "")")
            }
        }
        XCTAssertEqual(host.newTabs, [], "a frame's own navigation asked for a new tab")
        XCTAssertNil(page.displayURL, "a frame's navigation became the page's address")
        XCTAssertEqual(page.state, before)
        XCTAssertNil(page.committed)

        // The control: the same script in the main frame is the page's own.
        let main = Self.navigation(to: Self.web("main"), kind: .other)
        XCTAssertEqual(decide(page, main), .allow)
        XCTAssertEqual(page.displayURL, Self.web("main"), "the main frame's navigation didn't begin")
    }

    /// No target frame is the main frame, against a target frame that isn't:
    /// a script's navigation with ⌘ held is a new tab with none (refused
    /// one, the page's own), and stays in the frame with a subframe.
    func testNoTargetFrameIsTheMainFrame() {
        let url = Self.web("target")
        /// The same navigation to a fresh page whose host has no tabs, `frame` its target frame.
        func outcome(_ frame: Bool?) -> (decision: WebNavigationDecision?, newTabs: [NewTab], address: URL?) {
            let page = makePage()
            let host = NewTabHost()
            host.takesNewTabs = false
            page.host = host
            let navigation = Self.navigation(to: url, kind: .other, modifiers: [.command], mainFrame: frame)
            let rule = Self.newTabClick(navigation)
            XCTAssertEqual(rule, NewTabClick.choice(kind: .script, command: true, shift: false, middleButton: false,
                                                    method: "GET", scheme: "https", mainFrame: frame ?? true))
            let decision = decide(page, navigation)
            XCTAssertEqual(host.newTabs, rule == .here ? [] : [NewTab(url: url, inFront: rule == .inFront)])
            return (decision, host.newTabs, page.displayURL)
        }
        let subframe = outcome(false)
        let none = outcome(nil)
        XCTAssertEqual(subframe.decision, .allow)
        XCTAssertEqual(subframe.newTabs, [], "a frame's script asked for a new tab")
        XCTAssertNil(subframe.address, "a frame's navigation became the page's address")
        XCTAssertEqual(none.decision, .allow)
        XCTAssertEqual(none.newTabs, [NewTab(url: url, inFront: false)], "no target frame wasn't the main frame")
        XCTAssertEqual(none.address, url, "no target frame wasn't the page's own navigation")
    }

    // MARK: Downloads

    /// A link that asks to be saved is a download, answered before anything
    /// else is asked: no new tab with ⌘, ⌘⇧ or the middle button held, in
    /// any frame, and the page's address untouched.
    func testADownloadIsAnsweredFirst() {
        let page = makePage()
        let host = NewTabHost()
        page.host = host
        let clicks: [(String, WebModifiers, Int)] = [("click", [], 0)]
            + Self.newTabClicks.map { ($0.name, $0.modifiers, $0.button) }
        for (name, modifiers, button) in clicks {
            for url in [Self.web("download"), Self.address("Download")] {
                for frame in [true, false, nil] as [Bool?] {
                    let navigation = Self.navigation(to: url, modifiers: modifiers, button: button,
                                                     mainFrame: frame, download: true)
                    XCTAssertEqual(decide(page, navigation), .download, "a \(name) to save, " + Self.describe(navigation))
                }
            }
        }
        XCTAssertEqual(host.newTabs, [], "a download asked for a new tab")
        XCTAssertNil(page.displayURL, "a download began a navigation")
    }

    // MARK: WebKit's delegate

    /// The adapter is the view's navigation delegate and passes on what it
    /// doesn't decide: two pages loaded still reach the page's state, its
    /// back list, and its own notes of what was committed and of what kind.
    func testWhatTheAdapterDoesNotDecideReachesThePage() async {
        let page = makePage()
        XCTAssertTrue(page.view.navigationDelegate is WebKitNavigationAdapter, "the view's delegate isn't the adapter")
        XCTAssertFalse(page.view.navigationDelegate === page)

        await load(page, "One")
        let one = page.view.url
        XCTAssertNotNil(one)
        XCTAssertEqual(page.state.url, one)
        XCTAssertEqual(page.state.title, "One")
        XCTAssertEqual(page.committed, one, "the commit didn't reach the page")
        XCTAssertEqual(page.mimeType, "text/html", "the response's decision didn't reach the page")

        await load(page, "Two")
        let two = page.view.url
        XCTAssertNotEqual(two, one)
        XCTAssertEqual(page.state.url, two)
        XCTAssertEqual(page.state.title, "Two")
        XCTAssertTrue(page.state.canGoBack)
        XCTAssertFalse(page.state.canGoForward)
        XCTAssertEqual(page.view.backForwardList.backList.map(\.url), [one].compactMap { $0 })
        XCTAssertEqual(page.committed, two, "the second commit didn't reach the page")
        XCTAssertEqual(page.displayURL, two)
        XCTAssertNil(page.failure)
    }

    /// A real click on a link, by the page's own script: WebKit asks the
    /// adapter, the adapter the page, and the page begins the navigation
    /// itself and lets it go. The address it was holding without loading
    /// (hold), which only a navigation the page begins lets go of, is gone,
    /// and the new document commits.
    func testALinkClickedInThePageIsDecidedByThePage() async throws {
        let page = makePage()
        let host = NewTabHost()
        page.host = host
        page.load(Self.address("Links", body: "<a id=\"go\" href=\"about:blank\">Go</a>"))
        await waitForPage(page, titled: "Links")
        let links = page.view.url
        let held = Self.address("Held")
        page.hold(held)
        XCTAssertEqual(page.displayURL, held)

        _ = try await page.view.evaluateJavaScript("document.getElementById('go').click(); 1")
        await waitUntil(page, "about:blank committed") { $0.url?.absoluteString == "about:blank" && !$0.isLoading }
        XCTAssertNil(page.held, "the page's own navigation didn't begin")
        XCTAssertEqual(page.committed?.absoluteString, "about:blank", "the click's document didn't commit")
        XCTAssertEqual(page.displayURL?.absoluteString, "about:blank")
        XCTAssertEqual(page.view.backForwardList.backItem?.url, links)
        XCTAssertEqual(host.newTabs, [])
        XCTAssertNil(page.failure)
    }

    /// A real click on a link into a frame of the page: WebKit asks as the
    /// frame's, the page allows it, so the frame moves, and the page's own
    /// address, title and commit stay as they were.
    func testALinkIntoAFrameMovesOnlyTheFrame() async throws {
        let page = makePage()
        let host = NewTabHost()
        page.host = host
        let body = "<iframe name=\"inner\" src=\"about:blank\"></iframe>"
            + "<a id=\"go\" href=\"about:blank#moved\" target=\"inner\">Go</a>"
        page.load(Self.address("Framed", body: body))
        await waitForPage(page, titled: "Framed")
        let url = page.view.url, committed = page.committed

        _ = try await page.view.evaluateJavaScript("document.getElementById('go').click(); 1")
        let frame = "document.querySelector('iframe').contentWindow.location.href"
        var moved = false
        let deadline = Date().addingTimeInterval(10)
        while !moved, Date() < deadline {
            moved = try await page.view.evaluateJavaScript(frame) as? String == "about:blank#moved"
            if !moved { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(moved, "the frame didn't move: its navigation wasn't allowed")
        XCTAssertEqual(page.view.url, url)
        XCTAssertEqual(page.state.title, "Framed")
        XCTAssertEqual(page.committed, committed, "a frame's navigation was taken for the page's commit")
        XCTAssertEqual(page.displayURL, url)
        XCTAssertEqual(host.newTabs, [])
    }

    // MARK: Helpers

    /// The four clicks that ask for a new tab, and what PadCore's rule says of each.
    private static let newTabClicks: [(name: String, slug: String, modifiers: WebModifiers, button: Int,
                                       rule: NewTabClick.Choice)] = [
        ("⌘-click", "command", [.command], 0, .behind),
        ("⌘⇧-click", "command-shift", [.command, .shift], 0, .inFront),
        ("middle click", "middle", [], 2, .behind),
        ("⇧-middle click", "shift-middle", [.shift], 2, .inFront),
    ]

    /// A website's address, decided on and never loaded.
    private static func web(_ path: String) -> URL {
        URL(string: "https://eglu-tests.invalid/" + path)!
    }

    /// A navigation as WebKit's adapter gives one: by default a click on a
    /// link, no keys held, with the main button, in the main frame.
    private static func navigation(to url: URL, kind: WebNavigationKind = .link, modifiers: WebModifiers = [],
                                   button: Int = 0, mainFrame: Bool? = true, method: String = "GET",
                                   download: Bool = false) -> WebNavigation {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return WebNavigation(request: request, sourceOrigin: .opaque, targetIsMainFrame: mainFrame, kind: kind,
                             modifiers: modifiers, buttonNumber: button, requestsDownload: download,
                             isServerRedirect: false, contentRuleRedirect: nil)
    }

    /// What PadCore's rule says of `navigation`, its kind in the rule's
    /// words: a script's is `.script`; a step back or forward, a reload, a
    /// form sent again and a kind WebKit adds later are `.history`.
    private static func newTabClick(_ navigation: WebNavigation) -> NewTabClick.Choice {
        let kind: NewTabClick.Kind
        switch navigation.kind {
        case .link: kind = .link
        case .form: kind = .form
        case .other: kind = .script
        case .history, .reload, .formResubmission, .unknown: kind = .history
        }
        return NewTabClick.choice(kind: kind, command: navigation.modifiers.contains(.command),
                                  shift: navigation.modifiers.contains(.shift), middleButton: navigation.buttonNumber == 2,
                                  method: navigation.request.httpMethod, scheme: navigation.request.url?.scheme,
                                  mainFrame: navigation.targetIsMainFrame ?? true)
    }

    /// The page's one answer to `navigation`. A second answer, or none by the
    /// time the call returns, fails the test; the reply isn't escaping, so
    /// none can come later.
    private func decide(_ page: Page, _ navigation: WebNavigation,
                        file: StaticString = #filePath, line: UInt = #line) -> WebNavigationDecision? {
        var answers: [WebNavigationDecision] = []
        page.decideNavigation(navigation) { answers.append($0) }
        XCTAssertEqual(answers.count, 1, "answers to " + Self.describe(navigation), file: file, line: line)
        return answers.first
    }

    /// A navigation in words, for a failure's message.
    private static func describe(_ navigation: WebNavigation) -> String {
        var keys = ""
        if navigation.modifiers.contains(.command) { keys += "⌘" }
        if navigation.modifiers.contains(.shift) { keys += "⇧" }
        let frame = navigation.targetIsMainFrame.map { $0 ? "main frame" : "subframe" } ?? "no target frame"
        return "\(navigation.kind), \(keys.isEmpty ? "no keys" : keys), button \(navigation.buttonNumber), "
            + "\(navigation.request.httpMethod ?? "GET") \(navigation.request.url?.scheme ?? "no address"), \(frame)"
    }
}

/// A new tab a host was asked for.
private struct NewTab: Equatable {
    let url: URL
    let inFront: Bool
}

/// A host that keeps the new tabs it is asked for and takes them or not, as
/// the test says; for everything else, the least a host does.
@MainActor
private final class NewTabHost: PageHost {
    var takesNewTabs = true
    var newTabs: [NewTab] = []

    func page(_ page: Page, handOffFileAt url: URL) {}
    var takesHandoffFiles: Bool { false }
    func pageDidChange(_ page: Page) {}
    func isShowing(_ page: Page) -> Bool { false }
    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView? { nil }
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool {
        newTabs.append(NewTab(url: url, inFront: inFront))
        return takesNewTabs
    }
    func pageDidClose(_ page: Page) {}
    var hostWindow: NSWindow? { nil }
}
