import Foundation

/// Ads and trackers, blocked by WebKit's own content blocker: filter lists in
/// Adblock Plus's syntax (FilterLists.swift) turned into the JSON rules a
/// WKContentRuleList compiles. WebKit does the blocking itself, before a
/// request is made and in its own processes.
///
/// WebKit's rules say less than the lists do. A url-filter is a regular
/// expression without alternatives (a|b), counted repeats (a{2}) or classes
/// (\d), in ASCII only; a trigger has if-domain or unless-domain, never both;
/// an exception (ignore-previous-rules) undoes only the rules before it in its
/// own list; and a selector WebKit can't parse takes the rule it is in with
/// it, without a word. So a filter WebKit can't say exactly is left out
/// rather than said loosely, and hiding goes in lists of its own, apart from
/// blocking (RulePlanner). What a site's own filters ask for beyond that is
/// done by a script in that site's pages (ScriptedFilters.swift).
public struct BlockingRule: Encodable, Equatable, Sendable {
    public struct Trigger: Encodable, Equatable, Sendable {
        public var urlFilter: String
        public var caseSensitive: Bool?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var loadContext: [String]?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?

        public init(urlFilter: String = ".*", caseSensitive: Bool? = nil, resourceType: [String]? = nil,
                    loadType: [String]? = nil, loadContext: [String]? = nil, ifDomain: [String]? = nil,
                    unlessDomain: [String]? = nil) {
            self.urlFilter = urlFilter
            self.caseSensitive = caseSensitive
            self.resourceType = resourceType
            self.loadType = loadType
            self.loadContext = loadContext
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
        }

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case caseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    public struct Action: Encodable, Equatable, Sendable {
        public var type: String
        public var selector: String?

        public static let block = Action(type: "block")
        public static let allow = Action(type: "ignore-previous-rules")
        public static func hide(_ selector: String) -> Action { Action(type: "css-display-none", selector: selector) }
    }

    public var trigger: Trigger
    public var action: Action
    /// The host the filter was tied to ("||ads.test^…"), when it was: the
    /// rule can match only addresses on that host or under it. Not part of
    /// what WebKit reads; RulePlanner sorts rules into lists by it.
    public var site: String?

    public init(trigger: Trigger, action: Action, site: String? = nil) {
        self.trigger = trigger
        self.action = action
        self.site = site
    }

    enum CodingKeys: String, CodingKey {
        case trigger, action
    }

    /// The rule as WebKit reads it, added to `out`. Written by hand: asked
    /// for a hundred thousand rules, JSONEncoder builds an object for every
    /// rule and every value in it first, some 180 MB for a moment (measured),
    /// where the text itself is 15.
    func write(to out: inout String) {
        out += "{\"trigger\":{\"url-filter\":"
        Self.write(trigger.urlFilter, to: &out)
        if let sensitive = trigger.caseSensitive { out += ",\"url-filter-is-case-sensitive\":\(sensitive)" }
        Self.write(trigger.resourceType, as: "resource-type", to: &out)
        Self.write(trigger.loadType, as: "load-type", to: &out)
        Self.write(trigger.loadContext, as: "load-context", to: &out)
        Self.write(trigger.ifDomain, as: "if-domain", to: &out)
        Self.write(trigger.unlessDomain, as: "unless-domain", to: &out)
        out += "},\"action\":{\"type\":"
        Self.write(action.type, to: &out)
        if let selector = action.selector {
            out += ",\"selector\":"
            Self.write(selector, to: &out)
        }
        out += "}}"
    }

    private static func write(_ values: [String]?, as key: String, to out: inout String) {
        guard let values else { return }
        out += ",\"\(key)\":["
        for (index, value) in values.enumerated() {
            if index > 0 { out += "," }
            write(value, to: &out)
        }
        out += "]"
    }

