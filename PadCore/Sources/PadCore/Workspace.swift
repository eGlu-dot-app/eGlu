import Foundation

/// One tab as it is kept between launches: where it was and what it was
/// called. The page itself lives in the app (Pages.swift), live or frozen.
public struct TabRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL?
    public var title: String
    /// When it was last on screen: the freezer keeps the most recent ones.
    public var shown: Date
    /// For a pinned tab, the address it was pinned with, which closing it
    /// takes it back to; nil for every other tab.
    public var pinned: URL?
    /// For a pinned tab that came from iCloud or joined one there, the id
    /// the other devices know it by; nil otherwise, when its own id is
    /// that id (SyncPlan).
    public var cloudID: UUID?
    /// For a tab opened from its space's bookmarks bar, that bookmark's id:
    /// it stands in the bar's row under the pinned tiles, not among the
    /// space's tabs, while the bookmark is in the bar (Space.barTabs), and
    /// closing it takes it away, the bookmark staying. Nil for every other tab.
    public var bookmark: UUID?

    public init(id: UUID = UUID(), url: URL?, title: String = "", shown: Date = .distantPast, pinned: URL? = nil,
                bookmark: UUID? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.shown = shown
        self.pinned = pinned
        self.bookmark = bookmark
    }

    public var isPinned: Bool {
        pinned != nil
    }

    /// A pinned tab gone on from the address it was pinned with: going back
    /// to it, or pinning it where it is now, would change something.
    public var isAwayFromPinned: Bool {
        guard let pinned, let url else { return false }
        return url != pinned
    }

    /// The address it was pinned with, as its menus name it: without the
    /// scheme, "www." or a closing slash ("week.example/week").
    public var pinnedAddress: String? {
        guard let pinned, let host = pinned.host() else { return pinned?.absoluteString }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = pinned.path()
        if path.hasSuffix("/") { path.removeLast() }
        return site + path
    }

    /// The name a row shows: the page's title, else its address, else
    /// "New Tab" for a tab that has gone nowhere yet.
    public var label: String {
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        return url.map(Address.pretty) ?? BrowserText.localized("New Tab")
    }
}

/// The colour a space wears: its button is filled with it, so a window
/// says which space it is in at a glance (Design.swift has the shades).
public enum SpaceColor: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, gray

    /// The colour a space gets when none was chosen: one for each of the
    /// symbols spaces are given in turn, so spaces made one after another
    /// differ in colour as they do in symbol.
    public static func standard(for symbol: String) -> SpaceColor {
        let index = Workspace.symbols.firstIndex(of: symbol) ?? 0
        return allCases[index % allCases.count]
    }
}

/// Two tabs side by side in one window, as in Dia: `left` on the left.
/// The space's selected tab is the pane with the keys; the other stays on
/// screen beside it. A split's tabs sit next to each other in the row, left
/// first, so the row shows them as one tab (Workspace keeps them so).
public struct Split: Codable, Equatable, Sendable {
    public var left: UUID
    public var right: UUID
    /// The left pane's share of the window's width.
    public var ratio: Double

    /// As far as the divider goes either way: each pane keeps a quarter.
    public static let ratios: ClosedRange<Double> = 0.25...0.75

    public init(left: UUID, right: UUID, ratio: Double = 0.5) {
        self.left = left
        self.right = right
        self.ratio = min(max(ratio, Split.ratios.lowerBound), Split.ratios.upperBound)
    }

    public func contains(_ tab: UUID) -> Bool {
        left == tab || right == tab
    }

    /// The other pane's tab, or nil for a tab not in this split.
    public func partner(of tab: UUID) -> UUID? {
        tab == left ? right : tab == right ? left : nil
    }
}

