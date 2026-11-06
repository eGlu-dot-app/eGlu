import AppKit
import PadCore
import WebEngineCore
import WebKit
import XCTest
@testable import eGluMac

/// A Mac page's own services through the engine (Docs/EngineSplitPlan.md,
/// 7, step 7a: `WebFind`, `WebZoom`, `WebMediaCapture`, `WebUserAgent`),
/// through a real page and WebKit: Find's words found on the loaded page,
/// forwards and backwards, whatever their case, and words not on it not
/// found, with empty text answered at once; zoom by Safari's steps, to
/// actual size and to a size typed in, rounded to a whole percent and kept
/// within Safari's ends, the page's zoom its view's throughout and the host
/// told of each change and of no other; the pinch's magnification, the
/// view's; a page with neither the camera nor the microphone not kept for
/// them; and a phone's size with Safari's iPhone agent, which the page,
/// reloaded, sends, and Full putting WebKit's own agent back.
///
/// Every page is a data: page in a store that keeps nothing: no network.
/// The host here says it shows no page and has no window.
///
/// Not here: printing (`print()` runs the print panel on the host's window)
/// and the developer tools (`showDeveloperTool` opens the Web Inspector in
/// its own window), both covered without any window by the WebKitMacPlugin
/// package's tests (WebKitPageServicesTests); a page that has the camera or
/// the microphone (it needs a device and the person's permission), and so
/// what `appWentBehind()` does in a call (it floats a playing video); and
/// the window's zoom (`WindowModel.refresh` reads `page.pageZoom`), which
/// needs a real window.
@MainActor
final class PageServicesTests: PageTestCase {
    /// The hosts made here; let go of after each test.
    private var hosts: [ServicesHost] = []

    override func tearDown() async throws {
        hosts.removeAll()
        try await super.tearDown()
    }

    // MARK: Find

    /// Words on the page are found, forwards and backwards, whatever their
    /// case; words not on it, or not together, are not.
    func testFindFindsTheWordsOnThePageAndNoOthers() async {
        let page = makePage()
        await show(page, "Find", body: "<p>The quick brown fox jumps over the lazy dog.</p>")

        for backwards in [false, true] {
            let way = backwards ? "backwards" : "forwards"
            for text in ["quick", "QUICK", "Brown Fox", "lazy dog."] {
                let found = await find(text, backwards: backwards, in: page)
                XCTAssertEqual(found, true, "\"\(text)\" not found \(way)")
            }
            for text in ["zebra", "quick fox", "dogs"] {
                let found = await find(text, backwards: backwards, in: page)
                XCTAssertEqual(found, false, "\"\(text)\" found \(way)")
            }
        }
    }

    /// Empty text is no search: the answer is false, given before the call returns.
    func testFindingEmptyTextAnswersFalseAtOnce() async {
        let page = makePage()
        await load(page, "Nothing To Find")
        let answers = Answers()
        page.find("") { answers.values.append($0) }
        XCTAssertEqual(answers.values, [false])
        page.find("", backwards: true) { answers.values.append($0) }
        XCTAssertEqual(answers.values, [false, false])
    }

    // MARK: Zoom

    /// Safari's steps: up from actual size to 110%, back to it, down to 90%;
    /// 0 is actual size; there is no step past 300% or under 50%, where the
    /// zoom stays and the host isn't told. The page's zoom is its view's
    /// throughout, and the host is told of each change.
    func testZoomTakesSafarisSteps() async {
        let (page, host) = await hosted("Zoomed")
        XCTAssertEqual(page.pageZoom, 1)
        XCTAssertEqual(page.pageZoom, Double(page.view.pageZoom))
        host.told.removeAll()

        XCTAssertTrue(page.zoom(by: 1))
        assertZoom(page, 1.1, told: host, times: 1)
        XCTAssertTrue(page.zoom(by: -1))
        assertZoom(page, 1, told: host, times: 2)
        XCTAssertTrue(page.zoom(by: -1))
        assertZoom(page, 0.9, told: host, times: 3)
        XCTAssertTrue(page.zoom(by: 0))
        assertZoom(page, 1, told: host, times: 4)

        page.setZoom(3)
        assertZoom(page, 3, told: host, times: 5)
        XCTAssertFalse(page.zoom(by: 1), "a step past 300%")
        assertZoom(page, 3, told: host, times: 5)
        XCTAssertTrue(page.zoom(by: -1))
        assertZoom(page, 2.5, told: host, times: 6)

        page.setZoom(0.5)
        assertZoom(page, 0.5, told: host, times: 7)
        XCTAssertFalse(page.zoom(by: -1), "a step under 50%")
        assertZoom(page, 0.5, told: host, times: 7)
        XCTAssertTrue(page.zoom(by: 1))
        assertZoom(page, 0.67, told: host, times: 8)
        XCTAssertTrue(page.zoom(by: 0))
        assertZoom(page, 1, told: host, times: 9)
    }

