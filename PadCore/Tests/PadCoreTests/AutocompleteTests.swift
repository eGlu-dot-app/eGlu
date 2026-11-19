import XCTest
@testable import PadCore

final class AutocompleteTests: XCTestCase {
    private func url(_ text: String) -> URL {
        URL(string: text) ?? URL(fileURLWithPath: "/")
    }

    private func bookmark(_ title: String, _ address: String) -> Autocomplete.Candidate {
        Autocomplete.Candidate(id: "bookmark-\(title)", source: .bookmark, action: .open(url(address)), title: title,
                               url: url(address))
    }

    private func tab(_ title: String, _ address: String, pinned: Bool = false, shown: Date = .distantPast) -> Autocomplete.Candidate {
        let id = UUID()
        return Autocomplete.Candidate(id: "tab-\(id)", source: pinned ? .pinnedTab : .tab, action: .tab(id), title: title,
                                      url: url(address), shown: shown)
    }

    private func command(_ command: Command, keys: String = "") -> Autocomplete.Candidate {
        Autocomplete.Candidate(id: "command-\(command.rawValue)", source: .command, action: .command(command),
                               title: command.title, keywords: command.keywords, detail: keys)
    }

    private func setting(_ anchor: SettingsAnchor) -> Autocomplete.Candidate {
        Autocomplete.Candidate(id: "setting-\(anchor.rawValue)", source: .setting, action: .setting(anchor),
                               title: anchor.title, keywords: anchor.keywords, detail: anchor.detail)
    }

    private func space(_ name: String, symbol: String = "briefcase") -> Autocomplete.Candidate {
        let id = UUID()
        return Autocomplete.Candidate(id: "space-\(id)", source: .space, action: .space(id), title: name,
                                      keywords: ["space"], detail: "2 tabs", symbol: symbol)
    }

    // MARK: Matching

    /// The letters typed start a word, never sit inside one.
    func testLettersStartAWord() {
        XCTAssertEqual(Autocomplete.match("fig", in: "Figma: Flows")?.typed, [0..<3])
        XCTAssertEqual(Autocomplete.match("flo", in: "Figma: Flows")?.typed, [7..<10])
        XCTAssertNil(Autocomplete.match("fig", in: "Configure"))
        XCTAssertEqual(Autocomplete.match("피그", in: "피그마 강좌")?.typed, [0..<2])
    }

    /// Words typed in any order each find the start of one.
    func testWordsInAnyOrder() {
        let found = Autocomplete.match("guide auto", in: "Auto Layout Guide")
        XCTAssertEqual(found?.fit, .words)
        XCTAssertEqual(found?.typed, [0..<4, 12..<17])
        XCTAssertNil(Autocomplete.match("guide zoom", in: "Auto Layout Guide"))
    }

    // MARK: The device's rows

