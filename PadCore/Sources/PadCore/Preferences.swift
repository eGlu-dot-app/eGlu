import Foundation

/// A setting that can leave a choice to each site's adapter.
public enum Override: String, Codable, CaseIterable, Sendable {
    case site
    case on
    case off
}

/// Settings, saved as one JSON value. Every field has a default, and a field
/// missing from what was saved takes its default, so a setting added later
/// doesn't throw away the ones already there.
public struct Preferences: Codable, Equatable, Sendable {
    /// Where a window keeps its tabs (Settings › Tabs): in a row along the
    /// top, or in a sidebar down its side, as Arc keeps them.
    public enum TabsPlacement: String, Codable, CaseIterable, Sendable {
        case top
        case sidebar
    }

    /// Whether the tab on screen along the top, which is the address, says
    /// where the page is (always) or its title, but for sign-in pages.
    public var address: AddressMode = .always
    public var tabBar = true
    /// The wheel bridge for every site, or nil to leave it to each adapter.
    public var wheel: WheelMode?
    /// Tab and the arrow keys taken from the system for the page.
    public var keys: Override = .site
    public var limits = LiveLimits()
    public var diagnostics = false
    public var engine = Destination.standardEngine
    /// The engine's suggestions under the address as it is typed
    /// (Autocomplete), which sends what is typed to the engine; on unless
    /// turned off.
    public var searchSuggestions = true

    /// Whether what is typed may go to `provider` for its suggestions: the
    /// engine chosen, with its suggestions on.
    public func allowsRemoteSuggestions(for provider: String) -> Bool {
        searchSuggestions && engine == provider
    }

