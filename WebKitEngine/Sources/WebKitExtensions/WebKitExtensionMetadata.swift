#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit

/// Package reads and the icon cache, shared by Settings and the toolbar.
@MainActor
public final class WebKitExtensionMetadata: WebExtensionMetadata {
    private let host: any ExtensionMetadataHost
    private let contexts: () -> [UUID: [String: WKWebExtensionContext]]
    private let package: (String, String) -> URL
    /// Each extension's icon, read once.
    private var icons: [String: NSImage] = [:]
    /// Packages with no icon, not read again for one each time Settings draws.
    private var iconless: Set<String> = []

    public init(host: any ExtensionMetadataHost,
                contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
                package: @escaping (String, String) -> URL) {
        self.host = host
        self.contexts = contexts
        self.package = package
    }

    /// Its icon wherever it is loaded, or from its package when it is on
    /// in no space: for Settings, which lists every one.
    public func icon(of id: String) -> NSImage? {
        if let icon = icons[id] { return icon }
        guard !iconless.contains(id), let item = host.extensionMetadataInstallation(id) else { return nil }
        let loaded = contexts().values.lazy.compactMap { $0[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)) }.first
        let icon = loaded ?? (try? Data(contentsOf: package(item.id, item.version))).flatMap { archive in
            ZipFile.file(in: archive, matching: { $0 == "manifest.json" })
                .flatMap { try? ExtensionManifest(json: $0) }
                .flatMap { Self.icon(in: archive, manifest: $0) }
        }
        if let icon { icons[id] = icon } else { iconless.insert(id) }
        return icon
    }

    public func icon(of id: String, in space: UUID) -> NSImage? {
        if let icon = icons[id] { return icon }
        guard let icon = contexts()[space]?[id]?.webExtension.icon(for: CGSize(width: 32, height: 32)) else { return nil }
        icons[id] = icon
        return icon
    }

    public func forgetIcon(_ id: String) {
        icons[id] = nil
        iconless.remove(id)
    }

    public func manifestFacts(permissions: [String], optionalPermissions: [String]) -> WebExtensionManifestFacts {
        Self.facts(permissions: permissions, optionalPermissions: optionalPermissions)
    }

    private nonisolated static func facts(permissions: [String], optionalPermissions: [String]) -> WebExtensionManifestFacts {
        WebExtensionManifestFacts(offersCookies: optionalPermissions.contains("cookies"),
                                  nativeRequired: permissions.contains("nativeMessaging"),
                                  nativeOptional: !permissions.contains("nativeMessaging") && optionalPermissions.contains("nativeMessaging"))
    }

    public nonisolated func packageName(at file: URL, fallback: String) -> WebExtensionPackageName {
        Self.readPackageName(at: file, fallback: fallback)
    }

    nonisolated static func readPackageName(at file: URL, fallback: String) -> WebExtensionPackageName {
        guard let archive = try? Data(contentsOf: file),
              let data = ZipFile.file(in: archive, matching: { $0 == "manifest.json" }),
              let manifest = try? ExtensionManifest(json: data) else { return WebExtensionPackageName(name: fallback, facts: nil) }
        return WebExtensionPackageName(name: manifest.displayName(in: archive, fallback: fallback),
                                       facts: Self.facts(permissions: manifest.permissions, optionalPermissions: manifest.optionalPermissions))
    }

    /// These helpers keep callers with an already parsed manifest from
    /// parsing it again during the remaining install and update slices.
    public static func name(in archive: Data, manifest: ExtensionManifest, fallback: String) -> String {
        manifest.displayName(in: archive, fallback: fallback)
    }

    public static func name(of package: WKWebExtension) -> String? { package.displayName }

    /// A prompt asks for its own size, without using the shared bar cache.
    public static func icon(of package: WKWebExtension, size: CGSize) -> NSImage? { package.icon(for: size) }

    /// Its icon from its package, before it is installed: the largest its
    /// manifest lists.
    public static func icon(in archive: Data, manifest: ExtensionManifest) -> NSImage? {
        guard let path = manifest.icon, let data = ZipFile.file(in: archive, matching: { $0 == path }) else { return nil }
        return NSImage(data: data)
    }

    public func optionsPageURL(_ id: String, in space: UUID) -> URL? {
        contexts()[space]?[id]?.optionsPageURL
    }

    public static func optionsPageURL(for context: WKWebExtensionContext) -> URL? { context.optionsPageURL }

    public func newTabPageURL(_ id: String, in space: UUID) -> URL? {
        contexts()[space]?[id]?.overrideNewTabPageURL
    }

    public func hasNewTabPage(_ id: String) -> Bool {
        contexts().values.contains { $0[id]?.overrideNewTabPageURL != nil }
    }

    public func isNewTabPage(_ url: URL, in space: UUID) -> Bool {
        contexts()[space]?.values.contains { $0.overrideNewTabPageURL == url } ?? false
    }

    public func sidePanelDefaultPath(_ id: String, in space: UUID) -> String? {
        contexts()[space]?[id].flatMap { ExtensionSurface.defaultSidePanelPath(for: $0) }
    }
}
#endif
