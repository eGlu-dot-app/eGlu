import XCTest
@testable import PadCore

final class PreferencesTests: XCTestCase {
    func testMissingFieldsTakeTheirDefaults() throws {
        let saved = Data(#"{"address":"always","limits":{"heavy":1,"lightOffScreen":0}}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: saved)
        XCTAssertEqual(preferences.address, .always)
        XCTAssertEqual(preferences.limits.lightOffScreen, 0)
        XCTAssertTrue(preferences.tabBar)
        XCTAssertNil(preferences.wheel)
        XCTAssertEqual(preferences.keys, .site)
        XCTAssertEqual(preferences.engine, "google")
    }

    func testUnknownValuesFallBackRatherThanFail() throws {
        let saved = Data(#"{"address":"sometimes","wheel":"sideways","tabBar":false}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: saved)
        XCTAssertEqual(preferences.address, .always)
        XCTAssertNil(preferences.wheel)
        XCTAssertFalse(preferences.tabBar)
    }

    func testAdsAreBlockedUnlessTurnedOffForASite() throws {
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"address":"automatic"}"#.utf8))
        XCTAssertTrue(preferences.blocksContent, "settings saved before blocking came keep it on")
        XCTAssertTrue(preferences.blocksContent(onHost: "www.news.test"))
        preferences.setBlocksContent(false, onHost: "www.news.test")
        XCTAssertEqual(preferences.unblockedSites, ["news.test"])
        XCTAssertFalse(preferences.blocksContent(onHost: "news.test"), "www. or not, the same site")
        XCTAssertTrue(preferences.blocksContent(onHost: "other.test"))
        let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(saved.unblockedSites, ["news.test"])
        preferences.setBlocksContent(true, onHost: "news.test")
        XCTAssertEqual(preferences.unblockedSites, [])
        preferences.blocksContent = false
        XCTAssertFalse(preferences.blocksContent(onHost: "other.test"))
    }

    func testWritingIsOffUntilTurnedOn() throws {
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{}"#.utf8))
        XCTAssertFalse(preferences.writing, "settings saved before writing came keep it off")
        XCTAssertFalse(preferences.checksWriting(onHost: "news.test"))
        preferences.writing = true
        XCTAssertTrue(preferences.checksWriting(onHost: "www.news.test"))
        preferences.setWritingChecks(false, onHost: "www.news.test")
        XCTAssertEqual(preferences.writingOffSites, ["news.test"])
        XCTAssertFalse(preferences.checksWriting(onHost: "news.test"), "www. or not, the same site")
        preferences.setWritingChecks(true, onHost: "news.test")
        XCTAssertTrue(preferences.writingOffSites.isEmpty)
        XCTAssertTrue(preferences.checksWriting(onHost: "news.test"))
        let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(saved.writing)
        XCTAssertTrue(saved.writingRules.isEmpty)
    }

    func testALayoutSavedBeforeIsLetGo() throws {
        let saved = try JSONDecoder().decode(Preferences.self, from: Data(#"{"layout":"separate","address":"automatic"}"#.utf8))
        XCTAssertEqual(saved.address, .automatic, "the rest kept")
    }

    func testTheAddressBarStaysByDefault() throws {
        XCTAssertEqual(Preferences().address, .always)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).address, .always)
    }

    func testRoundTrip() throws {
        var preferences = Preferences()
        preferences.wheel = .always
        preferences.keys = .on
        preferences.diagnostics = true
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), preferences)
    }

    func testTabReachesEveryPageFirst() {
        // iPadOS 26's focus system keeps Tab from a page otherwise.
        XCTAssertEqual(Bridges().keys, [.tab])
        XCTAssertEqual(Adapters.standard.bridges.keys, [.tab])
        XCTAssertEqual(Adapters.figma.bridges.keys, [.tab])
        XCTAssertEqual(Preferences().bridges(for: Adapters.standard).keys, [.tab])
    }

    func testSettingsLayOverTheAdaptersBridges() {
        var preferences = Preferences()
        XCTAssertEqual(preferences.bridges(for: Adapters.figma), Adapters.figma.bridges)
        preferences.wheel = .off
        preferences.keys = .on
        let bridges = preferences.bridges(for: Adapters.figma)
        XCTAssertEqual(bridges.wheel, .off)
        XCTAssertEqual(bridges.keys, [.tab, .arrows])
        XCTAssertTrue(bridges.pinch)
        preferences.keys = .off
        XCTAssertEqual(preferences.bridges(for: Adapters.figma).keys, [])
    }
}

