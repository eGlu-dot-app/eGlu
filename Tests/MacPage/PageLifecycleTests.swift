import AppKit
import PadCore
import WebEngineCore
import WebKit
import XCTest
@testable import eGluMac

/// What the page does as its main frame's load goes (`Page`'s
/// `WebNavigationEvents`, Docs/EngineSplitPlan.md, 7, step 4c): where the
/// load is coming from, until it commits or fails before committing; a
/// commit that takes the event's address and clears the failure before it;
/// a stopped or interrupted load that changes nothing; a failure worth
/// telling, as "host: reason", or the reason alone; a form's sending that
/// fails and leaves the form; the page's process ending, reloaded by itself
/// until it keeps ending. And the same through WebKit, by the adapter: a
/// data: and an about:blank page committed and finished, a missing file
/// failed, and the page's process ended for real.
///
/// The events here are said by hand to pages that load nothing, or to data:
/// pages. Websites are at `.invalid`, which names no host anywhere, and are
/// only ever named in events and decisions, never loaded. Where nothing the
/// page shows depends on a value alone (where the load is coming from,
/// whether the request is a form's), the test reads the page's own value by
/// its name (`kept`).
///
/// Not here: a server's redirect through WebKit (it needs a server), a load
/// WebKit stops or interrupts for real (a download it begins would save a
/// file), the history the page keeps of a failure (PageHistory), an
/// extension's sign-in told of a failed load (ExtensionAuth), and what the
/// finish learns of a website (its icons, its description).
@MainActor
final class PageLifecycleTests: PageTestCase {
    // MARK: Where the load is coming from

    /// A load that starts, then is redirected by its server, is coming from
    /// each address in turn; its commit lets go of it.
    func testStartAndRedirectAreWhereTheLoadComesFromUntilItCommits() throws {
        let page = makePage()
        XCTAssertNil(try loadingFrom(page))
        let start = Self.web("start"), redirect = Self.web("redirected", host: "other.eglu-tests.invalid")

        page.navigationStarted(url: start)
        XCTAssertEqual(try loadingFrom(page), start)
        page.navigationRedirected(url: redirect)
        XCTAssertEqual(try loadingFrom(page), redirect)
        page.navigationCommitted(url: redirect)
        XCTAssertNil(try loadingFrom(page), "the commit didn't let go of where the load came from")

        page.navigationStarted(url: nil)
        XCTAssertNil(try loadingFrom(page), "a start with no address kept the last one")
    }

    /// A load that fails before it commits, for any reason, the quiet ones
    /// too, is coming from nowhere any more.
    func testAFailureBeforeTheCommitLetsGoOfIt() throws {
        for error in Self.quiet + [Self.notFound(Self.web("missing"))] {
            let page = makePage()
            page.navigationStarted(url: Self.web("start"))
            page.navigationRedirected(url: Self.web("redirected"))
            page.navigationFailed(error, provisional: true)
            XCTAssertNil(try loadingFrom(page), "a \(error.kind) failure before the commit kept it")
        }
    }

    /// A failure after a commit (the document on screen's own load, stopped
    /// or failed while the next one is starting) leaves the next load's
    /// address alone, whatever its reason.
    func testAFailureAfterTheCommitLeavesIt() throws {
        for error in Self.quiet + [Self.notFound(Self.web("missing"))] {
            let page = makePage()
            page.navigationCommitted(url: Self.web("shown"))
            let next = Self.web("next")
            page.navigationStarted(url: next)
            page.navigationFailed(error, provisional: false)
            XCTAssertEqual(try loadingFrom(page), next, "a \(error.kind) failure after the commit let go of it")
        }
    }

    // MARK: The commit

    /// A commit's address is the event's, not the view's (which has loaded
    /// nothing here): the page's committed address and what it shows. The
    /// failure before it is gone, and its address with it.
    func testACommitTakesTheEventsAddressAndClearsTheFailure() {
        let page = makePage()
        let failed = Self.web("failed")
        page.navigationFailed(Self.notFound(failed), provisional: true)
        XCTAssertNotNil(page.failure)
        XCTAssertEqual(page.displayURL, failed)

        let shown = Self.web("shown")
        page.navigationCommitted(url: shown)
        XCTAssertNil(page.view.url, "the test's commit loaded something")
        XCTAssertEqual(page.committed, shown, "the committed address isn't the event's")
        XCTAssertNil(page.failure, "the commit didn't clear the failure")
        XCTAssertNil(page.displayURL, "the failed address is still shown after the commit")

        page.navigationCommitted(url: nil)
        XCTAssertNil(page.committed, "a commit with no address kept the last one")
    }

