import WebKit
import WebKitMacPlugin
import XCTest

final class WebKitConfigurationTests: XCTestCase {
    @MainActor
    func testUsesTheGivenStoreControllerAndSettings() {
        let store = WKWebsiteDataStore.nonPersistent()
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let configuration = WebKitConfiguration.make(store: store, extensionController: controller,
                                                    applicationNameForUserAgent: "eGlu Test")

        XCTAssertTrue(configuration.websiteDataStore === store)
        XCTAssertTrue(configuration.webExtensionController === controller)
        XCTAssertEqual(configuration.applicationNameForUserAgent, "eGlu Test")
        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .audio)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(configuration.preferences.isElementFullscreenEnabled)
    }

    @MainActor
    func testEachCallReturnsANewConfiguration() {
        let store = WKWebsiteDataStore.nonPersistent()
        let first = WebKitConfiguration.make(store: store, extensionController: nil,
                                            applicationNameForUserAgent: "eGlu Test")
        let second = WebKitConfiguration.make(store: store, extensionController: nil,
                                             applicationNameForUserAgent: "eGlu Test")

        XCTAssertFalse(first === second)
        XCTAssertNil(first.webExtensionController)
        XCTAssertNil(second.webExtensionController)
    }
}
