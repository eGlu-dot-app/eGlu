import WebEngineCore
import WebKit
import WebKitSupport
import XCTest

@MainActor
private final class RuleListLoadDelegate: NSObject, WKNavigationDelegate {
    var completed: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completed?() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("Rule list fixture failed: \(error)")
        completed?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Rule list fixture failed before commit: \(error)")
        completed?()
    }
}

final class WebKitContentRulesTests: XCTestCase {
    private static let rules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#ad"}},
          {"trigger":{"url-filter":"tracker[.]invalid"},"action":{"type":"block"}}
        ]
        """

    @MainActor
    private func withStore(_ body: @MainActor (WebKitRuleListStore, WKContentRuleListStore) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuleLists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { XCTFail("Could not remove the rule list fixture: \(error)") }
        }
        let raw = try XCTUnwrap(WKContentRuleListStore(url: folder))
        try await body(WebKitRuleListStore(store: raw), raw)
    }

    @MainActor
    private func compile(_ id: String, in store: any WebRuleListStore, rules: String = WebKitContentRulesTests.rules)
        async -> ((any WebRuleList)?, (any Error)?) {
        await withCheckedContinuation { done in
            store.compile(forIdentifier: id, encodedRules: rules) { list, error in
                done.resume(returning: (list, error))
            }
        }
    }

    @MainActor
    private func lookUp(_ id: String, in store: any WebRuleListStore) async -> (any WebRuleList)? {
        await withCheckedContinuation { done in
            store.lookUp(forIdentifier: id) { list, _ in done.resume(returning: list) }
        }
    }

    @MainActor
    private func identifiers(in store: WKContentRuleListStore) async -> Set<String> {
        await withCheckedContinuation { done in
            store.getAvailableContentRuleListIdentifiers { done.resume(returning: Set($0 ?? [])) }
        }
    }

    @MainActor
    func testCompileAndLookUpKeepTheIdentifierAndUseWebKitLists() async throws {
        try await withStore { store, _ in
            let (made, error) = await compile("blocking.fixture", in: store)
            XCTAssertNil(error)
            let list = try XCTUnwrap(made as? WebKitRuleList)
            XCTAssertEqual(list.identifier, "blocking.fixture")
            let found = await lookUp(list.identifier, in: store)
            XCTAssertTrue(found is WebKitRuleList)
            XCTAssertEqual(found?.identifier, list.identifier)
            let missing = await lookUp("not-compiled", in: store)
            XCTAssertNil(missing)
        }
    }

    @MainActor
    func testBadRulesCompileToNil() async throws {
        try await withStore { store, raw in
            let (made, error) = await compile("blocking.bad", in: store, rules: "not JSON")
            XCTAssertNil(made)
            XCTAssertNotNil(error)
            let saved = await identifiers(in: raw)
            XCTAssertFalse(saved.contains("blocking.bad"))
        }
    }

    @MainActor
    func testRemoveOldKeepsOnlyTheKeptAndUnprefixedLists() async throws {
        try await withStore { store, raw in
            let ids = ["blocking.old-one", "blocking.kept", "blocking.old-two", "other.list"]
            for id in ids {
                let (made, error) = await compile(id, in: store)
                XCTAssertNotNil(made)
                XCTAssertNil(error)
            }
            let before = await identifiers(in: raw)
            XCTAssertEqual(before, Set(ids))
            store.removeOld(withPrefix: "blocking.", keeping: ["blocking.kept"])
            let expected: Set<String> = ["blocking.kept", "other.list"]
            // Removals start in WebKit's identifiers callback and are not awaited.
            let limit = ContinuousClock.now + .seconds(10)
            var after = await identifiers(in: raw)
            while after != expected, ContinuousClock.now < limit {
                try await Task.sleep(for: .milliseconds(20))
                after = await identifiers(in: raw)
            }
            XCTAssertEqual(after, expected)
        }
    }

    @MainActor
    private func load(_ view: WKWebView) async {
        let delegate = RuleListLoadDelegate()
        let loaded = expectation(description: "rule list fixture loaded")
        delegate.completed = { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString("<!doctype html><div id='ad'>Advertisement</div>", baseURL: URL(string: "https://fixture.invalid/"))
        await fulfillment(of: [loaded], timeout: 10)
        view.navigationDelegate = nil
    }

    @MainActor
    private func display(in view: WKWebView) async throws -> String? {
        try await view.evaluateJavaScript("getComputedStyle(document.getElementById('ad')).display") as? String
    }

    @MainActor
    func testReplacingListsHidesTheElementAndReplacingWithNoneShowsItAgain() async throws {
        try await withStore { store, _ in
            let (made, error) = await compile("blocking.display", in: store)
            XCTAssertNil(error)
            let list = try XCTUnwrap(made)
            let controller = WKUserContentController()
            let target = WebKitRuleListTarget(controller: controller)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController = controller
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
            defer { view.stopLoading() }
            await load(view)
            let before = try await display(in: view)
            XCTAssertEqual(before, "block")
            target.replaceAll(with: [list])
            await load(view)
            let hidden = try await display(in: view)
            XCTAssertEqual(hidden, "none")
            target.replaceAll(with: [])
            await load(view)
            let shown = try await display(in: view)
            XCTAssertEqual(shown, "block")
        }
    }
}
