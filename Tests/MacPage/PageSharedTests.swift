import AppKit
import PadCore
import WebEngineCore
import WebKit
import WebKitSupport
import XCTest
@testable import eGluMac

/// What the code both apps share asks of a Mac page now that it imports no
/// WebKit (Docs/EngineSplitPlan.md, 7, step 12a), through a real `Page` and
/// real WebKit:
/// - the page's calls for that code: its address and title (`pageURL`,
///   `pageTitle`), its view's, read when asked; and a call in the app's own
///   world (`callInAppWorld`), out of the page's sight, given its
///   arguments, answering what its body returns, throwing what it throws;
/// - Handoff's reading of a plain article page through those calls
///   (`readingForHandoff`): the article as Markdown, the very reading
///   markdown.js gives called directly, and one cut short by a small limit;
/// - the filter scripts (`addFilterScripts`, WebKitSupport) put into the
///   page's own controller, two small ones of the test's own: the
///   blocker's in the app's world, the scriptlet's in the page's, each in
///   the main frame only; and what the page's own preparing (`Page.prepare`)
///   puts there for a site with no scripted filters, which is neither;
/// - each space's store through the contract `Stores` is given
///   (`WebSpaceStores`): WebKit's (`WebKitSpaceStores.shared`) answering as
///   `WebKitStores` does, and `Stores` asking a contract of the test's own
///   at each step of an erase and of the sweeps after it;
/// - WebKit's own spell checking through the engine
///   (`MacPageEngine.spellingFollows`, `WebKitSpelling`), given pages and
///   given none: in WebKit's preference both times, since the pages' views
///   don't answer WebKit's spelling getter on this macOS.
///
/// Every page is loaded from a string with no base, or is a data: page, in
/// a store that keeps nothing: no network. No script of the test's waits on
/// a timer, which a page out of sight has slowed. The spelling test runs
/// only in the test host (its identifier ends in `.pagetests`), and puts
/// both of WebKit's spelling preferences back as they were. The fresh
/// spaces are made only for the test; the workspace's spaces are only looked at.
///
/// Not here:
/// - A real transcript (`Page.transcript`): it needs a site of the network.
/// - A site with scripted filters through `Page.prepare`: the content
///   blocker's lists and its table of filters are its own to set
///   (`private(set)`), and its services do not start in the test host, so
///   it has neither; the method itself is shown with the test's scripts.
/// - The engine's own erase of a space's store
///   (`AppWebKitEngine.eraseStore(space:)`): PageStorageTests runs it on a
///   fresh space already, so only the contract it now goes through is here.
/// - A hands-off address (PadCore's tests cover `HandsOff`).
/// - WebKit's spell checking as the pages open now have it: a view answers
///   no getter for it (`isContinuousSpellCheckingEnabled`, read with
///   `value(forKey: "continuousSpellCheckingEnabled")`, which would raise),
///   so it can't be read, and `WebKitSpelling`'s path through a view's
///   action is never taken.
/// - The iOS app, which compiles the same shared code with its own `Page`,
///   and anything with a window on screen.
@MainActor
final class PageSharedTests: PageTestCase {
    /// A fresh space's store the test made and has not removed itself; removed after it.
    private var storeLeft: UUID?

    override func tearDown() async throws {
        if let space = storeLeft { await Self.cleanUp(space) }
        storeLeft = nil
        try await super.tearDown()
    }

    // MARK: The page's calls

    /// A page's address and title for the shared code are its view's, read
    /// when asked: before a load, after one from a string, and after the
    /// next, a data: page.
    func testThePagesAddressAndTitleAreItsViews() async throws {
        let page = makePage()
        XCTAssertEqual(page.pageURL, page.view.url)
        XCTAssertEqual(page.pageTitle, page.view.title)

        page.view.loadHTMLString(Self.html("Shared Calls"), baseURL: nil)
        await waitForPage(page, titled: "Shared Calls")
        let first = try XCTUnwrap(page.view.url, "the page loaded from a string has no address")
        XCTAssertEqual(page.pageURL, first)
        XCTAssertEqual(page.pageTitle, page.view.title)
        XCTAssertEqual(page.pageTitle, "Shared Calls")

        await load(page, "Next Shared Page")
        XCTAssertEqual(page.pageURL, page.view.url)
        XCTAssertEqual(page.pageURL?.scheme, "data", "the address is still the first page's")
        XCTAssertNotEqual(page.pageURL, first)
        XCTAssertEqual(page.pageTitle, page.view.title)
        XCTAssertEqual(page.pageTitle, "Next Shared Page")
    }

