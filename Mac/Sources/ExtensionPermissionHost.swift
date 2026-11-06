import AppKit
import PadCore
import SwiftUI
import WebEngineAppKit

@MainActor
private final class PermissionTarget: ExtensionPermissionTarget {
    let window: WindowModel
    init(_ window: WindowModel) { self.window = window }
}

extension ExtensionHost: ExtensionPermissionHost {
    func extensionPermissionTarget(in space: UUID, tab id: UUID?, kind: ExtensionPermissionPromptKind) -> (any ExtensionPermissionTarget)? {
        let owner: WindowModel?
        if kind == .afterClick {
            owner = Session.shared.allWindows.first(where: { $0.spaceID == space && $0.window?.isKeyWindow == true })
                ?? Session.shared.allWindows.first(where: { $0.spaceID == space && $0.window?.isVisible == true })
        } else {
            owner = permissionWindow(in: space, tab: id)
        }
        return owner.map(PermissionTarget.init)
    }

    private func permissionWindow(in space: UUID, tab id: UUID?) -> WindowModel? {
        let candidates = Session.shared.allWindows.filter { $0.spaceID == space && $0.window?.isVisible == true }
        return candidates.first { id != nil && $0.tabID == id } ?? candidates.first { $0.window?.isKeyWindow == true } ?? candidates.first
    }

    func extensionPermissionTitle(name: String?, kind: ExtensionPermissionPromptKind) -> String {
        let name = name ?? String(localized: "An extension")
        switch kind {
        case .permissions: return String(localized: "\u{201C}\(name)\u{201D} wants more access")
        case .matchPatterns: return String(localized: "\u{201C}\(name)\u{201D} wants to read and change more sites")
        case .afterClick: return String(localized: "\u{201C}\(name)\u{201D} asks for more.")
        }
    }

    func requestExtensionPermission(_ request: ExtensionPermissionRequest, target: any ExtensionPermissionTarget) async -> Bool {
        guard let owner = (target as? PermissionTarget)?.window else { return false }
        if request.kind == .afterClick {
            let spaceName = Session.shared.workspace.space(request.space)?.name ?? String(localized: "this space")
            let alert = NSAlert()
            alert.messageText = extensionPermissionTitle(name: request.name, kind: .afterClick)
            let lines = request.permissions.map { ExtensionAccessDescription.capability($0) } + request.sites.map { ExtensionAccessDescription.site($0) }
            let cookies = request.permissions.contains("cookies")
            alert.informativeText = lines.sorted().joined(separator: "\n") + "\n\n" + String(localized: "Applies in \(spaceName). Google's sign-in pages remain blocked.")
                + (cookies ? " " + ExtensionAccessGroups.cookiesNote : "")
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Don't Allow"))
            return await Extensions.shared.present(alert, in: owner) == .alertFirstButtonReturn
        }
        let summary = ExtensionAccessSummary(permissions: request.permissions, sites: request.sites)
        if request.kind == .permissions {
            let title = request.title ?? extensionPermissionTitle(name: request.name, kind: .permissions)
            return await Extensions.shared.askForMore(title: title, image: request.image, in: request.space, window: owner,
                                                      note: summary.cookies ? ExtensionAccessGroups.cookiesNote : nil) {
                ExtensionAccessGroups(summary: summary, everything: true, grantsCookies: true)
            }
        }
        let title = request.title ?? extensionPermissionTitle(name: request.name, kind: .matchPatterns)
        return await Extensions.shared.askForMore(title: title, image: request.image, in: request.space, window: owner) {
            ExtensionAccessGroups(summary: summary, everything: true)
        }
    }

    func allowExtensionPermissionCookies(_ id: String) { Extensions.shared.setReadsCookies(id, true, restarting: false) }
}
