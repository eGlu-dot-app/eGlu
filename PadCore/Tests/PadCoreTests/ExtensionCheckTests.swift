import XCTest
@testable import PadCore

final class ExtensionCheckTests: XCTestCase {
    /// A worker's socket, made by eGlu, goes only where the extension's
    /// own policy would let it connect.
    func testAConnectionFollowsTheExtensionsPolicy() {
        let socket = URL(string: "wss://push.example.com/feed")!
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: nil))
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: "script-src 'self'; object-src 'self'"))
        XCTAssertFalse(ExtensionPolicy.allowsConnection(to: socket, policy: "script-src 'self'; connect-src 'self'"))
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src 'self' wss://push.example.com"))
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src *.example.com"))
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src https:"))
        XCTAssertFalse(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src https://other.example"))
        XCTAssertFalse(ExtensionPolicy.allowsConnection(to: socket, policy: "default-src 'none'"))
        XCTAssertFalse(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src push.example.com:8443"))
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src *"))
        // A path in a source holds the connection to it, as WebKit holds the extension's own.
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src wss://push.example.com/feed"))
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src wss://push.example.com/"))
        XCTAssertFalse(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src wss://push.example.com/allowed/"))
        XCTAssertFalse(ExtensionPolicy.allowsConnection(to: socket, policy: "connect-src wss://push.example.com/fee"))
        XCTAssertTrue(ExtensionPolicy.allowsConnection(to: URL(string: "wss://push.example.com/allowed/one")!,
                                                       policy: "connect-src wss://push.example.com/allowed/"))
    }

    /// A website sends its tab only to an extension page that page shows
    /// websites, and only to the sites it names.
    func testAWebsiteReachesOnlyAnExtensionsWebAccessiblePages() {
        let manifest: [String: Any] = ["manifest_version": 3, "web_accessible_resources": [
            ["resources": ["auth/*.html", "return.html"], "matches": ["https://*.nordpass.com/*"]],
            ["resources": ["open.html"], "matches": ["<all_urls>"]],
        ]]
        let site = URL(string: "https://app.nordpass.com/")!
        let page = { URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/" + $0)! }
        XCTAssertTrue(ExtensionPolicy.webAccessible(page("return.html"), from: site, manifest: manifest))
        XCTAssertTrue(ExtensionPolicy.webAccessible(page("auth/done.html?code=1"), from: site, manifest: manifest))
        XCTAssertTrue(ExtensionPolicy.webAccessible(page("open.html"), from: URL(string: "https://example.com/")!, manifest: manifest))
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("vault.html"), from: site, manifest: manifest), "a page it doesn't show websites")
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("return.html"), from: URL(string: "https://evil.example/")!, manifest: manifest), "another site")
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("return.html"), from: URL(string: "http://app.nordpass.com/")!, manifest: manifest), "not https")
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("auth/..%2Fvault.html"), from: site, manifest: manifest), "an encoded slash")
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("auth/../vault.html"), from: site, manifest: manifest), "a dot segment")
        XCTAssertFalse(ExtensionPolicy.webAccessible(URL(string: "https://app.nordpass.com/return.html")!, from: site, manifest: manifest), "not an extension page")
        let dynamic: [String: Any] = ["manifest_version": 3, "web_accessible_resources": [
            ["resources": ["return.html"], "matches": ["<all_urls>"], "use_dynamic_url": true]]]
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("return.html"), from: site, manifest: dynamic), "a dynamic address isn't read here")
        let old: [String: Any] = ["manifest_version": 2, "web_accessible_resources": ["pages/*"]]
        XCTAssertTrue(ExtensionPolicy.webAccessible(page("pages/a.html"), from: site, manifest: old))
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("popup.html"), from: site, manifest: old))
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("return.html"), from: site, manifest: ["manifest_version": 3]), "no list, no page")
    }

    /// An extension's own rule sending the tab to its page: http sites
    /// count, by their scheme, and a dynamic address is shown.
    func testARulesRedirectReachesWhatTheExtensionShowsTheSite() {
        let manifest: [String: Any] = ["manifest_version": 3, "web_accessible_resources": [
            ["resources": ["blocked.html"], "matches": ["*://*/*"]],
            ["resources": ["strict.html"], "matches": ["<all_urls>"], "use_dynamic_url": true],
            ["resources": ["secure.html"], "matches": ["https://*/*"]],
        ]]
        let page = { URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/" + $0)! }
        let http = URL(string: "http://instagram.com/")!
        XCTAssertTrue(ExtensionPolicy.webAccessible(page("blocked.html"), from: http, manifest: manifest, fromRule: true))
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("blocked.html"), from: http, manifest: manifest), "a site's own navigation: https only")
        XCTAssertTrue(ExtensionPolicy.webAccessible(page("strict.html"), from: http, manifest: manifest, fromRule: true))
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("strict.html"), from: URL(string: "https://a.example/")!, manifest: manifest), "dynamic: only a rule's")
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("secure.html"), from: http, manifest: manifest, fromRule: true), "listed for https only")
        XCTAssertFalse(ExtensionPolicy.webAccessible(page("vault.html"), from: http, manifest: manifest, fromRule: true))
    }

    func testARulesRedirectGetsItsQueryAndFragmentBack() {
        let escaped = URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/blocked.html%3Fsite=x%23top")!
        XCTAssertEqual(ExtensionPolicy.ruleTarget(escaped).absoluteString, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/blocked.html?site=x#top")
        let hashed = URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/blocked.html%23instagram.com")!
        XCTAssertEqual(ExtensionPolicy.ruleTarget(hashed).absoluteString, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/blocked.html#instagram.com")
        let plain = URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/blocked.html?a=1")!
        XCTAssertEqual(ExtensionPolicy.ruleTarget(plain), plain)
    }

    func testTheShimsListWhatTheyAnswer() {
        XCTAssertEqual(ExtensionAPITable.shims["sidePanel"], .shim)
        XCTAssertEqual(ExtensionAPITable.shims["offscreen"], .shim)
        XCTAssertEqual(ExtensionAPITable.shims["tabCapture"], .refused)
    }

    func testWhatThePasswordManagersReachForIsListedAsItIs() {
        let table = ExtensionAPITable(webKit: ["webNavigation": ["onBeforeNavigate", "getAllFrames"]], shims: ExtensionAPITable.shims)
        XCTAssertEqual(table.answer(for: "webNavigation.onHistoryStateUpdated"), .stub, "there to listen to, never fired")
        XCTAssertEqual(table.answer(for: "webNavigation.onBeforeNavigate"), .native)
        XCTAssertTrue(table.works("privacy.services.passwordSavingEnabled"), "read as eGlu has it")
        XCTAssertTrue(table.works("notifications.create"), "macOS delivers notifications")
        XCTAssertEqual(table.missing(asked: ["privacy", "notifications", "webNavigation"], kept: ["privacy", "notifications", "webNavigation"]),
                       [])
    }

    func testWhatInstallingAllowsIsWrittenDown() throws {
        let manifest = try ExtensionManifest(json: Data(#"""
        {"manifest_version": 3, "name": "N", "version": "1", "permissions": ["storage", "tabs"],
         "host_permissions": ["https://a.example/*"],
         "content_scripts": [{"matches": ["https://b.example/*", "https://a.example/*"], "js": ["c.js"]}]}
        """#.utf8))
        XCTAssertEqual(manifest.grants, ["site:https://a.example/*", "site:https://b.example/*", "storage", "tabs"])
    }

    // MARK: The manifest

    func testAManifestWithCommentsReadsAsChromeReadsIt() throws {
        let json = """
        \u{FEFF}{
          // Chrome allows comments.
          "manifest_version": 2,
          "name": "Old one", /* and these */
          "version": "1.0",
          "permissions": ["storage", "tabs", "<all_urls>", "https://*.example.com/*", "webRequestBlocking"],
          "background": {"scripts": ["bg.js"]},
          "browser_action": {"default_popup": "popup.html"},
          "options_page": "options.html",
          "content_scripts": [{"matches": ["<all_urls>"], "js": ["a.js"], "all_frames": true}],
          "description": "A // that isn't a comment"
        }
        """
        let manifest = try ExtensionManifest(json: Data(json.utf8))
        XCTAssertEqual(manifest.manifestVersion, 2)
        XCTAssertEqual(manifest.permissions, ["storage", "tabs", "webRequestBlocking"])
        XCTAssertEqual(manifest.hostPermissions, ["<all_urls>", "https://*.example.com/*"], "Manifest V2's sites are among its permissions")
        XCTAssertEqual(manifest.background, .scripts(["bg.js"], persistent: true), "no persistent key is persistent")
        XCTAssertEqual(manifest.popup, "popup.html")
        XCTAssertEqual(manifest.optionsPage, "options.html")
        XCTAssertEqual(manifest.contentScripts.first?.allFrames, true)
        XCTAssertEqual(manifest.contentScripts.first?.world, "ISOLATED")
        XCTAssertEqual(manifest.files, ["bg.js", "a.js", "popup.html", "options.html"])
    }

    func testAManifestV3ExtensionsWorkerAndPages() throws {
        let json = """
        {"manifest_version": 3, "name": "New", "version": "2.1",
         "permissions": ["sidePanel", "offscreen", "identity"], "optional_permissions": ["bookmarks"],
         "host_permissions": ["<all_urls>"],
         "background": {"service_worker": "sw.js", "type": "module"},
         "action": {"default_popup": "p.html"}, "options_ui": {"page": "o.html"},
         "side_panel": {"default_path": "panel.html"}, "oauth2": {"client_id": "x"}}
        """
        let manifest = try ExtensionManifest(json: Data(json.utf8))
        XCTAssertEqual(manifest.background, .worker("sw.js", module: true))
        XCTAssertEqual(manifest.sidePanel, "panel.html")
        XCTAssertTrue(manifest.usesChromeSignIn)
        XCTAssertEqual(manifest.dropped(kept: ["identity"]), ["sidePanel", "offscreen", "bookmarks"],
                       "what WebKit didn't keep, optional ones included")
    }

    func testAManifestWithoutAVersionIsRefused() {
        XCTAssertThrowsError(try ExtensionManifest(json: Data(#"{"name": "x"}"#.utf8)))
        XCTAssertThrowsError(try ExtensionManifest(json: Data("not json".utf8)))
    }

    // MARK: The table

    func testTheTableIsTheMacsWebKitWithTheShimsOnTop() {
        let table = ExtensionAPITable(
            webKit: ["tabs": ["query", "create"], "storage": ["local"]],
            shims: ["sidePanel": .shim, "identity": .part, "identity.getAuthToken": .refused,
                    "identity.launchWebAuthFlow": .shim, "contentSettings": .stub, "tabs": .shim]
        )
        XCTAssertEqual(table.answer(for: "tabs"), .native, "WebKit's own wins over a shim")
        XCTAssertEqual(table.answer(for: "tabs.query"), .native)
        XCTAssertNil(table.answer(for: "tabs.discard"), "a member WebKit's tabs lacks")
        XCTAssertEqual(table.answer(for: "sidePanel.open"), .shim)
        XCTAssertTrue(table.works("identity.launchWebAuthFlow"))
        XCTAssertFalse(table.works("identity.getAuthToken"))
        XCTAssertFalse(table.works("contentSettings.set"), "a stub does nothing")
        XCTAssertFalse(table.works("tabCapture"))
    }

    func testWhatNothingAnswersIsMissingThoughWebKitKeptItsPermission() {
        let table = ExtensionAPITable(webKit: ["tabs": ["query"], "storage": ["local"], "declarativeNetRequest": []],
                                      shims: ExtensionAPITable.shims)
        let asked = ["tabs", "storage", "notifications", "sidePanel", "declarativeNetRequestWithHostAccess",
                     "webRequestBlocking", "unlimitedStorage", "cookies", "history"]
        // WebKit kept notifications, unlimitedStorage and the rest; it dropped history and webRequestBlocking.
        let kept: Set<String> = ["tabs", "storage", "notifications", "declarativeNetRequestWithHostAccess", "unlimitedStorage", "cookies"]
        XCTAssertEqual(table.missing(asked: asked, kept: kept), ["webRequestBlocking"],
                       "a kept permission whose namespace isn't there counts; a shim's doesn't; cookies is the hands-off rules'")
    }

    // MARK: Reading the code

    private let missing: Set<String> = ["tabCapture", "identity.getAuthToken", "history", "sidePanel"]

    func testAPlainUseIsFoundAndATestIsNot() {
        let code = """
        chrome.tabCapture.capture({audio: true}, s => {});
        if (chrome.sidePanel) { chrome.sidePanel.open({}); }
        """
        let uses = ExtensionScan.uses(in: code, file: "bg.js", of: missing)
        XCTAssertEqual(uses.map(\.path), ["tabCapture", "sidePanel", "sidePanel"])
        XCTAssertEqual(uses.first { $0.path == "tabCapture" }?.tested, false)
        XCTAssertTrue(uses.filter { $0.path == "sidePanel" }.allSatisfy(\.tested), "the test guards the use after it")
        XCTAssertEqual(uses.first?.line, 1)
    }

    func testTheWaysCodeTestsForAnAPI() {
        for code in [
            "typeof chrome.tabCapture !== 'undefined'",
            "e.tabCapture?.capture()",
            "const ok = !!t.tabCapture",
            "x.tabCapture && x.tabCapture.capture()",
            "if ('tabCapture' in chrome) {}",
            "while (chrome.tabCapture) {}",
            "chrome.tabCapture ? a() : b()",
            "typeof chrome['tabCapture']",
        ] {
            let uses = ExtensionScan.uses(in: code, file: "a.js", of: missing)
            XCTAssertFalse(uses.isEmpty, code)
            XCTAssertTrue(uses.allSatisfy(\.tested), code)
        }
    }

    func testMinifiedCodeIsReadUnderAnyName() {
        let uses = ExtensionScan.uses(in: "n.tabCapture.capture(o);e[\"sidePanel\"].open()", file: "min.js", of: missing)
        XCTAssertEqual(uses.map(\.path), ["tabCapture", "sidePanel"])
        XCTAssertTrue(uses.allSatisfy { !$0.tested })
    }

    func testStringsCommentsAndRegexAreNotCode() {
        let code = """
        // chrome.tabCapture.capture()
        /* chrome.tabCapture.capture() */
        const s = "chrome.tabCapture.capture()";
        const t = `chrome.tabCapture.capture()`;
        const r = /chrome.tabCapture.capture/g;
        """
        XCTAssertEqual(ExtensionScan.uses(in: code, file: "a.js", of: missing), [])
    }

    func testACommonNameCountsOnlyAsChromes() {
        // window.history is the web's; chrome.history and history.search are Chrome's.
        XCTAssertEqual(ExtensionScan.uses(in: "window.history.back(); location.history", file: "a.js", of: missing), [])
        XCTAssertEqual(ExtensionScan.uses(in: "chrome.history.search({text: ''})", file: "a.js", of: missing).map(\.path), ["history"])
        XCTAssertEqual(ExtensionScan.uses(in: "e.history.getVisits({url})", file: "a.js", of: missing).map(\.path), ["history"])
    }

    func testAMissingMemberOfANamespaceThatWorks() {
        let uses = ExtensionScan.uses(in: "chrome.identity.launchWebAuthFlow(o); chrome.identity.getAuthToken({interactive: true})",
                                      file: "a.js", of: missing)
        XCTAssertEqual(uses.map(\.path), ["identity.getAuthToken"])
        XCTAssertEqual(uses.first?.tested, false)
    }

    func testANameOnItsOwnIsntChromes() {
        XCTAssertEqual(ExtensionScan.uses(in: "const sidePanel = 1; sidePanel.open()", file: "a.js", of: missing), [])
    }

    func testAWebAPIsNameIsFoundUsedAlone() {
        let missing = missing.union(["EyeDropper"])
        // Mesurer's colour tool reads it off the page's window.
        XCTAssertEqual(ExtensionScan.uses(in: "let u = e.EyeDropper; new u().open()", file: "a.js", of: missing).map(\.path), ["EyeDropper"])
        XCTAssertEqual(ExtensionScan.uses(in: "new EyeDropper().open()", file: "a.js", of: missing).map(\.path), ["EyeDropper"])
        XCTAssertEqual(ExtensionScan.uses(in: "if (typeof EyeDropper !== 'undefined') pick()", file: "a.js", of: missing).first?.tested, true)
        // Declared or an object's key, it isn't the API's.
        XCTAssertEqual(ExtensionScan.uses(in: "const EyeDropper = mine; const o = { EyeDropper: 1 }", file: "a.js", of: missing), [])
        // Not missing, its bare uses are nobody's.
        XCTAssertEqual(ExtensionScan.uses(in: "new EyeDropper().open()", file: "a.js", of: missing.subtracting(["EyeDropper"])), [])
    }

    func testAnArrayOfNamesIsntAUse() {
        XCTAssertEqual(ExtensionScan.uses(in: "const panels=[\"sidePanel\"];", file: "a.js", of: missing), [])
        XCTAssertEqual(ExtensionScan.uses(in: "f([\"tabCapture\", 1])", file: "a.js", of: missing), [])
    }

    func testNotOrVoidBeforeACallIsntATest() {
        for code in ["void chrome.sidePanel.open({});", "!chrome.sidePanel.open()", "typeof chrome.sidePanel.open"] {
            let uses = ExtensionScan.uses(in: code, file: "a.js", of: missing)
            XCTAssertEqual(uses.map(\.path), ["sidePanel"], code)
            XCTAssertEqual(uses.first?.tested, false, "the call throws all the same: \(code)")
        }
    }

    func testARegularExpressionAfterAConditionIsntCode() {
        XCTAssertEqual(ExtensionScan.uses(in: "if(ok)/chrome.sidePanel.open/.test(text);", file: "a.js", of: missing), [])
        XCTAssertEqual(ExtensionScan.uses(in: "while (x) /chrome.tabCapture/g.exec(s)", file: "a.js", of: missing), [])
        // A call's closing parenthesis still divides: f(x) / chrome.tabCapture.n
        XCTAssertEqual(ExtensionScan.uses(in: "f(x) / chrome.tabCapture.n", file: "a.js", of: missing).map(\.path), ["tabCapture"])
    }

    func testCodeInATemplateIsRead() {
        let uses = ExtensionScan.uses(in: "const text = `id: ${chrome.tabCapture.capture({a: {b: 1}})} and chrome.sidePanel`;", file: "a.js", of: missing)
        XCTAssertEqual(uses.map(\.path), ["tabCapture"], "the template's own text is not code")
        XCTAssertEqual(uses.first?.tested, false)
    }

    func testDivisionIsntARegularExpression() {
        let uses = ExtensionScan.uses(in: "const a = b / 2; chrome.tabCapture.capture(); const c = d / e;", file: "a.js", of: missing)
        XCTAssertEqual(uses.map(\.path), ["tabCapture"])
    }

    // MARK: Errors

    /// What nothing on this Mac answers, for the error tests.
    private let lacking: Set<String> = ["sidePanel", "notifications", "tabs.discard"]

    func testJavaScriptCoresWordingNamesTheAPI() {
        XCTAssertEqual(ExtensionError.problem(in: "TypeError: undefined is not an object (evaluating 'e.sidePanel.open')", missing: lacking),
                       ExtensionError.Problem(kind: .missing, api: "sidePanel"))
        XCTAssertEqual(ExtensionError.problem(in: "TypeError: chrome.tabs.discard is not a function. (In 'chrome.tabs.discard(1)', 'chrome.tabs.discard' is undefined)", missing: lacking),
                       ExtensionError.Problem(kind: .notAFunction, api: "tabs.discard"))
        XCTAssertEqual(ExtensionError.problem(in: "Invalid call to tabs.query(). The 'queryInfo' value is invalid.", missing: lacking),
                       ExtensionError.Problem(kind: .wrongArguments, api: "tabs.query"))
        XCTAssertEqual(ExtensionError.problem(in: "ReferenceError: Can't find variable: chrome", missing: lacking),
                       ExtensionError.Problem(kind: .missing, api: "chrome"))
        XCTAssertEqual(ExtensionError.problem(in: "ReferenceError: Can't find variable: EyeDropper", missing: lacking.union(["EyeDropper"])),
                       ExtensionError.Problem(kind: .missing, api: "EyeDropper"),
                       "a web API nothing answers is named too")
        XCTAssertNil(ExtensionError.problem(in: "ReferenceError: Can't find variable: EyeDropper", missing: lacking),
                     "kept only while it is missing")
    }

    func testAMinifiedNameCountsOnlyForWhatIsMissing() {
        XCTAssertEqual(ExtensionError.problem(in: "TypeError: e.tabs.discard is not a function. (In 'e.tabs.discard(1)', 'e.tabs.discard' is undefined)", missing: lacking),
                       ExtensionError.Problem(kind: .notAFunction, api: "tabs.discard"))
        // The extension's own state, whose field happens to be called tabs.
        XCTAssertNil(ExtensionError.problem(in: "TypeError: undefined is not an object (evaluating 'state.tabs.length')", missing: lacking))
        XCTAssertNil(ExtensionError.problem(in: "ReferenceError: Can't find variable: config", missing: lacking))
    }

    func testOnlyAChromeAPIsPathIsEverKept() {
        XCTAssertNil(ExtensionError.problem(in: "Invalid call to alice@example.com(x)", missing: []), "an account name is no API")
        XCTAssertNil(ExtensionError.problem(in: "Invalid call to https://site.example/path(", missing: []))
        XCTAssertNil(ExtensionError.problem(in: "Invalid call to secretToken.value(", missing: []), "not a Chrome namespace")
        XCTAssertEqual(ExtensionError.problem(in: "Invalid call to tabs.query(). 'x' is unknown.", missing: [])?.api, "tabs.query")
        XCTAssertNil(ExtensionError.problem(in: "TypeError: chrome.storage.local.get(\"alice@example.com\").finally is not a function", missing: []),
                     "a call's arguments are never read as an API")
        XCTAssertNil(ExtensionError.problem(in: "undefined is not an object (evaluating 'chrome.tabs.sendMessage(id, {url: \"https://mail.example\"}).then')", missing: []))
        XCTAssertEqual(ExtensionError.problem(in: "TypeError: chrome.sidePanel.open is not a function", missing: [])?.api, "sidePanel.open")
        XCTAssertTrue(ExtensionError.isAPIPath("system.display.getInfo"))
        XCTAssertFalse(ExtensionError.isAPIPath("tabs.query.x.y"))
    }

    func testAnErrorAboutTheExtensionsOwnCodeIsntAProblem() {
        XCTAssertNil(ExtensionError.problem(in: "TypeError: undefined is not an object (evaluating 'state.user.name')", missing: lacking))
        XCTAssertNil(ExtensionError.problem(in: "Saved your settings", missing: lacking), "console.error used for good news")
        XCTAssertNil(ExtensionError.problem(in: "NetworkError: Load failed", missing: lacking))
    }

    func testTheErrorsPlaceIsThePathInsideTheExtension() throws {
        let place = try XCTUnwrap(ExtensionError.place(in: "Oops (webkit-extension://1234-abcd/js/background.js:12:5)"))
        XCTAssertEqual(place.file, "js/background.js")
        XCTAssertEqual(place.line, 12)
        XCTAssertEqual(ExtensionError.place(in: "Oops (popup.js:3:1)")?.file, "popup.js")
        XCTAssertNil(ExtensionError.place(in: "no place"))
    }

    // MARK: What the person reads

    private func started(_ change: (inout ExtensionEvidence) -> Void = { _ in }) -> ExtensionVerdict {
        var evidence = ExtensionEvidence()
        evidence.start = .started
        change(&evidence)
        return ExtensionVerdict(evidence)
    }

    func testStartingAndTheChecksPassingIsStartedFineAndNoMore() {
        let verdict = started { $0.testPage = .passed; $0.popup = .passed }
        XCTAssertEqual(verdict.status, .startedFine)
        XCTAssertEqual(verdict.title, "Started Fine")
        XCTAssertEqual(verdict.lines, ["Checked: starting up, a test page and its popup. Its features haven't all been tried."])
    }

    func testReadingAloneNeverChangesTheStatus() {
        let verdict = started { $0.popup = .passed; $0.mayNotWork = ["tabCapture"] }
        XCTAssertEqual(verdict.status, .startedFine)
        XCTAssertEqual(verdict.lines.last, "May not work: record a tab.")
    }

    func testAnErrorSeenIsSomeFeaturesDontWork() {
        let verdict = started {
            $0.popup = .passed
            $0.problems = [ExtensionError.Problem(kind: .missing, api: "sidePanel")]
            $0.unreachableApp = "Bitwarden"
        }
        XCTAssertEqual(verdict.status, .someFeaturesDontWork)
        XCTAssertEqual(verdict.lines, ["Can't open its side panel.", "Can't reach the Bitwarden app."])
    }

    func testWhatWasSeenIsntAlsoSaidAsSuspected() {
        // As on macOS 27.0.1: the scan suspected the side panel, then the
        // worker's error showed it.
        let verdict = started {
            $0.mayNotWork = ["sidePanel", "tabCapture"]
            $0.problems = [ExtensionError.Problem(kind: .missing, api: "sidePanel")]
        }
        XCTAssertEqual(verdict.lines, ["Can't open its side panel.", "May not work: record a tab."])
    }

    func testNotStartingWinsOverEverything() {
        var evidence = ExtensionEvidence()
        evidence.start = .failed
        evidence.tried = .init(release: "2.3", works: true, what: "blocking on 20 sites")
        XCTAssertEqual(ExtensionVerdict(evidence).status, .couldntStart)
        XCTAssertEqual(ExtensionVerdict(evidence).lines.first, "eGlu tried starting it again.")
    }

    func testOnlyUntriableChecksIsNotCheckedYet() {
        XCTAssertEqual(started { $0.testPage = .skipped }.status, .notCheckedYet)
        XCTAssertEqual(started { $0.popup = .timedOut }.status, .notCheckedYet)
        XCTAssertEqual(started { $0.testPage = .skipped; $0.popup = .passed }.status, .startedFine)
        XCTAssertEqual(started().status, .startedFine, "a background and nothing else: starting is all there is")
        XCTAssertEqual(started { $0.popup = .checking }.status, .checking)
    }

    func testOnlyTheTriedListSaysItWorks() {
        let verdict = started { $0.popup = .passed; $0.tried = .init(release: "2.3", works: true, what: "blocking on 20 sites") }
        XCTAssertEqual(verdict.status, .triedWorks)
        XCTAssertEqual(verdict.title, "Works")
        XCTAssertEqual(verdict.lines.first, "Tried by eGlu on version 2.3: blocking on 20 sites.")
        // What this Mac saw still comes first.
        let failing = started { $0.tried = .init(release: "2.3", works: true, what: "x"); $0.problems = [.init(kind: .missing, api: "offscreen")] }
        XCTAssertEqual(failing.status, .someFeaturesDontWork)
    }

    func testCookiesKeptBackAreSaid() {
        XCTAssertEqual(started { $0.cookiesKeptBack = true }.lines.last, "Can't read cookies: kept from Google's sign-in.")
        var checking = ExtensionEvidence()
        checking.cookiesKeptBack = true
        XCTAssertEqual(ExtensionVerdict(checking).lines, [], "nothing under Checking…")
    }

    // MARK: The records and the tried list

    private func record(_ api: String, place: String = "worker", version: String = "1.0", at day: Double) -> ExtensionRecords.Record {
        let when = Date(timeIntervalSince1970: day * 86_400)
        return .init(id: "x", version: version, eglu: "1.0", macOS: "27.0.1", shim: "s", place: place,
                     api: api, kind: "missing", first: when, last: when)
    }

    func testTheSameProblemIsCountedOnOneRecord() {
        var records = ExtensionRecords()
        records.note(record("offscreen", at: 100), now: Date(timeIntervalSince1970: 100 * 86_400))
        records.note(record("offscreen", at: 101), now: Date(timeIntervalSince1970: 101 * 86_400))
        records.note(record("offscreen", version: "1.1", at: 101), now: Date(timeIntervalSince1970: 101 * 86_400))
        XCTAssertEqual(records.records.count, 2, "another version is another record")
        let first = records.of("x").first { $0.version == "1.0" }
        XCTAssertEqual(first?.count, 2)
        XCTAssertEqual(first?.first, Date(timeIntervalSince1970: 100 * 86_400))
        XCTAssertEqual(first?.last, Date(timeIntervalSince1970: 101 * 86_400))
    }

    func testRecordsLastThirtyDaysAndTwoHundredAnExtension() {
        var records = ExtensionRecords()
        let now = Date(timeIntervalSince1970: 200 * 86_400)
        records.note(record("old", at: 169), now: now)
        XCTAssertTrue(records.records.isEmpty, "past 30 days")
        for index in 0..<210 { records.note(record("api\(index)", at: 190 + Double(index) / 1000), now: now) }
        XCTAssertEqual(records.records.count, ExtensionRecords.most)
        XCTAssertFalse(records.records.contains { $0.api == "api0" }, "the oldest go first")
        XCTAssertTrue(records.records.contains { $0.api == "api209" })
        records.forget("x")
        XCTAssertTrue(records.records.isEmpty)
    }

    func testARecordSaysWhereNotWhat() throws {
        let manifest = try ExtensionManifest(json: Data("""
        {"manifest_version": 3, "name": "N", "version": "1", "background": {"service_worker": "bg.js"},
         "action": {"default_popup": "popup/index.html"},
         "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"]}]}
        """.utf8))
        XCTAssertEqual(ExtensionRecords.place(of: "/bg.js", in: manifest), "worker")
        XCTAssertEqual(ExtensionRecords.place(of: "content.js", in: manifest), "content script")
        XCTAssertEqual(ExtensionRecords.place(of: "popup/app.js", in: manifest), "popup")
        XCTAssertEqual(ExtensionRecords.place(of: "options/app.js", in: manifest), "page")
        // A record has no field for the error's words or an address.
        let fields = Set(Mirror(reflecting: record("x", at: 1)).children.compactMap(\.label))
        XCTAssertEqual(fields, ["id", "version", "eglu", "macOS", "shim", "place", "api", "kind", "count", "first", "last"])
    }

    func testRecordsKeptBeforeTheRenameAreRead() throws {
        // As Safience wrote them: the app's version under "safience".
        let kept = Data("""
        {"records": [{"id": "x", "version": "1.0", "safience": "1.0.7", "macOS": "27.0.1", "shim": "s", "place": "worker",
                      "api": "offscreen", "kind": "missing", "count": 3, "first": 0, "last": 86400}]}
        """.utf8)
        let records = try JSONDecoder().decode(ExtensionRecords.self, from: kept)
        XCTAssertEqual(records.records.first?.eglu, "1.0.7")
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)) as? [String: [[String: Any]]]
        XCTAssertEqual(written?["records"]?.first?["safience"] as? String, "1.0.7", "written back under the same key")
    }

    func testTheTriedListHoldsForItsVersions() throws {
        let list = ExtensionTried(entries: [
            .init(id: "a", from: ExtensionVersion("2.0"), through: ExtensionVersion("2.9"), works: true, release: "1.1", what: "blocking on 20 sites"),
            .init(id: "b", from: nil, through: nil, works: false, release: "1.1", what: "its popup"),
        ])
        XCTAssertEqual(list.entry(for: "a", version: "2.3")?.what, "blocking on 20 sites")
        XCTAssertNil(list.entry(for: "a", version: "3.0"))
        XCTAssertNil(list.entry(for: "a", version: "1.9"))
        XCTAssertEqual(list.entry(for: "b", version: "7")?.works, false)
        XCTAssertNil(list.entry(for: "c", version: "1"))
        XCTAssertTrue(ExtensionTried.shipped.entries.isEmpty, "nothing is said to work before it was tried by hand")
    }

    // MARK: Hands-off

    func testEveryExtensionIsKeptOffGooglesSignIn() throws {
        XCTAssertEqual(ExtensionPolicy.deniedSites, ["*://*.accounts.google.com/*"])
        XCTAssertTrue(ExtensionPolicy.deniedPermissions.contains("cookies"))
        XCTAssertFalse(ExtensionPolicy.grantsOnClick(try XCTUnwrap(URL(string: "https://accounts.google.com/signin"))))
        XCTAssertFalse(ExtensionPolicy.grantsOnClick(try XCTUnwrap(URL(string: "https://x.accounts.google.com/"))))
        XCTAssertTrue(ExtensionPolicy.grantsOnClick(try XCTUnwrap(URL(string: "https://mail.google.com/"))))
        XCTAssertFalse(ExtensionPolicy.mayTouchData(ofDomain: ".google.com"), "its cookies go to accounts.google.com")
        XCTAssertFalse(ExtensionPolicy.mayTouchData(ofDomain: "accounts.google.com"))
        XCTAssertTrue(ExtensionPolicy.mayTouchData(ofDomain: "mail.google.com"))
        XCTAssertTrue(ExtensionPolicy.mayTouchData(ofDomain: "figma.com"))
    }
}
