import Foundation

/// The access a person approves, without requiring manifest terminology.
public enum ExtensionAccessDescription {
    public static func capability(_ permission: String) -> String {
        let descriptions = [
            "storage": BrowserText.localized("Store its settings and data on this Mac"),
            "unlimitedStorage": BrowserText.localized("Store data without the normal storage limit"),
            "tabs": BrowserText.localized("Read the addresses and titles of your tabs"),
            "activeTab": BrowserText.localized("Read and change the page when you use the extension"),
            "scripting": BrowserText.localized("Run scripts on sites you allow"),
            "declarativeNetRequest": BrowserText.localized("Block or redirect network requests on allowed sites"),
            "declarativeNetRequestWithHostAccess": BrowserText.localized("Block or redirect requests on allowed sites"),
            "declarativeNetRequestFeedback": BrowserText.localized("Read which network rules were applied"),
            "webRequest": BrowserText.localized("Observe network requests on allowed sites"),
            "webRequestBlocking": BrowserText.localized("Block network requests on allowed sites"),
            "bookmarks": BrowserText.localized("Read and change your bookmarks"),
            "history": BrowserText.localized("Read and change your browsing history"),
            "downloads": BrowserText.localized("Manage downloaded files"),
            "notifications": BrowserText.localized("Show notifications"),
            "clipboardRead": BrowserText.localized("Read your clipboard"),
            "clipboardWrite": BrowserText.localized("Write to your clipboard"),
            "nativeMessaging": BrowserText.localized("Communicate with a desktop app you allow"),
            "sidePanel": BrowserText.localized("Show a side panel"),
            "contextMenus": BrowserText.localized("Add items to page menus"),
            "menus": BrowserText.localized("Add items to page menus"),
            "alarms": BrowserText.localized("Schedule background tasks"),
            "offscreen": BrowserText.localized("Run an extension page in the background"),
            "cookies": BrowserText.localized("Read and change cookies on allowed sites, sign-ins included"),
            "identity": BrowserText.localized("Request sign-in for the extension"),
            "tabCapture": BrowserText.localized("Capture a tab after you allow it"),
            "desktopCapture": BrowserText.localized("Request screen sharing"),
            "management": BrowserText.localized("Read or manage installed extensions"),
            "privacy": BrowserText.localized("Request changes to browser privacy settings"),
            "webNavigation": BrowserText.localized("See which pages you go to"),
            "idle": BrowserText.localized("Know when this Mac is idle"),
            "tabGroups": BrowserText.localized("Read and change your tab groups"),
            "browsingData": BrowserText.localized("Clear your browsing data"),
            "topSites": BrowserText.localized("Read the sites you visit most"),
            "sessions": BrowserText.localized("Read your recently closed tabs"),
            "search": BrowserText.localized("Search with your search engine"),
            "geolocation": BrowserText.localized("Use your location after you allow it"),
            "power": BrowserText.localized("Keep this Mac awake"),
            "system.cpu": BrowserText.localized("Read this Mac's processor details"),
            "system.memory": BrowserText.localized("Read this Mac's memory details"),
            "system.display": BrowserText.localized("Read this Mac's display details"),
            "system.storage": BrowserText.localized("Read this Mac's storage details"),
            "fontSettings": BrowserText.localized("Read and change font settings"),
            "proxy": BrowserText.localized("Change the browser's proxy settings"),
            "contentSettings": BrowserText.localized("Change site settings such as pop-ups and cookies"),
            "pageCapture": BrowserText.localized("Save pages as files"),
            "tts": BrowserText.localized("Speak text aloud"),
            "ttsEngine": BrowserText.localized("Provide a voice for speaking text"),
            "declarativeContent": BrowserText.localized("Show its button on certain pages"),
            "gcm": BrowserText.localized("Receive messages from its server"),
            "readingList": BrowserText.localized("Read and change your reading list"),
            "favicon": BrowserText.localized("Read the icons of sites"),
            "userScripts": BrowserText.localized("Run user scripts on sites you allow"),
            "debugger": BrowserText.localized("Inspect and control pages, as developer tools do"),
            "webRequestAuthProvider": BrowserText.localized("Answer sites' requests to sign in"),
        ]
        return descriptions[permission] ?? String(format: BrowserText.localized("Request an additional capability (%@)"), permission)
    }

