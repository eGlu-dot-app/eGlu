import AppKit
import PadCore
import WebEngineCore
import WebKit
import WebKitMacPlugin
import XCTest
@testable import eGluMac

/// A file opened in a page and a download a navigation became
/// (Docs/EngineSplitPlan.md, 7, step 4d): a file loads through the adapter
/// (`WebRequestLoading.loadFile`) with read access to itself, which reaches
/// no further than its own folder; WebKit's two "became a download"
/// callbacks are the adapter's, which hands the
/// download to the page (`navigationBecameDownload`); the page gives it to
/// Downloads and closes a tab that was only the file's way in; and the
/// adapter is the view's whole navigation delegate, passing nothing on.
///
/// No download here saves anything. One handed over by hand is WebKit's own,
/// started at an address of the test's scheme, whose handler never answers,
/// so there is never an answer to save. The one through WebKit is a data:
/// address, whose answer comes at once: the moment the page has handed it to
/// Downloads, it gets a delegate of the test's, which tells WebKit to save it
/// nowhere, and WebKit stops it. Each is then cancelled through Downloads and
/// its activity cleared, in the test run's own data folder. The test's files
/// are written in a folder of its own in the temporary folder, removed after.
///
/// Not here: a download that saves a file (where Downloads puts it, its
/// progress, its finish); a link that asks to be saved, clicked through
/// WebKit (`navigationAction:didBecome:`): a link of the test's scheme is an
/// app's link to the page (AppLink), a website's needs a server, and a data:
/// or blob: one has an answer to save, with no moment, on a page that is
/// shown, to give the download the test's delegate first; a file opened from
/// Finder, read again through its bookmark (FileAccess); and a file beside
/// the one opened: WebKit lets a file's script read its own folder, and the
/// folders in it, with read access to the file alone, by its own call too.
@MainActor
final class PageDownloadAndFileTests: PageTestCase {
    // MARK: A file

    /// A file opened in a page (Page.load): it loads through the adapter, so
    /// the committed address and the view's are the file's, and its title
    /// and text are there for script to read. Its script can't read a file
    /// in the folder above its own: the read access given is the file's
    /// (which WebKit lets reach the file's own folder, no further). The same
    /// file opened with read access to that folder above (WebKit's own call)
    /// can read it, so the refusal is the read access's.
    func testAFileOpensWithReadAccessNoWiderThanItself() async throws {
        let folder = try temporaryFolder()
        let own = folder.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: false)
        let file = own.appendingPathComponent("page.html")
        try Self.filePage.write(to: file, atomically: true, encoding: .utf8)
        try "window.aboveRead = 'read';".write(to: folder.appendingPathComponent("above.js"),
                                               atomically: true, encoding: .utf8)

        let page = makePage()
        page.load(file)
        await waitForPage(page, titled: "File")
        XCTAssertEqual(page.view.url?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        XCTAssertEqual(page.committed?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath(),
                       "the file's commit didn't reach the page")
        XCTAssertNil(page.failure)
        let text = try await page.view.evaluateJavaScript("document.querySelector('p').textContent") as? String
        XCTAssertEqual(text, "Opened from a file")
        let read = await aboveRead(page)
        XCTAssertEqual(read, "refused", "the file's script read a file outside its own folder")

        let wider = makePage()
        wider.view.loadFileURL(file, allowingReadAccessTo: folder)
        await waitForPage(wider, titled: "File")
        let readWider = await aboveRead(wider)
        XCTAssertEqual(readWider, "read", "the file above isn't read even with read access to its folder")
    }

    // MARK: A download handed over by hand

