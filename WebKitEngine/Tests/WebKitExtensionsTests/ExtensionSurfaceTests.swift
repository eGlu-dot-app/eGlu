#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

@MainActor
final class AuxiliaryPageHost: ExtensionAuxiliaryPageHost {
    var released: [NSView] = []
    var watched: [(NSView, String)] = []
    var displayDecision = 0
    var media: [ExtensionPageMedia] = []
    var allowMedia = false
    var onRelease: ((NSView) -> Void)?

    func releaseExtensionPage(_ view: NSView) { onRelease?(view); released.append(view) }
    func extensionDisplayDecision(for view: NSView) -> Int { displayDecision }
    func watchExtensionPage(_ view: NSView, id: String) { watched.append((view, id)) }
    func requestExtensionMedia(_ media: ExtensionPageMedia, name: String,
                               reply: @escaping @MainActor (Bool) -> Void) {
        self.media.append(media)
        reply(allowMedia)
    }
}

/// Records the extension address without loading it or opening a connection.
@MainActor
class AuxiliaryPageView: WKWebView {
    var loads: [URLRequest] = []
    var stops = 0
    var onLoad: (() -> Void)?

    override func load(_ request: URLRequest) -> WKNavigation? {
        loads.append(request)
        onLoad?()
        return nil
    }

    override func stopLoading() { stops += 1; super.stopLoading() }
}

@MainActor
private final class MeasuredPageView: AuxiliaryPageView {
    var result: Any? = [312.0, 173.0, 1.0]
    var failure: Error?
    var scripts: [String] = []

    override func evaluateJavaScript(_ javaScriptString: String,
                                     completionHandler: (@MainActor (Any?, (any Error)?) -> Void)? = nil) {
        scripts.append(javaScriptString)
        completionHandler?(result, failure)
    }
}

@MainActor
private final class SurfaceLoad: NSObject, WKNavigationDelegate {
    var finished: (() -> Void)?
    var error: Error?
    var didFinish = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { didFinish = true; finished?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished?()
    }
}

final class ExtensionSurfaceTests: XCTestCase {
    @MainActor
    private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Surface fixture"
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    @MainActor
    func testForeignInitialAddressesAreRefusedBeforeConfigurationOrViewCreation() {
        let host = AuxiliaryPageHost()
        for address in ["https://fixture.invalid/", "http://fixture/page", "file:///tmp/page", "about:blank",
                        "javascript:void(0)", "chrome-extension://other/page", "webkit-extension://fixture/page"] {
            var configurationReads = 0
            var viewCreations = 0
            let surface = ExtensionSurface(URL(string: address)!, extensionID: "fixture", in: UUID(),
                                           scheme: "chrome-extension", host: host, configuration: {
                configurationReads += 1
                return self.configuration()
            }, makeView: { frame, configuration in
                viewCreations += 1
                return AuxiliaryPageView(frame: frame, configuration: configuration)
            })
            XCTAssertNil(surface, address)
            XCTAssertEqual(configurationReads, 0, address)
            XCTAssertEqual(viewCreations, 0, address)
        }
    }

