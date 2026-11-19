import Foundation

/// A part of Settings the address bar goes straight to: "change icon" typed
/// there offers App Icon, and taking the row opens Settings scrolled to it.
/// One for each section of the Settings screen (SettingsView), found by its
/// name and by the words for what is changed there.
public enum SettingsAnchor: String, CaseIterable, Sendable {
    case defaultBrowser
    case sync
    case appIcon
    case desktopView
    case addressBar
    case window
    case spaces
    case memory
    case trackpad
    case search
    case history
    case blocking
    case linkMenu
    case handoff
    case writing
    case diagnostics
    case developer
    case shortcuts
    /// The Mac's own panes: the iPhone and iPad have neither.
    case pinnedTabs
    case extensions

    /// The section, as its row names it.
    public var title: String {
        switch self {
        case .defaultBrowser: return BrowserText.localized("Default browser")
        case .sync: return BrowserText.localized("iCloud")
        case .appIcon: return BrowserText.localized("App icon")
        case .desktopView: return BrowserText.localized("Trackpad View")
        case .addressBar: return BrowserText.localized("The address bar shows")
        case .window: return BrowserText.localized("Window")
        case .spaces: return BrowserText.localized("Spaces and bookmarks")
        case .memory: return BrowserText.localized("Memory")
        case .trackpad: return BrowserText.localized("Trackpad and keyboard")
        case .search: return BrowserText.localized("Search")
        case .history: return BrowserText.localized("History")
        case .blocking: return BrowserText.localized("Ads and trackers")
        case .linkMenu: return BrowserText.localized("Link menu")
        case .handoff: return BrowserText.localized("Handoff")
        case .writing: return BrowserText.localized("Writing")
        case .diagnostics: return BrowserText.localized("Developer diagnostics")
        case .developer: return BrowserText.localized("Developer")
        case .shortcuts: return BrowserText.localized("Shortcuts")
        case .pinnedTabs: return BrowserText.localized("Pinned Tabs")
        case .extensions: return BrowserText.localized("Extensions")
        }
    }

    /// What is changed there, for the line under the name.
    public var detail: String {
        switch self {
        case .defaultBrowser: return BrowserText.localized("Open links from other apps here")
        case .sync: return BrowserText.localized("Spaces, bookmarks and pinned tabs on your devices")
        case .appIcon: return BrowserText.localized("The Home Screen icon")
        case .desktopView: return BrowserText.localized("How far the cursor goes")
        case .addressBar: return BrowserText.localized("The page's address or its title")
        case .window: return BrowserText.localized("Tabs along the top or in a sidebar")
        case .spaces: return BrowserText.localized("Edit spaces, import bookmarks")
        case .memory: return BrowserText.localized("Tabs kept open off screen")
        case .trackpad: return BrowserText.localized("Scrolling, Tab and arrow keys, cursors")
        case .search: return BrowserText.localized("The engine, suggestions, Apple Intelligence")
        case .history: return BrowserText.localized("How long it is kept, clearing it")
        case .blocking: return BrowserText.localized("The content blocker and its lists")
        case .linkMenu: return BrowserText.localized("Sites with their own menus")
        case .handoff: return BrowserText.localized("A page and a question, to another app")
        case .writing: return BrowserText.localized("Grammar and spelling as you type, in English")
        case .diagnostics: return BrowserText.localized("The panel over the page")
        case .developer: return BrowserText.localized("Sites, keys and JSON for developer mode")
        case .shortcuts: return BrowserText.localized("Every command's keys")
        case .pinnedTabs: return BrowserText.localized("Each space's pinned tabs, in their order")
        case .extensions: return BrowserText.localized("Installed extensions and what they may do")
        }
    }