    public mutating func setRemoteSuggestions(_ enabled: Bool) {
        searchSuggestions = enabled
    }
    /// Apple Intelligence's on-device model finding tabs, bookmarks and
    /// commands by what the words typed mean (Autocomplete), where the device
    /// has it; on unless turned off. Nothing leaves the device for it.
    public var intelligence = true
    /// Pages' own cursor images, drawn over the hidden system pointer.
    public var pageCursors = true
    /// Request Desktop Site or Request Mobile Site, by site (SiteMode.siteKey).
    public var siteModes: [String: SiteMode] = [:]
    /// Spaces and their bookmarks kept in iCloud (CloudSync.swift); off until turned on.
    public var iCloudSync = false
    /// How far the iPhone's desktop view cursor goes for a finger's move,
    /// times the usual (DesktopView.cursorSpeeds).
    public var cursorSpeed = 1.0
    /// Ads and trackers blocked by WebKit's content blocker, with EasyList
    /// and EasyPrivacy (ContentBlocking.swift); on unless turned off.
    public var blocksContent = true
    /// The sites it is off for, by site (SiteMode.siteKey).
    public var unblockedSites: [String] = []
    /// The filter lists turned on or off in Settings, by the list's id. One
    /// not named here is as it starts out (ContentBlocking.isOnByDefault),
    /// so a list added later, or a device whose language changes, needs
    /// nothing saved.
    public var filterLists: [String: Bool] = [:]
    /// Sites said to keep their own context menus (true) or, for a built-in
    /// one, not to (false), by host (OwnMenus).
    public var ownMenuSites: [String: Bool] = [:]
    /// Handoff (Handoff.swift): the page on screen as a file, with its
    /// address, to an app picked in the share sheet. Off until turned on.
    public var handoff = false
    /// Pinned tabs this device leaves out of its tab bar, by id (Settings ›
    /// Pinned Tabs). They stay pinned, in their place, and in iCloud: only
    /// this device's row goes without them, and the Mac's preferences are
    /// its own, so it chooses for itself.
    public var hiddenPinnedTabs: Set<UUID> = []
    /// Where this device's windows keep their tabs; nil is the device's own
    /// way: the iPad's row along the top, the Mac's sidebar. A phone keeps
    /// them in its bar at the bottom whatever this says.
    public var tabsPlacement: TabsPlacement?
    /// The space's bookmarks in a bar under the tabs, where they are along
    /// the top: the button beside New Tab turns it on and off. Off until
    /// turned on.
    public var bookmarksBar = false
    /// How long each space's history is kept (Settings › History).
    public var historyRetention = HistoryRetention.month
    /// History on this device's other devices too, through iCloud (Settings
    /// › iCloud › Sync history), where Sync with iCloud is on. Off until turned on.
    public var historySync = false
    /// The parts of a new tab's page left out (its Customize): every part
    /// shows until left out, one added later too.
    public var hiddenStartSections: Set<StartSection> = []
    /// A link from a pinned tab to another site opens in a Peek over the
    /// tab (Peek.opensFromPinned), as in Arc; on unless turned off. The Mac's alone.
    public var peekFromPinnedTabs = true
    /// Float a playing video or a site's picture window when its tab leaves
    /// the screen, or another app comes forward. The Mac's alone.
    public var automaticPictureInPicture = true
    /// Where a link from another app opens, with eGlu the default
    /// browser: a little window of its own, as Arc's Little Arc, or a new
    /// tab of the window in front. The Mac's alone.
    public var linksFromApps = LinksFromApps.littleWindow
    /// Whether Harper checks the English typed in pages (Docs/Tasks/02).
    /// Off until the person turns it on.
    public var writing = false
    /// Harper's English (Engines' Dialect): "American", "British",
    /// "Canadian", "Australian" or "Indian".
    public var writingDialect = "American"
    /// Harper's rules the person changed, by name: only the differences
    /// from its defaults.
    public var writingRules: [String: Bool] = [:]
    /// Sites where pages are not checked, by site (SiteMode.siteKey, as
    /// unblockedSites and siteModes keep them).
    public var writingOffSites: [String] = []
    /// Whether Harper checks the English typed in other apps too (Docs/Tasks/03). Off until turned on.
    public var writingOtherApps = false
    /// Apps turned on or off by the person, by bundle identifier: only the differences from WritingApps.curated.
    public var writingApps: [String: Bool] = [:]
    /// Whether an app not yet chosen is checked.
    public var writingNewApps = false
    /// Developer mode on or off for each site that has chosen, by site
    /// (SiteMode.siteKey): turned on or off once, the choice stays until
    /// changed again. A site not here has it on when it is local and
    /// `developerLocal` is on, off otherwise (DeveloperMode.isOn).
    public var developerSites: [String: Bool] = [:]
    /// JSON pages shown formatted and folded (the json-view script); on
    /// unless turned off.
    public var formatJSON = true
    /// The keys the developer tools answer to: eGlu's own ⌃⌥, or Chrome's
    /// ⌥⌘. ⌥⌘ on, a page's own ⌥⌘ keys never reach it (Settings says so).
    public var developerKeys = DeveloperKeys.controlOption
    /// Developer mode on by itself on local sites (Settings › Developer);
    /// on unless turned off.
    public var developerLocal = true
    /// The measuring tool's column guides (the panel's fields): this many
    /// columns across the window.
    public var measureColumns = 12
    /// The space between the guides' columns, in points.
    public var measureGutter = 24.0
    /// The space the columns leave at the window's sides, in points.
    public var measureMargin = 0.0
    /// The row guides' step, in points: a line every this much.
    public var measureRow = 8.0
    /// The rulers the tool starts with; on unless turned off.
    public var measureRulers = true

    /// The modifier keys the developer tools' commands answer to.
    public enum DeveloperKeys: String, Codable, CaseIterable, Sendable {
        /// ⌃⌥, eGlu's own, beside the browser keys it already uses.
        case controlOption
        /// ⌥⌘, as Chrome has them.
        case optionCommand
    }

    /// Where a link from another app opens (Settings › General › Links).
    public enum LinksFromApps: String, Codable, CaseIterable, Sendable {
        case littleWindow
        case newTab
    }

    /// A part of a new tab's page, under the address field.
    public enum StartSection: String, Codable, CaseIterable, Sendable {
        /// The space's bookmarks, as tiles.
        case bookmarks
        /// The pages last gone to in the space on this device.
        case history
        /// The pages last gone to in the space on the person's other devices (History in iCloud).
        case otherDevices
    }

    public init() {}

    /// Whether this device shows `tab` in its row: every tab that isn't
    /// pinned, and every pinned one not hidden.
    public func shows(_ tab: TabRecord) -> Bool {
        !tab.isPinned || !hiddenPinnedTabs.contains(tab.id)
    }

