#if canImport(SQLite3)
import Foundation
import SQLite3
#if canImport(os)
import os

private let historyLog = Logger(subsystem: "net.taehee.safience", category: "History")
#endif

public enum HistoryStoreError: Error {
    case sqlite(String)
    /// A change failed and undoing it failed too, so the connection may
    /// still be inside the change.
    case rollbackFailed(change: any Error, rollback: any Error)
    /// A handoff to keep, in a store given no folder to keep their files in.
    case noHandoffFolder
}

/// Each space's history on this device, in a SQLite file of its own:
/// visits, pages, and the clearings made (HistoryRemoval), with the pages'
/// names, addresses and descriptions searchable inside words. That text is
/// kept decomposed (History.searchable) and indexed in threes (FTS5's
/// trigram tokenizer), so "은행" finds "우리은행", and "lass" finds "Glass".
///
/// Only the history: nothing of a page's own text, and no sign-in pages,
/// which are never recorded (History.keeps). Handoffs made here are kept
/// beside the visits, never as visits, with a copy of each one's Markdown
/// file in a folder of their own (HistoryHandoff).
public actor HistoryStore {
    /// Only this actor uses the connection; deinit, which runs outside it,
    /// closes it when nothing else can reach it.
    nonisolated(unsafe) private let db: OpaquePointer
    /// Clearings already made, for visits that arrive after them (HistoryRemoval.covers).
    private var removals: [HistoryRemoval] = []
    /// Clearings in the file that can't be read back, so missing from
    /// removals: what they cleared can come back, and this says why.
    public private(set) var unreadableRemovals = 0
    /// Goes up with every change, for what shows history to know it is out of date.
    public private(set) var revision = 0

    /// Where handoffs' Markdown files are kept, a folder for each by its id;
    /// nil for a store that keeps no handoff.
    public nonisolated let handoffFolder: URL?

    public init(url: URL, handoffs: URL? = nil) throws {
        handoffFolder = handoffs
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(url.path)"
            sqlite3_close(handle)
            throw HistoryStoreError.sqlite(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try Self.prepare(handle)
        (removals, unreadableRemovals) = try Self.loadRemovals(handle)
        var latest = removals.map(\.made).max()
        let statement = try Statement(handle, "SELECT MAX(COALESCE(stamp, time)) FROM visits")
        if try statement.step(), let time = Row(statement: statement).optionalReal(0) {
            latest = max(latest ?? .distantPast, Date(timeIntervalSince1970: time))
        }
        latestWhenOpened = latest
    }

    /// The latest time it held when opened, a visit's or a clearing's: a
    /// device's clock goes past it before anything is made, so what is
    /// made next is after it.
    public nonisolated let latestWhenOpened: Date?

    deinit {
        sqlite3_close(db)
    }

    // MARK: Recording

    /// A visit made on this device, unless a clearing already covers it.
    public func record(_ visit: HistoryVisit, now: Date = Date()) throws {
        let key = History.pageKey(visit.url)
        try query("SELECT title, summary FROM pages WHERE space = ? AND page = ?", [.text(visit.space.uuidString), .text(key)]) { row in
            named.append((visit.id, row.text(0), row.text(1)))
        }
        if named.count > 64 { named.removeFirst(named.count - 64) }
        try merge([visit], now: now)
    }

    /// What a page was called and said of itself before a visit made here
    /// renamed it: put back if that visit is taken back (forget), as a
    /// sign-in page's is, so none of that page stays. The last few only.
    private var named: [(visit: UUID, title: String, summary: String)] = []

    /// Visits from wherever they come (this device, another through iCloud):
    /// each once, none a clearing covers. Returns those kept.
    @discardableResult
    public func merge(_ visits: [HistoryVisit], now: Date = Date()) throws -> [HistoryVisit] {
        var kept: [HistoryVisit] = []
        var touched: Set<PageID> = []
        try transaction {
            // A handoff is never a visit (HistoryHandoff): one that comes as one is let go of.
            for visit in visits where visit.kind != .handoff && !removals.contains(where: { $0.covers(visit) }) {
                let key = History.pageKey(visit.url)
                try run("INSERT OR IGNORE INTO visits(id, space, page, url, time, device, kind, search, stamp) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        [.text(visit.id.uuidString), .text(visit.space.uuidString), .text(key), .text(visit.url.absoluteString),
                         .real(visit.time.timeIntervalSince1970), .text(visit.device), .text(visit.kind.rawValue),
                         visit.search.map { .text($0) } ?? .null, visit.stamp.map { .real($0.timeIntervalSince1970) } ?? .null])
                // Had already: only the page's name and description, which may have come since.
                let new = sqlite3_changes(db) > 0
                if !new {
                    guard !visit.title.isEmpty || !visit.summary.isEmpty else { continue }
                    try run("""
                        UPDATE pages SET title = CASE WHEN ? <> '' AND ? >= last THEN ? ELSE title END,
                                         summary = CASE WHEN ? <> '' AND ? >= last THEN ? ELSE summary END
                        WHERE space = ? AND page = ?
                        """, [.text(visit.title), .real(visit.time.timeIntervalSince1970), .text(visit.title),
                              .text(History.summary(visit.summary)), .real(visit.time.timeIntervalSince1970),
                              .text(History.summary(visit.summary)), .text(visit.space.uuidString), .text(key)])
                    touched.insert(PageID(space: visit.space, key: key))
                    continue
                }
                // The page as this visit has it, where it says more than the page so far does.
                try run("""
                    INSERT INTO pages(space, page, url, title, summary, last, count, frecency, search)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?)
                    ON CONFLICT(space, page) DO UPDATE SET
                        url = CASE WHEN excluded.last >= pages.last THEN excluded.url ELSE pages.url END,
                        title = CASE WHEN excluded.title <> '' AND excluded.last >= pages.last THEN excluded.title
                                     WHEN pages.title = '' THEN excluded.title ELSE pages.title END,
                        summary = CASE WHEN excluded.summary <> '' AND excluded.last >= pages.last THEN excluded.summary
                                       WHEN pages.summary = '' THEN excluded.summary ELSE pages.summary END,
                        search = COALESCE(excluded.search, pages.search)
                    """, [.text(visit.space.uuidString), .text(key), .text(visit.url.absoluteString), .text(visit.title),
                          .text(History.summary(visit.summary)), .real(visit.time.timeIntervalSince1970),
                          visit.search.map { .text($0) } ?? .null])
                touched.insert(PageID(space: visit.space, key: key))
                kept.append(visit)
            }
            for page in touched { try refresh(page, now: now) }
        }
        if !touched.isEmpty { revision += 1 }
        return kept
    }

    /// A page's name and description, as they come in after the visit was made.
    /// Returns the time of `device`'s last visit to the page, whose day's record then has its new name.
    @discardableResult
    public func update(space: UUID, url: URL, title: String?, summary: String?, device: String? = nil) throws -> Date? {
        let page = PageID(space: space, key: History.pageKey(url))
        try transaction {
            if let title, !title.isEmpty {
                try run("UPDATE pages SET title = ? WHERE space = ? AND page = ?", [.text(title), .text(space.uuidString), .text(page.key)])
            }
            if let summary {
                try run("UPDATE pages SET summary = ? WHERE space = ? AND page = ?",
                        [.text(History.summary(summary)), .text(space.uuidString), .text(page.key)])
            }
            try index(page)
        }
        revision += 1
        var last: Date?
        try query("SELECT MAX(time) FROM visits WHERE space = ? AND page = ? AND device = ?",
                  [.text(space.uuidString), .text(page.key), .text(device ?? "")]) { row in
            if let time = row.optionalReal(0) { last = Date(timeIntervalSince1970: time) }
        }
        return last
    }

    /// A visit taken back: it turned out to be a sign-in page.
    /// Returns the space and the time the visit had, for what was sent of it to be sent again.
    @discardableResult
    public func forget(visit id: UUID, now: Date = Date()) throws -> (space: UUID, time: Date)? {
        var page: PageID?
        var time = Date()
        try query("SELECT space, page, time FROM visits WHERE id = ?", [.text(id.uuidString)]) { row in
            if let space = UUID(uuidString: row.text(0)) { page = PageID(space: space, key: row.text(1)) }
            time = Date(timeIntervalSince1970: row.real(2))
        }
        guard let page else { return nil }
        var before = named.last { $0.visit == id }
        named.removeAll { $0.visit == id }
        // Only while it was the page's last visit: a later one named it since.
        try query("SELECT COUNT(*) FROM visits WHERE space = ? AND page = ? AND time > ?",
                  [.text(page.space.uuidString), .text(page.key), .real(time.timeIntervalSince1970)]) { row in
            if row.int(0) > 0 { before = nil }
        }
        try transaction {
            try run("DELETE FROM visits WHERE id = ?", [.text(id.uuidString)])
            if let before {
                try run("UPDATE pages SET title = ?, summary = ? WHERE space = ? AND page = ?",
                        [.text(before.title), .text(before.summary), .text(page.space.uuidString), .text(page.key)])
            }
            try refresh(page, now: now)
        }
        revision += 1
        return (page.space, time)
    }

    // MARK: Finding

    /// Extension searches use literal title/address text and visit time, without handoffs or semantic search.
    public func extensionSearch(space: UUID, text: String, from: Date, to: Date, limit: Int, mostVisited: Bool = false) throws -> [HistoryPage] {
        var pages: [HistoryPage] = []
        let like = "%" + Self.escaped(text) + "%"
        let order = mostVisited ? "p.count DESC, p.last DESC" : "p.last DESC"
        try query("""
            SELECT p.space, p.page, p.url, p.title, p.summary, p.last, p.count, p.frecency, p.search
            FROM pages p WHERE p.space = ? AND p.last >= ? AND p.last <= ?
            AND (p.title LIKE ? ESCAPE '\\' OR p.url LIKE ? ESCAPE '\\') ORDER BY \(order) LIMIT ?
            """, [.text(space.uuidString), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970),
                  .text(like), .text(like), .int(max(0, min(limit, 10_000)))]) { row in
            if let page = Self.page(row) { pages.append(page) }
        }
        return pages
    }

    public func extensionVisits(space: UUID, url: URL) throws -> [HistoryVisit] {
        try visits(where: "v.space = ? AND v.page = ?", [.text(space.uuidString), .text(History.pageKey(url))])
            .sorted { $0.time > $1.time }
    }

    /// The space's pages whose name, address or description has every one
    /// of the words in it (anywhere inside, as History.searchable keeps
    /// them), gone to within the query's stretch of time if it names one;
    /// most wanted first. Only pages with a visit the scope lets in, if one is given.
    public func search(space: UUID, query wanted: HistoryQuery, limit: Int = 30,
                       scope: HistoryScope = HistoryScope()) throws -> [HistoryPage] {
        guard scope.pages else { return [] }
        var scope = scope
        scope.from = [scope.from, wanted.from].compactMap { $0 }.max()
        scope.to = [scope.to, wanted.to].compactMap { $0 }.min()
        let visits = Self.conditions(scope)
        // A matching page can have newer visits outside this filter. Show
        // the latest matching visit, so Yesterday never displays Today.
        let last = visits.sql.isEmpty ? "p.last" : "(SELECT MAX(v.time) FROM visits v WHERE v.space = p.space AND v.page = p.page\(visits.sql))"
        var sql = """
            SELECT p.space, p.page, p.url, p.title, p.summary, \(last) AS matched_last, p.count, p.frecency, p.search
            FROM pages p JOIN pages_fts f ON f.rowid = p.rowid WHERE p.space = ?
            """
        var values: [Value] = visits.values + [.text(space.uuidString)]
        // An address's words are kept apart at its dots, dashes and slashes
        // (words(of:)), so what is typed is taken apart the same way.
        let words = wanted.words.split { !($0.isLetter || $0.isNumber) }.map { History.searchable(String($0)) }
        // Three letters or more (NFD's, so two Korean syllables) go through
        // the trigram index; fewer are looked for in every page's text.
        let long = words.filter { $0.unicodeScalars.count >= 3 }
        if !long.isEmpty {
            sql += " AND pages_fts MATCH ?"
            values.append(.text(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")))
        }
        for word in words where word.unicodeScalars.count < 3 {
            let like = "%" + Self.escaped(word) + "%"
            sql += " AND (f.title LIKE ? ESCAPE '\\' OR f.words LIKE ? ESCAPE '\\' OR f.summary LIKE ? ESCAPE '\\')"
            values += [.text(like), .text(like), .text(like)]
        }
        if !visits.sql.isEmpty {
            sql += " AND EXISTS (SELECT 1 FROM visits v WHERE v.space = p.space AND v.page = p.page\(visits.sql))"
            values += visits.values
        }
        sql += " ORDER BY p.frecency DESC, matched_last DESC LIMIT ?"
        values.append(.int(limit))
        var pages: [HistoryPage] = []
        try query(sql, values) { row in if let page = Self.page(row) { pages.append(page) } }
        return pages
    }

    /// The pages last gone to in a space, each once, at its latest visit,
    /// newest first: on this device (`device`), or on its others
    /// (`others`). What a new tab's page lists (History, Other Devices).
    public func recent(space: UUID, device: String, others: Bool, limit: Int = 6) throws -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        // SQLite takes a row's other columns from the one MAX() picks: the latest visit's.
        try query("""
            \(Self.selectEntries(time: "MAX(v.time)"))
            WHERE v.space = ? AND (v.device = ?) = ?
            GROUP BY v.page ORDER BY MAX(v.time) DESC LIMIT ?
            """, [.text(space.uuidString), .text(device), .int(others ? 0 : 1), .int(limit)]) { row in
            if let entry = Self.entry(row) { entries.append(entry) }
        }
        return entries
    }

    /// The space's visits and handoffs that the scope lets in, newest
    /// first, before `before` if given: the History list, a page at a time.
    public func entries(space: UUID, before: Date? = nil, limit: Int = 200,
                        scope: HistoryScope = HistoryScope()) throws -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        let end = before?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
        if scope.pages {
            let visits = Self.conditions(scope)
            try query("""
                \(Self.selectEntries(time: "v.time"))
                WHERE v.space = ? AND v.time < ?\(visits.sql) ORDER BY v.time DESC LIMIT ?
                """, [.text(space.uuidString), .real(end)] + visits.values + [.int(limit)]) { row in
                if let entry = Self.entry(row) { entries.append(entry) }
            }
        }
        guard scope.takesHandoffs else { return entries }
        // As many of each, then the newest of both: what is cut is older than all that stays.
        let times = Self.handoffConditions(from: scope.from, to: scope.to)
        let handoffs = try handoffs(where: "space = ? AND time < ?" + times.sql, [.text(space.uuidString), .real(end)] + times.values,
                                    limit: limit)
        guard !handoffs.isEmpty else { return entries }
        return Array((entries + handoffs.map(HistoryEntry.init(handoff:))).sorted { $0.time > $1.time }.prefix(limit))
    }

    /// The SELECT and FROM of a list of visits as HistoryEntry: a page's
    /// columns (`page(_:)`), then the visit's id, `time` and kind.
    private static func selectEntries(time: String) -> String {
        """
        SELECT p.space, p.page, p.url, p.title, p.summary, p.last, p.count, p.frecency, p.search, v.id, \(time), v.kind
        FROM visits v JOIN pages p ON p.space = v.space AND p.page = v.page
        """
    }

    private static func entry(_ row: Row) -> HistoryEntry? {
        guard let page = page(row), let id = UUID(uuidString: row.text(9)) else { return nil }
        return HistoryEntry(id: id, time: Date(timeIntervalSince1970: row.real(10)),
                            kind: HistoryKind(rawValue: row.text(11)) ?? .other, page: page)
    }

    /// What a visit `v` must be for the scope, as SQL to follow a WHERE's
    /// other conditions, and its values: nothing for a scope that lets all in.
    private static func conditions(_ scope: HistoryScope) -> (sql: String, values: [Value]) {
        var sql = ""
        var values: [Value] = []
        if let device = scope.device {
            sql += " AND (v.device = ?) = ?"
            values += [.text(device), .int(scope.others ? 0 : 1)]
        }
        if let from = scope.from {
            sql += " AND v.time >= ?"
            values.append(.real(from.timeIntervalSince1970))
        }
        if let to = scope.to {
            sql += " AND v.time <= ?"
            values.append(.real(to.timeIntervalSince1970))
        }
        return (sql, values)
    }

    // MARK: Handoffs

    /// A handoff an app took: its Markdown file copied into the folder for
    /// handoffs, under the name it went with, in a folder of the handoff's
    /// id; then the handoff kept. Nothing is kept if either fails. Returns
    /// the handoff as kept, with its file's place.
    @discardableResult
    public func recordHandoff(id: UUID = UUID(), space: UUID, title: String, address: URL?, time: Date,
                              copying source: URL) throws -> HistoryHandoff {
        guard let handoffFolder else { throw HistoryStoreError.noHandoffFolder }
        let files = FileManager.default
        let folder = handoffFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        let kept = folder.appendingPathComponent(source.lastPathComponent)
        // Without the tags that follow whoever opens it, as a visit's is kept.
        let address = address.map(History.address)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: kept)
            let words = title + " " + (address.map { Self.words(of: $0.absoluteString) } ?? "")
            try run("INSERT INTO handoffs(id, space, title, address, time, file, words) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.text(id.uuidString), .text(space.uuidString), .text(title), address.map { .text($0.absoluteString) } ?? .null,
                     .real(time.timeIntervalSince1970), .text(kept.lastPathComponent), .text(History.searchable(words))])
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
        revision += 1
        return HistoryHandoff(id: id, space: space, title: title, address: address, time: time, file: kept)
    }

    /// The space's handoffs whose name or address has every one of the
    /// words in it (as History.searchable keeps them), made within the
    /// query's stretch of time and the scope's; newest first.
    public func handoffs(space: UUID, query wanted: HistoryQuery, limit: Int = 30,
                         scope: HistoryScope = HistoryScope()) throws -> [HistoryHandoff] {
        guard scope.takesHandoffs else { return [] }
        let from = [scope.from, wanted.from].compactMap { $0 }.max()
        let to = [scope.to, wanted.to].compactMap { $0 }.min()
        let times = Self.handoffConditions(from: from, to: to)
        var condition = "space = ?" + times.sql
        var values: [Value] = [.text(space.uuidString)] + times.values
        for word in wanted.words.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map({ History.searchable(String($0)) }) {
            condition += " AND words LIKE ? ESCAPE '\\'"
            values.append(.text("%" + Self.escaped(word) + "%"))
        }
        return try handoffs(where: condition, values, limit: limit)
    }

    /// One handoff let go of, and its file.
    public func removeHandoff(_ id: UUID) throws {
        try run("DELETE FROM handoffs WHERE id = ?", [.text(id.uuidString)])
        removeKept([id])
        revision += 1
    }

    /// The folder for handoffs as the store holds them, at launch: a file
    /// kept for no handoff goes (its handoff let go of while the file
    /// couldn't be, or the app stopped between the two), and so does a
    /// handoff whose file is gone, which History could not offer again.
    public func tidyHandoffs() throws {
        guard let handoffFolder else { return }
        var held: [UUID: String] = [:]
        try query("SELECT id, file FROM handoffs", []) { row in
            if let id = UUID(uuidString: row.text(0)) { held[id] = row.text(1) }
        }
        let files = FileManager.default
        let found: [URL]
        do {
            found = try files.contentsOfDirectory(at: handoffFolder, includingPropertiesForKeys: nil)
        } catch {
            // A folder there and not read now (the device locked): nothing is let go of for it.
            guard !files.fileExists(atPath: handoffFolder.path) else { return }
            found = []
        }
        for item in found where UUID(uuidString: item.lastPathComponent).map({ held[$0] == nil }) ?? true {
            try? files.removeItem(at: item)
        }
        let gone = held.filter { !files.fileExists(atPath: Self.kept(id: $0.key, name: $0.value, in: handoffFolder).path) }.keys
        guard !gone.isEmpty else { return }
        try transaction {
            for id in gone { try run("DELETE FROM handoffs WHERE id = ?", [.text(id.uuidString)]) }
        }
        revision += 1
    }

    /// The handoffs that `condition` lets in, newest first, `limit` at most.
    private func handoffs(where condition: String, _ values: [Value], limit: Int) throws -> [HistoryHandoff] {
        guard let handoffFolder else { return [] }
        var found: [HistoryHandoff] = []
        try query("SELECT id, space, title, address, time, file FROM handoffs WHERE \(condition) ORDER BY time DESC LIMIT ?",
                  values + [.int(limit)]) { row in
            guard let id = UUID(uuidString: row.text(0)), let space = UUID(uuidString: row.text(1)) else { return }
            found.append(HistoryHandoff(id: id, space: space, title: row.text(2), address: row.optionalText(3).flatMap(URL.init(string:)),
                                        time: Date(timeIntervalSince1970: row.real(4)),
                                        file: Self.kept(id: id, name: row.text(5), in: handoffFolder)))
        }
        return found
    }

    /// The ids of the handoffs `condition` lets in.
    private func handoffIDs(where condition: String, _ values: [Value]) throws -> [UUID] {
        var ids: [UUID] = []
        try query("SELECT id FROM handoffs WHERE \(condition)", values) { row in
            if let id = UUID(uuidString: row.text(0)) { ids.append(id) }
        }
        return ids
    }

    /// Handoffs' files gone with them, once what let them go is saved. One
    /// that can't be removed now is at the next launch (tidyHandoffs).
    private func removeKept(_ ids: [UUID]) {
        guard let handoffFolder else { return }
        for id in ids {
            try? FileManager.default.removeItem(at: handoffFolder.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }

    private static func kept(id: UUID, name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(name)
    }

    /// What a handoff's time must be, as SQL to follow a WHERE's other conditions, and its values.
    private static func handoffConditions(from: Date?, to: Date?) -> (sql: String, values: [Value]) {
        var sql = ""
        var values: [Value] = []
        if let from {
            sql += " AND time >= ?"
            values.append(.real(from.timeIntervalSince1970))
        }
        if let to {
            sql += " AND time <= ?"
            values.append(.real(to.timeIntervalSince1970))
        }
        return (sql, values)
    }

    // MARK: For iCloud

    /// A device's visits in a space within a stretch of time, oldest first,
    /// with their pages' names: what one of its History records holds.
    public func visits(device: String, space: UUID, from: Date, to: Date) throws -> [HistoryVisit] {
        try visits(where: "v.device = ? AND v.space = ? AND v.time >= ? AND v.time <= ?",
                   [.text(device), .text(space.uuidString), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)])
    }

    /// The spaces and days (HistoryCloudDay) a device has visits on, after `since` if given.
    public func days(device: String, since: Date? = nil) throws -> Set<HistoryDayOfSpace> {
        var days: Set<HistoryDayOfSpace> = []
        try query("SELECT space, time FROM visits WHERE device = ? AND time > ?",
                  [.text(device), .real(since?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)]) { row in
            guard let space = UUID(uuidString: row.text(0)) else { return }
            days.insert(HistoryDayOfSpace(space: space, day: HistoryCloudDay.key(for: Date(timeIntervalSince1970: row.real(1)))))
        }
        return days
    }

    /// What iCloud's side keeps here between launches (HistoryCloud), by name; nil to let it go.
    public func syncValue(_ name: String) throws -> Data? {
        var value: Data?
        try query("SELECT value FROM sync_state WHERE name = ?", [.text(name)]) { value = $0.blob(0) }
        return value
    }

    public func setSyncValue(_ value: Data?, for name: String) throws {
        if let value {
            try run("INSERT INTO sync_state(name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                    [.text(name), .blob(value)])
        } else {
            try run("DELETE FROM sync_state WHERE name = ?", [.text(name)])
        }
    }

    /// Visits for other devices: this device's own, made after `since`, with their pages' names.
    public func visits(device: String, since: Date) throws -> [HistoryVisit] {
        try visits(where: "v.device = ? AND v.time > ?", [.text(device), .real(since.timeIntervalSince1970)])
    }

    /// The visits that `condition` lets in, oldest first, with their pages' names.
    private func visits(where condition: String, _ values: [Value]) throws -> [HistoryVisit] {
        var visits: [HistoryVisit] = []
        try query("""
            SELECT v.id, v.space, v.url, p.title, p.summary, v.time, v.device, v.kind, v.search, v.stamp
            FROM visits v JOIN pages p ON p.space = v.space AND p.page = v.page
            WHERE \(condition) ORDER BY v.time
            """, values) { row in
            guard let id = UUID(uuidString: row.text(0)), let space = UUID(uuidString: row.text(1)),
                  let url = URL(string: row.text(2)) else { return }
            visits.append(HistoryVisit(id: id, space: space, url: url, title: row.text(3), summary: row.text(4),
                                       time: Date(timeIntervalSince1970: row.real(5)),
                                       stamp: row.optionalReal(9).map(Date.init(timeIntervalSince1970:)), device: row.text(6),
                                       kind: HistoryKind(rawValue: row.text(7)) ?? .other, search: row.optionalText(8)))
        }
        return visits
    }

    // MARK: Clearing

    /// History cleared, and kept as cleared: visits arriving later that it covers are let go too.
    /// Returns the days `device`'s visits it took were on, for those days to be sent again.
    @discardableResult
    public func remove(_ removal: HistoryRemoval, now: Date = Date(), daysOf device: String? = nil, syncAccount: String? = nil) throws -> Set<HistoryDayOfSpace> {
        var condition = "COALESCE(stamp, time) <= ?"
        var values: [Value] = [.real(removal.made.timeIntervalSince1970)]
        if let space = removal.space {
            condition += " AND space = ?"
            values.append(.text(space.uuidString))
        }
        switch removal.scope {
        case .page(let digest):
            // The clearing names the page by its digest: the keys visited are looked at for it.
            var keys: [String] = []
            try query("SELECT DISTINCT page FROM visits WHERE \(condition)", values) { row in
                if History.digest(ofKey: row.text(0)) == digest { keys.append(row.text(0)) }
            }
            condition += keys.isEmpty ? " AND 0" : " AND page IN (\(keys.map { _ in "?" }.joined(separator: ", ")))"
            values += keys.map { .text($0) }
        case .range(let from, let to):
            condition += " AND time >= ? AND time <= ?"
            values += [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
        case .all:
            break
        case .visit(let id):
            condition += " AND id = ?"
            values.append(.text(id.uuidString))
        }
        var touched: Set<PageID> = []
        var days: Set<HistoryDayOfSpace> = []
        try query("SELECT space, page, time, device FROM visits WHERE \(condition)", values) { row in
            guard let space = UUID(uuidString: row.text(0)) else { return }
            touched.insert(PageID(space: space, key: row.text(1)))
            if row.text(3) == device {
                days.insert(HistoryDayOfSpace(space: space, day: HistoryCloudDay.key(for: Date(timeIntervalSince1970: row.real(2)))))
            }
        }
        // The handoffs made in a stretch of time it clears, or before it
        // cleared everything, go too, with their files; a page's or a
        // visit's clearing says which visits, and leaves them.
        var handoffCondition: (sql: String, values: [Value])?
        switch removal.scope {
        case .range(let from, let to): handoffCondition = Self.handoffConditions(from: from, to: to)
        case .all: handoffCondition = Self.handoffConditions(from: nil, to: removal.wall ?? removal.made)
        case .page, .visit: handoffCondition = nil
        }
        if let space = removal.space, let made = handoffCondition {
            handoffCondition = (made.sql + " AND space = ?", made.values + [.text(space.uuidString)])
        }
        let handoffs = try handoffCondition.map { try handoffIDs(where: "1" + $0.sql, $0.values) } ?? []
        let scope = String(data: try JSONEncoder().encode(removal.scope), encoding: .utf8) ?? "{}"
        let subsumed = try removals.filter { old in
            guard removal.subsumes(old) else { return false }
            return try syncValue("pending-clear:" + old.id.uuidString) == nil
        }
        let subsumedIDs = Set(subsumed.map(\.id))
        try transaction {
            try run("INSERT OR IGNORE INTO removals(id, space, scope, made, wall) VALUES (?, ?, ?, ?, ?)",
                    [.text(removal.id.uuidString), removal.space.map { .text($0.uuidString) } ?? .null, .text(scope),
                     .real(removal.made.timeIntervalSince1970), removal.wall.map { .real($0.timeIntervalSince1970) } ?? .null])
            // This intent commits with the deletion, so a metadata/read failure cannot lose its eventual sync.
            if let syncAccount {
                try setSyncValue(Data(syncAccount.utf8), for: "pending-clear:" + removal.id.uuidString)
            }
            // Everything cleared holds for the clearings before it: they go.
            for old in subsumed { try run("DELETE FROM removals WHERE id = ?", [.text(old.id.uuidString)]) }
            try run("DELETE FROM visits WHERE \(condition)", values)
            for id in handoffs { try run("DELETE FROM handoffs WHERE id = ?", [.text(id.uuidString)]) }
            for page in touched { try refresh(page, now: now) }
        }
        removeKept(handoffs)
        removals.removeAll { subsumedIDs.contains($0.id) }
        if !removals.contains(where: { $0.id == removal.id }) { removals.append(removal) }
        revision += 1
        return days
    }

    /// Durable local clear intents belonging to this exact Apple Account.
    public func pendingClearings(for account: String) throws -> [HistoryRemoval] {
        var ids: Set<UUID> = []
        try query("SELECT name, value FROM sync_state WHERE name LIKE 'pending-clear:%'", []) { row in
            guard String(data: row.blob(1), encoding: .utf8) == account,
                  let id = UUID(uuidString: String(row.text(0).dropFirst("pending-clear:".count))) else { return }
            ids.insert(id)
        }
        return removals.filter { ids.contains($0.id) }
    }

    public func clearingSynced(_ id: UUID) throws {
        try setSyncValue(nil, for: "pending-clear:" + id.uuidString)
    }

    /// Every account's clear intents let go, the clearings themselves kept:
    /// history sync was turned off before iCloud had them, and sends none of them later.
    public func dropPendingClearings() throws {
        try run("DELETE FROM sync_state WHERE name LIKE 'pending-clear:%'", [])
    }

    /// The clearings made, for other devices.
    public func allRemovals() -> [HistoryRemoval] {
        removals
    }

    /// A space gone, and its history with it, its handoffs too.
    public func removeSpace(_ space: UUID) throws {
        let handoffs = try handoffIDs(where: "space = ?", [.text(space.uuidString)])
        try transaction {
            try run("DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages WHERE space = ?)", [.text(space.uuidString)])
            try run("DELETE FROM pages WHERE space = ?", [.text(space.uuidString)])
            try run("DELETE FROM visits WHERE space = ?", [.text(space.uuidString)])
            try run("DELETE FROM handoffs WHERE space = ?", [.text(space.uuidString)])
        }
        removeKept(handoffs)
        revision += 1
    }

    /// The history of spaces that are gone (removed here, or on another device), let go.
    public func keepSpaces(_ spaces: Set<UUID>) throws {
        var held: Set<String> = []
        try query("SELECT DISTINCT space FROM visits UNION SELECT DISTINCT space FROM handoffs", []) { held.insert($0.text(0)) }
        for gone in held.subtracting(spaces.map(\.uuidString)) {
            if let id = UUID(uuidString: gone) { try removeSpace(id) }
        }
    }

    /// What is kept no longer: visits and handoffs older than the
    /// retention, pages with none left, clearings older than any record of
    /// what they cleared (400 days, as History's iCloud records are kept
    /// no longer); and every page's frecency again, as its visits have aged.
    public func prune(keeping retention: HistoryRetention, now: Date = Date()) throws {
        var touched: Set<PageID> = []
        let cutoff = retention.cutoff(now: now)
        let handoffs = try cutoff.map { try handoffIDs(where: "time < ?", [.real($0.timeIntervalSince1970)]) } ?? []
        try transaction {
            if let cutoff {
                try query("SELECT DISTINCT space, page FROM visits WHERE time < ?", [.real(cutoff.timeIntervalSince1970)]) { row in
                    if let space = UUID(uuidString: row.text(0)) { touched.insert(PageID(space: space, key: row.text(1))) }
                }
                try run("DELETE FROM visits WHERE time < ?", [.real(cutoff.timeIntervalSince1970)])
                for id in handoffs { try run("DELETE FROM handoffs WHERE id = ?", [.text(id.uuidString)]) }
            }
            try run("DELETE FROM removals WHERE made < ?", [.real(now.addingTimeInterval(-400 * 86_400).timeIntervalSince1970)])
            try query("SELECT space, page FROM pages", []) { row in
                if let space = UUID(uuidString: row.text(0)) { touched.insert(PageID(space: space, key: row.text(1))) }
            }
            for page in touched { try refresh(page, now: now) }
        }
        removeKept(handoffs)
        (removals, unreadableRemovals) = try Self.loadRemovals(db)
        revision += 1
    }

    // MARK: Pages' counts and index

    private struct PageID: Hashable {
        let space: UUID
        let key: String
    }

    /// A page's count, last visit and frecency from its visits; gone when it has none.
    private func refresh(_ page: PageID, now: Date) throws {
        var count = 0
        var last = 0.0
        try query("SELECT COUNT(*), MAX(time) FROM visits WHERE space = ? AND page = ?", [.text(page.space.uuidString), .text(page.key)]) { row in
            count = row.int(0)
            last = row.real(1)
        }
        guard count > 0 else {
            try run("DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages WHERE space = ? AND page = ?)",
                    [.text(page.space.uuidString), .text(page.key)])
            try run("DELETE FROM pages WHERE space = ? AND page = ?", [.text(page.space.uuidString), .text(page.key)])
            return
        }
        var recent: [(time: Date, kind: HistoryKind)] = []
        var address: String?
        try query("SELECT time, kind, url FROM visits WHERE space = ? AND page = ? ORDER BY time DESC LIMIT 10",
                  [.text(page.space.uuidString), .text(page.key)]) { row in
            recent.append((Date(timeIntervalSince1970: row.real(0)), HistoryKind(rawValue: row.text(1)) ?? .other))
            if address == nil { address = row.text(2) }
        }
        // The words of the last search typed that went here, of the visits
        // still kept: a cleared one takes its words with it.
        var search: String?
        try query("SELECT search FROM visits WHERE space = ? AND page = ? AND search IS NOT NULL ORDER BY time DESC LIMIT 1",
                  [.text(page.space.uuidString), .text(page.key)]) { search = $0.optionalText(0) }
        try run("UPDATE pages SET count = ?, last = ?, frecency = ?, url = COALESCE(?, url), search = ? WHERE space = ? AND page = ?",
                [.int(count), .real(last), .real(History.frecency(recent: recent, count: count, now: now)),
                 address.map { .text($0) } ?? .null, search.map { .text($0) } ?? .null,
                 .text(page.space.uuidString), .text(page.key)])
        try index(page)
    }

    /// The page's searchable text, again.
    private func index(_ page: PageID) throws {
        var row: (Int, String, String, String)?
        try query("SELECT rowid, title, url, summary FROM pages WHERE space = ? AND page = ?", [.text(page.space.uuidString), .text(page.key)]) {
            row = ($0.int(0), $0.text(1), $0.text(2), $0.text(3))
        }
        guard let (id, title, address, summary) = row else { return }
        try run("DELETE FROM pages_fts WHERE rowid = ?", [.int(id)])
        try run("INSERT INTO pages_fts(rowid, title, words, summary) VALUES (?, ?, ?, ?)",
                [.int(id), .text(History.searchable(title)), .text(History.searchable(Self.words(of: address))),
                 .text(History.searchable(summary))])
    }

    /// An address as words: its host without www., and its path, query and fragment as they read.
    private static func words(of address: String) -> String {
        guard let url = URL(string: address), let host = url.host() else { return address }
        let rest = (url.path(percentEncoded: false) + " " + (url.query(percentEncoded: false) ?? "") + " "
                    + (url.fragment(percentEncoded: false) ?? ""))
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        return host + " " + String(rest).split(separator: " ").joined(separator: " ")
    }

    private static func page(_ row: Row) -> HistoryPage? {
        guard let space = UUID(uuidString: row.text(0)), let url = URL(string: row.text(2)) else { return nil }
        return HistoryPage(space: space, key: row.text(1), url: url, title: row.text(3), summary: row.text(4),
                           last: Date(timeIntervalSince1970: row.real(5)), count: row.int(6), frecency: row.real(7),
                           search: row.optionalText(8))
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: SQLite

    private static func prepare(_ db: OpaquePointer) throws {
        let schema = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS visits (
                id TEXT PRIMARY KEY, space TEXT NOT NULL, page TEXT NOT NULL, url TEXT NOT NULL, time REAL NOT NULL,
                device TEXT NOT NULL, kind TEXT NOT NULL, search TEXT);
            CREATE INDEX IF NOT EXISTS visits_by_time ON visits(space, time);
            CREATE INDEX IF NOT EXISTS visits_by_page ON visits(space, page);
            CREATE INDEX IF NOT EXISTS visits_by_device ON visits(device, time);
            CREATE TABLE IF NOT EXISTS pages (
                space TEXT NOT NULL, page TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
                summary TEXT NOT NULL DEFAULT '', last REAL NOT NULL, count INTEGER NOT NULL, frecency REAL NOT NULL,
                search TEXT, embedding BLOB, embedding_model TEXT, UNIQUE(space, page));
            CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(title, words, summary, tokenize = 'trigram');
            CREATE TABLE IF NOT EXISTS removals (id TEXT PRIMARY KEY, space TEXT, scope TEXT NOT NULL, made REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_state (name TEXT PRIMARY KEY, value BLOB);
            CREATE TABLE IF NOT EXISTS handoffs (
                id TEXT PRIMARY KEY, space TEXT NOT NULL, title TEXT NOT NULL, address TEXT, time REAL NOT NULL,
                file TEXT NOT NULL, words TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS handoffs_by_time ON handoffs(space, time);
            """
        try exec(db, schema)
        // 2: each visit's sync-clock stamp, apart from its time
        // (HistoryVisit.stamp). 3: each clearing's own wall-clock time
        // (HistoryRemoval.wall). Each in one transaction, and only where
        // missing, so a stop halfway can't leave one to be added twice.
        let version = try Statement(db, "PRAGMA user_version")
        let at = try version.step() ? Row(statement: version).int(0) : 0
        for (number, table, column) in [(2, "visits", "stamp"), (3, "removals", "wall")] where at < number {
            var columns: Set<String> = []
            let info = try Statement(db, "PRAGMA table_info(\(table))")
            while try info.step() { columns.insert(Row(statement: info).text(1)) }
            let add = columns.contains(column) ? "" : "ALTER TABLE \(table) ADD COLUMN \(column) REAL; "
            try exec(db, "BEGIN; \(add)PRAGMA user_version = \(number); COMMIT;")
        }
        // Columns a build of 23 October 2026 wrote for history sync and nothing
        // reads now (every visit of this device's goes, by device); left as
        // they are, since a store that has them keeps them.
        if at < 4 {
            var columns: Set<String> = []
            let info = try Statement(db, "PRAGMA table_info(visits)")
            while try info.step() { columns.insert(Row(statement: info).text(1)) }
            let add = ["sync_epoch", "sync_title", "sync_summary"].filter { !columns.contains($0) }
                .map { "ALTER TABLE visits ADD COLUMN \($0) TEXT;" }.joined(separator: " ")
            try exec(db, "BEGIN; \(add) CREATE INDEX IF NOT EXISTS visits_by_sync_epoch ON visits(sync_epoch, device, space, time); PRAGMA user_version = 4; COMMIT;")
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "schema"
            sqlite3_free(error)
            throw HistoryStoreError.sqlite(message)
        }
    }

    /// The clearings kept, and how many rows can't be read as one.
    private static func loadRemovals(_ db: OpaquePointer) throws -> (removals: [HistoryRemoval], unreadable: Int) {
        var removals: [HistoryRemoval] = []
        var unreadable = 0
        let statement = try Statement(db, "SELECT id, space, scope, made, wall FROM removals")
        while try statement.step() {
            let row = Row(statement: statement)
            guard let id = UUID(uuidString: row.text(0)),
                  let scope = try? JSONDecoder().decode(HistoryRemoval.Scope.self, from: Data(row.text(2).utf8))
            else {
                unreadable += 1
                continue
            }
            removals.append(HistoryRemoval(id: id, space: row.optionalText(1).flatMap(UUID.init(uuidString:)), scope: scope,
                                           made: Date(timeIntervalSince1970: row.real(3)),
                                           wall: row.optionalReal(4).map(Date.init(timeIntervalSince1970:))))
        }
        #if canImport(os)
        if unreadable > 0 {
            historyLog.error("\(unreadable) history clearings can't be read and are left out; what they cleared can come back")
        }
        #endif
        return (removals, unreadable)
    }

    private enum Value {
        case text(String)
        case real(Double)
        case int(Int)
        case blob(Data)
        case null
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try Statement(db, sql)
        try statement.bind(values)
        _ = try statement.step()
    }

    private func query(_ sql: String, _ values: [Value], _ each: (Row) -> Void) throws {
        let statement = try Statement(db, sql)
        try statement.bind(values)
        while try statement.step() { each(Row(statement: statement)) }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE", [])
        do {
            try body()
            try run("COMMIT", [])
        } catch {
            // Some failures (a full disk, for one) end the transaction themselves.
            guard sqlite3_get_autocommit(db) == 0 else { throw error }
            do {
                try run("ROLLBACK", [])
            } catch let rollback {
                throw HistoryStoreError.rollbackFailed(change: error, rollback: rollback)
            }
            throw error
        }
    }

    private final class Statement {
        let handle: OpaquePointer
        let db: OpaquePointer
        /// SQLite copies text bound with this, rather than keeping a pointer that Swift may free.
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(_ db: OpaquePointer, _ sql: String) throws {
            self.db = db
            var handle: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
                throw HistoryStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            self.handle = handle
        }

        deinit {
            sqlite3_finalize(handle)
        }

        func bind(_ values: [Value]) throws {
            for (i, value) in values.enumerated() {
                let index = Int32(i + 1)
                let result: Int32
                switch value {
                case .text(let text): result = sqlite3_bind_text(handle, index, text, -1, Self.transient)
                case .real(let number): result = sqlite3_bind_double(handle, index, number)
                case .int(let number): result = sqlite3_bind_int64(handle, index, Int64(number))
                case .blob(let data):
                    result = data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), Self.transient) }
                case .null: result = sqlite3_bind_null(handle, index)
                }
                guard result == SQLITE_OK else { throw HistoryStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            }
        }

        /// A row to read (true), or the end (false).
        func step() throws -> Bool {
            switch sqlite3_step(handle) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw HistoryStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private struct Row {
        let statement: Statement

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement.handle, column).map { String(cString: $0) } ?? ""
        }

        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement.handle, column) == SQLITE_NULL ? nil : text(column)
        }

        func real(_ column: Int32) -> Double {
            sqlite3_column_double(statement.handle, column)
        }

        func optionalReal(_ column: Int32) -> Double? {
            sqlite3_column_type(statement.handle, column) == SQLITE_NULL ? nil : real(column)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement.handle, column))
        }

        func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement.handle, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement.handle, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }
}
#endif
