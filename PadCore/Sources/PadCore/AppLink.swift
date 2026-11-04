import Foundation

/// A link that is another app's to open rather than a page to load:
/// mailto:, tel:, an app's own scheme (instagram://), the App Store's.
/// WebKit loads none of them, so the app hands them over, and decides when.
///
/// A link the person clicked is opened at once. Where the page went there
/// itself (a script after a button, a redirect, a timer) the person is asked
/// first, as Safari asks, so a page or an ad can't send anyone off by
/// itself, and a site's "Open in app" button still works. A frame inside
/// the page is never even let ask, nor a tab that isn't the one on screen;
/// one question shows at a time. A no is taken as one slip of the finger,
/// so the button can be tried again; a second no stands until the page
/// changes, and a page that keeps trying asks twice at most.
public enum AppLink {
    /// What WebKit loads itself, or what stays inside the page.
    static let pages: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    public static func isOne(scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !pages.contains(scheme) && !ExtensionURL.schemes.contains(scheme)
    }

    public enum Answer: Equatable, Sendable {
        case open
        case ask
        case leave
    }

    /// - clicked: a link the person tapped or clicked, as WebKit names it.
    /// - mainFrame: the page itself is going there, not a frame inside it.
    /// - showing: the page is on screen.
    /// - asking: a question about another link is still up.
    /// - refusals: how often the person has said no to this page.
    public static func answer(clicked: Bool, mainFrame: Bool, showing: Bool, asking: Bool, refusals: Int) -> Answer {
        if clicked { return .open }
        guard mainFrame, showing, !asking, refusals < refusalsHeard else { return .leave }
        return .ask
    }

    public static func applicationName(for scheme: String?) -> String? {
        switch scheme?.lowercased() {
        case "mailto": return BrowserText.localized("your email app")
        case "tel", "facetime", "facetime-audio": return BrowserText.localized("your calling app")
        case "sms": return BrowserText.localized("Messages")
        case "msteams", "ms-teams": return "Microsoft Teams"
        case "zoommtg", "zoomus": return "Zoom"
        case "slack": return "Slack"
        case "spotify": return "Spotify"
        case "itms-apps", "itms-appss": return BrowserText.localized("the App Store")
        default: return nil
        }
    }

    /// How many nos it takes for a page to stop being let ask.
    public static let refusalsHeard = 2
}