    /// A download a navigation became, handed to the page as the adapter
    /// hands it, a real one of WebKit's whose answer never comes: Downloads
    /// takes it over, as its delegate, with an item at its address, named
    /// after it, in the page's space, as a GET, being downloaded, and the
    /// page's. Cancelled through Downloads, it stops, the page has nothing
    /// downloading, and clearing finished activity takes the item away.
    func testADownloadIsTakenOverByDownloads() async throws {
        try requireOwnDataFolder()
        let page = makeNeverAnsweringPage()
        let saves = SavesNothing()

        let handed = try await handOver("report.bin", to: page, delegate: saves)
        XCTAssertTrue(handed.delegate === Downloads.shared, "Downloads isn't the download's delegate")
        XCTAssertEqual(handed.item.source, NeverAnswers.address("report.bin"))
        XCTAssertEqual(handed.item.name, "report.bin")
        XCTAssertEqual(handed.item.space, page.space)
        XCTAssertEqual(handed.item.method, "GET")
        XCTAssertEqual(handed.item.phase, .downloading)
        XCTAssertNil(handed.item.file)
        XCTAssertTrue(Downloads.shared.isDownloading(for: page), "Downloads doesn't have it as the page's")
        XCTAssertTrue(Self.running(for: page).contains { $0 === handed.download })

        await stop(handed.item, of: page)
        XCTAssertEqual(saves.asked, 0, "WebKit asked where to save a download whose answer never comes")
        assertNothingSaved()
    }

    /// Who closes for a download: a page with nothing committed and no page
    /// to go back to was only the file's way in, so its host is told it
    /// closed when the download is handed over. A page that has committed a
    /// page isn't closed, nor one with nothing committed (a commit with no
    /// address, said by hand) but a page to go back to.
    func testOnlyAPageThatShowedNothingClosesForItsDownload() async throws {
        try requireOwnDataFolder()
        let saves = SavesNothing()

        let fresh = makeNeverAnsweringPage()
        let freshHost = DownloadHost()
        fresh.host = freshHost
        XCTAssertNil(fresh.committed)
        XCTAssertFalse(fresh.view.canGoBack)
        let first = try await handOver("first.bin", to: fresh, delegate: saves)
        XCTAssertEqual(freshHost.closed, [ObjectIdentifier(fresh)], "a page that showed nothing wasn't closed")
        await stop(first.item, of: fresh)

        let shown = makeNeverAnsweringPage()
        let shownHost = DownloadHost()
        shown.host = shownHost
        await load(shown, "Shown")
        XCTAssertNotNil(shown.committed)
        XCTAssertFalse(shown.view.canGoBack)
        let second = try await handOver("second.bin", to: shown, delegate: saves)
        XCTAssertEqual(shownHost.closed, [], "a page that shows a page was closed")
        XCTAssertEqual(shown.state.title, "Shown")
        await stop(second.item, of: shown)

        let back = makeNeverAnsweringPage()
        let backHost = DownloadHost()
        back.host = backHost
        await load(back, "One")
        await load(back, "Two")
        back.navigationCommitted(url: nil)
        XCTAssertNil(back.committed)
        XCTAssertTrue(back.view.canGoBack)
        let third = try await handOver("third.bin", to: back, delegate: saves)
        XCTAssertEqual(backHost.closed, [], "a page with a page to go back to was closed")
        await stop(third.item, of: back)

        XCTAssertEqual(saves.asked, 0)
        assertNothingSaved()
    }

    // MARK: A download through WebKit

