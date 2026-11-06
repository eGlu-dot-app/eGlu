import Foundation

/// A space's bookmark: a link, or a folder of them. Each space has its own,
/// as it has its own sign-ins, and a new tab shows them as a grid
/// (StartPage.swift).
public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// Where it goes; nil for a folder.
    public var url: URL?
    /// What a folder holds; nil for a link.
    public var children: [Bookmark]?

    public init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
        children = nil
    }

    public init(id: UUID = UUID(), folder title: String, children: [Bookmark]) {
        self.id = id
        self.title = title
        url = nil
        self.children = children
    }

    public var isFolder: Bool {
        url == nil
    }

    /// The name a tile shows: the title, else the address. The bookmarks
    /// bar in the reader's own words: its title stays Chromium's.
    public var label: String {
        if Bookmarks.isBar(self) { return BrowserText.localized("Bookmarks bar") }
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        return url.map(Address.pretty) ?? BrowserText.localized("Folder")
    }

    /// Every link in it and in its folders.
    public var links: [Bookmark] {
        isFolder ? (children ?? []).flatMap(\.links) : [self]
    }
}

/// What bookmarks do to each other: finding, adding, taking away, merging
/// an import in.
public enum Bookmarks {
    /// The folders a new tab's page has opened, outermost first, as they
    /// are now: each must be in the one before it, and a folder that has
    /// gone, or was never there, ends the path.
    public static func folders(along path: [UUID], in bookmarks: [Bookmark]) -> [Bookmark] {
        var level = bookmarks
        var found: [Bookmark] = []
        for id in path {
            guard let folder = level.first(where: { $0.id == id && $0.isFolder }) else { break }
            found.append(folder)
            level = folder.children ?? []
        }
        return found
    }

    /// The rows a sidebar lists: each bookmark and folder in order, and
    /// under each folder in `open` what it holds, a step further in.
    public static func rows(of bookmarks: [Bookmark], opening open: Set<UUID>,
                            depth: Int = 0) -> [(item: Bookmark, depth: Int)] {
        bookmarks.flatMap { item -> [(item: Bookmark, depth: Int)] in
            let own = [(item: item, depth: depth)]
            guard item.isFolder, open.contains(item.id) else { return own }
            return own + rows(of: item.children ?? [], opening: open, depth: depth + 1)
        }
    }

    // MARK: The bookmarks bar

    /// The folder whose bookmarks stand under a space's pinned tiles, each
    /// opening in a tab of its own (Workspace.openFromBar), named as
    /// Chromium names its own, so a bar imported from Chrome is this one.
    /// It is known by its name, at the top: iCloud keeps a folder's name and
    /// place already, so other devices know it with nothing more kept.
    public static let barName = "Bookmarks bar"

    public static func isBar(_ item: Bookmark) -> Bool {
        item.isFolder && item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == barName.lowercased()
    }

    /// The bar: the first folder at the top so named; nil before there is one.
    public static func bar(in items: [Bookmark]) -> Bookmark? {
        items.first(where: isBar)
    }

    /// Everything but the bar: Other Bookmarks, as Chromium calls the rest.
    public static func others(in items: [Bookmark]) -> [Bookmark] {
        guard let bar = bar(in: items) else { return items }
        return items.filter { $0.id != bar.id }
    }

    /// Every bookmark and folder inside the bar, at any depth.
    public static func barIDs(in items: [Bookmark]) -> Set<UUID> {
        func ids(_ items: [Bookmark]) -> [UUID] {
            items.flatMap { [$0.id] + ids($0.children ?? []) }
        }
        return Set(ids(bar(in: items)?.children ?? []))
    }

    /// The bar's rows, as `rows`, and in a folder that is shut the bookmarks
    /// of it in `kept` (those open in a tab), a step in from the folder: an
    /// open one stays in sight in a folder that is shut, as Arc keeps it.
    public static func rows(of bookmarks: [Bookmark], opening open: Set<UUID>, keeping kept: Set<UUID>,
                            depth: Int = 0) -> [(item: Bookmark, depth: Int)] {
        bookmarks.flatMap { item -> [(item: Bookmark, depth: Int)] in
            let own = [(item: item, depth: depth)]
            guard item.isFolder else { return own }
            if open.contains(item.id) {
                return own + rows(of: item.children ?? [], opening: open, keeping: kept, depth: depth + 1)
            }
            return own + item.links.filter { kept.contains($0.id) }.map { (item: $0, depth: depth + 1) }
        }
    }