/// A set of tabs with sign-ins of its own: each space's pages use a WebKit
/// store made for it (WKWebsiteDataStore(forIdentifier:) with the space's
/// id), so a client's Figma and your own can both stay signed in.
public struct Space: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// An SF Symbol's name.
    public var symbol: String
    public var color: SpaceColor
    /// Pinned tabs first, then the others (Workspace keeps them so).
    public var tabs: [TabRecord]
    public var selected: UUID?
    /// This space's own bookmarks, for the grid a new tab shows.
    public var bookmarks: [Bookmark]
    /// Tabs shown two at a time; a tab is in one split at most, and never a
    /// pinned one.
    public var splits: [Split]
    /// The id iCloud knows this space by, the same on every device; nil for
    /// a space that has never been synced (CloudSync.swift). Not `id`: that
    /// one names this device's sign-ins for the space.
    public var cloudID: UUID?

    public init(id: UUID = UUID(), name: String, symbol: String, color: SpaceColor? = nil, tabs: [TabRecord] = [],
                selected: UUID? = nil, bookmarks: [Bookmark] = [], splits: [Split] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color ?? SpaceColor.standard(for: symbol)
        self.tabs = tabs
        self.selected = selected
        self.bookmarks = bookmarks
        self.splits = splits
    }

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, color, tabs, selected, bookmarks, splits, cloudID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        tabs = try c.decode([TabRecord].self, forKey: .tabs)
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
        // Spaces got colours and bookmarks later: a file from before has
        // neither, and must still read.
        color = (try? c.decodeIfPresent(SpaceColor.self, forKey: .color)) ?? SpaceColor.standard(for: symbol)
        bookmarks = (try? c.decodeIfPresent([Bookmark].self, forKey: .bookmarks)) ?? []
        splits = (try? c.decodeIfPresent([Split].self, forKey: .splits)) ?? []
        cloudID = try? c.decodeIfPresent(UUID.self, forKey: .cloudID)
    }

    /// The split `tab` is in, if any.
    public func split(containing tab: UUID) -> Split? {
        splits.first { $0.contains(tab) }
    }

    /// How many tabs at the front of the row are pinned.
    public var pinnedCount: Int {
        tabs.prefix { $0.isPinned }.count
    }

    // MARK: The bookmarks bar

    /// Its bookmarks bar, the folder whose bookmarks stand under its pinned
    /// tiles (Bookmarks.bar); nil until it has one.
    public var bar: Bookmark? {
        Bookmarks.bar(in: bookmarks)
    }

    /// Its tabs open from the bar, by their bookmark: only those whose
    /// bookmark is in the bar still, the first for each. A tab whose
    /// bookmark has left the bar, here or on another device, is one of the
    /// others again.
    public var barTabs: [UUID: TabRecord] {
        Self.barTabs(of: tabs, inBar: Bookmarks.barIDs(in: bookmarks))
    }

    private static func barTabs(of tabs: [TabRecord], inBar: Set<UUID>) -> [UUID: TabRecord] {
        var found: [UUID: TabRecord] = [:]
        for tab in tabs where !tab.isPinned {
            guard let bookmark = tab.bookmark, inBar.contains(bookmark), found[bookmark] == nil else { continue }
            found[bookmark] = tab
        }
        return found
    }

    /// `barTabs` and the addresses of the bar's bookmarks, worked out once
    /// for a list that asks after each of its rows (the sidebar's bar rows,
    /// the bar's pane): `isInBar`, `home(of:)` and `isAwayFromHome` each
    /// walk the bar and every tab again, so a row that asked them for
    /// itself made a long bar slow. A value for one view update, never
    /// kept: the space's tabs and bookmarks change under it.
    public struct BarMap: Equatable, Sendable {
        /// Its tabs open from the bar, by their bookmark, as `barTabs`.
        public let tabs: [UUID: TabRecord]
        /// The address of each bookmark in the bar, by its id: where its
        /// tab goes back to.
        let homes: [UUID: URL]
    }

    public var barMap: BarMap {
        var inBar: Set<UUID> = []
        var homes: [UUID: URL] = [:]
        // Every id at any depth, as Bookmarks.barIDs has them, and each
        // one's address; for an id there twice, the first's, as
        // Bookmarks.find finds it.
        func walk(_ items: [Bookmark]) {
            for item in items {
                if inBar.insert(item.id).inserted, let url = item.url { homes[item.id] = url }
                walk(item.children ?? [])
            }
        }
        walk(bar?.children ?? [])
        return BarMap(tabs: Self.barTabs(of: tabs, inBar: inBar), homes: homes)
    }

    /// Whether `tab` stands in the bar's row rather than among the others.
    public func isInBar(_ tab: TabRecord) -> Bool {
        // Most tabs have no bookmark, and none of those is the bar's: no need to work the bar out for them.
        guard let bookmark = tab.bookmark else { return false }
        return barTabs[bookmark]?.id == tab.id
    }

    /// `isInBar`, from the space's `barMap` worked out already.
    public func isInBar(_ tab: TabRecord, in map: BarMap) -> Bool {
        guard let bookmark = tab.bookmark else { return false }
        return map.tabs[bookmark]?.id == tab.id
    }

    /// Its tabs as the list and the row show them, after the pinned tiles
    /// and the bar: neither pinned nor open from the bar.
    public var otherTabs: [TabRecord] {
        let inBar = Set(barTabs.values.map(\.id))
        return tabs.filter { !$0.isPinned && !inBar.contains($0.id) }
    }

    /// Where `tab` goes back to: a pinned tab's pinned address, a bar tab's
    /// bookmark's; nil for any other tab.
    public func home(of tab: TabRecord) -> URL? {
        if let pinned = tab.pinned { return pinned }
        guard isInBar(tab), let bookmark = tab.bookmark else { return nil }
        return Bookmarks.find(bookmark, in: bookmarks)?.url
    }

    /// `home(of:)`, from the space's `barMap` worked out already.
    public func home(of tab: TabRecord, in map: BarMap) -> URL? {
        if let pinned = tab.pinned { return pinned }
        guard isInBar(tab, in: map), let bookmark = tab.bookmark else { return nil }
        return map.homes[bookmark]
    }

    /// Tabs whose bookmark is gone from the space altogether let go of it
    /// for good, as iCloud's tree comes in (SyncPlan) and on loading
    /// (repair). One only out of the bar keeps it: iCloud can bring a
    /// bookmark before the folder it moved into, which puts it at the top
    /// until the folder comes, and the tab is the bar's again then. Until
    /// it is, `barTabs` leaves it among the others.
    public mutating func forgetGoneBookmarks() {
        for t in tabs.indices {
            guard let id = tabs[t].bookmark, Bookmarks.find(id, in: bookmarks) == nil else { continue }
            tabs[t].bookmark = nil
        }
    }

    /// A pinned or bar tab gone on from its home to another page: another
    /// site or another path. What a site adds as it loads, a query or a
    /// fragment (YouTube's ?themeRefresh=1), or https and www., is the same
    /// page still.
    public func isAwayFromHome(_ tab: TabRecord) -> Bool {
        Self.isAway(tab.url, from: home(of: tab))
    }

    /// `isAwayFromHome`, from the space's `barMap` worked out already.
    public func isAwayFromHome(_ tab: TabRecord, in map: BarMap) -> Bool {
        Self.isAway(tab.url, from: home(of: tab, in: map))
    }

    private static func isAway(_ url: URL?, from home: URL?) -> Bool {
        guard let home, let url else { return false }
        func page(_ url: URL) -> String {
            let host = url.host()?.lowercased() ?? ""
            var path = url.path()
            if path.hasSuffix("/") { path.removeLast() }
            return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
        }
        return page(url) != page(home)
    }
}

/// A tab that was closed, kept so it can be reopened where it was.
public struct ClosedTab: Codable, Equatable, Sendable {
    public var tab: TabRecord
    public var space: UUID
    public var index: Int
}

/// Every space and its tabs: what the app saves and reads back at launch.
public struct Workspace: Codable, Equatable, Sendable {
    public var spaces: [Space]
    public var closed: [ClosedTab]

    /// Closed tabs remembered, newest last.
    public static let closedKept = 25

