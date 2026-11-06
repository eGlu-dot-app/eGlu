import Foundation
import WebEngineAppKit

extension ExtensionHost: ExtensionScriptHost {
    var extensionScriptRoot: URL { Extensions.folder }

    func extensionScriptInstallation(_ id: () -> String) -> WebExtensionScriptInstallation? {
        Extensions.shared.installed.first { $0.id == id() }.map {
            WebExtensionScriptInstallation(id: $0.id, name: $0.name, version: $0.version, isUnsigned: $0.source == .unsigned)
        }
    }
}