    /// A JSON string: quotes, backslashes and control characters escaped,
    /// everything else as it is.
    private static func write(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// One filter list, converted.
public struct FilterRules: Equatable, Sendable {
    /// Blocking, then the exceptions to it, then the blocking marked
    /// $important, which exceptions don't undo: the order a list needs.
    public var blocks: [BlockingRule] = []
    public var exceptions: [BlockingRule] = []
    public var important: [BlockingRule] = []
    /// Windows a page opens to an advertiser ("$popup"): blocked by the same
    /// rules, in a list of their own (RulePlanner).
    public var popups: [BlockingRule] = []
    /// Element hiding (css-display-none), already grouped.
    public var hiding: [BlockingRule] = []
    /// What only a script in the page can do, for the sites that have any (ScriptedFilters.swift).
    public var scripted: [ScriptedFilter] = []
    /// Filters neither can say exactly, and so left out.
    public var skipped = 0
    /// The list's "! Version:" and "! Last modified:", and how long it says
    /// it stays fresh ("! Expires:").
    public var version: String?
    public var modified: String?
    public var expires: TimeInterval?

    public init() {}

    public var network: [BlockingRule] { blocks + exceptions + important }
    public var count: Int {
        blocks.count + exceptions.count + important.count + popups.count + hiding.count + scripted.count
    }
    /// What tells one copy of the list from the next: its version, or when
    /// it was last changed where it gives no version (EasyList Cookie List).
    public var stamp: String { version ?? modified ?? "" }
}

/// Whoever takes a list's rules as FilterConverter reads them.
public protocol FilterSink {
    mutating func block(_ rule: BlockingRule)
    mutating func except(_ rule: BlockingRule)
    mutating func important(_ rule: BlockingRule)
    mutating func popup(_ rule: BlockingRule)
    mutating func hide(_ rule: BlockingRule)
    mutating func script(_ filter: ScriptedFilter)
    /// A filter neither WebKit's rules nor the page's script can do.
    mutating func skip()
    /// The list is read: what its header said.
    mutating func finish(version: String?, modified: String?, expires: TimeInterval?)
}

extension FilterRules: FilterSink {
    public mutating func block(_ rule: BlockingRule) { blocks.append(rule) }
    public mutating func except(_ rule: BlockingRule) { exceptions.append(rule) }
    public mutating func important(_ rule: BlockingRule) { important.append(rule) }
    public mutating func popup(_ rule: BlockingRule) { popups.append(rule) }
    public mutating func hide(_ rule: BlockingRule) { hiding.append(rule) }
    public mutating func script(_ filter: ScriptedFilter) { scripted.append(filter) }
    public mutating func skip() { skipped += 1 }
    public mutating func finish(version: String?, modified: String?, expires: TimeInterval?) {
        self.version = version
        self.modified = modified
        self.expires = expires
    }
}

/// One rule list for WebKit to compile: its identifier, which changes when
/// what it holds does, its JSON, and how many rules it has.
public struct PlannedList: Equatable, Sendable {
    public let id: String
    public let json: String
    public let rules: Int
}

public enum ContentBlocking {
    /// Moves on when the conversion changes, so lists compiled by an older
    /// one are made again.
    public static let converterVersion = 3
    /// WebKit's limit for one list (an Apple engineer on the developer forums, thread 734111).
    public static let rulesPerList = 150_000
    /// Blocking in lists of at most this many rules, each ending with the
    /// exceptions that could apply to it. WebKit compiles a list in one go,
    /// in the app's own process, and the memory that takes grows with the
    /// list: with all 110,000 rules in one list the app's footprint peaked
    /// at 232 MB while it compiled, with lists of 20,000 at 145 MB, with
    /// lists of 10,000 at 117 MB (measured on a Mac, with the rules written
    /// straight to text as RulePlanner does; 283 MB before that). Smaller
    /// lists cost disk and time where each carries every exception again:
    /// 96 MB on disk and 9.5 s at 10,000, against 59 MB and 5 s for one
    /// list. So a list of rules tied to hosts carries only its own sites'
    /// exceptions (RulePlanner), which comes to 68 MB and 5.8 s.
    ///
    /// What is left of the peak, 87 to 110 MB on that Mac from one run to
    /// the next, is the lists' rules as text (40 MB) and the first list or
    /// two WebKit compiles, which take it 40 MB more and sometimes 100,
    /// whichever lists they are. Compiling in another order, or letting each
    /// list's text go once compiled, changed nothing that could be measured.
    public static let networkPerList = 10_000
    /// Hiding in lists of this many rules: a selector WebKit turns down then
    /// costs one of them, not all of the hiding.
    public static let hidingPerList = 1_000
    /// The least time between two downloads of a list, whatever it says.
    public static let shortestRefresh: TimeInterval = 4 * 24 * 60 * 60

    /// The list as it ships inside the app, for the first launch and for
    /// when no download has worked yet.
    public static func bundled(_ list: FilterList) -> String? {
        guard let url = bundledFile(list) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Where that list is, for whoever needs only its first lines.
    public static func bundledFile(_ list: FilterList) -> URL? {
        Bundle.module.url(forResource: list.id, withExtension: "txt", subdirectory: "Filters")
    }

    /// What WebKit compiles, list by list, for these lists (RulePlanner).
    public static func plan(_ converted: [FilterRules]) -> [PlannedList] {
        var planner = RulePlanner()
        for rules in converted { planner.add(rules) }
        return planner.lists()
    }

    /// All the lists' blocking, then all their exceptions, then $important,
    /// and last a rule that lets every page itself load: a filter blocks what
    /// a page loads, never the page you went to (Adblock Plus's own rule).
    public static func network(_ converted: [FilterRules]) -> [BlockingRule] {
        var rules = converted.flatMap(\.blocks) + converted.flatMap(\.exceptions) + converted.flatMap(\.important)
        guard !rules.isEmpty else { return [] }
        rules.append(pageItself)
        return rules
    }

    public static func json(_ rules: [BlockingRule]) -> String {
        var out = "["
        for (index, rule) in rules.enumerated() {
            if index > 0 { out += "," }
            rule.write(to: &out)
        }
        return out + "]"
    }

    /// The rule that lets every page itself load, which ends a list of blocking.
    static let pageItself = BlockingRule(trigger: .init(resourceType: ["document"], loadContext: ["top-frame"]), action: .allow)

    /// FNV-1a: the same everywhere and every run, unlike Hasher.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}

/// The lists' rules gathered into what WebKit compiles, one list after the
/// other, so that no more than one list's rules are in memory at a time: each
/// list's are written out as text as they come and then let go.
///
/// Blocking goes in lists of `ContentBlocking.networkPerList` at most, each
/// ending with the exceptions, then the blocking marked $important, then
/// the rule that lets a page itself load: an exception undoes only what is
/// before it in its own list, so each list of blocking carries its own.
///
/// Which exceptions a list needs depends on what it blocks. Nearly every
/// filter is tied to a host ("||ads.test^": that host and what is under it),
/// and an exception tied to one host and a block tied to another can match
/// the same address only if one host is inside the other. So blocking tied
/// to hosts goes in lists of its own, and each of those ends with only the
/// exceptions for its own sites (by a host's last two names, which takes in
/// more than it must where an ending has two, "co.kr", and never less) and
/// the few exceptions tied to no host. Blocking tied to no host ("/banner/ad.")
/// could match anywhere, and its lists end with every exception. With all
/// of them at every list's end, nine tenths of the exceptions WebKit
/// compiled were ones that could never apply.
/// Windows opened to advertisers ($popup) have a list of their own, so a
/// WebKit that didn't know that kind of load would turn down that list and
/// no other; it ends with the exceptions that are about windows ($popup)
/// or a whole site ($document), since to the lists an exception for
/// anything else never lets a window through. Hiding goes in lists of
/// `ContentBlocking.hidingPerList`.
public struct RulePlanner {
    /// Rules as text, joined by commas, and how many.
    private struct Piece {
        var json = ""
        var count = 0

        mutating func add(_ rule: BlockingRule) {
            if count > 0 { json += "," }
            rule.write(to: &json)
            count += 1
        }

        mutating func add(_ other: Piece) {
            guard other.count > 0 else { return }
            if count > 0 { json += "," }
            json += other.json
            count += other.count
        }
    }

    /// Blocking in pieces of this many rules, which the lists are filled with.
    static let pieceSize = 2_500

    /// Blocking that could match on any host, and blocking tied to a host
    /// with the sites (Self.key) each piece holds.
    private var anywhere: [Piece] = []
    private var tied: [Piece] = []
    private var tiedSites: [Set<String>] = []
    /// Every exception; the ones tied to no host; the rest by site.
    private var exceptions = Piece()
    private var loose = Piece()
    private var bySite: [String: Piece] = [:]
    private var important = Piece()
    private var popups = Piece()
    private var popupExceptions = Piece()
    private var hiding: [Piece] = []
    /// Every list's scripted filters (ScriptedTable).
    public private(set) var scripted: [ScriptedFilter] = []
    /// How long the freshest-wanting list says it keeps.
    public private(set) var expires: TimeInterval?

    /// How many rules were taken, and how many filters left out, list by list.
    public private(set) var kept: [Int] = []
    public private(set) var skipped: [Int] = []
    /// Each list's stamp (FilterRules.stamp), as its header gave it.
    public private(set) var stamps: [String] = []
    private var keptNow = 0
    private var skippedNow = 0

    public init() {}

    /// The site a host belongs to, near enough: its last two names.
    static func key(_ host: String) -> String {
        host.split(separator: ".").suffix(2).joined(separator: ".")
    }

    /// A list already converted, rule by rule.
    public mutating func add(_ rules: FilterRules) {
        for rule in rules.blocks { block(rule) }
        for rule in rules.exceptions { except(rule) }
        for rule in rules.important { important(rule) }
        for rule in rules.popups { popup(rule) }
        for rule in rules.hiding { hide(rule) }
        for filter in rules.scripted { script(filter) }
        skippedNow += rules.skipped
        finish(version: rules.version, modified: rules.modified, expires: rules.expires)
    }
}

extension RulePlanner: FilterSink {
    public mutating func block(_ rule: BlockingRule) {
        if let site = rule.site {
            if tied.last.map({ $0.count >= Self.pieceSize }) ?? true {
                tied.append(Piece())
                tiedSites.append([])
            }
            tied[tied.count - 1].add(rule)
            tiedSites[tiedSites.count - 1].insert(Self.key(site))
        } else {
            if anywhere.last.map({ $0.count >= Self.pieceSize }) ?? true { anywhere.append(Piece()) }
            anywhere[anywhere.count - 1].add(rule)
        }
        keptNow += 1
    }

    public mutating func except(_ rule: BlockingRule) {
        exceptions.add(rule)
        if let site = rule.site { bySite[Self.key(site), default: Piece()].add(rule) } else { loose.add(rule) }
        let trigger = rule.trigger
        let wholeSite = trigger.urlFilter == ".*" && trigger.ifDomain != nil && trigger.resourceType == nil
        if wholeSite || trigger.resourceType?.contains("popup") == true { popupExceptions.add(rule) }
        keptNow += 1
    }

    public mutating func important(_ rule: BlockingRule) {
        important.add(rule)
        keptNow += 1
    }

    public mutating func popup(_ rule: BlockingRule) {
        popups.add(rule)
        keptNow += 1
    }

    public mutating func hide(_ rule: BlockingRule) {
        if hiding.last.map({ $0.count >= ContentBlocking.hidingPerList }) ?? true { hiding.append(Piece()) }
        hiding[hiding.count - 1].add(rule)
        keptNow += 1
    }

    public mutating func script(_ filter: ScriptedFilter) {
        scripted.append(filter)
        keptNow += 1
    }

    public mutating func skip() {
        skippedNow += 1
    }

    public mutating func finish(version: String?, modified: String?, expires keeps: TimeInterval?) {
        stamps.append(version ?? modified ?? "?")
        kept.append(keptNow)
        skipped.append(skippedNow)
        keptNow = 0
        skippedNow = 0
        if let keeps { expires = min(expires ?? keeps, keeps) }
    }
}

extension RulePlanner {

    /// The lists to compile, each one's text put together only when it is
    /// asked for (RulePlan.list): the whole plan's text at once is the lists'
    /// rules a second time over.
    public func plan() -> RulePlan {
        let stamp = "v\(ContentBlocking.converterVersion)-\(ContentBlocking.stableHash(stamps.joined(separator: "+")))"
        let nothing = anywhere.isEmpty && tied.isEmpty
        // What ends a list: its exceptions, what no exception undoes, and the page itself.
        func tail(_ own: Piece) -> Piece {
            var tail = own
            tail.add(important)
            if !nothing || tail.count > 0 { tail.add(ContentBlocking.pageItself) }
            return tail
        }
        let whole = tail(exceptions)
        var entries: [RulePlan.Entry] = []
        var tails: [String] = []
        // As many pieces to a list as fit, with room for the longest tail there could be.
        let room = max(Self.pieceSize, min(ContentBlocking.networkPerList, ContentBlocking.rulesPerList - whole.count))
        func lists(of pieces: [Piece], from first: Int, tail: (Range<Int>) -> Piece) {
            var start = 0
            var count = 0
            func close(_ end: Int) {
                let ending = tail(start..<end)
                guard count + ending.count > 0 else { return }
                entries.append(.init(id: "blocking.\(stamp).network.\(entries.count)", kind: "network",
                                     pieces: Array((first + start)..<(first + end)), tail: tails.count, rules: count + ending.count))
                tails.append(ending.json)
            }
            for (index, piece) in pieces.enumerated() {
                if count > 0, count + piece.count > room {
                    close(index)
                    start = index
                    count = 0
                }
                count += piece.count
            }
            if count > 0 { close(pieces.count) }
        }
        lists(of: anywhere, from: 0) { _ in whole }
        lists(of: tied, from: anywhere.count) { pieces in
            var own = loose
            let sites = pieces.reduce(into: Set<String>()) { $0.formUnion(tiedSites[$1]) }
            // In the same order every time, so the same lists make the same text.
            for site in sites.sorted() { if let piece = bySite[site] { own.add(piece) } }
            return tail(own)
        }
        // Exceptions with nothing to except still say what the lists said, in a list of their own.
        if nothing, whole.count > 0 {
            entries.append(.init(id: "blocking.\(stamp).network.0", kind: "network", pieces: [], tail: 0, rules: whole.count))
            tails.append(whole.json)
        }
        if popups.count > 0 {
            entries.append(.init(id: "blocking.\(stamp).popups.0", kind: "popups", pieces: [], tail: 0, rules: popups.count + popupExceptions.count))
        }
        for (index, piece) in hiding.enumerated() {
            entries.append(.init(id: "blocking.\(stamp).hiding.\(index)", kind: "hiding", pieces: [index], tail: 0, rules: piece.count))
        }
        return RulePlan(entries: entries, blocks: (anywhere + tied).map(\.json), tails: tails, popups: popups.json,
                        popupExceptions: popupExceptions.json, hiding: hiding.map(\.json))
    }

    public func lists() -> [PlannedList] {
        let plan = plan()
        return plan.entries.indices.map(plan.list)
    }
}

/// What a RulePlanner made of the lists: which rule lists there are to
/// compile, and each one's text when it is asked for.
public struct RulePlan: Sendable {
    public struct Entry: Sendable {
        public let id: String
        let kind: String
        /// Which pieces of blocking, or which piece of hiding, it is made of.
        let pieces: [Int]
        /// Which of the plan's tails ends it, for a list of blocking.
        let tail: Int
        public let rules: Int
    }

    public let entries: [Entry]
    let blocks: [String]
    let tails: [String]
    let popups: String
    let popupExceptions: String
    let hiding: [String]

    /// One rule list's JSON, put together now.
    public func list(_ index: Int) -> PlannedList {
        let entry = entries[index]
        var parts: [String]
        switch entry.kind {
        case "network": parts = entry.pieces.map { blocks[$0] } + [tails[entry.tail]]
        case "popups": parts = [popups, popupExceptions]
        default: parts = entry.pieces.map { hiding[$0] }
        }
        parts.removeAll(where: \.isEmpty)
        var json = ""
        json.reserveCapacity(parts.reduce(2) { $0 + $1.utf8.count + 1 })
        json += "["
        for (place, part) in parts.enumerated() {
            if place > 0 { json += "," }
            json += part
        }
        json += "]"
        return PlannedList(id: entry.id, json: json, rules: entry.rules)
    }
}

/// Adblock Plus syntax to WebKit's rules (ContentBlocking).
public enum FilterConverter {
    public static let selectorsPerRule = 50

    public static func convert(_ text: String) -> FilterRules {
        var out = FilterRules()
        convert(text, into: &out)
        return out
    }

    /// The list's rules handed over one by one as they are read, so that
    /// whoever takes them needn't hold a list's worth at once (RulePlanner
    /// writes each out as text and lets it go).
    public static func convert<Sink: FilterSink>(_ text: String, into sink: inout Sink) {
        let lines = text.split(whereSeparator: \.isNewline)
        // $badfilter turns off the filter it names, wherever it is.
        var turnedOff = Set<String>()
        for raw in lines where raw.contains("badfilter") {
            if let named = withoutBadfilter(raw.trimmingCharacters(in: .whitespaces)) { turnedOff.insert(named) }
        }
        var head = FilterRules()
        var hide = HidingBuilder()
        // Hiding WebKit's rules can't carry, kept for the page's script once
        // every exception to hiding has been read.
        var forScript: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[") { continue }
            if line.hasPrefix("!") {
                header(line, into: &head)
                continue
            }
            if let kind = cosmeticKind(line) {
                // What WebKit's hiding can't carry (a site named with a
                // wildcard, an operator in the selector) goes to the page's
                // script where it can.
                if kind != .plain || !hide.add(line) { forScript.append(line) }
                continue
            }
            if turnedOff.contains(line) || withoutBadfilter(line) != nil {
                sink.skip()
                continue
            }
            guard let filter = NetworkFilter(line) else {
                sink.skip()
                continue
            }
            switch filter.kind {
            case .elemhideException(let domain):
                hide.noHiding.insert(domain)
            case .generichideException(let domain):
                hide.noGenericHiding.insert(domain)
            case .rules(let rules):
                for rule in rules {
                    if filter.exception {
                        sink.except(rule)
                    } else if filter.important {
                        sink.important(rule)
                    } else {
                        sink.block(rule)
                    }
                }
                for rule in filter.popups { sink.popup(rule) }
            }
        }
        for rule in hide.rules() { sink.hide(rule) }
        for line in forScript {
            let filters = ScriptedFilter.parse(line)
            if filters.isEmpty { sink.skip() }
            for filter in filters { sink.script(filter) }
        }
        sink.finish(version: head.version, modified: head.modified, expires: head.expires)
    }

    // MARK: The list's header

    static func header(_ line: String, into out: inout FilterRules) {
        let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("version:") {
            out.version = text.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        } else if text.lowercased().hasPrefix("last modified:") {
            out.modified = text.dropFirst("last modified:".count).trimmingCharacters(in: .whitespaces)
        } else if text.lowercased().hasPrefix("expires:") {
            // "4 days (update frequency)", "12 hours".
            let words = text.dropFirst("expires:".count).split(separator: " ")
            guard let first = words.first, let number = Double(first) else { return }
            let unit = words.count > 1 ? words[1].lowercased() : "days"
            out.expires = number * (unit.hasPrefix("hour") ? 3600 : 86400)
        }
    }

    // MARK: Telling hiding from blocking

    enum CosmeticKind { case plain, other }

    /// "##" and "#@#" are hiding WebKit can do; "#?#", "#$#", "#%#" and
    /// their exceptions are procedural filters, styles and scripts it can't,
    /// and so are "$$" and "##+js(…)" and "##^…" (HTML filtering).
    static func cosmeticKind(_ line: String) -> CosmeticKind? {
        if line.contains("$$") || line.contains("$@$") { return .other }
        guard let hash = line.range(of: "#") else { return nil }
        let rest = line[hash.lowerBound...]
        for marker in ["#?#", "#$#", "#%#", "#@?#", "#@$#", "#@%#"] where rest.contains(marker) { return .other }
        guard let separator = line.range(of: "#@#") ?? line.range(of: "##") else { return nil }
        let selector = line[separator.upperBound...]
        if selector.hasPrefix("+js(") || selector.hasPrefix("^") { return .other }
        return .plain
    }

    static func withoutBadfilter(_ line: String) -> String? {
        guard let dollar = line.lastIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",").map(String.init)
        guard options.contains("badfilter") else { return nil }
        let kept = options.filter { $0 != "badfilter" }
        return String(line[..<dollar]) + (kept.isEmpty ? "" : "$" + kept.joined(separator: ","))
    }
}

// MARK: Blocking filters

/// One blocking filter or exception: `||ads.example.com^$third-party`,
/// `@@||example.com/ads.js$script,domain=example.com`, `/banner/*/img^`.
struct NetworkFilter {
    enum Kind {
        case rules([BlockingRule])
        /// @@||example.com^$elemhide: no hiding at all on that site.
        case elemhideException(String)
        /// @@||example.com^$generichide: no hiding but that site's own.
        case generichideException(String)
    }

    let kind: Kind
    let exception: Bool
    let important: Bool
    /// The same filter for windows a page opens ("$popup"), when it blocks them.
    private(set) var popups: [BlockingRule] = []

    /// The resource types WebKit has, as the lists name them. `other` is
    /// WebKit's "raw" (fetch, XHR and loads with no type), which every
    /// version eGlu runs on knows.
    static let types: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "font": "font", "media": "media", "xmlhttprequest": "raw", "xhr": "raw", "other": "raw",
        "websocket": "websocket", "ping": "ping", "beacon": "ping",
    ]
    static let allTypes = Array(Set(types.values)).sorted()

    /// Options that change nothing WebKit can be told, or that ask for
    /// something it can't do: a filter with one of these is left out.
    static let unsupported: Set<String> = [
        "genericblock", "specifichide", "shide", "csp", "redirect", "redirect-rule", "removeparam",
        "queryprune", "rewrite", "header", "permissions", "replace", "urltransform", "denyallow", "to", "method",
        "cname", "sitekey", "strict1p", "strict3p", "webrtc", "inline-script", "inline-font", "empty", "mp4",
        "network", "app", "extension", "content", "jsinject", "urlblock", "stealth", "cookie", "hls", "jsonprune",
        "referrerpolicy", "ipaddress", "reason", "urlskip", "object", "object-subrequest",
    ]
    static let known: Set<String> = unsupported.union(types.keys).union([
        "third-party", "3p", "first-party", "1p", "domain", "from", "match-case", "important", "badfilter",
        "subdocument", "frame", "document", "doc", "elemhide", "ehide", "generichide", "ghide", "all", "popup",
    ])

    init?(_ line: String) {
        var body = Substring(line)
        exception = body.hasPrefix("@@")
        if exception { body = body.dropFirst(2) }
        var options: [String] = []
        if let dollar = body.lastIndex(of: "$") {
            let tail = body[body.index(after: dollar)...]
            let first = tail.prefix { $0 != "," && $0 != "=" }
            let name = first.hasPrefix("~") ? String(first.dropFirst()) : String(first)
            if NetworkFilter.known.contains(name) {
                options = tail.split(separator: ",").map(String.init)
                body = body[..<dollar]
            }
        }

        var resourceTypes = Set<String>()
        var notTypes = Set<String>()
        var frames = false
        var notFrames = false
        var party: String?
        var include: [String] = []
        var exclude: [String] = []
        var caseSensitive = false
        var isImportant = false
        var document = false
        var elemhide = false
        var generichide = false
        var droppedTypes = false
        var popup = false
        for option in options {
            let negated = option.hasPrefix("~")
            let plain = negated ? String(option.dropFirst()) : option
            let parts = plain.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            if NetworkFilter.unsupported.contains(name) {
                // Leaving out a type WebKit lacks ("object") is fine; asking for it alone is not.
                if name == "object" || name == "object-subrequest" {
                    droppedTypes = true
                    continue
                }
                return nil
            }
            switch name {
            case "third-party", "3p": party = negated ? "first-party" : "third-party"
            case "first-party", "1p": party = negated ? "third-party" : "first-party"
            case "domain", "from":
                // "*example.com": the site and its subdomains, as the lists mean it.
                for entry in value.split(separator: "|") {
                    let excluded = entry.hasPrefix("~")
                    guard let domain = Domains.webKit(excluded ? String(entry.dropFirst()) : String(entry)) else { continue }
                    if excluded { exclude.append("*" + domain) } else { include.append("*" + domain) }
                }
                if include.isEmpty && exclude.isEmpty { return nil }
            case "match-case": caseSensitive = !negated
            case "important": isImportant = true
            case "subdocument", "frame": if negated { notFrames = true } else { frames = true }
            case "document", "doc": if negated { continue } else { document = true }
            case "elemhide", "ehide": elemhide = true
            case "generichide", "ghide": generichide = true
            case "all": continue
            // "Not popups" is what every other kind of load already is.
            case "popup": if negated { continue } else { popup = true }
            case "badfilter": return nil
            default:
                guard let type = NetworkFilter.types[name] else { return nil }
                if negated { notTypes.insert(type) } else { resourceTypes.insert(type) }
            }
        }
        important = isImportant
        // One trigger can't say "on this site but not that part of it".
        if !include.isEmpty && !exclude.isEmpty { return nil }

        // Exceptions for a whole site: no blocking, or no hiding, on it.
        if exception && (document || elemhide || generichide) {
            guard let site = NetworkFilter.siteOnly(body) else { return nil }
            if document {
                kind = .rules([BlockingRule(trigger: .init(ifDomain: ["*" + site]), action: .allow)])
            } else if elemhide {
                kind = .elemhideException(site)
            } else {
                kind = .generichideException(site)
            }
            return
        }
        // Blocking a page you went to isn't done (ContentBlocking.network).
        if document || elemhide || generichide { return nil }

        guard let urlFilters = NetworkFilter.urlFilters(body) else { return nil }
        let site = NetworkFilter.site(body)
        if !notTypes.isEmpty && resourceTypes.isEmpty {
            resourceTypes = Set(NetworkFilter.allTypes).subtracting(notTypes)
            if !notFrames { frames = true }
        }
        if droppedTypes && resourceTypes.isEmpty && !frames && !popup { return nil }
        let action: BlockingRule.Action = exception ? .allow : .block
        var rules: [BlockingRule] = []
        var opened: [BlockingRule] = []
        for urlFilter in urlFilters {
            var trigger = BlockingRule.Trigger(urlFilter: urlFilter)
            if caseSensitive { trigger.caseSensitive = true }
            if let party { trigger.loadType = [party] }
            if !include.isEmpty { trigger.ifDomain = include.sorted() }
            if !exclude.isEmpty { trigger.unlessDomain = exclude.sorted() }
            if popup {
                // A window the page opens, which WebKit asks its rules about
                // as a load of its own kind. An exception for one goes with
                // the other exceptions, which the popups' list ends with too.
                var window = trigger
                window.resourceType = ["popup"]
                if exception { rules.append(BlockingRule(trigger: window, action: action, site: site)) }
                else { opened.append(BlockingRule(trigger: window, action: action, site: site)) }
                // "$popup" alone is about windows only.
                if resourceTypes.isEmpty && !frames && notTypes.isEmpty { continue }
            }
            var made = 0
            if !resourceTypes.isEmpty {
                var typed = trigger
                typed.resourceType = resourceTypes.sorted()
                rules.append(BlockingRule(trigger: typed, action: action, site: site))
                made += 1
            }
            if frames {
                // A frame is a document loaded inside the page.
                var framed = trigger
                framed.resourceType = ["document"]
                framed.loadContext = ["child-frame"]
                rules.append(BlockingRule(trigger: framed, action: action, site: site))
                made += 1
            }
            if made == 0 {
                if notFrames { trigger.resourceType = NetworkFilter.allTypes }
                rules.append(BlockingRule(trigger: trigger, action: action, site: site))
            }
        }
        kind = .rules(rules)
        popups = opened
    }

    /// The host a "||ads.test^…" or "||ads.test/…" filter is tied to: such a
    /// filter matches only addresses on that host or under it. Nil for any
    /// other filter, and for one whose host isn't ended ("||ads.test", which
    /// matches ads.testing.org too) or has a wildcard in it.
    static func site(_ body: Substring) -> String? {
        guard body.hasPrefix("||") else { return nil }
        let rest = body.dropFirst(2)
        let host = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              let end = rest.dropFirst(host.count).first, end == "^" || end == "/" || end == ":" else { return nil }
        return host.lowercased()
    }

    /// "||example.com^" or "||example.com": the site, for a whole-site exception.
    static func siteOnly(_ body: Substring) -> String? {
        guard body.hasPrefix("||") else { return nil }
        var host = body.dropFirst(2)
        if host.hasSuffix("^") { host = host.dropLast() }
        return Domains.webKit(String(host))
    }

    /// The filter's address pattern as WebKit's url-filters (one, or two
    /// where it ends in a separator that may be the end of the address), or
    /// nil where WebKit can't say it.
    static func urlFilters(_ body: Substring) -> [String]? {
        if body.count > 2, body.hasPrefix("/"), body.hasSuffix("/") {
            return regex(String(body.dropFirst().dropLast())).map { [$0] }
        }
        var pattern = body
        var out = ""
        let hostAnchor = pattern.hasPrefix("||")
        if hostAnchor {
            // Any scheme, the host or one of its subdomains.
            out = "^[a-z][a-z0-9.+-]*://([^/:]*\\.)?"
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            out = "^"
            pattern = pattern.dropFirst()
        }
        var endAnchor = false
        if pattern.hasSuffix("|") {
            endAnchor = true
            pattern = pattern.dropLast()
        }
        while pattern.hasPrefix("*") && out.isEmpty { pattern = pattern.dropFirst() }
        while pattern.hasSuffix("*") && !endAnchor { pattern = pattern.dropLast() }
        if pattern.isEmpty { return out.isEmpty ? [".*"] : nil }
        // A separator: any character but a letter, a digit or _ - . %, or the end.
        let separator = "[^a-zA-Z0-9_.%-]"
        let characters = Array(pattern)
        var lastSeparator = false
        for (index, character) in characters.enumerated() {
            guard character.isASCII, let ascii = character.asciiValue, ascii >= 0x21, ascii < 0x7f else { return nil }
            switch character {
            case "*":
                out += ".*"
            case "^":
                if index == characters.count - 1 && !endAnchor {
                    lastSeparator = true
                } else {
                    out += separator
                }
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "|", "$":
                out += "\\" + String(character)
            default:
                out.append(character)
            }
        }
        if endAnchor { out += "$" }
        guard lastSeparator else { return [out] }
        // A host is always followed by its path or its port in the address
        // WebKit matches ("https://ads.test/"), so there the end needn't be
        // asked for. Elsewhere, a separator or the end is two rules: WebKit
        // has no "or", and "(separator.*)?$" takes it twenty times as long
        // to compile.
        if hostAnchor && !characters.dropLast().contains(where: { "/^*?=&:".contains($0) }) {
            return [out + "[/:]"]
        }
        return [out + separator, out + "$"]
    }

    /// A /regular expression/ filter, if it is in the part of the syntax
    /// WebKit takes: literal ASCII, escapes of punctuation, . * + ?, [sets],
    /// (groups) and the anchors. Alternatives, counted repeats, classes such
    /// as \d, and (?…) aren't.
    static func regex(_ pattern: String) -> String? {
        guard !pattern.isEmpty, pattern.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        let characters = Array(pattern)
        var depth = 0
        var inSet = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                guard index + 1 < characters.count else { return nil }
                let next = characters[index + 1]
                if next.isLetter || next.isNumber { return nil }
                index += 1
            case "|", "{", "}":
                if !inSet { return nil }
            case "[":
                if inSet { return nil }
                inSet = true
            case "]":
                if inSet { inSet = false }
            case "(":
                if inSet { break }
                if index + 1 < characters.count && characters[index + 1] == "?" { return nil }
                depth += 1
            case ")":
                if inSet { break }
                depth -= 1
                if depth < 0 { return nil }
            case "^":
                if !inSet && index != 0 { return nil }
            case "$":
                if !inSet && index != characters.count - 1 { return nil }
            default:
                break
            }
            index += 1
        }
        return depth == 0 && !inSet ? pattern : nil
    }
}

// MARK: Element hiding

/// `##.ad-banner` on every site, `example.com##.ad` on one, `example.com#@#.ad`
/// not there: grouped into rules of `FilterConverter.selectorsPerRule`.
struct HidingBuilder {
    /// Sites with no hiding at all ($elemhide), or none but their own ($generichide).
    var noHiding = Set<String>()
    var noGenericHiding = Set<String>()