    /// Two addresses that are the same page as far as a bookmark goes: no
    /// difference for case in the scheme and host, or a slash at the end of
    /// the path. Only the path's: one at the end of a query or a fragment
    /// (?next=/a/, #/home/) is part of where the link goes.
    static func key(_ url: URL) -> String {
        var text = url.absoluteString
        if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.percentEncodedPath.hasSuffix("/") {
            parts.percentEncodedPath.removeLast()
            text = parts.string ?? text
        }
        if let scheme = url.scheme, let host = url.host {
            let start = "\(scheme)://\(host)"
            if text.lowercased().hasPrefix(start.lowercased()) {
                text = start.lowercased() + text.dropFirst(start.count)
            }
        }
        return text
    }

    /// The bookmark for `url` at any depth, or nil.
    public static func find(_ url: URL, in items: [Bookmark]) -> Bookmark? {
        let wanted = key(url)
        for item in items {
            if let link = item.url, key(link) == wanted { return item }
            if let found = find(url, in: item.children ?? []) { return found }
        }
        return nil
    }

    /// The bookmark or folder with `id`, at any depth.
    public static func find(_ id: UUID, in items: [Bookmark]) -> Bookmark? {
        for item in items {
            if item.id == id { return item }
            if let found = find(id, in: item.children ?? []) { return found }
        }
        return nil
    }

    /// Changes the bookmark or folder with `id` in place, at any depth.
    /// False when there was none.
    @discardableResult
    public static func update(_ id: UUID, in items: inout [Bookmark], _ change: (inout Bookmark) -> Void) -> Bool {
        for index in items.indices {
            if items[index].id == id {
                change(&items[index])
                return true
            }
            guard var inside = items[index].children, update(id, in: &inside, change) else { continue }
            items[index].children = inside
            return true
        }
        return false
    }

    /// Puts `item` at the end of the folder `folder`, or of the top level
    /// for nil; before `before` when that is in the same folder. False when
    /// there is no such folder.
    @discardableResult
    public static func insert(_ item: Bookmark, into folder: UUID?, before: UUID? = nil, of items: inout [Bookmark]) -> Bool {
        func placed(in level: [Bookmark]) -> [Bookmark] {
            var level = level
            level.insert(item, at: before.flatMap { b in level.firstIndex { $0.id == b } } ?? level.endIndex)
            return level
        }
        guard let folder else {
            items = placed(in: items)
            return true
        }
        return update(folder, in: &items) { $0.children = placed(in: $0.children ?? []) } && find(folder, in: items)?.isFolder == true
    }

    /// The folder `id` is in: nil for the top level, and for none.
    public static func parent(of id: UUID, in items: [Bookmark]) -> UUID? {
        for item in items {
            guard let children = item.children else { continue }
            if children.contains(where: { $0.id == id }) { return item.id }
            if let found = parent(of: id, in: children) { return found }
        }
        return nil
    }

