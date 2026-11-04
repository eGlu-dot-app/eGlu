import Foundation
import Testing
@testable import PadCore

struct ExtensionCompatibilityTests {
    private let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    @Test func uppercaseExtensionOriginsStayInternalAndKeepTheResource() throws {
        let input = try #require(URL(string: "CHROME-EXTENSION://\(id.uppercased())/inline/Tutorial.html?next=%2Fvault#start"))
        #expect(!AppLink.isOne(scheme: input.scheme))
        #expect(ExtensionURL.identifier(in: input) == id)
        let url = ExtensionURL.normalized(input)
        #expect(url.absoluteString == "chrome-extension://\(id)/inline/Tutorial.html?next=%2Fvault#start")
        #expect(ExtensionURL.normalized(url) == url)
    }

    @Test(arguments: ["chrome-extension://user@id/page", "chrome-extension://id:123/page", "https://id/page"])
    func extensionOriginsRejectCredentialsPortsAndWebsites(address: String) throws {
        #expect(ExtensionURL.identifier(in: try #require(URL(string: address))) == nil)
    }

    @Test func bookmarkMovesCannotLoseDataOrCreateCycles() throws {
        let link = Bookmark(title: "A", url: try #require(URL(string: "https://a.example/")))
        let child = Bookmark(folder: "Child", children: [link])
        let parent = Bookmark(folder: "Parent", children: [child])
        var tree = ExtensionBookmarks([parent])
        #expect(throws: ExtensionBookmarks.Failure.self) {
            try tree.answer("move", arguments: [parent.id.uuidString, ["parentId": child.id.uuidString]])
        }
        #expect(tree.items == [parent])
        #expect(throws: ExtensionBookmarks.Failure.self) {
            try tree.answer("move", arguments: [link.id.uuidString, ["parentId": "1", "index": 99]])
        }
        #expect(tree.items == [parent])
        #expect(tree.events.isEmpty)
        #expect(throws: ExtensionBookmarks.Failure.self) { try tree.answer("remove", arguments: [parent.id.uuidString]) }
        _ = try tree.answer("move", arguments: [link.id.uuidString, ["parentId": "1", "index": 0]])
        #expect(tree.items.first == link)
        #expect(Bookmarks.find(child.id, in: tree.items)?.children?.isEmpty == true)
        #expect(tree.events.last?.name == "bookmarks.onMoved")
    }

    @Test func bookmarksExposeFixedRootsAndScopeEveryLookupToTheirTree() throws {
        let link = Bookmark(title: "A", url: try #require(URL(string: "https://a.example/")))
        var first = ExtensionBookmarks([link]), second = ExtensionBookmarks([])
        let root = try #require(try first.answer("getTree", arguments: []) as? [[String: Any]])
        #expect(root.first?["id"] as? String == "0")
        let children = try #require(root.first?["children"] as? [[String: Any]])
        #expect(children.first?["id"] as? String == "1")
        #expect(throws: ExtensionBookmarks.Failure.self) { try second.answer("get", arguments: [link.id.uuidString]) }
        #expect(throws: ExtensionBookmarks.Failure.self) { try first.answer("removeTree", arguments: ["1"]) }
        #expect(throws: ExtensionBookmarks.Failure.self) { try first.answer("create", arguments: [["parentId": link.id.uuidString, "title": "Wrong"]]) }
        #expect(first.items == [link])
        let added = try #require(try first.answer("create", arguments: [["url": "https://b.example/", "title": "B", "index": 0]]) as? [String: Any])
        #expect(added["parentId"] as? String == "1")
        #expect(first.items.first?.title == "B")
        #expect(second.items.isEmpty)
    }

    @Test func partialSupportNeverClaimsUnknownMembersWork() {
        let table = ExtensionAPITable(webKit: [:], shims: ExtensionAPITable.shims)
        for path in ["bookmarks.getTree", "history.search", "downloads.download", "notifications.create", "system.memory.getInfo", "tts.speak"] {
            #expect(table.works(path))
        }
        for path in ["downloads.pause", "downloads.unknown", "bookmarks.getRecent", "system.display.setDisplayProperties", "identity.getAuthToken", "debugger.attach"] {
            #expect(!table.works(path))
        }
    }

    @Test func nativeFailuresUsePlainWordsAndRecoveryInstructions() {
        #expect(ExtensionError.problem(in: "Invalid call to runtime.connectNative(). Specified native messaging host not found.", missing: []) == nil)
        var evidence = ExtensionEvidence()
        evidence.start = .started
        evidence.problems = [.init(kind: .wrongArguments, api: "runtime.connectNative")]
        evidence.unreachableApp = "1Password"
        evidence.nativeAppHelp = "Open or reinstall 1Password."
        let verdict = ExtensionVerdict(evidence)
        #expect(verdict.lines == ["Can't reach the 1Password app.", "Open or reinstall 1Password."])
        #expect(!verdict.lines.joined().contains("runtime."))
        evidence.unreachableApp = nil
        evidence.nativeAppHelp = nil
        #expect(ExtensionVerdict(evidence).lines == ["Can't connect to its desktop app."])
    }

    @Test func knownPlatformLimitsAreExplainedWithoutAPINames() {
        var evidence = ExtensionEvidence()
        evidence.start = .started
        evidence.unavailableCapabilities = ["debugger", "tabCapture"]
        let verdict = ExtensionVerdict(evidence)
        #expect(verdict.status == .someFeaturesDontWork)
        #expect(verdict.lines.contains { $0.contains("record an individual tab") })
        #expect(!verdict.lines.joined().contains("tabCapture"))
    }

    @Test func extensionHistoryUsesLiteralQueriesTimeOrderAndOneSpace() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("extension-history-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        let store = try HistoryStore(url: file)
        let space = UUID(), other = UUID(), now = Date()
        let older = HistoryVisit(space: space, url: try #require(URL(string: "https://example.com/old")), title: "100% saved", time: now.addingTimeInterval(-10), device: "test", kind: .link)
        let newer = HistoryVisit(space: space, url: try #require(URL(string: "https://example.com/new")), title: "New", time: now, device: "test", kind: .typed)
        let hidden = HistoryVisit(space: other, url: try #require(URL(string: "https://private.example/")), title: "100% private", time: now, device: "test", kind: .link)
        try await store.record(older)
        try await store.record(newer)
        try await store.record(hidden)
        let literal = try await store.extensionSearch(space: space, text: "%", from: .distantPast, to: .distantFuture, limit: 100)
        #expect(literal.map(\.url) == [older.url])
        let recent = try await store.extensionSearch(space: space, text: "", from: .distantPast, to: .distantFuture, limit: 1)
        #expect(recent.map(\.url) == [newer.url])
        let visits = try await store.extensionVisits(space: space, url: hidden.url)
        #expect(visits.isEmpty)
    }
}