    /// A call in the app's own world (`Page.world`): a variable the page's
    /// own script set isn't seen there; one the call sets is, by the next
    /// call and by `Page.world` itself, and not by the page's world. The
    /// call is given its arguments and answers what its body returns,
    /// awaited; a body that throws, or a promise it returns that fails,
    /// makes it throw.
    func testACallInTheAppsWorldIsOutOfThePagesSight() async throws {
        let page = makePage()
        page.view.loadHTMLString(Self.html("App World", script: "window.egluTestsPageOwn = 'page';"), baseURL: nil)
        await waitForPage(page, titled: "App World")

        let pageSees = try await inPageWorld(page, "return typeof window.egluTestsPageOwn;")
        XCTAssertEqual(pageSees, "string", "the page's own script didn't run")
        let appSees = try await page.callInAppWorld("return typeof window.egluTestsPageOwn;", arguments: [:]) as? String
        XCTAssertEqual(appSees, "undefined", "the app's world sees the page's own variable")

        let set = try await page.callInAppWorld("window.egluTestsAppOwn = value; return window.egluTestsAppOwn;",
                                                arguments: ["value": "app"]) as? String
        XCTAssertEqual(set, "app")
        let again = try await page.callInAppWorld(
            "return typeof window.egluTestsAppOwn === 'string' ? window.egluTestsAppOwn : 'absent';", arguments: [:]) as? String
        XCTAssertEqual(again, "app", "the next call doesn't see what the first set")
        let world = try await page.view.callAsyncJavaScript("return typeof window.egluTestsAppOwn;", arguments: [:],
                                                            in: nil, contentWorld: Page.world) as? String
        XCTAssertEqual(world, "string", "the call wasn't in Page.world")
        let fromPage = try await inPageWorld(page, "return typeof window.egluTestsAppOwn;")
        XCTAssertEqual(fromPage, "undefined", "the page's world sees what the app's call set")

        let answer = try await page.callInAppWorld("""
            const doubled = await Promise.resolve(count * 2);
            return { doubled: doubled, word: word + '!', items: list.length, deep: options.deep };
            """, arguments: ["count": 21, "word": "shared", "list": ["a", "b", "c"], "options": ["deep": true]])
        let said = try XCTUnwrap(answer as? [String: Any], "the call answered \(String(describing: answer))")
        XCTAssertEqual(said["doubled"] as? Int, 42)
        XCTAssertEqual(said["word"] as? String, "shared!")
        XCTAssertEqual(said["items"] as? Int, 3)
        XCTAssertEqual(said["deep"] as? Bool, true)

        do {
            let thrown = try await page.callInAppWorld("throw new Error('eglu-tests: thrown');", arguments: [:])
            XCTFail("a body that throws answered \(String(describing: thrown))")
        } catch {
            XCTAssertEqual((error as NSError).domain, WKErrorDomain, "not WebKit's error: \(error)")
        }
        do {
            let failed = try await page.callInAppWorld("return Promise.reject(new Error('eglu-tests: failed'));", arguments: [:])
            XCTFail("a promise that fails answered \(String(describing: failed))")
        } catch {}
        let after = try await page.callInAppWorld("return 'still here';", arguments: [:]) as? String
        XCTAssertEqual(after, "still here", "the page's world stopped answering after a throw")
    }

    // MARK: Reading for Handoff