    public static func site(_ pattern: String) -> String {
        if ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"].contains(pattern) {
            if pattern.hasPrefix("https:") { return BrowserText.localized("All HTTPS websites") }
            if pattern.hasPrefix("http:") { return BrowserText.localized("All HTTP websites") }
            return BrowserText.localized("All websites")
        }
        if pattern.hasPrefix("file:") { return BrowserText.localized("Local files you open") }
        guard let scheme = pattern.range(of: "://") else { return pattern }
        let rest = pattern[scheme.upperBound...]
        let host = String(rest.prefix { $0 != "/" })
        let path = String(rest.dropFirst(host.count))
        let domain = host.hasPrefix("*.") ? String(format: BrowserText.localized("%@ and its subdomains"), String(host.dropFirst(2))) : host
        let matching = path.isEmpty || path == "/*" ? nil : path
        if pattern.hasPrefix("https:") {
            return matching.map { String(format: BrowserText.localized("%1$@, pages matching %2$@ over HTTPS"), domain, $0) }
                ?? String(format: BrowserText.localized("%@ over HTTPS"), domain)
        }
        if pattern.hasPrefix("http:") {
            return matching.map { String(format: BrowserText.localized("%1$@, pages matching %2$@ over HTTP"), domain, $0) }
                ?? String(format: BrowserText.localized("%@ over HTTP"), domain)
        }
        return matching.map { String(format: BrowserText.localized("%1$@, pages matching %2$@"), domain, $0) } ?? domain
    }

    public static func lines(for grants: [String]) -> [String] {
        Array(Set(grants.map { $0.hasPrefix("site:") ? site(String($0.dropFirst(5))) : capability($0) })).sorted()
    }

    /// A symbol for each capability, so a list of them can be scanned.
    public static func symbol(_ permission: String) -> String {
        let symbols = [
            "storage": "internaldrive", "unlimitedStorage": "internaldrive",
            "tabs": "rectangle.stack", "activeTab": "cursorarrow.click",
            "scripting": "chevron.left.forwardslash.chevron.right", "userScripts": "chevron.left.forwardslash.chevron.right",
            "declarativeNetRequest": "hand.raised", "declarativeNetRequestWithHostAccess": "hand.raised",
            "declarativeNetRequestFeedback": "list.bullet.rectangle", "webRequest": "network", "webRequestBlocking": "hand.raised",
            "bookmarks": "bookmark", "history": "clock.arrow.circlepath", "downloads": "arrow.down.circle",
            "notifications": "bell", "clipboardRead": "doc.on.clipboard", "clipboardWrite": "doc.on.clipboard",
            "nativeMessaging": "arrow.left.arrow.right", "sidePanel": "sidebar.right",
            "contextMenus": "contextualmenu.and.cursorarrow", "menus": "contextualmenu.and.cursorarrow",
            "alarms": "alarm", "offscreen": "rectangle.dashed", "cookies": "lock", "identity": "person.crop.circle",
            "tabCapture": "record.circle", "desktopCapture": "rectangle.dashed.badge.record",
            "management": "puzzlepiece.extension", "privacy": "lock.shield", "webNavigation": "arrow.triangle.turn.up.right.circle",
            "idle": "moon.zzz", "tabGroups": "square.stack.3d.up", "browsingData": "trash", "topSites": "star",
            "sessions": "clock", "search": "magnifyingglass", "geolocation": "location", "power": "bolt",
            "system.cpu": "cpu", "system.memory": "memorychip", "system.display": "display", "system.storage": "externaldrive",
            "fontSettings": "textformat", "proxy": "network.badge.shield.half.filled", "contentSettings": "slider.horizontal.3",
            "pageCapture": "doc.richtext", "tts": "speaker.wave.2", "ttsEngine": "speaker.wave.2",
            "declarativeContent": "eye", "gcm": "antenna.radiowaves.left.and.right", "readingList": "eyeglasses",
            "favicon": "photo", "debugger": "ladybug", "webRequestAuthProvider": "key",
        ]
        return symbols[permission] ?? "puzzlepiece"
    }

    /// What Chrome's own prompt leaves out, as it reaches nothing of yours:
    /// kept for Show All. What it doesn't know is never among them.
    public static let routine: Set<String> = [
        "storage", "unlimitedStorage", "alarms", "contextMenus", "menus", "idle", "sidePanel", "offscreen",
        "activeTab", "power", "declarativeContent", "gcm", "tts", "search", "identity", "notifications",
        "system.cpu", "system.memory", "system.display", "fontSettings",
        // Only where its sites allow, which the line for its sites says.
        "scripting", "webRequest", "webRequestBlocking",
    ]
}

/// What an extension asks for, as a person weighs it: its sites in one
/// line, the capabilities worth a second look, and the rest kept for
/// Show All, with every site written out.
public struct ExtensionAccessSummary: Equatable, Sendable {
    public struct Line: Equatable, Hashable, Sendable {
        public let symbol: String
        public let text: String
    }
    public enum Reach: Equatable, Sendable {
        case none
        case everywhere
        /// Each site once, its subdomains and pages taken in: example.com
        /// for https://*.example.com/private/*.
        case hosts([String])
    }

    public let reach: Reach
    /// It asks for local files (file:///*).
    public let localFiles: Bool
    public let notable: [Line]
    public let routine: [Line]
    /// Every site as asked for, in words.
    public let siteLines: [String]
    /// It asks for cookies, which it gets only once the person allows them
    /// (ExtensionPolicy.heldPermissions): a choice of its own, not a line.
    public let cookies: Bool

