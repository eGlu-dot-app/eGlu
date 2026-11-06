import PadCore
import WebKit
import WebKitSupport
import XCTest
@testable import eGluMac

/// A Mac page's script messages on the engine's channels (Docs/EngineSplitPlan.md,
/// 5.4 and 7, step 6), through a real page and WebKit: the bridge
/// (`egluBridge`) the page's own scripts put in the app's world, and only
/// there, with the channels Page opens; the password watch heard through
/// it, at the load and as the page changes; Writing's replying channel,
/// which answers the card's opening only while writing is on, its closing
/// always, and a lint once Harper has looked; writing.js put into the
/// document already up when writing is turned on, asking the Mac through
/// the bridge; the measuring tool's word reaching its panel, and its end;
/// a channel that isn't open throwing a TypeError; and the handlers' own
/// checks: a body that is no object, another run's word, a frame's message.
///
/// Every page is a data: page in a store that keeps nothing: no network.
/// Writing is turned on only for the tests that need it, never for other
/// apps' fields, and the settings are put back as they were after each
/// test. A test reads where a message went by what the page then holds;
/// where nothing changes, it first waits for one answer on Writing's
/// replying channel (`heardSoFar`), which comes only after every message
/// the document posted before it was heard, as WebKit hands them to the
/// app in the order they were posted.
///
/// The measuring tool says nothing when it starts: its first word is the
/// one a key pressed on the page makes (G, here, which switches its guides
/// on), so that is the word waited for. The frame's messages go to
/// WebKit's handlers by name, as nothing puts the bridge into a frame.
///
/// Not here: the Chrome Web Store's button (StoreButton needs the store's
/// own page, at its address on the network), Apple Passwords' messages
/// (Apple's helper and a site it serves; only whether its channel is open
/// is checked), a hands-off page's (a Google sign-in page), an extension's
/// page (it needs an installed extension), and Writing's actions that
/// write (a word for the dictionary, a rule turned off in the settings).
@MainActor
final class PageChannelTests: PageTestCase {
    /// The settings before the test, put back after it.
    private var preferences: Preferences?

    override func setUp() async throws {
        try await super.setUp()
        preferences = Session.shared.preferences
    }

    override func tearDown() async throws {
        if let preferences, Session.shared.preferences != preferences {
            Session.shared.preferences = preferences
        }
        preferences = nil
        try await super.tearDown()
    }

    // MARK: The password watch

    /// A page with a password field says so once it has loaded: the watch,
    /// in the app's world, posts through the bridge on egluPassword.
    func testAPasswordFieldOnThePageIsHeard() async throws {
        let page = makePage()
        XCTAssertFalse(page.passwordField)
        await show(page, "Sign In", body: "<form><input type=\"password\" name=\"p\"></form>")
        await waitFor("the password field heard") { page.passwordField }
    }

    /// A page without one has none, once all its watch said is heard.
    func testAPageWithoutAPasswordFieldHasNone() async throws {
        let page = makePage()
        await show(page, "No Sign In", body: "<form><input type=\"text\" name=\"q\"></form>")
        try await heardSoFar(page)
        XCTAssertFalse(page.passwordField)
    }

    /// A password field the page's own script adds after the load is heard,
    /// and so is its going: the watch looks again as the page changes.
    func testAPasswordFieldAddedLaterIsHeardAndSoIsItsGoing() async throws {
        let page = makePage()
        await show(page, "Later", body: "<form id=\"f\"></form>")
        try await heardSoFar(page)
        XCTAssertFalse(page.passwordField)

        _ = try await inPage(page, """
            const input = document.createElement('input');
            input.type = 'password';
            input.id = 'p';
            document.getElementById('f').append(input);
            return 'added';
            """)
        await waitFor("the added field heard", timeout: 20) { page.passwordField }
        _ = try await inPage(page, "document.getElementById('p').remove(); return 'removed';")
        await waitFor("the field's going heard", timeout: 20) { !page.passwordField }
    }

    // MARK: The bridge

