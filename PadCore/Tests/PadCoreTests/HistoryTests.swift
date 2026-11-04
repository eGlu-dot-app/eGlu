import XCTest
#if canImport(SQLite3)
import SQLite3
#endif
@testable import PadCore

/// History: what is kept, how it is found again, and how clearing it holds.
final class HistoryTests: XCTestCase {
    private let space = UUID()
    private let now = Date(timeIntervalSince1970: 1_792_500_000)   // a Tuesday in October 2026

    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    private func visit(_ address: String, title: String = "", summary: String = "", daysAgo: Double = 0,
                       kind: HistoryKind = .link, in space: UUID? = nil) throws -> HistoryVisit {
        HistoryVisit(space: space ?? self.space, url: try url(address), title: title, summary: summary,
                     time: now.addingTimeInterval(-daysAgo * 86_400), device: "this", kind: kind)
    }

    // MARK: What is kept

    func testSignInPagesAndCredentialsAreNeverKept() throws {
        XCTAssertTrue(History.keeps(try url("https://developer.apple.com/design/")))
        XCTAssertFalse(History.keeps(try url("https://accounts.google.com/signin")), "a sign-in page")
        XCTAssertFalse(History.keeps(try url("https://example.com/callback?code=abc")), "an address that signs whoever opens it in")
        XCTAssertFalse(History.keeps(try url("file:///Users/me/note.html")), "not a web page")
        XCTAssertEqual(History.address(try url("https://example.com/a?utm_source=x&id=2")).absoluteString, "https://example.com/a?id=2")
    }

    func testADescriptionIsOneLineAndShort() {
        XCTAssertEqual(History.summary("  Two\n lines  "), "Two lines")
        let long = String(repeating: "word ", count: 100)
        let kept = History.summary(long)
        XCTAssertLessThanOrEqual(kept.count, History.summaryLength + 1)
        XCTAssertTrue(kept.hasSuffix("…"))
    }

    func testRetentionIsAMonthUnlessChangedAndUntilClearedIsKept() throws {
        XCTAssertEqual(Preferences().historyRetention, .month)
        XCTAssertFalse(Preferences().historySync, "history leaves the device only when turned on")
        let saved = try JSONDecoder().decode(Preferences.self, from: Data(#"{"historyRetention":"forever"}"#.utf8))
        XCTAssertEqual(saved.historyRetention, .forever)
        XCTAssertNil(HistoryRetention.forever.cutoff(now: now))
        XCTAssertEqual(HistoryRetention.week.cutoff(now: now), now.addingTimeInterval(-7 * 86_400))
    }

    // MARK: Finding it again

    func testWordsForWhenAreTakenOutAndNameAStretchOfTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let yesterday = HistoryQuery.parse("figma yesterday", now: now, calendar: calendar)
        XCTAssertEqual(yesterday.words, "figma")
        XCTAssertEqual(yesterday.from, calendar.dateInterval(of: .day, for: now.addingTimeInterval(-86_400))?.start)

        let korean = HistoryQuery.parse("지난주 피그마 강좌", now: now, calendar: calendar)
        XCTAssertEqual(korean.words, "피그마 강좌")
        let lastWeek = calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: -1, to: now)!)!
        XCTAssertEqual(korean.from, lastWeek.start)

        let name = HistoryQuery.parse("todayshow recipes", now: now, calendar: calendar)
        XCTAssertEqual(name.words, "todayshow recipes", "a word that only starts with one is a name")
        XCTAssertNil(name.from)

