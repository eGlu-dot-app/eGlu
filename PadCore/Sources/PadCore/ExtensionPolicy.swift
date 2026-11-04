import Foundation

/// What every extension is held to, whatever it asks for and whatever the
/// person grants it: Google's sign-in stays untouched (HandsOff).
///
/// An extension's content script on accounts.google.com would be exactly
/// the injected listener Google's sign-in looks for, so every extension
/// context denies the hands-off hosts, which in WebKit beats any site it was
/// granted, all sites included. A click on an extension's button would
/// grant the tab before that denial is read, so on a hands-off page the
/// click grants nothing. And the cookies accounts.google.com receives are
/// set for .google.com, which an extension let on any Google site could
/// read through `chrome.cookies`, so no extension gets that permission
/// unless the person allows it for that one extension, told so.
public enum ExtensionPolicy {
    /// Match patterns every extension context denies: each hands-off host
    /// and the hosts within it.
    public static var deniedSites: [String] {
        HandsOff.hosts.map { "*://*.\($0)/*" }
    }

    /// Permissions every extension context denies until the person allows
    /// one for that extension in its settings, told what it reaches:
    /// `cookies` reads the sign-ins of every site the extension may read,
    /// Google's included.
    public static let heldPermissions: Set<String> = ["cookies"]

    /// Whether a click on an extension's button may grant it the page it
    /// was clicked on.
    public static func grantsOnClick(_ url: URL?) -> Bool {
        !HandsOff.covers(url)
    }

    /// Whether eGlu's own answer to an extension (its shims) may delete
    /// or read the data of sites under `domain`: not those whose cookies go
    /// to a hands-off host. A shim that clears browsing data leaves them.
    public static func mayTouchData(ofDomain domain: String) -> Bool {
        !HandsOff.covers(cookieDomain: domain) && !HandsOff.covers(host: domain)
    }

    /// Whether an extension's own content security policy lets it connect
    /// to `url`, as WebKit checks a connection the extension makes itself:
    /// its `connect-src`, or `default-src` without one. A connection
    /// eGlu makes for it (its worker's WebSocket) is held to the same.
    /// No policy, or neither directive, lets everything through, as in
    /// Chrome. 'self' is the extension's own origin, which no socket is.
    public static func allowsConnection(to url: URL, policy: String?) -> Bool {
        guard let policy else { return true }
        var directives: [String: [String]] = [:]
        for part in policy.split(separator: ";") {
            let words = part.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard let name = words.first, directives[name] == nil else { continue }
            directives[name] = Array(words.dropFirst())
        }
        guard let sources = directives["connect-src"] ?? directives["default-src"] else { return true }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host()?.lowercased() ?? ""
        let web = ["http", "https", "ws", "wss"]
        // A secure scheme is let through by its plain one's name too: https
        // covers wss, and http covers ws (CSP Level 3).
        func schemeMatches(_ source: String) -> Bool {
            source == scheme || (source == "https" && scheme == "wss") || (source == "http" && (scheme == "ws" || scheme == "https" || scheme == "wss"))
                || (source == "ws" && scheme == "wss")
        }
        for source in sources {
            if source == "*" {
                if web.contains(scheme) { return true }
                continue
            }
            if source.hasPrefix("'") { continue }
            if source.hasSuffix(":"), !source.contains("/") {
                if schemeMatches(String(source.dropLast())) { return true }
                continue
            }
            var rest = Substring(source)
            if let separator = rest.range(of: "://") {
                guard schemeMatches(String(rest[..<separator.lowerBound])) else { continue }
                rest = rest[separator.upperBound...]
            } else if !web.contains(scheme) {
                continue
            }
            // The source's path, if it names one: a folder (ending in /)
            // takes what is under it, anything else that one address (CSP
            // Level 3's path-part match).
            var sourcePath = ""
            if let slash = rest.firstIndex(of: "/") {
                sourcePath = String(rest[slash...])
                rest = rest[..<slash]
            }
            if !sourcePath.isEmpty {
                let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
                if sourcePath.hasSuffix("/") ? !path.hasPrefix(sourcePath) : path != sourcePath { continue }
            }
            var sourceHost = String(rest)
            if let colon = sourceHost.lastIndex(of: ":") {
                let port = sourceHost[sourceHost.index(after: colon)...]
                sourceHost = String(sourceHost[..<colon])
                let actual = url.port ?? (["https", "wss"].contains(scheme) ? 443 : 80)
                if port != "*", Int(port) != actual { continue }
            }
            if sourceHost.hasPrefix("*.") {
                if host.hasSuffix(String(sourceHost.dropFirst(1))) { return true }
            } else if sourceHost == host {
                return true
            }
        }
        return false
    }
}