    /// Words it is also found by: what one wants done, not what the section
    /// is called.
    public var keywords: [String] {
        switch self {
        case .defaultBrowser: return ["set as default", "make default", "browser app", "open links"]
        case .sync: return ["sync", "icloud", "cloudkit", "other devices", "mac", "turn on sync"]
        case .appIcon:
            return ["change icon", "change app icon", "home screen icon", "alternate icon", "icon style", "logo"]
        case .desktopView: return ["cursor speed", "pointer speed", "sensitivity", "tracking speed"]
        case .addressBar: return ["show address", "show title", "url", "page title"]
        case .window:
            return ["layout", "compact", "separate", "tab layout", "hide tab bar", "show tab bar", "window", "sidebar",
                    "vertical tabs",
                    "show address", "show title", "url"]
        case .spaces: return ["manage spaces", "edit spaces", "rename space", "delete space", "reorder spaces", "profiles"]
        case .memory: return ["light tabs", "tabs kept open", "freeze tabs", "frozen tabs", "background tabs", "ram"]
        case .trackpad:
            return ["two-finger scroll", "scroll", "wheel", "tab key", "arrow keys", "page cursor", "pointer", "bridge"]
        case .search:
            return ["change search engine", "default search", "suggestions", "search suggestions", "autocomplete",
                    "apple intelligence"] + Engine.allCases.map { $0.title.lowercased() }
        case .history:
            return ["clear history", "delete history", "browsing history", "keep history", "forget", "erase"]
        case .blocking: return ["ad blocker", "adblock", "block ads", "content blocker", "privacy", "easylist"]
        case .linkMenu: return ["context menu", "long press", "right click", "secondary click", "own menus"]
        case .handoff:
            return ["ai", "ask ai", "assistant", "claude", "chatgpt", "gemini", "markdown", "summarize", "question", "prompt"]
        case .writing: return ["grammar", "spelling", "harper", "writing", "check"]
        case .diagnostics: return ["debug", "hud", "show diagnostics", "user agent"]
        case .developer:
            return ["developer mode", "devtools", "web inspector", "localhost", "json", "element picture",
                    "developer tools keys"]
        case .shortcuts: return ["shortcuts", "cheat sheet", "cheatsheet", "keys", "hotkeys", "key commands"]
        case .pinnedTabs: return ["pinned", "pin tab", "unpin", "reorder pinned"]
        case .extensions:
            return ["extension", "add-on", "addon", "plugin", "chrome web store", "install extension", "remove extension"]
        }
    }

    /// Whether Settings has the section on this kind of device: an iPhone
    /// has one bar and no trackpad, an iPad no Desktop View.
    public func isOffered(phone: Bool) -> Bool {
        isOffered(phoneLayout: phone, padLayout: !phone)
    }

    /// Whether Settings has the section where windows take the phone's
    /// layout, the iPad's, or either: the iPhone Duo and a large iPhone have
    /// both, as they open or turn (Docs/iPhoneDuoPlan.md, decisions 5 and 9).
    /// A keyboard with keys brings a phone layout the keyboard's parts, as
    /// it brings their groups (SettingsGroup.isOffered(padLayout:keyboard:)).
    public func isOffered(phoneLayout: Bool, padLayout: Bool, keyboard: Bool = false) -> Bool {
        switch self {
        case .desktopView, .addressBar: return phoneLayout
        case .window: return padLayout
        case .trackpad, .shortcuts: return padLayout || keyboard
        case .pinnedTabs, .extensions: return false
        default: return true
        }
    }
}


/// Settings categories and command-search destinations share one routing policy.
public enum SettingsGroup: String, CaseIterable, Hashable, Sendable {
    // Developer mode and the diagnostics panel's switch share the last
    // group, the diagnostics' section only where they are offered at all.
    case general, spaces, browsing, privacy, writing, input, shortcuts, developer

    public var title: String {
        switch self {
        case .general: return BrowserText.localized("General")
        case .spaces: return BrowserText.localized("Spaces and iCloud")
        case .browsing: return BrowserText.localized("Browsing")
        case .privacy: return BrowserText.localized("Search and privacy")
        case .writing: return BrowserText.localized("Writing")
        case .input: return BrowserText.localized("Keyboard and trackpad")
        case .shortcuts: return BrowserText.localized("Shortcuts")
        case .developer: return BrowserText.localized("Developer")
        }
    }

    public var detail: String {
        switch self {
        case .general: return BrowserText.localized("Default browser and app icon")
        case .spaces: return BrowserText.localized("Spaces, bookmarks, pinned tabs and sync")
        case .browsing: return BrowserText.localized("Tabs, address bar, cursor, link menus and memory")
        case .privacy: return BrowserText.localized("Search suggestions, history, ads and trackers")
        case .writing: return BrowserText.localized("Grammar and spelling in pages")
        case .input: return BrowserText.localized("Scrolling, keys and cursor styles")
        case .shortcuts: return BrowserText.localized("Browser commands and system limitations")
        case .developer: return BrowserText.localized("Sites, keys and JSON for developer mode")
        }
    }

    public func isOffered(padLayout: Bool, keyboard: Bool) -> Bool {
        switch self {
        case .input, .shortcuts: return padLayout || keyboard
        default: return true
        }
    }
}

public extension SettingsAnchor {
    var group: SettingsGroup {
        switch self {
        case .defaultBrowser, .appIcon: return .general
        case .sync, .spaces, .pinnedTabs: return .spaces
        case .desktopView, .addressBar, .window, .memory, .linkMenu, .extensions: return .browsing
        case .search, .history, .blocking, .handoff: return .privacy
        case .writing: return .writing
        case .trackpad: return .input
        case .shortcuts: return .shortcuts
        case .diagnostics, .developer: return .developer
        }
    }
}
