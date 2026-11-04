import AppKit
import PadCore
import WebEngineCore
import WebKit
import XCTest
@testable import eGluMac

/// The page's answer to each response, asked with plain values
/// (`Page.decideResponse`, Docs/EngineSplitPlan.md, 7, step 4b): one
/// answer, given before the call returns; what WebKit can't show and what
/// the server says to save is a download; only the main frame's answer
/// becomes the page's kind of document and its status. And the same
/// through WebKit, a data: page's response reaching the page by the adapter.
///
/// The responses here are made by the test and only ever decided on, never
/// loaded: websites at `.invalid`, which names no host anywhere, and data:
/// and file: addresses. The page's status keeps an answer until its
/// document commits (PageStatus), so a test that reads `statusCode` tells
/// the page of a commit by hand, as WebKit would after the answer.
///
/// Not here: the colour-hint retry itself (a host asking for
/// `Sec-CH-Prefers-Color-Scheme` on a dark screen: the page loads it again,
/// and the hosts that asked are kept for the whole run), a hands-off host
/// (HandsOff), and a download WebKit really begins (it would save a file).
@MainActor
final class PageResponsePolicyTests: PageTestCase {
    // MARK: One answer

    /// Every mix of frame, of whether WebKit can show it, and of response (a
    /// website's, with and without a status other than 200 or a header to
    /// save it, and a data: page's): one answer each, before the call
    /// returns; a download exactly where WebKit can't show it or the server
    /// says to save it, allowed otherwise, never cancelled; and nothing loaded.
    func testEveryResponseIsAnsweredOnceBeforeTheCallReturns() {
        let page = makePage()
        let responses: [(String, URLResponse, Bool)] = [
            ("a website's page", Self.http(Self.web("page")), false),
            ("a website's missing page", Self.http(Self.web("missing"), status: 404), false),
            ("a website's failing page", Self.http(Self.web("failing"), status: 500), false),
            ("a page to show inline", Self.http(Self.web("inline"), headers: ["Content-Disposition": "inline"]), false),
            ("a file to save", Self.http(Self.web("save"), type: "application/zip",
                                         headers: ["Content-Disposition": "attachment; filename=x.zip"]), true),
            ("a data: page", Self.plain(Self.dataPage, type: "text/html"), false),
        ]
        for (name, response, attachment) in responses {
            for mainFrame in [true, false] {
                for shows in [true, false] {
                    let what = "\(name), \(mainFrame ? "main frame" : "subframe"), \(shows ? "shown" : "not shown")"
                    let answer: WebResponseDecision = shows && !attachment ? .allow : .download
                    XCTAssertEqual(decide(page, response, mainFrame: mainFrame, shows: shows), answer, what)
                }
            }
        }
        XCTAssertNil(page.view.url, "an answer went to WebKit")
        XCTAssertFalse(page.view.isLoading)
    }

    // MARK: The main frame

    /// A main-frame response WebKit can show is allowed: the page's kind of
    /// document becomes the response's, and its HTTP status is kept until
    /// the document commits, then is the page's.
    func testAMainFrameResponseShownIsThePagesKindAndStatus() {
        let page = makePage()
        XCTAssertNil(page.mimeType)
        XCTAssertNil(page.statusCode)
        let answers: [(String, Int)] = [("text/html", 200), ("application/pdf", 404), ("image/png", 500),
                                        ("application/json", 203)]
        for (type, status) in answers {
            let response = Self.http(Self.web("kind"), status: status, type: type + "; charset=utf-8")
            XCTAssertEqual(response.mimeType, type, "Foundation's own reading of Content-Type")
            XCTAssertEqual(decide(page, response), .allow, type)
            XCTAssertEqual(page.mimeType, type)
            commit(page)
            XCTAssertEqual(page.statusCode, status, "the status of a \(type) answered \(status)")
        }
    }