    /// Takes a bookmark or a folder away, at any depth. False when there was none.
    @discardableResult
    public static func remove(_ id: UUID, from items: inout [Bookmark]) -> Bool {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: index)
            return true
        }
        for index in items.indices {
            guard var inside = items[index].children, remove(id, from: &inside) else { continue }
            items[index].children = inside
            return true
        }
        return false
    }

    /// What the bookmark manager lists while words are typed, as Chromium's
    /// does: every link and folder, at any depth and in order, whose name or
    /// address holds each of the words, with the folders it is in, outermost
    /// first. The bookmarks bar itself is no result: it is always in the
    /// manager's list of folders already.
    public static func matching(_ query: String, in items: [Bookmark]) -> [(item: Bookmark, path: [Bookmark])] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        func holds(_ item: Bookmark) -> Bool {
            let text = [item.label, item.url?.absoluteString ?? ""].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        func walk(_ level: [Bookmark], path: [Bookmark], top: Bool) -> [(item: Bookmark, path: [Bookmark])] {
            level.flatMap { item -> [(item: Bookmark, path: [Bookmark])] in
                let bar = top && item.id == Bookmarks.bar(in: items)?.id
                let own = !bar && holds(item) ? [(item: item, path: path)] : []
                return own + walk(item.children ?? [], path: path + [item], top: false)
            }
        }
        return walk(items, path: [], top: true)
    }

    /// `imported` added to `existing`: a link already at its level is left
    /// out, and a folder whose name is already there is merged into that
    /// one, so importing the same file twice adds nothing. A new folder that
    /// brings no links is left out too, unless `keepingEmpty`: eGlu's own
    /// export, whose empty folders were made so on purpose. Returns how many
    /// links it added.
    @discardableResult
    public static func merge(_ imported: [Bookmark], into existing: inout [Bookmark], keepingEmpty: Bool = false) -> Int {
        var added = 0
        // What this level holds already, worked out once: its links by key
        // and its folders by name. Looking through the level for each link
        // coming in made a folder of a thousand links a million comparisons.
        var links = Set(existing.compactMap { $0.url.map(key) })
        // The bar by any spelling of its name is the one bar.
        func name(_ folder: Bookmark) -> String { isBar(folder) ? barName : folder.title }
        var folders: [String: Int] = [:]
        for (index, item) in existing.enumerated() where item.isFolder && folders[name(item)] == nil {
            folders[name(item)] = index
        }
        for item in imported {
            if let link = item.url {
                guard links.insert(key(link)).inserted else { continue }
                existing.append(Bookmark(title: item.title, url: link))
                added += 1
                continue
            }
            let children = item.children ?? []
            if let index = folders[name(item)] {
                var inside = existing[index].children ?? []
                added += merge(children, into: &inside, keepingEmpty: keepingEmpty)
                existing[index].children = inside
            } else {
                var inside: [Bookmark] = []
                added += merge(children, into: &inside, keepingEmpty: keepingEmpty)
                if !inside.isEmpty || keepingEmpty {
                    existing.append(Bookmark(folder: item.title, children: inside))
                    folders[name(item)] = existing.count - 1
                }
            }
        }
        return added
    }
}

