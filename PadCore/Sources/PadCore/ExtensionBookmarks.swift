import Foundation

/// Chrome's bookmark tree over one space. The two fixed folders cannot be edited.
public struct ExtensionBookmarks {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    public private(set) var items: [Bookmark]
    public private(set) var events: [(name: String, arguments: [Any])] = []
    public init(_ items: [Bookmark]) { self.items = items }
    public var entries: [(item: Bookmark, parent: String, index: Int)] { rows() }

    public func node(_ item: Bookmark, parent: String, index: Int, recursive: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["id": item.id.uuidString, "parentId": parent, "index": index, "title": item.title]
        if let url = item.url { result["url"] = url.absoluteString }
        if recursive, let children = item.children {
            result["children"] = children.enumerated().map { node($0.element, parent: item.id.uuidString, index: $0.offset, recursive: true) }
        }
        return result
    }

    private func folder(_ root: Bool, recursive: Bool) -> [String: Any] {
        if root {
            return ["id": "0", "title": "", "children": [folder(false, recursive: recursive)]]
        }
        var result: [String: Any] = ["id": "1", "parentId": "0", "index": 0, "title": BrowserText.localized("Bookmarks")]
        if recursive { result["children"] = items.enumerated().map { node($0.element, parent: "1", index: $0.offset, recursive: true) } }
        return result
    }

    private func rows(_ list: [Bookmark]? = nil, parent: String = "1") -> [(item: Bookmark, parent: String, index: Int)] {
        (list ?? items).enumerated().flatMap { index, item in
            [(item: item, parent: parent, index: index)] + rows(item.children ?? [], parent: item.id.uuidString)
        }
    }

    private func children(_ parent: String) throws -> [Bookmark] {
        if parent == "1" { return items }
        guard let id = UUID(uuidString: parent), let item = Bookmarks.find(id, in: items), let children = item.children else {
            throw Failure("Bookmark folder not found.")
        }
        return children
    }

    private mutating func insert(_ item: Bookmark, parent: String, index: Int?) throws {
        var list = try children(parent)
        let at = index ?? list.count
        guard (0...list.count).contains(at) else { throw Failure("Invalid bookmark index.") }
        list.insert(item, at: at)
        if parent == "1" { items = list }
        else if let id = UUID(uuidString: parent) { Bookmarks.update(id, in: &items) { $0.children = list } }
    }

    public mutating func answer(_ method: String, arguments: [Any]) throws -> Any? {
        let first = arguments.first
        func described(_ id: String, recursive: Bool = false) throws -> [String: Any] {
            if id == "0" || id == "1" { return folder(id == "0", recursive: recursive) }
            guard let uuid = UUID(uuidString: id), let row = rows().first(where: { $0.item.id == uuid }) else { throw Failure("Bookmark not found.") }
            return node(row.item, parent: row.parent, index: row.index, recursive: recursive)
        }
        switch method {
        case "getTree": return [folder(true, recursive: true)]
        case "get":
            let ids = (first as? [String]) ?? (first as? String).map { [$0] } ?? []
            guard !ids.isEmpty else { throw Failure("A bookmark id is required.") }
            return try ids.map { try described($0) }
        case "getSubTree": return try [described(first as? String ?? "", recursive: true)]
        case "getChildren":
            let parent = first as? String ?? ""
            if parent == "0" { return [folder(false, recursive: false)] }
            return try children(parent).enumerated().map { node($0.element, parent: parent, index: $0.offset) }
        case "search":
            let query = first as? [String: Any] ?? [:]
            let text = (first as? String ?? query["query"] as? String ?? "").lowercased()
            return rows().filter { row in
                (text.isEmpty || (row.item.title + " " + (row.item.url?.absoluteString ?? "")).lowercased().contains(text))
                    && ((query["title"] as? String).map { $0 == row.item.title } ?? true)
                    && ((query["url"] as? String).map { $0 == row.item.url?.absoluteString } ?? true)
            }.map { node($0.item, parent: $0.parent, index: $0.index) }
        case "create":
            let properties = first as? [String: Any] ?? [:]
            let title = properties["title"] as? String ?? ""
            let item: Bookmark
            if let address = properties["url"] as? String {
                guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      url.user == nil, url.password == nil else { throw Failure("A bookmark requires an HTTP or HTTPS address without credentials.") }
                item = Bookmark(title: title, url: url)
            } else { item = Bookmark(folder: title, children: []) }
            let parent = properties["parentId"] as? String ?? "1"
            try insert(item, parent: parent, index: properties["index"] as? Int)
            let result = try described(item.id.uuidString)
            events.append(("bookmarks.onCreated", [item.id.uuidString, result]))
            return result
        case "update", "move", "remove", "removeTree":
            guard let text = first as? String, let id = UUID(uuidString: text),
                  let before = rows().first(where: { $0.item.id == id }) else { throw Failure("This bookmark cannot be edited.") }
            let properties = arguments.dropFirst().first as? [String: Any] ?? [:]
            if method == "update" {
                var changed = before.item
                if let title = properties["title"] as? String { changed.title = title }
                if let address = properties["url"] as? String {
                    guard !changed.isFolder, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          url.user == nil, url.password == nil else { throw Failure("A bookmark requires an HTTP or HTTPS address without credentials.") }
                    changed.url = url
                }
                Bookmarks.update(id, in: &items) { $0 = changed }
                var change: [String: Any] = ["title": changed.title]
                if let url = changed.url { change["url"] = url.absoluteString }
                events.append(("bookmarks.onChanged", [id.uuidString, change]))
                return try described(id.uuidString)
            }
            if method == "move" {
                let parent = properties["parentId"] as? String ?? before.parent
                let descendants = Set(rows([before.item]).map { $0.item.id })
                guard UUID(uuidString: parent).map({ !descendants.contains($0) }) ?? (parent == "1") else { throw Failure("A folder cannot be moved inside itself.") }
                _ = try children(parent)
                let original = items
                Bookmarks.remove(id, from: &items)
                do { try insert(before.item, parent: parent, index: properties["index"] as? Int) }
                catch { items = original; throw error }
                let after = try described(id.uuidString)
                events.append(("bookmarks.onMoved", [id.uuidString, ["parentId": parent, "index": after["index"] ?? 0,
                                                                          "oldParentId": before.parent, "oldIndex": before.index]]))
                return after
            }
            guard method == "removeTree" || (before.item.children ?? []).isEmpty else { throw Failure("The folder is not empty. Use removeTree to remove its contents.") }
            Bookmarks.remove(id, from: &items)
            events.append(("bookmarks.onRemoved", [id.uuidString, ["parentId": before.parent, "index": before.index,
                                                                       "node": node(before.item, parent: before.parent, index: before.index, recursive: true)]]))
            return nil
        default: throw Failure("This browser cannot provide bookmark creation dates or import events.")
        }
    }
}