/// WritingSites: where a page's typing is checked, by site.
final class WritingSitesTests: XCTestCase {
    func testTheSitesTheAppNeverChecks() {
        XCTAssertTrue(WritingSites.isOff(URL(string: "https://docs.google.com/document/d/1"), sites: []))
        XCTAssertTrue(WritingSites.isOff(URL(string: "https://www.docs.google.com/"), sites: []),
                      "a host under a never site is never checked")
        XCTAssertFalse(WritingSites.isOff(URL(string: "https://google.com/"), sites: []))
    }

    func testTheSitesThePersonTurnedOff() {
        XCTAssertTrue(WritingSites.isOff(URL(string: "https://mail.google.com/inbox"), sites: ["google.com"]),
                      "a host under the site is off too")
        XCTAssertTrue(WritingSites.isOff(URL(string: "https://google.com/"), sites: ["google.com"]))
        XCTAssertFalse(WritingSites.isOff(URL(string: "https://news.test/"), sites: ["google.com"]))
        XCTAssertFalse(WritingSites.isOff(URL(string: "https://notgoogle.com/"), sites: ["google.com"]),
                       "a name that ends the same is not under it")
        XCTAssertFalse(WritingSites.isOff(nil, sites: ["google.com"]))
    }
}

final class ScriptsTests: XCTestCase {
    func testTheResourcesShip() {
        XCTAssertTrue(Scripts.bridge.contains("__eglu"))
        XCTAssertTrue(Scripts.style.contains("touch-action: manipulation"))
    }

    func testDraftInspectionShipsWithoutDependingOnTheInputBridge() {
        XCTAssertTrue(Scripts.draft.contains("function egluHasDraft(handsOff)"))
        XCTAssertEqual(Scripts.draftCall, Scripts.draft + "\nreturn egluHasDraft(handsOff);")
        XCTAssertTrue(Scripts.bridge.contains(Scripts.draft))
        XCTAssertFalse(Scripts.bridge.contains("/*DRAFT_PROBE*/"))
        XCTAssertFalse(Scripts.draftCall.contains("__eglu"))
        XCTAssertFalse(Scripts.draftCall.contains("addEventListener"))
    }

    func testCalloutsAreOffOnlyWhereTheSiteKeepsItsOwnMenus() {
        let anywhere = Scripts.ours(for: Adapters.standard, bridges: Adapters.standard.bridges)
        let kept = Scripts.ours(for: Adapters.standard, bridges: Adapters.standard.bridges, ownMenus: true)
        XCTAssertFalse(anywhere.contains("-webkit-touch-callout"), "or WebKit never asks the app for a link's menu")
        XCTAssertTrue(anywhere.contains("touch-action"))
        XCTAssertTrue(kept.contains("-webkit-touch-callout: none"), "the site's own context menu is the only one there")
    }

    func testTheCalloutRuleGoesInByItselfSoAPageThatIsUpCanBeGivenIt() {
        let anywhere = Scripts.ours(for: Adapters.standard, bridges: Adapters.standard.bridges)
        let kept = Scripts.ours(for: Adapters.standard, bridges: Adapters.standard.bridges, ownMenus: true)
        XCTAssertTrue(anywhere.contains("\"callouts\":\"\""))
        XCTAssertTrue(kept.contains("\"callouts\":\"html, html * { -webkit-touch-callout: none !important; }\""))
        // Apart from the rest of the style, and changed by the app while the page is up (Page.settingsChanged).
        XCTAssertTrue(Scripts.bridge.contains("let ownMenus = addStyle(config.callouts);"))
        XCTAssertTrue(Scripts.bridge.contains("if (ownMenus) ownMenus.textContent = css || '';"))
        XCTAssertTrue(Scripts.bridge.contains("wheel, key, pointer, type, callouts,"))
    }