    /// Handoff's reading of a plain article page, loaded from a string with
    /// no base (which WebKit gives no response, so the page has no MIME
    /// type), goes through the page's call in the app's world: content,
    /// the article's heading and its paragraphs as Markdown, the very
    /// reading markdown.js gives called directly in that world; and with
    /// markdown.js's smallest limit, a reading cut short. A web page is read
    /// as no document, and nothing is written into the job's folder.
    func testHandoffReadsAnArticleAsMarkdownJSDoes() async throws {
        let page = makePage()
        page.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        page.view.loadHTMLString(Self.article, baseURL: nil)
        await waitForPage(page, titled: Self.articleTitle)
        XCTAssertNil(page.mimeType.flatMap { FileFormat(mimeType: $0) }, "the article is a document to the page")
        let folder = try folderOfOwn()

        let outcome = await page.readingForHandoff(limit: Handoff.limit, into: folder)
        guard case .content(let reading) = outcome else { return XCTFail("the article wasn't read: \(outcome)") }
        XCTAssertTrue(reading.blocks.contains { $0.text == "# " + Self.articleTitle }, "no heading in \(reading.text)")
        for paragraph in Self.paragraphs {
            XCTAssertTrue(reading.text.contains(paragraph), "a paragraph is missing from \(reading.text)")
        }
        XCTAssertFalse(reading.truncated, "the whole article didn't fit the limit")
        XCTAssertNil(page.handoffDocument, "the web page was read as a document")

        let said = try await page.view.callAsyncJavaScript(Scripts.markdownCall, arguments: ["limit": Handoff.limit],
                                                           in: nil, contentWorld: Page.world)
        let direct = try XCTUnwrap((said as? [String: Any]).flatMap { PageReading($0) }, "markdown.js read nothing")
        XCTAssertEqual(reading, direct, "Handoff's reading isn't markdown.js's")

        let cutOutcome = await page.readingForHandoff(limit: 200, into: folder)
        guard case .content(let cut) = cutOutcome else { return XCTFail("the article wasn't read at 200: \(cutOutcome)") }
        XCTAssertTrue(cut.truncated, "the smallest limit didn't cut the article")
        XCTAssertLessThan(cut.text.count, reading.text.count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [],
                       "reading a web page wrote into the job's folder")
    }

    // MARK: The filter scripts

    /// Two filter scripts of the test's own, each setting a global, put
    /// into the page's own controller after its first load: the controller
    /// has them last, at document start, for the main frame only. After the
    /// page's next load, the blocker's global is seen in the app's world and
    /// not the page's, the scriptlet's in the page's and not the app's, in
    /// the main frame; in a frame inside it (`iframe srcdoc`) neither world
    /// sees either, though scripts of the test's own for every frame report
    /// from both. The page's own preparing for that load, which found it
    /// already had the scripts it gives such a page, left them in.
    func testTheFilterScriptsGoIntoTheirWorldsInTheMainFrameOnly() async throws {
        let page = makePage()
        let controller = page.view.configuration.userContentController
        XCTAssertTrue(try kept("controller", of: page.enginePage, as: WKUserContentController.self) === controller,
                      "the page's controller isn't its view's")
        page.view.loadHTMLString(Self.html("Before Filters"), baseURL: nil)
        await waitForPage(page, titled: "Before Filters")
        let before = controller.userScripts.count

        controller.addFilterScripts(blocker: Self.blockerScript, scriptlets: Self.scriptletScript, appWorld: Page.world)
        XCTAssertEqual(controller.userScripts.count, before + 2, "not one script each")
        let added = Array(controller.userScripts.suffix(2))
        XCTAssertEqual(added.map(\.source), [Self.blockerScript, Self.scriptletScript], "not the scripts given, in order")
        XCTAssertTrue(added.allSatisfy { $0.injectionTime == .atDocumentStart && $0.isForMainFrameOnly },
                      "a filter script isn't at document start in the main frame only")

        // Scripts of the test's own, in every frame, one in each world: what each sees.
        let reports = FrameReports()
        for (name, world) in [("app", Page.world), ("page", WKContentWorld.page)] {
            controller.add(reports, contentWorld: world, name: FrameReports.name)
            controller.addUserScript(WKUserScript(source: FrameReports.script(world: name), injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: false, in: world))
        }
        defer {
            controller.removeScriptMessageHandler(forName: FrameReports.name, contentWorld: Page.world)
            controller.removeScriptMessageHandler(forName: FrameReports.name, contentWorld: .page)
        }
        XCTAssertEqual(controller.userScripts.count, before + 4)

        let reported = expectation(description: "both worlds of the page and of its frame reported")
        reported.expectedFulfillmentCount = 4
        reports.heard = { reported.fulfill() }
        page.view.loadHTMLString(Self.framed, baseURL: nil)
        await fulfillment(of: [reported], timeout: 10)
        await waitForPage(page, titled: "Filters")
        XCTAssertEqual(controller.userScripts.count, before + 4, "the page's preparing changed its scripts")
        XCTAssertEqual(Array(controller.userScripts.suffix(4).prefix(2)).map(\.source), [Self.blockerScript, Self.scriptletScript])

        XCTAssertEqual(reports.seen.count, 4, "reports: \(reports.seen)")
        for world in ["app", "page"] {
            let main = try XCTUnwrap(reports.seen.first { $0.world == world && $0.mainFrame }, "no main frame report from \(world)")
            XCTAssertEqual(main.text, "Filters")
            XCTAssertEqual(main.blocker, world == "app" ? "blocker" : "absent", "the blocker's global in the \(world) world")
            XCTAssertEqual(main.scriptlet, world == "page" ? "scriptlet" : "absent", "the scriptlet's global in the \(world) world")
            let inner = try XCTUnwrap(reports.seen.first { $0.world == world && !$0.mainFrame }, "no inner frame report from \(world)")
            XCTAssertEqual(inner.text, "Inside")
            XCTAssertEqual(inner.blocker, "absent", "the blocker ran in the inner frame's \(world) world")
            XCTAssertEqual(inner.scriptlet, "absent", "the scriptlet ran in the inner frame's \(world) world")
        }
    }

