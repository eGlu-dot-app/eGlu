import Foundation

/// Extension origins are case insensitive, including for custom URL schemes.
public enum ExtensionURL {
    public static let schemes: Set<String> = ["chrome-extension", "webkit-extension"]

    public static func isPage(_ url: URL?) -> Bool {
        url?.scheme.map { schemes.contains($0.lowercased()) } ?? false
    }

    public static func identifier(in url: URL?) -> String? {
        guard let url, isPage(url), url.user == nil, url.password == nil, url.port == nil,
              let host = url.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    public static func normalized(_ url: URL) -> URL {
        guard let id = identifier(in: url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = id
        return parts.url ?? url
    }
}