    /// The symbols a space can wear, from Apple's SF Symbols. New ones go at
    /// the end: a space's standard colour follows its symbol's place here.
    public static let symbols = [
        "briefcase", "paintpalette", "building.2", "person.2", "sparkles", "lightbulb",
        "hammer", "book", "house", "heart", "leaf", "star",
        "folder", "doc.text", "pencil.and.ruler", "paintbrush", "camera", "film",
        "music.note", "gamecontroller", "cart", "creditcard", "chart.bar", "globe",
        "airplane", "graduationcap", "flame", "bolt", "cloud", "moon",
        "sun.max", "flag", "tag", "bell", "gift", "cup.and.saucer",
        "laptopcomputer", "wrench.and.screwdriver", "cube", "puzzlepiece", "mountain.2", "pawprint",
    ]

    /// A symbol's name as VoiceOver says it, in words, not as SF Symbols
    /// names it ("Office Buildings", not "building 2"): the iPad's and the
    /// Mac's icon pickers alike.
    public static func symbolName(_ symbol: String) -> String {
        let labels = [
            "briefcase": "Briefcase", "paintpalette": "Paint Palette", "building.2": "Office Buildings",
            "person.2": "People", "sparkles": "Sparkles", "lightbulb": "Light Bulb", "hammer": "Hammer",
            "book": "Book", "house": "House", "heart": "Heart", "leaf": "Leaf", "star": "Star",
            "folder": "Folder", "doc.text": "Document", "pencil.and.ruler": "Pencil and Ruler",
            "paintbrush": "Paintbrush", "camera": "Camera", "film": "Film", "music.note": "Music",
            "gamecontroller": "Game Controller", "cart": "Shopping Cart", "creditcard": "Payment Card",
            "chart.bar": "Bar Chart", "globe": "Globe", "airplane": "Airplane", "graduationcap": "Graduation Cap",
            "flame": "Flame", "bolt": "Lightning Bolt", "cloud": "Cloud", "moon": "Moon", "sun.max": "Sun",
            "flag": "Flag", "tag": "Tag", "bell": "Bell", "gift": "Gift", "cup.and.saucer": "Coffee Cup",
            "laptopcomputer": "Laptop", "wrench.and.screwdriver": "Tools", "cube": "Cube",
            "puzzlepiece": "Puzzle Piece", "mountain.2": "Mountains", "pawprint": "Paw Print"
        ]
        return BrowserText.localized(labels[symbol] ?? "Space Icon")
    }

    public init(spaces: [Space], closed: [ClosedTab] = []) {
        self.spaces = spaces
        self.closed = closed
    }

    /// The first launch: one space, on a new tab. What shows first is then the
    /// browser's own start page and its address field, not a site's sign-in
    /// page, which reads as the app asking for an account.
    public static func starting(now: Date = Date()) -> Workspace {
        let tab = TabRecord(url: nil, shown: now)
        return Workspace(spaces: [Space(name: BrowserText.localized("Work"), symbol: "briefcase", tabs: [tab], selected: tab.id)])
    }

    // MARK: Reading

    /// The first space. There is always one: `repair` makes one in an empty
    /// workspace, and `removeSpace` keeps the last.
    public var firstSpace: Space {
        precondition(!spaces.isEmpty, "A workspace keeps at least one space (repair, removeSpace)")
        return spaces[0]
    }