    enum CodingKeys: String, CodingKey {
        // A layout with the address bar under the tabs (layout) once went with
        // these; one saved then is let go: the tab on screen is the address.
        case address, tabBar, wheel, keys, limits, diagnostics, engine, pageCursors, siteModes, iCloudSync, cursorSpeed
        case blocksContent, unblockedSites, searchSuggestions, intelligence, ownMenuSites, filterLists
        // A question of Handoff's own once went with the file; one saved then is let go.
        case handoff
        case hiddenPinnedTabs
        case tabsPlacement
        // The sidebar's Bookmarks once folded away under their name; they come out
        // as a popover now, and a choice saved then is let go.
        case bookmarksBar
        case historyRetention, historySync
        case hiddenStartSections
        case peekFromPinnedTabs, linksFromApps, automaticPictureInPicture
        case writing, writingDialect, writingRules, writingOffSites
        case writingOtherApps, writingApps, writingNewApps
        case developerSites, formatJSON, developerKeys, developerLocal
        case measureColumns, measureGutter, measureMargin, measureRow, measureRulers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = (try? c.decodeIfPresent(AddressMode.self, forKey: .address)) ?? .always
        tabBar = (try? c.decodeIfPresent(Bool.self, forKey: .tabBar)) ?? true
        wheel = (try? c.decodeIfPresent(WheelMode.self, forKey: .wheel)) ?? nil
        keys = (try? c.decodeIfPresent(Override.self, forKey: .keys)) ?? .site
        limits = (try? c.decodeIfPresent(LiveLimits.self, forKey: .limits)) ?? LiveLimits()
        diagnostics = (try? c.decodeIfPresent(Bool.self, forKey: .diagnostics)) ?? false
        engine = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? Destination.standardEngine
        searchSuggestions = (try? c.decodeIfPresent(Bool.self, forKey: .searchSuggestions)) ?? true
        intelligence = (try? c.decodeIfPresent(Bool.self, forKey: .intelligence)) ?? true
        pageCursors = (try? c.decodeIfPresent(Bool.self, forKey: .pageCursors)) ?? true
        siteModes = (try? c.decodeIfPresent([String: SiteMode].self, forKey: .siteModes)) ?? [:]
        iCloudSync = (try? c.decodeIfPresent(Bool.self, forKey: .iCloudSync)) ?? false
        let speed = (try? c.decodeIfPresent(Double.self, forKey: .cursorSpeed)) ?? 1
        cursorSpeed = min(max(speed, DesktopView.cursorSpeeds.lowerBound), DesktopView.cursorSpeeds.upperBound)
        blocksContent = (try? c.decodeIfPresent(Bool.self, forKey: .blocksContent)) ?? true
        unblockedSites = (try? c.decodeIfPresent([String].self, forKey: .unblockedSites)) ?? []
        ownMenuSites = (try? c.decodeIfPresent([String: Bool].self, forKey: .ownMenuSites)) ?? [:]
        filterLists = (try? c.decodeIfPresent([String: Bool].self, forKey: .filterLists)) ?? [:]
        handoff = (try? c.decodeIfPresent(Bool.self, forKey: .handoff)) ?? false
        hiddenPinnedTabs = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .hiddenPinnedTabs)) ?? []
        tabsPlacement = (try? c.decodeIfPresent(TabsPlacement.self, forKey: .tabsPlacement)) ?? nil
        bookmarksBar = (try? c.decodeIfPresent(Bool.self, forKey: .bookmarksBar)) ?? false
        historyRetention = (try? c.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention)) ?? .month
        historySync = (try? c.decodeIfPresent(Bool.self, forKey: .historySync)) ?? false
        hiddenStartSections = (try? c.decodeIfPresent(Set<StartSection>.self, forKey: .hiddenStartSections)) ?? []
        peekFromPinnedTabs = (try? c.decodeIfPresent(Bool.self, forKey: .peekFromPinnedTabs)) ?? true
        automaticPictureInPicture = (try? c.decodeIfPresent(Bool.self, forKey: .automaticPictureInPicture)) ?? true
        linksFromApps = (try? c.decodeIfPresent(LinksFromApps.self, forKey: .linksFromApps)) ?? .littleWindow
        writing = (try? c.decodeIfPresent(Bool.self, forKey: .writing)) ?? false
        writingDialect = (try? c.decodeIfPresent(String.self, forKey: .writingDialect)) ?? "American"
        writingRules = (try? c.decodeIfPresent([String: Bool].self, forKey: .writingRules)) ?? [:]
        writingOffSites = (try? c.decodeIfPresent([String].self, forKey: .writingOffSites)) ?? []
        writingOtherApps = (try? c.decodeIfPresent(Bool.self, forKey: .writingOtherApps)) ?? false
        writingApps = (try? c.decodeIfPresent([String: Bool].self, forKey: .writingApps)) ?? [:]
        writingNewApps = (try? c.decodeIfPresent(Bool.self, forKey: .writingNewApps)) ?? false
        developerSites = (try? c.decodeIfPresent([String: Bool].self, forKey: .developerSites)) ?? [:]
        formatJSON = (try? c.decodeIfPresent(Bool.self, forKey: .formatJSON)) ?? true
        developerKeys = (try? c.decodeIfPresent(DeveloperKeys.self, forKey: .developerKeys)) ?? .controlOption
        developerLocal = (try? c.decodeIfPresent(Bool.self, forKey: .developerLocal)) ?? true
        measureColumns = (try? c.decodeIfPresent(Int.self, forKey: .measureColumns)) ?? 12
        measureGutter = (try? c.decodeIfPresent(Double.self, forKey: .measureGutter)) ?? 24
        measureMargin = (try? c.decodeIfPresent(Double.self, forKey: .measureMargin)) ?? 0
        measureRow = (try? c.decodeIfPresent(Double.self, forKey: .measureRow)) ?? 8
        measureRulers = (try? c.decodeIfPresent(Bool.self, forKey: .measureRulers)) ?? true
    }

    /// Whether a page at `host` has ads and trackers blocked.
    public func blocksContent(onHost host: String?) -> Bool {
        guard blocksContent else { return false }
        guard let site = SiteMode.siteKey(host) else { return true }
        return !unblockedSites.contains(site)
    }

    /// Blocking on or off for the site at `host`, the rest as they were.
    public mutating func setBlocksContent(_ on: Bool, onHost host: String?) {
        guard let site = SiteMode.siteKey(host) else { return }
        unblockedSites.removeAll { $0 == site }
        if !on { unblockedSites.append(site) }
        unblockedSites.sort()
    }

    /// Whether a page at `host` has its typing checked (WritingSites).
    public func checksWriting(onHost host: String?) -> Bool {
        guard writing, let site = SiteMode.siteKey(host) else { return false }
        return !writingOffSites.contains(site)
    }

    /// Checking on or off for the site at `host`, the rest as they were.
    public mutating func setWritingChecks(_ on: Bool, onHost host: String?) {
        guard let site = SiteMode.siteKey(host) else { return }
        writingOffSites.removeAll { $0 == site }
        if !on { writingOffSites.append(site) }
        writingOffSites.sort()
    }

    /// An adapter's bridges with these settings laid over them.
    public func bridges(for adapter: SiteAdapter) -> Bridges {
        var bridges = adapter.bridges
        if let wheel { bridges.wheel = wheel }
        switch keys {
        case .site: break
        case .on: bridges.keys = Set(RelayKey.allCases)
        case .off: bridges.keys = []
        }
        if !pageCursors { bridges.cursors = false }
        return bridges
    }
}