    @MainActor
    func testConfigurationNavigationAndCloseOnceOnTheSameUnhostedView() throws {
        let host = AuxiliaryPageHost()
        let configuration = configuration()
        let space = UUID()
        let address = URL(string: "chrome-extension://fixture/popup.html")!
        var view: AuxiliaryPageView?
        let surface = try XCTUnwrap(ExtensionSurface(address, extensionID: "fixture", in: space,
                                                     scheme: "chrome-extension", host: host,
                                                     configuration: { configuration }, makeView: { frame, configuration in
            let made = AuxiliaryPageView(frame: frame, configuration: configuration)
            view = made
            return made
        }))
        let web = try XCTUnwrap(view)
        XCTAssertTrue(surface.view === web)
        XCTAssertNil(web.window)
        XCTAssertEqual(web.frame, NSRect(x: 0, y: 0, width: 25, height: 25))
        XCTAssertTrue(web.configuration.websiteDataStore === configuration.websiteDataStore)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(web.configuration.userContentController === configuration.userContentController)
        XCTAssertEqual(web.configuration.userContentController.userScripts.count, 0)
        XCTAssertEqual(web.configuration.applicationNameForUserAgent, "Surface fixture")
        XCTAssertEqual(web.configuration.mediaTypesRequiringUserActionForPlayback, .audio)
        XCTAssertFalse(web.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(web.isInspectable)
        let background = try XCTUnwrap(web.underPageBackgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(background.redComponent, 1)
        XCTAssertEqual(background.greenComponent, 1)
        XCTAssertEqual(background.blueComponent, 1)
        XCTAssertEqual(background.alphaComponent, 1)
        XCTAssertTrue(web.uiDelegate === surface)
        XCTAssertTrue(web.navigationDelegate === surface)
        XCTAssertEqual(web.loads.map(\.url), [address])
        XCTAssertEqual(surface.extensionID, "fixture")
        XCTAssertEqual(surface.space, space)
        XCTAssertFalse(surface.hasFocus)
        surface.focus()
        XCTAssertNil(web.window)
        for frame in [true, nil] as [Bool?] {
            XCTAssertEqual(surface.navigationPolicy(to: address, targetIsMainFrame: frame), .allow)
            XCTAssertEqual(surface.navigationPolicy(to: URL(string: "chrome-extension://fixture/elsewhere?q=1#x"), targetIsMainFrame: frame), .allow)
            for address in ["https://fixture/", "http://fixture/", "chrome-extension://other/", "webkit-extension://fixture/",
                            "about:blank", "file:///tmp/page", "data:text/html,hi", "javascript:void(0)"] {
                XCTAssertEqual(surface.navigationPolicy(to: URL(string: address), targetIsMainFrame: frame), .cancel, address)
            }
            XCTAssertEqual(surface.navigationPolicy(to: nil, targetIsMainFrame: frame), .cancel)
        }
        // Subframes retain the original exception to the main-frame refusal.
        XCTAssertEqual(surface.navigationPolicy(to: URL(string: "https://frame.invalid/"), targetIsMainFrame: false), .allow)
        XCTAssertEqual(web.loads.count, 1)
        var closeRequests = 0
        surface.onClose = { closeRequests += 1 }
        surface.webViewDidClose(web)
        XCTAssertEqual(closeRequests, 1)
        host.onRelease = { view in
            XCTAssertTrue(view === web)
            XCTAssertTrue(web.navigationDelegate === surface)
            XCTAssertTrue(web.uiDelegate === surface)
            XCTAssertEqual(web.stops, 0)
        }
        surface.close()
        surface.close()
        surface.webViewDidClose(web)
        XCTAssertEqual(closeRequests, 1)
        XCTAssertNil(surface.onClose)
        XCTAssertEqual(host.released.count, 1)
        XCTAssertTrue(host.released.first === web)
        XCTAssertNil(web.navigationDelegate)
        XCTAssertNil(web.uiDelegate)
        XCTAssertEqual(web.stops, 1)
    }

    @MainActor
    func testSitesInTheMainFrameOpenAnActiveTabInTheSurfacesSpace() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("surface-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Surface fixture","version":"1"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        // Parse a fixture only. No controller loads this context or an installed extension.
        let package = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "fixture"
        XCTAssertFalse(context.isLoaded)
        let browser = BrowserHost()
        let tabs = ExtensionTabs(host: browser, enabled: { _ in true },
                                 controller: { _ in WKWebExtensionController(configuration: ExtensionTrial.throwaway()) },
                                 othersPage: { _, _ in false }, refusal: { _, _ in nil }, heldOwner: { _ in nil })
        let space = UUID()
        let configuration = configuration()
        let surface = try XCTUnwrap(ExtensionSurface(URL(string: "chrome-extension://fixture/popup.html")!, extensionID: "fixture",
                                                     context: context, in: space, scheme: "chrome-extension", tabs: tabs,
                                                     host: AuxiliaryPageHost(), configuration: { configuration },
                                                     makeView: { AuxiliaryPageView(frame: $0, configuration: $1) }))
        // Its own pages, a subframe's site and any other address open nothing.
        XCTAssertEqual(surface.navigationPolicy(to: URL(string: "chrome-extension://fixture/other.html"), targetIsMainFrame: true), .allow)
        XCTAssertEqual(surface.navigationPolicy(to: URL(string: "https://frame.invalid/"), targetIsMainFrame: false), .allow)
        for address in ["file:///tmp/page", "chrome-extension://other/", "about:blank", "data:text/html,hi"] {
            XCTAssertEqual(surface.navigationPolicy(to: URL(string: address), targetIsMainFrame: true), .cancel, address)
        }
        XCTAssertEqual(surface.navigationPolicy(to: nil, targetIsMainFrame: true), .cancel)
        XCTAssertTrue(browser.calls.isEmpty)
        // A site in the main frame, or with no frame named, stays out of the
        // surface and opens as an active, unpinned tab in its space.
        XCTAssertEqual(surface.navigationPolicy(to: URL(string: "https://site.invalid/a?b=1"), targetIsMainFrame: true), .cancel)
        XCTAssertEqual(surface.navigationPolicy(to: URL(string: "http://site.invalid/"), targetIsMainFrame: nil), .cancel)
        XCTAssertEqual(browser.calls, ["open:\(space):https://site.invalid/a?b=1:true:false:fixture",
                                       "open:\(space):http://site.invalid/:true:false:fixture"])
        surface.close()
    }

    @MainActor
    func testMeasurePassesTheOriginalScriptAndDecodesAllThreeValues() async throws {
        let host = AuxiliaryPageHost()
        let configuration = configuration()
        let web = MeasuredPageView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        let surface = try XCTUnwrap(ExtensionSurface(URL(string: "chrome-extension://fixture/popup")!,
                                                     extensionID: "fixture", in: UUID(), scheme: "chrome-extension",
                                                     host: host, configuration: { configuration }, makeView: { _, _ in web }))
        defer { surface.close() }
        let named = await surface.measure()
        XCTAssertEqual(named?.size, NSSize(width: 312, height: 173))
        XCTAssertEqual(named?.named, true)
        web.result = [417.0, 229.0, 0.0]
        let unnamed = await surface.measure()
        XCTAssertEqual(unnamed?.size, NSSize(width: 417, height: 229))
        XCTAssertEqual(unnamed?.named, false)
        for invalid in [nil, "wrong", [1.0, 2.0], [1.0, 2.0, 3.0, 4.0]] as [Any?] {
            web.result = invalid
            let measured = await surface.measure()
            XCTAssertNil(measured)
        }
        web.failure = NSError(domain: "fixture", code: 1)
        let failed = await surface.measure()
        XCTAssertNil(failed)
        XCTAssertEqual(web.scripts, Array(repeating: ExtensionSurface.preferred, count: 7))
        XCTAssertEqual(web.loads.count, 1)
    }

    @MainActor
    func testActualMeasureClampsSizeAndRestoresInlineStyle() async throws {
        let configuration = configuration()
        let web = AuxiliaryPageView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        let load = SurfaceLoad()
        let loaded = expectation(description: "Local HTML only")
        load.finished = { loaded.fulfill() }
        web.navigationDelegate = load
        web.loadHTMLString("<!doctype html><html style='width:312px;height:173px'><body style='margin:0'></body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        if let error = load.error { throw error }
        guard load.didFinish else { return XCTFail("The local HTML did not load") }
        let surface = try XCTUnwrap(ExtensionSurface(URL(string: "chrome-extension://fixture/popup")!, extensionID: "fixture",
                                                     in: UUID(), scheme: "chrome-extension", host: AuxiliaryPageHost(),
                                                     configuration: { configuration }, makeView: { _, _ in web }))
        defer { surface.close() }
        XCTAssertNil(web.window)
        for (style, size) in [("width:312px;height:173px", NSSize(width: 312, height: 173)),
                              ("width:2000px;height:1000px", NSSize(width: 800, height: 600)),
                              ("width:1px;height:1px", NSSize(width: 25, height: 25))] {
            _ = try await web.evaluateJavaScript("document.documentElement.setAttribute('style', '\(style)'); delete window.__egluSizing")
            let found = await surface.measure()
            XCTAssertEqual(found?.size, size)
            XCTAssertEqual(found?.named, true)
            let restored = try await web.evaluateJavaScript("document.documentElement.getAttribute('style')")
            XCTAssertEqual(restored as? String, style)
        }
        XCTAssertEqual(web.loads.map(\.url), [URL(string: "chrome-extension://fixture/popup")!])
        XCTAssertEqual(web.configuration.userContentController.userScripts.count, 0)
    }
}
#endif
