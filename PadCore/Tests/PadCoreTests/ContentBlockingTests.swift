import XCTest
@testable import PadCore
#if canImport(WebKit)
import WebKit
#endif

final class ContentBlockingTests: XCTestCase {
    private func network(_ text: String) -> [BlockingRule] {
        FilterConverter.convert(text).network
    }

    /// The url-filter as a regular expression, matched case-insensitively as WebKit does.
    private func matches(_ filter: String, _ url: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    func testADomainAnchorTakesTheSiteAndItsSubdomainsOnly() throws {
        let rule = try XCTUnwrap(network("||ads.example.com^").first)
        XCTAssertEqual(rule.action, .block)
        let filter = rule.trigger.urlFilter
        XCTAssertTrue(matches(filter, "https://ads.example.com/banner.png"))
        XCTAssertTrue(matches(filter, "https://cdn.ads.example.com:8443/x"))
        // WebKit matches the address as it writes it: a path after the host, always.
        XCTAssertTrue(matches(filter, "https://ads.example.com/"))
        XCTAssertTrue(matches(filter, "http://ads.example.com/?id=1"))
        XCTAssertFalse(matches(filter, "https://notads.example.com/"))
        XCTAssertFalse(matches(filter, "https://ads.example.community/"))
        XCTAssertFalse(matches(filter, "https://example.com/?u=https://ads.example.com/"))
    }

    func testSeparatorsWildcardsAndAnchors() throws {
        // Ending in a separator, away from a host: a separator, or the end.
        let ends = network("/banner/*/img^").map(\.trigger.urlFilter)
        XCTAssertEqual(ends.count, 2)
        let either = { (url: String) in ends.contains { self.matches($0, url) } }
        XCTAssertTrue(either("https://site.test/banner/big/img?x=1"))
        XCTAssertTrue(either("https://site.test/banner/big/img"))
        XCTAssertFalse(either("https://site.test/banner/big/imgs"))
        let middle = try XCTUnwrap(network("/ad^frame").first?.trigger.urlFilter)
        XCTAssertTrue(matches(middle, "https://site.test/ad/frame"))
        XCTAssertFalse(matches(middle, "https://site.test/adsframe"))
        let start = try XCTUnwrap(network("|https://ads.").first?.trigger.urlFilter)
        XCTAssertTrue(matches(start, "https://ads.site.test/"))
        XCTAssertFalse(matches(start, "http://x.test/?https://ads."))
        let end = try XCTUnwrap(network(".gif|").first?.trigger.urlFilter)
        XCTAssertTrue(matches(end, "https://x.test/a.gif"))
        XCTAssertFalse(matches(end, "https://x.test/a.gif?x"))
        XCTAssertEqual(network("-ad-banner.").first?.trigger.urlFilter, "-ad-banner\\.")
    }

    func testOptionsBecomeTheTrigger() throws {
        let rule = try XCTUnwrap(network("||tracker.test/p.js$script,third-party,domain=a.test|b.test").first)
        XCTAssertEqual(rule.trigger.resourceType, ["script"])
        XCTAssertEqual(rule.trigger.loadType, ["third-party"])
        XCTAssertEqual(rule.trigger.ifDomain, ["*a.test", "*b.test"])
        XCTAssertNil(rule.trigger.unlessDomain)
        let unless = try XCTUnwrap(network("/ads.js$~third-party,domain=~safe.test").first)
        XCTAssertEqual(unless.trigger.loadType, ["first-party"])
        XCTAssertEqual(unless.trigger.unlessDomain, ["*safe.test"])
        XCTAssertEqual(network("/AdUnit$match-case").first?.trigger.caseSensitive, true)
        XCTAssertEqual(network("||x.test^$xmlhttprequest,ping").first?.trigger.resourceType, ["ping", "raw"])
    }

    func testAFrameIsADocumentInsideThePage() throws {
        let rules = network("||ads.test^$subdocument,script")
        XCTAssertEqual(rules.count, 2, "the script, and the frame")
        XCTAssertEqual(rules[0].trigger.resourceType, ["script"])
        XCTAssertEqual(rules[1].trigger.resourceType, ["document"])
        XCTAssertEqual(rules[1].trigger.loadContext, ["child-frame"])
    }

    func testWhatWebKitCantSayIsLeftOut() {
        for filter in ["||x.test^$redirect=noop.js", "||x.test^$csp=script-src 'none'",
                       "$removeparam=utm_source", "/ads$domain=a.test|~b.a.test", "/(ads|banner)\\.js/",
                       "/ad\\d+\\.js/", "/a{2}/", "||bücher.test^", "||x.test^$object"] {
            let converted = FilterConverter.convert(filter)
            XCTAssertTrue(converted.network.isEmpty, filter)
            XCTAssertEqual(converted.skipped, 1, filter)
        }
        XCTAssertEqual(network("/ad[0-9]+\\.js/").first?.trigger.urlFilter, "ad[0-9]+\\.js")
        // A type WebKit lacks is left out of a filter that names others too.
        XCTAssertEqual(network("||x.test^$object,script").first?.trigger.resourceType, ["script"])
    }

    func testAWindowOpenedToAnAdvertiserIsBlockedAsALoadOfItsOwnKind() throws {
        let alone = FilterConverter.convert("||ads.test^$popup,third-party")
        XCTAssertTrue(alone.blocks.isEmpty, "$popup alone is about windows only")
        XCTAssertEqual(alone.skipped, 0)
        let window = try XCTUnwrap(alone.popups.first)
        XCTAssertEqual(window.trigger.resourceType, ["popup"])
        XCTAssertEqual(window.trigger.loadType, ["third-party"])
        XCTAssertEqual(window.action, .block)
        let both = FilterConverter.convert("/earn.php?z=$popup,subdocument")
        XCTAssertEqual(both.popups.count, 1)
        XCTAssertEqual(both.blocks.first?.trigger.loadContext, ["child-frame"], "and the frame, as before")
        let allowed = FilterConverter.convert("@@||shop.test/pay^$popup")
        XCTAssertTrue(allowed.popups.isEmpty)
        XCTAssertEqual(allowed.exceptions.first?.trigger.resourceType, ["popup"])
        XCTAssertEqual(FilterConverter.convert("||x.test^$~popup").blocks.count, 1, "not popups: every other load")
    }

    func testExceptionsComeAfterBlockingAndImportantAfterThem() throws {
        let rules = ContentBlocking.network([FilterConverter.convert("""
        ||a.test^$important
        @@||b.test/ok.js
        ||b.test^
        """)])
        XCTAssertEqual(rules.map(\.action.type), ["block", "ignore-previous-rules", "block", "ignore-previous-rules"])
        XCTAssertTrue(rules[0].trigger.urlFilter.contains("b\\.test"))
        XCTAssertTrue(rules[1].trigger.urlFilter.contains("b\\.test/ok"))
        XCTAssertTrue(rules[2].trigger.urlFilter.contains("a\\.test"), "$important: no exception undoes it")
        XCTAssertEqual(rules[3].trigger.resourceType, ["document"], "and last, the page you went to always loads")
        XCTAssertEqual(rules[3].trigger.loadContext, ["top-frame"])
    }

    func testAWholeSiteException() throws {
        let rule = try XCTUnwrap(FilterConverter.convert("@@||news.test^$document").exceptions.first)
        XCTAssertEqual(rule.action, .allow)
        XCTAssertEqual(rule.trigger.urlFilter, ".*")
        XCTAssertEqual(rule.trigger.ifDomain, ["*news.test"])
    }

    func testBadfilterTurnsAFilterOff() {
        let converted = FilterConverter.convert("""
        ||a.test^
        ||a.test^$badfilter
        ||b.test^
        """)
        XCTAssertEqual(converted.blocks.count, 1)
        XCTAssertTrue(converted.blocks[0].trigger.urlFilter.contains("b\\.test"))
    }

    func testHidingIsGroupedAndHonoursExceptions() throws {
        let hiding = FilterConverter.convert("""
        ##.ad
        ##.banner
        ###sponsor
        example.test#@#.ad
        ~other.test##.promo
        shop.test,deals.test##.offer
        #@#.banner
        """).hiding
        XCTAssertEqual(hiding.count, 4)
        let ad = try XCTUnwrap(hiding.first { $0.action.selector == ".ad" })
        XCTAssertEqual(ad.trigger.unlessDomain, ["*example.test"])
        let promo = try XCTUnwrap(hiding.first { $0.action.selector == ".promo" })
        XCTAssertEqual(promo.trigger.unlessDomain, ["*other.test"])
        let grouped = try XCTUnwrap(hiding.first { $0.action.selector == "#sponsor" })
        XCTAssertNil(grouped.trigger.unlessDomain)
        XCTAssertFalse(hiding.contains { $0.action.selector?.contains(".banner") == true }, "#@# with no site: hidden nowhere")
        let offer = try XCTUnwrap(hiding.first { $0.action.selector == ".offer" })
        XCTAssertEqual(offer.trigger.ifDomain, ["*deals.test", "*shop.test"])
    }

    func testSelectorsAreGroupedFiftyToARule() {
        let text = (0..<120).map { "##.ad-\($0)" }.joined(separator: "\n")
        let hiding = FilterConverter.convert(text).hiding
        XCTAssertEqual(hiding.count, 3)
        XCTAssertEqual(hiding[0].action.selector?.components(separatedBy: ", ").count, 50)
    }

    func testHidingWebKitCantParseGoesToThePagesScriptOrIsLeftOut() {
        let converted = FilterConverter.convert("""
        ##div:-abp-has(.ad)
        ##+js(nowebrtc)
        example.test##^script:has-text(ads)
        ##.a::before
        ##div[class="unclosed]
        ##.x:upward(2)
        ##div:has(> .a:has(.b))
        example.test#?#div:has-text(Sponsored)
        example.*##.wild
        """)
        XCTAssertTrue(converted.hiding.isEmpty)
        XCTAssertEqual(converted.skipped, 7, "for every site, or nothing a script here can do")
        XCTAssertEqual(converted.scripted.map(\.action), [.hide([.css("div"), .text("Sponsored")]), .css(".wild")],
                       "a site's own, which the script in its pages does")
        XCTAssertEqual(converted.scripted.map(\.domains), [["example.test"], ["example.*"]])
        XCTAssertEqual(FilterConverter.convert("##div:has(> .sponsored):not(.keep)").hiding.count, 1)
        XCTAssertEqual(FilterConverter.convert("##.trailing\\").hiding.count, 0, "an escape with nothing after it")
        XCTAssertEqual(FilterConverter.convert("##a[href^=\"https://ads.test/\"]").hiding.count, 1)
    }

    func testAQuotedValueMayHoldAnything() {
        // The page's own text, not CSS: a style attribute's semicolons, a Korean address.
        let converted = FilterConverter.convert("""
        news.test##div#article>div[style="margin:35px 0 10px 0;text-align:center;"]
        ~ad.test##a[href*="//광고.com"]
        ##div[style*="display: block !important"]
        ##a[title="{x}"]
        """)
        XCTAssertEqual(converted.skipped, 0)
        XCTAssertEqual(converted.hiding.count, 3)
        XCTAssertTrue(converted.hiding.contains { $0.action.selector?.contains("광고") == true })
        // Outside quotes they could end the rule and start another: never.
        for selector in ["##.a { color: red }", "##.a;.b", "##.a !important", "##.광고"] {
            XCTAssertTrue(FilterConverter.convert(selector).hiding.isEmpty, selector)
        }
    }

    func testTheRulesWrittenByHandReadAsTheEncodersDo() throws {
        let rules = FilterConverter.convert("""
        ||tracker.test/p.js$script,third-party,domain=a.test|b.test
        /AdUnit$match-case
        @@||b.test/ok.js
        news.test##a[title="say \\"hi\\"\\\\"]
        ~ad.test##a[href*="//광고.com"]
        """)
        let all = rules.network + rules.hiding
        XCTAssertEqual(all.count, 5)
        let written = try JSONSerialization.jsonObject(with: Data(ContentBlocking.json(all).utf8)) as? NSArray
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(all)) as? NSArray
        XCTAssertNotNil(written)
        XCTAssertEqual(written, encoded)
        XCTAssertEqual(ContentBlocking.json([]), "[]")
    }