    /// The app's world of a loaded page has egluBridge from the page's own
    /// scripts, nothing put in by the test: version 1, frozen, its name
    /// neither writable nor configurable, so nothing replaces it. eGlu's
    /// channels are open there, Apple Passwords' only in a build that may
    /// use it.
    func testTheBridgeAndTheChannelsAreInTheAppsWorld() async throws {
        let page = makePage()
        await load(page, "Bridged")

        let bridge = try await inApp(page, bridged: false, """
            const property = Object.getOwnPropertyDescriptor(globalThis, 'egluBridge');
            if (!property) return said(null);
            try { globalThis.egluBridge = null; } catch (_) {}
            try { egluBridge.version = 2; } catch (_) {}
            try { egluBridge.post = null; } catch (_) {}
            return said({
              version: egluBridge.version, frozen: Object.isFrozen(egluBridge),
              writable: property.writable, configurable: property.configurable,
              post: typeof egluBridge.post, request: typeof egluBridge.request,
            });
            """)
        let found = try object(bridge, "the bridge")
        XCTAssertEqual(found["version"] as? Int, 1)
        XCTAssertEqual(found["frozen"] as? Bool, true, "the bridge isn't frozen")
        XCTAssertEqual(found["writable"] as? Bool, false, "the bridge's name can be given another value")
        XCTAssertEqual(found["configurable"] as? Bool, false, "the bridge's name can be redefined")
        XCTAssertEqual(found["post"] as? String, "function")
        XCTAssertEqual(found["request"] as? String, "function")

        let open = try await inApp(page, bridged: false, """
            const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
            return said(\(Self.channelNames).filter((name) => handlers && handlers[name] !== undefined));
            """)
        var expected = ["egluStore", "egluPassword", "egluWriting", "egluMeasure"]
        if ApplePasswords.entitled { expected.append(ApplePasswordsForm.name) }
        XCTAssertEqual(try strings(open, "the channels open"), expected)
    }

    /// The page's own world sees none of it: no egluBridge and none of
    /// eGlu's channels; and a bridge the page makes for itself there is its
    /// own, never the app's.
    func testThePagesOwnWorldSeesNoneOfIt() async throws {
        let page = makePage()
        await load(page, "Unbridged")

        let seen = try await inPage(page, """
            const handlers = window.webkit && window.webkit.messageHandlers;
            return said({
              bridge: typeof globalThis.egluBridge,
              channels: \(Self.channelNames).filter((name) => handlers && handlers[name] !== undefined),
            });
            """)
        let found = try object(seen, "the page's world")
        XCTAssertEqual(found["bridge"] as? String, "undefined", "the page's own world has egluBridge")
        XCTAssertEqual(found["channels"] as? [String], [], "the page's own world has eGlu's channels")

        _ = try await inPage(page, "globalThis.egluBridge = { version: 99 }; return 'made';")
        let version = try await inApp(page, bridged: false, "return said(egluBridge.version);")
        XCTAssertEqual(version, "1", "the page's own bridge reached the app's world")
    }

    /// A post or a request to a channel that isn't open throws a TypeError
    /// in the script, as WebKit's own handlers do.
    func testAChannelNotOpenThrowsATypeError() async throws {
        let page = makePage()
        await load(page, "Not Open")
        let thrown = try await inApp(page, """
            const thrown = [];
            try { egluBridge.post('egluNoSuchChannel', {}); thrown.push('nothing'); } catch (error) { thrown.push(error.name); }
            try { egluBridge.request('egluNoSuchChannel', {}); thrown.push('nothing'); } catch (error) { thrown.push(error.name); }
            return said(thrown);
            """)
        XCTAssertEqual(try strings(thrown, "what was thrown"), ["TypeError", "TypeError"])
    }

    // MARK: Writing's channel

