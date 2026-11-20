import XCTest
@testable import PadCore

final class ExtensionPreparationTests: XCTestCase {
    func testTheWorkerAndContentScriptsGetTheShimFirst() throws {
        let manifest = """
        {
          // Chrome takes comments.
          "manifest_version": 3, "name": "N", "version": "1.0",
          "permissions": ["storage"],
          "background": { "service_worker": "./bg.js", "type": "module" },
          "content_scripts": [
            { "matches": ["<all_urls>"], "js": ["a.js", "b.js"] },
            { "matches": ["<all_urls>"], "css": ["only.css"] },
            { "matches": ["<all_urls>"], "js": ["page.js"], "world": "MAIN" }
          ]
        }
        """
        let edited = try ExtensionPreparation.manifest(Data(manifest.utf8))
        XCTAssertEqual(edited.worker?.path, "./bg.js")
        XCTAssertEqual(edited.worker?.module, true)
        XCTAssertEqual(edited.added, ["nativeMessaging"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: edited.manifest) as? [String: Any])
        XCTAssertEqual(object["permissions"] as? [String], ["storage", "nativeMessaging"])
        let scripts = try XCTUnwrap(object["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts[0]["js"] as? [String], [ExtensionPreparation.shimFile, "a.js", "b.js"])
        XCTAssertNil(scripts[1]["js"])
        XCTAssertEqual(scripts[2]["js"] as? [String], ["page.js"])
        XCTAssertEqual((object["background"] as? [String: Any])?["type"] as? String, "module")
    }

    /// User scripts go through WebKit's registered content scripts, which
    /// need scripting: given with userScripts, asked outright or optional.
    func testUserScriptsBringScripting() throws {
        for (permissions, optional) in [(#"["userScripts"]"#, "[]"), (#"["storage"]"#, #"["userScripts"]"#)] {
            let manifest = #"{"manifest_version": 3, "name": "U", "version": "1", "permissions": "# + permissions + #", "optional_permissions": "# + optional + "}"
            let edited = try ExtensionPreparation.manifest(Data(manifest.utf8))
            XCTAssertEqual(edited.added, ["nativeMessaging", "scripting"], manifest)
        }
        let already = try ExtensionPreparation.manifest(Data(#"{"manifest_version": 3, "name": "U", "version": "1", "permissions": ["userScripts", "scripting"]}"#.utf8))
        XCTAssertEqual(already.added, ["nativeMessaging"])
    }

    func testAScriptingExtensionGetsTheShimWhereItInjects() throws {
        // Mesurer declares no content_scripts: its worker injects them with
        // chrome.scripting. The shim still goes where they land, only to
        // the hosts it already asked for.
        let manifest = """
        {
          "manifest_version": 3, "name": "N", "version": "1.0",
          "permissions": ["scripting", "activeTab"],
          "host_permissions": ["http://*/*", "https://*/*"],
          "background": { "service_worker": "bg.js" }
        }
        """
        let edited = try ExtensionPreparation.manifest(Data(manifest.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: edited.manifest) as? [String: Any])
        let scripts = try XCTUnwrap(object["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0]["js"] as? [String], [ExtensionPreparation.shimFile])
        XCTAssertEqual(scripts[0]["matches"] as? [String], ["http://*/*", "https://*/*"])
        XCTAssertEqual(scripts[0]["run_at"] as? String, "document_start")
        // Without scripting or anywhere to run, no entry is made up.
        for noEntry in [
            #"{"manifest_version": 3, "permissions": ["storage"], "host_permissions": ["http://*/*"]}"#,
            #"{"manifest_version": 3, "permissions": ["scripting"]}"#,
        ] {
            let out = try XCTUnwrap(JSONSerialization.jsonObject(with: ExtensionPreparation.manifest(Data(noEntry.utf8)).manifest) as? [String: Any])
            XCTAssertNil(out["content_scripts"], noEntry)
        }
    }

    /// Dark Reader's entries: the shim goes in its first one, which runs in
    /// every frame from the start, and not again in the later one or in an
    /// entry for where chrome.scripting injects.
    func testTheShimIsListedOnceWhereAnEarlierEntryRanIt() throws {
        let manifest = """
        {
          "manifest_version": 3, "name": "N", "version": "1.0",
          "permissions": ["scripting", "storage"],
          "host_permissions": ["*://*/*"],
          "content_scripts": [
            { "matches": ["<all_urls>"], "js": ["proxy.js"], "run_at": "document_start", "all_frames": true, "match_about_blank": true, "world": "MAIN" },
            { "matches": ["<all_urls>"], "js": ["fallback.js", "index.js"], "run_at": "document_start", "all_frames": true, "match_about_blank": true, "world": "ISOLATED" },
            { "matches": ["<all_urls>"], "js": ["watcher.js"], "run_at": "document_idle", "all_frames": false }
          ]
        }
        """
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ExtensionPreparation.manifest(Data(manifest.utf8)).manifest) as? [String: Any])
        let scripts = try XCTUnwrap(object["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.map { $0["js"] as? [String] ?? [] }, [
            ["proxy.js"], [ExtensionPreparation.shimFile, "fallback.js", "index.js"], ["watcher.js"],
        ])
    }

    /// Wherever the earlier entry might not have run the shim first, the
    /// later one keeps it.
    func testTheShimStaysWhereNoEarlierEntryRanIt() throws {
        let later = #"{ "matches": ["https://a.example/*"], "js": ["later.js"], "run_at": "document_end", "all_frames": true, "match_about_blank": true }"#
        for earlier in [
            #"{ "matches": ["<all_urls>"], "js": ["e.js"], "run_at": "document_start", "match_about_blank": true }"#,
            #"{ "matches": ["<all_urls>"], "js": ["e.js"], "run_at": "document_start", "all_frames": true }"#,
            #"{ "matches": ["<all_urls>"], "js": ["e.js"], "run_at": "document_idle", "all_frames": true, "match_about_blank": true }"#,
            #"{ "matches": ["https://b.example/*"], "js": ["e.js"], "run_at": "document_start", "all_frames": true, "match_about_blank": true }"#,
            #"{ "matches": ["<all_urls>"], "exclude_matches": ["https://a.example/x"], "js": ["e.js"], "run_at": "document_start", "all_frames": true, "match_about_blank": true }"#,
            #"{ "matches": ["<all_urls>"], "include_globs": ["*a*"], "js": ["e.js"], "run_at": "document_start", "all_frames": true, "match_about_blank": true }"#,
            #"{ "matches": ["<all_urls>"], "js": ["e.js"], "run_at": "document_start", "all_frames": true, "match_about_blank": true, "world": "MAIN" }"#,
            #"{ "matches": ["<all_urls>"], "css": ["e.css"], "run_at": "document_start", "all_frames": true, "match_about_blank": true }"#,
        ] {
            let manifest = #"{"manifest_version": 3, "name": "N", "version": "1", "content_scripts": ["# + earlier + ", " + later + "]}"
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ExtensionPreparation.manifest(Data(manifest.utf8)).manifest) as? [String: Any])
            let scripts = try XCTUnwrap(object["content_scripts"] as? [[String: Any]])
            XCTAssertEqual(scripts[1]["js"] as? [String], [ExtensionPreparation.shimFile, "later.js"], earlier)
        }
        // The same entry as early, or one for the same addresses, does reach it.
        let same = #"{"manifest_version": 3, "name": "N", "version": "1", "content_scripts": [{ "matches": ["https://a.example/*"], "js": ["e.js"], "run_at": "document_end", "all_frames": true, "match_about_blank": true }, "# + later + "]}"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ExtensionPreparation.manifest(Data(same.utf8)).manifest) as? [String: Any])
        XCTAssertEqual((object["content_scripts"] as? [[String: Any]])?[1]["js"] as? [String], ["later.js"])
    }

    /// A scripting extension whose own entry doesn't run the shim in every
    /// address it may inject on still gets the entry for those.
    func testAScriptingExtensionKeepsItsShimEntryBeyondItsOwn() throws {
        let manifest = #"{"manifest_version": 3, "name": "N", "version": "1", "permissions": ["scripting"], "host_permissions": ["*://*/*"], "content_scripts": [{ "matches": ["https://a.example/*"], "js": ["a.js"], "run_at": "document_start" }]}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ExtensionPreparation.manifest(Data(manifest.utf8)).manifest) as? [String: Any])
        let scripts = try XCTUnwrap(object["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.map { $0["js"] as? [String] ?? [] }, [[ExtensionPreparation.shimFile, "a.js"], [ExtensionPreparation.shimFile]])
    }

    func testBackgroundScriptsGetTheShimFirst() throws {
        let manifest = #"{"manifest_version": 2, "name": "N", "version": "1", "permissions": ["nativeMessaging"], "background": {"scripts": ["one.js"], "persistent": false}}"#
        let edited = try ExtensionPreparation.manifest(Data(manifest.utf8))
        XCTAssertNil(edited.worker?.path)
        XCTAssertEqual(edited.added, [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: edited.manifest) as? [String: Any])
        let background = try XCTUnwrap(object["background"] as? [String: Any])
        XCTAssertEqual(background["scripts"] as? [String], [ExtensionPreparation.shimFile, "one.js"])
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertThrowsError(try ExtensionPreparation.manifest(Data("[1]".utf8)))
    }

    func testAPageGetsTheShimFirstInItsHead() {
        let tag = "<script src=\"/_eglu/shim.js\"></script>"
        XCTAssertEqual(ExtensionPreparation.page("<html><HEAD lang=\"en\"><title>x</title></head></html>"),
                       "<html><HEAD lang=\"en\">\(tag)<title>x</title></head></html>")
        // A <header> is not the head.
        XCTAssertEqual(ExtensionPreparation.page("<!DOCTYPE html><body><header>x</header></body>"),
                       "<!DOCTYPE html>\(tag)<body><header>x</header></body>")
        XCTAssertEqual(ExtensionPreparation.page("<div>x</div>"), "\(tag)<div>x</div>")
        // Not the one in a comment.
        XCTAssertEqual(ExtensionPreparation.page("<!-- <head> --><head></head>"), "<!-- <head> --><head>\(tag)</head>")
    }

    func testAClassicWorkerKeepsItsBytes() {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("self.x = 1;\n".utf8)
        let out = ExtensionPreparation.worker(source, shim: "/* shim */", module: false)
        XCTAssertTrue(out.starts(with: Data([0xEF, 0xBB, 0xBF]) + Data(ExtensionPreparation.shimMarks.0.utf8)))
        XCTAssertEqual(out.suffix(source.count - 3), source.dropFirst(3))
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("/* shim */"))
    }

    /// Its imports run before its own code: the shim is one of them, the
    /// first, on the first line.
    func testAModuleWorkerImportsTheShimFirst() {
        let source = Data("import x from './x.js';\nx();\n".utf8)
        let out = String(decoding: ExtensionPreparation.worker(source, shim: "/* shim */", module: true), as: UTF8.self)
        XCTAssertEqual(out, "import \"/_eglu/shim.js\";import x from './x.js';\nx();\n")
    }

    func testAStrictWorkerStaysStrict() {
        func worker(_ source: String) -> String {
            String(decoding: ExtensionPreparation.worker(Data(source.utf8), shim: "/* shim */", module: false), as: UTF8.self)
        }
        let marks = ExtensionPreparation.shimMarks
        XCTAssertEqual(worker("\u{FEFF}\n'use strict';\nself.x = 1;\n"),
                       "\u{FEFF}\n'use strict';\n\(marks.0)\n/* shim */\n\(marks.1)\n\nself.x = 1;\n")
        // Past a licence's comment; and with no semicolon, one is put, or the
        // string would be called.
        XCTAssertEqual(worker("/*! licence */\n// more\n\"use strict\"\n(() => {})();"),
                       "/*! licence */\n// more\n\"use strict\";\n\(marks.0)\n/* shim */\n\(marks.1)\n\n(() => {})();")
        XCTAssertTrue(worker("\"use strictly\"").hasSuffix("\(marks.1)\n\"use strictly\""))
        // After every directive, the strict one not first among them.
        XCTAssertEqual(worker("'licence'; \"use strict\";x = 1;"),
                       "'licence'; \"use strict\";\n\(marks.0)\n/* shim */\n\(marks.1)\nx = 1;")
        // A string that goes on is no directive.
        XCTAssertTrue(worker("\"use strict\".slice(0);").hasSuffix("\(marks.1)\n\"use strict\".slice(0);"))
        XCTAssertTrue(worker("/* never closed").hasPrefix(marks.0))
    }

    /// A Mac's disk takes neither case nor the two ways of writing é apart.
    func testNamesThatAreOneFileOnAMacAreRefused() {
        XCTAssertEqual(ExtensionPreparation.sameFile(in: ["manifest.json", "Manifest.json"]), "Manifest.json")
        XCTAssertEqual(ExtensionPreparation.sameFile(in: ["caf\u{E9}.js", "cafe\u{301}.js"]), "cafe\u{301}.js")
        XCTAssertNotNil(ExtensionPreparation.sameFile(in: ["lib", "Lib/a.js"]))
        XCTAssertNotNil(ExtensionPreparation.sameFile(in: ["icons/", "Icons"]))
        XCTAssertNil(ExtensionPreparation.sameFile(in: ["icons/", "icons/a.png", "Icons/b.png", "manifest.json"]))
        let twice = Self.zip([("manifest.json", Data("{}".utf8)), ("MANIFEST.JSON", Data("{}".utf8))])
        XCTAssertThrowsError(try ExtensionPreparation.prepare(twice, shim: "", stamp: "") { _, _ in }) {
            XCTAssertEqual($0 as? ExtensionPreparation.Problem, .sameFile("MANIFEST.JSON"))
        }
    }

    /// A link in a package is refused: it would be written as a file of its
    /// target's name, which isn't the package's to give.
    func testALinkIsRefused() {
        var archive = [UInt8](Self.zip([("manifest.json", Data("{}".utf8)), ("lib", Data("../../etc".utf8))]))
        let central = Int(ZipFile.u32(archive, archive.count - 22 + 16)!)
        let second = central + 46 + "manifest.json".utf8.count
        // External attributes, 38 bytes in: a link's mode, 0o120777, in the top half.
        let mode = UInt32(0o120777) << 16
        for i in 0..<4 { archive[second + 38 + i] = UInt8((mode >> (8 * UInt32(i))) & 0xFF) }
        XCTAssertThrowsError(try ExtensionPreparation.prepare(Data(archive), shim: "", stamp: "") { _, _ in }) {
            XCTAssertEqual($0 as? ExtensionPreparation.Problem, .link("lib"))
        }
    }

    /// A stored file that says it holds less than it has: its size can't
    /// be counted on, so it isn't unpacked.
    func testAStoredFileMustHoldWhatItSays() {
        var archive = [UInt8](Self.zip([("manifest.json", Data("{}".utf8)), ("big.bin", Data(repeating: 1, count: 100))]))
        // The central directory's size of big.bin: its second entry, 24 bytes in.
        let central = Int(ZipFile.u32(archive, archive.count - 22 + 16)!)
        let second = central + 46 + "manifest.json".utf8.count
        archive[second + 24] = 0
        XCTAssertThrowsError(try ExtensionPreparation.prepare(Data(archive), shim: "", stamp: "") { _, _ in }) {
            XCTAssertEqual($0 as? ExtensionPreparation.Problem, .unreadable("big.bin"))
        }
    }

    func testNamesStayInTheFolder() {
        for name in ["manifest.json", "icons/", "icons/a.png", "_locales/en/messages.json", "eglu/x"] {
            XCTAssertTrue(ExtensionPreparation.isSafe(name: name), name)
        }
        for name in ["", "/abs", "../x", "a/../b", "a/./b", "./a", "a//b", "a\\b", "_eglu/shim.js", "_eGlu/x", "..", "/"] {
            XCTAssertFalse(ExtensionPreparation.isSafe(name: name), name)
        }
        XCTAssertEqual(ExtensionPreparation.normalized("./bg.js"), "bg.js")
        XCTAssertEqual(ExtensionPreparation.normalized("/js/bg.js"), "js/bg.js")
    }

    func testAPackageIsPreparedFileByFile() throws {
        let manifest = #"{"manifest_version": 3, "name": "N", "version": "1", "background": {"service_worker": "bg.js"}, "action": {"default_popup": "popup.html"}}"#
        let icon = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let archive = Self.zip([
            ("manifest.json", Data(manifest.utf8)),
            ("bg.js", Data("chrome.runtime.onInstalled.addListener(() => {});".utf8)),
            ("popup.html", Data("<html><head></head><body></body></html>".utf8)),
            ("icons/", Data()),
            ("icons/a.png", icon),
        ])
        var files: [String: Data] = [:]
        var order: [String] = []
        try ExtensionPreparation.prepare(archive, shim: "/* shim */", stamp: "made") { path, data in
            files[path] = data
            order.append(path)
        }
        XCTAssertEqual(order.last, ExtensionPreparation.stampFile)
        XCTAssertNil(files["icons/"])
        XCTAssertEqual(files["icons/a.png"], icon)
        XCTAssertEqual(files[ExtensionPreparation.shimFile], Data("/* shim */".utf8))
        XCTAssertEqual(files[ExtensionPreparation.stampFile], Data("made".utf8))
        XCTAssertTrue(String(decoding: try XCTUnwrap(files["bg.js"]), as: UTF8.self).hasPrefix(ExtensionPreparation.shimMarks.0))
        XCTAssertTrue(String(decoding: try XCTUnwrap(files["popup.html"]), as: UTF8.self).contains("<head><script src=\"/_eglu/shim.js\">"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(files["manifest.json"])) as? [String: Any])
        XCTAssertEqual(object["permissions"] as? [String], ["nativeMessaging"])
    }

    func testABadPackageWritesNothing() {
        var written = 0
        let leading = Self.zip([("manifest.json", Data("{}".utf8)), ("../outside.js", Data("x".utf8))])
        XCTAssertThrowsError(try ExtensionPreparation.prepare(leading, shim: "", stamp: "") { _, _ in written += 1 }) {
            XCTAssertEqual($0 as? ExtensionPreparation.Problem, .unsafeName("../outside.js"))
        }
        let ours = Self.zip([("manifest.json", Data("{}".utf8)), ("_eglu/shim.js", Data("x".utf8))])
        XCTAssertThrowsError(try ExtensionPreparation.prepare(ours, shim: "", stamp: "") { _, _ in written += 1 })
        let bare = Self.zip([("bg.js", Data("x".utf8))])
        XCTAssertThrowsError(try ExtensionPreparation.prepare(bare, shim: "", stamp: "") { _, _ in written += 1 }) {
            XCTAssertEqual($0 as? ExtensionPreparation.Problem, .noManifest)
        }
        XCTAssertEqual(written, 0)
    }

    func testTheShimIsToldTheScriptsAndTheChrome() throws {
        let archive = Self.zip([("manifest.json", Data(#"{"background": {"service_worker": "bg.js"}}"#.utf8)),
                                ("bg.js", Data("x()".utf8)), ("lib/test.js", Data(" \n".utf8)), ("a.css", Data())])
        var files: [String: Data] = [:]
        try ExtensionPreparation.prepare(archive, shim: "s = /*__EGLU_SCRIPTS__*/null; v = \"__EGLU_CHROME__\";", stamp: "") { files[$0] = $1 }
        let shim = String(decoding: try XCTUnwrap(files[ExtensionPreparation.shimFile]), as: UTF8.self)
        XCTAssertEqual(shim, "s = [\"/bg.js\",\"-/lib/test.js\"]; v = \"\(ExtensionStore.chromeVersion)\";")
        XCTAssertTrue(String(decoding: try XCTUnwrap(files["bg.js"]), as: UTF8.self).contains(shim))
    }

    func testTheShimIsToldTheEventsTheCodeNames() throws {
        let archive = Self.zip([("manifest.json", Data(#"{"background": {"service_worker": "bg.js"}}"#.utf8)),
                                ("bg.js", Data("chrome.runtime.onConnect.addListener(f); e.tabs.onUpdated.addListener(g); x.onClick = 1".utf8)),
                                ("lib/a.mjs", Data("browser.storage.onChanged.addListener(h); chrome.runtime.onConnect".utf8)),
                                ("notes.txt", Data("chrome.alarms.onAlarm".utf8))])
        var files: [String: Data] = [:]
        try ExtensionPreparation.prepare(archive, shim: "e = /*__EGLU_EVENTS__*/[];", stamp: "") { files[$0] = $1 }
        let shim = String(decoding: try XCTUnwrap(files[ExtensionPreparation.shimFile]), as: UTF8.self)
        XCTAssertEqual(shim, #"e = ["runtime.onConnect","storage.onChanged","tabs.onUpdated"];"#)
    }

    func testAScriptWithUnicodeSaysItIsUTF8() throws {
        let korean = Data("const 인사 = /[가-힣]/;".utf8)
        let archive = Self.zip([("manifest.json", Data(#"{"background": {"service_worker": "bg.js"}}"#.utf8)),
                                ("bg.js", Data("x()".utf8)), ("content.js", korean), ("plain.js", Data("y()".utf8)),
                                ("tool.js", Data("#!/usr/bin/env node\nconst é = 1".utf8)), ("latin.js", Data([0x63, 0xE9, 0x0A]))])
        var files: [String: Data] = [:]
        try ExtensionPreparation.prepare(archive, shim: "", stamp: "") { files[$0] = $1 }
        XCTAssertEqual(files["content.js"], Data([0xEF, 0xBB, 0xBF]) + korean, "Unicode text, signed")
        XCTAssertEqual(files["plain.js"], Data("y()".utf8), "ASCII alone, as it was")
        XCTAssertEqual(files["tool.js"]?.prefix(2), Data("#!".utf8), "a hashbang stays first")
        XCTAssertEqual(files["latin.js"], Data([0x63, 0xE9, 0x0A]), "not UTF-8: left alone")
        XCTAssertEqual(ExtensionPreparation.signed(files["content.js"]!), files["content.js"], "signed once")
    }

    func testModulesThatAwaitBecomeOneThatImportsThemInOrder() throws {
        let page = #"<html><head><script type="module" src="base.js"></script><script type="module" src="./defs.js" blocking="render"></script></head></html>"#
        let archive = Self.zip([("manifest.json", Data(#"{"options_page": "pages/options.html"}"#.utf8)),
                                ("pages/options.html", Data(page.utf8)), ("pages/base.js", Data("export const d = await load();".utf8)),
                                ("pages/defs.js", Data("import { d } from './base.js';".utf8)),
                                ("plain.html", Data(#"<script type="module" src="a.js"></script><script type="module" src="b.js"></script>"#.utf8)),
                                ("a.js", Data("export const a = 1;".utf8)), ("b.js", Data("import { a } from './a.js';".utf8))])
        var files: [String: Data] = [:]
        try ExtensionPreparation.prepare(archive, shim: "", stamp: "") { files[$0] = $1 }
        let options = String(decoding: try XCTUnwrap(files["pages/options.html"]), as: UTF8.self)
        let wrapper = "eglu-modules-options-" + ExtensionPreparation.shortHash("pages/options.html") + ".js"
        XCTAssertTrue(options.contains(#"<script type="module" src=""# + wrapper + #""></script>"#), options)
        XCTAssertFalse(options.contains("defs.js"), "the other tags are gone")
        XCTAssertEqual(String(decoding: try XCTUnwrap(files["pages/" + wrapper]), as: UTF8.self),
                       "// eGlu: this page's module scripts, in their order (ExtensionPreparation.chainModules).\nimport \"./base.js\";\nimport \"./defs.js\";\n")
        let plain = String(decoding: try XCTUnwrap(files["plain.html"]), as: UTF8.self)
        XCTAssertTrue(plain.contains(#"src="a.js""#) && plain.contains(#"src="b.js""#), "no await: as it was")
        XCTAssertNil(files["eglu-modules-plain.js"])
    }

    func testRulesWebKitWouldCarryOutEverywhereAreLeftOut() throws {
        let rules = #"[{"id":1,"action":{"type":"redirect","redirect":{"extensionPath":"/strict.html"}},"condition":{"regexFilter":"^https?://.*","requestDomains":["bad.example"]}},"#
            + #"{"id":2,"action":{"type":"block"},"condition":{"regexFilter":"^https?://.*","requestDomains":["bad.example"]}},"#
            + #"{"id":3,"action":{"type":"redirect","redirect":{"extensionPath":"/b.html"}},"condition":{"urlFilter":"||x.example","requestDomains":["x.example"]}}]"#
        let manifest = #"{"declarative_net_request": {"rule_resources": [{"id": "a", "enabled": true, "path": "rules/a.json"}]}}"#
        let archive = Self.zip([("manifest.json", Data(manifest.utf8)), ("rules/a.json", Data(rules.utf8)), ("other.json", Data(rules.utf8))])
        var files: [String: Data] = [:]
        try ExtensionPreparation.prepare(archive, shim: "", stamp: "") { files[$0] = $1 }
        let kept = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files["rules/a.json"])) as? [[String: Any]])
        XCTAssertEqual(kept.compactMap { $0["id"] as? Int }, [2, 3], "the redirect with a pattern beside sites goes; a block of that shape and a redirect by urlFilter stay")
        XCTAssertEqual(files["other.json"], Data(rules.utf8), "a file that isn't a ruleset is left alone")
    }

    func testTheModuleChainSkipsCommentsHashesAndNamesTaken() {
        let files = ["a.js": Data("await x;".utf8), "b.js": Data("y()".utf8)]
        let tags = #"<script type="module" src="a.js"></script><script type="module" src="b.js"></script>"#
        let stem = "eglu-modules-page-" + ExtensionPreparation.shortHash("page.html")
        // A tag in a comment is no tag: one module left, nothing to chain.
        XCTAssertNil(ExtensionPreparation.chainModules(#"<!-- <script type="module" src="a.js"></script> --><script type="module" src="b.js"></script>"#,
                                                       page: "page.html", read: { files[$0] }))
        let quoted = #"<script>const marker = "<!--";</script><script type="module" src="a.js"></script><script type="module" src="b.js"></script>"#
        XCTAssertNotNil(ExtensionPreparation.chainModules(quoted, page: "page.html", read: { files[$0] }), "\"<!--\" in a script's text opens no comment")
        let shown = #"<textarea><!--<script type="module" src="a.js"></script>--></textarea><script type="module" src="b.js"></script>"#
        XCTAssertNil(ExtensionPreparation.chainModules(shown, page: "page.html", read: { files[$0] }), "a tag shown in a text box is text")
        XCTAssertNil(ExtensionPreparation.chainModules(#"<base href="/">"# + tags, page: "page.html", read: { files[$0] }), "a <base> page left alone")
        XCTAssertNotNil(ExtensionPreparation.chainModules(#"<base data-href="/x/">"# + tags, page: "page.html", read: { files[$0] }), "data-href is no href")
        XCTAssertNil(ExtensionPreparation.chainModules(#"<base/href="/x/">"# + tags, page: "page.html", read: { files[$0] }), "<base/href> is a base too")
        XCTAssertNil(ExtensionPreparation.chainModules(#"<textarea></textareax>"# + tags + "</textarea>", page: "page.html", read: { files[$0] }),
                     "\"</textareax>\" closes no text box")
        XCTAssertNotNil(ExtensionPreparation.chainModules(#"<!-- <script> -->"# + tags, page: "page.html", read: { files[$0] }), "\"<script>\" in a comment opens no script")
        XCTAssertNil(ExtensionPreparation.chainModules(#"<script type="module" src="a.js"></script><script type="module">globalThis.c = 1;</script><script type="module" src="b.js"></script>"#,
                                                       page: "page.html", read: { files[$0] }), "an inline module between them: left as it is")
        XCTAssertNil(ExtensionPreparation.chainModules(#"<script type="module" src="a.js" integrity="sha384-x"></script><script type="module" src="b.js"></script>"#,
                                                       page: "page.html", read: { files[$0] }), "a hash to check: left alone")
        let taken = files.merging([stem + ".js": Data()]) { $1 }
        XCTAssertEqual(ExtensionPreparation.chainModules(tags, page: "page.html", read: { taken[$0] })?.file, stem + "-2.js")
        XCTAssertNotEqual(ExtensionPreparation.chainModules(tags, page: "page.html", read: { files[$0] })?.file,
                          ExtensionPreparation.chainModules(tags, page: "page.htm", read: { files[$0] })?.file)
    }

    func testAMethodToInjectIsReadAsAFunction() {
        XCTAssertEqual(ExtensionPreparation.expression(of: "inject(a) { return a }"), #"({inject(a) { return a }})["inject"]"#)
        XCTAssertEqual(ExtensionPreparation.expression(of: "async go() {}"), #"({async go() {}})["go"]"#)
        XCTAssertEqual(ExtensionPreparation.expression(of: "*gen() {}"), #"({*gen() {}})["gen"]"#)
        for left in ["function (a) {}", "function named(a) {}", "async function (a) {}", "async (a) => a", "(a) => a", "a => a"] {
            XCTAssertEqual(ExtensionPreparation.expression(of: left), left)
        }
    }

    func testAScriptWithAnIntegrityHashIsLeftUnsigned() throws {
        let korean = Data("const 인사 = 1;".utf8)
        let archive = Self.zip([("manifest.json", Data(#"{"options_page": "pages/options.html"}"#.utf8)),
                                ("pages/options.html", Data((#"<script data-src="free.js" src="../lib/checked.js?v=2" integrity="sha256-x"></script><script src="free.js"></script>"#
                                    + #"<!-- <script src="other.js" integrity="sha256-y"></script> --><script src="other.js"></script><script src="my%20lib.js" integrity="sha256-z"></script>"#).utf8)),
                                ("lib/checked.js", korean), ("pages/free.js", korean), ("pages/other.js", korean), ("pages/my lib.js", korean)])
        var files: [String: Data] = [:]
        try ExtensionPreparation.prepare(archive, shim: "", stamp: "") { files[$0] = $1 }
        XCTAssertEqual(files["lib/checked.js"], korean, "its hash still holds")
        XCTAssertEqual(files["pages/free.js"], Data([0xEF, 0xBB, 0xBF]) + korean, "data-src is not src")
        XCTAssertEqual(files["pages/other.js"], Data([0xEF, 0xBB, 0xBF]) + korean, "a hash in a comment checks nothing")
        XCTAssertEqual(files["pages/my lib.js"], korean, "named with %20")
    }

    func testTheStampFollowsTheShim() {
        XCTAssertNotEqual(ExtensionPreparation.stamp(for: "a"), ExtensionPreparation.stamp(for: "b"))
        XCTAssertEqual(ExtensionPreparation.stamp(for: "a"), ExtensionPreparation.stamp(for: "a"))
        XCTAssertTrue(ExtensionPreparation.stamp(for: "a").hasPrefix("\(ExtensionPreparation.version)-"))
    }

    func testTheShimShips() {
        let shim = Scripts.extensionShim
        XCTAssertTrue(shim.contains("__egluShim"))
        XCTAssertTrue(shim.contains("sendNativeMessage(\"eglu\""))
    }

    /// Files stored in a ZIP, without CRCs, which the reader doesn't check.
    static func zip(_ files: [(String, Data)]) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func u16(_ value: Int, _ to: inout [UInt8]) { to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func u32(_ value: Int, _ to: inout [UInt8]) {
            to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
        }
        for (name, data) in files {
            let nameBytes = Array(name.utf8)
            let offset = out.count
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out); u32(0, &out)
            u32(data.count, &out); u32(data.count, &out); u16(nameBytes.count, &out); u16(0, &out)
            out += nameBytes
            out += data
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(data.count, &central); u32(data.count, &central)
            u16(nameBytes.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central)
            central += nameBytes
        }
        let start = out.count
        out += central
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(central.count, &out); u32(start, &out); u16(0, &out)
        return Data(out)
    }
}