    /// A form's sending that failed is over once a document commits: the
    /// page no longer takes Try Again for the form's.
    func testACommitClearsAFormsFailedSending() throws {
        let page = makePage()
        XCTAssertEqual(decide(page, Self.sending(Self.web("send"))), .allow)
        page.navigationFailed(Self.notFound(Self.web("send")), provisional: true)
        XCTAssertTrue(try kept("sendingFailed", of: page, as: Bool.self), "the sending's failure wasn't a form's")
        XCTAssertNotNil(page.failure)

        page.navigationCommitted(url: Self.web("shown"))
        XCTAssertFalse(try kept("sendingFailed", of: page, as: Bool.self), "the commit didn't clear the form's failure")
        XCTAssertNil(page.failure)
    }

    // MARK: Quiet failures

    /// A load stopped (cancelled) or interrupted (it became a download, or
    /// a plug-in's own load), before or after its commit, while a page is
    /// under way and after a form's sending failed: no failure is shown
    /// where none was, the form's stays, and the address shown, the status,
    /// the committed address and whether a form's sending failed stay as
    /// they were; the host isn't told. A failure worth telling would have
    /// changed each (testAFailedPageIsItsHostAndTheReason).
    func testAStoppedOrInterruptedLoadChangesNothingShown() throws {
        for error in Self.quiet {
            for provisional in [true, false] {
                for formFailed in [false, true] {
                    let what = "\(error.domain) \(error.code), \(provisional ? "before" : "after") the commit, "
                        + (formFailed ? "after a form's failed sending" : "a page under way")
                    let page = makePage()
                    let host = LifecycleHost()
                    page.host = host
                    XCTAssertEqual(decideAnswer(page, status: 404), .allow)
                    page.navigationCommitted(url: Self.web("shown"))
                    if formFailed {
                        XCTAssertEqual(decide(page, Self.sending(Self.web("send"))), .allow)
                        page.navigationFailed(Self.notFound(Self.web("send")), provisional: true)
                    } else {
                        XCTAssertEqual(decide(page, Self.going(Self.web("next"))), .allow)
                    }
                    let before = Shown(page)
                    let sending: Bool = try kept("sendingFailed", of: page)
                    XCTAssertEqual(before.failure != nil, formFailed, what)
                    XCTAssertEqual(sending, formFailed, what)
                    XCTAssertEqual(before.statusCode, 404, what)
                    XCTAssertEqual(before.displayURL, formFailed ? nil : Self.web("next"), what)
                    host.told.removeAll()

                    page.navigationFailed(error, provisional: provisional)
                    XCTAssertEqual(Shown(page), before, what)
                    XCTAssertEqual(try kept("sendingFailed", of: page, as: Bool.self), sending, what)
                    XCTAssertEqual(host.told, [], "the host was told of a quiet failure, \(what)")
                }
            }
        }
    }

    /// A page that has shown nothing yet stays that way through a quiet
    /// failure: no failure message, no address, and the host not told.
    func testAQuietFailureOnANewPageShowsNoFailure() {
        for error in Self.quiet {
            let page = makePage()
            let host = LifecycleHost()
            page.host = host
            page.navigationStarted(url: Self.web("start"))
            page.navigationFailed(error, provisional: true)
            XCTAssertNil(page.failure, "a \(error.kind) failure was shown")
            XCTAssertNil(page.displayURL)
            XCTAssertEqual(host.told, [])
        }
    }

    // MARK: A failure worth telling

