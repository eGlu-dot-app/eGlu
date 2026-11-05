#if os(macOS)
import Foundation
import WebKit

extension ExtensionSurface {
    public static func defaultSidePanelPath(for context: WKWebExtensionContext) -> String? {
        let manifest = context.webExtension.manifest
        return (manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    public static func sidePanelEntry(_ path: String, for context: WKWebExtensionContext) -> URL? {
        URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }
}
#endif
