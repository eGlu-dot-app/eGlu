import Combine
import PadCore
import WebEngineCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Ads and trackers, blocked by WebKit's own content blocker with the filter
/// lists turned on in Settings (FilterLists.swift in PadCore). EasyList,
/// EasyPrivacy and YousList ship with the app; the others are downloaded
/// from their authors when they are first turned on. All are downloaded
/// again when they say they are stale, four days at the soonest. The app
/// turns them into WebKit's rules and WebKit compiles them into rule lists,
/// kept on disk until the lists change. Every page but a hands-off one gets
/// them (PageBlocking), unless Settings or the site's own switch says
/// no, and WebKit decides each load itself.
///
/// What a site's filters ask for that WebKit's rules can't do is kept here
/// too, by site (ScriptedTable), for the script a page on that site is given
/// (Page.prepare). A page on any other site gets no script.
@MainActor
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    /// The compiled lists, in the order a page gets them.
    private(set) var lists: [any WebRuleList] = []
    /// The filters for the script in a site's pages.
    private(set) var scripted = ScriptedTable()
    /// What Settings and Diagnostics say about it.
    @Published private(set) var summary = String(localized: "Getting the lists ready…")
    /// The rules WebKit has, and the rule lists it turned down. Nil until the lists are ready.
    @Published private(set) var shown: Shown?
    /// Each filter list as Settings shows it, by its id.
    @Published private(set) var states: [String: ListState] = [:]

    struct Shown: Equatable {
        var rules: Int
        var dropped: Int
    }

    enum ListState: Equatable {
        case off
        /// On, and being downloaded or made into rules.
        case waiting
        /// On, with no copy of it yet: no network when it was asked for.
        case missing
        case ready(made: Date?, rules: Int)
    }

    private let store: (any WebRuleListStore)? = ContentBlocker.makeRuleStore()
    private var saved = Saved()
    private var building = false
    /// The lists the build now running is making rules from, by id.
    private var buildingFrom: [String]?
    /// Newer lists arrived while a build ran: one more build when it ends.
    private var buildAgain = false
    /// Settings changed while a build ran: one more build when it ends, if
    /// the lists turned on then are not the ones it made rules from.
    private var lookAgain = false
    private var checking = false
    private var started = false
    private var observer: AnyCancellable?
    /// When a list with no copy was last asked for, so a device with no
    /// network isn't asking each time the app comes to the front.
    private var askedForMissing: Date?
    /// Each list's stamp as a date, read once: reading one makes a date
    /// formatter, and every list's is asked for whenever any list's state changes.
    private var dates: [String: Date?] = [:]

    private struct Saved: Codable {
        /// The compiled lists' identifiers, in order.
        var identifiers: [String] = []
        /// The filter lists they were made from, in order, and each one's
        /// stamp (FilterRules.stamp) and rules; and the converter that made them.
        var used: [String] = []
        var versions: [String: String] = [:]
        var counts: [String: Int] = [:]
        var converter = 0
        var rules = 0
        /// Rule lists WebKit turned down, left out.
        var dropped = 0
        /// When the lists were last asked for, and what their server said they were.
        var checked: Date?
        var expires: TimeInterval?
        var etags: [String: String] = [:]
        var modified: [String: String] = [:]

        init() {}

        /// Every field by itself, so a file saved before one was added still reads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            identifiers = (try? c.decodeIfPresent([String].self, forKey: .identifiers)) ?? []
            used = (try? c.decodeIfPresent([String].self, forKey: .used)) ?? []
            versions = (try? c.decodeIfPresent([String: String].self, forKey: .versions)) ?? [:]
            counts = (try? c.decodeIfPresent([String: Int].self, forKey: .counts)) ?? [:]
            converter = (try? c.decodeIfPresent(Int.self, forKey: .converter)) ?? 0
            rules = (try? c.decodeIfPresent(Int.self, forKey: .rules)) ?? 0
            dropped = (try? c.decodeIfPresent(Int.self, forKey: .dropped)) ?? 0
            checked = try? c.decodeIfPresent(Date.self, forKey: .checked)
            expires = try? c.decodeIfPresent(TimeInterval.self, forKey: .expires)
            etags = (try? c.decodeIfPresent([String: String].self, forKey: .etags)) ?? [:]
            modified = (try? c.decodeIfPresent([String: String].self, forKey: .modified)) ?? [:]
        }
    }

    private static var folder: URL {
        Session.folder.appendingPathComponent("Filters", isDirectory: true)
    }

    private static var savedFile: URL {
        folder.appendingPathComponent("lists.json")
    }

    /// The scripted filters of the lists compiled last, read at launch
    /// rather than made again from the lists' megabytes.
    private static var scriptedFile: URL {
        folder.appendingPathComponent("scripted.json")
    }

    nonisolated private static func downloaded(_ list: FilterList) -> URL {
        Session.folder.appendingPathComponent("Filters", isDirectory: true).appendingPathComponent("\(list.id).txt")
    }

    /// The device's languages and region, which say which regional lists start out on.
    static var languages: [String] {
        ContentBlocking.languages(of: Locale.preferredLanguages)
    }

    static var region: String? {
        Locale.current.region?.identifier
    }

    /// The lists turned on, in the catalogue's order.
    private var wanted: [FilterList] {
        Session.shared.preferences.filterLists(languages: Self.languages, region: Self.region)
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        // Who is asking, as list maintainers ask apps to say.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        configuration.httpAdditionalHeaders = ["User-Agent": "eGlu/\(version) (filter list update; +https://github.com/eGlu-dot-app/eGlu)"]
        return URLSession(configuration: configuration)
    }()

    /// The app coming to the front, on the iPad and on the Mac.
    #if os(macOS)
    private static let becameActive = NSApplication.didBecomeActiveNotification
    #else
    private static let becameActive = UIApplication.didBecomeActiveNotification
    #endif

    // MARK: Starting

    /// At launch, and when Settings turns blocking on: the lists compiled
    /// last time if WebKit still has them, made again otherwise; then a look
    /// for newer ones if they are due.
    func start() {
        guard Session.shared.preferences.blocksContent, !started else { return }
        started = true
        if let data = try? Data(contentsOf: Self.savedFile), let read = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = read
        }
        observer = NotificationCenter.default.publisher(for: Self.becameActive)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.checkIfDue() } }
        publishStates()
        Task {
            // Compiled lists are kept only while they are what the lists
            // turned on, as they are on disk, and this converter would make:
            // a download that came in as the app quit, a list turned on or
            // off, or a new converter, makes them again.
            let lists = wanted
            // Read from the lists' files, away from the main thread: this is launch.
            let onDisk = await Task.detached(priority: .userInitiated) { Self.versionsOnDisk(lists) }.value
            if saved.converter == ContentBlocking.converterVersion, saved.used == lists.map(\.id),
               saved.versions == onDisk, await lookUpSaved() {
                let file = Self.scriptedFile
                scripted = await Task.detached(priority: .utility) {
                    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ScriptedTable.self, from: $0) } ?? ScriptedTable()
                }.value
                announce()
            } else {
                // Nothing compiled yet (a first launch, most often). The
                // lists take seconds to make, and WebKit reads each one's
                // rules on the main thread before it compiles them, so the
                // making waits for the window to be up and still.
                try? await Task.sleep(for: .seconds(1))
                // Never asked for newer lists: asked before any are made, so
                // they are made once, from the newest, rather than from the
                // ones that shipped and again a moment later. Lists with no
                // copy yet (turned on by an update, or by the device's
                // language) are asked for first too. Offline, or with a
                // server that doesn't answer soon, the ones that shipped do.
                if saved.checked == nil {
                    _ = await fetch(lists, patience: 6)
                } else {
                    _ = await fetch(lists.filter(Self.hasNoCopy), patience: 6)
                }
                await build()
            }
            checkIfDue()
        }
    }

    nonisolated private static func hasNoCopy(_ list: FilterList) -> Bool {
        !list.bundled && !FileManager.default.fileExists(atPath: downloaded(list).path)
    }

    /// Each list's stamp as the text on disk has it, downloaded or as it
    /// shipped: from its first lines alone, not the megabytes after them.
    nonisolated private static func versionsOnDisk(_ lists: [FilterList]) -> [String: String] {
        var out: [String: String] = [:]
        for list in lists {
            let fetched = downloaded(list)
            let file = FileManager.default.fileExists(atPath: fetched.path) ? fetched : (list.bundled ? ContentBlocking.bundledFile(list) : nil)
            var head = ""
            if let file, let handle = try? FileHandle(forReadingFrom: file) {
                head = String(decoding: (try? handle.read(upToCount: 4_000)) ?? Data(), as: UTF8.self)
                try? handle.close()
            }
            // Its header's whole lines and nothing else: the last line read
            // may be cut short, and a filter after the header is no part of it.
            let lines = head.split(whereSeparator: \.isNewline).dropLast()
                .prefix { $0.hasPrefix("!") || $0.hasPrefix("[") }
            out[list.id] = FilterConverter.convert(lines.joined(separator: "\n")).stamp
        }
        return out
    }

    private func lookUpSaved() async -> Bool {
        guard let store else { return false }
        // Made from no lists at all (every one turned off): nothing to look up, and nothing missing.
        if saved.identifiers.isEmpty { return saved.used.isEmpty }
        var found: [any WebRuleList] = []
        for id in saved.identifiers {
            guard let list = await withCheckedContinuation({ (done: CheckedContinuation<(any WebRuleList)?, Never>) in
                store.lookUp(forIdentifier: id) { list, _ in done.resume(returning: list) }
            }) else { return false }
            found.append(list)
        }
        lists = found
        return true
    }

    // MARK: Making the rule lists

    /// What the lists' texts come to, made away from the main thread.
    private struct Made: Sendable {
        var plan: RulePlan
        var table: ScriptedTable
        var stamps: [String]
        var counts: [Int]
        var expires: TimeInterval?
    }

    /// The lists' texts (downloaded, or as they shipped) turned into rules
    /// away from the main thread, then compiled by WebKit one rule list at a
    /// time. A rule list WebKit turns down is left out; the others still block.
    ///
    /// Memory is what this is shaped by: all the lists' rules in memory at
    /// once, as objects and again as one text, took the app to some 300 MB
    /// for the seconds it lasted. So each list is read, turned into rules and
    /// written out as text one after the other (RulePlanner), each rule list's
    /// text is put together only as WebKit is given it, and blocking goes to
    /// WebKit in lists small enough to compile in a third of that
    /// (ContentBlocking.networkPerList).
    ///
    /// `onlyIfChanged` is for Settings, where a list turned on and off again
    /// asks twice for what is already there: nothing is made when the rules
    /// WebKit has were made from the lists turned on. Lists that arrived are
    /// always made into rules.
    private func build(onlyIfChanged: Bool = false) async {
        guard let store else { return }
        guard !building else {
            if onlyIfChanged { lookAgain = true } else { buildAgain = true }
            return
        }
        if onlyIfChanged, saved.converter == ContentBlocking.converterVersion, saved.used == wanted.map(\.id),
           !lists.isEmpty || saved.identifiers.isEmpty {
            publishStates()
            return
        }
        building = true
        defer {
            building = false
            buildingFrom = nil
            let again = buildAgain || (lookAgain && saved.used != wanted.map(\.id))
            buildAgain = false
            lookAgain = false
            if again {
                Task { await build() }
            } else {
                publishStates()
            }
        }
        summary = String(localized: "Getting the lists ready…")
        shown = nil
        let used = wanted
        buildingFrom = used.map(\.id)
        publishStates()
        let scriptedFile = Self.scriptedFile
        let made = await Task.detached(priority: .utility) { () -> Made in
            var planner = RulePlanner()
            for list in used {
                // Each list's text is let go before the next is read.
                autoreleasepool {
                    let text = (try? String(contentsOf: Self.downloaded(list), encoding: .utf8))
                        ?? (list.bundled ? ContentBlocking.bundled(list) : nil) ?? ""
                    FilterConverter.convert(text, into: &planner)
                }
            }
            let table = ScriptedTable(planner.scripted)
            if let data = try? JSONEncoder().encode(table) {
                try? FileManager.default.createDirectory(at: scriptedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: scriptedFile, options: .atomic)
            }
            return Made(plan: planner.plan(), table: table, stamps: planner.stamps, counts: planner.kept, expires: planner.expires)
        }.value
        var compiled: [any WebRuleList] = []
        var rules = 0
        var dropped = 0
        for index in made.plan.entries.indices {
            let planned = await Task.detached(priority: .utility) { made.plan.list(index) }.value
            let list = await withCheckedContinuation { (done: CheckedContinuation<(any WebRuleList)?, Never>) in
                store.compile(forIdentifier: planned.id, encodedRules: planned.json) { list, _ in
                    done.resume(returning: list)
                }
            }
            if let list {
                compiled.append(list)
                rules += planned.rules
            } else {
                dropped += 1
            }
        }
        lists = compiled
        scripted = made.table
        saved.identifiers = compiled.map(\.identifier)
        saved.used = used.map(\.id)
        // The lists' own rules, each once: the rule lists hold more, since
        // every list of blocking ends with the exceptions again.
        saved.rules = dropped == 0 ? made.counts.reduce(0, +) : rules
        saved.dropped = dropped
        // A list with neither a version nor a date reads as "" from its file (versionsOnDisk).
        saved.versions = Dictionary(uniqueKeysWithValues: zip(used.map(\.id), made.stamps.map { $0 == "?" ? "" : $0 }))
        saved.counts = Dictionary(uniqueKeysWithValues: zip(used.map(\.id), made.counts))
        saved.expires = made.expires
        saved.converter = ContentBlocking.converterVersion
        save()
        removeOld(keeping: Set(saved.identifiers))
        announce()
    }

    /// Lists compiled from older versions, gone from the disk.
    private func removeOld(keeping: Set<String>) {
        guard let store else { return }
        store.removeOld(withPrefix: "blocking.", keeping: keeping)
    }

    /// Every page takes the new lists for its next load; Settings and
    /// Diagnostics say what there is.
    private func announce() {
        summary = Self.describe(saved)
        shown = Shown(rules: saved.rules, dropped: saved.dropped)
        publishStates()
        for page in Session.shared.pages.live.values { page.blockingChanged() }
    }

    /// Each list as Settings shows it: off, on its way, or what it came to.
    private func publishStates() {
        let on = Set(wanted.map(\.id))
        var out: [String: ListState] = [:]
        for list in ContentBlocking.lists {
            if !on.contains(list.id) {
                out[list.id] = .off
            } else if saved.used.contains(list.id), let count = saved.counts[list.id], count > 0, !buildAgain {
                out[list.id] = .ready(made: saved.versions[list.id].flatMap { date(ofStamp: $0) }, rules: count)
            } else if building || checking {
                out[list.id] = .waiting
            } else {
                out[list.id] = Self.hasNoCopy(list) ? .missing : .waiting
            }
        }
        if out != states { states = out }
    }

    private static func describe(_ saved: Saved) -> String {
        let rules = saved.rules.formatted(.number)
        guard saved.dropped > 0 else { return String(localized: "\(rules) rules from \(saved.used.count) lists") }
        return String(localized: "\(rules) rules from \(saved.used.count) lists; \(saved.dropped) rule lists couldn't be used")
    }

    /// When a list was made, from its "! Version:" ("202610080509", or
    /// YousList's "20260922") or its "! Last modified:" ("12 Oct 2026 13:42
    /// UTC", "2026-10-12 11:50 UTC"), in UTC.
    private func date(ofStamp stamp: String) -> Date? {
        if let known = dates[stamp] { return known }
        let read = Self.read(stamp: stamp)
        dates[stamp] = .some(read)
        return read
    }

    private static func read(stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let text = stamp.replacingOccurrences(of: " UTC", with: "")
        for format in ["yyyyMMddHHmm", "yyyyMMdd", "dd MMM yyyy HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.savedFile, options: .atomic)
    }

    // MARK: Newer lists

    /// Asks for newer lists when the ones there have expired: as often as
    /// they say, never sooner than four days. A list comes only if it
    /// changed (If-None-Match, If-Modified-Since), and only a real one is
    /// kept: what doesn't read as that list leaves the old one in place. A
    /// list turned on with no network is asked for again here, ten minutes
    /// apart at the soonest.
    func checkIfDue() {
        guard started, Session.shared.preferences.blocksContent, !checking else { return }
        let lists = wanted
        let wait = max(saved.expires ?? 0, ContentBlocking.shortestRefresh)
        if let checked = saved.checked, Date().timeIntervalSince(checked) < wait {
            let missing = lists.filter(Self.hasNoCopy)
            guard !missing.isEmpty, askedForMissing.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
            askedForMissing = Date()
            Task {
                if await fetch(missing) { await build() }
            }
            return
        }
        Task {
            if await fetch(lists, stamping: true) { await build() }
        }
    }

    /// Asks each list's server for it and keeps the ones that changed; true
    /// when any did. `patience` is how long a silent server is waited for,
    /// in seconds, where something is waiting on the answer. `stamping`
    /// says this was the regular look for newer lists, which the next one
    /// counts from.
    private func fetch(_ lists: [FilterList], patience: TimeInterval? = nil, stamping: Bool = false) async -> Bool {
        guard !lists.isEmpty, !checking else { return false }
        checking = true
        publishStates()
        defer {
            checking = false
            publishStates()
        }
        struct Got: Sendable {
            var id: String
            var kept = false
            var etag: String?
            var modified: String?
        }
        // At once rather than in turn: a server that doesn't answer holds
        // up only its own list.
        let session = session
        let etags = saved.etags
        let modified = saved.modified
        let results = await withTaskGroup(of: Got?.self) { group -> [Got] in
            for list in lists {
                group.addTask {
                    var request = URLRequest(url: list.url)
                    if let patience { request.timeoutInterval = patience }
                    // Only for a copy that is there: a list whose file is gone is asked for whole.
                    if FileManager.default.fileExists(atPath: Self.downloaded(list).path) {
                        if let etag = etags[list.id] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                        if let since = modified[list.id] { request.setValue(since, forHTTPHeaderField: "If-Modified-Since") }
                    }
                    guard let (data, response) = try? await session.data(for: request),
                          let http = response as? HTTPURLResponse else { return nil }
                    var got = Got(id: list.id)
                    // Megabytes of text: checked and written away from the main thread.
                    guard http.statusCode == 200, let text = String(data: data, encoding: .utf8),
                          Self.isList(text, list) else { return got }
                    let file = Self.downloaded(list)
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return got }
                    got.kept = true
                    got.etag = http.value(forHTTPHeaderField: "ETag")
                    got.modified = http.value(forHTTPHeaderField: "Last-Modified")
                    return got
                }
            }
            var out: [Got] = []
            for await got in group { if let got { out.append(got) } }
            return out
        }
        for got in results where got.kept {
            saved.etags[got.id] = got.etag
            saved.modified[got.id] = got.modified
        }
        // Offline: asked again next time the app comes up, not in four days.
        guard !results.isEmpty else { return false }
        if stamping || saved.checked == nil { saved.checked = Date() }
        save()
        return results.contains(where: \.kept)
    }

    /// A filter list, not an error page or half a download: the header
    /// Adblock Plus lists start with, its own title, and enough of it.
    nonisolated private static func isList(_ text: String, _ list: FilterList) -> Bool {
        text.hasPrefix("[Adblock Plus") && text.prefix(2_000).contains("! Title: \(list.title)")
            && text.utf8.count > list.leastSize
    }

    // MARK: Settings

    /// Settings turned blocking on or off, or a list.
    func preferencesChanged() {
        guard Session.shared.preferences.blocksContent else {
            summary = String(localized: "Off")
            return
        }
        guard started else {
            start()
            return
        }
        let lists = wanted
        // Against the lists a build now running is making rules from, where
        // there is one: a list turned off and on again while it runs would
        // otherwise look done, and be left out when the build ends.
        if (buildingFrom ?? saved.used) != lists.map(\.id) {
            // A list turned on is downloaded if there is no copy of it, then
            // the rules are made again with it, or without the one turned off.
            Task {
                // After a look for newer lists that is under way, which
                // would turn this one away (fetch).
                while checking { try? await Task.sleep(for: .milliseconds(200)) }
                let arrived = await fetch(wanted.filter(Self.hasNoCopy), patience: 20)
                await build(onlyIfChanged: !arrived)
            }
        }
        summary = self.lists.isEmpty ? String(localized: "Getting the lists ready…") : Self.describe(saved)
        shown = self.lists.isEmpty ? nil : Shown(rules: saved.rules, dropped: saved.dropped)
        publishStates()
    }

    /// What a page at `url` is given to hide and to run, beyond WebKit's
    /// rules: nothing on most sites.
    func scriptedRules(for url: URL?) -> PageRules {
        guard Session.shared.preferences.blocksContent, !lists.isEmpty else { return PageRules() }
        return scripted.rules(forHost: url?.host)
    }

    /// For Diagnostics.
    var status: String {
        guard Session.shared.preferences.blocksContent else { return "off in Settings" }
        if building { return "compiling the lists" }
        return "\(lists.count) rule lists, \(Self.describe(saved)), \(scripted.count) filters for scripts"
    }
}