    private var generic: [String] = []
    private var genericSeen = Set<String>()
    private var genericExceptions: [String: Set<String>] = [:]
    private var genericNowhere = Set<String>()
    private var specific: [String: (domains: [String], selectors: [String])] = [:]
    private var specificOrder: [String] = []

    /// False for a line it leaves out.
    mutating func add(_ line: String) -> Bool {
        let isException: Bool
        let separator: Range<String.Index>
        if let at = line.range(of: "#@#") {
            isException = true
            separator = at
        } else if let at = line.range(of: "##") {
            isException = false
            separator = at
        } else {
            return false
        }
        let selector = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard Selectors.isSafe(selector) else { return false }
        var include: [String] = []
        var exclude: [String] = []
        let domainText = line[..<separator.lowerBound]
        if !domainText.isEmpty {
            for entry in domainText.split(separator: ",") {
                let excluded = entry.hasPrefix("~")
                guard let domain = Domains.webKit(excluded ? String(entry.dropFirst()) : String(entry)) else { continue }
                if excluded { exclude.append(domain) } else { include.append(domain) }
            }
            if include.isEmpty && exclude.isEmpty { return false }
        }
        if isException {
            if include.isEmpty {
                // Not hidden anywhere after all.
                genericNowhere.insert(selector)
            } else {
                genericExceptions[selector, default: []].formUnion(include)
            }
            return true
        }
        if include.isEmpty {
            if !exclude.isEmpty { genericExceptions[selector, default: []].formUnion(exclude) }
            if genericSeen.insert(selector).inserted { generic.append(selector) }
        } else {
            // A site's own hiding; "on these but not those" says "on these".
            let key = include.sorted().joined(separator: ",")
            if specific[key] == nil {
                specific[key] = (include.sorted(), [])
                specificOrder.append(key)
            }
            specific[key]?.selectors.append(selector)
        }
        return true
    }