    /// The card's opening is answered, and heard, only while writing is on:
    /// off, the page's script gets nothing back and the card isn't open; on,
    /// it gets true and the card is open, its closing is answered true and
    /// the card is closed, and a question writing doesn't know gets nothing.
    func testWritingHearsTheCardOpenOnlyWhileWritingIsOn() async throws {
        setWriting(false)
        let page = makePage()
        await load(page, "Card")
        XCTAssertFalse(page.checksWriting())
        let refused = try await askWriting(page, "{kind: 'opened'}")
        XCTAssertEqual(refused, "undefined", "a card opening was answered with writing off")
        XCTAssertFalse(page.writingCardOpen)

        setWriting(true)
        XCTAssertTrue(page.checksWriting())
        let opened = try await askWriting(page, "{kind: 'opened'}")
        XCTAssertEqual(opened, "true")
        XCTAssertTrue(page.writingCardOpen, "the card's opening wasn't heard")
        let closed = try await askWriting(page, "{kind: 'closed'}")
        XCTAssertEqual(closed, "true")
        XCTAssertFalse(page.writingCardOpen, "the card's closing wasn't heard")
        let unknown = try await askWriting(page, "{kind: 'eglu-tests-unknown'}")
        XCTAssertEqual(unknown, "undefined")
    }

    /// The card's closing is heard even while writing is off, so ⌃⌥G never
    /// stays on for a card no longer there.
    func testACardClosingIsHeardWhileWritingIsOff() async throws {
        setWriting(false)
        let page = makePage()
        await load(page, "Closing")
        page.writingCardOpen = true
        let closed = try await askWriting(page, "{kind: 'closed'}")
        XCTAssertEqual(closed, "true")
        XCTAssertFalse(page.writingCardOpen, "the card's closing wasn't heard with writing off")
    }

