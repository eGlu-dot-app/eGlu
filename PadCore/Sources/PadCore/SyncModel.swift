import Foundation

// What iCloud holds of the workspace, and how the two turn into each other.
//
// Records live in the user's private CloudKit database, in one zone
// (SyncZone.name): a record per space, per bookmark and folder, per pinned
// tab, and one per device and space for that device's open tabs; and, from
// the Mac, one per Chrome extension and one per extension and space it is
// on in. The iPhone,
// iPad and Mac apps write them through CKSyncEngine (Sync.swift). A Chrome
// extension once wrote the same record types through CloudKit Web Services;
// records it left are read as any device's.
//
// Nothing here knows CloudKit: records are plain values (SyncRecord), so the
// rules can be tested apart from it.

public enum SyncZone {
    public static let name = "Sync"
}

public enum SyncKind: String, CaseIterable, Codable, Sendable {
    case space = "Space"
    case bookmark = "BookmarkNode"
    case pinned = "PinnedTab"
    case deviceTabs = "DeviceTabs"
    case extensionItem = "Extension"
    case extensionUse = "ExtensionUse"

    /// Every field a record of this kind has. A save sets each, or clears
    /// it, so a field left out of the record (a folder's address) is none.
    public var fields: [String] {
        switch self {
        case .space: return ["name", "symbol", "color"]
        case .bookmark: return ["space", "parent", "position", "title", "url"]
        case .pinned: return ["space", "position", "title", "url"]
        case .deviceTabs: return ["device", "deviceName", "browser", "space", "updated", "tabs"]
        case .extensionItem: return ["storeID", "title", "siteAccess"]
        case .extensionUse: return ["extension", "space"]
        }
    }

    /// Fields a device sets as it finds them, not as someone edits them: a
    /// pinned tab's title is its page's, and a position is worked out again
    /// whenever anything beside it moves. Their changes don't make a deleted
    /// record, or a removed space, come back (SyncPlan.stamp, settleSpaces).
    public var foundFields: Set<String> {
        switch self {
        case .pinned: return ["title", "position"]
        case .bookmark: return ["position"]
        default: return []
        }
    }

    /// Whether its fields go in CloudKit's encrypted values, which Advanced
    /// Data Protection encrypts end to end: the extensions someone uses can
    /// tell of a password manager, accessibility tools, their beliefs. The
    /// others stay plain for the desktop extension to read
    /// (Docs/SyncDesign.md); it never needs these.
    public var isEncrypted: Bool {
        self == .extensionItem || self == .extensionUse
    }
}

/// A field's value as CloudKit keeps it: text, a number, or a time.
public enum SyncField: Codable, Equatable, Sendable {
    case string(String)
    case double(Double)
    case date(Date)

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    public var date: Date? {
        if case .date(let value) = self { return value }
        return nil
    }
}

/// A record, CloudKit aside: its type, its name in the zone, its fields,
/// and when each was last set (SyncCRDT.swift). A field left out is one
/// with no value.
public struct SyncRecord: Codable, Equatable, Sendable {
    public var kind: SyncKind
    public var name: String
    public var fields: [String: SyncField]
    public var stamps: SyncStamps

    public init(kind: SyncKind, name: String, fields: [String: SyncField], stamps: SyncStamps = SyncStamps()) {
        self.kind = kind
        self.name = name
        self.fields = fields
        self.stamps = stamps
    }

    /// The field CloudKit keeps the stamps in, beside the kind's own (SyncKind.fields).
    public static let stampsField = "stamps"
}

// MARK: The records

/// A space's name, icon and colour. Its record name is the space's iCloud
/// id (Space.cloudID), the same on every device.
public struct SyncSpace: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var color: String

    public init(id: String, name: String, symbol: String, color: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
    }

    public var record: SyncRecord {
        SyncRecord(kind: .space, name: id, fields: ["name": .string(name), "symbol": .string(symbol), "color": .string(color)])
    }

    public init?(_ record: SyncRecord) {
        guard record.kind == .space, let name = record.fields["name"]?.string else { return nil }
        self.init(id: record.name, name: name, symbol: record.fields["symbol"]?.string ?? "square.grid.2x2",
                  color: record.fields["color"]?.string ?? SpaceColor.blue.rawValue)
    }
}

/// A bookmark, or a folder of them: which space, which folder, where among
/// its neighbours. Its record name is the bookmark's id.
public struct SyncBookmark: Codable, Equatable, Sendable {
    public var id: String
    public var space: String
    /// The folder it is in; nil at the space's top level.
    public var parent: String?
    /// Neighbours are ordered by position, then by record name.
    public var position: Double
    public var title: String
    /// Nil for a folder.
    public var url: String?

    public init(id: String, space: String, parent: String?, position: Double, title: String, url: String?) {
        self.id = id
        self.space = space
        self.parent = parent
        self.position = position
        self.title = title
        self.url = url
    }

    public var record: SyncRecord {
        var fields: [String: SyncField] = ["space": .string(space), "position": .double(position), "title": .string(title)]
        if let parent { fields["parent"] = .string(parent) }
        if let url { fields["url"] = .string(url) }
        return SyncRecord(kind: .bookmark, name: id, fields: fields)
    }