    /// A size typed in is the whole percent nearest it, within Safari's
    /// ends; a step from a typed size is the next of Safari's past it, a
    /// typed 99% going up to 100%. Each is the view's, and the host is told.
    func testATypedZoomIsAWholePercentWithinSafarisEnds() async {
        let (page, host) = await hosted("Typed")
        host.told.removeAll()

        let typed: [(Double, Double)] = [(1.234, 1.23), (1.236, 1.24), (0.996, 1), (2.999, 3),
                                         (5, 3), (3.004, 3), (0.1, 0.5), (0.494, 0.5), (-1, 0.5)]
        for (index, (asked, zoom)) in typed.enumerated() {
            page.setZoom(asked)
            assertZoom(page, zoom, told: host, times: index + 1, "typed \(asked)")
        }

        page.setZoom(0.99)
        XCTAssertTrue(page.zoom(by: 1))
        assertZoom(page, 1, told: host, times: typed.count + 2, "up from a typed 99%")
        page.setZoom(1.23)
        XCTAssertTrue(page.zoom(by: 1))
        assertZoom(page, 1.25, told: host, times: typed.count + 4, "up from a typed 123%")
        page.setZoom(1.23)
        XCTAssertTrue(page.zoom(by: -1))
        assertZoom(page, 1.1, told: host, times: typed.count + 6, "down from a typed 123%")
        page.setZoom(2.99)
        XCTAssertTrue(page.zoom(by: 1))
        assertZoom(page, 3, told: host, times: typed.count + 8, "up from a typed 299%")
    }

    /// The pinch's magnification is the view's: 1 with none, then what the
    /// view is set to, and back.
    func testMagnificationIsTheViews() async {
        let page = makePage()
        await load(page, "Magnified")
        XCTAssertEqual(page.magnification, 1)

        page.view.setMagnification(2, centeredAt: .zero)
        XCTAssertEqual(page.magnification, Double(page.view.magnification))
        XCTAssertEqual(page.magnification, 2, accuracy: 0.0001)
        page.view.setMagnification(1.5, centeredAt: .zero)
        XCTAssertEqual(page.magnification, Double(page.view.magnification))
        XCTAssertEqual(page.magnification, 1.5, accuracy: 0.0001)
        page.view.setMagnification(1, centeredAt: .zero)
        XCTAssertEqual(page.magnification, Double(page.view.magnification))
        XCTAssertEqual(page.magnification, 1, accuracy: 0.0001)
    }

    // MARK: The camera and the microphone

    /// A page with neither the camera nor the microphone isn't kept for
    /// them: a loaded page that nothing else holds (no dialog, not
    /// hands-off, no extension's, no picture window, no Peek, no download)
    /// need not stay.
    func testAPageWithNoCameraOrMicrophoneNeedNotStay() async {
        let page = makePage()
        await load(page, "Quiet")
        XCTAssertEqual(page.view.cameraCaptureState, .none)
        XCTAssertEqual(page.view.microphoneCaptureState, .none)
        XCTAssertFalse(page.hasPendingDialog)
        XCTAssertFalse(page.isHandsOff)
        XCTAssertFalse(page.isExtensionPage)
        XCTAssertNil(page.picture)
        XCTAssertNil(page.peek)
        XCTAssertFalse(Downloads.shared.isDownloading(for: page))
        XCTAssertFalse(page.mustStay)
    }

    // MARK: A device's size

    /// An iPhone's size has the page at that size with Safari's iPhone
    /// agent, which the page, reloaded, sends; Full puts both back: WebKit's
    /// own agent, read before, sent again after the next reload.
    func testAPhonesSizeSendsSafarisAgentAndFullPutsWebKitsBack() async throws {
        let (page, host) = await hosted("Sized")
        XCTAssertNil(page.deviceSize)
        let own = try await userAgent(of: page)
        XCTAssertFalse(own.contains("iPhone"), "WebKit's own agent is a phone's: \(own)")
        let phone = CGSize(width: 390, height: 844)
        let mobile = Identity.mobileUserAgent(for: ProcessInfo.processInfo.operatingSystemVersion, pad: false)
        XCTAssertNotEqual(mobile, own)

        try await markDocument(page)
        host.told.removeAll()
        page.size(phone, pad: false)
        XCTAssertEqual(page.deviceSize, phone)
        XCTAssertEqual(page.view.customUserAgent, mobile)
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told of the size")
        await waitForReload(page, titled: "Sized")
        let sent = try await userAgent(of: page)
        XCTAssertEqual(sent, mobile)

        try await markDocument(page)
        host.told.removeAll()
        page.size(nil, pad: false)
        XCTAssertNil(page.deviceSize)
        XCTAssertEqual(page.view.customUserAgent ?? "", "", "Full left an agent of eGlu's")
        XCTAssertFalse(host.told.isEmpty, "the host wasn't told of Full")
        await waitForReload(page, titled: "Sized")
        let back = try await userAgent(of: page)
        XCTAssertEqual(back, own)
    }

