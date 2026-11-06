#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import PadCore
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

private struct ScriptRefusal: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

@MainActor
private final class ScriptHost: ExtensionScriptHost {
    var extensionScriptRoot: URL
    var installations: [String: WebExtensionScriptInstallation] = [:]
    var queries: [String] = []
    var onInstallation: (() -> Void)?

    init(_ root: URL) { extensionScriptRoot = root }
    func extensionScriptInstallation(_ identity: () -> String) -> WebExtensionScriptInstallation? {
        let id = identity()
        queries.append(id)
        onInstallation?()
        return installations[id]
    }
}

final class ExtensionScriptAnswersTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-answers-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = try XCTUnwrap(root.withUnsafeFileSystemRepresentation { realpath($0!, nil) })
        defer { free(path) }
        return URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
    }

    @MainActor
    private func runtime(_ host: ScriptHost, prepared: URL? = nil) -> WebKitExtensionScriptAnswers {
        WebKitExtensionScriptAnswers(host: host, prepared: { id, version in
            (prepared ?? host.extensionScriptRoot.appendingPathComponent(id)).appendingPathComponent(version)
        }, unanswered: { ScriptRefusal(why: $0) })
    }

    private func age(_ file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: file.path)
    }

    private func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    private func refusal(_ words: String, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? ScriptRefusal)?.why, words, file: file, line: line)
        }
    }

    @MainActor
    func testFunctionBytesHashesLimitsAndOldFiles() throws {
        let root = try folder(), host = ScriptHost(root)
        let answers: any WebExtensionScriptAnswers = runtime(host)
        let expected = "((x) => x)(...[7,\"text\"])\n"
        let path = try answers.scriptingFile(" (x) => x \n", arguments: [7, "text"], in: root)
        XCTAssertEqual(try text(root.appendingPathComponent(path)), expected)
        XCTAssertEqual(path, "_eglu/script-" + SHA256.hash(data: Data(expected.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js")
        let method = try answers.scriptingFile("inject(x) { return x; }", arguments: [], in: root)
        XCTAssertEqual(try text(root.appendingPathComponent(method)), "(({inject(x) { return x; }})[\"inject\"])(...[])\n")
        let dir = root.appendingPathComponent("_eglu")
        let old = dir.appendingPathComponent("script-old.js"), fresh = dir.appendingPathComponent("script-fresh.js")
        let other = dir.appendingPathComponent("us-other.js"), current = root.appendingPathComponent(path)
        for file in [old, fresh, other] { try Data("fixture".utf8).write(to: file) }
        for file in [old, other, current] { try age(file) }
        let before = try current.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(try answers.scriptingFile("(x) => x", arguments: [7, "text"], in: root), path)
        XCTAssertEqual(try current.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for file in [fresh, other, current] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path) }
        let invalid = "Invalid script function or arguments"
        refusal(invalid) { try answers.scriptingFile("", arguments: [], in: root) }
        refusal(invalid) { try answers.scriptingFile("() => 1", arguments: [Date()], in: root) }
        refusal(invalid) { try answers.scriptingFile(String(repeating: "é", count: 500_001), arguments: [], in: root) }
        refusal(invalid) { try answers.scriptingFile("() => 1", arguments: [String(repeating: "a", count: 1_000_000)], in: root) }
    }

    @MainActor
    func testUserScriptBytesWorldsAndContentNames() throws {
        let root = try folder(), answers = runtime(ScriptHost(root))
        let script: [String: Any] = ["world": "MAIN", "js": [["code": "globalThis.answer = 7;"]],
                                     "includeGlobs": ["*example*"], "excludeGlobs": ["*private*"]]
        let main = try answers.userScriptFile(script, in: root, writing: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("_eglu").path))
        XCTAssertEqual(try answers.userScriptFile(script, in: root), main)
        XCTAssertEqual(try text(root.appendingPathComponent(main)), Self.mainBytes)
        XCTAssertEqual(main, Self.mainPath)
        var user = script
        user["world"] = "USER_SCRIPT"
        let isolated = try answers.userScriptFile(user, in: root)
        XCTAssertEqual(try text(root.appendingPathComponent(isolated)), Self.userBytes)
        XCTAssertEqual(isolated, Self.userPath)
        user["world"] = nil
        XCTAssertEqual(try answers.userScriptFile(user, in: root), isolated)
        user["world"] = "main"
        XCTAssertEqual(try answers.userScriptFile(user, in: root), isolated)
        user["id"] = "different-id"
        user["worldId"] = "different-world"
        XCTAssertEqual(try answers.userScriptFile(user, in: root), isolated)
        user["js"] = [["code": "globalThis.answer = 8;"]]
        XCTAssertNotEqual(try answers.userScriptFile(user, in: root), isolated)
        try age(root.appendingPathComponent(isolated))
        let before = try root.appendingPathComponent(isolated).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        user["js"] = script["js"]
        XCTAssertEqual(try answers.userScriptFile(user, in: root), isolated)
        XCTAssertEqual(try root.appendingPathComponent(isolated).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
    }

    @MainActor
    func testUserScriptPathsResolveContainmentAndRejectLinksAndTraversal() throws {
        let root = try folder(), prepared = root.appendingPathComponent("prepared", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        for dir in [prepared, outside, prepared.appendingPathComponent("sub")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "globalThis.local = 1;".write(to: prepared.appendingPathComponent("local.js"), atomically: true, encoding: .utf8)
        try "globalThis.secret = 1;".write(to: outside.appendingPathComponent("outside.js"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: prepared.appendingPathComponent("leaf.js"), withDestinationURL: prepared.appendingPathComponent("local.js"))
        try FileManager.default.createSymbolicLink(at: prepared.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: prepared.appendingPathComponent("internal"), withDestinationURL: prepared)
        let answers = runtime(ScriptHost(root))
        func made(_ names: [String]) throws -> String {
            let path = try answers.userScriptFile(["world": "MAIN", "js": names.map { ["file": $0] }], in: prepared)
            return try text(prepared.appendingPathComponent(path))
        }
        let empty = try made([])
        for name in ["../outside/outside.js", "sub/../../outside/outside.js", "leaf.js", "escape/outside.js", "missing.js", "."] {
            XCTAssertEqual(try made([name]), empty, name)
        }
        let local = try made(["local.js"])
        XCTAssertTrue(local.contains("globalThis.local = 1;\n;\n"))
        for name in ["/local.js/", "sub/../local.js", "internal/local.js"] {
            XCTAssertEqual(try made([name]), local, name)
        }
        XCTAssertFalse(try made(["../outside/outside.js", "local.js", "escape/outside.js"]).contains("secret"))
        let both = try answers.userScriptFile(["world": "MAIN", "js": [["code": "inline", "file": "local.js"]]], in: prepared)
        XCTAssertTrue(try text(prepared.appendingPathComponent(both)).contains("inline\n;\n"))
        XCTAssertFalse(try text(prepared.appendingPathComponent(both)).contains("globalThis.local"))
    }

    @MainActor
    func testListsKeepSpaceAndExtensionIdentityAndFailedChangesKeepDiskBytes() throws {
        let root = try folder(), host = ScriptHost(root), answers = runtime(host)
        let space = UUID(), other = UUID(), id = UUID().uuidString
        XCTAssertEqual(answers.kept("userscripts", of: id, in: space), root.appendingPathComponent(id).appendingPathComponent("_eglu/userscripts-\(space.uuidString).json"))
        XCTAssertTrue((answers.userScripts(of: id, in: space) as? [Any])?.isEmpty == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
        let added: [String: Any] = ["id": "first", "js": [["code": "one"]], "matches": ["<all_urls>"]]
        let result = try answers.changeUserScripts(["add": [added]], of: id, in: space)
        XCTAssertEqual(result.count, 1)
        let file = answers.kept("userscripts", of: id, in: space), before = try Data(contentsOf: file)
        refusal("Duplicate script id 'first'") { try answers.changeUserScripts(["add": [["id": "new"], added]], of: id, in: space) }
        refusal("Script with id 'missing' does not exist") { try answers.changeUserScripts(["update": [["id": "missing"]]], of: id, in: space) }
        refusal("Invalid scripts.") { try answers.changeUserScripts(["add": [["id": "bad", "value": Date()]]], of: id, in: space) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let updated = try answers.changeUserScripts(["update": [["id": "first", "js": [["code": "two"]]]]], of: id, in: space)
        XCTAssertEqual(updated.first?["matches"] as? [String], ["<all_urls>"])
        XCTAssertEqual((updated.first?["js"] as? [[String: String]])?.first?["code"], "two")
        XCTAssertEqual((answers.userScripts(of: id, in: space) as? [[String: Any]])?.count, 1)
        XCTAssertTrue((answers.userScripts(of: id, in: other) as? [Any])?.isEmpty == true)
        XCTAssertTrue((answers.userScripts(of: "other", in: space) as? [Any])?.isEmpty == true)
        XCTAssertTrue(try answers.changeUserScripts(["add": [["id": "new"]], "update": [["id": "new", "value": 1]], "remove": ["first", "new"]], of: id, in: space).isEmpty)
        try Data("broken".utf8).write(to: file)
        XCTAssertTrue((answers.userScripts(of: id, in: space) as? [Any])?.isEmpty == true)
        try Data(#"{"kept":true}"#.utf8).write(to: file)
        XCTAssertEqual((answers.userScripts(of: id, in: space) as? [String: Bool])?["kept"], true)
        refusal("Duplicate script id ''") { try answers.changeUserScripts(["add": [[:], [:]]], of: id, in: other) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: answers.kept("userscripts", of: id, in: other).path))
    }

    @MainActor
    func testWorldsReplaceResetAndKeepOtherSpacesAndLists() throws {
        let root = try folder(), answers = runtime(ScriptHost(root)), space = UUID(), other = UUID()
        XCTAssertTrue(answers.userScriptWorlds(of: "fixture", in: space).isEmpty)
        try answers.setUserScriptWorld(["worldId": "a", "csp": "first"], of: "fixture", in: space)
        try answers.setUserScriptWorld(["worldId": "b", "messaging": true], of: "fixture", in: space)
        try answers.setUserScriptWorld(["worldId": "a", "csp": "second"], of: "fixture", in: space)
        var worlds = answers.userScriptWorlds(of: "fixture", in: space)
        XCTAssertEqual(worlds.compactMap { $0["worldId"] as? String }, ["b", "a"])
        XCTAssertEqual(worlds.last?["csp"] as? String, "second")
        try answers.setUserScriptWorld(["worldId": "a", "reset": true], of: "fixture", in: space)
        try answers.setUserScriptWorld(["worldId": "b", "invalid": Date()], of: "fixture", in: space)
        XCTAssertTrue(answers.userScriptWorlds(of: "fixture", in: space).isEmpty)
        try answers.setUserScriptWorld(nil, of: "fixture", in: space)
        try answers.setUserScriptWorld(["csp": "default"], of: "fixture", in: space)
        worlds = answers.userScriptWorlds(of: "fixture", in: space)
        XCTAssertEqual(worlds.count, 1)
        XCTAssertEqual(worlds.first?["csp"] as? String, "default")
        XCTAssertTrue(answers.userScriptWorlds(of: "fixture", in: other).isEmpty)
        XCTAssertTrue((answers.userScripts(of: "fixture", in: space) as? [Any])?.isEmpty == true)
        try Data("broken".utf8).write(to: answers.kept("worlds", of: "fixture", in: space))
        XCTAssertTrue(answers.userScriptWorlds(of: "fixture", in: space).isEmpty)
    }

    @MainActor
    func testPruningUsesEverySpaceListAndPreservesRecentAndOtherFiles() throws {
        let root = try folder(), host = ScriptHost(root), answers = runtime(host), id = UUID().uuidString
        defer { WebKitExtensionScriptAnswers.pruned[id] = nil }
        let prepared = root.appendingPathComponent("prepared")
        let first: [String: Any] = ["id": "one", "js": [["code": "one"]]]
        let second: [String: Any] = ["id": "two", "js": [["code": "two"]]]
        let one = try answers.userScriptFile(first, in: prepared), two = try answers.userScriptFile(second, in: prepared)
        for script in [first, second] {
            let list = answers.kept("userscripts", of: id, in: UUID())
            try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [script]).write(to: list)
        }
        let listDir = answers.kept("userscripts", of: id, in: UUID()).deletingLastPathComponent()
        try Data("broken".utf8).write(to: listDir.appendingPathComponent("userscripts-broken.json"))
        let dir = prepared.appendingPathComponent("_eglu")
        let obsolete = dir.appendingPathComponent("us-obsolete.js"), recent = dir.appendingPathComponent("us-recent.js")
        let function = dir.appendingPathComponent("script-kept.js"), other = dir.appendingPathComponent("other.js")
        for file in [obsolete, recent, function, other] { try Data("fixture".utf8).write(to: file) }
        for file in [prepared.appendingPathComponent(one), prepared.appendingPathComponent(two), obsolete, function, other] { try age(file) }
        answers.pruneUserScripts(of: id, in: prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path))
        for file in [prepared.appendingPathComponent(one), prepared.appendingPathComponent(two), recent, function, other] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
        }
        XCTAssertNotNil(WebKitExtensionScriptAnswers.pruned[id])
        XCTAssertFalse(WebKitExtensionScriptAnswers.prunePending.contains(id))
        let unregistered: [String: Any] = ["id": "absent", "js": [["code": "absent"]]]
        let space = UUID()
        host.onInstallation = {
            XCTAssertEqual((answers.userScripts(of: id, in: space) as? [[String: Any]])?.first?["id"] as? String, "absent",
                           "Catalog lookup stays after the list's atomic write")
        }
        _ = try answers.changeUserScripts(["add": [unregistered]], of: id, in: space)
        XCTAssertEqual(host.queries, [id])
        XCTAssertFalse(WebKitExtensionScriptAnswers.prunePending.contains(id), "No installation means no prune is scheduled")
    }

    @MainActor
    func testPendingPruneIsSharedAndRunsOnceWithTheFirstFolder() async throws {
        let root = try folder(), host = ScriptHost(root), answers = runtime(host), second = runtime(host)
        let id = UUID().uuidString
        let firstFolder = root.appendingPathComponent("first"), secondFolder = root.appendingPathComponent("second")
        let firstFile = firstFolder.appendingPathComponent("_eglu/us-old.js"), secondFile = secondFolder.appendingPathComponent("_eglu/us-old.js")
        for file in [firstFile, secondFile] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
            try age(file)
        }
        // Keep the real dispatch and its extra second, without waiting a minute.
        WebKitExtensionScriptAnswers.pruned[id] = Date(timeIntervalSinceNow: -59)
        defer {
            WebKitExtensionScriptAnswers.pruned[id] = nil
            WebKitExtensionScriptAnswers.prunePending.remove(id)
        }
        answers.pruneUserScripts(of: id, in: firstFolder)
        let before = WebKitExtensionScriptAnswers.pruned[id]
        second.pruneUserScripts(of: id, in: secondFolder)
        XCTAssertTrue(WebKitExtensionScriptAnswers.prunePending.contains(id))
        XCTAssertEqual(WebKitExtensionScriptAnswers.pruned[id], before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))
        try await Task.sleep(for: .milliseconds(2600))
        XCTAssertFalse(WebKitExtensionScriptAnswers.prunePending.contains(id))
        XCTAssertNotEqual(WebKitExtensionScriptAnswers.pruned[id], before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path), "The second request must not replace the pending folder")
    }

    @MainActor
    func testManagementUsesTheGivenCatalogValuesAndRefusesOtherIDsBeforeLookingUp() async throws {
        let root = try folder(), host = ScriptHost(root), answers = runtime(host)
        let files: [(String, Data)] = [
            ("manifest.json", Data(#"{"manifest_version":3,"name":"Fixture name","short_name":"Short","description":"Fixture description","version":"1.2","permissions":["storage","scripting"],"host_permissions":["https://z.invalid/*","https://a.invalid/*"],"options_ui":{"page":"options.html"}}"#.utf8)),
            ("options.html", Data("<!doctype html>".utf8))
        ]
        let archive = Self.zip(files)
        try archive.write(to: root.appendingPathComponent("fixture.zip"))
        for (name, _) in files {
            try XCTUnwrap(ZipFile.file(in: archive, matching: { $0 == name })).write(to: root.appendingPathComponent(name))
        }
        // Only parsed, never installed or loaded. No controller, store or view.
        let package = try await WKWebExtension(resourceBaseURL: root)
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "fixture"
        context.baseURL = URL(string: "chrome-extension://fixture/")!
        host.installations["fixture"] = .init(id: "fixture", name: "Catalog name", version: "9", isUnsigned: true)
        let info = try answers.management("management.getSelf", first: nil, id: "fixture", context: context)
        let expected: [String: Any] = [
            "id": "fixture", "name": "Fixture name", "shortName": "Short", "description": "Fixture description", "version": "1.2",
            "enabled": true, "mayDisable": true, "offlineEnabled": false, "type": "extension", "installType": "development",
            "permissions": ["scripting", "storage"], "hostPermissions": ["https://a.invalid/*", "https://z.invalid/*"], "isApp": false,
            "optionsUrl": "chrome-extension://fixture/options.html"
        ]
        XCTAssertEqual(info as NSDictionary, expected as NSDictionary)
        XCTAssertEqual(try answers.management("management.get", first: "fixture", id: "fixture", context: context) as NSDictionary, expected as NSDictionary)
        XCTAssertEqual(host.queries, ["fixture", "fixture"])
        refusal("No extension with id other") { try answers.management("management.get", first: "other", id: "fixture", context: context) }
        refusal("No extension with id ") { try answers.management("management.get", first: nil, id: "fixture", context: context) }
        XCTAssertEqual(host.queries.count, 2)
        host.installations["fixture"] = .init(id: "fixture", name: "Catalog name", version: "9", isUnsigned: false)
        XCTAssertEqual(try answers.management("management.getSelf", first: nil, id: "fixture", context: context)["installType"] as? String, "normal")
        host.installations = [:]
        XCTAssertEqual(try answers.management("management.getSelf", first: nil, id: "fixture", context: context)["installType"] as? String, "normal")
        let minimalFolder = try folder()
        try Data(#"{"manifest_version":3}"#.utf8).write(to: minimalFolder.appendingPathComponent("manifest.json"))
        let minimalPackage = try await WKWebExtension(resourceBaseURL: minimalFolder)
        let minimal = WKWebExtensionContext(for: minimalPackage)
        minimal.uniqueIdentifier = "minimal"
        host.installations["minimal"] = .init(id: "minimal", name: "Saved name", version: "7", isUnsigned: true)
        let fallback = try answers.management("management.getSelf", first: nil, id: "minimal", context: minimal)
        XCTAssertEqual(fallback["name"] as? String, "Saved name")
        XCTAssertEqual(fallback["version"] as? String, "7")
        XCTAssertEqual(fallback["shortName"] as? String, "")
        XCTAssertNil(fallback["optionsUrl"])
        host.installations = [:]
        let missing = try answers.management("management.getSelf", first: nil, id: "minimal", context: minimal)
        XCTAssertEqual(missing["name"] as? String, "")
        XCTAssertEqual(missing["version"] as? String, "")
        XCTAssertFalse(context.isLoaded)
        XCTAssertFalse(minimal.isLoaded)
    }

    @MainActor
    func testScriptAnswerGuardsAndCatalogPaths() async throws {
        let root = try folder(), host = ScriptHost(root), answers = runtime(host), id = UUID().uuidString
        try Data(#"{"manifest_version":3,"name":"Fixture","version":"1","permissions":["scripting"]}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        let package = try await WKWebExtension(resourceBaseURL: root)
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = id
        context.setPermissionStatus(.deniedExplicitly, for: .scripting)
        refusal("The extension never asked for \u{201C}scripting\u{201D}") {
            try answers.scripting("() => 1", arguments: [], id: id, context: context)
        }
        XCTAssertTrue(host.queries.isEmpty)
        context.setPermissionStatus(.grantedExplicitly, for: .scripting)
        refusal("No such extension.") { try answers.scripting("() => 1", arguments: [], id: id, context: context) }
        refusal("No such extension.") { try answers.userScriptFile([:], of: id) }
        XCTAssertEqual(host.queries, [id, id])
        host.installations[id] = .init(id: id, name: "Saved", version: "9", isUnsigned: false)
        let path = try answers.scripting("(x) => x", arguments: ["(x) => x", [2]], id: id, context: context)
        let prepared = root.appendingPathComponent(id).appendingPathComponent("9")
        XCTAssertEqual(try text(prepared.appendingPathComponent(path)), "((x) => x)(...[2])\n")
        let user = try answers.userScriptFile(["world": "MAIN", "js": [["code": "fixture"]]], of: id)
        XCTAssertTrue(try text(prepared.appendingPathComponent(user)).contains("fixture\n;\n"))
        refusal("Invalid script function or arguments") { try answers.scripting(nil, arguments: [], id: id, context: context) }
        let space = UUID()
        _ = try answers.changeUserScripts(["add": [["id": "registered"]]], of: id, in: space)
        XCTAssertNotNil(WebKitExtensionScriptAnswers.pruned.removeValue(forKey: id))
        XCTAssertFalse(WebKitExtensionScriptAnswers.prunePending.contains(id))
        XCTAssertFalse(context.isLoaded)
    }

    private static let mainPath = "_eglu/us-ccb3aa868e7a3f09.js"
    private static let mainBytes = #"""
    /* eGlu: a user script (chrome.userScripts) */
    eglu_user_script: {
      const __egluHref = location.href;
      const __egluGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
      const __egluIn = ["*example*"], __egluOut = ["*private*"];
      if ((__egluIn.length && !__egluIn.some((g) => __egluGlob(g).test(__egluHref))) || __egluOut.some((g) => __egluGlob(g).test(__egluHref))) break eglu_user_script;
    
    globalThis.answer = 7;
    ;
    
    }
    """#

    private static let userPath = "_eglu/us-1b341f4f5b5d38de.js"
    private static let userBytes = #"""
    /* eGlu: a user script (chrome.userScripts) */
    eglu_user_script: {
      const __egluHref = location.href;
      const __egluGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
      const __egluIn = ["*example*"], __egluOut = ["*private*"];
      if ((__egluIn.length && !__egluIn.some((g) => __egluGlob(g).test(__egluHref))) || __egluOut.some((g) => __egluGlob(g).test(__egluHref))) break eglu_user_script;
      const chrome = (() => {
        const runtime = globalThis.chrome.runtime;
        return { runtime: {
          id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
          sendMessage: (message, ...rest) => runtime.sendMessage({ __egluUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
          connect: (info) => runtime.connect({ ...(info || {}), name: "eglu-us:" + ((info && info.name) || "") }),
        } };
      })();
      const browser = chrome;
    globalThis.answer = 7;
    ;
    
    }
    """#

    private static func zip(_ files: [(String, Data)]) -> Data {
        var out: [UInt8] = [], central: [UInt8] = []
        func u16(_ value: Int, _ to: inout [UInt8]) { to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func u32(_ value: Int, _ to: inout [UInt8]) {
            to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
        }
        for (name, data) in files {
            let nameBytes = Array(name.utf8), offset = out.count
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out); u32(0, &out)
            u32(data.count, &out); u32(data.count, &out); u16(nameBytes.count, &out); u16(0, &out)
            out += nameBytes; out += data
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(data.count, &central); u32(data.count, &central)
            u16(nameBytes.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central); central += nameBytes
        }
        let start = out.count
        out += central
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(central.count, &out); u32(start, &out); u16(0, &out)
        return Data(out)
    }
}
#endif
