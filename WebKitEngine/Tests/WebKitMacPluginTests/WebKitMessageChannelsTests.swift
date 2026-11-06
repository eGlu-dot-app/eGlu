import Foundation
import WebEngineCore
import WebKit
import WebKitMacPlugin
import WebKitSupport
import XCTest

@MainActor
private final class MessageLoadDelegate: NSObject, WKNavigationDelegate {
    var finished: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("Message fixture failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Message fixture failed before commit: \(error)")
    }
}

final class WebKitMessageChannelsTests: XCTestCase {
    @MainActor private static let world = WKContentWorld.world(name: "eGlu message tests")

    func testBridgeResourceIsPresent() {
        XCTAssertFalse(WebKitScriptBridge.source.isEmpty)
    }

    @MainActor
    private func fixture() -> (WKWebView, WebKitMessageChannels) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let channels = WebKitMessageChannels(controller: configuration.userContentController, appWorld: Self.world)
        return (WKWebView(frame: .zero, configuration: configuration), channels)
    }

    @MainActor
    private func load(_ view: WKWebView, html: String = "<!doctype html><title>messages</title>",
                      base: URL? = URL(string: "https://fixture.eglu.invalid:8443/")) async {
        let delegate = MessageLoadDelegate()
        let loaded = expectation(description: "message fixture loaded")
        delegate.finished = { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString(html, baseURL: base)
        await fulfillment(of: [loaded], timeout: 10)
        view.navigationDelegate = nil
    }

    @MainActor
    func testAppScriptPostsEngineMetadataAndJSON() async throws {
        let (view, channels) = fixture()
        defer { view.stopLoading() }
        let posted = expectation(description: "app world post")
        var received: WebMessage?
        channels.open("post", in: .app) { message in received = message; posted.fulfill() }
        let source = channels.bridgeScript + "\nglobalThis.egluBridge.post('post', { flag: true, count: 17, nested: [null, 'word'] });"
        view.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                                           forMainFrameOnly: true, in: Self.world))
        await load(view)
        await fulfillment(of: [posted], timeout: 10)
        let message = try XCTUnwrap(received)
        XCTAssertEqual(message.channel, "post")
        XCTAssertEqual(message.world, .app)
        XCTAssertTrue(message.isMainFrame)
        XCTAssertEqual(message.origin, .tuple(scheme: "https", host: "fixture.eglu.invalid", port: 8443))
        XCTAssertEqual(message.body, .object(["flag": .bool(true), "count": .number(17),
                                              "nested": .array([.null, .string("word")])]))
    }

    @MainActor
    func testSubframePostIsNotMainFrame() async {
        let (view, channels) = fixture()
        defer { view.stopLoading() }
        let posted = expectation(description: "main frame and srcdoc frame post")
        posted.expectedFulfillmentCount = 2
        var frames: [Bool] = []
        channels.open("frames", in: .app) { message in
            frames.append(message.isMainFrame)
            XCTAssertEqual(message.world, .app)
            posted.fulfill()
        }
        let source = channels.bridgeScript + "\nglobalThis.egluBridge.post('frames', {});"
        view.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                                           forMainFrameOnly: false, in: Self.world))
        await load(view, html: "<!doctype html><iframe srcdoc='<p>frame</p>'></iframe>")
        await fulfillment(of: [posted], timeout: 10)
        XCTAssertEqual(frames.sorted { !$0 && $1 }, [false, true])
    }

    @MainActor
    func testRequestsReturnObjectTrueUndefinedAndLaterReply() async throws {
        let (view, channels) = fixture()
        defer { view.stopLoading() }
        var laterHandlerReturned = false
        channels.open("ask", in: .app, replying: { message, reply in
            switch message.body {
            case .string("object"): reply(.object(["number": .number(17), "flag": .bool(true)]))
            case .string("true"):
                reply(.bool(true))
                reply(.bool(false)) // The second reply cannot reach WebKit.
            case .string("undefined"): reply(nil)
            case .string("later"):
                Task { @MainActor in
                    await Task.yield()
                    XCTAssertTrue(laterHandlerReturned)
                    reply(.string("later"))
                }
                laterHandlerReturned = true
            default: XCTFail("Unexpected request")
            }
        })
        await load(view)
        let source = channels.bridgeScript + """
        \nconst object = await globalThis.egluBridge.request('ask', 'object');
        const yes = await globalThis.egluBridge.request('ask', 'true');
        const empty = await globalThis.egluBridge.request('ask', 'undefined');
        const later = await globalThis.egluBridge.request('ask', 'later');
        return object.number === 17 && object.flag === true && yes === true && empty === undefined && later === 'later';
        """
        let answer = try await view.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: Self.world)
        XCTAssertEqual(answer as? Bool, true)
    }

    @MainActor
    func testPageWorldCannotSeeAppBridgeOrChannel() async throws {
        let (view, channels) = fixture()
        defer { view.stopLoading() }
        channels.open("privateChannel", in: .app) { _ in XCTFail("Page reached app channel") }
        await load(view)
        _ = try await view.evaluateJavaScript(channels.bridgeScript, in: nil, contentWorld: Self.world)
        let result = try await view.evaluateJavaScript("""
        typeof globalThis.egluBridge === 'undefined' &&
          typeof globalThis.webkit?.messageHandlers?.privateChannel === 'undefined'
        """, in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    @MainActor
    func testMissingChannelThrowsTypeErrorAndBridgeIsDefinedOnce() async throws {
        let (view, channels) = fixture()
        defer { view.stopLoading() }
        await load(view)
        let source = channels.bridgeScript + "\nconst first = globalThis.egluBridge;\n" + channels.bridgeScript + """
        \nlet postThrows = false, requestThrows = false;
        try { globalThis.egluBridge.post('missing', {}); } catch (error) { postThrows = error instanceof TypeError; }
        try { globalThis.egluBridge.request('missing', {}); } catch (error) { requestThrows = error instanceof TypeError; }
        return postThrows && requestThrows && first === globalThis.egluBridge && first.version === 1 && Object.isFrozen(first);
        """
        let result = try await view.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: Self.world)
        XCTAssertEqual(result as? Bool, true)
    }

    /// A page element with the id "egluBridge" is a named property of the
    /// window in the app's world too: the bridge is still defined, and the
    /// script's post still arrives.
    @MainActor
    func testElementNamedEgluBridgeDoesNotStopTheBridge() async throws {
        let (view, channels) = fixture()
        defer { view.stopLoading() }
        let posted = expectation(description: "post despite a named element")
        channels.open("named", in: .app) { message in
            XCTAssertEqual(message.body, .object(["ok": .bool(true)]))
            posted.fulfill()
        }
        let source = channels.bridgeScript + "\nglobalThis.egluBridge.post('named', { ok: true });"
        view.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                                           forMainFrameOnly: true, in: Self.world))
        await load(view, html: "<!doctype html><input id='egluBridge' type='password'>")
        await fulfillment(of: [posted], timeout: 10)
        let named = try await view.evaluateJavaScript(
            "globalThis.egluBridge instanceof Element === false && globalThis.egluBridge.version === 1",
            in: nil, contentWorld: Self.world)
        XCTAssertEqual(named as? Bool, true)
        let page = try await view.evaluateJavaScript("globalThis.egluBridge instanceof Element", in: nil, contentWorld: .page)
        XCTAssertEqual(page as? Bool, true, "the page's own world still sees its element")
    }

    @MainActor
    func testPageChannelUsesPageWorldAndOpaqueOrigin() async throws {
        let (view, channels) = fixture()
        defer { view.stopLoading() }
        let posted = expectation(description: "page world post")
        channels.open("publicChannel", in: .page) { message in
            XCTAssertEqual(message.world, .page)
            XCTAssertEqual(message.origin, .opaque)
            XCTAssertTrue(message.isMainFrame)
            posted.fulfill()
        }
        await load(view, base: nil)
        _ = try await view.evaluateJavaScript(channels.bridgeScript + "\nglobalThis.egluBridge.post('publicChannel', {});",
                                              in: nil, contentWorld: .page)
        await fulfillment(of: [posted], timeout: 10)
    }
}