    /// A page asked for that fails, before or after its commit, for any
    /// reason worth telling: the failure is the failing address's host and
    /// PadCore's reason for the domain and code; the address shown is the
    /// one that failed; the status is gone; the committed address stays;
    /// it isn't a form's; and the host is told.
    func testAFailedPageIsItsHostAndTheReason() throws {
        let errors: [(String, Int)] = [
            (NSURLErrorDomain, NSURLErrorCannotFindHost),
            (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
            (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
            (NSURLErrorDomain, NSURLErrorTimedOut),
            (NSURLErrorDomain, NSURLErrorUserAuthenticationRequired),
            (NSURLErrorDomain, NSURLErrorBadURL),
            ("WebKitErrorDomain", 101),
        ]
        let reasons = Set(errors.map { PageLoadFailure.message(domain: $0.0, code: $0.1) })
        XCTAssertGreaterThan(reasons.count, 4, "PadCore gives the same reason for every code")
        for (domain, code) in errors {
            for provisional in [true, false] {
                let what = "\(domain) \(code), \(provisional ? "before" : "after") the commit"
                let page = makePage()
                let host = LifecycleHost()
                page.host = host
                let shown = Self.web("shown")
                XCTAssertEqual(decideAnswer(page, status: 404), .allow)
                page.navigationCommitted(url: shown)
                XCTAssertEqual(page.statusCode, 404)
                XCTAssertEqual(decide(page, Self.going(Self.web("next"))), .allow)
                host.told.removeAll()

                let failing = Self.web("missing", host: "missing.eglu-tests.invalid")
                let error = WebLoadError(kind: .other, domain: domain, code: code, failingURL: failing)
                page.navigationFailed(error, provisional: provisional)
                let reason = PageLoadFailure.message(domain: domain, code: code)
                XCTAssertEqual(page.failure, "missing.eglu-tests.invalid: " + reason, what)
                XCTAssertEqual(page.displayURL, failing, what)
                XCTAssertNil(page.statusCode, "a failed page kept its status, \(what)")
                XCTAssertEqual(page.committed, shown, what)
                XCTAssertFalse(try kept("sendingFailed", of: page, as: Bool.self), what)
                XCTAssertFalse(host.told.isEmpty, "the host wasn't told, \(what)")
            }
        }
    }

    /// Without a failing address, and nothing begun before it, the failure
    /// is the reason alone. With a load begun, it is the address begun's
    /// host, and that address is shown (PageLoadState.fail).
    func testWithoutAFailingAddressTheReasonIsAlone() {
        let reason = PageLoadFailure.message(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = WebLoadError(kind: .other, domain: NSURLErrorDomain, code: NSURLErrorTimedOut, failingURL: nil)

        let fresh = makePage()
        let host = LifecycleHost()
        fresh.host = host
        fresh.navigationFailed(error, provisional: true)
        XCTAssertEqual(fresh.failure, reason)
        XCTAssertNil(fresh.displayURL)
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told")

        let begun = makePage()
        let address = Self.web("begun", host: "begun.eglu-tests.invalid")
        XCTAssertEqual(decide(begun, Self.going(address)), .allow)
        begun.navigationFailed(error, provisional: true)
        XCTAssertEqual(begun.failure, "begun.eglu-tests.invalid: " + reason)
        XCTAssertEqual(begun.displayURL, address)
    }

    // MARK: A form's sending

    /// A form's sending (a POST the page decided) that fails: the failure
    /// is a form's and the reason alone, the page's address and its
    /// document stay, and the host is told. Try Again takes the failure
    /// away over the form, still there, and loads nothing.
    func testAFormsSendingThatFailsLeavesTheForm() async throws {
        let page = makePage()
        let host = LifecycleHost()
        page.host = host
        await load(page, "Form")
        let form = try XCTUnwrap(page.view.url)
        XCTAssertEqual(page.committed, form)

        let send = Self.web("send")
        XCTAssertEqual(decide(page, Self.sending(send)), .allow)
        XCTAssertFalse(try kept("askingForPage", of: page, as: Bool.self), "the POST was taken for a page")
        page.navigationStarted(url: send)
        host.told.removeAll()
        page.navigationFailed(Self.notFound(send), provisional: true)

        XCTAssertTrue(try kept("sendingFailed", of: page, as: Bool.self), "the failure isn't a form's")
        XCTAssertEqual(page.failure, PageLoadFailure.message(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        XCTAssertEqual(page.displayURL, form, "the address shown isn't the form's page")
        XCTAssertEqual(page.committed, form)
        XCTAssertNil(try loadingFrom(page))
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told")

        page.retry()
        XCTAssertNil(page.failure, "Try Again left the failure over the form")
        XCTAssertFalse(try kept("sendingFailed", of: page, as: Bool.self))
        XCTAssertFalse(page.view.isLoading, "Try Again loaded the form's page again, which would empty it")
        XCTAssertEqual(page.view.url, form)
        XCTAssertEqual(page.state.title, "Form")
    }

    // MARK: The page's process ending

    /// The first time the page's process ends, the page loads its document
    /// again by itself (a change only a load undoes is gone), shows no
    /// failure, isn't waiting, and the host is told.
    func testTheFirstEndingReloadsByItself() async throws {
        let page = makePage()
        let host = LifecycleHost()
        page.host = host
        await load(page, "One")
        try await retitle(page)
        host.told.removeAll()

        page.contentProcessEnded()
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told")
        await waitForPage(page, titled: "One")
        XCTAssertFalse(page.exhausted)
        XCTAssertNil(page.failure)
        XCTAssertEqual(try kept("crashes", of: page, as: CrashGuard.self).endings.count, 1)
    }

    /// Ending as many times as the page's crash budget allows, inside its
    /// window: each ending but the last reloads by itself; the last leaves
    /// the page as it is, unloaded, waiting, with its "used too much
    /// memory" failure, which is its own and not a form's. Reload by hand
    /// starts the count over: the next ending reloads by itself again.
    func testEndingTooOftenWaitsForReload() async throws {
        let page = makePage()
        let host = LifecycleHost()
        page.host = host
        await load(page, "One")
        let budget: CrashGuard = try kept("crashes", of: page)
        XCTAssertGreaterThan(budget.limit, 1)
        XCTAssertGreaterThan(budget.window, 10, "the window is too short for the test to end inside it")

        for ending in 1..<budget.limit {
            try await retitle(page)
            page.contentProcessEnded()
            await waitForPage(page, titled: "One")
            XCTAssertFalse(page.exhausted, "the page waited after ending \(ending) time(s)")
            XCTAssertNil(page.failure)
        }

        try await retitle(page)
        host.told.removeAll()
        page.contentProcessEnded()
        XCTAssertTrue(page.exhausted, "the page didn't wait after \(budget.limit) endings")
        XCTAssertEqual(page.failure, Self.usedTooMuchMemory)
        XCTAssertFalse(try kept("sendingFailed", of: page, as: Bool.self))
        XCTAssertFalse(page.view.isLoading, "the page loaded again by itself after its budget was used")
        XCTAssertEqual(page.state.title, "Changed")
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told")

        page.reload()
        XCTAssertFalse(page.exhausted, "Reload left the page waiting")
        XCTAssertNil(page.failure)
        await waitForPage(page, titled: "One")
        XCTAssertEqual(try kept("crashes", of: page, as: CrashGuard.self).endings, [], "Reload didn't start the count over")
        try await retitle(page)
        page.contentProcessEnded()
        await waitForPage(page, titled: "One")
        XCTAssertFalse(page.exhausted)
    }

    // MARK: Through WebKit

    /// A data: page and about:blank loaded for real: WebKit tells the
    /// adapter, the adapter the page, so the committed address is the
    /// view's, the load is coming from nowhere, and the host is told once
    /// the load is over (as it is by the view's own loading, too: the
    /// finish itself is the next test's).
    func testARealLoadCommitsThroughTheAdapter() async throws {
        let page = makePage()
        let host = LifecycleHost()
        page.host = host

        await load(page, "Loaded")
        let loaded = try XCTUnwrap(page.view.url)
        XCTAssertEqual(page.committed, loaded, "the commit didn't reach the page")
        XCTAssertEqual(page.displayURL, loaded)
        XCTAssertNil(page.failure)
        XCTAssertNil(try loadingFrom(page))
        XCTAssertEqual(host.told.last, false, "the host wasn't told once the load was over")

        let blank = try XCTUnwrap(URL(string: "about:blank"))
        page.load(blank)
        await waitUntil(page, "about:blank shown") { $0.url == blank && !$0.isLoading }
        XCTAssertEqual(page.committed, blank, "about:blank's commit didn't reach the page")
        XCTAssertNil(page.failure)
        XCTAssertNil(try loadingFrom(page))
    }

    /// A JSON data: page loaded for real: only the page's finish asks the
    /// document whether its JSON view is drawn, so a drawn view says the
    /// finish came through the adapter.
    func testARealFinishReachesThePage() async throws {
        XCTAssertTrue(Session.shared.preferences.formatJSON, "the test run's Settings don't format JSON")
        let page = makePage()
        let json = "{\"lifecycle\":\"finished\"}"
        let url = try XCTUnwrap(URL(string: "data:application/json;charset=utf-8,"
                                    + json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        page.load(url)
        await waitUntil(page, "the JSON page shown") { $0.url == url && !$0.isLoading }
        XCTAssertEqual(page.mimeType, "application/json")
        XCTAssertEqual(page.committed, url)
        await waitFor("the JSON view learned") { page.jsonView != nil }
        XCTAssertEqual(page.jsonView, true, "the finish didn't reach the page, or the view wasn't drawn")
    }

    /// A file that isn't there, loaded for real after a data: page: WebKit's
    /// failure before the commit reaches the page by the adapter. A file has
    /// no host, so the failure is the reason alone; the address shown is
    /// the file's, the committed address stays the data: page's, and the
    /// load is coming from nowhere.
    func testARealFailureReachesThePage() async throws {
        let page = makePage()
        let host = LifecycleHost()
        page.host = host
        await load(page, "Before")
        let before = try XCTUnwrap(page.view.url)
        let folder = FileManager.default.temporaryDirectory
        let missing = folder.appendingPathComponent("eglu-tests-missing-\(UUID().uuidString).html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        host.told.removeAll()

        page.view.loadFileURL(missing, allowingReadAccessTo: folder)
        await waitFor("the failure shown") { page.failure != nil }
        await waitUntil(page, "the load over") { !$0.isLoading }
        XCTAssertEqual(page.failure, PageLoadFailure.message(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
        XCTAssertEqual(page.displayURL?.standardizedFileURL, missing.standardizedFileURL)
        XCTAssertEqual(page.committed, before)
        XCTAssertNil(page.statusCode)
        XCTAssertNil(try loadingFrom(page))
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told")
    }

    /// The page's own content process ended for real (killed, as the system
    /// does one that uses too much memory): WebKit tells the adapter, the
    /// adapter the page, which loads its document again by itself in a new
    /// process, until its budget is used; then it waits, with its failure,
    /// and loads nothing.
    func testARealProcessEndingReachesThePage() async throws {
        let page = makePage()
        let host = LifecycleHost()
        page.host = host
        await load(page, "One")
        let budget: CrashGuard = try kept("crashes", of: page)

        for ending in 1..<budget.limit {
            try await retitle(page)
            let process = try Self.endProcess(of: page)
            await waitForPage(page, titled: "One")
            XCTAssertFalse(page.exhausted, "the page waited after ending \(ending) time(s)")
            XCTAssertNil(page.failure)
            XCTAssertNotEqual(Self.process(of: page), process, "the page is still in the process that ended")
        }
        XCTAssertEqual(try kept("crashes", of: page, as: CrashGuard.self).endings.count, budget.limit - 1,
                       "an ending didn't reach the page")

        host.told.removeAll()
        _ = try Self.endProcess(of: page)
        await waitFor("the page waiting") { page.exhausted }
        XCTAssertEqual(page.failure, Self.usedTooMuchMemory)
        XCTAssertFalse(page.view.isLoading, "the page loaded again by itself after its budget was used")
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told")
    }

    // MARK: Helpers

    /// What a person sees of the page, to compare before and after.
    private struct Shown: Equatable {
        let failure: String?
        let displayURL: URL?
        let statusCode: Int?
        let committed: URL?

        @MainActor init(_ page: Page) {
            failure = page.failure
            displayURL = page.displayURL
            statusCode = page.statusCode
            committed = page.committed
        }
    }

    /// The page's own failure where its process kept ending, in the app's words.
    private static let usedTooMuchMemory = String(
        localized: "This page used too much memory and was closed several times. Reload to try again.")

    /// A website's address, named in events and decisions and never loaded.
    private static func web(_ path: String, host: String = "eglu-tests.invalid") -> URL {
        URL(string: "https://\(host)/\(path)")!
    }

    /// The failures the page keeps quiet about, with the domains and codes
    /// WebKit gives them: stopped, and turned into a download or a plug-in's load.
    private static let quiet: [WebLoadError] = [
        WebLoadError(kind: .cancelled, domain: NSURLErrorDomain, code: NSURLErrorCancelled, failingURL: web("stopped")),
        WebLoadError(kind: .interrupted, domain: "WebKitErrorDomain", code: 102, failingURL: web("download")),
        WebLoadError(kind: .interrupted, domain: "WebKitErrorDomain", code: 204, failingURL: web("plug-in")),
    ]

    /// A failure worth telling: no such host.
    private static func notFound(_ url: URL) -> WebLoadError {
        WebLoadError(kind: .other, domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, failingURL: url)
    }

    /// The main frame going to `url` for a page (a GET), as the adapter gives it.
    private static func going(_ url: URL) -> WebNavigation {
        navigation(URLRequest(url: url), kind: .link)
    }

    /// The main frame sending a form to `url` (a POST), as the adapter gives it.
    private static func sending(_ url: URL) -> WebNavigation {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return navigation(request, kind: .form)
    }

    private static func navigation(_ request: URLRequest, kind: WebNavigationKind) -> WebNavigation {
        WebNavigation(request: request, sourceOrigin: .opaque, targetIsMainFrame: true, kind: kind,
                      modifiers: [], buttonNumber: 0, requestsDownload: false, isServerRedirect: false,
                      contentRuleRedirect: nil)
    }

    /// The page's one answer to `navigation`, given before the call returns.
    private func decide(_ page: Page, _ navigation: WebNavigation,
                        file: StaticString = #filePath, line: UInt = #line) -> WebNavigationDecision? {
        var answers: [WebNavigationDecision] = []
        page.decideNavigation(navigation) { answers.append($0) }
        XCTAssertEqual(answers.count, 1, "answers to \(navigation.request.url?.absoluteString ?? "no address")",
                       file: file, line: line)
        return answers.first
    }

    /// The page's one answer to a website's main-frame response with `status`,
    /// which the next commit makes the page's status.
    private func decideAnswer(_ page: Page, status: Int,
                              file: StaticString = #filePath, line: UInt = #line) -> WebResponseDecision? {
        let response = HTTPURLResponse(url: Self.web("answered"), statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        var answers: [WebResponseDecision] = []
        page.decideResponse(WebResponse(response: response, isForMainFrame: true, canShowMIMEType: true)) {
            answers.append($0)
        }
        XCTAssertEqual(answers.count, 1, "answers to the response", file: file, line: line)
        return answers.first
    }

    /// A value the page keeps to itself, read by its name, where nothing
    /// the page shows depends on it alone.
    private func kept<T>(_ name: String, of page: Page, as type: T.Type = T.self,
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let child = try XCTUnwrap(Mirror(reflecting: page).children.first { $0.label == name },
                                  "Page keeps no \(name)", file: file, line: line)
        return try XCTUnwrap(child.value as? T, "Page's \(name) is a \(Swift.type(of: child.value))",
                             file: file, line: line)
    }

    /// Where the page's load is coming from (Page.loadingFrom): what a
    /// redirect to an extension's page is checked against.
    private func loadingFrom(_ page: Page, file: StaticString = #filePath, line: UInt = #line) throws -> URL? {
        try kept("loadingFrom", of: page, as: URL?.self, file: file, line: line)
    }

    /// The document's title changed by its own script: only a load undoes it.
    private func retitle(_ page: Page, file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await page.view.evaluateJavaScript("document.title = 'Changed'; 1")
        await waitUntil(page, "the title changed", file: file, line: line) { $0.title == "Changed" }
    }

    /// Waits, up to `timeout`, for `condition`, looked at every 20 ms: for
    /// what the page keeps, which WebKit doesn't report a change of.
    private func waitFor(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath,
                         line: UInt = #line, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "\(what): not by \(timeout) s", file: file, line: line)
    }

    /// The page's content process, as WebKit says privately; nil where it doesn't.
    private static func process(of page: Page) -> pid_t? {
        let key = "_webProcessIdentifier"
        guard page.view.responds(to: NSSelectorFromString(key)),
              let number = page.view.value(forKey: key) as? NSNumber, number.int32Value > 1 else { return nil }
        return number.int32Value
    }

    /// Kills the page's own content process, and only a process that is
    /// WebKit's content process: its number from the page's view, its
    /// program checked just before. WebKit's own testing call for this
    /// (`_killWebContentProcess`) isn't let signal the service from here.
    /// Skips the test where the page's process can't be named or killed.
    private static func endProcess(of page: Page) throws -> pid_t {
        let pid = try XCTUnwrap(process(of: page), "WebKit doesn't say which process is the page's")
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw XCTSkip("the page's process \(pid) has no program to check")
        }
        let program = String(cString: path)
        guard program.contains("/WebKit.framework/"), program.contains("com.apple.WebKit.WebContent") else {
            XCTFail("process \(pid) is \(program), not WebKit's content process")
            throw XCTSkip("not killing \(program)")
        }
        guard kill(pid, SIGKILL) == 0 else {
            throw XCTSkip("the page's process can't be killed from here: \(String(cString: strerror(errno)))")
        }
        return pid
    }
}

/// A host that keeps, for each time the page told it of a change, whether
/// the page was loading then; for everything else, the least a host does.
@MainActor
private final class LifecycleHost: PageHost {
    var told: [Bool] = []

    func pageDidChange(_ page: Page) { told.append(page.view.isLoading) }
    func isShowing(_ page: Page) -> Bool { false }
    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView? { nil }
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool { false }
    func pageDidClose(_ page: Page) {}
    var hostWindow: NSWindow? { nil }
}