    /// The answer is kept until the commit: before it, the page's status is
    /// still the document on screen's; the last answer before the commit is
    /// the one that counts.
    func testTheStatusWaitsForTheCommit() {
        let page = makePage()
        XCTAssertEqual(decide(page, Self.http(Self.web("first"), status: 404)), .allow)
        XCTAssertNil(page.statusCode, "an answer became the status before its document committed")
        commit(page)
        XCTAssertEqual(page.statusCode, 404)

        XCTAssertEqual(decide(page, Self.http(Self.web("second"), status: 500)), .allow)
        XCTAssertEqual(page.statusCode, 404, "the next answer replaced the status on screen before it committed")
        XCTAssertEqual(decide(page, Self.http(Self.web("third"), status: 201)), .allow)
        commit(page)
        XCTAssertEqual(page.statusCode, 201)
    }

    // MARK: Downloads

    /// `Content-Disposition: attachment`, in any letter case and with or
    /// without a file name, is a download, though WebKit could show it: the
    /// page's kind stays as it was, and the answer kept before it is
    /// dropped, so no status is the page's after the next commit. Inline, or
    /// a file name that only has the word in it, is shown.
    func testAnAttachmentIsADownload() {
        let saved = ["attachment", "Attachment; filename=x", "ATTACHMENT; filename=\"a.zip\"", "attachment;filename=b"]
        for value in saved {
            let page = makePage()
            XCTAssertEqual(decide(page, Self.http(Self.web("before"), status: 404)), .allow)
            XCTAssertEqual(page.mimeType, "text/html")

            let response = Self.http(Self.web("save"), headers: ["Content-Disposition": value])
            XCTAssertEqual(decide(page, response), .download, value)
            XCTAssertEqual(page.mimeType, "text/html", "a download changed the page's kind, \(value)")
            commit(page)
            XCTAssertNil(page.statusCode, "the answer before a download wasn't dropped, \(value)")
        }
        for value in ["inline", "inline; filename=attachment.zip", "form-data; name=attachment"] {
            let page = makePage()
            let response = Self.http(Self.web("shown"), status: 404, headers: ["Content-Disposition": value])
            XCTAssertEqual(decide(page, response), .allow, value)
            commit(page)
            XCTAssertEqual(page.statusCode, 404, value)
        }
    }

    /// A kind WebKit can't show (a ZIP, an installer) is a download, with no
    /// header to say so: the page's kind stays, and its status is dropped
    /// as an attachment's is.
    func testWhatWebKitCannotShowIsADownload() {
        for type in ["application/zip", "application/octet-stream", "application/x-apple-diskimage"] {
            let page = makePage()
            XCTAssertEqual(decide(page, Self.http(Self.web("before"), status: 404)), .allow)

            let response = Self.http(Self.web("installer"), type: type)
            XCTAssertNil(response.value(forHTTPHeaderField: "Content-Disposition"))
            XCTAssertEqual(decide(page, response, shows: false), .download, type)
            XCTAssertEqual(page.mimeType, "text/html", "a download changed the page's kind, \(type)")
            commit(page)
            XCTAssertNil(page.statusCode, "the answer before a download wasn't dropped, \(type)")
        }
    }

    // MARK: Frames

    /// A frame's response is allowed or saved by the same rule, and leaves
    /// the page's kind and its status alone: the main frame's answer before
    /// it is the one the commit makes the page's.
    func testASubframeResponseLeavesThePageAlone() {
        let page = makePage()
        XCTAssertEqual(decide(page, Self.http(Self.web("main"), status: 404)), .allow)
        XCTAssertEqual(page.mimeType, "text/html")

        let frames: [(String, URLResponse, Bool, WebResponseDecision)] = [
            ("a picture", Self.http(Self.web("frame.png"), status: 500, type: "image/png"), true, .allow),
            ("a file to save", Self.http(Self.web("frame.zip"), status: 200, type: "application/zip",
                                         headers: ["Content-Disposition": "attachment"]), true, .download),
            ("an installer", Self.http(Self.web("frame.dmg"), status: 200, type: "application/x-apple-diskimage"),
             false, .download),
            ("a data: page", Self.plain(Self.dataPage, type: "text/plain"), true, .allow),
        ]
        for (name, response, shows, answer) in frames {
            XCTAssertEqual(decide(page, response, mainFrame: false, shows: shows), answer, "a frame's \(name)")
            XCTAssertEqual(page.mimeType, "text/html", "a frame's \(name) changed the page's kind")
        }
        commit(page)
        XCTAssertEqual(page.statusCode, 404, "a frame's answer replaced or dropped the page's")
    }