    /// A data: address WebKit can't show (bytes to save) opened in a new
    /// page: the page decides its answer is a download, WebKit tells the
    /// adapter it became one, the adapter the page, and the page gives it to
    /// Downloads (an item at its address, in its space) and, having shown
    /// nothing, tells its host it closed. Nothing is committed and no
    /// failure shown. When the host is told, the download gets the test's
    /// delegate, which WebKit then asks where to save it: nowhere, so
    /// nothing is saved.
    func testAnAnswerToSaveBecomesTheTabsDownload() async throws {
        try requireOwnDataFolder()
        // First, that a download the page handed over is found in Downloads'
        // own list in time, as the one through WebKit must be.
        let scratch = makeNeverAnsweringPage()
        let checking = SavesNothing()
        let check = try await handOver("check.bin", to: scratch, delegate: checking)
        let found = Self.running(for: scratch).contains { $0 === check.download }
        await stop(check.item, of: scratch)
        guard found else {
            return XCTFail("Downloads' own list can't be read, so no download whose answer comes is started")
        }

        let page = makePage()
        let saves = SavesNothing()
        let host = DownloadHost()
        var given: [Int] = []
        host.whenClosed = { closing in
            let downloads = Self.running(for: closing)
            downloads.forEach { $0.delegate = saves }
            given.append(downloads.count)
            // Not found after all: stopped at once, before WebKit can ask Downloads where to save it.
            if downloads.isEmpty, let newest = Downloads.shared.items.first { Downloads.shared.cancel(newest) }
        }
        page.host = host
        let before = Set(Downloads.shared.items.map(\.id))
        let address = try XCTUnwrap(URL(string: "data:application/octet-stream;base64,ZWdsdS10ZXN0cw=="))

        page.load(address)
        await waitFor("the download handed over") { !host.closed.isEmpty }
        XCTAssertEqual(host.closed, [ObjectIdentifier(page)])
        XCTAssertEqual(given, [1], "the download didn't get the test's delegate when the host was told")
        let item = try XCTUnwrap(Downloads.shared.items.first { !before.contains($0.id) }, "Downloads has no item for it")
        XCTAssertEqual(item.source, address)
        XCTAssertEqual(item.space, page.space)
        XCTAssertEqual(item.method, "GET")
        XCTAssertNil(page.committed, "the download committed a page")
        XCTAssertNil(page.failure, "a download showed a failure")

        await waitFor("WebKit asked the test's delegate where to save it") { saves.asked > 0 }
        XCTAssertEqual(saves.finished, 0, "the download finished")
        let kept = Downloads.shared.items.first { $0.id == item.id }
        XCTAssertNotNil(kept)
        XCTAssertNil(kept?.file, "Downloads chose a file to save it in")
        await stop(item, of: page)
        assertNothingSaved()
    }

    // MARK: WebKit's delegate

    /// The adapter is the view's whole navigation delegate, and passes
    /// nothing on: the page isn't one and answers none of its callbacks;
    /// the adapter answers those it has, the downloads' among them, and none
    /// it hasn't (a sign-in challenge, the decision's `preferences:` form);
    /// and it neither answers nor forwards the UI delegate's questions,
    /// WebKit's private ones among them, which the adapter that forwarded to
    /// the page (step 4c) answered. Since step 7b the UI delegate is the
    /// plugin's `WebKitUIAdapter`, which answers them (PageUIDelegateTests).
    func testTheAdapterIsTheWholeNavigationDelegate() throws {
        let page = makePage()
        let adapter = try XCTUnwrap(page.view.navigationDelegate as? WebKitNavigationAdapter,
                                    "the view's navigation delegate isn't the adapter")
        XCTAssertFalse((page as AnyObject) is WKNavigationDelegate, "the page is still a navigation delegate")
        let ui = try XCTUnwrap(page.view.uiDelegate as? WebKitUIAdapter, "the view's UI delegate isn't the UI adapter")

        let adapters = ["webView:decidePolicyForNavigationAction:decisionHandler:",
                        "webView:decidePolicyForNavigationResponse:decisionHandler:",
                        "webView:didStartProvisionalNavigation:", "webView:didCommitNavigation:",
                        "webView:didFinishNavigation:", "webView:didFailProvisionalNavigation:withError:",
                        "webViewWebContentProcessDidTerminate:",
                        "webView:navigationAction:didBecomeDownload:",
                        "webView:navigationResponse:didBecomeDownload:"].map(NSSelectorFromString)
        for selector in adapters {
            XCTAssertTrue(adapter.responds(to: selector), "the adapter doesn't answer \(selector)")
            XCTAssertFalse(page.responds(to: selector), "the page still answers \(selector)")
        }

        let nobodys = ["webView:didReceiveAuthenticationChallenge:completionHandler:",
                       "webView:authenticationChallenge:shouldAllowDeprecatedTLS:",
                       "webView:decidePolicyForNavigationAction:preferences:decisionHandler:"].map(NSSelectorFromString)
        let uis = ["webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
                   "webViewDidClose:",
                   "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
                   "_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:",
                   "_webView:didNotHandleWheelEvent:"].map(NSSelectorFromString)
        for selector in uis {
            XCTAssertTrue(ui.responds(to: selector), "the UI adapter doesn't answer \(selector), so it proves nothing")
        }
        for selector in nobodys + uis {
            XCTAssertFalse(adapter.responds(to: selector), "the adapter answers \(selector)")
            XCTAssertNil(adapter.forwardingTarget(for: selector), "the adapter forwards \(selector)")
        }
    }