    public func space(_ id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    public func spaceID(of tab: UUID) -> UUID? {
        spaces.first { $0.tabs.contains { $0.id == tab } }?.id
    }

    public func tab(_ id: UUID) -> TabRecord? {
        for space in spaces {
            if let tab = space.tabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    /// The split `tab` is in, in whichever space.
    public func split(containing tab: UUID) -> Split? {
        for space in spaces {
            if let split = space.split(containing: tab) { return split }
        }
        return nil
    }

    /// The tab `offset` places along from `tab` in its space, going round.
    public func neighbour(of tab: UUID, by offset: Int) -> UUID? {
        guard let space = spaces.first(where: { $0.tabs.contains { $0.id == tab } }),
              let index = space.tabs.firstIndex(where: { $0.id == tab })
        else { return nil }
        let count = space.tabs.count
        return space.tabs[((index + offset) % count + count) % count].id
    }

    /// The tab `offset` places along from `tab` in its space's row, with no
    /// going round: nothing past either end. Where a sideways swipe on the
    /// phone's bar goes, which stops at the row's ends as Safari's does.
    public func tabBeside(_ tab: UUID, by offset: Int) -> TabRecord? {
        guard let space = spaces.first(where: { $0.tabs.contains { $0.id == tab } }),
              let index = space.tabs.firstIndex(where: { $0.id == tab }),
              space.tabs.indices.contains(index + offset)
        else { return nil }
        return space.tabs[index + offset]
    }

    /// The same, among the tabs `shown` keeps: a device's row leaves out
    /// the pinned tabs it hides (Preferences.shows), and going to the next
    /// tab goes past them as the row does.
    public func neighbour(of tab: UUID, by offset: Int, among shown: (TabRecord) -> Bool) -> UUID? {
        guard let space = spaces.first(where: { $0.tabs.contains { $0.id == tab } }) else { return nil }
        let tabs = space.tabs.filter { $0.id == tab || shown($0) }
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return nil }
        let count = tabs.count
        return tabs[((index + offset) % count + count) % count].id
    }

    /// The space `offset` places along from `space`, going round.
    public func spaceNeighbour(of space: UUID, by offset: Int) -> UUID? {
        guard let index = spaces.firstIndex(where: { $0.id == space }), !spaces.isEmpty else { return nil }
        let count = spaces.count
        return spaces[((index + offset) % count + count) % count].id
    }

    // MARK: Changing

    /// A new tab in `space`, right after `after` when that tab is in the same
    /// space, at the end otherwise; selected. Nil when there is no such space.
    /// `id`: the one a live page was made for already (a Peek's, a little
    /// window's), which becomes the tab's page as it is; nil when a tab has it.
    @discardableResult
    public mutating func openTab(_ url: URL?, in space: UUID, after: UUID? = nil, id: UUID = UUID(),
                                 now: Date = Date()) -> UUID? {
        guard let s = spaces.firstIndex(where: { $0.id == space }), self.tab(id) == nil else { return nil }
        let tab = TabRecord(id: id, url: url, shown: now)
        if let after, let index = spaces[s].tabs.firstIndex(where: { $0.id == after }) {
            // Opened from a pinned tab: first of the others, never among the pinned.
            spaces[s].tabs.insert(tab, at: max(index + 1, spaces[s].pinnedCount))
        } else {
            spaces[s].tabs.append(tab)
        }
        spaces[s].selected = tab.id
        tidySplits(s)
        return tab.id
    }

    public mutating func select(_ tab: UUID, now: Date = Date()) {
        for s in spaces.indices {
            guard let t = spaces[s].tabs.firstIndex(where: { $0.id == tab }) else { continue }
            spaces[s].selected = tab
            spaces[s].tabs[t].shown = now
            return
        }
    }

    /// Takes a tab away and remembers it for `reopen()`. When it was its
    /// space's selected tab, the one to its right is selected instead, or the
    /// one to its left when it was last, as browsers do. Returns the space's
    /// selection afterwards.
    ///
    /// A pinned tab stays: it goes back to the address it was pinned with,
    /// and only its page goes, which the app unloads, as Dia and Arc do.
    @discardableResult
    public mutating func closeTab(_ id: UUID) -> UUID? {
        for s in spaces.indices {
            guard let index = spaces[s].tabs.firstIndex(where: { $0.id == id }) else { continue }
            // Its split ends; the pane beside it is the one left on screen.
            let partner = spaces[s].split(containing: id)?.partner(of: id)
            spaces[s].splits.removeAll { $0.contains(id) }
            if let pinned = spaces[s].tabs[index].pinned {
                spaces[s].tabs[index].url = pinned
                spaces[s].tabs[index].title = ""
                let tabs = spaces[s].tabs
                if spaces[s].selected == id, tabs.count > 1 {
                    spaces[s].selected = tabs[index + 1 < tabs.count ? index + 1 : index - 1].id
                }
                return spaces[s].selected
            }
            // A tab open from the bookmarks bar goes as a pinned tab's page
            // does: the bookmark stays, and there is nothing to reopen.
            let fromBar = spaces[s].isInBar(spaces[s].tabs[index])
            let tab = spaces[s].tabs.remove(at: index)
            // A tab that never went anywhere has nothing to reopen.
            if tab.url != nil, !fromBar {
                closed.append(ClosedTab(tab: tab, space: spaces[s].id, index: index))
                if closed.count > Workspace.closedKept { closed.removeFirst(closed.count - Workspace.closedKept) }
            }
            if spaces[s].selected == id {
                let tabs = spaces[s].tabs
                spaces[s].selected = partner ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id)
            }
            return spaces[s].selected
        }
        return nil
    }

    /// How a space's tabs can be put in order, as Safari's Arrange Tabs By.
    public enum Arrangement: Sendable {
        case title
        case website
    }

    /// The space's tabs in order of their names or their sites. The pinned
    /// ones stay first as they were, and a split's two tabs stay together,
    /// in order of the left one. Tabs that tie keep their order.
    public mutating func arrangeTabs(in space: UUID, by arrangement: Arrangement) {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return }
        let pinned = spaces[s].tabs.filter(\.isPinned)
        let ordinary = spaces[s].tabs.filter { !$0.isPinned }
        var units: [[TabRecord]] = []
        var index = 0
        while index < ordinary.count {
            let tab = ordinary[index]
            if index + 1 < ordinary.count,
               spaces[s].splits.contains(where: { $0.left == tab.id && $0.right == ordinary[index + 1].id }) {
                units.append([tab, ordinary[index + 1]])
                index += 2
            } else {
                units.append([tab])
                index += 1
            }
        }
        func key(_ tab: TabRecord) -> String {
            switch arrangement {
            case .title:
                return tab.label
            case .website:
                let host = tab.url?.host()?.lowercased() ?? ""
                let site = Destination.registrable(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                // A tab gone nowhere yet goes last.
                return site.isEmpty ? "\u{10FFFF}" : site + " " + tab.label
            }
        }
        let sorted = units.enumerated().sorted { a, b in
            switch key(a.element[0]).localizedStandardCompare(key(b.element[0])) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }
        spaces[s].tabs = pinned + sorted.flatMap(\.element)
    }

    /// The last closed tab back where it was, selected; into the first space
    /// when its own is gone. Returns its id.
    public mutating func reopen(now: Date = Date()) -> UUID? {
        guard var last = closed.popLast() else { return nil }
        let s = spaces.firstIndex(where: { $0.id == last.space }) ?? 0
        guard spaces.indices.contains(s) else { return nil }
        last.tab.shown = now
        last.tab.pinned = nil
        last.tab.bookmark = nil
        let place = max(min(last.index, spaces[s].tabs.count), spaces[s].pinnedCount)
        spaces[s].tabs.insert(last.tab, at: place)
        spaces[s].selected = last.tab.id
        tidySplits(s)
        return last.tab.id
    }

    /// What a page said about itself: its address and title.
    public mutating func record(_ tab: UUID, url: URL?, title: String?) {
        for s in spaces.indices {
            guard let t = spaces[s].tabs.firstIndex(where: { $0.id == tab }) else { continue }
            if let url { spaces[s].tabs[t].url = url }
            if let title { spaces[s].tabs[t].title = title }
            return
        }
    }

    /// A new space at the end, with one empty tab. Returns its id.
    @discardableResult
    public mutating func addSpace(named name: String, symbol: String? = nil, now: Date = Date()) -> UUID {
        let tab = TabRecord(url: nil, shown: now)
        let used = Set(spaces.map(\.symbol))
        let symbol = symbol ?? Workspace.symbols.first { !used.contains($0) } ?? "square.grid.2x2"
        let colors = Set(spaces.map(\.color))
        let color = SpaceColor.allCases.first { !colors.contains($0) } ?? SpaceColor.standard(for: symbol)
        let space = Space(name: name, symbol: symbol, color: color, tabs: [tab], selected: tab.id)
        spaces.append(space)
        return space.id
    }

    /// Takes a space and its tabs away, never the last one. Its closed tabs
    /// are forgotten too: their sign-ins go with the space's store.
    public mutating func removeSpace(_ id: UUID) -> Bool {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return false }
        spaces.remove(at: index)
        closed.removeAll { $0.space == id }
        return true
    }

