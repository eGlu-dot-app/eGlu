#if os(macOS)
import AppKit
import WebEngineAppKit
import XCTest

// This file imports only contracts and AppKit, with no plugin or WebKit.
@MainActor
private final class FakeMetadata: WebExtensionMetadata {
    let image = NSImage(size: NSSize(width: 32, height: 32))
    let options = URL(string: "fixture://extension/options.html")!
    let newTab = URL(string: "fixture://extension/newtab.html")!
    var forgotten: [String] = []

    func icon(of id: String) -> NSImage? { image }
    func icon(of id: String, in space: UUID) -> NSImage? { image }
    func forgetIcon(_ id: String) { forgotten.append(id) }
    func manifestFacts(permissions: [String], optionalPermissions: [String]) -> WebExtensionManifestFacts {
        .init(offersCookies: true, nativeRequired: false, nativeOptional: true)
    }
    func optionsPageURL(_ id: String, in space: UUID) -> URL? { options }
    func newTabPageURL(_ id: String, in space: UUID) -> URL? { newTab }
    func hasNewTabPage(_ id: String) -> Bool { true }
    func isNewTabPage(_ url: URL, in space: UUID) -> Bool { url == newTab }
    func sidePanelDefaultPath(_ id: String, in space: UUID) -> String? { "panel.html" }
    nonisolated func packageName(at file: URL, fallback: String) -> WebExtensionPackageName {
        .init(name: "Fixture", facts: .init(offersCookies: true, nativeRequired: false, nativeOptional: true))
    }
}

final class ExtensionMetadataInterfaceTests: XCTestCase {
    @MainActor
    func testInterfaceCanReadMetadataWithoutEngineObjects() async throws {
        let fake = FakeMetadata()
        let metadata: any WebExtensionMetadata = fake
        let space = UUID()
        XCTAssertTrue(metadata.icon(of: "fixture") === fake.image)
        XCTAssertTrue(metadata.icon(of: "fixture", in: space) === fake.image)
        let facts = metadata.manifestFacts(permissions: [], optionalPermissions: [])
        XCTAssertTrue(facts.offersCookies)
        XCTAssertFalse(facts.nativeRequired)
        XCTAssertTrue(facts.nativeOptional)
        XCTAssertEqual(metadata.optionsPageURL("fixture", in: space), fake.options)
        XCTAssertEqual(metadata.newTabPageURL("fixture", in: space), fake.newTab)
        XCTAssertTrue(metadata.hasNewTabPage("fixture"))
        XCTAssertTrue(metadata.isNewTabPage(fake.newTab, in: space))
        XCTAssertEqual(metadata.sidePanelDefaultPath("fixture", in: space), "panel.html")
        metadata.forgetIcon("fixture")
        XCTAssertEqual(fake.forgotten, ["fixture"])
        let result = await Task.detached {
            metadata.packageName(at: URL(fileURLWithPath: "/unused"), fallback: "saved")
        }.value
        XCTAssertEqual(result.name, "Fixture")
        XCTAssertEqual(result.facts, facts)
    }
}
#endif
