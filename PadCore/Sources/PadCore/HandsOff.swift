import Foundation

/// Hosts the app never touches. No script of its own runs on their pages, in
/// any world; no JavaScript is called into them; their cookies are never read.
///
/// Google's sign-in is why the list exists. It looks for signs of an embedded
/// or automated browser, and anything an app does inside it, from a style
/// sheet to an injected listener, is a reason for Google to refuse the
/// sign-in or put the account through extra checks. Left alone it sees
/// Safari on a Mac and nothing else.
///
/// The app reads no cookies anywhere, so the cookie rule holds by not having
/// the code; `covers(cookieDomain:)` is for anything that ever has to. An
/// extension the person lets read cookies can read these too
/// (ExtensionPolicy.heldPermissions); that is its, and their, choice.
public enum HandsOff {
    public static let hosts = ["accounts.google.com"]

    public static func covers(_ url: URL?) -> Bool {
        covers(host: url?.host())
    }

    public static func covers(host: String?) -> Bool {
        guard let host = Hosts.normal(host) else { return false }
        return hosts.contains { Hosts.host(host, isWithin: $0) }
    }

    /// A cookie set for `domain` is sent to every host within it, so reading
    /// a ".google.com" cookie reads one accounts.google.com receives.
    public static func covers(cookieDomain domain: String) -> Bool {
        var bare = domain.lowercased()
        while bare.hasPrefix(".") { bare.removeFirst() }
        guard let name = Hosts.normal(bare) else { return false }
        return hosts.contains { Hosts.host($0, isWithin: name) }
    }
}

/// Whether WebKit's own scrolling stays on for a page.
///
/// It is off, so two fingers on the trackpad reach the page instead of
/// moving it, and the page scrolls through the wheel bridge (bridge.js
/// scrolls what a desktop browser would when the page doesn't take the
/// wheel). Two kinds of page have no bridge to scroll them and keep WebKit's:
/// a hands-off page, where no script of the app's may run, and a PDF, which
/// WebKit draws itself rather than as a document.
public enum Scrolling {
    public static func isNative(url: URL?, mimeType: String?) -> Bool {
        if HandsOff.covers(url) { return true }
        if mimeType?.lowercased() == "application/pdf" { return true }
        return url?.pathExtension.lowercased() == "pdf" && mimeType == nil
    }
}