    func testTheBridgeSaysWhetherThePageKeptAContextMenu() {
        XCTAssertTrue(Scripts.bridge.contains("kind: 'context', kept: event.defaultPrevented"))
        XCTAssertTrue(Scripts.bridge.contains("if (!event.isTrusted) return;"))
    }

    func testTheBridgeSaysWhenASidewaysSwipeWentUnused() {
        // What a swipe back goes on (TrackpadSwipe): the page left the event, and nothing scrolled sideways.
        XCTAssertTrue(Scripts.bridge.contains("if (m.dx && !moved.x && !moved.keptX) return 'free';"))
        // overscroll-behavior keeps the swipe to the page: on a scroller, and on the page itself.
        XCTAssertTrue(Scripts.bridge.contains("if (leftX && !x && contains('x', style)) moved.keptX = true;"))
        XCTAssertTrue(Scripts.bridge.contains("getComputedStyle(doc.documentElement).overscrollBehaviorX"))
    }

    func testOurScriptCarriesTheSitesSettings() {
        var bridges = Adapters.figma.bridges
        bridges.keys = [.arrows]
        let script = Scripts.ours(for: Adapters.figma, bridges: bridges, ownMenus: true)
        XCTAssertTrue(script.hasPrefix("window.__egluConfig = {"))
        XCTAssertTrue(script.contains(#""adapter":"figma""#))
        XCTAssertTrue(script.contains(#""wheel":"auto""#))
        XCTAssertTrue(script.contains(#""keys":["arrows"]"#))
        XCTAssertTrue(script.contains(#""handsOff":["accounts.google.com"]"#))
        XCTAssertTrue(script.contains("-webkit-touch-callout"))
        XCTAssertTrue(script.contains(Scripts.bridge))
    }

    func testOnlyFigmaHasAPageWorldScript() {
        XCTAssertNotNil(Scripts.page(for: Adapters.figma))
        XCTAssertNil(Scripts.page(for: Adapters.standard))
    }

    func testAdapterScriptsCannotBreakTheBridge() {
        let adapter = SiteAdapter(id: "x", name: "X", domains: ["x.example"], script: "throw new Error('no')")
        let script = Scripts.ours(for: adapter, bridges: .standard)
        XCTAssertTrue(script.contains("try {\nthrow new Error('no')\n} catch (_) {}"))
    }

    /// writing.js's words and keys go in as JSON, where its mark was: a
    /// quote in a translation can't end the object early.
    func testTheWritingScriptTakesItsWordsAsData() throws {
        let script = Scripts.writing(strings: ["card.ignore": #"Say "no""#], keys: ["accept": "⌃⌥G"])
        XCTAssertFalse(script.contains(Scripts.writingMark))
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("const config = ") })
        let json = line.dropFirst("const config = ".count).dropLast()
        let config = try JSONDecoder().decode([String: [String: String]].self, from: Data(json.utf8))
        XCTAssertEqual(config["strings"]?["card.ignore"], #"Say "no""#)
        XCTAssertEqual(config["keys"]?["accept"], "⌃⌥G")
    }
}

/// The rules about Google's sign-in, kept by reading the app's own source:
/// a cookie read or a script call anywhere else would break them without any
/// test of behaviour noticing.
final class PolicyTests: XCTestCase {
    /// The repository's root, where App/, Mac/ and PadCore/ are.
    var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PadCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PadCore
            .deletingLastPathComponent()   // the root
    }

    func sources(in folder: String, ending: String) throws -> [(String, String)] {
        let start = root.appendingPathComponent(folder)
        guard let files = FileManager.default.enumerator(at: start, includingPropertiesForKeys: nil) else { return [] }
        return try files.compactMap { $0 as? URL }
            .filter { $0.path.hasSuffix(ending) }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNothingReadsCookies() throws {
        var swift = try sources(in: "App", ending: ".swift") + sources(in: "Mac", ending: ".swift")
            + sources(in: "Shared", ending: ".swift") + sources(in: "PadCore/Sources", ending: ".swift")
        XCTAssertFalse(swift.isEmpty)
        // Future engine and service packages from the split plan (Docs/EngineSplitPlan.md, step 0).
        let futureFolders = [
            "WebEngineKit/Sources",
            "WebKitEngine/Sources",
            "WritingServiceKit/Sources",
            "DocumentServiceKit/Sources",
            "HarperPlugin/Sources",
            "DocumentsPlugin/Sources",
        ]
        var js = try sources(in: "PadCore/Sources", ending: ".js")
        for folder in futureFolders {
            let path = root.appendingPathComponent(folder).path
            if FileManager.default.fileExists(atPath: path) {
                swift += try sources(in: folder, ending: ".swift")
                js += try sources(in: folder, ending: ".js")
            }
        }
        for (name, text) in swift {
            for banned in ["getAllCookies", "httpCookieStore", "HTTPCookieStorage", "document.cookie"] {
                XCTAssertFalse(text.contains(banned), "\(name) uses \(banned)")
            }
        }
        for (name, text) in js {
            XCTAssertFalse(text.contains("document.cookie"), "\(name) reads cookies")
        }
    }

    /// On the iPad (App/) and on the Mac (Mac/), each with a Page.swift of its
    /// own; in what both compile (Shared/), only PageShared.swift, the half of
    /// Page.swift the two share. In the WebKit plugin's support code, which
    /// both link, only two: WebKitSVGRaster.swift calls into a page of the
    /// app's own, where sites' SVG icons are drawn, and may, so long as that
    /// page is never a site's; WebKitHiddenPage.swift calls the reader of
    /// PageShared.swift's Unseen, in the app's world only, on a site page
    /// Unseen has asked HandsOff about and whose steps it decides. So may the Mac's
    /// ExtensionBlankPage.swift, an empty page of the app's own at a removed
    /// extension's address, where what it kept is cleared; and its
    /// ExtensionPopup.swift, whose views (an extension's popup and side
    /// panel) only ever load that extension's own pages.
    func testOnlyPageSwiftCallsIntoPagesAndItAsksHandsOffFirst() throws {
        let sharedPage = "PageShared.swift"
        let blank = "ExtensionBlankPage.swift"
        let surface = "ExtensionPopup.swift"
        for folder in ["App", "Mac", "Shared"] {
            let swift = try sources(in: folder, ending: ".swift")
            if let page = swift.first(where: { $0.0 == blank })?.1 {
                XCTAssertTrue(page.contains("loadHTMLString(\"<!doctype html>\", baseURL: base)") && page.contains("base.scheme == Extensions.scheme"),
                              "\(blank)'s page must be an empty one at an extension's own address")
                for load in ["load(URLRequest", ".load(", "loadFileURL", "addUserScript", "evaluateJavaScript"] {
                    XCTAssertFalse(page.contains(load), "\(blank) must never load a site or add a script to one")
                }
            }
            if let page = swift.first(where: { $0.0 == surface })?.1 {
                XCTAssertTrue(page.contains("guard url.scheme == Extensions.scheme, url.host() == context.uniqueIdentifier"),
                              "\(surface)'s views must load only their extension's own pages")
                for load in ["loadHTMLString", "loadFileURL", "addUserScript"] {
                    XCTAssertFalse(page.contains(load), "\(surface) must never load a site or add a script to one")
                }
            }
            // The first-seconds checks try content scripts on an empty page
            // at a reserved address, never a site, and only the extension's
            // own popup and settings page.
            if let trial = swift.first(where: { $0.0 == "ExtensionTrial.swift" })?.1 {
                XCTAssertTrue(trial.contains("loadHTMLString(\"<!doctype html>\", baseURL: testPage)")
                              && trial.contains("static let testPage = URL(string: \"https://test.eglu.invalid/\")!"),
                              "ExtensionTrial.swift's test page must be an empty one at a .invalid address")
                XCTAssertTrue(trial.contains("url.scheme == Extensions.scheme, url.host() == id"),
                              "ExtensionTrial.swift must load only the extension's own pages")
                XCTAssertFalse(trial.contains("loadFileURL"), "ExtensionTrial.swift must never load a file")
            }
            let pageFile = folder == "Shared" ? sharedPage : "Page.swift"
            for (name, text) in swift where name != pageFile && name != blank && name != surface {
                for call in ["evaluateJavaScript", "callAsyncJavaScript", "addUserScript"] {
                    XCTAssertFalse(text.contains(call), "\(folder)/\(name) calls \(call); calls into pages go through Page.swift")
                }
            }
            let text = try XCTUnwrap(swift.first { $0.0 == pageFile }?.1, "\(folder) has no \(pageFile)")
            XCTAssertTrue(text.contains("HandsOff.covers"), "\(folder)/\(pageFile) doesn't ask HandsOff")
        }
        let ownPage = "WebKitSVGRaster.swift"
        let hiddenPage = "WebKitHiddenPage.swift"
        let support = try sources(in: "WebKitEngine/Sources", ending: ".swift")
        for (name, text) in support where name != ownPage && name != hiddenPage {
            for call in ["evaluateJavaScript", "callAsyncJavaScript", "addUserScript"] {
                XCTAssertFalse(text.contains(call), "WebKitEngine's \(name) calls \(call)")
            }
        }
        let raster = try XCTUnwrap(support.first { $0.0 == ownPage }?.1, "WebKitEngine has no \(ownPage)")
        XCTAssertTrue(raster.contains("loadHTMLString(") && raster.contains("baseURL: nil"),
                      "\(ownPage)'s page must be the app's own, with no site for its origin")
        for load in ["load(URLRequest", ".load(", "loadFileURL", "addUserScript"] {
            XCTAssertFalse(raster.contains(load), "\(ownPage) must never load a site or add a script to one")
        }
        let hidden = try XCTUnwrap(support.first { $0.0 == hiddenPage }?.1, "WebKitEngine has no \(hiddenPage)")
        XCTAssertTrue(hidden.contains("contentWorld: appWorld") && hidden.contains("guard allows(url)"),
                      "\(hiddenPage) must call only in the app's world and load only what its owner allows")
        for call in ["evaluateJavaScript", "addUserScript", "loadFileURL", "loadHTMLString"] {
            XCTAssertFalse(hidden.contains(call), "\(hiddenPage) must not \(call)")
        }
        let unseen = try XCTUnwrap(try sources(in: "Shared", ending: ".swift").first { $0.0 == sharedPage }?.1)
        XCTAssertTrue(unseen.contains("guard !HandsOff.covers(url), await hidden.begin("),
                      "Unseen must ask HandsOff before its hidden page loads")
    }

    /// What Apple's browser entitlement asks of the app
    /// (developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser).
    func testTheAppMeetsTheBrowserEntitlementsTerms() throws {
        let plist = try String(contentsOf: root.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        for scheme in ["<string>http</string>", "<string>https</string>"] {
            XCTAssertTrue(plist.contains(scheme), "Info.plist must name \(scheme) as a URL scheme")
        }
        // Keys a browser with the entitlement is rejected for.
        for banned in ["NSPhotoLibraryUsageDescription", "NSLocationAlwaysUsageDescription",
                       "NSLocationAlwaysAndWhenInUseUsageDescription", "NSHomeKitUsageDescription",
                       "NSBluetoothAlwaysUsageDescription", "NSHealthShareUsageDescription",
                       "NSHealthUpdateUsageDescription"] {
            XCTAssertFalse(plist.contains(banned), "Info.plist has \(banned), which a browser may not use")
        }
        let swift = try sources(in: "App", ending: ".swift") + sources(in: "Shared", ending: ".swift")
        for (name, text) in swift {
            XCTAssertFalse(text.contains("UIWebView"), "\(name) uses UIWebView")
        }
        let entitlements = try String(contentsOf: root.appendingPathComponent("Config/eGlu.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("<key>com.apple.developer.web-browser</key>"))
        // A browser may not claim Universal Links for its own domains.
        XCTAssertFalse(entitlements.contains("com.apple.developer.associated-domains"))
        let signing = try String(contentsOf: root.appendingPathComponent("Config/Signing.xcconfig"), encoding: .utf8)
        XCTAssertTrue(signing.contains("\nCODE_SIGN_ENTITLEMENTS = Config/eGlu.entitlements"),
                      "the app is signed with the browser entitlement unless Local.xcconfig turns it off")
    }
}