    /// The page's own preparing, for a page from a string and for a data:
    /// page, puts in its scripts but neither filter script: the test
    /// host's content blocker has no lists, so it has no scripted filters
    /// for any site (`scriptedRules(for:)` empty) and the page blocks
    /// nothing. The filter scripts are told by the start of blocker.js and
    /// scriptlets.js, which every script made from them begins with.
    func testThePagesPreparingAddsNoFilterScriptsForASiteWithNone() async throws {
        XCTAssertTrue(ContentBlocker.shared.lists.isEmpty, "the test host's content blocker has lists")
        let blockerStart = try XCTUnwrap(Scripts.blocker.components(separatedBy: Self.rulesMark).first)
        let scriptletsStart = try XCTUnwrap(Scripts.scriptlets.components(separatedBy: Self.rulesMark).first)
        XCTAssertGreaterThan(blockerStart.count, 200, "blocker.js has no rules mark where it was")
        XCTAssertGreaterThan(scriptletsStart.count, 200, "scriptlets.js has no rules mark where it was")
        var rules = PageRules()
        rules.css = ["#ad"]
        rules.run = [(name: "set-constant", arguments: ["egluTests", "1"])]
        XCTAssertEqual(Scripts.blocker(for: rules)?.hasPrefix(blockerStart), true)
        XCTAssertEqual(Scripts.scriptlets(for: rules)?.hasPrefix(scriptletsStart), true)
        XCTAssertNil(Scripts.blocker(for: PageRules()))
        XCTAssertNil(Scripts.scriptlets(for: PageRules()))

        let page = makePage()
        let controller = page.view.configuration.userContentController
        page.view.loadHTMLString(Self.html("No Filters"), baseURL: nil)
        await waitForPage(page, titled: "No Filters")
        await load(page, "Still No Filters")
        for url in [nil, page.view.url] {
            XCTAssertTrue(ContentBlocker.shared.scriptedRules(for: url).isEmpty, "scripted filters for \(String(describing: url))")
        }
        XCTAssertFalse(page.blocksContent)
        let sources = controller.userScripts.map(\.source)
        XCTAssertFalse(sources.isEmpty, "the page's preparing put in none of its scripts")
        XCTAssertFalse(sources.contains { $0.hasPrefix(blockerStart) }, "the page has the blocker's script")
        XCTAssertFalse(sources.contains { $0.hasPrefix(scriptletsStart) }, "the page has the scriptlets' script")
    }

    // MARK: Each space's store through the contract

