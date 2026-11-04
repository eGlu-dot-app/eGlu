import AppKit
import PadCore
import WebEngineCore
import WebKit
import WebKitMacPlugin
import WebKitSupport
import XCTest
@testable import eGluMac

/// What a Mac page's engine does out of sight (Docs/EngineSplitPlan.md, 7,
/// step 9), through a real `Page` and real WebKit: the SVG rasterizer the
/// engine gives SiteIcons (`WebKitSVGRaster.shared`) and the picture it
/// draws; a page's download session (`Page.downloadStarter`, the page's own
/// services), which holds the page's view weakly unless it is kept for one
/// call (`keepingSessionAlive()`); a Handoff link whose page has gone
/// (`DocumentSource(link:downloads:)`); a retry's session in its space's
/// store (`Downloads.retryStarter(space:)`); and the hidden page the
/// transcript reader loads beside a page (`Page.hiddenPage(allowing:)`).
///
/// Every page is a data: page, and every store but the retry's keeps
/// nothing: no network. The one download started, through the retry's
/// session, is a data: address answered nowhere: its wrapper
/// (`WebKitDownload`) is WebKit's download's delegate from the moment WebKit
/// hands it over, and says nowhere while it has no delegate of its own; the
/// test's delegate then says nowhere too. So no download writes a file, and
/// Downloads is not asked. A page let go of is made by the test itself and
/// torn down, and the test waits until its view has gone before it looks.
///
/// The hidden page's limit is shown with a limit of zero: no data: address
/// was found that never commits within a time, without a network or a
/// scheme handler, which the hidden page's own configuration has none of.
/// That the false came from the limit is shown by the page committing after.
///
/// Not here: the content blocker's lists in a hidden page. The test host's
/// blocker has none (its services do not start), and WebKit has no way to
/// read a controller's rule lists, so only what the hidden page is given
/// when its page does not block is looked at: a controller of its own, with
/// none of the page's scripts. A transcript itself (Unseen) needs a site of
/// the network. The recording pill (`RecordingIndicator.shared.host` and
/// `update`) is not called: it puts a panel on screen.
@MainActor
final class PageHiddenTests: PageTestCase {
    // MARK: Drawing an icon

