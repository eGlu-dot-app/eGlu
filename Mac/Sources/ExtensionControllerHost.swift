import Foundation
import IOKit.pwr_mgt
import WebEngineAppKit

extension ExtensionHost: ExtensionControllerHost {
    func extensionInstallation(_ id: String) -> WebExtensionInstallation? {
        Extensions.shared.installed.first { $0.id == id }.map(WebExtensionInstallation.init)
    }
    func extensionSpaceExists(_ space: UUID) -> Bool { Session.shared.workspace.space(space) != nil }
    func extensionIsIncompatible(_ id: String) -> Bool { Extensions.shared.isIncompatible(id) }
    func extensionCleared(_ id: String, in space: UUID) async -> Bool { await Extensions.shared.cleared(id, in: space) }
    func markExtensionLoadIncompatible(_ id: String, version: String) {
        Extensions.shared.markLoadIncompatible(id, version: version)
    }
    func releaseExtensionLoadPower(_ key: String) {
        if let assertion = Extensions.shared.keptAwake.removeValue(forKey: key) { IOPMAssertionRelease(assertion) }
    }
    func closeExtensionLoadPopup(_ id: String, in space: UUID) { ExtensionPopups.shared.closeAll(of: id, in: space) }
    func closeExtensionLoadSidePanel(_ id: String, in space: UUID) { ExtensionSidePanels.shared.closeAll(of: id, in: space) }
    func clearExtensionLoadVerdict(_ id: String, in space: UUID) { Extensions.shared.clearLoadVerdict(id, in: space) }
    func noteExtensionLoadFailure(_ error: any Error) {
        #if DEBUG
        Extensions.note("load failed: \(error)")
        #endif
    }
    var extensionControllerMockCapture: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "extensionMockCapture")
        #else
        false
        #endif
    }
}

extension WebExtensionInstallation {
    init(_ item: Extensions.Installed) {
        self.init(id: item.id, name: item.name, version: item.version, source: Source(rawValue: item.source.rawValue)!,
                  siteAccess: SiteAccess(rawValue: item.siteAccess.rawValue)!, spaces: item.spaces,
                  granted: item.granted, folder: item.folder, looksWrong: item.looksWrong, readsCookies: item.readsCookies)
    }
}

extension Extensions.Installed {
    init(_ item: WebExtensionInstallation) {
        self.init(id: item.id, name: item.name, version: item.version, source: Source(rawValue: item.source.rawValue)!,
                  siteAccess: SiteAccess(rawValue: item.siteAccess.rawValue)!, spaces: item.spaces,
                  granted: item.granted, folder: item.folder, looksWrong: item.looksWrong, readsCookies: item.readsCookies)
    }
}