    func testNoHidingOnASiteWithElemhide() throws {
        let hiding = FilterConverter.convert("""
        @@||app.test^$elemhide
        @@||mail.test^$generichide
        ##.ad
        app.test##.x
        mail.test##.y
        """).hiding
        let generic = try XCTUnwrap(hiding.first { $0.action.selector == ".ad" })
        XCTAssertEqual(generic.trigger.unlessDomain, ["*app.test", "*mail.test"])
        XCTAssertNil(hiding.first { $0.action.selector == ".x" }, "$elemhide: not even the site's own")
        XCTAssertEqual(hiding.first { $0.action.selector == ".y" }?.trigger.ifDomain, ["*mail.test"])
    }

    func testHidingIsToldByDocumentsOnly() {
        let hiding = FilterConverter.convert("""
        @@||mail.test^$generichide
        ##.ad
        ##.banner
        mail.test#@#.banner
        news.test##.promo
        """).hiding
        XCTAssertEqual(hiding.count, 3)
        XCTAssertTrue(hiding.allSatisfy { $0.trigger.resourceType == ["document"] })
    }

    func testTheHeaderSaysTheVersionAndHowLongItKeeps() {
        let converted = FilterConverter.convert("""
        [Adblock Plus 2.0]
        ! Version: 202610080509
        ! Expires: 4 days (update frequency)
        """)
        XCTAssertEqual(converted.version, "202610080509")
        XCTAssertEqual(converted.expires, 4 * 86400)
        XCTAssertEqual(FilterConverter.convert("! Expires: 12 hours").expires, 12 * 3600)
    }