    public init(permissions: [String], sites: [String]) {
        let permissions = Array(Set(permissions)).sorted()
        func line(_ permission: String) -> Line {
            Line(symbol: ExtensionAccessDescription.symbol(permission), text: ExtensionAccessDescription.capability(permission))
        }
        // Two permissions in the same words (contextMenus, menus) are one line.
        func once(_ lines: [Line]) -> [Line] {
            var seen = Set<String>()
            return lines.filter { seen.insert($0.text).inserted }.sorted { $0.text < $1.text }
        }
        cookies = permissions.contains("cookies")
        let lined = permissions.filter { $0 != "cookies" }
        notable = once(lined.filter { !ExtensionAccessDescription.routine.contains($0) }.map(line))
        routine = once(lined.filter { ExtensionAccessDescription.routine.contains($0) }.map(line))
        let sites = Array(Set(sites)).sorted()
        siteLines = Array(Set(sites.map(ExtensionAccessDescription.site))).sorted()
        localFiles = sites.contains { $0.hasPrefix("file:") }
        let web = sites.filter { !$0.hasPrefix("file:") }
        if web.contains(where: Self.isEverywhere) {
            reach = .everywhere
        } else {
            let hosts = Set(web.compactMap(Self.host)).sorted()
            reach = hosts.isEmpty ? .none : .hosts(hosts)
        }
    }

    /// From what an installed one was allowed (ExtensionManifest.grants).
    public init(grants: [String]) {
        self.init(permissions: grants.filter { !$0.hasPrefix("site:") },
                  sites: grants.filter { $0.hasPrefix("site:") }.map { String($0.dropFirst(5)) })
    }

    public var isEmpty: Bool { reach == .none && !localFiles && notable.isEmpty && routine.isEmpty && !cookies }

    /// The line for its sites; with `onClick`, as When I Click It leaves it.
    public func siteHeadline(onClick: Bool) -> String? {
        if onClick, reach != .none || localFiles { return BrowserText.localized("Read and change the page you're on, only when you click it") }
        switch reach {
        case .none: return localFiles ? BrowserText.localized("Read and change local files you open") : nil
        case .everywhere: return BrowserText.localized("Read and change pages on all websites")
        case .hosts(let hosts) where hosts.count <= 3:
            return String(format: BrowserText.localized("Read and change pages on %@"), ListFormatter.localizedString(byJoining: hosts))
        case .hosts(let hosts):
            return String(format: BrowserText.localized("Read and change pages on %lld sites"), hosts.count)
        }
    }

    static func isEverywhere(_ pattern: String) -> Bool {
        guard pattern != "<all_urls>" else { return true }
        guard let host = host(pattern) else { return false }
        return host == "*"
    }

    /// A pattern's host, its subdomains and port taken in: nil for one
    /// that isn't a pattern.
    static func host(_ pattern: String) -> String? {
        guard let scheme = pattern.range(of: "://") else { return nil }
        var host = String(pattern[scheme.upperBound...].prefix { $0 != "/" })
        if let port = host.lastIndex(of: ":") { host = String(host[..<port]) }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        return host.isEmpty ? nil : host
    }
}

/// A zero update count is meaningful only alongside every extension's outcome.
public struct ExtensionUpdateReport: Sendable {
    public enum Status: Sendable { case completed, busy, disabled, notDue, empty }
    public enum Outcome: String, Sendable { case current, updated, failed, declined, deferred }
    public struct Entry: Sendable {
        public let id: String
        public let name: String
        public let outcome: Outcome
        public let detail: String?
        public init(id: String, name: String, outcome: Outcome, detail: String? = nil) {
            self.id = id; self.name = name; self.outcome = outcome; self.detail = detail
        }
    }
    public var status: Status
    public var entries: [Entry]
    public init(status: Status = .completed, entries: [Entry] = []) { self.status = status; self.entries = entries }
    public var fullyChecked: Bool { status == .completed && !entries.isEmpty && entries.allSatisfy { [.current, .updated].contains($0.outcome) } }
    public var summary: String {
        switch status {
        case .busy: return BrowserText.localized("An update check is already running.")
        case .disabled: return BrowserText.localized("Automatic update checks are off.")
        case .notDue: return BrowserText.localized("The next automatic check is not due yet.")
        case .empty: return BrowserText.localized("No Chrome Web Store extensions to check.")
        case .completed: break
        }
        guard !entries.isEmpty else { return BrowserText.localized("The store did not return an update result. Try again.") }
        let updated = entries.filter { $0.outcome == .updated }.count
        if fullyChecked {
            if updated == 0 { return BrowserText.localized("All checked extensions are up to date.") }
            return updated == 1 ? String(format: BrowserText.localized("Updated %lld extension."), updated)
                                : String(format: BrowserText.localized("Updated %lld extensions."), updated)
        }
        let counts = [Outcome.updated, .current, .failed, .declined, .deferred].compactMap { outcome -> String? in
            let count = entries.filter { $0.outcome == outcome }.count
            guard count > 0 else { return nil }
            switch outcome {
            case .updated: return String(format: BrowserText.localized("%lld updated"), count)
            case .current: return String(format: BrowserText.localized("%lld current"), count)
            case .failed: return String(format: BrowserText.localized("%lld failed"), count)
            case .declined: return String(format: BrowserText.localized("%lld declined"), count)
            case .deferred: return String(format: BrowserText.localized("%lld deferred"), count)
            }
        }
        return String(format: BrowserText.localized("%@. Check Again retries failures and declined versions."), counts.joined(separator: ", "))
    }
}
