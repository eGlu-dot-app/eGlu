import WebKit
import WebKitSupport
import XCTest

@MainActor
private final class FilterScriptObserver: NSObject, WKScriptMessageHandler {
    struct Seen {
        let world: String
        let mainFrame: Bool
        let blocker: String
        let scriptlet: String
    }

    var seen: [Seen] = []
    var completed: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String], let world = body["world"],
              let blocker = body["blocker"], let scriptlet = body["scriptlet"] else {
            XCTFail("The filter fixture must report both globals and its world.")
            return
        }
        seen.append(Seen(world: world, mainFrame: message.frameInfo.isMainFrame, blocker: blocker, scriptlet: scriptlet))
        completed?()
    }
}

final class WebKitFilterScriptsTests: XCTestCase {
    private static let blocker = "globalThis.filterBlocker = 'blocker';"
    private static let scriptlets = "globalThis.filterScriptlet = 'scriptlet';"

    @MainActor
    func testScriptsRunOnlyInTheirGivenWorldsAndOnlyInTheMainFrame() async throws {
        let appWorld = WKContentWorld.world(name: "filter-tests-\(UUID().uuidString)")
        let controller = WKUserContentController()
        controller.addFilterScripts(blocker: Self.blocker, scriptlets: Self.scriptlets, appWorld: appWorld)
        XCTAssertEqual(controller.userScripts.map(\.source), [Self.blocker, Self.scriptlets])
        XCTAssertTrue(controller.userScripts.allSatisfy { $0.injectionTime == .atDocumentStart && $0.isForMainFrameOnly })

        let observer = FilterScriptObserver()
        let observed = expectation(description: "both worlds in the main frame and srcdoc frame reported")
        observed.expectedFulfillmentCount = 4
        observer.completed = { observed.fulfill() }
        for (name, world) in [("app", appWorld), ("page", WKContentWorld.page)] {
            controller.add(observer, contentWorld: world, name: "filterFixture")
            let source = """
                window.webkit.messageHandlers.filterFixture.postMessage({
                  world: '\(name)',
                  blocker: typeof globalThis.filterBlocker === 'undefined' ? 'absent' : globalThis.filterBlocker,
                  scriptlet: typeof globalThis.filterScriptlet === 'undefined' ? 'absent' : globalThis.filterScriptlet
                });
                """
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                forMainFrameOnly: false, in: world))
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        defer {
            view.stopLoading()
            controller.removeScriptMessageHandler(forName: "filterFixture", contentWorld: appWorld)
            controller.removeScriptMessageHandler(forName: "filterFixture", contentWorld: .page)
        }
        view.loadHTMLString("<!doctype html><title>Filters</title><iframe srcdoc='<!doctype html><p>Frame</p>'></iframe>",
                            baseURL: URL(string: "https://fixture.invalid/"))
        await fulfillment(of: [observed], timeout: 10)
        XCTAssertEqual(observer.seen.count, 4)
        for world in ["app", "page"] {
            let main = try XCTUnwrap(observer.seen.first { $0.world == world && $0.mainFrame })
            XCTAssertEqual(main.blocker, world == "app" ? "blocker" : "absent")
            XCTAssertEqual(main.scriptlet, world == "page" ? "scriptlet" : "absent")
            let child = try XCTUnwrap(observer.seen.first { $0.world == world && !$0.mainFrame })
            XCTAssertEqual(child.blocker, "absent")
            XCTAssertEqual(child.scriptlet, "absent")
        }
    }

    @MainActor
    func testNilScriptsAreNotAdded() {
        let appWorld = WKContentWorld.world(name: "filter-nil-tests")
        for (blocker, scriptlets, expected) in [
            (Self.blocker, nil, [Self.blocker]),
            (nil, Self.scriptlets, [Self.scriptlets]),
            (nil, nil, [])
        ] as [(String?, String?, [String])] {
            let controller = WKUserContentController()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController = controller
            let view = WKWebView(frame: .zero, configuration: configuration)
            controller.addFilterScripts(blocker: blocker, scriptlets: scriptlets, appWorld: appWorld)
            XCTAssertEqual(view.configuration.userContentController.userScripts.count, expected.count)
            XCTAssertEqual(controller.userScripts.map(\.source), expected)
            XCTAssertTrue(controller.userScripts.allSatisfy { $0.injectionTime == .atDocumentStart && $0.isForMainFrameOnly })
        }
    }
}