    public mutating func renameSpace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = trimmed
    }

    public mutating func setSymbol(_ id: UUID, to symbol: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].symbol = symbol
    }

    public mutating func setColor(_ id: UUID, to color: SpaceColor) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].color = color
    }

    /// Spaces to another place in the order they are listed and stepped
    /// through, as a list's drag gives it: the spaces at `offsets` go before
    /// the one at `destination`, as they were before the move.
    public mutating func moveSpaces(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.filter(spaces.indices.contains).map { spaces[$0] }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        var rest = spaces.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: max(0, min(destination - before, rest.count)))
        spaces = rest
    }

    /// A tab into another space, at its end and selected there. The page
    /// has to load again in that space's store; the app does that.
    @discardableResult
    public mutating func moveTab(_ id: UUID, to space: UUID) -> Bool {
        guard let from = spaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
              let to = spaces.firstIndex(where: { $0.id == space }), from != to,
              let index = spaces[from].tabs.firstIndex(where: { $0.id == id })
        else { return false }
        spaces[from].splits.removeAll { $0.contains(id) }
        var tab = spaces[from].tabs.remove(at: index)
        // A space's bookmarks are its own: in another, it is one of the others.
        tab.bookmark = nil
        if spaces[from].selected == id {
            let tabs = spaces[from].tabs
            spaces[from].selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        // A pinned tab stays pinned in its new space.
        if tab.isPinned {
            spaces[to].tabs.insert(tab, at: spaces[to].pinnedCount)
        } else {
            spaces[to].tabs.append(tab)
        }
        spaces[to].selected = tab.id
        return true
    }

    /// A tab to another place in its own space's row: among the pinned tabs
    /// when it is one, among the others when not. A split's two tabs go
    /// together.
    public mutating func moveTab(_ id: UUID, toIndex target: Int) {
        for s in spaces.indices {
            guard spaces[s].tabs.contains(where: { $0.id == id }) else { continue }
            let moving = spaces[s].split(containing: id).map { [$0.left, $0.right] } ?? [id]
            let tabs = moving.compactMap { m in spaces[s].tabs.first { $0.id == m } }
            spaces[s].tabs.removeAll { moving.contains($0.id) }
            let isPinned = tabs.first?.isPinned == true
            let pinned = spaces[s].pinnedCount
            let lowest = isPinned ? 0 : pinned
            let highest = isPinned ? pinned : spaces[s].tabs.count
            spaces[s].tabs.insert(contentsOf: tabs, at: max(lowest, min(target, highest)))
            tidySplits(s)
            return
        }
    }

    /// Where a tab dropped among its space's other tabs goes, as an index for
    /// moveTab(_:toIndex:): `slot` is how many of the others (each tab one
    /// card, the dropped tab not counted, the pinned ones never) end up
    /// before it. A split's other pane moves with it and is not counted
    /// either, so dropping a pane anywhere inside its own pair changes
    /// nothing. Nil where the drop leaves the order as it was.
    public func dropIndex(of id: UUID, at slot: Int) -> Int? {
        guard let space = spaces.first(where: { $0.tabs.contains { $0.id == id } }) else { return nil }
        let moving = space.split(containing: id).map { [$0.left, $0.right] } ?? [id]
        let ordinary = space.tabs.filter { !$0.isPinned }.map(\.id)
        let staying = ordinary.filter { !moving.contains($0) }
        let before = ordinary.filter { $0 != id }.prefix(max(0, slot)).filter { !moving.contains($0) }.count
        let order = staying.prefix(before) + moving.filter(ordinary.contains) + staying.dropFirst(before)
        return Array(order) == ordinary ? nil : space.pinnedCount + before
    }

    // MARK: Pinned tabs

    /// Pins a tab at the address it is on: it goes to the end of the pinned
    /// tabs at the front of its row, and from now on closing it takes it
    /// back there instead of away. A tab that has been nowhere yet has no
    /// address to pin.
    @discardableResult
    public mutating func pin(_ id: UUID) -> Bool {
        for s in spaces.indices {
            guard let index = spaces[s].tabs.firstIndex(where: { $0.id == id }) else { continue }
            guard !spaces[s].tabs[index].isPinned, let url = spaces[s].tabs[index].url else { return false }
            spaces[s].splits.removeAll { $0.contains(id) }
            var tab = spaces[s].tabs.remove(at: index)
            tab.pinned = url
            // From the bar, it leaves the bar's row for the tiles; its bookmark stays.
            tab.bookmark = nil
            spaces[s].tabs.insert(tab, at: spaces[s].pinnedCount)
            return true
        }
        return false
    }

    /// A space's pinned tabs in another order, as a list of them alone is
    /// reordered (Settings › Pinned Tabs): `offsets` and `destination` are
    /// places among the pinned tabs, which stay at the front of the row.
    public mutating func movePinned(in space: UUID, from offsets: IndexSet, to destination: Int) {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return }
        let count = spaces[s].pinnedCount
        var pinned = Array(spaces[s].tabs.prefix(count))
        let moving = offsets.filter { pinned.indices.contains($0) }.map { pinned[$0] }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        pinned.removeAll { tab in moving.contains { $0.id == tab.id } }
        pinned.insert(contentsOf: moving, at: min(max(destination - before, 0), pinned.count))
        spaces[s].tabs.replaceSubrange(0..<count, with: pinned)
    }

    /// A pinned tab back to being an ordinary one, first after the pinned.
    @discardableResult
    public mutating func unpin(_ id: UUID) -> Bool {
        for s in spaces.indices {
            guard let index = spaces[s].tabs.firstIndex(where: { $0.id == id }) else { continue }
            guard spaces[s].tabs[index].isPinned else { return false }
            var tab = spaces[s].tabs.remove(at: index)
            tab.pinned = nil
            spaces[s].tabs.insert(tab, at: spaces[s].pinnedCount)
            return true
        }
        return false
    }

    /// A pinned tab pinned anew at the address it is on: closing it, or
    /// going back, takes it there from now on. False for a tab not pinned,
    /// or already there.
    @discardableResult
    public mutating func repin(_ id: UUID) -> Bool {
        for s in spaces.indices {
            guard let index = spaces[s].tabs.firstIndex(where: { $0.id == id }) else { continue }
            let tab = spaces[s].tabs[index]
            guard tab.isPinned, let url = tab.url, url != tab.pinned else { return false }
            spaces[s].tabs[index].pinned = url
            return true
        }
        return false
    }

    /// A pinned tab's page at the address it was pinned with, a bar tab's
    /// at its bookmark's (Space.home); returns it.
    public mutating func backToPinned(_ id: UUID) -> URL? {
        for s in spaces.indices {
            guard let index = spaces[s].tabs.firstIndex(where: { $0.id == id }) else { continue }
            guard let home = spaces[s].home(of: spaces[s].tabs[index]) else { return nil }
            // The page gone from names itself no more, as closing a pinned tab leaves it.
            if spaces[s].tabs[index].url != home { spaces[s].tabs[index].title = "" }
            spaces[s].tabs[index].url = home
            return home
        }
        return nil
    }

    // MARK: Splits

    /// Shows `other` beside `tab`, on its right, as one tab of the row: the
    /// two must be ordinary tabs of one space. A split either was in ends.
    @discardableResult
    public mutating func split(_ tab: UUID, with other: UUID) -> Bool {
        guard tab != other, let s = spaces.firstIndex(where: { $0.tabs.contains { $0.id == tab } }),
              let left = spaces[s].tabs.first(where: { $0.id == tab }), !left.isPinned, !spaces[s].isInBar(left),
              let right = spaces[s].tabs.first(where: { $0.id == other }), !right.isPinned, !spaces[s].isInBar(right)
        else { return false }
        spaces[s].splits.removeAll { $0.contains(tab) || $0.contains(other) }
        spaces[s].splits.append(Split(left: tab, right: other))
        tidySplits(s)
        return true
    }

    /// A new tab beside `tab`, on its right, selected so it is the one typed
    /// into. Returns its id; nil for a pinned tab, a bar tab, or none.
    @discardableResult
    public mutating func splitWithNewTab(_ tab: UUID, url: URL? = nil, now: Date = Date()) -> UUID? {
        guard let space = spaceID(of: tab), self.space(space)?.otherTabs.contains(where: { $0.id == tab }) == true,
              let new = openTab(url, in: space, after: tab, now: now), split(tab, with: new)
        else { return nil }
        select(new, now: now)
        return new
    }

    /// The split `tab` is in ends; both tabs stay where they are.
    public mutating func separate(_ tab: UUID) {
        for s in spaces.indices { spaces[s].splits.removeAll { $0.contains(tab) } }
    }

    /// The two panes change sides.
    public mutating func swapSides(_ tab: UUID) {
        for s in spaces.indices {
            guard let i = spaces[s].splits.firstIndex(where: { $0.contains(tab) }) else { continue }
            let split = spaces[s].splits[i]
            spaces[s].splits[i] = Split(left: split.right, right: split.left, ratio: 1 - split.ratio)
            tidySplits(s)
            return
        }
    }

    /// Where the divider of `tab`'s split is: the left pane's share.
    public mutating func setSplitRatio(_ tab: UUID, to ratio: Double) {
        for s in spaces.indices {
            guard let i = spaces[s].splits.firstIndex(where: { $0.contains(tab) }) else { continue }
            let split = spaces[s].splits[i]
            spaces[s].splits[i] = Split(left: split.left, right: split.right, ratio: ratio)
            return
        }
    }

    /// Keeps a space's splits as they must be: two ordinary tabs of its own
    /// each, no tab in two, and each split's tabs side by side in the row,
    /// left first, so the row shows them as one.
    mutating func tidySplits(_ s: Int) {
        let ordinary = Set(spaces[s].otherTabs.map(\.id))
        var seen: Set<UUID> = []
        spaces[s].splits = spaces[s].splits.filter { split in
            guard split.left != split.right, ordinary.contains(split.left), ordinary.contains(split.right),
                  !seen.contains(split.left), !seen.contains(split.right)
            else { return false }
            seen.formUnion([split.left, split.right])
            return true
        }
        for split in spaces[s].splits {
            guard let r = spaces[s].tabs.firstIndex(where: { $0.id == split.right }) else { continue }
            let right = spaces[s].tabs.remove(at: r)
            let l = spaces[s].tabs.firstIndex { $0.id == split.left }
            spaces[s].tabs.insert(right, at: l.map { $0 + 1 } ?? r)
        }
    }

    // MARK: Bookmarks, each space its own

    /// This space's bookmark for `url`, at any depth.
    public func bookmark(for url: URL, in space: UUID) -> Bookmark? {
        self.space(space).flatMap { Bookmarks.find(url, in: $0.bookmarks) }
    }

    /// A bookmark at the end of the space's top level, unless the space has
    /// one for the address already. Returns the bookmark's id.
    @discardableResult
    public mutating func addBookmark(_ url: URL, title: String, in space: UUID) -> UUID? {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return nil }
        if let known = Bookmarks.find(url, in: spaces[s].bookmarks) { return known.id }
        let bookmark = Bookmark(title: title, url: url)
        spaces[s].bookmarks.append(bookmark)
        return bookmark.id
    }

    /// Takes a bookmark or a folder away, at any depth. Asked of the
    /// bookmarks bar itself, it does nothing: the bar is where the bar's
    /// bookmarks go, and only what is in it is ever deleted, as Chromium's.
    public mutating func removeBookmark(_ id: UUID, in space: UUID) {
        guard let s = spaces.firstIndex(where: { $0.id == space }), spaces[s].bar?.id != id else { return }
        Bookmarks.remove(id, from: &spaces[s].bookmarks)
        spaces[s].forgetGoneBookmarks()
    }

    /// A bookmark at the end of `folder` (nil: the top level), or before
    /// `before` in it, as the bookmark manager adds one. Unlike
    /// addBookmark(_:title:in:) the address may be bookmarked elsewhere in
    /// the space already, as Chromium allows. Returns its id; nil when the
    /// space or the folder is not there.
    @discardableResult
    public mutating func addBookmark(_ url: URL, title: String, into folder: UUID?, before: UUID? = nil,
                                     in space: UUID) -> UUID? {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return nil }
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(title: named.isEmpty ? Address.pretty(url) : named, url: url)
        return Bookmarks.insert(bookmark, into: folder, before: before, of: &spaces[s].bookmarks) ? bookmark.id : nil
    }

    /// A link's address changed in place; a folder has none. A tab open from
    /// the bar for it stays where it is, and goes back to the new address.
    public mutating func changeBookmarkAddress(_ id: UUID, to url: URL, in space: UUID) {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return }
        Bookmarks.update(id, in: &spaces[s].bookmarks) { item in
            if !item.isFolder { item.url = url }
        }
    }

    /// The space's bookmarks bar, made at the top of its bookmarks when it
    /// has none yet. Nil for no such space.
    @discardableResult
    public mutating func makeBar(in space: UUID) -> UUID? {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return nil }
        if let bar = spaces[s].bar { return bar.id }
        let made = Bookmark(folder: Bookmarks.barName, children: [])
        spaces[s].bookmarks.insert(made, at: 0)
        return made.id
    }

    /// A new folder at the end of `parent` (nil: the top level), named as
    /// given, or "New Folder". Returns its id; nil when the space or the
    /// parent is not there.
    @discardableResult
    public mutating func addFolder(named name: String, in parent: UUID?, of space: UUID) -> UUID? {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Bookmark(folder: trimmed.isEmpty ? BrowserText.localized("New Folder") : trimmed, children: [])
        return Bookmarks.insert(folder, into: parent, of: &spaces[s].bookmarks) ? folder.id : nil
    }

    /// A bookmark's or a folder's name; an empty name leaves it as it was,
    /// and the bookmarks bar keeps its own, which is how it is known.
    public mutating func renameBookmark(_ id: UUID, to name: String, in space: UUID) {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, spaces[s].bar?.id != id else { return }
        Bookmarks.update(id, in: &spaces[s].bookmarks) { $0.title = trimmed }
        // A folder named as the bar where there was none is the bar, and its open tabs leave their splits.
        tidySplits(s)
    }

    /// Moves a bookmark or a folder to the end of `folder` (nil: the top
    /// level), or before `before` in it. A folder never goes into itself or
    /// into one of its own, and the bookmarks bar stays at the top.
    public mutating func moveBookmark(_ id: UUID, into folder: UUID?, before: UUID? = nil, in space: UUID) {
        guard let s = spaces.firstIndex(where: { $0.id == space }), before != id,
              let item = Bookmarks.find(id, in: spaces[s].bookmarks) else { return }
        if spaces[s].bar?.id == id, folder != nil { return }
        if let folder {
            guard folder != id, Bookmarks.find(folder, in: item.children ?? []) == nil,
                  Bookmarks.find(folder, in: spaces[s].bookmarks)?.isFolder == true else { return }
        }
        var items = spaces[s].bookmarks
        Bookmarks.remove(id, from: &items)
        guard Bookmarks.insert(item, into: folder, before: before, of: &items) else { return }
        spaces[s].bookmarks = items
        // What was moved out of the bar here leaves its tabs among the others; nothing else does.
        let moved = Set(Self.everything(item).map(\.id))
        let inBar = Bookmarks.barIDs(in: items)
        for t in spaces[s].tabs.indices {
            guard let mark = spaces[s].tabs[t].bookmark, moved.contains(mark), !inBar.contains(mark) else { continue }
            spaces[s].tabs[t].bookmark = nil
        }
        // What was moved into the bar takes its open tabs out of their splits.
        tidySplits(s)
    }

    /// A bookmark or folder and everything in it, at any depth.
    private static func everything(_ item: Bookmark) -> [Bookmark] {
        [item] + (item.children ?? []).flatMap(everything)
    }

    // MARK: The bookmarks bar

    /// The bar's bookmark `id` in a tab of its own, selected: the one open
    /// for it already, or a new one at its address just after the pinned
    /// tabs. Returns the tab; nil for a folder, or for none in the space's bar.
    @discardableResult
    public mutating func openFromBar(_ id: UUID, in space: UUID, now: Date = Date()) -> UUID? {
        guard let s = spaces.firstIndex(where: { $0.id == space }),
              Bookmarks.barIDs(in: spaces[s].bookmarks).contains(id),
              let url = Bookmarks.find(id, in: spaces[s].bookmarks)?.url else { return nil }
        if let open = spaces[s].barTabs[id] {
            select(open.id, now: now)
            return open.id
        }
        let tab = TabRecord(url: url, shown: now, bookmark: id)
        spaces[s].tabs.insert(tab, at: spaces[s].pinnedCount)
        spaces[s].selected = tab.id
        tidySplits(s)
        return tab.id
    }

    /// A tab into its space's bookmarks bar, made at the top of its
    /// bookmarks if there is none yet: a bookmark for where it is, at the
    /// end of `folder` (nil: the bar itself) or before `before` there, and
    /// the tab in the bar's row from now on, out of its split. A pinned
    /// tab leaves the tiles for it. Returns the bookmark; nil for a tab gone
    /// nowhere yet, a folder not in the bar, or no such tab.
    @discardableResult
    public mutating func addToBar(_ tab: UUID, into folder: UUID? = nil, before: UUID? = nil) -> UUID? {
        guard let s = spaces.firstIndex(where: { $0.tabs.contains { $0.id == tab } }),
              let index = spaces[s].tabs.firstIndex(where: { $0.id == tab }),
              let url = spaces[s].tabs[index].url else { return nil }
        guard let bar = makeBar(in: spaces[s].id) else { return nil }
        if let folder, folder != bar, !Bookmarks.barIDs(in: spaces[s].bookmarks).contains(folder) { return nil }
        let record = spaces[s].tabs[index]
        let bookmark: UUID
        if spaces[s].isInBar(record), let own = record.bookmark {
            // Already in the bar: only its place there changes.
            moveBookmark(own, into: folder ?? bar, before: before, in: spaces[s].id)
            return own
        } else {
            let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let made = Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url)
            guard Bookmarks.insert(made, into: folder ?? bar, before: before, of: &spaces[s].bookmarks) else { return nil }
            bookmark = made.id
        }
        spaces[s].splits.removeAll { $0.contains(tab) }
        var moved = spaces[s].tabs.remove(at: index)
        moved.pinned = nil
        moved.bookmark = bookmark
        spaces[s].tabs.insert(moved, at: spaces[s].pinnedCount)
        tidySplits(s)
        return bookmark
    }

    /// A bar tab out of the bar's row, one of the others from now on, its
    /// bookmark staying in the bar, as Arc separates a page from its pinned
    /// tab. False for a tab not open from the bar.
    @discardableResult
    public mutating func separateFromBar(_ tab: UUID) -> Bool {
        for s in spaces.indices {
            guard let index = spaces[s].tabs.firstIndex(where: { $0.id == tab }) else { continue }
            guard spaces[s].isInBar(spaces[s].tabs[index]) else { return false }
            spaces[s].tabs[index].bookmark = nil
            return true
        }
        return false
    }

    /// Revalidates destination identity after file reading. A missing space
    /// retains the parsed content for an explicit choice of another destination.
    @discardableResult
    public mutating func importBookmarks(_ bookmarks: BookmarkImport, into space: UUID) -> BookmarkImportOutcome {
        guard let s = spaces.firstIndex(where: { $0.id == space }) else { return .destinationMissing(bookmarks) }
        guard bookmarks.count > 0 else { return .empty }
        let before = Self.folderCount(spaces[s].bookmarks)
        let added = Bookmarks.merge(bookmarks.items, into: &spaces[s].bookmarks, keepingEmpty: bookmarks.keepsEmptyFolders)
        // Folders it brought with no new links in them (eGlu's own export
        // keeps its empty ones) change the space too: no duplicate, that.
        let folders = Self.folderCount(spaces[s].bookmarks) - before
        let name = spaces[s].name
        return added > 0 || folders > 0 ? .imported(added: added, total: bookmarks.count, space: name, folders: folders)
            : .duplicates(total: bookmarks.count, space: name)
    }

    private static func folderCount(_ items: [Bookmark]) -> Int {
        items.reduce(0) { $0 + ($1.isFolder ? 1 + folderCount($1.children ?? []) : 0) }
    }

    /// Puts right what a damaged or hand-edited file got wrong: no spaces, a
    /// selection that isn't one of the space's tabs.
    public mutating func repair(now: Date = Date()) {
        if spaces.isEmpty { self = Workspace.starting(now: now) }
        for s in spaces.indices {
            // Pinned tabs at the front, the others after, each in its order.
            spaces[s].tabs = spaces[s].tabs.filter(\.isPinned) + spaces[s].tabs.filter { !$0.isPinned }
            spaces[s].forgetGoneBookmarks()
            let ids = Set(spaces[s].tabs.map(\.id))
            if let selected = spaces[s].selected, !ids.contains(selected) { spaces[s].selected = nil }
            if spaces[s].selected == nil { spaces[s].selected = spaces[s].tabs.first?.id }
            tidySplits(s)
        }
    }
}