    func testBlockingGoesInListsSmallEnoughToCompileEachWithTheExceptions() throws {
        var big = FilterRules()
        big.blocks = Array(repeating: BlockingRule(trigger: .init(urlFilter: "ad"), action: .block), count: 3 * ContentBlocking.networkPerList)
        big.exceptions = [BlockingRule(trigger: .init(urlFilter: "ok"), action: .allow)]
        var other = FilterRules()
        other.blocks = [BlockingRule(trigger: .init(urlFilter: "track"), action: .block)]
        other.important = [BlockingRule(trigger: .init(urlFilter: "must"), action: .block)]
        let plan = ContentBlocking.plan([big, other])
        XCTAssertEqual(plan.count, 4)
        // Nothing is lost: every rule of blocking is in one list or another.
        XCTAssertEqual(plan.map(\.rules).reduce(0, +), 3 * ContentBlocking.networkPerList + 1 + plan.count * 3)
        for list in plan {
            XCTAssertLessThanOrEqual(list.rules, ContentBlocking.networkPerList + 3, "so much blocking, and its tail")
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.json.utf8)) as? [[String: Any]])
            XCTAssertEqual(rules.count, list.rules)
            let end = rules.suffix(3).compactMap { rule -> String? in
                let filter = (rule["trigger"] as? [String: Any])?["url-filter"] as? String
                let type = (rule["action"] as? [String: Any])?["type"] as? String
                return "\(filter ?? "") \(type ?? "")"
            }
            XCTAssertEqual(end, ["ok ignore-previous-rules", "must block", ".* ignore-previous-rules"],
                           "the exception, what no exception undoes, then the page itself, at each list's end")
        }
        XCTAssertLessThanOrEqual(ContentBlocking.networkPerList, ContentBlocking.rulesPerList)
    }

    func testAListOfBlockingEndsWithTheExceptionsThatCouldApplyToIt() throws {
        let rules = FilterConverter.convert("""
        ||ads.shop.test^
        ||track.news.test/pixel
        /banner/ad.
        @@||shop.test/checkout/ads.js
        @@||cdn.other.test^$script
        @@/ads/allowed.$domain=blog.test
        ||must.test^$important
        """)
        XCTAssertEqual(rules.blocks.map(\.site), ["ads.shop.test", "track.news.test", nil])
        XCTAssertEqual(rules.exceptions.map(\.site), ["shop.test", "cdn.other.test", nil])
        // Tied to a host only where the host is ended: "||ads.test" matches ads.testing.org too.
        for loose in ["||ads.test", "||ads.*.test^", "|https://ads.test/", "/ads.test/", "||localhost^"] {
            XCTAssertNil(FilterConverter.convert(loose).blocks.first?.site, loose)
        }
        var planner = RulePlanner()
        planner.add(rules)
        let plan = planner.lists()
        XCTAssertEqual(plan.count, 2)
        func filters(_ list: PlannedList) throws -> [String] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.json.utf8)) as? [[String: Any]]).compactMap {
                (($0["trigger"] as? [String: Any])?["url-filter"] as? String)
            }
        }
        // What could match anywhere ends with every exception.
        let anywhere = try filters(plan[0])
        XCTAssertEqual(anywhere.count, 1 + 3 + 1 + 1)
        XCTAssertTrue(anywhere.contains { $0.contains("cdn\\.other") })
        // What is tied to hosts ends with the exceptions for its own sites and the ones
        // tied to none: never another site's, which could not match what it blocks.
        let tied = try filters(plan[1])
        XCTAssertEqual(tied.count, 2 + 2 + 1 + 1)
        XCTAssertTrue(tied.contains { $0.contains("shop\\.test/checkout") }, "shop.test's own, for ads.shop.test")
        XCTAssertTrue(tied.contains { $0.contains("allowed") }, "tied to no host: it could match anywhere")
        XCTAssertFalse(tied.contains { $0.contains("cdn\\.other") })
        XCTAssertTrue(tied[tied.count - 2].contains("must"), "then what no exception undoes")
        XCTAssertEqual(tied.last, ".*", "then the page itself")
        XCTAssertEqual(RulePlanner.key("a.b.shop.co.kr"), "co.kr", "an ending of two names takes in more, never less")
        XCTAssertNil(rules.blocks[0].site.flatMap { _ in ContentBlocking.json(rules.blocks).range(of: "site") },
                     "the site is the planner's to sort by, not WebKit's to read")
    }

    func testThePlannerTakesAListsRulesAsTheyAreReadAndCountsThem() {
        let text = """
        ! Version: 3
        ! Expires: 2 days
        ||a.test^
        @@||a.test/ok
        ##.ad
        news.test#?#div:has-text(Sponsored)
        ||x.test^$redirect=noop.js
        """
        var planner = RulePlanner()
        FilterConverter.convert(text, into: &planner)
        FilterConverter.convert("! Last modified: 12 Oct 2026 13:42 UTC\n||b.test^", into: &planner)
        XCTAssertEqual(planner.kept, [4, 1])
        XCTAssertEqual(planner.skipped, [1, 0])
        XCTAssertEqual(planner.stamps, ["3", "12 Oct 2026 13:42 UTC"], "a list with no version is known by when it changed")
        XCTAssertEqual(planner.expires, 2 * 86400)
        XCTAssertEqual(planner.scripted.count, 1)
        // The same lists by way of FilterRules come to the same rule lists.
        let direct = planner.lists()
        let collected = ContentBlocking.plan([FilterConverter.convert(text),
                                             FilterConverter.convert("! Last modified: 12 Oct 2026 13:42 UTC\n||b.test^")])
        XCTAssertEqual(direct, collected)
        XCTAssertEqual(direct.map(\.rules), [4, 1])
        // Each rule list's text is made when it is asked for, and is the same each time.
        let plan = planner.plan()
        XCTAssertEqual(plan.entries.map(\.rules), [4, 1])
        XCTAssertEqual(plan.list(0), direct[0])
    }

    func testPopupsAndHidingHaveListsOfTheirOwn() throws {
        let rules = FilterConverter.convert("""
        ! Version: 7
        ||a.test^
        ||pop.test^$popup
        @@||fine.test^
        @@||shop.test/pay^$popup
        @@||news.test^$document
        ##.ad
        shop.*##.promo
        """)
        var planner = RulePlanner()
        planner.add(rules)
        let plan = planner.lists()
        XCTAssertEqual(plan.map { $0.id.components(separatedBy: ".").suffix(2).joined(separator: ".") },
                       ["network.0", "popups.0", "hiding.0"])
        // The list of blocking: the block, the one exception that could apply to it (a whole
        // site's, tied to no host) and the page itself. "@@||fine.test^" is about another site.
        // The popups: the block, "/pay^" as two rules (a separator after it, or the address's
        // end), and the whole site's.
        XCTAssertEqual(plan.map(\.rules), [3, 4, 1])
        XCTAssertFalse(plan[0].json.contains("fine"))
        let popups = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plan[1].json.utf8)) as? [[String: Any]])
        XCTAssertEqual((popups[0]["trigger"] as? [String: Any])?["resource-type"] as? [String], ["popup"])
        // Only the exceptions about windows, or about a whole site: to the
        // lists, "@@||fine.test^" lets no window through.
        let allowed = popups.dropFirst().compactMap { $0["trigger"] as? [String: Any] }
        XCTAssertEqual(allowed.count, 3)
        XCTAssertEqual(allowed[0]["resource-type"] as? [String], ["popup"])
        XCTAssertEqual(allowed[1]["resource-type"] as? [String], ["popup"])
        XCTAssertEqual(allowed[2]["if-domain"] as? [String], ["*news.test"])
        XCTAssertFalse(plan[1].json.contains("fine"))
        XCTAssertEqual(planner.scripted.count, 1, "and what is left for the page's script comes with them")
        // With nothing at all, nothing to compile.
        XCTAssertTrue(RulePlanner().lists().isEmpty)
    }

    func testThePlanAndItsIdentifiers() {
        var one = FilterConverter.convert("! Version: 1\n||a.test^\n##.ad")
        let plan = ContentBlocking.plan([one])
        XCTAssertEqual(plan.map(\.rules), [2, 1])
        XCTAssertTrue(plan[0].id.hasSuffix(".network.0"))
        XCTAssertTrue(plan[1].id.hasSuffix(".hiding.0"))
        let decoded = try? JSONSerialization.jsonObject(with: Data(plan[0].json.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertNotNil(decoded?.first?["trigger"])
        one.version = "2"
        XCTAssertNotEqual(ContentBlocking.plan([one])[0].id, plan[0].id, "a new version of a list compiles anew")
    }

    // MARK: The lists there are

    func testTheCatalogueOfLists() throws {
        let lists = ContentBlocking.lists
        XCTAssertEqual(Set(lists.map(\.id)).count, lists.count)
        XCTAssertEqual(lists.filter(\.bundled).map(\.id), ["easylist", "easyprivacy", "youslist"])
        // The best known first (the stars each list's repository has on GitHub).
        XCTAssertEqual(lists.map(\.id), ["easylist", "easyprivacy", "cookies", "easylistchina", "youslist", "antiadblock",
                                         "easylistgermany", "liste_fr", "easylistspanish", "koreanlist", "easylistitaly",
                                         "easylistportuguese", "easylistdutch"])
        for list in lists {
            XCTAssertEqual(list.url.scheme, "https", list.name)
            XCTAssertFalse(list.credit.isEmpty, "\(list.name): its licence asks that it be named")
            XCTAssertEqual(list.bundled, ContentBlocking.bundledFile(list) != nil, "\(list.name) ships, or is downloaded")
            if list.bundled {
                // A download is known for the list by its own title.
                let text = try XCTUnwrap(ContentBlocking.bundled(list))
                XCTAssertTrue(text.hasPrefix("[Adblock Plus"), list.name)
                XCTAssertTrue(text.prefix(2_000).contains("! Title: \(list.title)"), list.name)
                XCTAssertGreaterThan(text.utf8.count, list.leastSize, list.name)
            }
        }
    }

    func testWhichListsStartOutOn() throws {
        let on = { (languages: [String], region: String?) in
            Preferences().filterLists(languages: ContentBlocking.languages(of: languages), region: region).map(\.id)
        }
        XCTAssertEqual(on(["en-US"], "US"), ["easylist", "easyprivacy", "youslist", "antiadblock"])
        XCTAssertEqual(on(["ko-KR", "en-KR"], "KR"), ["easylist", "easyprivacy", "youslist", "antiadblock", "koreanlist"])
        XCTAssertTrue(on(["en-KR"], "KR").contains("koreanlist"), "an English iPhone in Korea")
        XCTAssertTrue(on(["en-US", "ko-US"], "US").contains("koreanlist"), "Korean as a second language")
        XCTAssertTrue(on(["zh-Hans-CN"], "CN").contains("easylistchina"))
        XCTAssertTrue(on(["de-CH"], "CH").contains("easylistgermany"))
        XCTAssertFalse(on(["ko-KR"], "KR").contains("cookies"), "cookie banners only when asked for")
        XCTAssertEqual(ContentBlocking.languages(of: ["zh-Hans-CN", "zh-Hant-TW", "pt_BR", ""]), ["zh", "pt"])

        var preferences = Preferences()
        let cookies = try XCTUnwrap(ContentBlocking.lists.first { $0.id == "cookies" })
        let korean = try XCTUnwrap(ContentBlocking.lists.first { $0.id == "youslist" })
        preferences.filterLists["cookies"] = true
        preferences.filterLists["youslist"] = false
        XCTAssertTrue(preferences.uses(cookies, languages: ["en"], region: "US"))
        XCTAssertFalse(preferences.uses(korean, languages: ["ko"], region: "KR"), "a choice made stands, whatever the language")
        let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(saved.filterLists, ["cookies": true, "youslist": false])
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).filterLists, [:])
    }

    // MARK: The lists the app ships with

    private func bundled() throws -> [FilterRules] {
        try ContentBlocking.lists.filter(\.bundled).map { list in
            FilterConverter.convert(try XCTUnwrap(ContentBlocking.bundled(list), list.name))
        }
    }

    func testTheBundledListsFitWebKitsLimits() throws {
        let converted = try bundled()
        XCTAssertEqual(converted.count, 3, "EasyList, EasyPrivacy and YousList")
        let network = ContentBlocking.network(converted)
        XCTAssertLessThanOrEqual(network.count, ContentBlocking.rulesPerList)
        XCTAssertGreaterThan(network.count, 50_000)
        for rules in converted {
            XCTAssertFalse(rules.stamp.isEmpty)
            let lines = rules.count + rules.skipped
            XCTAssertLessThan(Double(rules.skipped) / Double(max(lines, 1)), 0.02, "nearly all of the list is kept")
        }
        // The Korean list's hiding by a style attribute, which a converter that turned down ";" lost.
        XCTAssertGreaterThan(converted[2].hiding.count, 1_500)
        XCTAssertTrue(converted[2].hiding.contains { $0.action.selector?.contains("text-align:center;") == true })
        XCTAssertGreaterThan(converted[0].popups.count, 2_000, "EasyList's popups")
        XCTAssertGreaterThan(converted[0].scripted.count, 400, "and its filters for the page's script")
        for list in ContentBlocking.plan(converted) {
            XCTAssertLessThanOrEqual(list.rules, ContentBlocking.rulesPerList)
        }
    }

    #if canImport(WebKit)
    /// WebKit itself compiles every list of the plan: one url-filter or
    /// selector it turned down would fail a list in the app.
    @MainActor
    func testWebKitCompilesTheBundledLists() throws {
        let plan = ContentBlocking.plan(try bundled())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContentBlockingTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        var failures: [String] = []
        for list in plan {
            let compiled = expectation(description: list.id)
            store.compileContentRuleList(forIdentifier: list.id, encodedContentRuleList: list.json) { compiledList, error in
                if compiledList == nil { failures.append("\(list.id): \(error.map { "\($0)" } ?? "no list")") }
                compiled.fulfill()
            }
            wait(for: [compiled], timeout: 600)
        }
        XCTAssertEqual(failures, [])
    }
    #endif
}