    /// Hiding is told by the document's own load, a frame's included. Without
    /// this, WebKit weighs every hiding rule again for each image, script
    /// and request the page makes, on the page's own thread, to add
    /// selectors it already has.
    static let documents = ["document"]

    func rules() -> [BlockingRule] {
        var out: [BlockingRule] = []
        let noGeneric = noHiding.union(noGenericHiding).map { "*" + $0 }.sorted()
        var plain: [String] = []
        for selector in generic where !genericNowhere.contains(selector) {
            if let except = genericExceptions[selector] {
                let unless = Set(except.map { "*" + $0 }).union(noGeneric).sorted()
                out.append(BlockingRule(trigger: .init(resourceType: Self.documents, unlessDomain: unless), action: .hide(selector)))
            } else {
                plain.append(selector)
            }
        }
        for group in Self.chunks(plain) {
            out.append(BlockingRule(trigger: .init(resourceType: Self.documents, unlessDomain: noGeneric.isEmpty ? nil : noGeneric),
                                    action: .hide(group.joined(separator: ", "))))
        }
        for key in specificOrder {
            guard let entry = specific[key] else { continue }
            let domains = entry.domains.filter { !noHiding.contains($0) }.map { "*" + $0 }
            guard !domains.isEmpty else { continue }
            var seen = Set<String>()
            let selectors = entry.selectors.filter { selector in
                // Excepted on one of its sites: left out on all, rather than hidden where it shouldn't be.
                if let except = genericExceptions[selector], !except.isDisjoint(with: entry.domains) { return false }
                return seen.insert(selector).inserted
            }
            for group in Self.chunks(selectors) {
                out.append(BlockingRule(trigger: .init(resourceType: Self.documents, ifDomain: domains), action: .hide(group.joined(separator: ", "))))
            }
        }
        return out
    }