    /// A page whose address the letters start is offered by its address,
    /// completed, with its title under it.
    func testAddressIsCompleted() {
        let rows = Autocomplete.local([bookmark("Figma", "https://www.figma.com/files/recent")], query: "fig")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.phrase, "figma.com/files/recent")
        XCTAssertEqual(rows.first?.typed, [0..<3])
        XCTAssertEqual(rows.first?.detail, "Figma")
        XCTAssertEqual(rows.first?.source, .bookmark)
        XCTAssertEqual(rows.first?.source.label, "Bookmark")
    }

    /// Otherwise by its title, with its address under it.
    func testTitleWhenTheAddressDoesNotStartWithIt() {
        let rows = Autocomplete.local([tab("Auto Layout Guide", "https://example.com/al")], query: "lay")
        XCTAssertEqual(rows.first?.phrase, "Auto Layout Guide")
        XCTAssertEqual(rows.first?.typed, [5..<8])
        XCTAssertEqual(rows.first?.detail, "example.com/al")
        XCTAssertEqual(rows.first?.source.label, "Open Tab")
    }

    /// One row a page: the open tab, rather than its bookmark.
    func testOpenTabBeforeItsBookmark() {
        let rows = Autocomplete.local([bookmark("Figma", "https://figma.com"), tab("Figma", "https://figma.com/")],
                                      query: "fig")
        XCTAssertEqual(rows.map(\.source), [.tab])
    }

    /// Pinned tabs say so; the tab seen last comes first.
    func testPinnedTabsAndRecency() {
        let now = Date()
        let rows = Autocomplete.local([
            tab("Figma Files", "https://figma.com/files", shown: now.addingTimeInterval(-60)),
            tab("Figma Community", "https://figma.com/community", pinned: true, shown: now),
        ], query: "figma")
        XCTAssertEqual(rows.map(\.source), [.pinnedTab, .tab])
        XCTAssertEqual(rows.first?.source.label, "Pinned Tab")
    }

    /// Commands need two letters, are found by their other words too, and
    /// take at most three rows.
    func testCommands() {
        let commands = [command(.newTab, keys: "⌘T"), command(.newSpace), command(.newWindow), command(.reload),
                        command(.reopenTab)]
        XCTAssertTrue(Autocomplete.local(commands, query: "n").isEmpty)
        let new = Autocomplete.local(commands + [command(.nextTab)], query: "ne")
        XCTAssertEqual(new.map(\.phrase), ["New Tab", "Next Tab", "New Space"])
        XCTAssertEqual(new.first?.phrase, "New Tab")
        XCTAssertEqual(new.first?.detail, "⌘T")
        XCTAssertEqual(new.first?.source.label, "Command")
        let refresh = Autocomplete.local(commands, query: "refresh")
        XCTAssertEqual(refresh.first?.phrase, "Reload Page")
        XCTAssertEqual(refresh.first?.typed, [])
        XCTAssertEqual(refresh.first?.action, .command(.reload))
    }

    /// Typing goes through the same candidates letter after letter: made
    /// ready once, they answer each as a fresh search of them would.
    func testCandidatesMadeReadyOnceAnswerEveryLetter() {
        let candidates = [
            tab("Figma: Flows", "https://www.figma.com/file/abc"),
            bookmark("Configure", "https://example.com/settings"),
            bookmark("Notion", "https://www.notion.so/"),
            command(.newTab, keys: "⌘T"),
        ]
        let ready = Autocomplete.Index(candidates)
        XCTAssertEqual(ready.candidates.map(\.id), candidates.map(\.id))
        for query in ["f", "fi", "fig", "figma.com", "www.fig", "https://www.n", "flows fig", "new", "con", "zzz", "  no ", ""] {
            XCTAssertEqual(ready.local(query: query), Autocomplete.local(candidates, query: query), "typed: \(query)")
        }
        XCTAssertEqual(ready.local(query: "fig").first?.phrase, "figma.com/file/abc")
    }

    func testTheModelIsAskedOnlyForWordsWorthItsWhile() {
        XCTAssertFalse(Autocomplete.asksModel("fi"))
        XCTAssertTrue(Autocomplete.asksModel("the onboarding file"))
        XCTAssertFalse(Autocomplete.asksModel("figma.com"), "an address goes where it says")
        XCTAssertFalse(Autocomplete.asksModel(String(repeating: "a", count: 101)))
    }

    func testNothingTypedOffersNothing() {
        XCTAssertTrue(Autocomplete.local([bookmark("Figma", "https://figma.com")], query: "  ").isEmpty)
    }

    // MARK: Settings, spaces and other places

    /// A part of Settings is found by its name and by the words for what is
    /// changed there, in any order, its name and those words together too;
    /// its row goes to that part, and says what is there.
    func testSettingsAreFoundByWhatIsChangedThere() {
        let settings = SettingsAnchor.allCases.map(setting)
        for query in ["change icon", "icon", "app ic", "home screen icon", "icon change", "app icon change"] {
            let rows = Autocomplete.local(settings, query: query)
            XCTAssertEqual(rows.first?.action, .setting(.appIcon), "typed: \(query)")
        }
        let icon = Autocomplete.local(settings, query: "change icon").first
        XCTAssertEqual(icon?.phrase, "App icon")
        XCTAssertEqual(icon?.detail, "The Home Screen icon")
        XCTAssertEqual(icon?.source.label, "Settings")
        XCTAssertEqual(Autocomplete.local(settings, query: "duckduckgo").first?.action, .setting(.search))
        XCTAssertEqual(Autocomplete.local(settings, query: "ad blocker").first?.action, .setting(.blocking))
        XCTAssertTrue(Autocomplete.local(settings, query: "i").isEmpty, "one letter is a page's")
        XCTAssertTrue(Autocomplete.local(settings, query: "change the weather").isEmpty)
    }

    /// Two parts of Settings at most, so they never crowd out the pages.
    func testSettingsTakeTwoRowsAtMost() {
        let rows = Autocomplete.local(SettingsAnchor.allCases.map(setting), query: "show")
        XCTAssertEqual(rows.count, 2)
    }

    /// Every part has a name and words of its own, and an iPhone's Settings
    /// has other parts than an iPad's.
    func testSettingsAnchors() {
        for anchor in SettingsAnchor.allCases {
            XCTAssertFalse(anchor.title.isEmpty, anchor.rawValue)
            XCTAssertFalse(anchor.detail.isEmpty, anchor.rawValue)
            XCTAssertFalse(anchor.keywords.isEmpty, anchor.rawValue)
        }
        XCTAssertEqual(Set(SettingsAnchor.allCases.map(\.title)).count, SettingsAnchor.allCases.count)
        XCTAssertTrue(SettingsAnchor.desktopView.isOffered(phone: true))
        XCTAssertFalse(SettingsAnchor.desktopView.isOffered(phone: false))
        XCTAssertTrue(SettingsAnchor.trackpad.isOffered(phone: false))
        XCTAssertFalse(SettingsAnchor.trackpad.isOffered(phone: true))
        XCTAssertFalse(SettingsAnchor.window.isOffered(phone: true))
        // The iPhone Duo: both layouts' sections.
        XCTAssertTrue(SettingsAnchor.desktopView.isOffered(phoneLayout: true, padLayout: true))
        XCTAssertTrue(SettingsAnchor.window.isOffered(phoneLayout: true, padLayout: true))
        XCTAssertTrue(SettingsAnchor.shortcuts.isOffered(phoneLayout: true, padLayout: true))
        XCTAssertTrue(SettingsAnchor.appIcon.isOffered(phone: true) && SettingsAnchor.appIcon.isOffered(phone: false))
    }

    /// Another space is found by its name, though nothing in it is (the
    /// command bar is given only this space's tabs); this space's tab comes
    /// before a bookmark of the same fit, and a tab on another device after it.
    func testOtherSpacesAndDevices() {
        let phone = Autocomplete.Candidate(id: "elsewhere-1", source: .device("Chrome · MacBook"),
                                           action: .open(url("https://figma.com/design/2")), title: "Figma Design",
                                           url: url("https://figma.com/design/2"))
        let rows = Autocomplete.local([phone, bookmark("Figma Help", "https://help.figma.com"),
                                       tab("Figma Files", "https://figma.com/files"), space("Figma team")], query: "figma")
        XCTAssertEqual(rows.map(\.source), [.tab, .bookmark, .device("Chrome · MacBook"), .space])
        XCTAssertEqual(rows.map(\.source.label), ["Open Tab", "Bookmark", "Chrome · MacBook", "Space"])
        XCTAssertEqual(rows.last?.symbol, "briefcase")
        XCTAssertEqual(rows.last?.detail, "2 tabs")
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.source.isPage })
        XCTAssertFalse(Suggestion.Source.space.isPage || Suggestion.Source.setting.isPage || Suggestion.Source.command.isPage)
    }

    // MARK: Everything listed

    func testPaletteSectionBoundsAndTypedBypass() {
        let listing = PaletteListing()
        XCTAssertTrue(listing.rows([], listing: true).isEmpty)
        for count in [0, PaletteListing.sectionLimit - 1, PaletteListing.sectionLimit, PaletteListing.sectionLimit + 1] {
            let all = Autocomplete.Index((0..<count).map { bookmark("Bookmark \($0)", "https://example.com/\($0)") }).everything
            let rows = listing.rows(all, listing: true)
            XCTAssertEqual(rows.count, min(count, PaletteListing.sectionLimit) + (count > PaletteListing.sectionLimit ? 1 : 0))
            if count > PaletteListing.sectionLimit {
                XCTAssertEqual(rows.last, .showAll(section: .bookmarks, total: count, source: .bookmark))
            }
            XCTAssertEqual(listing.rows(all, listing: false), all.map(PaletteListing.Row.suggestion))
        }
    }

    func testPaletteExpansionKeepsSectionsIndependentAndIDsStable() throws {
        let tabs = (0..<8).map { tab("Tab \($0)", "https://tabs.example/\($0)", pinned: $0.isMultiple(of: 2)) }
        let bookmarks = (0..<9).map { bookmark("Bookmark \($0)", "https://bookmarks.example/\($0)") }
        let all = Autocomplete.Index(tabs + bookmarks).everything
        var listing = PaletteListing()
        let before = listing.rows(all, listing: true).map(\.suggestion)
        XCTAssertEqual(before.prefix(5).map(\.id), all.prefix(5).map(\.id))
        XCTAssertEqual(before[5].action, .showAll(.tabs))
        XCTAssertEqual(before[11].action, .showAll(.bookmarks))
        let selected = try XCTUnwrap(listing.expand(.bookmarks, in: all))
        XCTAssertEqual(selected, all[8 + PaletteListing.sectionLimit].id)
        let after = listing.rows(all, listing: true).map(\.suggestion)
        XCTAssertEqual(Array(after.prefix(6)), Array(before.prefix(6)))
        XCTAssertEqual(Array(after.dropFirst(6)), Array(all.dropFirst(8)))
        XCTAssertEqual(after.firstIndex { $0.id == selected }, 6 + PaletteListing.sectionLimit)
        XCTAssertEqual(listing.rows(all, listing: false).map(\.suggestion), all)
        XCTAssertEqual(PaletteListing().rows(all, listing: true).map(\.suggestion), before)
    }

    func testPaletteGroupsPinnedTabsInFirstSectionOrder() {
        let candidates = [bookmark("First", "https://example.com/first"),
                          tab("Pinned", "https://example.com/pinned", pinned: true),
                          tab("Tab", "https://example.com/tab"),
                          bookmark("Last", "https://example.com/last")]
        let all = Autocomplete.Index(candidates).everything
        XCTAssertEqual(PaletteListing().rows(all, listing: true).map(\.suggestion.id),
                       [all[0].id, all[3].id, all[1].id, all[2].id])
    }

    /// Asked for everything, the field lists all of it before anything is
    /// typed, in the order given; what is typed then finds every kind with
    /// none held back, one letter enough.
    func testEverythingListed() {
        let candidates = [tab("Figma", "https://figma.com")] + Command.allCases.map { command($0) }
            + SettingsAnchor.allCases.map(setting)
        let ready = Autocomplete.Index(candidates)
        XCTAssertEqual(ready.local(query: "", wide: true).map(\.id), candidates.map(\.id))
        XCTAssertEqual(ready.everything.first?.detail, "figma.com")
        XCTAssertTrue(ready.everything.allSatisfy { $0.typed.isEmpty })
        XCTAssertTrue(ready.local(query: "").isEmpty)
        let tabs = ready.local(query: "tab", wide: true).filter { $0.source == .command }
        XCTAssertGreaterThan(tabs.count, Autocomplete.commandLimit)
        XCTAssertEqual(ready.local(query: "tab").filter { $0.source == .command }.count, Autocomplete.commandLimit)
        XCTAssertFalse(ready.local(query: "s", wide: true).filter { !$0.source.isPage }.isEmpty)
        XCTAssertLessThanOrEqual(ready.local(query: "s", wide: true).count, Autocomplete.wideLimit)
    }

    // MARK: The engine's rows and the order

    /// The words as typed are left out, and repeats; four at most.
    func testEngineRows() {
        let words = ["figma", "Figma login", "figma login", "figma jam", "figma fonts", "figma ai", "figma pricing"]
        let rows = Autocomplete.engine(words, query: "figma", engine: "Google")
        XCTAssertEqual(rows.map(\.phrase), ["Figma login", "figma jam", "figma fonts", "figma ai"])
        XCTAssertEqual(rows.first?.typed, [0..<5])
        XCTAssertEqual(rows.first?.action, .go("Figma login"))
        XCTAssertEqual(rows.first?.source.label, "Google")
    }

    /// A page the letters start comes first, then the engine's words, then
    /// the rest. A command or a part of Settings comes first only when three
    /// letters or more start its name and no page's, never for its other
    /// words; with everything listed, all the device's rows come first.
    func testOrder() {
        let figma = Suggestion(id: "b", source: .bookmark, action: .open(url("https://figma.com")), phrase: "figma.com",
                               typed: [0..<3])
        let guide = Suggestion(id: "t", source: .tab, action: .open(url("https://example.com")),
                               phrase: "Auto Figma Guide", typed: [5..<8])
        let new = Suggestion(id: "c", source: .command, action: .command(.newTab), phrase: "New Tab", typed: [0..<3])
        let search = Suggestion(id: "e", source: .engine("Google"), action: .go("figma login"), phrase: "figma login",
                                typed: [0..<3])
        XCTAssertEqual(Autocomplete.rows(local: [figma, guide], engine: [search]).map(\.id), ["b", "e", "t"])
        XCTAssertEqual(Autocomplete.rows(local: [guide], engine: [search]).map(\.id), ["e", "t"])
        XCTAssertEqual(Autocomplete.rows(local: [figma, new], engine: [search]).map(\.id), ["b", "e", "c"])
        XCTAssertEqual(Autocomplete.rows(local: [new, guide], engine: [search]).map(\.id), ["c", "e", "t"])
        let two = Suggestion(id: "c2", source: .command, action: .command(.newTab), phrase: "New Tab", typed: [0..<2])
        XCTAssertEqual(Autocomplete.rows(local: [two], engine: [search]).map(\.id), ["e", "c2"])
        let icon = Suggestion(id: "s", source: .setting, action: .setting(.appIcon), phrase: "App Icon", typed: [])
        XCTAssertEqual(Autocomplete.rows(local: [icon], engine: [search]).map(\.id), ["e", "s"])
        let named = Suggestion(id: "s2", source: .setting, action: .setting(.appIcon), phrase: "App Icon", typed: [0..<3])
        XCTAssertEqual(Autocomplete.rows(local: [named], engine: [search]).map(\.id), ["s2", "e"])
        XCTAssertEqual(Autocomplete.rows(local: [guide, two, icon], meant: [], engine: [search], wide: true).map(\.id),
                       ["t", "c2", "s", "e"])
    }

    // MARK: Asking the engine

    func testSuggestionsAddress() {
        XCTAssertEqual(Autocomplete.suggestionsURL(for: "auto layout", engine: "google")?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=auto%20layout")
        XCTAssertEqual(Autocomplete.suggestionsURL(for: "피그마", engine: "google")?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=%ED%94%BC%EA%B7%B8%EB%A7%88")
        XCTAssertEqual(Autocomplete.suggestionsURL(for: "figma", engine: "duckduckgo")?.absoluteString,
                       "https://duckduckgo.com/ac/?type=list&q=figma")
        XCTAssertEqual(Autocomplete.suggestionsURL(for: "figma", engine: "bing")?.absoluteString,
                       "https://api.bing.com/osjson.aspx?query=figma")
    }

    /// Complete recognized addresses and providers without endpoints produce no request.
    func testAddressesAreNotSent() {
        XCTAssertNil(Autocomplete.suggestionsURL(for: "figma.com", engine: "google"))
        XCTAssertNil(Autocomplete.suggestionsURL(for: "github.com/team/private-repo", engine: "google"))
        XCTAssertNil(Autocomplete.suggestionsURL(for: "localhost:3000", engine: "google"))
        XCTAssertNil(Autocomplete.suggestionsURL(for: "   ", engine: "google"))
        XCTAssertNil(Autocomplete.suggestionsURL(for: "figma", engine: "kagi"))
    }

    func testEngineName() {
        XCTAssertEqual(Autocomplete.engineName("bing"), "Bing")
        XCTAssertEqual(Autocomplete.engineName("nonsense"), "Google")
    }

    func testParse() {
        XCTAssertEqual(Autocomplete.parse(Data(#"["fig",["figma","figma login"]]"#.utf8)), ["figma", "figma login"])
        XCTAssertEqual(Autocomplete.parse(Data(#"["피그",["피그마"],[],{}]"#.utf8)), ["피그마"])
        XCTAssertEqual(Autocomplete.parse(Data("not json".utf8)), [])
        XCTAssertEqual(Autocomplete.parse(Data(#"{"q":"fig"}"#.utf8)), [])
    }

    func testEngineSuggestionsAreOnUnlessTurnedOff() throws {
        XCTAssertTrue(Preferences().searchSuggestions)
        for (saved, on) in [("{}", true), (#"{"searchSuggestions":true}"#, true), (#"{"searchSuggestions":false}"#, false)] {
            let preferences = try JSONDecoder().decode(Preferences.self, from: Data(saved.utf8))
            XCTAssertEqual(preferences.searchSuggestions, on, saved)
            XCTAssertEqual(Autocomplete.suggestionsURL(for: "private", preferences: preferences) != nil, on, saved)
        }
    }

    func testTurningSuggestionsOffSurvivesRelaunchAndStopsRequests() throws {
        var preferences = Preferences()
        preferences.setRemoteSuggestions(false)
        let relaunched = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(relaunched.allowsRemoteSuggestions(for: "google"))
        XCTAssertNil(Autocomplete.suggestionsURL(for: "private", preferences: relaunched))
        preferences.setRemoteSuggestions(true)
        XCTAssertTrue(preferences.allowsRemoteSuggestions(for: "google"))
    }

    func testSuggestionsGoToTheEngineChosen() {
        var preferences = Preferences()
        preferences.engine = "bing"
        XCTAssertTrue(preferences.allowsRemoteSuggestions(for: "bing"))
        XCTAssertFalse(preferences.allowsRemoteSuggestions(for: "google"))
        XCTAssertEqual(Autocomplete.suggestionsURL(for: "private", preferences: preferences)?.host, "api.bing.com")
    }

    func testSlowPrivateAddressTypingOnlyProducesRequestsAfterOptIn() {
        let prefixes = ["p", "pr", "private", "private.c", "private.corp", "private.corp/client"]
        var preferences = Preferences()
        preferences.setRemoteSuggestions(false)
        var requests: [URL] = []
        func record() {
            requests += prefixes.compactMap { Autocomplete.suggestionsURL(for: $0, preferences: preferences) }
        }
        record()
        XCTAssertTrue(requests.isEmpty)
        preferences.setRemoteSuggestions(true)
        record()
        XCTAssertEqual(requests.count, 4, "only prefixes not yet recognized as addresses can reach the explicitly approved provider")
        XCTAssertTrue(requests.allSatisfy { $0.host == "suggestqueries.google.com" })
        requests = []
        preferences.setRemoteSuggestions(false)
        record()
        XCTAssertTrue(requests.isEmpty)
        let list = Autocomplete.Index([bookmark("Private Client", "https://private.corp")])
        XCTAssertFalse(list.local(query: "private", wide: false).isEmpty, "local suggestions remain available without remote consent")
    }

    func testProviderDisclosureNamesRecipientAndPrivatePrefixRisk() {
        XCTAssertTrue(Autocomplete.suggestionsDisclosure(engine: "bing").contains("Bing"))
        XCTAssertTrue(Autocomplete.suggestionsDisclosure(engine: "google").contains("private address"))
        XCTAssertTrue(Autocomplete.suggestionsDisclosure(engine: "google").contains("IP address"))
        XCTAssertFalse(Autocomplete.offersSuggestions(engine: "kagi"))
    }

    // MARK: Apple Intelligence

    /// The letters do the work alone for fewer than three of them, and for an address.
    func testIntentQuestionWaitsForThreeLettersAndSkipsAddresses() {
        let list = [bookmark("Figma", "https://figma.com")]
        XCTAssertNil(Autocomplete.intentQuestion(query: "fi", candidates: list))
        XCTAssertNil(Autocomplete.intentQuestion(query: "figma.com", candidates: list))
        XCTAssertNotNil(Autocomplete.intentQuestion(query: "design tool", candidates: list))
    }

    /// The pages seen last first, one line a page with its site, then every
    /// command, numbered from 1.
    func testIntentQuestionLists() throws {
        let now = Date()
        let list = [
            bookmark("Linear", "https://linear.app"),
            tab("Onboarding flows", "https://www.figma.com/file/abc", shown: now),
            tab("Older", "https://example.com", shown: now.addingTimeInterval(-60)),
            bookmark("Figma file", "https://www.figma.com/file/abc"),
            command(.closeTab),
        ]
        let question = try XCTUnwrap(Autocomplete.intentQuestion(query: "close everything", candidates: list))
        XCTAssertEqual(question.prompt, """
            Typed: close everything

            1. Open tab: Onboarding flows (figma.com)
            2. Open tab: Older (example.com)
            3. Bookmark: Linear (linear.app)
            4. Command: Close Tab
            """)
        XCTAssertEqual(question.candidates.map(\.title), ["Onboarding flows", "Older", "Linear", "Close Tab"])
    }

    /// What the model picks is told by its name as well as its number: a
    /// name cut short, or with the line's kind and site round it, is still
    /// that line's; a number a line off is put right by the name; a name of
    /// the model's own making is no item. One already shown, one not in the
    /// list, and any after the fifth are passed over.
    func testIntentPicks() throws {
        let list = [
            tab("Onboarding flows", "https://figma.com/file/abc", shown: Date()),
            bookmark("Linear", "https://linear.app"),
            command(.closeTab, keys: "⌘W"),
            bookmark("Notion", "https://notion.so"),
            bookmark("Slack", "https://slack.com"),
        ]
        let question = try XCTUnwrap(Autocomplete.intentQuestion(query: "close everything", candidates: list))
        XCTAssertEqual(question.candidates.map(\.title), ["Onboarding flows", "Linear", "Notion", "Slack", "Close Tab"])
        let shown = Autocomplete.local([bookmark("Linear", "https://linear.app")], query: "lin")
        let pick = Autocomplete.IntentPick.init
        let answer = Autocomplete.IntentAnswer(
            picks: [pick(5, "Close Tab"), pick(2, "Linear"), pick(0, "Nothing"), pick(99, "Nowhere"),
                    pick(1, "Onboarding"), pick(4, "Notion"), pick(4, "Bookmark: Slack (slack.com)"), pick(3, "dark mode"),
                    pick(5, "Command: Close Tab")],
            searches: ["close everything", "close all tabs chrome", "Close all tabs chrome", "", "close tabs shortcut"]
        )
        let picked = Autocomplete.intentPicks(answer, to: question, shown: shown)
        XCTAssertEqual(picked.map(\.title), ["Close Tab", "Onboarding flows", "Notion", "Slack"])
        let rows = picked.map { Autocomplete.meantRow(for: $0, query: question.query) }
        XCTAssertEqual(rows.map(\.source), [.command, .tab, .bookmark, .bookmark])
        XCTAssertTrue(rows.allSatisfy(\.byMeaning))
        XCTAssertEqual(rows.first?.detail, "⌘W")
        XCTAssertEqual(rows.dropFirst().first?.detail, "figma.com/file/abc")
        let searches = Autocomplete.intentSearches(answer, to: question)
        XCTAssertEqual(searches.map(\.phrase), ["close all tabs chrome", "close tabs shortcut"])
        XCTAssertEqual(searches.first?.source.label, "Apple Intelligence")
        XCTAssertEqual(searches.first?.action, .go("close all tabs chrome"))
    }

    /// Five picks at most, and as few as none: nothing picked, nothing offered.
    func testIntentPicksAreFiveAtMostAndMayBeNone() throws {
        let list = (1...8).map { bookmark("Site \($0)", "https://site\($0).example") }
        let question = try XCTUnwrap(Autocomplete.intentQuestion(query: "my sites", candidates: list))
        let all = Autocomplete.IntentAnswer(picks: (1...8).map { .init(number: $0, name: "Site \($0)") }, searches: [])
        XCTAssertEqual(Autocomplete.intentPicks(all, to: question, shown: []).map(\.title), (1...5).map { "Site \($0)" })
        XCTAssertEqual(Autocomplete.meantLimit, 5)
        let none = Autocomplete.IntentAnswer(picks: [], searches: [])
        XCTAssertTrue(Autocomplete.intentPicks(none, to: question, shown: []).isEmpty)
        // "Site 1" is also the start of nothing else's whole name here, and a made-up name is nobody's.
        let made = Autocomplete.IntentAnswer(picks: [.init(number: 3, name: "weather tomorrow")], searches: [])
        XCTAssertTrue(Autocomplete.intentPicks(made, to: question, shown: []).isEmpty)
    }

    /// Each pick is asked about by itself: the words, and the thing with
    /// what it is, its site, or what a part of Settings changes. Only what
    /// is graded as asked for or related is kept.
    func testGrading() {
        XCTAssertEqual(Autocomplete.gradeQuestion(query: " email ", about: tab("Inbox (3) – Gmail", "https://mail.google.com/mail/u/0/")),
                       "Typed: email\nThing: Open tab: Inbox (3) – Gmail (mail.google.com)")
        XCTAssertEqual(Autocomplete.gradeQuestion(query: "news", about: bookmark("Hacker News", "https://news.ycombinator.com")),
                       "Typed: news\nThing: Bookmark: Hacker News (news.ycombinator.com)")
        XCTAssertEqual(Autocomplete.gradeQuestion(query: "close this", about: command(.closeTab, keys: "⌘W")),
                       "Typed: close this\nThing: Browser command: Close Tab")
        XCTAssertEqual(Autocomplete.gradeQuestion(query: "change icon", about: setting(.appIcon)),
                       "Typed: change icon\nThing: Browser setting: App icon: The Home Screen icon")
        XCTAssertEqual(Autocomplete.gradeQuestion(query: "work", about: space("Client")), "Typed: work\nThing: Space: Client")
        XCTAssertTrue(Autocomplete.IntentGrade.askedFor.keeps)
        XCTAssertTrue(Autocomplete.IntentGrade.related.keeps)
        XCTAssertFalse(Autocomplete.IntentGrade.unrelated.keeps)
    }

    /// What the model found comes after the page the letters start, before the searches.
    func testOrderWithWhatWasMeant() {
        let figma = Suggestion(id: "b", source: .bookmark, action: .open(url("https://figma.com")), phrase: "figma.com",
                               typed: [0..<3])
        let guide = Suggestion(id: "t", source: .tab, action: .open(url("https://example.com")),
                               phrase: "Auto Figma Guide", typed: [5..<8])
        let meant = Suggestion(id: "m", source: .command, action: .command(.closeTab), phrase: "Close Tab", typed: [],
                               byMeaning: true)
        let search = Suggestion(id: "e", source: .engine("Google"), action: .go("figma login"), phrase: "figma login",
                                typed: [0..<3])
        XCTAssertEqual(Autocomplete.rows(local: [figma, guide], meant: [meant], engine: [search]).map(\.id),
                       ["b", "m", "e", "t"])
        XCTAssertEqual(Autocomplete.rows(local: [guide], meant: [meant], engine: [search]).map(\.id), ["m", "e", "t"])
    }

    func testIntelligenceSettingDefaultsToOn() throws {
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).intelligence)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: Data(#"{"intelligence":false}"#.utf8)).intelligence)
    }

    // MARK: History

    private func visited(_ title: String, _ address: String, search: String? = nil) -> HistoryPage {
        HistoryPage(space: UUID(), key: History.pageKey(url(address)), url: url(address), title: title, summary: "",
                    last: Date(), count: 1, frecency: 100, search: search)
    }

    /// History's rows keep what the store found, inside a word or in a
    /// description too, after an open tab or a bookmark of the same page.
    func testHistoryRowsKeepWhatTheStoreFound() {
        let open = Suggestion(id: "t", source: .tab, action: .tab(UUID()), phrase: "Figma", typed: [0..<3],
                              url: url("https://www.figma.com/"))
        let pages = [visited("Figma", "https://www.figma.com"), visited("우리은행 인터넷뱅킹", "https://www.wooribank.com/"),
                     visited("Materials", "https://developer.apple.com/design/materials")]
        let bank = Autocomplete.history(pages, query: "은행", shown: [open])
        XCTAssertEqual(bank.map(\.phrase), ["Figma", "우리은행 인터넷뱅킹", "Materials"].filter { $0 != "Figma" },
                       "the open tab's page is not offered twice; what the store found stays")
        XCTAssertEqual(bank.first?.typed, [], "found inside a word: nothing marked as typed")
        XCTAssertEqual(bank.first?.detail, "wooribank.com")
        XCTAssertEqual(bank.first?.source, .history)
        XCTAssertEqual(bank.first?.action, .open(url("https://www.wooribank.com/")))

        let byAddress = Autocomplete.history([visited("Apple Design", "https://developer.apple.com/design")], query: "develop",
                                             shown: [])
        XCTAssertEqual(byAddress.first?.phrase, "developer.apple.com/design")
        XCTAssertEqual(byAddress.first?.typed, [0..<7])
        let byTitle = Autocomplete.history([visited("Apple Design", "https://developer.apple.com/design")],
                                           query: "design yesterday", shown: [])
        XCTAssertEqual(byTitle.first?.typed, [6..<12], "the words for when are not looked for in the row")
    }

    /// A search typed before is offered as itself, and the engine's same words not again.
    func testSearchesTypedBefore() {
        let pages = [visited("figma tutorial - Google Search", "https://www.google.com/search?q=figma+tutorial",
                             search: "figma tutorial"),
                     visited("figma - Google Search", "https://www.google.com/search?q=figma", search: "figma")]
        let rows = Autocomplete.history(pages, query: "figma", shown: [])
        XCTAssertEqual(rows.map(\.phrase), ["figma tutorial"], "the words as typed are what Return sends already")
        XCTAssertEqual(rows.first?.source, .searched)
        XCTAssertEqual(rows.first?.action, .go("figma tutorial"))
        let engine = Autocomplete.engine(["figma tutorial", "figma login"], query: "figma", engine: "Google")
        XCTAssertEqual(Autocomplete.rows(local: [], history: rows, engine: engine).map(\.phrase),
                       ["figma tutorial", "figma login"])
    }

    /// A page from history the letters start leads when no open tab or
    /// bookmark does; otherwise history comes after the device's own.
    func testHistoryOrder() {
        let page = Autocomplete.history([visited("Linear", "https://linear.app")], query: "lin", shown: [])
        let search = Suggestion(id: "e", source: .engine("Google"), action: .go("linear login"), phrase: "linear login",
                                typed: [0..<3])
        XCTAssertEqual(Autocomplete.rows(local: [], history: page, engine: [search]).map(\.phrase), ["linear.app", "linear login"])
        let bookmark = Suggestion(id: "b", source: .bookmark, action: .open(url("https://lingo.dev")), phrase: "lingo.dev",
                                  typed: [0..<3], url: url("https://lingo.dev"))
        XCTAssertEqual(Autocomplete.rows(local: [bookmark], history: page, engine: [search]).map(\.phrase),
                       ["lingo.dev", "linear login", "linear.app"])
    }

    /// A search typed before is offered only for words in it, not because
    /// the store found its results page by the engine's name.
    func testASearchIsOfferedForItsOwnWords() {
        let pages = [visited("pasta recipe - Google Search", "https://www.google.com/search?q=pasta+recipe", search: "pasta recipe")]
        XCTAssertTrue(Autocomplete.history(pages, query: "google", shown: []).isEmpty)
        XCTAssertEqual(Autocomplete.history(pages, query: "pasta", shown: []).map(\.phrase), ["pasta recipe"])
        XCTAssertEqual(Autocomplete.history(pages, query: "recipe", shown: []).map(\.phrase), ["pasta recipe"], "a later word")
    }

    /// What the model meant is not offered again for a page shown already, by whatever found it.
    func testWhatWasMeantIsNotAPageShownAlready() {
        let history = Autocomplete.history([visited("Budget 2026", "https://docs.google.com/spreadsheets/d/1")], query: "team sheet",
                                           shown: [])
        let meant = Suggestion(id: "bookmark-budget", source: .bookmark, action: .open(url("https://docs.google.com/spreadsheets/d/1")),
                               phrase: "Budget 2026", typed: [], url: url("https://docs.google.com/spreadsheets/d/1"), byMeaning: true)
        XCTAssertEqual(Autocomplete.rows(local: [], history: history, meant: [meant], engine: []).count, 1)
    }

    /// A page found in history that is open in a tab is that tab.
    func testHistoryOfAnOpenPageGoesToItsTab() {
        let open = tab("Linear", "https://linear.app/")
        let index = Autocomplete.Index([open, bookmark("Lingo", "https://lingo.dev")])
        XCTAssertEqual(index.tabs.keys.sorted(), [History.pageKey(url("https://linear.app"))])
        let rows = Autocomplete.history([visited("Linear", "https://linear.app")], query: "agents", shown: [], tabs: index.tabs)
        XCTAssertEqual(rows.first?.id, open.id)
        XCTAssertEqual(rows.first?.action, open.action)
        XCTAssertEqual(rows.first?.source, .tab)
    }

    /// Pages from history have places of their own in the model's list,
    /// with when they were visited and what they are about, whatever the
    /// number of tabs; a page open in a tab is listed as the tab.
    func testHistoryInTheModelsList() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        let tabs = (1...50).map { tab("Tab \($0)", "https://site\($0).example/", shown: now.addingTimeInterval(Double(-$0))) }
        var glass = visited("Glass - Wikipedia", "https://en.wikipedia.org/wiki/Glass")
        glass.summary = String(repeating: "Glass is an amorphous solid. ", count: 6)
        glass.last = now.addingTimeInterval(-86_400)
        var open = visited("Tab 1", "https://site1.example/")
        open.last = now
        let history = [glass, open].map(Autocomplete.candidate(for:))
        let question = try XCTUnwrap(Autocomplete.intentQuestion(query: "that glass article", candidates: tabs, history: history,
                                                                 now: now, calendar: calendar))
        let pages = question.candidates.filter { $0.source.isPage }
        XCTAssertEqual(pages.count, 40)
        XCTAssertEqual(pages.filter { $0.source == .history }.map(\.title), ["Glass - Wikipedia"], "the open page is its tab")
        let line = try XCTUnwrap(question.prompt.split(separator: "\n").first { $0.contains("Visited page") })
        XCTAssertTrue(line.hasSuffix("Visited page: Glass - Wikipedia (en.wikipedia.org), yesterday: " + String(glass.summary.prefix(80)).trimmingCharacters(in: .whitespaces) + "…")
                      || line.contains("yesterday: Glass is an amorphous solid."), String(line))
        XCTAssertEqual(Autocomplete.when(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar), "3 days ago")
        XCTAssertTrue(Autocomplete.gradeQuestion(query: "glass", about: history[0]).contains(": Glass is an amorphous solid."))
    }

    /// From an answer to fewer letters, only the rows the letters still start.
    func testAStaleAnswerKeepsWhatStillFits() {
        let pages = [visited("Linear", "https://linear.app"), visited("Lingo", "https://lingo.dev")]
        XCTAssertEqual(Autocomplete.history(pages, query: "line", shown: [], stale: true).map(\.phrase), ["linear.app"])
    }
}