    // MARK: Not HTTP

    /// A response that isn't HTTP (a data: or file: page) has no headers to
    /// read and no status: shown, it is allowed, its kind is the page's, and
    /// it replaces the website's answer kept before it, so no status is the
    /// page's after the commit; not shown, it is a download.
    func testAResponseThatIsNotHTTPHasNoStatus() {
        let pages: [(String, URL, String)] = [
            ("data:", Self.dataPage, "text/html"),
            ("file:", URL(string: "file:///eglu-tests.invalid/notes.txt")!, "text/plain"),
        ]
        for (name, url, type) in pages {
            let page = makePage()
            XCTAssertEqual(decide(page, Self.http(Self.web("before"), status: 404)), .allow)
            let response = Self.plain(url, type: type)
            XCTAssertFalse(response is HTTPURLResponse)
            XCTAssertEqual(decide(page, response), .allow, name)
            XCTAssertEqual(page.mimeType, type, name)
            commit(page)
            XCTAssertNil(page.statusCode, "a \(name) page's answer didn't replace the website's")

            let unshown = makePage()
            XCTAssertEqual(decide(unshown, Self.http(Self.web("before"), status: 404)), .allow)
            XCTAssertEqual(decide(unshown, Self.plain(url, type: "application/zip"), shows: false), .download, name)
            XCTAssertEqual(unshown.mimeType, "text/html", "a \(name) download changed the page's kind")
            commit(unshown)
            XCTAssertNil(unshown.statusCode, "the answer before a \(name) download wasn't dropped")
        }
    }

    /// The header is found in any letter case, as Foundation's own lookup
    /// (`HTTPURLResponse.value(forHTTPHeaderField:)`) finds it: a server's
    /// `content-disposition` in lower case still saves the file.
    func testTheHeaderIsFoundInAnyLetterCase() {
        for name in ["content-disposition", "CONTENT-DISPOSITION", "Content-disposition"] {
            let page = makePage()
            let response = Self.http(Self.web("case"), headers: [name: "attachment; filename=x"])
            XCTAssertNotNil(response.value(forHTTPHeaderField: "Content-Disposition"), "Foundation's lookup, \(name)")
            XCTAssertEqual(decide(page, response), .download, name)
            XCTAssertNil(page.mimeType, "a download became the page's kind, \(name)")
        }
    }

    // MARK: The screen's light or dark

    /// A website that doesn't ask for the screen's light or dark, on a dark
    /// screen, by a plain click the page decided (a request that could be
    /// made again, without the hint): everything a second request needs but
    /// the host's asking. With no Accept-CH, or one that names only other
    /// hints, it is allowed, not cancelled, and nothing is loaded again.
    func testAHostThatDoesNotAskIsNotAskedAgain() {
        let page = makePage()
        page.view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(page.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
                       "the page's screen isn't dark")
        let url = URL(string: "https://hint.eglu-tests.invalid/page")!
        var answers: [WebNavigationDecision] = []
        page.decideNavigation(WebNavigation(request: URLRequest(url: url), sourceOrigin: .opaque,
                                            targetIsMainFrame: true, kind: .link, modifiers: [], buttonNumber: 0,
                                            requestsDownload: false, isServerRedirect: false,
                                            contentRuleRedirect: nil)) { answers.append($0) }
        XCTAssertEqual(answers, [.allow], "the click itself")

        let headers: [(String, [String: String])] = [
            ("no Accept-CH", [:]),
            ("other hints", ["Accept-CH": "Sec-CH-UA-Platform, Sec-CH-UA-Mobile"]),
            ("other critical hints", ["Accept-CH": "Sec-CH-UA-Platform", "Critical-CH": "Sec-CH-UA-Platform"]),
        ]
        for (name, fields) in headers {
            let response = Self.http(url, headers: fields)
            XCTAssertFalse(ColorSchemeHint.isAsked(acceptCH: response.value(forHTTPHeaderField: "Accept-CH"),
                                                   criticalCH: response.value(forHTTPHeaderField: "Critical-CH")),
                           "the response asks for the screen's light or dark, \(name)")
            XCTAssertEqual(decide(page, response), .allow, name)
            XCTAssertEqual(page.mimeType, "text/html", name)
        }
        XCTAssertNil(page.view.url, "the page was loaded again")
        XCTAssertFalse(page.view.isLoading, "the page was loaded again")
    }

