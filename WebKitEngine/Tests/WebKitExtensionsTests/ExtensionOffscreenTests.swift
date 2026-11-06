#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

final class ExtensionOffscreenTests: XCTestCase {
    @MainActor private func context() async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offscreen-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Offscreen fixture","version":"1"}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        // Parse a fixture only; never load an installed extension or a controller.
        let package = try await WKWebExtension(resourceBaseURL: folder)
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "fixture"
        context.baseURL = URL(string: "chrome-extension://fixture/")!
        XCTAssertFalse(context.isLoaded)
        return context
    }

    @MainActor private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return configuration
    }

    @MainActor private func focusPreference(_ preferences: WKPreferences) -> Bool? {
        let selector = NSSelectorFromString("_getUserMediaRequiresFocus")
        guard preferences.responds(to: selector),
              let method = class_getMethodImplementation(type(of: preferences), selector) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Get.self)(preferences, selector)
    }

    @MainActor private func setFocusPreference(_ preferences: WKPreferences, _ value: Bool) {
        let selector = NSSelectorFromString("_setGetUserMediaRequiresFocus:")
        guard preferences.responds(to: selector),
              let method = class_getMethodImplementation(type(of: preferences), selector) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Set.self)(preferences, selector, value)
    }

    @MainActor
    func testConfigurationForEveryReasonAndTeardownOfEachDocument() async throws {
        let context = try await context()
        // Reasons are passed through as strings, including ones WebKit does not know.
        let reasons: [Set<String>] = [[], ["TESTING"], ["AUDIO_PLAYBACK"], ["IFRAME_SCRIPTING"], ["DOM_SCRAPING"],
            ["BLOBS"], ["DOM_PARSER"], ["USER_MEDIA"], ["DISPLAY_MEDIA"], ["WEB_RTC"], ["CLIPBOARD"],
            ["LOCAL_STORAGE"], ["WORKERS"], ["BATTERY_STATUS"], ["MATCH_MEDIA"], ["GEOLOCATION"],
            ["USER_MEDIA", "DISPLAY_MEDIA"], ["UNKNOWN"]]
        for reason in reasons {
            let space = UUID()
            let configuration = configuration()
            let original = configuration.preferences
            setFocusPreference(original, true)
            let host = AuxiliaryPageHost()
            let loaded = expectation(description: "Load intercepted for \(reason)")
            var web: AuxiliaryPageView?
            var creation: Task<Void, Error>? = Task { @MainActor in
                let document = try ExtensionOffscreen.make("offscreen.html", reasons: reason, for: context, in: space,
                                                    scheme: "chrome-extension", host: host,
                                                    configuration: { configuration }, makeView: { frame, configuration in
                    let made = AuxiliaryPageView(frame: frame, configuration: configuration)
                    made.onLoad = { loaded.fulfill() }
                    web = made
                    return made
                })
                try await document.load()
            }
            await fulfillment(of: [loaded], timeout: 5)
            let view = try XCTUnwrap(web)
            var document = try XCTUnwrap(view.navigationDelegate as? ExtensionOffscreen) as ExtensionOffscreen?
            weak let lifetime = document
            XCTAssertNil(view.window)
            XCTAssertEqual(view.frame, NSRect(x: 0, y: 0, width: 800, height: 600))
            XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
            XCTAssertTrue(view.configuration.websiteDataStore === configuration.websiteDataStore)
            XCTAssertTrue(view.configuration.userContentController === configuration.userContentController)
            XCTAssertEqual(view.configuration.userContentController.userScripts.count, 0)
            XCTAssertTrue(view.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            XCTAssertEqual(original.inactiveSchedulingPolicy, .none)
            XCTAssertFalse(configuration.preferences === original)
            XCTAssertEqual(configuration.preferences.inactiveSchedulingPolicy, .throttle)
            XCTAssertEqual(view.configuration.preferences.inactiveSchedulingPolicy, .throttle)
            if let originalFocus = focusPreference(original) {
                XCTAssertTrue(originalFocus)
                XCTAssertEqual(focusPreference(view.configuration.preferences), !reason.contains("USER_MEDIA"))
            } else if reason.contains("USER_MEDIA") {
                XCTFail("This WebKit cannot verify the private focus preference getter")
            }
            XCTAssertEqual(view.loads.map(\.url), [URL(string: "chrome-extension://fixture/offscreen.html")!])
            XCTAssertTrue(ExtensionOffscreen.hasDocument("fixture", in: space))
            XCTAssertEqual(ExtensionOffscreen.reasons(of: view), reason)
            XCTAssertTrue(ExtensionOffscreen.contexts("fixture", in: space, matching: [:]).isEmpty)
            XCTAssertNil(document?.window(for: context))
            XCTAssertEqual(document?.indexInWindow(for: context), NSNotFound)
            XCTAssertEqual(document?.isSelected(for: context), false)
            // A duplicate is refused before looking for another configuration.
            do {
                _ = try ExtensionOffscreen.make("second.html", reasons: [], for: context, in: space,
                                                    scheme: "chrome-extension", host: host, configuration: {
                    XCTFail("A duplicate must not ask for a configuration")
                    return nil
                })
                XCTFail("A duplicate was accepted")
            } catch { XCTAssertEqual(error.localizedDescription, "Only a single offscreen document may be created.") }
            document?.webView(view, didFinish: nil)
            try await creation?.value
            creation = nil
            let records = ExtensionOffscreen.contexts("fixture", in: space, matching: [:])
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?["documentUrl"] as? String, "chrome-extension://fixture/offscreen.html")
            XCTAssertEqual(records.first?["contextType"] as? String, "OFFSCREEN_DOCUMENT")
            XCTAssertEqual(records.first?["windowId"] as? Int, -1)
            XCTAssertTrue(ExtensionOffscreen.contexts("fixture", in: space, matching: ["incognito": true]).isEmpty)
            host.onRelease = { released in
                XCTAssertTrue(released === view)
                XCTAssertTrue(view.navigationDelegate === document)
                XCTAssertTrue(view.uiDelegate === document)
                XCTAssertFalse(ExtensionOffscreen.hasDocument("fixture", in: space))
                XCTAssertEqual(view.stops, 0)
            }
            ExtensionOffscreen.close("fixture", in: space)
            document?.webViewWebContentProcessDidTerminate(view)
            ExtensionOffscreen.closeAll(in: space)
            XCTAssertEqual(host.released.count, 1)
            XCTAssertTrue(host.released.first === view)
            XCTAssertNil(view.navigationDelegate)
            XCTAssertNil(view.uiDelegate)
            XCTAssertEqual(view.stops, 1)
            XCTAssertNil(ExtensionOffscreen.reasons(of: view))
            XCTAssertTrue(ExtensionOffscreen.contexts("fixture", in: space, matching: [:]).isEmpty)
            host.onRelease = nil
            document = nil
            let drained = expectation(description: "Released task and tab notification")
            DispatchQueue.main.async { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 5)
            XCTAssertNil(lifetime)
        }
    }

    @MainActor
    func testForeignPathIsRefusedBeforeConfigurationAndViewCreation() async throws {
        let context = try await context()
        for path in ["https://fixture/offscreen", "chrome-extension://other/page", "chrome-extension://user@fixture/page",
                     "chrome-extension://user:password@fixture/page", "file:///tmp/page", "about:blank"] {
            do {
                _ = try ExtensionOffscreen.make(path, reasons: [], for: context, in: UUID(),
                                                    scheme: "chrome-extension", host: AuxiliaryPageHost(), configuration: {
                    XCTFail("An invalid address must not ask for a configuration")
                    return nil
                }, makeView: { frame, configuration in
                    XCTFail("An invalid address must not make a view")
                    return AuxiliaryPageView(frame: frame, configuration: configuration)
                })
                XCTFail("An invalid address was accepted: \(path)")
            } catch { XCTAssertEqual(error.localizedDescription, "The offscreen document must belong to this extension.") }
        }
    }

    @MainActor
    func testClosingWhileLoadingResumesTheWaitAndReleasesOnlyOnce() async throws {
        let context = try await context()
        let space = UUID()
        let host = AuxiliaryPageHost()
        let configuration = configuration()
        let loaded = expectation(description: "Load intercepted")
        var web: AuxiliaryPageView?
        let creation = Task { @MainActor in
            let document = try ExtensionOffscreen.make("pending.html", reasons: ["USER_MEDIA"], for: context, in: space,
                                                scheme: "chrome-extension", host: host, configuration: { configuration },
                                                makeView: { frame, configuration in
                let view = AuxiliaryPageView(frame: frame, configuration: configuration)
                view.onLoad = { loaded.fulfill() }
                web = view
                return view
            })
            try await document.load()
        }
        await fulfillment(of: [loaded], timeout: 5)
        let view = try XCTUnwrap(web)
        let document = try XCTUnwrap(view.navigationDelegate as? ExtensionOffscreen)
        ExtensionOffscreen.closeAll(of: "fixture")
        do { try await creation.value; XCTFail("Closing must fail the pending load") }
        catch { XCTAssertEqual(error.localizedDescription, "The offscreen document was closed.") }
        document.webView(view, didFinish: nil)
        document.webViewWebContentProcessDidTerminate(view)
        XCTAssertFalse(ExtensionOffscreen.hasDocument("fixture", in: space))
        XCTAssertNil(view.navigationDelegate)
        XCTAssertNil(view.uiDelegate)
        XCTAssertEqual(host.released.count, 1)
        XCTAssertEqual(view.stops, 1)
        XCTAssertTrue(ExtensionOffscreen.contexts("fixture", in: space, matching: [:]).isEmpty)
    }
}
#endif