    static func chunks(_ list: [String]) -> [[String]] {
        stride(from: 0, to: list.count, by: FilterConverter.selectorsPerRule).map {
            Array(list[$0..<min($0 + FilterConverter.selectorsPerRule, list.count)])
        }
    }
}

enum Domains {
    /// A domain as WebKit's if-domain and unless-domain take it: lower case
    /// ASCII, no wildcard TLD ("example.*") and nothing that isn't a host.
    static func webKit(_ text: String) -> String? {
        let domain = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return domain
    }
}

enum Selectors {
    /// The pseudo-classes WebKit's CSS parser knows, of those filter lists use.
    static let pseudoClasses: Set<String> = [
        "not", "has", "is", "where", "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type",
        "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type", "empty",
        "root", "checked", "disabled", "enabled", "link", "any-link", "target", "lang", "dir", "optional",
        "required", "read-only", "read-write", "placeholder-shown", "default", "indeterminate", "valid",
        "invalid", "in-range", "out-of-range", "defined", "scope", "visited",
    ]

    /// A selector WebKit will parse. One it won't is dropped with every
    /// selector grouped into the same rule, and nothing says so, so anything
    /// unsure is turned down: procedural filters (:-abp-has, :has-text,
    /// :xpath…), pseudo-elements, unbalanced brackets or quotes, anything
    /// outside plain ASCII or that could end the rule, and :has inside :has.
    /// Inside quotes is another matter: a quoted value is the page's text,
    /// not CSS ([style="top:0;left:0"], [href*="//광고.com"]), and WebKit
    /// takes anything there (tried: ContentBlockingTests).
    static func isSafe(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 2_000 else { return false }
        if selector.components(separatedBy: ":has(").count > 2 { return false }
        let characters = Array(selector)
        var parens = 0
        var brackets = 0
        var quote: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                // A line end can't be inside a quoted value.
                if character.isNewline { return false }
                if character == "\\" { index += 2; continue }
                if character == open { quote = nil }
                index += 1
                continue
            }
            guard character.isASCII, character == " " || !character.isWhitespace else { return false }
            switch character {
            case "{", "}", ";", "!":
                return false
            case "\\":
                // An escape needs something to escape.
                if index + 1 >= characters.count { return false }
                index += 2
                continue
            case "\"", "'":
                quote = character
            case "[":
                brackets += 1
            case "]":
                brackets -= 1
                if brackets < 0 { return false }
            case "(":
                parens += 1
            case ")":
                parens -= 1
                if parens < 0 { return false }
            case ":" where brackets == 0:
                if index + 1 < characters.count && characters[index + 1] == ":" { return false }
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end] == "-" { end += 1 }
                let name = String(characters[(index + 1)..<end]).lowercased()
                guard pseudoClasses.contains(name) else { return false }
                index = end
                continue
            default:
                break
            }
            index += 1
        }
        return parens == 0 && brackets == 0 && quote == nil
    }
}