/// A site's icon is kept once for every page of the site: the host, in
/// lower case, without www.
public enum IconKey {
    public static func of(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What a bookmarks file holds, ready to go into a space.
public struct BookmarkImport: Equatable, Sendable {
    /// For the top of a space's bookmarks: the file's favourites first (its
    /// bookmarks bar, Safari's Favorites), as the space's own bookmarks bar
    /// (Bookmarks.barName), then its other links and folders.
    public var items: [Bookmark]
    /// The icons the file carries, by IconKey (Chrome's export has them).
    public var icons: [String: Data]
    /// Whether its empty folders stay: in eGlu's own export they were made
    /// so on purpose (BookmarkFile.generator); in another browser's, a
    /// folder with nothing to open is left out.
    public var keepsEmptyFolders = false

    public var count: Int {
        items.flatMap(\.links).count
    }
}

/// A bookmark import's result, including recoverable failures. Parsed bookmarks
/// stay available when the destination disappears during file reading.
public struct BookmarkImportRetry: Equatable, Sendable {
    public let bookmarks: BookmarkImport
    public let destination: UUID

    public init(bookmarks: BookmarkImport, destination: UUID) {
        self.bookmarks = bookmarks
        self.destination = destination
    }
}

public enum BookmarkImportOutcome: Equatable, Sendable {
    /// `folders`: new folders it brought, which only eGlu's own export
    /// brings without links in them (BookmarkImport.keepsEmptyFolders).
    case imported(added: Int, total: Int, space: String, folders: Int = 0)
    case duplicates(total: Int, space: String)
    case unreadable, archiveWithoutBookmarks, empty, cancelled
    case destinationMissing(BookmarkImport)
    case workspaceUnavailable
    case notSaved(added: Int, total: Int, space: String, retry: BookmarkImportRetry? = nil, folders: Int = 0)

    public var isComplete: Bool {
        switch self {
        case .imported, .duplicates: return true
        default: return false
        }
    }

    public var canChooseFile: Bool {
        switch self {
        case .unreadable, .archiveWithoutBookmarks, .empty, .cancelled: return true
        default: return false
        }
    }

    public var parsed: BookmarkImport? {
        if case .destinationMissing(let bookmarks) = self { return bookmarks }
        return nil
    }

    public var needsSave: Bool {
        if case .notSaved = self { return true }
        return false
    }

    /// Recheck identity after an asynchronous save or before a retry. A matching
    /// name is not enough to make a replacement space the import destination.
    public func validatingDestination(in workspace: Workspace) -> Self {
        guard case let .notSaved(added, total, _, retry?, folders) = self else { return self }
        guard let space = workspace.space(retry.destination) else { return .destinationMissing(retry.bookmarks) }
        return .notSaved(added: added, total: total, space: space.name, retry: retry, folders: folders)
    }

    public func acknowledgingSave(_ saved: Bool, retry: BookmarkImportRetry? = nil) -> Self {
        switch self {
        case let .imported(added, total, space, folders) where !saved:
            return .notSaved(added: added, total: total, space: space, retry: retry, folders: folders)
        case let .duplicates(total, space) where !saved: return .notSaved(added: 0, total: total, space: space, retry: retry)
        case let .notSaved(added, total, space, _, folders) where saved:
            return added > 0 || folders > 0 ? .imported(added: added, total: total, space: space, folders: folders)
                : .duplicates(total: total, space: space)
        default: return self
        }
    }

    public var title: String {
        switch self {
        case let .imported(added, _, _, folders) where added == 0 && folders > 0: return BrowserText.localized("Folders Imported")
        case .imported: return BrowserText.localized("Bookmarks Imported")
        case .duplicates: return BrowserText.localized("Bookmarks Already Present")
        case .unreadable: return BrowserText.localized("Could Not Read the File")
        case .archiveWithoutBookmarks: return BrowserText.localized("No Bookmarks in This Archive")
        case .empty: return BrowserText.localized("No Bookmarks Found")
        case .cancelled: return BrowserText.localized("Import Cancelled")
        case .destinationMissing: return BrowserText.localized("Choose Another Space")
        case .workspaceUnavailable: return BrowserText.localized("Workspace Is Unavailable")
        case .notSaved: return BrowserText.localized("Bookmarks Are Not Saved Yet")
        }
    }

    public var message: String {
        switch self {
        // Only folders new: the file's bookmarks were all there already.
        case let .imported(added, total, space, folders) where added == 0 && folders > 0:
            return String(format: BrowserText.localized("%1$lld folders added to %2$@. The %3$lld bookmarks in the file were already there."), folders, space, total)
        case let .imported(added, total, space, _):
            return String(format: BrowserText.localized("%1$lld of %2$lld bookmarks added to %3$@. They appear in this space's bookmarks and on new tabs."), added, total, space)
        case let .duplicates(total, space): return String(format: BrowserText.localized("All %1$lld bookmarks in the file are already in %2$@."), total, space)
        case .unreadable: return BrowserText.localized("Choose the file again, or save a local copy first. You can also import later in Settings.")
        case .archiveWithoutBookmarks: return BrowserText.localized("Choose an HTML bookmark export from Chrome, Firefox or Safari, or a Safari ZIP export that includes Bookmarks.")
        case .empty: return BrowserText.localized("Export bookmarks as HTML from Chrome, Firefox or Safari, then choose that file.")
        case .cancelled: return BrowserText.localized("No bookmarks were imported.")
        case .destinationMissing: return BrowserText.localized("The destination space was removed while the file was being read. The file has been read. Choose an existing space to import into.")
        case .workspaceUnavailable: return BrowserText.localized("Recover and save the workspace before importing bookmarks. The bookmark file is unchanged.")
        case let .notSaved(added, _, space, _, folders) where added == 0 && folders > 0:
            return String(format: BrowserText.localized("%1$lld folders were added to %2$@ in this session, but the workspace could not be saved. Keep eGlu open and retry saving."), folders, space)
        case let .notSaved(added, _, space, _, _):
            return String(format: BrowserText.localized("%1$lld bookmarks were added to %2$@ in this session, but the workspace could not be saved. Keep eGlu open and retry saving."), added, space)
        }
    }
}

public enum BookmarkImportReadFailure: Error, Equatable, Sendable {
    case archiveWithoutBookmarks, empty

    public var outcome: BookmarkImportOutcome {
        switch self {
        case .archiveWithoutBookmarks: return .archiveWithoutBookmarks
        case .empty: return .empty
        }
    }
}

/// The bookmarks file every browser exports, Chrome's, Safari's (on its own
/// or inside the ZIP of Safari's Export Browsing Data), Firefox's and Edge's:
/// Netscape's old format, links in nested <DL> lists under <H3> folder names.
///
/// It is read loosely, a byte at a time, because exporters never quite agree
/// and a Chrome file can be megabytes of inline icons. Only web addresses are
/// kept; javascript:, file: and browser-internal links are left out.
public enum BookmarkFile {
    public static func readExport(_ data: Data) -> Result<BookmarkImport, BookmarkImportReadFailure> {
        var html = data
        if ZipFile.isArchive(data) {
            guard let inside = ZipFile.file(in: data, matching: { $0.lowercased().hasSuffix("bookmarks.html") }) else {
                return .failure(.archiveWithoutBookmarks)
            }
            html = inside
        }
        let parsed = parse(html)
        return parsed.count > 0 ? .success(parsed) : .failure(.empty)
    }

    public static func parse(_ data: Data) -> BookmarkImport {
        var reader = Reader(bytes: [UInt8](data))
        return reader.read()
    }

    /// A space's bookmarks in the same format, as Chrome writes it: the bar
    /// as the folder marked PERSONAL_TOOLBAR_FOLDER, first, and the rest
    /// after it at the top, so Chrome, Firefox, Safari and eGlu each read the
    /// bar back as their own. There are no dates to write: none are kept.
    public static func export(_ items: [Bookmark]) -> Data {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<META NAME=\"generator\" CONTENT=\"\(generator)\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        func write(_ level: [Bookmark], depth: Int) {
            let indent = String(repeating: "    ", count: depth)
            for item in level {
                if let url = item.url {
                    lines.append("\(indent)<DT><A HREF=\"\(escaped(url.absoluteString))\">\(escaped(item.title))</A>")
                    continue
                }
                let bar = depth == 1 && Bookmarks.isBar(item) && Bookmarks.bar(in: items)?.id == item.id
                let mark = bar ? " PERSONAL_TOOLBAR_FOLDER=\"true\"" : ""
                lines.append("\(indent)<DT><H3\(mark)>\(escaped(bar ? Bookmarks.barName : item.title))</H3>")
                lines.append("\(indent)<DL><p>")
                write(item.children ?? [], depth: depth + 1)
                lines.append("\(indent)</DL><p>")
            }
        }
        let bar = Bookmarks.bar(in: items).map { [$0] } ?? []
        write(bar + Bookmarks.others(in: items), depth: 1)
        lines.append("</DL><p>")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// What eGlu's export says made it, so reading the file back keeps its
    /// empty folders. Other browsers pass over a META they don't know.
    static let generator = "eGlu"

    /// Text safe in an attribute in double quotes, and between tags.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Names a folder of favourites goes by: the bar under the address bar.
    static let favouriteNames: Set<String> = [
        "bookmarks bar", "bookmarks toolbar", "bookmarksbar", "favorites", "favourites",
        "favorites bar", "favourites bar", "toolbar",
    ]

    /// Chrome's and Firefox's folder for what is not in the bar.
    static let othersName = "Other bookmarks"

    private struct Frame {
        var title: String
        var favourites: Bool
        var items: [Bookmark] = []
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        var frames = [Frame(title: "", favourites: false)]
        /// For each <DL> open: whether it opened a folder of its own.
        var lists: [Bool] = []
        var pending: Frame?
        var icons: [String: Data] = [:]

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func read() -> BookmarkImport {
            while let tag = nextTag() {
                switch tag.name {
                case "dl":
                    if let folder = pending {
                        frames.append(folder)
                        pending = nil
                        lists.append(true)
                    } else {
                        lists.append(false)
                    }
                case "/dl":
                    if lists.popLast() == true, frames.count > 1, let folder = frames.popLast() {
                        frames[frames.count - 1].items.append(
                            Bookmark(folder: folder.title, children: folder.items)
                        )
                        // Kept apart, to be lifted out when it is the file's favourites.
                        if folder.favourites, frames.count == 1 { favouritesIndex = frames[0].items.count - 1 }
                    }
                case "h3":
                    let title = text(until: "</h3")
                    let marked = tag.attributes["personal_toolbar_folder"]?.lowercased() == "true"
                    // Other browsers' bars are known by their names too; eGlu's
                    // own export marks its one bar, and a folder of the space's
                    // called Favorites is only a folder.
                    let named = !ownExport && BookmarkFile.favouriteNames.contains(title.lowercased())
                    pending = Frame(title: title, favourites: marked || (named && frames.count == 1))
                case "meta":
                    if tag.attributes["name"]?.lowercased() == "generator",
                       tag.attributes["content"]?.lowercased().hasPrefix(BookmarkFile.generator.lowercased()) == true {
                        ownExport = true
                    }
                case "a":
                    let title = text(until: "</a")
                    guard let href = tag.attributes["href"], let url = URL(string: href),
                          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                          url.host != nil
                    else { break }
                    frames[frames.count - 1].items.append(Bookmark(title: title, url: url))
                    if let icon = tag.attributes["icon"], let key = IconKey.of(url), icons[key] == nil,
                       let picture = Reader.dataURL(icon) {
                        icons[key] = picture
                    }
                default:
                    break
                }
            }
            // Folders a broken file never closed.
            while frames.count > 1, let folder = frames.popLast() {
                frames[frames.count - 1].items.append(Bookmark(folder: folder.title, children: folder.items))
            }
            // Chrome's and Firefox's Other Bookmarks are the top's own rest:
            // what they hold goes there, not into a folder of that name.
            var top: [Bookmark] = []
            for (offset, item) in frames[0].items.enumerated() {
                // In eGlu's own export a folder so named is one of the space's own.
                if !ownExport, offset != favouritesIndex, item.isFolder,
                   item.title.lowercased() == BookmarkFile.othersName.lowercased() {
                    top += item.children ?? []
                } else {
                    top.append(item)
                }
            }
            // eGlu's own export keeps its empty folders: they were made so on purpose.
            let keep = ownExport
            func tidy(_ items: [Bookmark]) -> [Bookmark] { keep ? items : Reader.pruned(items) }
            var items = tidy(top)
            if let index = favouritesIndex, index < frames[0].items.count {
                // The file's favourites are the space's bookmarks bar, first.
                let favourites = frames[0].items[index]
                let bar = Bookmark(folder: Bookmarks.barName, children: favourites.children ?? [])
                items = tidy([bar] + items.filter { $0.id != favourites.id })
            }
            return BookmarkImport(items: items, icons: icons, keepsEmptyFolders: ownExport)
        }

        var favouritesIndex: Int?
        /// The file is eGlu's own export (BookmarkFile.generator).
        var ownExport = false

        /// Folders with no links left in them taken out.
        static func pruned(_ items: [Bookmark]) -> [Bookmark] {
            items.compactMap { item in
                guard item.isFolder else { return item }
                let inside = pruned(item.children ?? [])
                return inside.isEmpty ? nil : Bookmark(id: item.id, folder: item.title, children: inside)
            }
        }

        // MARK: Bytes

        struct Tag {
            var name: String
            var attributes: [String: String]
        }

        /// The next tag, its name in lower case and its attributes, with the
        /// reader just past it. Comments and <!DOCTYPE> are skipped.
        mutating func nextTag() -> Tag? {
            while at < bytes.count {
                guard bytes[at] == UInt8(ascii: "<") else {
                    at += 1
                    continue
                }
                at += 1
                if starts("!--") {
                    skip(past: "-->")
                    continue
                }
                if at < bytes.count, bytes[at] == UInt8(ascii: "!") || bytes[at] == UInt8(ascii: "?") {
                    skip(past: ">")
                    continue
                }
                var name = ""
                while at < bytes.count, !Reader.isSpace(bytes[at]), bytes[at] != UInt8(ascii: ">") {
                    name.append(Character(Unicode.Scalar(Reader.lower(bytes[at]))))
                    at += 1
                }
                var attributes: [String: String] = [:]
                while at < bytes.count, bytes[at] != UInt8(ascii: ">") {
                    if Reader.isSpace(bytes[at]) || bytes[at] == UInt8(ascii: "/") {
                        at += 1
                        continue
                    }
                    let start = at
                    while at < bytes.count, !Reader.isSpace(bytes[at]), bytes[at] != UInt8(ascii: "="),
                          bytes[at] != UInt8(ascii: ">") {
                        at += 1
                    }
                    let key = String(decoding: bytes[start..<at].map(Reader.lower), as: UTF8.self)
                    while at < bytes.count, Reader.isSpace(bytes[at]) { at += 1 }
                    guard at < bytes.count, bytes[at] == UInt8(ascii: "=") else {
                        attributes[key] = ""
                        continue
                    }
                    at += 1
                    while at < bytes.count, Reader.isSpace(bytes[at]) { at += 1 }
                    var value: ArraySlice<UInt8>
                    if at < bytes.count, bytes[at] == UInt8(ascii: "\"") || bytes[at] == UInt8(ascii: "'") {
                        let quote = bytes[at]
                        at += 1
                        let from = at
                        while at < bytes.count, bytes[at] != quote { at += 1 }
                        value = bytes[from..<min(at, bytes.count)]
                        at += 1
                    } else {
                        let from = at
                        while at < bytes.count, !Reader.isSpace(bytes[at]), bytes[at] != UInt8(ascii: ">") { at += 1 }
                        value = bytes[from..<at]
                    }
                    attributes[key] = Reader.decode(String(decoding: value, as: UTF8.self))
                }
                at += 1
                return Tag(name: name, attributes: attributes)
            }
            return nil
        }

        /// The text up to a closing tag, its tags taken out, its entities
        /// decoded, its spaces tidied; the reader just past the tag.
        mutating func text(until closing: String) -> String {
            let end = Array(closing.utf8)
            // A file cut off inside a tag leaves the reader past the end.
            at = min(at, bytes.count)
            let start = at
            while at < bytes.count, !matches(end, at: at) { at += 1 }
            var raw = String(decoding: bytes[start..<min(at, bytes.count)], as: UTF8.self)
            skip(past: ">")
            raw = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            let words = Reader.decode(raw).split(whereSeparator: { $0.isWhitespace })
            return words.joined(separator: " ")
        }

        func matches(_ word: [UInt8], at index: Int) -> Bool {
            guard index + word.count <= bytes.count else { return false }
            for offset in word.indices where Reader.lower(bytes[index + offset]) != word[offset] {
                return false
            }
            return true
        }

        func starts(_ word: String) -> Bool {
            matches(Array(word.utf8), at: at)
        }

        mutating func skip(past word: String) {
            let wanted = Array(word.utf8)
            while at < bytes.count, !matches(wanted, at: at) { at += 1 }
            at = min(at + wanted.count, bytes.count)
        }

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
        }

        static func lower(_ byte: UInt8) -> UInt8 {
            byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
        }

        /// &amp; and the rest, and numeric references.
        static func decode(_ text: String) -> String {
            guard text.contains("&") else { return text }
            let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
            var out = ""
            var rest = Substring(text)
            while let amp = rest.firstIndex(of: "&") {
                out += rest[..<amp]
                let after = rest[rest.index(after: amp)...]
                guard let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 10 else {
                    out += "&"
                    rest = after
                    continue
                }
                let name = String(after[..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[name.lowercased()]
                }
                if let replacement {
                    out += replacement
                    rest = after[after.index(after: semi)...]
                } else {
                    out += "&"
                    rest = after
                }
            }
            out += rest
            return out
        }

        /// The picture in a data: URL, base64 or not.
        static func dataURL(_ text: String) -> Data? {
            guard text.lowercased().hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
            let header = text[..<comma].lowercased()
            guard header.contains("image/") else { return nil }
            let body = String(text[text.index(after: comma)...])
            if header.hasSuffix(";base64") { return Data(base64Encoded: body, options: .ignoreUnknownCharacters) }
            return body.removingPercentEncoding.map { Data($0.utf8) }
        }
    }
}