    /// WebKit's stores as `Stores` asks for them answer as `WebKitStores`
    /// does, for a fresh space made only for the test: not made, made once
    /// WebKit's store is, not made once let go of through the contract, and
    /// removed from disk through it, after which neither has it. A space of
    /// the workspace is answered the same by both.
    func testWebKitsSpaceStoresAnswerAsWebKitStoresDo() async throws {
        let stores: any WebSpaceStores = WebKitSpaceStores.shared
        XCTAssertTrue(stores === WebKitSpaceStores.shared)
        if let space = Session.shared.workspace.spaces.first?.id {
            XCTAssertEqual(stores.isMade(space), WebKitStores.isMade(space))
        }
        let fresh = UUID()
        XCTAssertNil(Session.shared.workspace.space(fresh), "the fresh space is the workspace's")
        XCTAssertFalse(stores.isMade(fresh))
        XCTAssertFalse(WebKitStores.isMade(fresh))

        storeLeft = fresh
        autoreleasepool {
            let store = WebKitStores.store(for: fresh)
            XCTAssertEqual(store.identifier, fresh)
        }
        XCTAssertTrue(stores.isMade(fresh), "the contract doesn't see the store WebKit made")
        XCTAssertTrue(WebKitStores.isMade(fresh))

        stores.forget(fresh)
        XCTAssertFalse(stores.isMade(fresh), "the contract didn't let the store go")
        XCTAssertFalse(WebKitStores.isMade(fresh), "the contract let go of another store than WebKit's")

        stores.prepareForRemoval()
        var removed = false
        for _ in 0..<20 where !removed {
            removed = await withCheckedContinuation { done in
                stores.remove(fresh) { done.resume(returning: $0) }
            }
            if !removed { try? await Task.sleep(for: .milliseconds(500)) }
        }
        XCTAssertTrue(removed, "the contract didn't remove the store from disk")
        if removed { storeLeft = nil }
        XCTAssertFalse(stores.isMade(fresh))
        XCTAssertFalse(WebKitStores.isMade(fresh))
    }

    /// `Stores` asks the contract it is given, a spy of the test's own for
    /// a fresh space, and never WebKit's: an erase lets the store go and
    /// writes the space down under `stores.erasing` in the test host's
    /// preferences; the sweep two seconds later readies the stores and,
    /// told the store is still made, leaves it written down; a sweep told
    /// it isn't asks for the removal and, told it failed, still leaves it;
    /// one told it was removed takes it off.
    func testStoresAskTheContractTheyAreGiven() async throws {
        let host = try XCTUnwrap(Bundle.main.bundleIdentifier)
        guard host.hasSuffix(".pagetests") else {
            return XCTFail("not the test host, \(host): its preferences are not the run's own")
        }
        let fresh = UUID()
        XCTAssertNil(Session.shared.workspace.space(fresh), "the fresh space is the workspace's")
        XCTAssertFalse(Self.erasing.contains(fresh.uuidString))
        addTeardownBlock { @MainActor in
            if PageSharedTests.erasing.contains(fresh.uuidString) {
                UserDefaults.standard.set(PageSharedTests.erasing.filter { $0 != fresh.uuidString },
                                          forKey: PageSharedTests.erasingKey)
            }
        }
        let spy = SpyStores(space: fresh)
        spy.made = true

        Stores.erase(fresh, in: spy)
        let erased = Date()
        XCTAssertEqual(spy.asked, ["forget"])
        XCTAssertTrue(Self.erasing.contains(fresh.uuidString), "the erased space isn't written down")
        let kept = UserDefaults.standard.persistentDomain(forName: host)?[Self.erasingKey] as? [String]
        XCTAssertEqual(kept?.contains(fresh.uuidString), true, "not written down in the test host's own preferences")

        await waitFor("the sweep after the erase asked the contract", timeout: 20) { spy.asked.count >= 3 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(erased), 1.9, "the sweep came before its two seconds")
        XCTAssertEqual(spy.asked, ["forget", "prepare", "isMade"], "a store still made was asked to go")
        XCTAssertTrue(Self.erasing.contains(fresh.uuidString), "a store still made was taken off")

        spy.made = false
        spy.removes = false
        Stores.sweep(in: spy)
        XCTAssertEqual(spy.asked, ["forget", "prepare", "isMade", "prepare", "isMade", "remove"])
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(Self.erasing.contains(fresh.uuidString), "a store that wasn't removed was taken off")

        spy.removes = true
        Stores.sweep(in: spy)
        XCTAssertEqual(spy.asked.suffix(3), ["prepare", "isMade", "remove"])
        await waitFor("the removed store taken off \(Self.erasingKey)") { !Self.erasing.contains(fresh.uuidString) }
        XCTAssertFalse(WebKitStores.isMade(fresh), "WebKit's stores were asked for the spy's space")
    }