    // MARK: Helpers

    /// A page whose script reads a file in the folder above its own, saying
    /// "refused" where it can't.
    private static let filePage = """
        <!doctype html><title>File</title><p>Opened from a file</p>
        <script src="../above.js" onerror="window.aboveRead = 'refused'"></script>
        """

    /// A folder of the test's own in the temporary folder, removed after the test.
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eglu-tests-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// What the file's script found of the file above: "read" or
    /// "refused"; nil where it says nothing by 10 s.
    private func aboveRead(_ page: Page) async -> String? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let value = try? await page.view.evaluateJavaScript(
                "typeof window.aboveRead === 'string' ? window.aboveRead : ''") as? String
            if let value, !value.isEmpty { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Downloads saves into the test run's data folder only where one is set
    /// as it looks for one (EGLU_DATA_ROOT, a full path); without it, into
    /// the person's Downloads folder. No download is started without it.
    private func requireOwnDataFolder(file: StaticString = #filePath, line: UInt = #line) throws {
        let set = [ProcessInfo.processInfo.environment["EGLU_DATA_ROOT"],
                   Bundle.main.object(forInfoDictionaryKey: "EGLU_DATA_ROOT") as? String]
            .compactMap { $0 }.contains { $0.hasPrefix("/") }
        let root = try XCTUnwrap(set ? Session.dataRootOverride : nil,
                                 "no data folder of the test run's own: no download is started", file: file, line: line)
        XCTAssertEqual(Session.folder.standardizedFileURL, root.standardizedFileURL, file: file, line: line)
    }

    /// A page whose configuration has the test's scheme, whose answer never comes.
    private func makeNeverAnsweringPage() -> Page {
        let configuration = Self.keepingNothing()
        configuration.setURLSchemeHandler(NeverAnswers(), forURLScheme: NeverAnswers.scheme)
        return makePage(configuration: configuration)
    }

    /// A download handed to a page, and what came of it.
    private struct HandedOver {
        let download: WKDownload
        /// The item Downloads made for it.
        let item: DownloadRecord
        /// The download's delegate once the page had handed it over, before the test's.
        let delegate: AnyObject?
    }

    /// A download of WebKit's at the test's scheme, whose answer never comes,
    /// handed to `page` as the adapter hands one, then given `delegate`.
    private func handOver(_ name: String, to page: Page, delegate: SavesNothing,
                          file: StaticString = #filePath, line: UInt = #line) async throws -> HandedOver {
        let download = try await startDownload(NeverAnswers.address(name), on: page, file: file, line: line)
        let before = Set(Downloads.shared.items.map(\.id))
        page.navigationBecameDownload(WebKitDownload(download))
        let taken = download.delegate
        download.delegate = delegate
        let item = try XCTUnwrap(Downloads.shared.items.first { !before.contains($0.id) },
                                 "Downloads has no item for the download", file: file, line: line)
        return HandedOver(download: download, item: item, delegate: taken)
    }

    /// A download WebKit starts by itself at `url`, with no navigation.
    private func startDownload(_ url: URL, on page: Page,
                               file: StaticString = #filePath, line: UInt = #line) async throws -> WKDownload {
        let started = Started()
        let done = expectation(description: "WebKit started the download")
        page.view.startDownload(using: URLRequest(url: url)) { download in
            started.download = download
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        return try XCTUnwrap(started.download, "WebKit didn't start a download at \(url)", file: file, line: line)
    }

    /// Cancels the item's download through Downloads and waits until it has
    /// stopped and isn't the page's, then clears finished activity, the item's with it.
    private func stop(_ item: DownloadRecord, of page: Page, file: StaticString = #filePath, line: UInt = #line) async {
        Downloads.shared.cancel(item)
        await waitFor("the download stopped", file: file, line: line) {
            Downloads.shared.items.first { $0.id == item.id }?.phase != .downloading
                && !Downloads.shared.isDownloading(for: page)
        }
        Downloads.shared.clearFinished()
        XCTAssertNil(Downloads.shared.items.first { $0.id == item.id }, "clearing activity left the download",
                     file: file, line: line)
    }

    /// Nothing saved by a download here: the test run's Downloads folder,
    /// where Downloads saves in a run with a data folder of its own (Files),
    /// holds nothing but its list of activity.
    private func assertNothingSaved(file: StaticString = #filePath, line: UInt = #line) {
        let folder = Session.folder.appendingPathComponent("Downloads", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(names.filter { $0 != "activity.json" }, [], "a download saved something in \(folder.path)",
                       file: file, line: line)
    }

    /// The downloads of WebKit's Downloads is running for `page`, read from
    /// the list it keeps to itself (`running`): the only way to the download
    /// WebKit handed the page, to give it the test's delegate.
    private static func running(for page: Page) -> [WKDownload] {
        let owner = ObjectIdentifier(page)
        guard let running = Mirror(reflecting: Downloads.shared).children.first(where: { $0.label == "running" })?.value
        else { return [] }
        return Mirror(reflecting: running).children.compactMap { entry -> WKDownload? in
            guard let value = Mirror(reflecting: entry.value).children.first(where: { $0.label == "value" })?.value
            else { return nil }
            let fields = Mirror(reflecting: value).children
            guard fields.first(where: { $0.label == "page" })?.value as? ObjectIdentifier == owner else { return nil }
            return fields.first { $0.label == "download" }?.value as? WKDownload
        }
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

/// The download WebKit gave a start's completion.
@MainActor
private final class Started {
    var download: WKDownload?
}

/// Never answers what it is asked for, so a download at its address never
/// has an answer to save.
private final class NeverAnswers: NSObject, WKURLSchemeHandler {
    static let scheme = "eglu-test-never-saved"

    static func address(_ name: String) -> URL {
        URL(string: "\(scheme)://downloads/\(name)")!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// A download's delegate that saves nothing: asked where to save, it says
/// nowhere, which stops the download. It counts what WebKit told it.
@MainActor
private final class SavesNothing: NSObject, WKDownloadDelegate {
    private(set) var asked = 0
    private(set) var failed = 0
    private(set) var finished = 0

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        asked += 1
        completionHandler(nil)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        failed += 1
    }

    func downloadDidFinish(_ download: WKDownload) {
        finished += 1
    }
}

/// A host that keeps which pages told it they closed, and does what the test
/// says the moment one does; for everything else, the least a host does.
@MainActor
private final class DownloadHost: PageHost {
    private(set) var closed: [ObjectIdentifier] = []
    var whenClosed: ((Page) -> Void)?

    func pageDidChange(_ page: Page) {}
    func isShowing(_ page: Page) -> Bool { false }
    func page(_ page: Page, openChild request: any WebChildRequest) -> Page? { nil }
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool { false }
    func pageDidClose(_ page: Page) {
        closed.append(ObjectIdentifier(page))
        whenClosed?(page)
    }
    var hostWindow: NSWindow? { nil }
}
