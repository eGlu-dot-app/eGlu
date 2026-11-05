import Foundation
import WebEngineAppKit
import WebKitSupport

extension ExtensionHost: ExtensionCleanupHost {
    func extensionCleanupIsInstalled(_ id: String) -> Bool {
        Extensions.shared.installed.contains { $0.id == id }
    }

    func extensionCleanupIDs(in space: UUID) -> [String] {
        Extensions.shared.installed.filter { $0.spaces.contains(space) }.map(\.id)
    }

    func removeExtensionCleanupMembership(in space: UUID) { Extensions.shared.removeCleanupMembership(in: space) }
    func clearExtensionCleanupVerdicts(in space: UUID) { Extensions.shared.clearCleanupVerdicts(in: space) }

    /// An extension's own tabs and popup, before its offscreen page closes.
    func closeExtensionCleanupPages(of id: String, in space: UUID) {
        let session = Session.shared
        for tab in session.workspace.space(space)?.tabs ?? [] {
            guard let url = session.pages.live[tab.id]?.view.url ?? tab.url, url.scheme == Extensions.scheme, url.host() == id else { continue }
            session.change { _ = $0.closeTab(tab.id) }
            session.pages.close(tab.id)
        }
        ExtensionPopups.shared.closeAll(of: id, in: space)
    }

    func closeExtensionCleanupPopups(in space: UUID) { ExtensionPopups.shared.closeAll(in: space) }
    func closeExtensionCleanupSidePanels(in space: UUID) { ExtensionSidePanels.shared.closeAll(in: space) }

    func scheduleExtensionCleanupStoreSweep() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Stores.sweep(in: WebKitSpaceStores.shared) }
    }

    func noteExtensionCleanup(_ message: () -> String) {
        #if DEBUG
        Extensions.note(message())
        #endif
    }
}