    // MARK: WebKit's spell checking

    /// WebKit's own spell checking through the engine, given two open
    /// pages and given none, the same both times: the pages' views answer
    /// WebKit's action (`toggleContinuousSpellChecking:`) but not its getter
    /// (`isContinuousSpellCheckingEnabled`), so `WebKitSpelling` finds no view
    /// to go through and writes WebKit's preference instead, as
    /// `WritingSpelling` did. Writing turned on writes spell checking off
    /// and, in the test host's own preferences, that it was on; on again,
    /// what it was stays written; off, it is written back on and the note
    /// removed; off again, nothing changes. Started from off, it stays off
    /// and comes back off; with nothing written, it counts as on.
    func testSpellingFollowsWritingInWebKitsPreference() async throws {
        let host = try spellingHost()
        let page = makePage()
        let other = makePage()
        await load(page, "Spelling")
        await load(other, "Other Spelling")
        keepSpellingPreferences()
        XCTAssertTrue(page.view.responds(to: Self.toggle), "the page's view doesn't answer WebKit's spelling action")
        XCTAssertFalse(page.view.responds(to: Self.isOn),
                       "the page's view answers WebKit's spelling getter: WebKitSpelling now goes through the view, not its preference")
        let engine = Session.shared.engine
        let defaults = UserDefaults.standard

        let cases: [(String, [Page])] = [("two pages", [page, other]), ("no page", [])]
        for (given, pages) in cases {
            defaults.set(true, forKey: Self.spellingKey)
            defaults.removeObject(forKey: Self.wasKey)
            engine.spellingFollows(writing: true, pages: pages)
            XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, false, "\(given): spell checking still on")
            XCTAssertEqual(defaults.object(forKey: Self.wasKey) as? Bool, true, "\(given): that it was on isn't written down")
            XCTAssertEqual(defaults.persistentDomain(forName: host)?[Self.wasKey] as? Bool, true,
                           "\(given): not written down in the test host's own preferences")

            engine.spellingFollows(writing: true, pages: pages)
            XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, false, given)
            XCTAssertEqual(defaults.object(forKey: Self.wasKey) as? Bool, true, "\(given): a second turn on wrote over what it was")