    // MARK: Through WebKit

    /// A data: page loaded for real: WebKit asks the adapter, the adapter
    /// the page, and the page's kind is the response's, `text/html`, then
    /// `text/plain`. A data: page has no status: the load's own answer
    /// replaces a website's kept from before it, so none is the page's.
    func testADataPageLoadedThroughWebKitIsDecidedByThePage() async {
        let page = makePage()
        XCTAssertEqual(decide(page, Self.http(Self.web("before"), status: 404)), .allow)
        XCTAssertNil(page.statusCode)

        await load(page, "One")
        XCTAssertEqual(page.mimeType, "text/html", "the response's decision didn't reach the page")
        XCTAssertNil(page.statusCode, "the load's own answer didn't reach the page's status")
        XCTAssertNotNil(page.committed)

        let plain = URL(string: "data:text/plain;charset=utf-8,Plain")!
        page.load(plain)
        await waitUntil(page, "the plain page shown") { $0.url == plain && !$0.isLoading }
        XCTAssertEqual(page.mimeType, "text/plain", "the second response's kind didn't reach the page")
        XCTAssertNil(page.statusCode)
        XCTAssertEqual(page.committed, plain)
        XCTAssertNil(page.failure)
    }

    /// A page with a frame of another kind (an SVG picture's own document),
    /// loaded for real: the frame's response is allowed, so the frame shows
    /// and tells the page so, and the page's kind is still its own.
    func testAFrameLoadedThroughWebKitLeavesThePagesKind() async {
        let page = makePage()
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"parent.postMessage('inner', '*')\"/>"
        let frame = "data:image/svg+xml;charset=utf-8," + svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let body = "<script>addEventListener('message', e => { if (e.data === 'inner') document.title = 'Inner shown' })"
            + "</script><iframe src=\"\(frame)\"></iframe>"
        page.load(Self.address("Framed", body: body))
        await waitForPage(page, titled: "Inner shown")
        XCTAssertEqual(page.mimeType, "text/html", "the frame's response became the page's kind")
        XCTAssertNil(page.statusCode)
        XCTAssertNil(page.failure)
    }

    // MARK: Helpers

    /// A website's address, decided on and never loaded.
    private static func web(_ path: String) -> URL {
        URL(string: "https://eglu-tests.invalid/" + path)!
    }

    /// A data: page's address, decided on and never loaded by these.
    private static let dataPage = URL(string: "data:text/html;charset=utf-8,%3Cp%3EData%3C%2Fp%3E")!

    /// A website's response: its status, its Content-Type (which Foundation
    /// reads the kind from), and any other headers.
    private static func http(_ url: URL, status: Int = 200, type: String = "text/html; charset=utf-8",
                             headers: [String: String] = [:]) -> HTTPURLResponse {
        let fields = headers.merging(["Content-Type": type]) { given, _ in given }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    }

    /// A response that isn't HTTP, as a data: or file: page's is: a kind and nothing else.
    private static func plain(_ url: URL, type: String) -> URLResponse {
        URLResponse(url: url, mimeType: type, expectedContentLength: -1, textEncodingName: "utf-8")
    }

    /// The page's one answer to `response`. A second answer, or none by the
    /// time the call returns, fails the test; the reply isn't escaping, so
    /// none can come later.
    private func decide(_ page: Page, _ response: URLResponse, mainFrame: Bool = true, shows: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) -> WebResponseDecision? {
        var answers: [WebResponseDecision] = []
        page.decideResponse(WebResponse(response: response, isForMainFrame: mainFrame, canShowMIMEType: shows)) {
            answers.append($0)
        }
        XCTAssertEqual(answers.count, 1, "answers to \(response.url?.absoluteString ?? "no address")",
                       file: file, line: line)
        return answers.first
    }

    /// WebKit's word that the main frame's document committed, said by hand
    /// to a page that loads nothing: when the page's status takes the answer
    /// it was keeping (PageStatus.committed).
    private func commit(_ page: Page) {
        page.webView(page.view, didCommit: nil)
    }
}