extension ExtensionPolicy {
    /// Whether a website may send its tab to an extension's page: only to
    /// one its manifest shows websites (`web_accessible_resources`), and
    /// only to the sites it names there, as Chrome. A password manager's
    /// sign-in comes back to its own page this way (NordPass); any other
    /// page of any installed extension, a vault's included, is refused.
    /// `source` is the https site sending it; anything unusual (an
    /// encoded slash, a dot segment, a declaration not read here) is
    /// refused rather than read generously. (Search's ExtensionRedirectPolicy)
    ///
    /// `fromRule`: the extension's own declarativeNetRequest rule sent the
    /// tab there, not the site (WebKit marks such a navigation; a page
    /// can't). Then, as Chrome, a plain http site counts too, by its
    /// scheme, and a file shown at an address made afresh each session
    /// (use_dynamic_url) is shown: uBlock Origin Lite's warning for a
    /// known-bad site is one.
    public static func webAccessible(_ target: URL, from source: URL, manifest: [String: Any], scheme: String = "chrome-extension", fromRule: Bool = false) -> Bool {
        let sourceScheme = source.scheme?.lowercased() ?? ""
        guard target.scheme?.lowercased() == scheme,
              target.host != nil, target.user == nil, target.password == nil, target.port == nil,
              sourceScheme == "https" || (fromRule && sourceScheme == "http"),
              source.host != nil, source.user == nil, source.password == nil,
              let components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        else { return false }
        let encoded = components.percentEncodedPath
        let lower = encoded.lowercased()
        guard encoded.hasPrefix("/"), !lower.contains("%2f"), !lower.contains("%5c"),
              let decoded = encoded.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("%"),
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let path = String(decoded.dropFirst())
        guard !path.isEmpty,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
        else { return false }
        // Manifest version 2 lists files alone, for every site.
        if (manifest["manifest_version"] as? Int) == 2, let resources = manifest["web_accessible_resources"] as? [String] {
            return resources.contains { resource(path, matches: $0) }
        }
        guard (manifest["manifest_version"] as? Int) == 3,
              let rules = manifest["web_accessible_resources"] as? [[String: Any]]
        else { return false }
        return rules.contains { rule in
            // An address made afresh each session isn't read here: refused.
            if let dynamic = rule["use_dynamic_url"] {
                guard let on = dynamic as? Bool, !on || fromRule else { return false }
            }
            guard let resources = rule["resources"] as? [String], let sites = rule["matches"] as? [String],
                  resources.contains(where: { resource(path, matches: $0) })
            else { return false }
            return sites.contains { site(source, matches: $0) }
        }
    }

    /// A declarativeNetRequest redirect to one of the extension's own files
    /// arrives with its ? and # escaped into the path: WebKit sets the
    /// rule's extensionPath as a path, where Chrome reads "/blocked.html#site"
    /// as a file and a fragment. The first escaped one is put back as Chrome
    /// reads it, so the page gets its query and fragment and the file is the
    /// one the extension ships. Anything else is left as it is. (Search)
    public static func ruleTarget(_ target: URL) -> URL {
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false),
              components.percentEncodedQuery == nil, components.percentEncodedFragment == nil
        else { return target }
        let path = components.percentEncodedPath
        let lower = path.lowercased()
        let query = lower.range(of: "%3f"), fragment = lower.range(of: "%23")
        guard let first = [query, fragment].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { return target }
        let at = path.index(path.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: first.lowerBound))
        let rest = String(path[path.index(at, offsetBy: 3)...])
        components.percentEncodedPath = String(path[..<at])
        if first == query {
            if let hash = rest.lowercased().range(of: "%23") {
                let split = rest.index(rest.startIndex, offsetBy: rest.lowercased().distance(from: rest.lowercased().startIndex, to: hash.lowerBound))
                components.percentEncodedQuery = String(rest[..<split])
                components.percentEncodedFragment = String(rest[rest.index(split, offsetBy: 3)...])
            } else {
                components.percentEncodedQuery = rest
            }
        } else {
            components.percentEncodedFragment = rest
        }
        return components.url ?? target
    }

    /// A resource pattern: its one wildcard is *; the rest is read as it is.
    private static func resource(_ path: String, matches pattern: String) -> Bool {
        guard !pattern.isEmpty, !pattern.contains("\\"), !pattern.contains("%"),
              !pattern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let clean = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        guard !clean.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
        else { return false }
        let expression = "\\A" + clean.components(separatedBy: "*").map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: ".*") + "\\z"
        guard let regex = try? NSRegularExpression(pattern: expression) else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// A site pattern of manifest version 3 (its path is /*), for the
    /// source's own scheme; any other form is refused.
    private static func site(_ source: URL, matches pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let separator = pattern.range(of: "://"), let host = source.host?.lowercased() else { return false }
        let scheme = String(pattern[..<separator.lowerBound]).lowercased()
        guard scheme == source.scheme?.lowercased() || scheme == "*" else { return false }
        let rest = String(pattern[separator.upperBound...])
        guard let slash = rest.firstIndex(of: "/"), rest[slash...] == "/*" else { return false }
        let allowed = String(rest[..<slash]).lowercased()
        guard !allowed.isEmpty, !allowed.contains(":"), !allowed.contains("@"), !allowed.contains("%"), !allowed.contains("\\") else { return false }
        if allowed == "*" { return true }
        if allowed.hasPrefix("*.") {
            let suffix = String(allowed.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*") else { return false }
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return !allowed.contains("*") && host == allowed
    }
}
