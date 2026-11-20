import XCTest
@testable import PadCore

final class ShortcutTests: XCTestCase {
    /// ⌃⌥ for every command but the few on keys every browser keeps for itself.
    func testEveryChordIsControlOptionButTheBrowsersOwnAndNamesOneCommand() {
        XCTAssertTrue(Shortcuts.isUnambiguous)
        for command in Command.allCases {
            let chord = Shortcuts.chord(for: command)
            XCTAssertNotNil(chord, command.rawValue)
            XCTAssertEqual(chord?.base == .controlOption, !Shortcuts.reserved.contains(command), command.rawValue)
        }
    }

    func testLabels() {
        XCTAssertEqual(Shortcuts.chord(for: .summarizePage)?.label, "⌃⌥U")
        XCTAssertEqual(Shortcuts.chord(for: .everything)?.label, "⌃⌥K")
        XCTAssertEqual(Shortcuts.chord(for: .newSpace)?.label, "⌃⌥⇧N")
        XCTAssertEqual(Shortcuts.chord(for: .nextSpace)?.label, "⌃⌥↓")
        XCTAssertEqual(Shortcuts.tabNumbers.first?.label, "⌃⌥1")
    }

    /// The browser's own keys, as Chrome and Safari have them, in Apple's order.
    func testBrowsersOwnKeys() {
        XCTAssertEqual(Shortcuts.chord(for: .newTab)?.label, "⌘T")
        XCTAssertEqual(Shortcuts.chord(for: .reopenTab)?.label, "⇧⌘T")
        XCTAssertEqual(Shortcuts.chord(for: .closeTab)?.label, "⌘W")
        XCTAssertEqual(Shortcuts.chord(for: .newWindow)?.label, "⌘N")
        XCTAssertEqual(Shortcuts.chord(for: .closeWindow)?.label, "⇧⌘W")
        XCTAssertEqual(Shortcuts.chord(for: .nextTab)?.label, "⌃⇥")
        XCTAssertEqual(Shortcuts.chord(for: .previousTab)?.label, "⌃⇧⇥")
    }

    func testEveryCommandHasATitle() {
        for command in Command.allCases {
            XCTAssertFalse(command.title.isEmpty)
        }
    }

    func testPageSummaryIsNamedAndHandoffRemainsOptIn() {
        XCTAssertEqual(Command.summarizePage.title, "Summarize Page")
        XCTAssertTrue(Command.summarizePage.keywords.contains("summary"))
        XCTAssertFalse(Preferences().handoff)
    }

    /// The keys one by one, as a cheat sheet draws them, are the label's.
    func testCaps() {
        XCTAssertEqual(Shortcuts.chord(for: .newSpace)?.caps, ["⌃", "⌥", "⇧", "N"])
        XCTAssertEqual(Shortcuts.chord(for: .reopenTab)?.caps, ["⇧", "⌘", "T"])
        XCTAssertEqual(Shortcuts.chord(for: .previousTab)?.caps, ["⌃", "⇧", "⇥"])
        for chord in Array(Shortcuts.chords.values) + Shortcuts.tabNumbers {
            XCTAssertEqual(chord.caps.joined(), chord.label)
        }
    }

    /// Every command is in one menu, and so in the cheat sheet, once.
    func testEveryCommandIsInOneGroup() {
        let grouped = ShortcutGroup.allCases.flatMap(\.commands)
        XCTAssertEqual(grouped.count, Command.allCases.count)
        XCTAssertEqual(Set(grouped), Set(Command.allCases))
    }
}

final class DestinationTests: XCTestCase {
    func testAddressesGoThere() {
        XCTAssertEqual(Destination.url(for: "figma.com", engine: "google")?.absoluteString, "https://figma.com")
        XCTAssertEqual(Destination.url(for: " https://www.figma.com/files ", engine: "google")?.absoluteString, "https://www.figma.com/files")
        XCTAssertEqual(Destination.url(for: "localhost:3000", engine: "google")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(Destination.url(for: "0.0.0.0:5173", engine: "google")?.absoluteString, "http://localhost:5173")
    }

    func testWordsAreSearched() {
        XCTAssertEqual(Destination.url(for: "auto layout tips", engine: "google")?.absoluteString,
                       "https://www.google.com/search?q=auto%20layout%20tips")
        XCTAssertEqual(Destination.url(for: "figma", engine: "duckduckgo")?.absoluteString, "https://duckduckgo.com/?q=figma")
        XCTAssertEqual(Destination.url(for: "figma", engine: "nonsense")?.host(), "www.google.com")
        XCTAssertNil(Destination.url(for: "   ", engine: "google"))
    }

    func testASearchShowsItsWords() {
        let made = Destination.url(for: "auto layout tips", engine: "google")!
        XCTAssertEqual(Destination.searchWords(in: made, engine: "google"), "auto layout tips")
        // As Google writes its address back: + for spaces, and its own parameters after.
        let google = URL(string: "https://www.google.com/search?q=c%2B%2B+lambdas&sca_esv=1&ei=x")!
        XCTAssertEqual(Destination.searchWords(in: google, engine: "google"), "c++ lambdas")
        XCTAssertEqual(Destination.searchWords(in: URL(string: "https://duckduckgo.com/?q=figma&ia=web")!,
                                               engine: "duckduckgo"), "figma")
        XCTAssertEqual(Destination.searchWords(in: URL(string: "https://www.startpage.com/sp/search?query=%ED%95%9C%EA%B8%80")!,
                                               engine: "startpage"), "한글")
        XCTAssertEqual(Destination.editable(google, engine: "google"), "c++ lambdas")
    }

    func testOnlyTheChosenEnginesSearchesShowWords() {
        let google = URL(string: "https://www.google.com/search?q=figma")!
        XCTAssertNil(Destination.searchWords(in: google, engine: "bing"))
        // Another page of the engine's, or a search with nothing in it, is an address.
        XCTAssertNil(Destination.searchWords(in: URL(string: "https://www.google.com/maps?q=seoul")!, engine: "google"))
        XCTAssertNil(Destination.searchWords(in: URL(string: "https://www.google.com/search?q=+")!, engine: "google"))
        XCTAssertNil(Destination.searchWords(in: URL(string: "https://evil.example/search?q=figma")!, engine: "google"))
        XCTAssertEqual(Destination.editable(URL(string: "https://www.figma.com/files")!, engine: "google"),
                       "www.figma.com/files")
    }

    func testEnginesOfferedLeaveOutCustom() {
        let ids = Destination.engines.map(\.id)
        XCTAssertTrue(ids.contains("google"))
        XCTAssertFalse(ids.contains("custom"))
    }

    func testRegistrablePartOfAHost() {
        XCTAssertEqual(Destination.registrable("www.figma.com"), "figma.com")
        XCTAssertEqual(Destination.registrable("accounts.google.com"), "google.com")
        XCTAssertEqual(Destination.registrable("acme.okta.com"), "okta.com")
        XCTAssertEqual(Destination.registrable("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(Destination.registrable("someone.github.io"), "someone.github.io")
        XCTAssertEqual(Destination.registrable("localhost"), "localhost")
    }
}