    public init?(_ record: SyncRecord) {
        guard record.kind == .bookmark, let space = record.fields["space"]?.string else { return nil }
        let parent = record.fields["parent"]?.string
        self.init(id: record.name, space: space, parent: parent?.isEmpty == true ? nil : parent,
                  position: record.fields["position"]?.double ?? 0, title: record.fields["title"]?.string ?? "",
                  url: record.fields["url"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// A pinned tab of a space: the address it was pinned with, and where it is
/// among the space's pinned tabs. Its record name is the tab's iCloud id
/// (TabRecord.cloudID, else its id).
public struct SyncPinned: Codable, Equatable, Sendable {
    public var id: String
    public var space: String
    public var position: Double
    public var title: String
    public var url: String

    public init(id: String, space: String, position: Double, title: String, url: String) {
        self.id = id
        self.space = space
        self.position = position
        self.title = title
        self.url = url
    }

    public var record: SyncRecord {
        SyncRecord(kind: .pinned, name: id, fields: [
            "space": .string(space), "position": .double(position), "title": .string(title), "url": .string(url),
        ])
    }

    public init?(_ record: SyncRecord) {
        guard record.kind == .pinned, let space = record.fields["space"]?.string,
              let url = record.fields["url"]?.string, !url.isEmpty
        else { return nil }
        self.init(id: record.name, space: space, position: record.fields["position"]?.double ?? 0,
                  title: record.fields["title"]?.string ?? "", url: url)
    }
}

/// One open tab of another device, as it shows in a list.
public struct SyncTab: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var pinned: Bool
    /// The tab group it is in, in a desktop browser.
    public var group: String?

    public init(url: String, title: String, pinned: Bool = false, group: String? = nil) {
        self.url = url
        self.title = title
        self.pinned = pinned
        self.group = group
    }

    enum CodingKeys: String, CodingKey {
        case url = "u", title = "t", pinned = "p", group = "g"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        group = try? c.decodeIfPresent(String.self, forKey: .group)
    }
}

/// A device's open tabs in one space: eGlu on an iPhone, an iPad or a
/// Mac. Only that device writes it.
public struct SyncDeviceTabs: Codable, Equatable, Sendable {
    public var id: String
    public var device: String
    /// "iPhone", "Mac", what the person called it.
    public var deviceName: String
    /// "eGlu", "Chrome", "Edge"...
    public var browser: String
    public var space: String
    public var updated: Date
    public var tabs: [SyncTab]

    public init(device: String, deviceName: String, browser: String, space: String, updated: Date, tabs: [SyncTab]) {
        id = Self.recordName(device: device, space: space)
        self.device = device
        self.deviceName = deviceName
        self.browser = browser
        self.space = space
        self.updated = updated
        self.tabs = tabs
    }

    public static func recordName(device: String, space: String) -> String {
        "tabs.\(device).\(space)"
    }

    /// Unseen for this long, a device's tabs are out of date and don't show.
    public static let stale: TimeInterval = 14 * 24 * 60 * 60

    public var record: SyncRecord {
        let list = (try? JSONEncoder().encode(tabs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return SyncRecord(kind: .deviceTabs, name: id, fields: [
            "device": .string(device), "deviceName": .string(deviceName), "browser": .string(browser),
            "space": .string(space), "updated": .date(updated), "tabs": .string(list),
        ])
    }

    public init?(_ record: SyncRecord) {
        guard record.kind == .deviceTabs, let device = record.fields["device"]?.string,
              let space = record.fields["space"]?.string
        else { return nil }
        let list = record.fields["tabs"]?.string.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([SyncTab].self, from: $0) } ?? []
        self.init(device: device, deviceName: record.fields["deviceName"]?.string ?? "",
                  browser: record.fields["browser"]?.string ?? "", space: space,
                  updated: record.fields["updated"]?.date ?? .distantPast, tabs: list)
        id = record.name
    }
}

/// A Chrome extension installed from the Chrome Web Store on a Mac, by its
/// store id: each Mac downloads it and checks Google's signature itself;
/// nothing of it is copied. Its record name is random, not the store id,
/// since record names stay readable to Apple. Its site access is where
/// another Mac's install sheet starts from, not an answer for that Mac.
public struct SyncExtension: Codable, Equatable, Sendable {
    public var id: String
    public var storeID: String
    public var title: String
    /// "allSites" or "onClick".
    public var siteAccess: String

    public init(id: String, storeID: String, title: String, siteAccess: String) {
        self.id = id
        self.storeID = storeID
        self.title = title
        self.siteAccess = siteAccess
    }

    public var record: SyncRecord {
        SyncRecord(kind: .extensionItem, name: id, fields: [
            "storeID": .string(storeID), "title": .string(title), "siteAccess": .string(siteAccess),
        ])
    }

    public init?(_ record: SyncRecord) {
        guard record.kind == .extensionItem, let storeID = record.fields["storeID"]?.string, !storeID.isEmpty else { return nil }
        self.init(id: record.name, storeID: storeID, title: record.fields["title"]?.string ?? storeID,
                  siteAccess: record.fields["siteAccess"]?.string ?? "allSites")
    }
}

/// An extension on in a space: its Extension record's name and the
/// space's iCloud id. Its record name is random too.
public struct SyncExtensionUse: Codable, Equatable, Sendable {
    public var id: String
    public var extensionRecord: String
    public var space: String

    public init(id: String, extensionRecord: String, space: String) {
        self.id = id
        self.extensionRecord = extensionRecord
        self.space = space
    }

    public var record: SyncRecord {
        SyncRecord(kind: .extensionUse, name: id, fields: ["extension": .string(extensionRecord), "space": .string(space)])
    }

    public init?(_ record: SyncRecord) {
        guard record.kind == .extensionUse, let item = record.fields["extension"]?.string,
              let space = record.fields["space"]?.string
        else { return nil }
        self.init(id: record.name, extensionRecord: item, space: space)
    }
}

// MARK: The mirror

/// Every synced record as this device knows it: what iCloud holds, plus
/// this device's changes on their way there. The workspace's synced spaces
/// are built from it, and it from them (SyncPlan).
public struct SyncMirror: Codable, Equatable, Sendable {
    public var spaces: [String: SyncSpace] = [:]
    public var bookmarks: [String: SyncBookmark] = [:]
    public var pinned: [String: SyncPinned] = [:]
    public var deviceTabs: [String: SyncDeviceTabs] = [:]
    public var extensions: [String: SyncExtension] = [:]
    public var extensionUses: [String: SyncExtensionUse] = [:]
    /// Every record's stamps, by name, shown or buried (SyncCRDT.swift).
    public var stamps: [String: SyncStamps] = [:]
    /// Records known but not shown: deleted ones, kept as tombstones until
    /// they expire, and any this build can't read.
    public var buried: [String: SyncRecord] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case spaces, bookmarks, pinned, deviceTabs, extensions, extensionUses, stamps, buried
    }

    /// A mirror kept before extensions synced reads as one with none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try c.decodeIfPresent([String: SyncSpace].self, forKey: .spaces) ?? [:]
        bookmarks = try c.decodeIfPresent([String: SyncBookmark].self, forKey: .bookmarks) ?? [:]
        pinned = try c.decodeIfPresent([String: SyncPinned].self, forKey: .pinned) ?? [:]
        deviceTabs = try c.decodeIfPresent([String: SyncDeviceTabs].self, forKey: .deviceTabs) ?? [:]
        extensions = try c.decodeIfPresent([String: SyncExtension].self, forKey: .extensions) ?? [:]
        extensionUses = try c.decodeIfPresent([String: SyncExtensionUse].self, forKey: .extensionUses) ?? [:]
        stamps = try c.decodeIfPresent([String: SyncStamps].self, forKey: .stamps) ?? [:]
        buried = try c.decodeIfPresent([String: SyncRecord].self, forKey: .buried) ?? [:]
    }

    public var isEmpty: Bool {
        spaces.isEmpty && bookmarks.isEmpty && pinned.isEmpty && deviceTabs.isEmpty && extensions.isEmpty && extensionUses.isEmpty
            && buried.isEmpty
    }

    /// A record from iCloud in place of what was here; false for one that
    /// can't be read, which is left out.
    @discardableResult
    public mutating func take(_ record: SyncRecord) -> Bool {
        switch record.kind {
        case .space:
            guard let space = SyncSpace(record) else { return false }
            spaces[record.name] = space
        case .bookmark:
            guard let bookmark = SyncBookmark(record) else { return false }
            bookmarks[record.name] = bookmark
        case .pinned:
            guard let pin = SyncPinned(record) else { return false }
            pinned[record.name] = pin
        case .deviceTabs:
            guard let tabs = SyncDeviceTabs(record) else { return false }
            deviceTabs[record.name] = tabs
        case .extensionItem:
            guard let item = SyncExtension(record) else { return false }
            extensions[record.name] = item
        case .extensionUse:
            guard let use = SyncExtensionUse(record) else { return false }
            extensionUses[record.name] = use
        }
        return true
    }

    /// A record deleted in iCloud, whatever its kind.
    public mutating func remove(_ name: String) {
        spaces[name] = nil
        bookmarks[name] = nil
        pinned[name] = nil
        deviceTabs[name] = nil
        extensions[name] = nil
        extensionUses[name] = nil
    }

    public func record(named name: String) -> SyncRecord? {
        spaces[name]?.record ?? bookmarks[name]?.record ?? pinned[name]?.record ?? deviceTabs[name]?.record
            ?? extensions[name]?.record ?? extensionUses[name]?.record
    }

    /// Everything that belongs to a space: what goes with it when it is removed.
    public func names(in space: String) -> [String] {
        [space] + bookmarks.values.filter { $0.space == space }.map(\.id)
            + pinned.values.filter { $0.space == space }.map(\.id)
            + deviceTabs.values.filter { $0.space == space }.map(\.id)
            + extensionUses.values.filter { $0.space == space }.map(\.id)
    }
}

// MARK: The rules

public enum SyncPlan {
    /// Every space gets an iCloud id while sync is on.
    public static func assignIDs(_ workspace: inout Workspace) {
        for s in workspace.spaces.indices where workspace.spaces[s].cloudID == nil {
            workspace.spaces[s].cloudID = UUID()
        }
    }

    // MARK: Workspace to records

    /// What iCloud should hold of the workspace's synced spaces: their
    /// names, bookmarks and pinned tabs. Built on `mirror`, what it holds
    /// now: neighbours keep their positions wherever their order is
    /// unchanged, so moving one bookmark rewrites one record; a bookmark
    /// whose folder hasn't arrived yet stays in that folder. Device tabs
    /// are carried over as they are.
    public static func records(of workspace: Workspace, keeping mirror: SyncMirror) -> SyncMirror {
        var out = SyncMirror()
        out.deviceTabs = mirror.deviceTabs
        // Extensions are the Mac's to change (publish); they come along as
        // they are, but for the uses of a space this device removed. A use
        // of a space it has never seen stays: its space may not have
        // arrived yet.
        out.extensions = mirror.extensions
        let synced = Set(workspace.spaces.compactMap { $0.cloudID?.uuidString })
        out.extensionUses = mirror.extensionUses.filter { synced.contains($0.value.space) || mirror.spaces[$0.value.space] == nil }
        // Where everything was, read out once: made again for every folder,
        // a tree of many folders went through every bookmark for each.
        let bookmarkPlaces = mirror.bookmarks.mapValues(\.position)
        let pinnedPlaces = mirror.pinned.mapValues(\.position)
        for space in workspace.spaces {
            guard let cloud = space.cloudID?.uuidString else { continue }
            out.spaces[cloud] = SyncSpace(id: cloud, name: space.name, symbol: space.symbol, color: space.color.rawValue)
            addBookmarks(space.bookmarks, parent: nil, space: cloud, previous: mirror, places: bookmarkPlaces, into: &out)
            let pins = space.tabs.filter(\.isPinned)
            let names = pins.map(pinName)
            let places = positions(names, previous: pinnedPlaces)
            for (index, tab) in pins.enumerated() {
                guard let url = tab.pinned else { continue }
                let name = names[index]
                // The title of the page it was pinned at; another page's
                // title, while it is elsewhere, would rewrite it on every load.
                let title = tab.url == tab.pinned ? tab.title : (mirror.pinned[name]?.title ?? tab.title)
                out.pinned[name] = SyncPinned(id: name, space: cloud, position: places[index], title: title, url: url.absoluteString)
            }
        }
        return out
    }

    private static func addBookmarks(_ list: [Bookmark], parent: String?, space: String, previous: SyncMirror,
                                     places known: [String: Double], into out: inout SyncMirror) {
        let names = list.map(\.id.uuidString)
        let places = positions(names, previous: known)
        for (index, item) in list.enumerated() {
            let name = names[index]
            var folder = parent
            var position = places[index]
            // At the top only because its folder hasn't arrived: still in it.
            if parent == nil, let known = previous.bookmarks[name], let waiting = known.parent,
               previous.bookmarks[waiting] == nil {
                folder = waiting
                position = known.position
            }
            out.bookmarks[name] = SyncBookmark(id: name, space: space, parent: folder, position: position,
                                               title: item.title, url: item.url?.absoluteString)
            if let children = item.children {
                addBookmarks(children, parent: name, space: space, previous: previous, places: known, into: &out)
            }
        }
    }

    static func pinName(_ tab: TabRecord) -> String {
        (tab.cloudID ?? tab.id).uuidString
    }

    /// Positions for `names` in this order: those already in increasing
    /// order (the longest such run) keep theirs, the rest go between their
    /// neighbours. When a gap has run out of room, all are numbered again.
    public static func positions(_ names: [String], previous: [String: Double]) -> [Double] {
        let known = names.map { previous[$0] }
        let keep = increasingRun(known)
        var out = [Double](repeating: 0, count: names.count)
        var index = 0
        while index < names.count {
            if keep.contains(index), let value = known[index] {
                out[index] = value
                index += 1
                continue
            }
            // A run of new places, between the kept ones around it.
            let start = index
            while index < names.count && !keep.contains(index) { index += 1 }
            let below = start > 0 ? out[start - 1] : nil
            let above = index < names.count ? known[index] : nil
            let count = index - start
            for k in 0..<count {
                switch (below, above) {
                case let (low?, high?): out[start + k] = low + (high - low) * Double(k + 1) / Double(count + 1)
                case let (low?, nil): out[start + k] = low + Double(k + 1)
                case let (nil, high?): out[start + k] = high - Double(count - k)
                case (nil, nil): out[start + k] = Double(k + 1)
                }
            }
        }
        // Halved too often to tell apart: start again from 1, 2, 3.
        for i in 1..<max(out.count, 1) where !(out[i] > out[i - 1]) || out[i] - out[i - 1] < 1e-9 {
            return names.indices.map { Double($0 + 1) }
        }
        return out
    }

    /// The indices of the longest run of known values that increases.
    private static func increasingRun(_ values: [Double?]) -> Set<Int> {
        var tails: [Int] = []
        var before = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if let tail = values[tails[mid]], tail < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { before[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run = Set<Int>()
        var at = tails.last ?? -1
        while at >= 0 {
            run.insert(at)
            at = before[at]
        }
        return run
    }

    /// The records to save and to delete for `old` to become `new`, device
    /// tabs aside: they are each device's own (deviceChanges).
    public static func changes(from old: SyncMirror, to new: SyncMirror) -> (save: [String], delete: [String]) {
        var save: [String] = []
        var delete: [String] = []
        for (name, value) in new.spaces where old.spaces[name] != value { save.append(name) }
        for (name, value) in new.bookmarks where old.bookmarks[name] != value { save.append(name) }
        for (name, value) in new.pinned where old.pinned[name] != value { save.append(name) }
        for (name, value) in new.extensions where old.extensions[name] != value { save.append(name) }
        for (name, value) in new.extensionUses where old.extensionUses[name] != value { save.append(name) }
        for name in old.spaces.keys where new.spaces[name] == nil { delete.append(name) }
        for name in old.bookmarks.keys where new.bookmarks[name] == nil { delete.append(name) }
        for name in old.pinned.keys where new.pinned[name] == nil { delete.append(name) }
        for name in old.extensions.keys where new.extensions[name] == nil { delete.append(name) }
        for name in old.extensionUses.keys where new.extensionUses[name] == nil { delete.append(name) }
        return (save.sorted(), delete.sorted())
    }

    // MARK: Records to workspace

    /// The space's bookmarks as the mirror has them: each folder's children
    /// in order. A bookmark whose folder hasn't arrived shows at the top
    /// until it does; two folders each in the other (two devices moving
    /// them at once) are broken at the top too.
    public static func tree(of space: String, in mirror: SyncMirror) -> [Bookmark] {
        let nodes = mirror.bookmarks.values.filter { $0.space == space }
        let names = Set(nodes.map(\.id))
        var children: [String?: [SyncBookmark]] = [:]
        for node in nodes {
            let parent = node.parent.flatMap { names.contains($0) && $0 != node.id ? $0 : nil }
            children[parent, default: []].append(node)
        }
        var placed = Set<String>()
        func build(_ parent: String?) -> [Bookmark] {
            let list = (children[parent] ?? []).sorted { ($0.position, $0.id) < ($1.position, $1.id) }
            return list.compactMap { node in
                guard placed.insert(node.id).inserted, let id = UUID(uuidString: node.id) else { return nil }
                if let address = node.url {
                    guard let url = URL(string: address) else { return nil }
                    return Bookmark(id: id, title: node.title, url: url)
                }
                return Bookmark(id: id, folder: node.title, children: build(node.id))
            }
        }
        var top = build(nil)
        // What a loop of folders kept from the top, in the same order on every device.
        for node in nodes.sorted(by: { $0.id < $1.id }) where !placed.contains(node.id) {
            guard let id = UUID(uuidString: node.id) else { continue }
            placed.insert(node.id)
            if let address = node.url, let url = URL(string: address) {
                top.append(Bookmark(id: id, title: node.title, url: url))
            } else if node.url == nil {
                top.append(Bookmark(id: id, folder: node.title, children: build(node.id)))
            }
        }
        return top
    }

    /// Spaces removed elsewhere, and pins removed elsewhere. Unpinned
    /// tabs keep their local browsing session, selection and unsaved work.
    public struct Applied: Equatable, Sendable {
        public var removedSpaces: [UUID] = []
        public var unpinnedTabs: [UUID] = []
    }

    /// The workspace's synced spaces as the mirror has them: names, icons,
    /// colours, bookmarks and pinned tabs. Spaces new to this device come in
    /// with one empty tab; `deleted` are spaces removed elsewhere, for the
    /// app to remove with their sign-ins.
    @discardableResult
    public static func apply(_ mirror: SyncMirror, to workspace: inout Workspace, deleted: Set<String> = [],
                             now: Date = Date()) -> Applied {
        var applied = Applied()
        for s in workspace.spaces.indices {
            guard let cloud = workspace.spaces[s].cloudID?.uuidString else { continue }
            if deleted.contains(cloud) {
                applied.removedSpaces.append(workspace.spaces[s].id)
                continue
            }
            guard let record = mirror.spaces[cloud] else { continue }
            workspace.spaces[s].name = record.name
            workspace.spaces[s].symbol = record.symbol
            workspace.spaces[s].color = SpaceColor(rawValue: record.color) ?? workspace.spaces[s].color
            workspace.spaces[s].bookmarks = tree(of: cloud, in: mirror)
            // A bookmark removed elsewhere lets its tab here go; one only moved keeps it,
            // its new folder perhaps still to come.
            workspace.spaces[s].forgetGoneBookmarks()
            applied.unpinnedTabs += applyPinned(mirror, to: &workspace.spaces[s], cloud: cloud, now: now)
        }
        let known = Set(workspace.spaces.compactMap { $0.cloudID?.uuidString })
        for record in mirror.spaces.values.sorted(by: { $0.name < $1.name }) where !known.contains(record.id) && !deleted.contains(record.id) {
            guard let cloud = UUID(uuidString: record.id) else { continue }
            let tab = TabRecord(url: nil, shown: now)
            var space = Space(name: record.name, symbol: record.symbol, color: SpaceColor(rawValue: record.color),
                              tabs: [tab], selected: tab.id, bookmarks: tree(of: record.id, in: mirror))
            space.cloudID = cloud
            _ = applyPinned(mirror, to: &space, cloud: record.id, now: now)
            workspace.spaces.append(space)
        }
        return applied
    }

    /// The space's pinned tabs in the mirror's order: kept, added, or
    /// unpinned without closing. A live tab keeps its page; only the address it
    /// goes back to changes.
    private static func applyPinned(_ mirror: SyncMirror, to space: inout Space, cloud: String, now: Date) -> [UUID] {
        let wanted = mirror.pinned.values.filter { $0.space == cloud }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        var pins: [String: TabRecord] = [:]
        for tab in space.tabs where tab.isPinned { pins[pinName(tab)] = tab }
        var pinnedTabs: [TabRecord] = []
        for record in wanted {
            guard let url = URL(string: record.url) else { continue }
            if var tab = pins.removeValue(forKey: record.id) {
                // At its pinned page, named as the mirror has it, so a name
                // from before isn't taken for a change here.
                if tab.url == tab.pinned || tab.url == url { tab.title = record.title }
                tab.pinned = url
                pinnedTabs.append(tab)
            } else {
                var tab = TabRecord(url: url, title: record.title, shown: .distantPast, pinned: url)
                tab.cloudID = UUID(uuidString: record.id)
                pinnedTabs.append(tab)
            }
        }
        // Unpin in local order without closing the page or losing its draft.
        var gone: [TabRecord] = []
        for var tab in space.tabs where tab.isPinned && pins[pinName(tab)] != nil {
            tab.pinned = nil
            tab.cloudID = nil
            gone.append(tab)
        }
        let others = space.tabs.filter { !$0.isPinned }
        space.tabs = pinnedTabs + gone + others
        if space.selected == nil || !space.tabs.contains(where: { $0.id == space.selected }) {
            space.selected = space.tabs.first?.id
        }
        return gone.map(\.id)
    }

    /// A device's last space, removed on another device: the app keeps one
    /// space, so it stays, but as a new one, without what was removed with
    /// it (its bookmarks; its pinned tabs, left open as ordinary tabs), so
    /// nothing removed comes back under the new space's iCloud id.
    public static func keepAsNew(_ space: inout Space) {
        space.cloudID = nil
        space.bookmarks = []
        space.forgetGoneBookmarks()
        for t in space.tabs.indices where space.tabs[t].isPinned {
            space.tabs[t].pinned = nil
            space.tabs[t].cloudID = nil
        }
    }

    // MARK: Turning sync on

    /// Joins this device's spaces to what iCloud holds: a space joins the
    /// one with its iCloud id, or else the one with its name, or comes in as
    /// new; both sets of bookmarks are kept, and pinned tabs at the same
    /// address are one. iCloud's spaces this device hasn't got come in too.
    /// Returns what iCloud should then hold; nothing of iCloud's is deleted.
    public static func join(_ workspace: inout Workspace, remote: SyncMirror, now: Date = Date()) -> SyncMirror {
        var taken = Set<String>()
        // Every space joined already keeps its iCloud id before any is
        // matched by name: else one earlier in the list, of the same name,
        // would take that id, and the joined one come in again as new.
        var joined = Set<Int>()
        for s in workspace.spaces.indices {
            guard let id = workspace.spaces[s].cloudID?.uuidString, remote.spaces[id] != nil, !taken.contains(id) else { continue }
            taken.insert(id)
            joined.insert(s)
        }
        for s in workspace.spaces.indices {
            var cloud = joined.contains(s) ? workspace.spaces[s].cloudID?.uuidString : nil
            if cloud == nil {
                let name = key(workspace.spaces[s].name)
                cloud = remote.spaces.values.sorted { $0.id < $1.id }
                    .first { key($0.name) == name && !taken.contains($0.id) }?.id
            }
            guard let match = cloud, let there = remote.spaces[match], let id = UUID(uuidString: match) else {
                // New to iCloud: its own id, unless it has none or another space took it.
                if workspace.spaces[s].cloudID.map({ taken.contains($0.uuidString) }) ?? true {
                    workspace.spaces[s].cloudID = UUID()
                }
                if let id = workspace.spaces[s].cloudID?.uuidString { taken.insert(id) }
                continue
            }
            taken.insert(match)
            workspace.spaces[s].cloudID = id
            workspace.spaces[s].name = there.name
            workspace.spaces[s].symbol = there.symbol
            workspace.spaces[s].color = SpaceColor(rawValue: there.color) ?? workspace.spaces[s].color
            var bookmarks = tree(of: match, in: remote)
            _ = Bookmarks.merge(workspace.spaces[s].bookmarks, into: &bookmarks)
            workspace.spaces[s].bookmarks = bookmarks
            workspace.spaces[s].forgetGoneBookmarks()
            // A pinned tab here at an address pinned there is that one.
            let theirs = remote.pinned.values.filter { $0.space == match }
            for t in workspace.spaces[s].tabs.indices where workspace.spaces[s].tabs[t].isPinned {
                let address = workspace.spaces[s].tabs[t].pinned.map(Bookmarks.key)
                if let same = theirs.first(where: { URL(string: $0.url).map(Bookmarks.key) == address }) {
                    workspace.spaces[s].tabs[t].cloudID = UUID(uuidString: same.id)
                }
            }
            // Theirs come in as pinned tabs; ours that they haven't got stay.
            _ = applyPinnedKeepingOurs(remote, to: &workspace.spaces[s], cloud: match, now: now)
        }
        // iCloud's spaces this device hasn't got.
        var incoming = remote
        incoming.spaces = remote.spaces.filter { !taken.contains($0.key) }
        apply(incoming, to: &workspace, now: now)
        return records(of: workspace, keeping: remote)
    }

    /// Pinned tabs on joining: iCloud's, then this device's own that iCloud hasn't got.
    private static func applyPinnedKeepingOurs(_ mirror: SyncMirror, to space: inout Space, cloud: String, now: Date) -> [UUID] {
        let ours = space.tabs.filter { $0.isPinned && mirror.pinned[pinName($0)] == nil }
        var merged = mirror
        let last = mirror.pinned.values.filter { $0.space == cloud }.map(\.position).max() ?? 0
        for (index, tab) in ours.enumerated() {
            guard let url = tab.pinned else { continue }
            merged.pinned[pinName(tab)] = SyncPinned(id: pinName(tab), space: cloud, position: last + Double(index + 1),
                                                     title: tab.title, url: url.absoluteString)
        }
        return applyPinned(merged, to: &space, cloud: cloud, now: now)
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: What may leave the device

    /// Query names that make an address a credential: whoever opens it is
    /// signed in, or finishes someone's sign-in.
    static let secretNames: Set<String> = [
        "code", "token", "access_token", "id_token", "refresh_token", "session", "sessionid", "sid",
        "sig", "signature", "auth", "authuser_token", "password", "otp", "key", "api_key", "apikey",
    ]

    /// A web address that is fine for another device to see.
    public static func isShareable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.user == nil,
              url.password == nil, !SignIn.isSignInPage(url),
              // An extension's store page would name, in plain words, what
              // the encrypted list of extensions keeps from Apple's sight.
              ExtensionStore.id(ofPage: url) == nil
        else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fragment = URLComponents(string: "x:?" + (url.fragment ?? ""))?.queryItems ?? []
        return !(items + fragment).contains { secretNames.contains($0.name.lowercased()) }
    }

    // MARK: Chrome extensions, between Macs

    /// What the list says of one of this Mac's extensions: from the Chrome
    /// Web Store only (a file or a folder has nowhere to come from on
    /// another Mac), and the synced spaces it is on in, by iCloud id.
    public struct LocalExtension: Codable, Equatable, Sendable {
        public var storeID: String
        public var title: String
        public var siteAccess: String
        public var spaces: Set<String>

        public init(storeID: String, title: String, siteAccess: String, spaces: Set<String>) {
            self.storeID = storeID
            self.title = title
            self.siteAccess = siteAccess
            self.spaces = spaces
        }
    }

    /// The records for this Mac's own changes, from the list it last sent
    /// (`old`; nil before its first) to the one it has now: an extension it
    /// added gets a record, another Mac's for the same store id if there is
    /// one; one it removed loses its record and its uses; a space it was
    /// turned on or off in gains or loses its use. What only other Macs have
    /// is left alone, so a Mac that hasn't installed something never takes
    /// it from the others.
    public static func publish(from old: [LocalExtension]?, to new: [LocalExtension], in mirror: inout SyncMirror,
                               name: () -> String = { UUID().uuidString }) -> (save: [String], delete: [String]) {
        var save: [String] = []
        var delete: [String] = []
        let before = Dictionary((old ?? []).map { ($0.storeID, $0) }, uniquingKeysWith: { first, _ in first })
        for item in new {
            let was = before[item.storeID]
            var record = mirror.extensions.values.sorted { $0.id < $1.id }.first { $0.storeID == item.storeID }
                ?? SyncExtension(id: name(), storeID: item.storeID, title: item.title, siteAccess: item.siteAccess)
            if was == nil || was?.title != item.title || was?.siteAccess != item.siteAccess || mirror.extensions[record.id] == nil {
                record.title = item.title
                record.siteAccess = item.siteAccess
                if mirror.extensions[record.id] != record {
                    mirror.extensions[record.id] = record
                    save.append(record.id)
                }
            }
            let id = record.id
            // Every record of the store id: two Macs that added it at once,
            // offline, each made one, and the two stand for one extension.
            let same = Set(mirror.extensions.values.filter { $0.storeID == item.storeID }.map(\.id) + [id])
            for space in item.spaces.subtracting(was?.spaces ?? []).sorted()
            where !mirror.extensionUses.values.contains(where: { same.contains($0.extensionRecord) && $0.space == space }) {
                let use = SyncExtensionUse(id: name(), extensionRecord: id, space: space)
                mirror.extensionUses[use.id] = use
                save.append(use.id)
            }
            let off = (was?.spaces ?? []).subtracting(item.spaces)
            for use in mirror.extensionUses.values where same.contains(use.extensionRecord) && off.contains(use.space) {
                mirror.extensionUses[use.id] = nil
                delete.append(use.id)
            }
        }
        let kept = Set(new.map(\.storeID))
        for item in old ?? [] where !kept.contains(item.storeID) {
            for record in mirror.extensions.values where record.storeID == item.storeID {
                mirror.extensions[record.id] = nil
                delete.append(record.id)
                for use in mirror.extensionUses.values where use.extensionRecord == record.id {
                    mirror.extensionUses[use.id] = nil
                    delete.append(use.id)
                }
            }
        }
        return (save, delete)
    }

    /// An extension and a space, by store id and the space's iCloud id.
    public struct ExtensionInSpace: Hashable, Sendable, Codable {
        public var storeID: String
        public var space: String

        public init(storeID: String, space: String) {
            self.storeID = storeID
            self.space = space
        }
    }

    /// What this Mac does to follow another Mac's change to the list, from
    /// the list as it was to as it is: an extension removed there, and
    /// installed here, is removed here, as Chrome's sync does; one turned on
    /// or off in a space there is here, if it is installed here. One that
    /// isn't installed here is offered (offers), never installed unasked.
    public static func follow(from before: SyncMirror, to after: SyncMirror,
                              local: [LocalExtension]) -> (removed: [String], on: [ExtensionInSpace], off: [ExtensionInSpace]) {
        let here = Dictionary(local.map { ($0.storeID, $0) }, uniquingKeysWith: { first, _ in first })
        let was = Set(before.extensions.values.map(\.storeID))
        let now = Set(after.extensions.values.map(\.storeID))
        let removed = was.subtracting(now).filter { here[$0] != nil }.sorted()
        let (old, new) = (extensionsOn(in: before), extensionsOn(in: after))
        let on = new.subtracting(old).filter { pair in here[pair.storeID].map { !$0.spaces.contains(pair.space) } ?? false }
        let off = old.subtracting(new).filter { now.contains($0.storeID) && (here[$0.storeID]?.spaces.contains($0.space) ?? false) }
        let order = { (a: ExtensionInSpace, b: ExtensionInSpace) in (a.storeID, a.space) < (b.storeID, b.space) }
        return (removed, on.sorted(by: order), off.sorted(by: order))
    }

    /// Every extension and the spaces the records have it on in. Not in a
    /// removed space: what it held is hidden with it, and comes back on if
    /// the space does (SyncMirror.settleSpaces).
    public static func extensionsOn(in mirror: SyncMirror) -> Set<ExtensionInSpace> {
        let removed = mirror.removedSpaces
        return Set(mirror.extensionUses.values.compactMap { use in
            guard !removed.contains(use.space) else { return nil }
            return mirror.extensions[use.extensionRecord].map { ExtensionInSpace(storeID: $0.storeID, space: use.space) }
        })
    }

    /// Other Macs' extensions that aren't on this one: offered, one by one.
    public static func offers(in mirror: SyncMirror, local: [LocalExtension]) -> [SyncExtension] {
        let here = Set(local.map(\.storeID))
        var seen = Set<String>()
        return mirror.extensions.values.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
            .filter { !here.contains($0.storeID) && seen.insert($0.storeID).inserted }
    }

    /// What joining takes up of the other Macs' list: the spaces their
    /// extensions are on in, for those installed here, as if each had just
    /// been turned on there; before this Mac's own list is first sent.
    public static func joining(_ mirror: SyncMirror, local: [LocalExtension]) -> [ExtensionInSpace] {
        var none = mirror
        none.extensionUses = [:]
        return follow(from: none, to: mirror, local: local).on
    }

    /// A space removed elsewhere: its uses, which an app that doesn't know
    /// them (an older one, the desktop extension) left behind. Only once its
    /// deletion has arrived, never for a space not seen yet.
    public static func uses(ofRemoved spaces: Set<String>, in mirror: SyncMirror) -> [String] {
        mirror.extensionUses.values.filter { spaces.contains($0.space) }.map(\.id).sorted()
    }

    // MARK: From the key-value store, once

    /// The spaces the key-value store kept before sync moved to CloudKit,
    /// as records: on the first sync after the update, they join like any
    /// other device's.
    public static func mirror(fromLegacy spaces: [CloudSpace]) -> SyncMirror {
        var mirror = SyncMirror()
        for space in spaces where !space.deleted {
            let cloud = space.id.uuidString
            mirror.spaces[cloud] = SyncSpace(id: cloud, name: space.name, symbol: space.symbol, color: space.color.rawValue)
            var workspace = Workspace(spaces: [Space(name: space.name, symbol: space.symbol, bookmarks: space.bookmarks)])
            workspace.spaces[0].cloudID = space.id
            mirror.bookmarks.merge(records(of: workspace, keeping: SyncMirror()).bookmarks) { _, new in new }
        }
        return mirror
    }
}

extension SyncPlan {
    /// The same fields sent to iCloud, excluding ordinary tabs and navigation.
    public static func hasSyncableChanges(from old: Workspace, to new: Workspace) -> Bool {
        face(of: old) != face(of: new)
    }

    /// What of a workspace goes to iCloud, to tell cheaply whether a change
    /// touched it: most changes are a page's title or address.
    private struct Face: Equatable {
        var cloud: UUID?
        var name: String
        var symbol: String
        var color: SpaceColor
        var bookmarks: [Bookmark]
        var pins: [String]
    }

    private static func face(of workspace: Workspace) -> [Face] {
        workspace.spaces.map { space in
            Face(cloud: space.cloudID, name: space.name, symbol: space.symbol, color: space.color, bookmarks: space.bookmarks,
                 pins: space.tabs.filter(\.isPinned).map {
                     "\(($0.cloudID ?? $0.id).uuidString) \($0.pinned?.absoluteString ?? "") \($0.url == $0.pinned ? $0.title : "")"
                 })
        }
    }
}
