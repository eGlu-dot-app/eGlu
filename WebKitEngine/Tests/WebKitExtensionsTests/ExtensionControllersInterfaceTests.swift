#if os(macOS)
import Foundation
import WebEngineAppKit
import XCTest

// Only contracts. A different engine owns its own registry and URL scheme.
@MainActor
private final class FakeControllers: WebExtensionControllers {
    var loaded: [UUID: Set<String>] = [:]
    var access: WebExtensionInstallation.SiteAccess?
    func isLoaded(_ id: String, in space: UUID) -> Bool { loaded[space]?.contains(id) == true }
    func extensionID(for url: URL?) -> String? { url?.scheme == "fixture" ? url?.host() : nil }
    func load(_ item: WebExtensionInstallation, in space: UUID) async -> Bool {
        loaded[space, default: []].insert(item.id)
        return true
    }
    func unload(_ id: String, in space: UUID) { loaded[space]?.remove(id) }
    func setSiteAccess(_ id: String, _ access: WebExtensionInstallation.SiteAccess) { self.access = access }
    func setReadsCookies(_ id: String, _ on: Bool, changed: (UUID) -> Void) {
        for space in loaded.keys where isLoaded(id, in: space) { changed(space) }
    }
}

final class ExtensionControllersInterfaceTests: XCTestCase {
    @MainActor func testCatalogCopyAndRuntimeOperationsNeedNoEngineObjects() async {
        let fake = FakeControllers(), runtime: any WebExtensionControllers = fake, space = UUID()
        let item = WebExtensionInstallation(id: "fixture", name: "Fixture", version: "1", source: .unpacked,
            siteAccess: .onClick, spaces: [space], granted: ["cookies"], folder: "/fixture",
            looksWrong: "1", readsCookies: false)
        let loaded = await runtime.load(item, in: space)
        XCTAssertTrue(loaded)
        XCTAssertTrue(runtime.isLoaded(item.id, in: space))
        XCTAssertFalse(runtime.isLoaded(item.id, in: UUID()))
        XCTAssertEqual(runtime.extensionID(for: URL(string: "fixture://fixture/page")), item.id)
        XCTAssertNil(runtime.extensionID(for: URL(string: "https://fixture/page")))
        runtime.setSiteAccess(item.id, .allSites)
        XCTAssertEqual(fake.access, .allSites)
        var callbacks: [UUID] = []
        runtime.setReadsCookies(item.id, true) { callbacks.append($0) }
        XCTAssertEqual(callbacks, [space])
        // The catalog value passed to load is unchanged by runtime choices.
        XCTAssertEqual(item.siteAccess, .onClick)
        XCTAssertEqual(item.readsCookies, false)
        XCTAssertEqual(item.granted, ["cookies"])
        XCTAssertEqual(item.folder, "/fixture")
        XCTAssertEqual(item.looksWrong, "1")
        runtime.unload(item.id, in: space)
        XCTAssertFalse(runtime.isLoaded(item.id, in: space))
    }
}
#endif
