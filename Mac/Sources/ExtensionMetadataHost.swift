import WebEngineAppKit

extension ExtensionHost: ExtensionMetadataHost {
    func extensionMetadataInstallation(_ id: String) -> WebExtensionMetadataInstallation? {
        guard let item = Extensions.shared.installed.first(where: { $0.id == id }) else { return nil }
        return WebExtensionMetadataInstallation(id: item.id, version: item.version)
    }
}