    /// A lint is answered later, once Harper has looked (the reply given
    /// from a task, after the handler returned): the text's lints come back
    /// to the script, each with where it is in the text.
    func testWritingsLintIsAnsweredLater() async throws {
        setWriting(true)
        let page = makePage()
        await load(page, "Linted")
        let text = "This is an test."
        let answer = try await inApp(page, """
            const answer = await Promise.race([
              egluBridge.request('egluWriting', {kind: 'lint', text: '\(text)'}),
              new Promise((done) => setTimeout(() => done('no answer'), 60000)),
            ]);
            return said(answer);
            """)
        let json = try XCTUnwrap(answer, "the script gave nothing back")
        let lints = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
                                  "the answer isn't a list of lints: \(json)")
        XCTAssertFalse(lints.isEmpty, "Harper found nothing in \"\(text)\"")
        for lint in lints {
            let start = try XCTUnwrap(lint["start"] as? Int), end = try XCTUnwrap(lint["end"] as? Int)
            XCTAssertTrue(start >= 0 && start < end && end <= text.utf16.count, "a lint at \(start) to \(end)")
            XCTAssertNotNil(lint["message"] as? String)
            XCTAssertNotNil(lint["suggestions"] as? [Any])
        }
    }

    /// Writing turned on while a page is up (the setting changed, then the
    /// page told) puts writing.js into the document already there, the
    /// bridge before it: it is there in the app's world, takes the field
    /// focused before it came, and asks the Mac for that field's lints
    /// through the bridge, which Harper answers.
    func testTurningWritingOnPutsItIntoTheDocumentUp() async throws {
        setWriting(false)
        let page = makePage()
        await show(page, "Typed", body: "<textarea id=\"t\">This is an test.</textarea>")
        let before = try await inApp(page, bridged: false, "return typeof window.__egluWriting;")
        XCTAssertEqual(before, "undefined", "writing.js is in the page with writing off")
        let focused = try await inPage(page, """
            const field = document.getElementById('t');
            field.focus();
            return said(document.activeElement === field);
            """)
        XCTAssertEqual(focused, "true", "the field can't be focused here, so writing.js has none to check")

        setWriting(true)
        page.settingsChanged()
        await waitForScript(page, "writing.js in the document", "typeof window.__egluWriting === 'object'")
        await waitForScript(page, "the field's lints from the Mac", timeout: 60,
                            "window.__egluWriting.lints().length > 0")
    }

    /// A page loaded while writing is on has writing.js from its start, in
    /// the app's world and not the page's.
    func testAPageLoadedWithWritingOnHasIt() async throws {
        setWriting(true)
        let page = makePage()
        await load(page, "Checked")
        let app = try await inApp(page, bridged: false, "return typeof window.__egluWriting;")
        XCTAssertEqual(app, "object", "writing.js isn't in the app's world")
        let own = try await inPage(page, "return typeof window.__egluWriting;")
        XCTAssertEqual(own, "undefined", "writing.js is in the page's own world")
    }

    // MARK: The measuring tool

    /// The measuring tool started on a loaded page speaks through
    /// egluMeasure: a word for another run, or one that is no object,
    /// changes nothing; G pressed on the page switches its guides on, and
    /// what it says reaches the panel (MeasureModel.showsGuides). Stopped,
    /// the tool ends in the page.
    func testTheMeasuringToolSpeaksThroughItsChannel() async throws {
        let page = makePage()
        await load(page, "Measured")
        page.startMeasuring()
        let model = try XCTUnwrap(page.measure, "the tool didn't start")
        XCTAssertFalse(model.showsGuides)
        XCTAssertFalse(model.showsXray)
        await waitForScript(page, "the tool running", "window.__egluMeasure !== undefined")

        _ = try await inApp(page, """
            egluBridge.post('egluMeasure', {run: \(model.run + 1), kind: 'shown', guides: true, rulers: \(model.guides.rulers), xray: true});
            egluBridge.post('egluMeasure', 'shown');
            return 'posted';
            """)
        try await heardSoFar(page)
        XCTAssertFalse(model.showsGuides, "another run's word reached this run's panel")
        XCTAssertFalse(model.showsXray, "another run's word reached this run's panel")

        _ = try await inPage(page, """
            document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'g', bubbles: true, cancelable: true}));
            return 'pressed';
            """)
        await waitFor("the tool's word heard") { model.showsGuides }
        XCTAssertTrue(page.measure === model)
        XCTAssertFalse(model.showsXray)

        page.stopMeasuring()
        XCTAssertNil(page.measure)
        await waitForScript(page, "the tool ended in the page", "window.__egluMeasure === undefined")
    }

    // MARK: The handlers' checks

    /// A message whose body is no object is let go by its handler: the
    /// password watch's channel keeps what it had, Writing's answers nothing
    /// and changes nothing, and both still hear an object after.
    func testABodyThatIsNoObjectIsIgnored() async throws {
        let page = makePage()
        await show(page, "Odd", body: "<input type=\"password\">")
        await waitFor("the password field heard") { page.passwordField }
        _ = try await inApp(page, """
            for (const body of ['x', null, 0, true, [false], {present: 'no'}]) egluBridge.post('egluPassword', body);
            return 'posted';
            """)
        try await heardSoFar(page)
        XCTAssertTrue(page.passwordField, "a body that is no object changed what the page holds")
        _ = try await inApp(page, "egluBridge.post('egluPassword', {present: false}); return 'posted';")
        try await heardSoFar(page)
        XCTAssertFalse(page.passwordField, "the password watch's channel stopped hearing")

        page.writingCardOpen = true
        let odd = try await inApp(page, """
            const answers = [];
            for (const body of ['closed', null, 1, ['closed'], {kind: 1}]) {
              answers.push(said(await egluBridge.request('egluWriting', body)));
            }
            return said(answers);
            """)
        XCTAssertEqual(try strings(odd, "Writing's answers"), Array(repeating: "undefined", count: 5))
        XCTAssertTrue(page.writingCardOpen, "a body that is no object closed the card")
        let closed = try await askWriting(page, "{kind: 'closed'}")
        XCTAssertEqual(closed, "true")
        XCTAssertFalse(page.writingCardOpen)
    }

    /// A message from a frame inside the page isn't the main frame's, though
    /// it comes from the app's world: Writing answers it nothing and the
    /// password watch lets it go. The same messages from the main frame are
    /// heard.
    func testAFramesMessagesAreNotTheMainFrames() async throws {
        let page = makePage()
        await show(page, "Framed", body: "<iframe srcdoc=\"<p>Inside</p>\"></iframe>")
        await waitForScript(page, "the frame loaded",
                            "frames.length === 1 && frames[0].document.readyState === 'complete'")
        page.writingCardOpen = true

        let fromFrame = try await inApp(page, """
            const handlers = frames[0].webkit.messageHandlers;
            handlers.egluPassword.postMessage({present: true});
            return said(await handlers.egluWriting.postMessage({kind: 'closed'}));
            """)
        XCTAssertEqual(fromFrame, "undefined", "Writing answered a frame's message")
        XCTAssertTrue(page.writingCardOpen, "a frame's message closed the card")
        XCTAssertFalse(page.passwordField, "a frame's message was taken for the page's")

        let fromMain = try await inApp(page, """
            egluBridge.post('egluPassword', {present: true});
            return said(await egluBridge.request('egluWriting', {kind: 'closed'}));
            """)
        XCTAssertEqual(fromMain, "true")
        XCTAssertFalse(page.writingCardOpen)
        XCTAssertTrue(page.passwordField)
    }

    // MARK: Helpers

    /// The names of eGlu's channels on a Mac page, as a script's list.
    private static let channelNames = "['egluStore', 'egluPassword', 'egluWriting', 'egluMeasure', 'egluApplePasswords']"

    /// What a script's value is, as these tests compare it: its JSON, or
    /// "undefined".
    private static let said = "const said = (value) => value === undefined ? 'undefined' : JSON.stringify(value);"

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

    /// Writing on or off in the settings, never for other apps' fields.
    private func setWriting(_ on: Bool) {
        var preferences = Session.shared.preferences
        preferences.writing = on
        preferences.writingOtherApps = false
        Session.shared.preferences = preferences
    }

    /// `body` run as an async function in the app's own world of the page's
    /// main frame, egluBridge put in front of it unless `bridged` is false
    /// (it is already there in a document the page's scripts reached): what
    /// it returns, a string.
    private func inApp(_ page: Page, bridged: Bool = true, _ body: String) async throws -> String? {
        let script = (bridged ? WebKitScriptBridge.source + "\n" : "") + Self.said + "\n" + body
        return try await page.view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: Page.world) as? String
    }

    /// `body` run as an async function in the page's own world: what it
    /// returns, a string.
    private func inPage(_ page: Page, _ body: String) async throws -> String? {
        try await page.view.callAsyncJavaScript(Self.said + "\n" + body, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    /// Writing's channel asked `body` (a script's expression), as
    /// writing.js asks: its answer, as `said` puts it.
    private func askWriting(_ page: Page, _ body: String) async throws -> String? {
        try await inApp(page, "return said(await egluBridge.request('egluWriting', \(body)));")
    }

    /// One question on Writing's replying channel, which changes nothing,
    /// and its answer: every message the document posted before it has
    /// been heard by then.
    private func heardSoFar(_ page: Page, file: StaticString = #filePath, line: UInt = #line) async throws {
        let answer = try await askWriting(page, "{kind: 'eglu-tests-nothing'}")
        XCTAssertEqual(answer, "undefined", "Writing answered a question it doesn't know", file: file, line: line)
    }

    /// A script's JSON object, read.
    private func object(_ json: String?, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let text = try XCTUnwrap(json, "\(what): the script gave nothing back", file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                             "\(what): \(text)", file: file, line: line)
    }

    /// A script's JSON list of strings, read.
    private func strings(_ json: String?, _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let text = try XCTUnwrap(json, "\(what): the script gave nothing back", file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String],
                             "\(what): \(text)", file: file, line: line)
    }

    /// Waits, up to `timeout`, for `condition`, looked at every 20 ms: for
    /// what the page keeps, which WebKit doesn't report a change of.
    private func waitFor(_ what: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !condition() { XCTFail("\(what): not by \(timeout) s", file: file, line: line) }
    }

    /// Waits, up to `timeout`, for the script expression `condition` to be
    /// true in the app's own world, looked at every 50 ms.
    private func waitForScript(_ page: Page, _ what: String, timeout: TimeInterval = 10,
                               file: StaticString = #filePath, line: UInt = #line, _ condition: String) async {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let value = try? await page.view.callAsyncJavaScript("return !!(\(condition));", arguments: [:], in: nil,
                                                                 contentWorld: Page.world)
            if value as? Bool == true { return }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        XCTFail("\(what): not by \(timeout) s", file: file, line: line)
    }
}
