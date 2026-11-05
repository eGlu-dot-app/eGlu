#if os(macOS)
import AppKit
import WebEngineAppKit
import XCTest

@MainActor
private final class FakePermissions: WebExtensionPermissions {
    var permissionPresses: [String: Date] = [:]
}

@MainActor
private final class FakePermissionTarget: ExtensionPermissionTarget {}

@MainActor
private final class FakePermissionHost: ExtensionPermissionHost {
    let target = FakePermissionTarget()
    var request: ExtensionPermissionRequest?
    var cookies: [String] = []
    func extensionPermissionTarget(in space: UUID, tab: UUID?, kind: ExtensionPermissionPromptKind) -> (any ExtensionPermissionTarget)? { target }
    func extensionPermissionTitle(name: String?, kind: ExtensionPermissionPromptKind) -> String { "Fixture title" }
    func requestExtensionPermission(_ request: ExtensionPermissionRequest, target: any ExtensionPermissionTarget) async -> Bool {
        self.request = request
        return target === self.target
    }
    func allowExtensionPermissionCookies(_ id: String) { cookies.append(id) }
}

final class ExtensionPermissionsInterfaceTests: XCTestCase {
    @MainActor func testPromptAndPressValuesNeedNoWebKit() async throws {
        let runtime: any WebExtensionPermissions = FakePermissions()
        let fake = FakePermissionHost(), host: any ExtensionPermissionHost = fake
        let space = UUID(), tab = UUID(), date = Date(), image = NSImage(size: NSSize(width: 96, height: 96))
        runtime.permissionPresses["\(space)/fixture"] = date
        XCTAssertEqual(runtime.permissionPresses["\(space)/fixture"], date)
        let target = try XCTUnwrap(host.extensionPermissionTarget(in: space, tab: tab, kind: .permissions))
        let request = ExtensionPermissionRequest(extensionID: "fixture", space: space, tab: tab, name: "Fixture", image: image,
            permissions: ["cookies"], sites: ["https://example.invalid/*"], kind: .permissions)
        let yes = await host.requestExtensionPermission(request, target: target)
        XCTAssertTrue(yes)
        XCTAssertTrue(fake.request?.image === image)
        XCTAssertEqual(fake.request?.tab, tab)
        host.allowExtensionPermissionCookies("fixture")
        XCTAssertEqual(fake.cookies, ["fixture"])
    }
}
#endif