            engine.spellingFollows(writing: false, pages: pages)
            XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, true, "\(given): spell checking didn't come back")
            XCTAssertNil(defaults.object(forKey: Self.wasKey), "\(given): the note of what it was is still there")

            engine.spellingFollows(writing: false, pages: pages)
            XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, true, "\(given): a second turn off changed it")
            XCTAssertNil(defaults.object(forKey: Self.wasKey), given)

            defaults.set(false, forKey: Self.spellingKey)
            engine.spellingFollows(writing: true, pages: pages)
            XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, false, given)
            XCTAssertEqual(defaults.object(forKey: Self.wasKey) as? Bool, false, "\(given): that it was off isn't written down")
            engine.spellingFollows(writing: false, pages: pages)
            XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, false, "\(given): spell checking that was off came back on")
            XCTAssertNil(defaults.object(forKey: Self.wasKey), given)

            defaults.removeObject(forKey: Self.spellingKey)
            if defaults.object(forKey: Self.spellingKey) == nil {
                engine.spellingFollows(writing: true, pages: pages)
                XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, false, given)
                XCTAssertEqual(defaults.object(forKey: Self.wasKey) as? Bool, true, "\(given): nothing written didn't count as on")
                engine.spellingFollows(writing: false, pages: pages)
                XCTAssertEqual(defaults.object(forKey: Self.spellingKey) as? Bool, true, given)
                XCTAssertNil(defaults.object(forKey: Self.wasKey), given)
            }
        }
    }

    // MARK: Helpers

    /// A page named `title`, with a script of its own if one is given.
    private static func html(_ title: String, script: String? = nil) -> String {
        "<!doctype html><title>\(title)</title>" + (script.map { "<script>\($0)</script>" } ?? "") + "<p>\(title)</p>"
    }

    private static let articleTitle = "A Walk by the River"
    private static let paragraphs = [
        "The path along the river begins at the old mill, where the water runs fast over the stones and the "
            + "willows lean out above it. In the morning the light comes low across the fields, and the walk to the "
            + "first bridge takes about twenty minutes at an easy pace.",
        "Past the bridge the river widens and slows, and the path climbs a little through a wood of oak and ash. "
            + "There are benches at the top of the rise, and from there the whole valley can be seen, with the "
            + "village roofs and the church tower a mile or so beyond the water meadows.",
        "The way back follows the other bank, through the meadows and past the boathouse, and comes into the "
            + "village by the green. Altogether the walk is a little over five miles, and it can be done in an "
            + "afternoon with time to stop along the way.",
    ]

    /// A plain article page: a heading and three paragraphs.
    private static var article: String {
        "<!doctype html><html lang=\"en\"><title>\(articleTitle)</title><body><article><h1>\(articleTitle)</h1>"
            + paragraphs.map { "<p>\($0)</p>" }.joined() + "</article></body></html>"
    }

    /// The test's own filter scripts, each setting a global.
    private static let blockerScript = "globalThis.egluTestsBlocker = 'blocker';"
    private static let scriptletScript = "globalThis.egluTestsScriptlet = 'scriptlet';"

    /// A page with a frame inside it, from its own `srcdoc`.
    private static let framed = "<!doctype html><title>Filters</title><body><p>Filters</p>"
        + "<iframe srcdoc=\"<!doctype html><title>Inside</title><body><p>Inside</p></body>\"></iframe></body>"

    /// Where blocker.js and scriptlets.js have their rules written in (Scripts.rulesMark).
    private static let rulesMark = "/*RULES*/null"

    /// What the script says, run in the page's own world.
    private func inPageWorld(_ page: Page, _ body: String) async throws -> String? {
        try await page.view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    /// A folder of the test's own in the test run's data folder (never the
    /// person's), removed after the test.
    private func folderOfOwn(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let root = try XCTUnwrap(Session.dataRootOverride, "the test host has no data folder of its own",
                                 file: file, line: line)
        XCTAssertEqual(Session.folder, root, file: file, line: line)
        XCTAssertFalse(root.path.contains("Application Support/Safience"), "the data folder is \(root.path)",
                       file: file, line: line)
        let folder = root.appendingPathComponent("eglu-tests-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the test's folder is still there")
        }
        return folder
    }

    /// The preference the app writes removed spaces' stores down under (Stores).
    fileprivate static let erasingKey = "stores.erasing"

    /// The spaces written down for their stores' removal, in the test host's preferences.
    fileprivate static var erasing: [String] {
        UserDefaults.standard.stringArray(forKey: erasingKey) ?? []
    }

    /// The fresh space's store the test made gone, as PageStorageTests
    /// leaves one: taken off `stores.erasing`, let go of and removed, tried
    /// for a few seconds while WebKit still holds it.
    private static func cleanUp(_ space: UUID) async {
        let listed = erasing.contains(space.uuidString)
        if listed { UserDefaults.standard.set(erasing.filter { $0 != space.uuidString }, forKey: erasingKey) }
        WebKitStores.forget(space)
        WebKitStores.prepareForRemoval()
        for _ in 0..<20 {
            let removed = await withCheckedContinuation { done in
                WebKitStores.remove(space) { done.resume(returning: $0) }
            }
            if removed { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("the test's store \(space) is still on disk")
    }

    /// WebKit's own spell checking setting, in its defaults (WebKitSpelling).
    private static let spellingKey = "WebContinuousSpellCheckingEnabled"
    /// What it was before writing took over (WebKitSpelling).
    private static let wasKey = "egluSpellingBeforeWriting"
    private static let isOn = #selector(getter: NSTextView.isContinuousSpellCheckingEnabled)
    private static let toggle = #selector(NSTextView.toggleContinuousSpellChecking(_:))

    /// The test host's identifier; the test is skipped in any other app,
    /// whose preferences are not the run's own.
    private func spellingHost() throws -> String {
        let host = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try XCTSkipUnless(host.hasSuffix(".pagetests"), "not the test host, \(host): its preferences are not the run's own")
        return host
    }

    /// Both of WebKit's spelling preferences as the test host's own domain
    /// has them, put back after the test.
    private func keepSpellingPreferences() {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let spellingBefore = domain[Self.spellingKey]
        let wasBefore = domain[Self.wasKey]
        addTeardownBlock { @MainActor in
            for (key, value) in [(Self.spellingKey, spellingBefore), (Self.wasKey, wasBefore)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            let after = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
            XCTAssertEqual(after[Self.spellingKey] as? Bool, spellingBefore as? Bool, "\(Self.spellingKey) wasn't put back")
            XCTAssertEqual(after[Self.wasKey] as? Bool, wasBefore as? Bool, "\(Self.wasKey) wasn't put back")
        }
    }

    /// A value `subject` keeps to itself, read by its name.
    private func kept<T>(_ name: String, of subject: Any, as type: T.Type = T.self,
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let child = try XCTUnwrap(Mirror(reflecting: subject).children.first { $0.label == name },
                                  "\(Swift.type(of: subject)) keeps no \(name)", file: file, line: line)
        return try XCTUnwrap(child.value as? T, "\(name) is a \(Swift.type(of: child.value))", file: file, line: line)
    }

    /// Waits, up to `timeout`, for `condition`, looked at every 20 ms: for
    /// what WebKit doesn't report a change of.
    private func waitFor(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath,
                         line: UInt = #line, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "\(what): not by \(timeout) s", file: file, line: line)
    }
}

/// What a script of the test's own, in every frame of a page and one
/// world, says it sees: which world and frame it is, the frame's text, and
/// the filter scripts' globals, or "absent".
@MainActor
private final class FrameReports: NSObject, WKScriptMessageHandler {
    static let name = "egluTestsFrames"

    struct Seen {
        let world: String
        let mainFrame: Bool
        let text: String
        let blocker: String
        let scriptlet: String
    }

    private(set) var seen: [Seen] = []
    var heard: (() -> Void)?

    /// The script for the world named `world`, run at document end.
    static func script(world: String) -> String {
        """
        window.webkit.messageHandlers.\(name).postMessage({
          world: '\(world)',
          text: document.body ? document.body.textContent.trim() : '',
          blocker: typeof globalThis.egluTestsBlocker === 'string' ? globalThis.egluTestsBlocker : 'absent',
          scriptlet: typeof globalThis.egluTestsScriptlet === 'string' ? globalThis.egluTestsScriptlet : 'absent'
        });
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let world = body["world"] as? String,
              let text = body["text"] as? String, let blocker = body["blocker"] as? String,
              let scriptlet = body["scriptlet"] as? String else {
            return XCTFail("a frame's report isn't what the test's script sends: \(message.body)")
        }
        seen.append(Seen(world: world, mainFrame: message.frameInfo.isMainFrame, text: text,
                         blocker: blocker, scriptlet: scriptlet))
        heard?()
    }
}

/// The contract `Stores` is given, as a spy of the test's own for one
/// space: says what it was asked of that space, and answers as the test
/// sets it. Any other space written down is answered as still made, so a
/// sweep leaves it as it is.
@MainActor
private final class SpyStores: WebSpaceStores {
    let space: UUID
    /// Whether the space's store is still made.
    var made = false
    /// Whether a removal of the space's store succeeds.
    var removes = false
    private(set) var asked: [String] = []

    init(space: UUID) {
        self.space = space
    }

    func isMade(_ space: UUID) -> Bool {
        guard space == self.space else { return true }
        asked.append("isMade")
        return made
    }

    func forget(_ space: UUID) {
        guard space == self.space else { return }
        asked.append("forget")
    }

    func prepareForRemoval() {
        asked.append("prepare")
    }

    func remove(_ space: UUID, removed: @escaping @MainActor (Bool) -> Void) {
        guard space == self.space else { return removed(false) }
        asked.append("remove")
        removed(removes)
    }
}
