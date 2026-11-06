#if os(macOS)
import PadCore
import WebKit
import XCTest
@testable import WebKitExtensions

final class ExtensionPageTests: XCTestCase {
    @MainActor
    func testThrowawayUsesOneNonpersistentWebsiteStoreForControllerAndPages() throws {
        let configuration = ExtensionTrial.throwaway()
        let store = try XCTUnwrap(configuration.defaultWebsiteDataStore)
        XCTAssertFalse(store.isPersistent)
        XCTAssertTrue(configuration.webViewConfiguration?.websiteDataStore === store)
        XCTAssertFalse(ExtensionTrial.throwaway().defaultWebsiteDataStore === store)
        XCTAssertEqual(ExtensionTrial.testPage.absoluteString, "https://test.eglu.invalid/")
        XCTAssertEqual(ExtensionTrial.everywhere, ["<all_urls>", "*://*/*", "https://*/*", "http://*/*"])
        XCTAssertTrue(ExtensionTrial.copysOwn("TAB NOT FOUND"))
        XCTAssertTrue(ExtensionTrial.copysOwn("Window not found"))
        XCTAssertFalse(ExtensionTrial.copysOwn("API not found"))
    }

    @MainActor
    func testBlankPageKeepsGivenConfigurationAndRefusesASiteWithoutLoading() async throws {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.websiteDataStore = store
        let controller = WKUserContentController()
        configuration.userContentController = controller
        let page = ExtensionBlankPage(configuration, scheme: "chrome-extension")
        XCTAssertTrue(page.view.configuration.websiteDataStore === store)
        XCTAssertTrue(page.view.configuration.userContentController === controller)
        XCTAssertNil(page.view.window)
        let cleared = try await page.clear(at: URL(string: "https://example.invalid/")!)
        XCTAssertFalse(cleared)
        XCTAssertNil(page.view.url)
        XCTAssertTrue(ExtensionBlankPage.clearing.contains("if (location.origin !== origin) throw"))
        XCTAssertTrue(ExtensionBlankPage.clearing.contains("localStorage.clear()"))
        XCTAssertTrue(ExtensionBlankPage.clearing.contains("indexedDB.deleteDatabase(db.name)"))
        XCTAssertTrue(ExtensionBlankPage.clearing.contains("await caches.delete(key)"))
    }

    @MainActor
    func testTrialHandsTheSameContextToPolicyCallbacksBeforeLoading() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = Data(#"{"manifest_version":3,"name":"Fixture","version":"1","permissions":["storage","cookies"]}"#.utf8)
        try json.write(to: folder.appendingPathComponent("manifest.json"))
        let manifest = try ExtensionManifest(json: json)
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        var events: [String] = []
        var seen: WKWebExtensionContext?
        let result = await ExtensionTrial.check(folder, id: "fixture", manifest: manifest, missing: [],
                                               scheme: "chrome-extension", shimApplication: "eglu", letRulesRedirect: { context, package in
            events.append("redirect")
            seen = context
            XCTAssertTrue(context.webExtension === package)
            XCTAssertEqual(context.uniqueIdentifier, "fixture")
            XCTAssertEqual(context.baseURL.absoluteString, "chrome-extension://fixture/")
            XCTAssertFalse(context.isLoaded)
            XCTAssertEqual(context.permissionStatus(for: .storage), .grantedExplicitly)
        }, sites: { package in
            events.append("sites")
            XCTAssertTrue(package === seen?.webExtension)
            return []
        }, fence: { context in
            events.append("fence")
            XCTAssertTrue(context === seen)
            XCTAssertFalse(context.isLoaded)
        })
        XCTAssertEqual(events, ["redirect", "sites", "fence"])
        XCTAssertEqual(result, ExtensionTrial.Checked())
        XCTAssertEqual(seen?.permissionStatus(for: .cookies), .deniedExplicitly)
        XCTAssertEqual(seen?.isLoaded, false)
    }

    @MainActor
    func testTableFixtureManifestAndWorker() throws {
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ExtensionTable.manifest.utf8)) as? [String: Any])
        XCTAssertEqual(manifest["manifest_version"] as? Int, 3)
        XCTAssertEqual(manifest["permissions"] as? [String], ExtensionTable.permissions)
        XCTAssertEqual(manifest["host_permissions"] as? [String], ["<all_urls>"])
        XCTAssertEqual((manifest["background"] as? [String: String])?["service_worker"], "worker.js")
        XCTAssertNotNil(manifest["action"])
        XCTAssertNotNil((manifest["commands"] as? [String: Any])?["one"])
        XCTAssertTrue(ExtensionTable.worker.contains("chrome.runtime.sendNativeMessage(\"eglu.table\", table)"))
        XCTAssertEqual(ExtensionTable.build, ProcessInfo.processInfo.operatingSystemVersionString)
    }
}
#endif