/// The workspace on disk. A failed read must never be treated as first launch.
public enum WorkspaceFile {
    public enum Failure: Error, Equatable, Sendable {
        case unreadable
        case invalid
        case unsupportedVersion(Int)
    }

    public enum LoadResult: Equatable, Sendable {
        case missing
        case loaded(Workspace)
        case failed(Failure)
    }

    private struct Header: Decodable { var schemaVersion: Int? }
    private static let schemaVersion = 1

    public static func backup(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("workspace.last-good.json")
    }

    public static func load(_ file: URL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError {
                return .missing
            }
            return .failed(.unreadable)
        }
        return decode(data)
    }

    private static func decode(_ data: Data) -> LoadResult {
        let decoder = JSONDecoder()
        do {
            let header = try decoder.decode(Header.self, from: data)
            if let version = header.schemaVersion, version != schemaVersion {
                return .failed(.unsupportedVersion(version))
            }
            var workspace = try decoder.decode(Workspace.self, from: data)
            // Repair selection/order, but never invent a new space identity for damaged data.
            guard !workspace.spaces.isEmpty else { return .failed(.invalid) }
            workspace.repair()
            return .loaded(workspace)
        } catch {
            return .failed(.invalid)
        }
    }

    /// Compatibility for callers that only need a successfully loaded value.
    public static func read(_ file: URL) -> Workspace? {
        guard case .loaded(let workspace) = load(file) else { return nil }
        return workspace
    }

    public static func exportData(_ workspace: Workspace) throws -> Data {
        guard !workspace.spaces.isEmpty else { throw Failure.invalid }
        let encoded = try JSONEncoder().encode(workspace)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw Failure.invalid }
        object["schemaVersion"] = schemaVersion
        return try JSONSerialization.data(withJSONObject: object)
    }

    public static func write(_ workspace: Workspace, to file: URL) throws {
        let data = try exportData(workspace)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous: Data
        do {
            previous = try Data(contentsOf: file)
        } catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError else { throw error }
            // The first save also establishes a recovery copy before browsing starts.
            try data.write(to: backup(for: file), options: .atomic)
            try data.write(to: file, options: .atomic)
            return
        }
        switch decode(previous) {
        case .loaded:
            try previous.write(to: backup(for: file), options: .atomic)
        case .failed(let failure):
            throw failure
        case .missing:
            throw Failure.unreadable
        }
        try data.write(to: file, options: .atomic)
    }

    /// Explicit recovery preserves the rejected source before replacing it.
    /// Invalid backups never replace either the source or its recovery copy.
    @discardableResult
    public static func restore(from candidate: URL, to file: URL, preserving retainedFiles: [URL] = []) throws -> Workspace {
        let data = try Data(contentsOf: candidate)
        guard case .loaded(let workspace) = decode(data) else { throw Failure.invalid }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originals = ([file] + retainedFiles).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !originals.isEmpty {
            let preserved = folder.appendingPathComponent("workspace-recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
            for original in originals {
                try FileManager.default.copyItem(at: original, to: preserved.appendingPathComponent(original.lastPathComponent))
            }
        }
        try data.write(to: file, options: .atomic)
        return workspace
    }
}