extension Preferences {
    /// The settings saved under `key`, or the defaults where none are.
    public static func stored(in defaults: UserDefaults, key: String) -> Preferences {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }

    public func store(in defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }

    /// The settings that something besides the pages answers to when they
    /// change: what both apps' Session look at after a change.
    public struct Changes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let historyRetention = Changes(rawValue: 1 << 0)
        public static let historySync = Changes(rawValue: 1 << 1)
        /// Content blocking turned on or off, or a filter list.
        public static let contentBlocking = Changes(rawValue: 1 << 2)
        public static let iCloudSync = Changes(rawValue: 1 << 3)
        public static let limits = Changes(rawValue: 1 << 4)
        public static let handoff = Changes(rawValue: 1 << 5)
    }

    public func changes(from old: Preferences) -> Changes {
        var changes: Changes = []
        if historyRetention != old.historyRetention { changes.insert(.historyRetention) }
        if historySync != old.historySync { changes.insert(.historySync) }
        if blocksContent != old.blocksContent || filterLists != old.filterLists { changes.insert(.contentBlocking) }
        if iCloudSync != old.iCloudSync { changes.insert(.iCloudSync) }
        if limits != old.limits { changes.insert(.limits) }
        if handoff != old.handoff { changes.insert(.handoff) }
        return changes
    }
}
