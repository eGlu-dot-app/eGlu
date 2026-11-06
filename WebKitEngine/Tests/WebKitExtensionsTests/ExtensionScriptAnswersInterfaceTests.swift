#if os(macOS)
import Foundation
import WebEngineAppKit
import XCTest

// The interface can use this part of the runtime without importing a plugin.
@MainActor
private final class FakeScriptAnswers: WebExtensionScriptAnswers {
    var calls: [String] = []
    let root = URL(fileURLWithPath: "/unused-fixture")

    func kept(_ name: String, of id: String, in space: UUID) -> URL {
        calls.append("kept")
        return root.appendingPathComponent(name)
    }
    func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String { "_eglu/script-fixture.js" }
    func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool) throws -> String { "_eglu/us-fixture.js" }
    func userScripts(of id: String, in space: UUID) -> Any { [["id": "fixture"]] }
    func changeUserScripts(_ first: Any?, of id: String, in space: UUID) throws -> [[String: Any]] {
        calls.append("change")
        return [["id": "changed"]]
    }
    func userScriptWorlds(of id: String, in space: UUID) -> [[String: Any]] { [["worldId": "fixture"]] }
    func setUserScriptWorld(_ first: Any?, of id: String, in space: UUID) throws { calls.append("world") }
    func pruneUserScripts(of id: String, in folder: URL) { calls.append("prune") }
}

final class ExtensionScriptAnswersInterfaceTests: XCTestCase {
    @MainActor
    func testInterfaceUsesPathsListsAndWorldsWithoutWebKit() throws {
        let fake = FakeScriptAnswers(), space = UUID()
        let runtime: any WebExtensionScriptAnswers = fake
        XCTAssertEqual(runtime.kept("userscripts", of: "fixture", in: space), fake.root.appendingPathComponent("userscripts"))
        XCTAssertEqual(try runtime.scriptingFile("() => 1", arguments: [], in: fake.root), "_eglu/script-fixture.js")
        XCTAssertEqual(try runtime.userScriptFile([:], in: fake.root, writing: false), "_eglu/us-fixture.js")
        XCTAssertEqual((runtime.userScripts(of: "fixture", in: space) as? [[String: String]])?.first?["id"], "fixture")
        XCTAssertEqual(try runtime.changeUserScripts([:], of: "fixture", in: space).first?["id"] as? String, "changed")
        XCTAssertEqual(runtime.userScriptWorlds(of: "fixture", in: space).first?["worldId"] as? String, "fixture")
        try runtime.setUserScriptWorld([:], of: "fixture", in: space)
        runtime.pruneUserScripts(of: "fixture", in: fake.root)
        XCTAssertEqual(fake.calls, ["kept", "change", "world", "prune"])
    }
}
#endif