        let later = HistoryQuery.parse("usatoday today", now: now, calendar: calendar)
        XCTAssertEqual(later.words, "usatoday", "the phrase on its own further on")
        XCTAssertNotNil(later.from)
        let shop = HistoryQuery.parse("오늘의집 소파", now: now, calendar: calendar)
        XCTAssertEqual(shop.words, "오늘의집 소파", "a shop's name, not today")
        XCTAssertNil(shop.from)
        let particle = HistoryQuery.parse("어제의 기사", now: now, calendar: calendar)
        XCTAssertEqual(particle.words, "기사", "the word for when goes with its particle")
        XCTAssertEqual(particle.from, calendar.dateInterval(of: .day, for: now.addingTimeInterval(-86_400))?.start)
        XCTAssertEqual(HistoryQuery.parse("today's news", now: now, calendar: calendar).words, "news")
        for name in ["today.com", "usa-today", "오늘날"] {
            XCTAssertNil(HistoryQuery.parse(name, now: now, calendar: calendar).from, name)
        }
    }

    func testWhatAppleIntelligenceMakesOfAMemoryIsAQuery() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(HistoryQuery.askPrompt(" glass article "), "Written: glass article")
        let friday = HistoryQuery.asked(words: " glass  ", when: "last Friday", written: "the glass article from last friday",
                                        now: now, calendar: calendar)
        XCTAssertEqual(friday.words, "glass")
        let today = calendar.startOfDay(for: now)   // a Tuesday
        XCTAssertEqual(friday.from, calendar.date(byAdding: .day, value: -4, to: today))
        let fallback = HistoryQuery.asked(words: "glass", when: "", written: "glass yesterday", now: now, calendar: calendar)
        XCTAssertEqual(fallback.from, calendar.date(byAdding: .day, value: -1, to: today), "what was written, when the model gave nothing")
        XCTAssertNil(HistoryQuery.asked(words: "glass", when: "", written: "glass", now: now).from)
    }

    func testMoreWaysOfSayingWhen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let today = calendar.startOfDay(for: now)   // Tuesday 20 October 2026
        func day(_ back: Int) -> Date? { calendar.date(byAdding: .day, value: -back, to: today) }
        func parse(_ text: String) -> HistoryQuery { HistoryQuery.parse(text, now: now, calendar: calendar) }
        XCTAssertEqual(parse("figma 3 days ago").from, day(3))
        XCTAssertEqual(parse("figma 3 days ago").words, "figma")
        XCTAssertEqual(parse("two days ago").from, day(2))
        XCTAssertEqual(parse("last friday").from, day(4))
        XCTAssertEqual(parse("on tuesday").from, day(7), "the last one before today")
        XCTAssertEqual(parse("in september").from, calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        XCTAssertEqual(parse("december").from, calendar.date(from: DateComponents(year: 2025, month: 12, day: 1)), "not yet this year")
        let korean = parse("지난 금요일에 본 유리 기사")
        XCTAssertEqual(korean.from, day(4))
        XCTAssertEqual(korean.words, "본 유리 기사", "with its particle")
        XCTAssertEqual(parse("3일 전 기사").from, day(3))
        XCTAssertEqual(parse("9월에 본").from, calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        XCTAssertEqual(parse("2주 전").from, calendar.dateInterval(of: .weekOfYear, for: day(14)!)?.start)
        for name in ["monday.com", "may the force", "월요일 아침", "9월호"] {
            XCTAssertNil(parse(name).from, name)
        }
    }

    func testPagesGoneToRecentlyAndTypedAreWantedMore() {
        let day = 86_400.0
        let recentTyped = History.frecency(of: [(now.addingTimeInterval(-day), .typed)], now: now)
        let recentLink = History.frecency(of: [(now.addingTimeInterval(-day), .link)], now: now)
        let oldLink = History.frecency(of: [(now.addingTimeInterval(-60 * day), .link)], now: now)
        let oftenOld = History.frecency(of: Array(repeating: (now.addingTimeInterval(-60 * day), HistoryKind.link), count: 5), now: now)
        XCTAssertGreaterThan(recentTyped, recentLink)
        XCTAssertGreaterThan(recentLink, oldLink)
        XCTAssertGreaterThan(oftenOld, oldLink, "five visits count for more than one")
    }

    func testAClearingCoversWhatCameBeforeItInItsSpace() throws {
        let other = UUID()
        let old = try visit("https://figma.com/file", daysAgo: 2)
        let clearing = HistoryRemoval(space: space, scope: .all, made: now.addingTimeInterval(-86_400))
        XCTAssertTrue(clearing.covers(old))
        XCTAssertFalse(clearing.covers(try visit("https://figma.com/file", daysAgo: 0)), "made after the clearing")
        XCTAssertFalse(clearing.covers(try visit("https://figma.com/file", daysAgo: 2, in: other)), "another space's")
        let page = HistoryRemoval(space: nil, scope: .page(History.digest(ofKey: History.pageKey(try url("https://figma.com/file/")))), made: now)
        XCTAssertTrue(page.covers(old), "the same page, however its address ends")
        XCTAssertFalse(page.covers(try visit("https://figma.com/other", daysAgo: 2)))
    }

    // MARK: The History list

    func testClearHistoryGoesBackFromNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let today = calendar.startOfDay(for: now)
        XCTAssertEqual(HistorySpan.lastHour.scope(now: now, calendar: calendar), .range(from: now.addingTimeInterval(-3600), to: now))
        XCTAssertEqual(HistorySpan.today.scope(now: now, calendar: calendar), .range(from: today, to: now))
        XCTAssertEqual(HistorySpan.todayAndYesterday.scope(now: now, calendar: calendar),
                       .range(from: calendar.date(byAdding: .day, value: -1, to: today)!, to: now))
        XCTAssertEqual(HistorySpan.all.scope(now: now, calendar: calendar), .all)
    }

    func testTheListShowsEachPageOnceADay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func entry(_ address: String, hoursAgo: Double) throws -> HistoryEntry {
            let page = HistoryPage(space: space, key: History.pageKey(try url(address)), url: try url(address), title: address,
                                   summary: "", last: now, count: 1, frecency: 0)
            return HistoryEntry(id: UUID(), time: now.addingTimeInterval(-hoursAgo * 3600), kind: .link, page: page)
        }
        let start = calendar.startOfDay(for: now)
        let hours = now.timeIntervalSince(start) / 3600
        let days = History.days([
            try entry("https://figma.com/a", hoursAgo: 0.5),
            try entry("https://figma.com/a/", hoursAgo: 0.2),
            try entry("https://figma.com/b", hoursAgo: 0.1),
            try entry("https://figma.com/a", hoursAgo: hours + 1),
        ], calendar: calendar)
        XCTAssertEqual(days.map(\.start), [start, calendar.date(byAdding: .day, value: -1, to: start)!])
        XCTAssertEqual(days[0].entries.map(\.page.url.absoluteString), ["https://figma.com/b", "https://figma.com/a/"],
                       "newest first, the page once, at its last visit")
        XCTAssertEqual(days[1].entries.count, 1, "the day before has its own")
    }

    #if canImport(SQLite3)
    // MARK: The store

    private func store() throws -> HistoryStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return try HistoryStore(url: file)
    }

    func testPagesAreFoundByWhatIsInsideTheirWords() async throws {
        let history = try store()
        try await history.record(try visit("https://www.wooribank.com/", title: "우리은행 인터넷뱅킹"), now: now)
        try await history.record(try visit("https://developer.apple.com/design/human-interface-guidelines/materials",
                                           title: "Materials", summary: "Liquid Glass and the materials under it"), now: now)
        try await history.record(try visit("https://figma.com/file/abc", title: "Onboarding flow"), now: now)

        let bank = try await history.search(space: space, query: HistoryQuery(words: "은행"))
        XCTAssertEqual(bank.map(\.title), ["우리은행 인터넷뱅킹"], "two syllables, inside a word")
        let glass = try await history.search(space: space, query: HistoryQuery(words: "LASS"))
        XCTAssertEqual(glass.map(\.title), ["Materials"], "inside a word of the description, case set aside")
        let byAddress = try await history.search(space: space, query: HistoryQuery(words: "figma onboard"))
        XCTAssertEqual(byAddress.map(\.title), ["Onboarding flow"], "every word, from the address and the name")
        let elsewhere = try await history.search(space: UUID(), query: HistoryQuery(words: "figma"))
        XCTAssertTrue(elsewhere.isEmpty, "each space its own")
    }

    func testAPageGoneToAgainIsOnePageCountedTwiceAndWantedMore() async throws {
        let history = try store()
        try await history.record(try visit("https://figma.com/file/abc", title: "Old name", daysAgo: 3), now: now)
        try await history.record(try visit("https://figma.com/file/abc/", title: "New name", kind: .typed), now: now)
        try await history.record(try visit("https://news.ycombinator.com/", title: "Hacker News", daysAgo: 20), now: now)
        let all = try await history.search(space: space, query: HistoryQuery(words: ""))
        XCTAssertEqual(all.map(\.title), ["New name", "Hacker News"], "most wanted first; the newest name")
        XCTAssertEqual(all.first?.count, 2)
        let entries = try await history.entries(space: space)
        XCTAssertEqual(entries.map(\.page.title), ["New name", "New name", "Hacker News"], "newest visit first")
    }

    func testAStretchOfTimeNarrowsTheSearch() async throws {
        let history = try store()
        try await history.record(try visit("https://figma.com/a", title: "Figma A", daysAgo: 1), now: now)
        try await history.record(try visit("https://figma.com/b", title: "Figma B", daysAgo: 10), now: now)
        let found = try await history.search(space: space, query: HistoryQuery(words: "figma", from: now.addingTimeInterval(-2 * 86_400), to: now))
        XCTAssertEqual(found.map(\.title), ["Figma A"])
    }

    func testAPageClearedIsKeptAsClearedWithoutItsAddress() async throws {
        let history = try store()
        let page = try visit("https://bank.example.com/statements/2026", title: "Statements", daysAgo: 0.5)
        try await history.record(page, now: now)
        try await history.record(try visit("https://figma.com/a", title: "Figma", daysAgo: 0.4), now: now)
        let removal = HistoryRemoval(space: space, scope: .page(History.digest(ofKey: History.pageKey(page.url))), made: now)
        try await history.remove(removal, now: now)
        let left = try await history.entries(space: space)
        XCTAssertEqual(left.map(\.page.url.absoluteString), ["https://figma.com/a"])
        let kept = try await history.allRemovals()
        let written = String(data: try JSONEncoder().encode(kept), encoding: .utf8) ?? ""
        XCTAssertFalse(written.contains("bank"), "the clearing names the page by its digest only")
        let late = try await history.merge([page], now: now)
        XCTAssertTrue(late.isEmpty, "and still keeps it out")
    }

    func testClearingEverythingLetsTheClearingsBeforeItGo() async throws {
        let history = try store()
        let elsewhere = UUID()
        let page = HistoryRemoval(space: space, scope: .page(History.digest(ofKey: "figma.com/a")), made: now.addingTimeInterval(-60))
        let other = HistoryRemoval(space: elsewhere, scope: .all, made: now.addingTimeInterval(-30))
        let everywhere = HistoryRemoval(space: nil, scope: .range(from: now.addingTimeInterval(-3600), to: now), made: now.addingTimeInterval(-20))
        for removal in [page, other, everywhere] { try await history.remove(removal, now: now) }
        let all = HistoryRemoval(space: space, scope: .all, made: now)
        try await history.remove(all, now: now)
        var kept = Set(try await history.allRemovals().map(\.id))
        XCTAssertEqual(kept, [other.id, everywhere.id, all.id], "only the page cleared in this space is held by it")
        let allSpaces = HistoryRemoval(space: nil, scope: .all, made: now.addingTimeInterval(1))
        try await history.remove(allSpaces, now: now)
        kept = Set(try await history.allRemovals().map(\.id))
        XCTAssertEqual(kept, [allSpaces.id])
    }

    func testAClearingSaysWhichOfADevicesDaysItTook() async throws {
        let history = try store()
        let mine = try visit("https://figma.com/a", daysAgo: 0.1)
        let older = try visit("https://figma.com/b", daysAgo: 3)
        var theirs = try visit("https://figma.com/c", daysAgo: 0.1)
        theirs.device = "other"
        for each in [mine, older, theirs] { try await history.record(each, now: now) }
        let days = try await history.remove(HistoryRemoval(space: space, scope: .range(from: now.addingTimeInterval(-86_400), to: now),
                                                           made: now), now: now, daysOf: "this")
        XCTAssertEqual(days, [HistoryDayOfSpace(space: space, day: HistoryCloudDay.key(for: mine.time))])
        let named = try await history.update(space: space, url: older.url, title: "B", summary: nil, device: "this")
        XCTAssertEqual(named, older.time, "a new name goes with the day of this device's last visit to the page")
    }

    func testOneVisitTakenBackGoesAloneAndStaysOut() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let history = try HistoryStore(url: file)
        let taken = try visit("https://figma.com/account", title: "Account", daysAgo: 0.5)
        let other = try visit("https://figma.com/account", title: "Account", daysAgo: 0.2)
        try await history.record(taken, now: now)
        try await history.record(other, now: now)
        let removal = HistoryRemoval(space: space, scope: .visit(taken.id), made: now)
        XCTAssertTrue(removal.covers(taken))
        XCTAssertFalse(removal.covers(other))
        try await history.remove(removal, now: now)
        var left = try await history.entries(space: space)
        XCTAssertEqual(left.map(\.id), [other.id], "the other visit to the same page stays")

        // Kept as taken back, after the store is opened again: the same
        // visit, from a device that took it before, is let go.
        let reopened = try HistoryStore(url: file)
        let kept = try await reopened.merge([taken], now: now)
        XCTAssertTrue(kept.isEmpty)
        left = try await reopened.entries(space: space)
        XCTAssertEqual(left.map(\.id), [other.id])
    }

    func testClearedHistoryStaysClearedWhenOlderVisitsArriveLater() async throws {
        let history = try store()
        let early = try visit("https://figma.com/a", title: "Figma", daysAgo: 1)
        try await history.record(early, now: now)
        try await history.remove(HistoryRemoval(space: space, scope: .all, made: now), now: now)
        var left = try await history.entries(space: space)
        XCTAssertTrue(left.isEmpty)

        // The same visit, and another made before the clearing, from a device that was offline.
        let late = try visit("https://figma.com/b", title: "Figma B", daysAgo: 0.5)
        let kept = try await history.merge([early, late], now: now)
        XCTAssertTrue(kept.isEmpty, "made before the clearing: let go again")
        let after = HistoryVisit(space: space, url: try url("https://figma.com/c"), time: now.addingTimeInterval(60), device: "other", kind: .link)
        try await history.merge([after], now: now)
        left = try await history.entries(space: space)
        XCTAssertEqual(left.map(\.page.url.absoluteString), ["https://figma.com/c"], "made after it: kept")
    }

    func testAVisitTakenBackAndAPageClearedLeaveNothingBehind() async throws {
        let history = try store()
        let signIn = try visit("https://corp.example.com/portal", title: "Portal")
        try await history.record(signIn, now: now)
        try await history.forget(visit: signIn.id, now: now)
        let gone = try await history.search(space: space, query: HistoryQuery(words: "portal"))
        XCTAssertTrue(gone.isEmpty, "the page goes with its only visit, and out of the index")

        try await history.record(try visit("https://figma.com/a", title: "Figma"), now: now)
        try await history.record(try visit("https://figma.com/b", title: "Figma B"), now: now)
        try await history.remove(HistoryRemoval(space: space, scope: .page(History.digest(ofKey: History.pageKey(try url("https://figma.com/a")))), made: now), now: now)
        let left = try await history.search(space: space, query: HistoryQuery(words: "figma"))
        XCTAssertEqual(left.map(\.title), ["Figma B"])
    }

    func testANewTabListsThisDevicesPagesAndTheOthersApart() async throws {
        let history = try store()
        try await history.record(try visit("https://figma.com/a", title: "Figma", daysAgo: 2), now: now)
        try await history.record(try visit("https://figma.com/a", title: "Figma", daysAgo: 0.1), now: now)
        try await history.record(try visit("https://linear.app", title: "Linear", daysAgo: 1), now: now)
        var there = try visit("https://notion.so", title: "Notion", daysAgo: 0.5)
        there.device = "other"
        try await history.merge([there], now: now)
        try await history.record(try visit("https://elsewhere.example", title: "Elsewhere", in: UUID()), now: now)
        let here = try await history.recent(space: space, device: "this", others: false)
        XCTAssertEqual(here.map(\.page.title), ["Figma", "Linear"], "each page once, at its last visit, newest first")
        XCTAssertEqual(here.first?.time, now.addingTimeInterval(-0.1 * 86_400))
        let others = try await history.recent(space: space, device: "this", others: true)
        XCTAssertEqual(others.map(\.page.title), ["Notion"], "the other devices' own, and only this space's")
    }

    func testTheFilterNarrowsTheListAndTheSearchByDeviceAndDay() async throws {
        let history = try store()
        try await history.record(try visit("https://figma.com/a", title: "Figma today", daysAgo: 0.01), now: now)
        try await history.record(try visit("https://figma.com/b", title: "Figma last week", daysAgo: 5), now: now)
        var there = try visit("https://figma.com/c", title: "Figma there", daysAgo: 0.02)
        there.device = "other"
        try await history.merge([there], now: now)
        let calendar = Calendar(identifier: .gregorian)
        func titles(_ filter: HistoryFilter) async throws -> [String] {
            try await history.entries(space: space, scope: filter.scope(device: "this", now: now, calendar: calendar)).map(\.page.title)
        }
        let all = try await titles(HistoryFilter())
        XCTAssertEqual(all, ["Figma today", "Figma there", "Figma last week"])
        let here = try await titles(HistoryFilter(source: .thisDevice))
        XCTAssertEqual(here, ["Figma today", "Figma last week"])
        let others = try await titles(HistoryFilter(source: .otherDevices))
        XCTAssertEqual(others, ["Figma there"])
        let week = try await titles(HistoryFilter(source: .thisDevice, period: .week))
        XCTAssertEqual(week, ["Figma today", "Figma last week"], "five days ago is within the last seven")
        let yesterday = try await titles(HistoryFilter(period: .yesterday))
        XCTAssertTrue(yesterday.isEmpty)
        let found = try await history.search(space: space, query: HistoryQuery(words: "figma"),
                                             scope: HistoryFilter(source: .otherDevices).scope(device: "this", now: now, calendar: calendar))
        XCTAssertEqual(found.map(\.title), ["Figma there"], "the search keeps to the filter too")
        let span = HistoryFilter(period: .yesterday).scope(device: "this", now: now, calendar: calendar)
        let found2 = try await history.search(space: space, query: HistoryQuery(words: "figma", from: now.addingTimeInterval(-10 * 86_400)),
                                              scope: span)
        XCTAssertTrue(found2.isEmpty, "the words' stretch of time within the filter's")
    }

    func testAClearingGoesByAVisitsStampAndShowsByItsTime() async throws {
        let history = try store()
        // A visit made after this device saw a clearing from a device a day ahead:
        // today by its own clock, after the clearing by the sync clock.
        let cleared = now.addingTimeInterval(86_400)
        try await history.remove(HistoryRemoval(space: space, scope: .all, made: cleared), now: now)
        var later = try visit("https://figma.com/a", title: "Figma")
        later.stamp = cleared.addingTimeInterval(0.001)
        try await history.record(later, now: now)
        let left = try await history.entries(space: space)
        XCTAssertEqual(left.map(\.page.url.absoluteString), ["https://figma.com/a"], "after the clearing: kept")
        XCTAssertEqual(left.first?.time, now, "and shown at its own time, not a day ahead")
        let found = try await history.search(space: space, query: HistoryQuery(words: "figma", from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60)))
        XCTAssertEqual(found.map(\.title), ["Figma"], "found today")
    }

    func testAStoreFromBeforeStampsGetsThem() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE visits (id TEXT PRIMARY KEY, space TEXT NOT NULL, page TEXT NOT NULL, url TEXT NOT NULL, time REAL NOT NULL,
                device TEXT NOT NULL, kind TEXT NOT NULL, search TEXT);
            PRAGMA user_version = 1;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let history = try HistoryStore(url: file)
        var visit = try visit("https://figma.com/a", title: "Figma")
        visit.stamp = now.addingTimeInterval(5)
        try await history.record(visit, now: now)
        let sent = try await history.visits(device: "this", since: .distantPast)
        XCTAssertEqual(sent.first?.stamp, visit.stamp, "kept in the column added")
        let reopened = try HistoryStore(url: file)
        XCTAssertEqual(reopened.latestWhenOpened, visit.stamp, "opened again without adding it twice")
    }

    func testAStoreStoppedHalfwayThroughAddingStampsOpens() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE visits (id TEXT PRIMARY KEY, space TEXT NOT NULL, page TEXT NOT NULL, url TEXT NOT NULL, time REAL NOT NULL,
                device TEXT NOT NULL, kind TEXT NOT NULL, search TEXT, stamp REAL);
            PRAGMA user_version = 1;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertNoThrow(try HistoryStore(url: file), "the column there, the version not yet: no second ALTER")
    }

    func testTheLatestTimeHeldIsKnownAsTheStoreOpens() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var history: HistoryStore? = try HistoryStore(url: file)
        XCTAssertNil(history?.latestWhenOpened, "nothing held")
        try await history?.record(try visit("https://figma.com/a", title: "Figma"), now: now)
        let ahead = now.addingTimeInterval(2 * 86_400)
        try await history?.remove(HistoryRemoval(space: space, scope: .all, made: ahead), now: now)
        history = nil
        let reopened = try HistoryStore(url: file)
        XCTAssertEqual(reopened.latestWhenOpened, ahead, "a clearing from a device two days ahead")
    }

    func testAClearingKeepsItsOwnTimeAcrossLaunches() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var history: HistoryStore? = try HistoryStore(url: file)
        let removal = HistoryRemoval(space: space, scope: .all, made: now.addingTimeInterval(86_400), wall: now)
        try await history?.remove(removal, now: now)
        history = nil
        let reopened = try HistoryStore(url: file)
        let kept = await reopened.allRemovals()
        XCTAssertEqual(kept.first?.wall, now, "its device's own time, for Reopen Closed Tab, as well as the sync clock's")
    }

    func testAClearingThatCantBeReadIsCounted() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var history: HistoryStore? = try HistoryStore(url: file)
        let removal = HistoryRemoval(space: space, scope: .all, made: now)
        try await history?.remove(removal, now: now)
        let none = await history?.unreadableRemovals
        XCTAssertEqual(none, 0)
        history = nil
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO removals (id, space, scope, made) VALUES ('\(UUID().uuidString)', NULL, 'not a scope', 0);
            INSERT INTO removals (id, space, scope, made) VALUES ('not an id', NULL, '"all"', 0);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let reopened = try HistoryStore(url: file)
        let kept = await reopened.allRemovals()
        XCTAssertEqual(kept.map(\.id), [removal.id], "the one that reads is kept")
        let unreadable = await reopened.unreadableRemovals
        XCTAssertEqual(unreadable, 2, "the two that don't are counted, not forgotten silently")
    }

    func testAVisitTakenBackPutsBackWhatThePageWasCalled() async throws {
        let history = try store()
        try await history.record(try visit("https://bank.example/account", title: "Accounts", daysAgo: 1), now: now)
        // The same address, later, a sign-in page that renames it before its password field shows.
        let signIn = try visit("https://bank.example/account", title: "Accounts")
        try await history.record(signIn, now: now)
        _ = try await history.update(space: space, url: try url("https://bank.example/account"), title: "Sign in to Bank",
                                     summary: "Enter your password")
        try await history.forget(visit: signIn.id, now: now)
        let named = try await history.search(space: space, query: HistoryQuery(words: "accounts"))
        XCTAssertEqual(named.map(\.title), ["Accounts"])
        let said = try await history.search(space: space, query: HistoryQuery(words: "password"))
        XCTAssertTrue(said.isEmpty, "nothing the sign-in page said stays")
    }

    func testAnAddressIsFoundByItsPartsAndTagsAreNotAPage() async throws {
        let history = try store()
        try await history.record(try visit("https://www.github.com/apple/swift-nio/blob/main/README.md#install", title: "Repository"),
                                 now: now)
        for typed in ["swift-nio", "apple/swift", "README.md", "github.com", "install"] {
            let found = try await history.search(space: space, query: HistoryQuery(words: typed))
            XCTAssertEqual(found.count, 1, typed)
        }
        XCTAssertEqual(History.pageKey(try url("https://example.com/post?utm_source=mail")),
                       History.pageKey(try url("https://example.com/post")))
    }

    func testAClearedSearchIsNotOfferedAgain() async throws {
        let history = try store()
        let page = "https://www.google.com/search?q=secret"
        try await history.record(try visit(page, title: "secret - Google Search", daysAgo: 2), now: now)
        var typed = try visit(page, title: "secret - Google Search", kind: .typed)
        typed.search = "secret"
        try await history.record(typed, now: now)
        var found = try await history.search(space: space, query: HistoryQuery(words: "secret"))
        XCTAssertEqual(found.first?.search, "secret")
        try await history.remove(HistoryRemoval(space: space, scope: .range(from: now.addingTimeInterval(-3600), to: now), made: now),
                                 now: now)
        found = try await history.search(space: space, query: HistoryQuery(words: "secret"))
        XCTAssertEqual(found.count, 1, "the older visit stays")
        XCTAssertNil(found.first?.search, "the words typed went with their visit")
    }

    func testOldVisitsAreLetGoAndANameComesInLater() async throws {
        let history = try store()
        try await history.record(try visit("https://figma.com/a", title: "Old", daysAgo: 40), now: now)
        try await history.record(try visit("https://figma.com/b", daysAgo: 1), now: now)
        try await history.update(space: space, url: try url("https://figma.com/b"), title: "Named later", summary: "About it")
        try await history.prune(keeping: .month, now: now)
        let left = try await history.search(space: space, query: HistoryQuery(words: ""))
        XCTAssertEqual(left.map(\.title), ["Named later"])
        let byDescription = try await history.search(space: space, query: HistoryQuery(words: "about"))
        XCTAssertEqual(byDescription.count, 1, "the description is searchable once it comes")
        let forever = try store()
        try await forever.record(try visit("https://figma.com/a", title: "Old", daysAgo: 400), now: now)
        try await forever.prune(keeping: .forever, now: now)
        let kept = try await forever.entries(space: space)
        XCTAssertEqual(kept.count, 1, "until cleared: nothing let go")
    }

    func testThisDevicesVisitsGoOutWithTheirPagesNames() async throws {
        let history = try store()
        try await history.record(try visit("https://figma.com/a", title: "Figma", daysAgo: 1), now: now)
        try await history.merge([HistoryVisit(space: space, url: try url("https://b.com"), time: now, device: "other", kind: .link)], now: now)
        let mine = try await history.visits(device: "this", since: now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(mine.map(\.title), ["Figma"], "only this device's own")
    }

    func testAPagesLastVisitsAreReadByAnIndexOfItsOwn() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE visits (id TEXT PRIMARY KEY, space TEXT NOT NULL, page TEXT NOT NULL, url TEXT NOT NULL, time REAL NOT NULL,
                device TEXT NOT NULL, kind TEXT NOT NULL, search TEXT, stamp REAL, sync_epoch TEXT, sync_title TEXT, sync_summary TEXT);
            CREATE INDEX visits_by_page ON visits(space, page);
            CREATE TABLE removals (id TEXT PRIMARY KEY, space TEXT, scope TEXT NOT NULL, made REAL NOT NULL, wall REAL);
            PRAGMA user_version = 4;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        var history: HistoryStore? = try HistoryStore(url: file)
        try await history?.record(try visit("https://figma.com/a", title: "Figma"), now: now)
        history = nil
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func rows(_ sql: String, column: Int32) -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var found: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { found.append(String(cString: sqlite3_column_text(statement, column))) }
            return found
        }
        let indexes = rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'visits'", column: 0)
        XCTAssertTrue(indexes.contains("visits_by_page_time"))
        XCTAssertFalse(indexes.contains("visits_by_page"), "the one by page alone, which it starts with, let go")
        for sql in ["SELECT time, kind, url FROM visits WHERE space = ?1 AND page = ?2 ORDER BY time DESC LIMIT 10",
                    "SELECT search FROM visits WHERE space = ?1 AND page = ?2 AND search IS NOT NULL ORDER BY time DESC LIMIT 1"] {
            let plan = rows("EXPLAIN QUERY PLAN " + sql, column: 3).joined(separator: " ")
            XCTAssertTrue(plan.contains("visits_by_page_time"), plan)
            XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
        }
        XCTAssertEqual(rows("PRAGMA user_version", column: 0), ["5"])
    }

    func testASearchLetGoOfIsNotLookedFor() async throws {
        let history = try store()
        try await history.record(try visit("https://figma.com/a", title: "Figma"), now: now)
        let space = self.space
        let found = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.search(space: space, query: HistoryQuery(words: "figma"))
        }.value
        XCTAssertTrue(found.isEmpty)
        let wanted = try await history.search(space: space, query: HistoryQuery(words: "figma"))
        XCTAssertEqual(wanted.count, 1)
    }
    #endif
}