    // MARK: Helpers

    /// A data: page named `title` with `body` after its title.
    private static func document(_ title: String, _ body: String) -> URL {
        let html = "<!doctype html><title>\(title)</title>\(body)"
        return URL(string: "data:text/html;charset=utf-8," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    /// Loads the page named `title` with `body`, the way eGlu loads an
    /// address, and waits for it.
    private func show(_ page: Page, _ title: String, body: String,
                      file: StaticString = #filePath, line: UInt = #line) async {
        page.load(Self.document(title, body))
        await waitForPage(page, titled: title, file: file, line: line)
    }

    /// A page named `title`, loaded, its host a `ServicesHost`.
    private func hosted(_ title: String, file: StaticString = #filePath, line: UInt = #line) async -> (Page, ServicesHost) {
        let page = makePage()
        let host = ServicesHost()
        hosts.append(host)
        page.host = host
        await load(page, title, file: file, line: line)
        return (page, host)
    }

    /// Whether Find found `text` on the page: its one answer, or nil where none came.
    private func find(_ text: String, backwards: Bool, in page: Page,
                      file: StaticString = #filePath, line: UInt = #line) async -> Bool? {
        let answered = expectation(description: "Find answered for \(text)")
        let answers = Answers()
        page.find(text, backwards: backwards) {
            answers.values.append($0)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(answers.values.count, 1, "answers to Find for \(text)", file: file, line: line)
        return answers.values.first
    }

    /// The page's zoom is `zoom`, its view's is the same, and the host has
    /// been told `times` in all, last at that zoom.
    private func assertZoom(_ page: Page, _ zoom: Double, told host: ServicesHost, times: Int, _ what: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(page.pageZoom, zoom, accuracy: 0.0001, what, file: file, line: line)
        XCTAssertEqual(page.pageZoom, Double(page.view.pageZoom), "the page's zoom isn't its view's \(what)",
                       file: file, line: line)
        XCTAssertEqual(host.told.count, times, "times the host was told \(what)", file: file, line: line)
        if let last = host.told.last {
            XCTAssertEqual(last, zoom, accuracy: 0.0001, "the zoom the host was last told at \(what)", file: file, line: line)
        }
    }

    /// The agent the page's document sends, as its script reads it.
    private func userAgent(of page: Page, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let agent = try await page.view.evaluateJavaScript("navigator.userAgent")
        return try XCTUnwrap(agent as? String, "the page has no agent", file: file, line: line)
    }

    /// A mark in the document now, which a reload takes away.
    private func markDocument(_ page: Page) async throws {
        _ = try await page.view.evaluateJavaScript("window.__egluTestsBefore = true; 1")
    }

    /// Waits, up to `timeout`, for a new document named `title` (the mark
    /// gone), loaded, looked at every 50 ms.
    private func waitForReload(_ page: Page, titled title: String, timeout: TimeInterval = 10,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !page.view.isLoading, page.view.title == title {
                let fresh = try? await page.view.evaluateJavaScript(
                    "window.__egluTestsBefore === undefined && document.readyState === 'complete'")
                if fresh as? Bool == true, !page.view.isLoading { return }
            }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        XCTFail("the page wasn't reloaded by \(timeout) s", file: file, line: line)
    }
}

/// Each answer Find gave, in order.
@MainActor
private final class Answers {
    var values: [Bool] = []
}

/// A host that keeps the page's zoom each time the page told it of a
/// change; for everything else, the least a host does: it shows nothing.
@MainActor
private final class ServicesHost: PageHost {
    var told: [Double] = []

    func pageDidChange(_ page: Page) { told.append(page.pageZoom) }
    func isShowing(_ page: Page) -> Bool { false }
    func page(_ page: Page, openChild request: any WebChildRequest) -> Page? { nil }
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool { false }
    func pageDidClose(_ page: Page) {}
    var hostWindow: NSWindow? { nil }
}