    /// The engine's rasterizer is WebKit's one, and SiteIcons has that same
    /// object; it draws a small filled square as PNG bytes that NSImage
    /// reads, at the size asked, filled in the middle.
    func testTheEnginesRasterizerIsSiteIconsAndDrawsAPicture() async throws {
        XCTAssertTrue(Session.shared.engine.svgRasterizer === WebKitSVGRaster.shared,
                      "the engine's rasterizer isn't WebKit's shared one")
        let icons = try kept("rasterizer", of: SiteIcons.shared, as: AnyObject.self)
        XCTAssertTrue(icons === WebKitSVGRaster.shared, "SiteIcons has another rasterizer than the engine's")

        let square = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8" fill="#0a64ff"/></svg>
            """
        let drawn = await WebKitSVGRaster.shared.png(of: square, side: 40, dark: false)
        let png = try XCTUnwrap(drawn, "the square wasn't drawn")
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "not PNG bytes")
        XCTAssertNotNil(NSImage(data: png), "NSImage can't read the picture")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 40)
        XCTAssertEqual(bitmap.pixelsHigh, 40)
        let middle = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(middle.alphaComponent, 0.9, "the square's middle isn't filled")
        XCTAssertGreaterThan(middle.blueComponent, middle.redComponent, "the square's middle isn't its blue")
    }

    // MARK: A page's download session

    /// A page's download session is its own services object, which can
    /// start downloads while the page is there; kept for one call, it is a
    /// starter holding the page's view itself, kept already.
    func testAPagesDownloadSessionIsItsOwnServices() throws {
        let page = makePage()
        let services = try kept("services", of: page, as: WebKitPageServices.self)
        XCTAssertTrue(page.downloadStarter === services, "the page's download session isn't its services")
        XCTAssertTrue(page.downloadStarter.canStartDownloads)

        let session = page.downloadStarter.keepingSessionAlive()
        let starter = try XCTUnwrap(session as? WebKitDownloadStarter, "a kept session is a \(type(of: session))")
        XCTAssertTrue(try kept("held", of: starter, as: WKWebView.self) === page.view,
                      "the kept session doesn't hold the page's view")
        XCTAssertTrue(session.canStartDownloads)
        XCTAssertTrue(session.keepingSessionAlive() === session, "a kept session, kept again, made another")
    }

    /// A page torn down and let go: a session kept for one call before it
    /// went can still start downloads, its view with it, and so can the
    /// page's own while that holds it; a page's session not kept cannot,
    /// once the page's view has gone. Let go of too, the kept one's view
    /// goes, and its page's own session cannot either.
    func testAKeptSessionOutlivesItsPageAndOneNotKeptDoesNot() async throws {
        var plain: (any WebDownloadStarting)?
        let plainView = pageLetGo { plain = $0.downloadStarter }
        var own: (any WebDownloadStarting)?
        var kept: (any WebDownloadStarting)?
        let keptView = pageLetGo {
            own = $0.downloadStarter
            kept = $0.downloadStarter.keepingSessionAlive()
        }

        try await requireGone(plainView)
        XCTAssertEqual(plain?.canStartDownloads, false, "the session of a page that has gone can start downloads")
        XCTAssertNotNil(keptView.object, "the kept session let its page's view go")
        XCTAssertEqual(kept?.canStartDownloads, true, "the kept session can't start downloads once its page went")
        XCTAssertEqual(own?.canStartDownloads, true, "the page's own session lost the view the kept one holds")

        kept = nil
        try await requireGone(keptView)
        XCTAssertEqual(own?.canStartDownloads, false, "the session of a page that has gone can start downloads")
    }

    /// A link handed off from a page that has gone, read: the tab it was on
    /// is gone, and nothing is fetched (the job's folder is never made).
    func testALinkFromAPageThatHasGoneIsNotFetched() async throws {
        try requireOwnDataFolder()
        let link = try XCTUnwrap(URL(string: "https://eglu-tests.invalid/report.pdf"))
        var source: DocumentSource?
        let gone = pageLetGo { source = DocumentSource(link: link, downloads: $0.downloadStarter) }
        try await requireGone(gone)

        let folder = Session.folder.appendingPathComponent("eglu-tests-handoff-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let reading = try XCTUnwrap(source)
        let outcome = await reading.reading(limit: 10_000, into: folder, telling: nil)
        guard case .failed(let message) = outcome else {
            return XCTFail("a link from a page that has gone was read: \(outcome)")
        }
        XCTAssertEqual(message, String(localized: "The tab it was on is gone."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "something was fetched into the job's folder")
    }

    // MARK: A retry's session

    /// A retry's session for a space of the test run's workspace is a
    /// starter holding a hidden view of its own in the space's one store,
    /// which can start downloads: one at a data: address, answered nowhere,
    /// is asked where to save and stops, and Downloads gets no item for it.
    func testARetrysSessionIsInItsSpacesStore() async throws {
        XCTAssertTrue(Session.shared.canUseWorkspace, "the test run's workspace can't be used")
        let space = try XCTUnwrap(Session.shared.workspace.spaces.first?.id)
        let session = Downloads.retryStarter(space: space)
        let starter = try XCTUnwrap(session as? WebKitDownloadStarter, "a retry's session is a \(type(of: session))")
        let view = try kept("held", of: starter, as: WKWebView.self)
        XCTAssertTrue(view.configuration.websiteDataStore === WebKitStores.store(for: space),
                      "the retry's view isn't in its space's store")
        XCTAssertNil(view.superview)
        XCTAssertTrue(session.canStartDownloads)
        XCTAssertTrue(session.keepingSessionAlive() === session, "a retry's session, kept, made another")

        let other = try XCTUnwrap(Downloads.retryStarter(space: space) as? WebKitDownloadStarter)
        let otherView = try kept("held", of: other, as: WKWebView.self)
        XCTAssertFalse(otherView === view, "two retries share a view")
        XCTAssertTrue(otherView.configuration.websiteDataStore === view.configuration.websiteDataStore,
                      "two retries in a space are in two stores")

        let before = Downloads.shared.items.map(\.id)
        let nowhere = NowhereToSave()
        let handed = Handed()
        let address = try XCTUnwrap(URL(string: "data:application/octet-stream;base64,ZWdsdS10ZXN0cw=="))
        session.startDownload(using: URLRequest(url: address)) { download in
            // The wrapper already answers nowhere; the test's delegate counts what WebKit asks.
            download.delegate = nowhere
            handed.download = download
        }
        await waitFor("the retry's download asked where to save, and stopped") {
            nowhere.asked > 0 && nowhere.failed > 0
        }
        let download = try XCTUnwrap(handed.download as? WebKitDownload, "the retry's download isn't wrapped")
        XCTAssertEqual(download.originalURL, address)
        XCTAssertEqual(nowhere.asked, 1)
        XCTAssertEqual(nowhere.finished, 0, "the retry's download finished")
        XCTAssertEqual(Downloads.shared.items.map(\.id), before, "Downloads got an item for the retry's download")
    }

    // MARK: The hidden page

    /// A page's hidden page, its view in a plain view with no window: a
    /// web view of its own in the same superview, directly below the page's
    /// view, at its frame, transparent, out of accessibility, in the page's
    /// store, with its application name, and a controller of its own with
    /// none of the page's scripts (the page doesn't block, and the test
    /// host's blocker has no lists). An address its rule allows begins;
    /// the call it makes in the app's own world sees its arguments, not what
    /// the page's own script set, and what it sets isn't the page world's.
    /// Stopped, it is out of the superview, which is as it was.
    func testTheHiddenPageIsBelowThePageAndCallsInTheAppsWorld() async throws {
        let (page, parent, under, over) = pageInAPlainView()
        XCTAssertNil(parent.window)
        let rule = Rule(allowing: Self.allowed)
        let hidden = try XCTUnwrap(page.hiddenPage(allowing: rule.allows) as? WebKitHiddenPage)
        defer { hidden.stop() }
        let made = try kept("view", of: hidden, as: WKWebView.self)

        XCTAssertFalse(made === page.view)
        XCTAssertTrue(made.superview === parent, "the hidden page isn't in the page's superview")
        XCTAssertEqual(parent.subviews.count, 4)
        let hiddenIndex = try XCTUnwrap(parent.subviews.firstIndex { $0 === made })
        let pageIndex = try XCTUnwrap(parent.subviews.firstIndex { $0 === page.view })
        XCTAssertEqual(hiddenIndex, pageIndex - 1, "the hidden page isn't directly below the page")
        XCTAssertTrue(parent.subviews.first === under && parent.subviews.last === over)
        XCTAssertEqual(made.frame, page.view.frame)
        XCTAssertEqual(made.alphaValue, 0)
        XCTAssertFalse(made.isAccessibilityElement(), "the hidden page is an accessibility element")
        XCTAssertTrue(made.navigationDelegate === hidden)
        XCTAssertTrue(made.configuration.websiteDataStore === page.view.configuration.websiteDataStore,
                      "the hidden page isn't in the page's store")
        let name = try XCTUnwrap(page.view.configuration.applicationNameForUserAgent)
        XCTAssertFalse(name.isEmpty)
        XCTAssertEqual(made.configuration.applicationNameForUserAgent, name)
        XCTAssertFalse(page.blocksContent, "the page blocks content, which this test can't look at")
        XCTAssertTrue(ContentBlocker.shared.lists.isEmpty, "the test host's content blocker has lists")
        XCTAssertFalse(made.configuration.userContentController === page.view.configuration.userContentController,
                       "the hidden page has the page's own controller")
        XCTAssertTrue(made.configuration.userContentController.userScripts.isEmpty, "the hidden page has scripts")

        let began = await hidden.begin(Self.allowed, within: .seconds(10))
        XCTAssertTrue(began, "an address the rule allows didn't begin")
        XCTAssertEqual(rule.asked, [Rule.said(Self.allowed)])
        await waitFor("the hidden page loaded") { made.title == "Hidden" && !made.isLoading }
        let pageSet = try await made.callAsyncJavaScript("return typeof globalThis.fromPage", arguments: [:],
                                                         in: nil, contentWorld: .page)
        XCTAssertEqual(pageSet as? String, "string", "the page's own script didn't run")

        let said = try await hidden.callInAppWorld(
            "globalThis.fromApp = value; return [typeof globalThis.fromPage, value + suffix];",
            arguments: ["value": "argument", "suffix": " seen"])
        XCTAssertEqual(said as? [String], ["undefined", "argument seen"],
                       "the call saw the page's world, or not its arguments")
        let inPageWorld = try await made.callAsyncJavaScript("return typeof globalThis.fromApp", arguments: [:],
                                                             in: nil, contentWorld: .page)
        XCTAssertEqual(inPageWorld as? String, "undefined", "what the call set is the page world's")
        let inAppWorld = try await made.callAsyncJavaScript("return typeof globalThis.fromApp", arguments: [:],
                                                            in: nil, contentWorld: Page.world)
        XCTAssertEqual(inAppWorld as? String, "string", "the call wasn't in the app's own world")

        hidden.stop()
        XCTAssertNil(made.superview, "the stopped hidden page is still in the superview")
        XCTAssertNil(made.navigationDelegate)
        XCTAssertEqual(parent.subviews.count, 3)
        XCTAssertTrue(parent.subviews[0] === under && parent.subviews[1] === page.view && parent.subviews[2] === over)
    }

    /// An address the hidden page's rule refuses doesn't begin: the rule is
    /// asked for it, and the hidden page never shows it.
    func testAnAddressTheRuleRefusesDoesNotBegin() async throws {
        let (page, parent, _, _) = pageInAPlainView()
        let rule = Rule(allowing: Self.allowed)
        let hidden = try XCTUnwrap(page.hiddenPage(allowing: rule.allows) as? WebKitHiddenPage)
        defer { hidden.stop() }
        let made = try kept("view", of: hidden, as: WKWebView.self)
        XCTAssertTrue(made.superview === parent)

        let began = await hidden.begin(Self.refused, within: .seconds(10))
        XCTAssertFalse(began, "an address the rule refuses began")
        XCTAssertEqual(rule.asked, [Rule.said(Self.refused)])
        XCTAssertNotEqual(made.url, Self.refused, "the hidden page shows the refused address")
        XCTAssertNotEqual(made.title, "Refused")
    }

    /// A limit that passes before the page has begun answers false, though
    /// the rule allows the address and the page then comes: the false was
    /// the limit's, not a refusal's or a failure's.
    func testALimitThatPassesFirstAnswersFalse() async throws {
        let (page, _, _, _) = pageInAPlainView()
        let late = Self.address("Late")
        let rule = Rule(allowing: late)
        let hidden = try XCTUnwrap(page.hiddenPage(allowing: rule.allows) as? WebKitHiddenPage)
        defer { hidden.stop() }
        let made = try kept("view", of: hidden, as: WKWebView.self)

        let began = await hidden.begin(late, within: .zero)
        XCTAssertFalse(began, "a load given no time began")
        await waitFor("the page given no time came after all") { made.title == "Late" && !made.isLoading }
        XCTAssertEqual(rule.asked, [Rule.said(late)])
    }

    // MARK: Helpers

    /// A hidden page's address its rule allows: a page whose own script sets a value.
    private static let allowed: URL = {
        let html = "<!doctype html><title>Hidden</title><script>globalThis.fromPage = 'page';</script><p>Hidden</p>"
        return URL(string: "data:text/html;charset=utf-8,"
                   + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }()

    /// One the rule refuses.
    private static let refused = address("Refused")

    /// A page of the test's, its view in a plain view with no window,
    /// between two others, at a frame of its own; its configuration has the
    /// application name the app's engine gives a page.
    private func pageInAPlainView() -> (page: Page, parent: NSView, under: NSView, over: NSView) {
        let configuration = Self.keepingNothing()
        configuration.applicationNameForUserAgent = Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion)
        let page = makePage(configuration: configuration)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let under = NSView(frame: parent.bounds)
        let over = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        page.view.frame = NSRect(x: 4, y: 6, width: 300, height: 200)
        parent.addSubview(under)
        parent.addSubview(page.view)
        parent.addSubview(over)
        addTeardownBlock { @MainActor in withExtendedLifetime(parent) {} }
        return (page, parent, under, over)
    }

    /// A page made here and let go of, as a closed tab's is: `take` sees it,
    /// then it is torn down and nothing of the test's holds it. Its view is
    /// held weakly, to see it go.
    private func pageLetGo(_ take: (Page) -> Void) -> Weakly<PageView> {
        autoreleasepool { () -> Weakly<PageView> in
            let page = Page(tab: UUID(), space: UUID(), enginePage: AppWebKitEngine.page(configuration: Self.keepingNothing()))
            take(page)
            let view = Weakly(page.view)
            page.tearDown()
            return view
        }
    }

    /// Waits up to 10 s for a page's view to go; skips the test where the
    /// test host still holds it, as there is then no page that has gone to look at.
    private func requireGone(_ view: Weakly<PageView>, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while view.object != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if view.object != nil {
            throw XCTSkip("a torn-down page's view is still held after 10 s in the test host", file: file, line: line)
        }
    }

    /// Downloads saves into the test run's data folder only where one is
    /// set (EGLU_DATA_ROOT, a full path); nothing is read into a folder without it.
    private func requireOwnDataFolder(file: StaticString = #filePath, line: UInt = #line) throws {
        let set = [ProcessInfo.processInfo.environment["EGLU_DATA_ROOT"],
                   Bundle.main.object(forInfoDictionaryKey: "EGLU_DATA_ROOT") as? String]
            .compactMap { $0 }.contains { $0.hasPrefix("/") }
        let root = try XCTUnwrap(set ? Session.dataRootOverride : nil,
                                 "no data folder of the test run's own", file: file, line: line)
        XCTAssertEqual(Session.folder.standardizedFileURL, root.standardizedFileURL, file: file, line: line)
    }

    /// A value `subject` keeps to itself, read by its name.
    private func kept<T>(_ name: String, of subject: Any, as type: T.Type = T.self,
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let child = try XCTUnwrap(Mirror(reflecting: subject).children.first { $0.label == name },
                                  "\(Swift.type(of: subject)) keeps no \(name)", file: file, line: line)
        return try XCTUnwrap(child.value as? T, "\(name) is a \(Swift.type(of: child.value))", file: file, line: line)
    }

    /// Waits, up to `timeout`, for `condition`, looked at every 20 ms.
    private func waitFor(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath,
                         line: UInt = #line, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "\(what): not by \(timeout) s", file: file, line: line)
    }
}

/// An object held weakly, to see when it goes.
@MainActor
private final class Weakly<Object: AnyObject> {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// A hidden page's rule: one address allowed, every other refused, and
/// each address it was asked about kept. Addresses are told apart by what
/// they say, decoded, so WebKit's own spelling of one is the same address.
@MainActor
private final class Rule {
    private let allowed: String?
    private(set) var asked: [String?] = []

    init(allowing allowed: URL) {
        self.allowed = Self.said(allowed)
    }

    var allows: @MainActor (URL?) -> Bool {
        { [self] url in
            asked.append(Self.said(url))
            return Self.said(url) == allowed
        }
    }

    /// What an address says, decoded.
    nonisolated static func said(_ url: URL?) -> String? {
        url.map { $0.absoluteString.removingPercentEncoding ?? $0.absoluteString }
    }
}

/// The download a session's start gave.
@MainActor
private final class Handed {
    var download: (any WebEngineCore.WebDownload)?
}

/// A download's delegate that saves nothing, set on its wrapper: asked
/// where to save, it says nowhere, which stops the download. It counts what
/// WebKit told it through the wrapper.
@MainActor
private final class NowhereToSave: WebEngineCore.WebDownloadDelegate {
    private(set) var asked = 0
    private(set) var failed = 0
    private(set) var finished = 0

    func download(_ download: any WebEngineCore.WebDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        asked += 1
        completionHandler(nil)
    }

    func download(_ download: any WebEngineCore.WebDownload, didFailWithError error: any Error, resumeData: Data?) {
        failed += 1
    }

    func downloadDidFinish(_ download: any WebEngineCore.WebDownload) {
        finished += 1
    }
}
