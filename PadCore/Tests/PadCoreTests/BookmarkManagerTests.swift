import XCTest
@testable import PadCore

/// What the bookmark manager does to a space's bookmarks: the bar kept,
/// bookmarks added into folders and edited, words found, and the file it
/// exports read back as it was.
final class BookmarkManagerTests: XCTestCase {
    let figma = URL(string: "https://www.figma.com/files")!
    let slack = URL(string: "https://app.slack.com/client")!
    let notion = URL(string: "https://www.notion.so/")!

    /// A bar of Slack and a folder holding Notion, and Figma among the others.
    private func space() -> (Workspace, space: UUID, bar: UUID, docs: UUID) {
        var w = Workspace.onFigma()
        let docs = Bookmark(folder: "Docs", children: [Bookmark(title: "Notion", url: notion)])
        let bar = Bookmark(folder: Bookmarks.barName, children: [Bookmark(title: "Slack", url: slack), docs])
        w.spaces[0].bookmarks = [bar, Bookmark(title: "Figma", url: figma)]
        return (w, w.spaces[0].id, bar.id, docs.id)
    }

    func testTheBarIsNeverRemovedButWhatIsInItIs() throws {
        var (w, space, bar, docs) = space()
        w.removeBookmark(bar, in: space)
        XCTAssertEqual(w.spaces[0].bar?.id, bar)
        w.removeBookmark(docs, in: space)
        XCTAssertEqual(w.spaces[0].bar?.children?.map(\.title), ["Slack"])
        // A folder only named as the bar, inside another, is no bar and goes.
        let named = try XCTUnwrap(w.addFolder(named: Bookmarks.barName, in: bar, of: space))
        w.removeBookmark(named, in: space)
        XCTAssertNil(Bookmarks.find(named, in: w.spaces[0].bookmarks))
    }

    func testABookmarkGoesIntoTheFolderAskedForEvenWhenTheAddressIsBookmarkedElsewhere() throws {
        var (w, space, bar, docs) = space()
        let first = try XCTUnwrap(w.addBookmark(figma, title: "  ", into: docs, in: space))
        XCTAssertEqual(Bookmarks.find(docs, in: w.spaces[0].bookmarks)?.children?.last?.id, first)
        // An empty name is the address, as a tile shows it.
        XCTAssertEqual(Bookmarks.find(first, in: w.spaces[0].bookmarks)?.title, "figma.com/files")
        let slackID = try XCTUnwrap(Bookmarks.find(slack, in: w.spaces[0].bookmarks)?.id)
        let second = try XCTUnwrap(w.addBookmark(notion, title: "Notion", into: bar, before: slackID, in: space))
        XCTAssertEqual(w.spaces[0].bar?.children?.first?.id, second)
        XCTAssertNil(w.addBookmark(notion, title: "Notion", into: UUID(), in: space))
    }

    func testTheBarIsMadeOnceAtTheTop() throws {
        var w = Workspace.onFigma()
        let space = w.spaces[0].id
        w.spaces[0].bookmarks = [Bookmark(title: "Figma", url: figma)]
        let bar = try XCTUnwrap(w.makeBar(in: space))
        XCTAssertEqual(w.spaces[0].bookmarks.first?.id, bar)
        XCTAssertEqual(w.makeBar(in: space), bar)
        XCTAssertEqual(w.spaces[0].bookmarks.count, 2)
    }

    func testAnAddressChangesOnlyOnALink() throws {
        var (w, space, _, docs) = space()
        let figmaID = try XCTUnwrap(Bookmarks.find(figma, in: w.spaces[0].bookmarks)?.id)
        w.changeBookmarkAddress(figmaID, to: notion, in: space)
        XCTAssertEqual(Bookmarks.find(figmaID, in: w.spaces[0].bookmarks)?.url, notion)
        w.changeBookmarkAddress(docs, to: notion, in: space)
        XCTAssertTrue(Bookmarks.find(docs, in: w.spaces[0].bookmarks)?.isFolder == true)
    }

    func testWordsFindLinksAndFoldersWithWhereTheyAre() {
        let (w, _, _, _) = space()
        let items = w.spaces[0].bookmarks
        let notionFound = Bookmarks.matching("notion", in: items)
        XCTAssertEqual(notionFound.map(\.item.title), ["Notion"])
        XCTAssertEqual(notionFound.first?.path.map(\.title), [Bookmarks.barName, "Docs"])
        // By the address too, every word, in any case.
        XCTAssertEqual(Bookmarks.matching("SLACK client", in: items).map(\.item.title), ["Slack"])
        XCTAssertEqual(Bookmarks.matching("docs", in: items).map(\.item.title), ["Docs"])
        // The bar itself is always listed among the folders: never a result.
        XCTAssertTrue(Bookmarks.matching("bookmarks bar", in: items).isEmpty)
        XCTAssertTrue(Bookmarks.matching("   ", in: items).isEmpty)
    }

    func testAFolderChosenWithWhatIsInItCountsOnceInTheOrderTheyStand() throws {
        var (w, space, bar, docs) = space()
        let notionID = try XCTUnwrap(Bookmarks.find(notion, in: w.spaces[0].bookmarks)?.id)
        let figmaID = try XCTUnwrap(Bookmarks.find(figma, in: w.spaces[0].bookmarks)?.id)
        let items = w.spaces[0].bookmarks
        // Chosen in any order, Notion inside Docs: Docs carries it, and the bar's folder comes before Figma.
        XCTAssertEqual(Bookmarks.outermost([figmaID, notionID, docs, UUID()], in: items), [docs, figmaID])
        XCTAssertEqual(Bookmarks.outermost([notionID, figmaID], in: items), [notionID, figmaID])
        XCTAssertEqual(Bookmarks.outermost([bar, docs], in: items), [bar])

        // Moved together into Other Bookmarks, Notion stays in Docs.
        for id in Bookmarks.outermost([notionID, docs], in: items) {
            w.moveBookmark(id, into: nil, in: space)
        }
        XCTAssertEqual(Bookmarks.find(docs, in: w.spaces[0].bookmarks)?.children?.map(\.id), [notionID])
        XCTAssertEqual(Bookmarks.parent(of: docs, in: w.spaces[0].bookmarks), nil)
    }

    func testABookmarksAddressIsAWebAddressAndNeverASearch() {
        XCTAssertEqual(Destination.webAddress(from: " figma.com/files "), URL(string: "https://figma.com/files"))
        XCTAssertEqual(Destination.webAddress(from: "localhost:3000"), URL(string: "http://localhost:3000"))
        XCTAssertEqual(Destination.webAddress(from: "http://0.0.0.0:5173/"), URL(string: "http://localhost:5173/"))
        XCTAssertNil(Destination.webAddress(from: "design system"))
        XCTAssertNil(Destination.webAddress(from: "about:blank"))
        XCTAssertNil(Destination.webAddress(from: "file:///Users/me/a.html"))
        XCTAssertNil(Destination.webAddress(from: "mailto:me@example.com"))
    }

    func testTheExportReadsBackAsTheSameBookmarks() throws {
        var (w, space, _, docs) = space()
        _ = w.addBookmark(URL(string: "https://example.com/?a=1&b=<2>")!, title: "Tom & \"Jerry\" <3", into: docs, in: space)
        let items = w.spaces[0].bookmarks
        let data = BookmarkFile.export(items)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        XCTAssertTrue(text.contains("<H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks bar</H3>"))
        XCTAssertTrue(text.contains("Tom &amp; &quot;Jerry&quot; &lt;3"))
        let read = BookmarkFile.parse(data)
        XCTAssertEqual(Self.shape(read.items), Self.shape(items))
    }

    func testEglusOwnExportBringsItsEmptyFoldersBackIntoAnotherSpace() throws {
        var (w, space, _, docs) = space()
        _ = try XCTUnwrap(w.addFolder(named: "Later", in: nil, of: space))
        _ = try XCTUnwrap(w.addFolder(named: "Someday", in: docs, of: space))
        let items = w.spaces[0].bookmarks
        let data = BookmarkFile.export(items)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<META NAME=\"generator\" CONTENT=\"eGlu\">"))
        let read = BookmarkFile.parse(data)
        XCTAssertTrue(read.asWritten)
        XCTAssertEqual(Self.shape(read.items), Self.shape(items))

        // Into a space with no bookmarks: the empty folders come too, and a second import adds nothing.
        let fresh = w.addSpace(named: "Fresh")
        XCTAssertTrue(w.importBookmarks(read, into: fresh).isComplete)
        let landed = try XCTUnwrap(w.space(fresh)).bookmarks
        XCTAssertEqual(Self.shape(landed), Self.shape(items))
        XCTAssertEqual(w.importBookmarks(read, into: fresh), .duplicates(total: read.count, space: "Fresh"))
        XCTAssertEqual(Self.shape(try XCTUnwrap(w.space(fresh)).bookmarks), Self.shape(items))
    }

    func testAnImportThatOnlyBringsFoldersSaysSoAndIsNoDuplicate() throws {
        var w = Workspace.onFigma()
        let space = w.spaces[0].id
        let name = w.spaces[0].name
        w.spaces[0].bookmarks = [Bookmark(title: "Figma", url: figma)]
        let read = BookmarkFile.parse(BookmarkFile.export([Bookmark(title: "Figma", url: figma),
                                                          Bookmark(folder: "Later", children: [])]))
        let outcome = w.importBookmarks(read, into: space)
        XCTAssertEqual(outcome, .imported(added: 0, total: 1, space: name, folders: 1))
        XCTAssertEqual(w.spaces[0].bookmarks.map(\.title), ["Figma", "Later"])
        XCTAssertEqual(outcome.title, "Folders Imported")
        XCTAssertEqual(outcome.message, "1 folders added to \(name). The 1 bookmarks in the file were already there.")
        // A save that fails and then succeeds keeps saying what it brought.
        let unsaved = outcome.acknowledgingSave(false)
        XCTAssertEqual(unsaved, .notSaved(added: 0, total: 1, space: name, folders: 1))
        XCTAssertTrue(unsaved.message.hasPrefix("1 folders were added to \(name)"))
        XCTAssertEqual(unsaved.acknowledgingSave(true), outcome)
    }

    func testFoldersNamedAsOtherBrowsersBarsComeBackAsFoldersFromEglusOwnExport() throws {
        var (w, space, bar, _) = space()
        let favorites = try XCTUnwrap(w.addFolder(named: "Favorites", in: nil, of: space))
        w.addBookmark(notion, title: "Notion", into: favorites, in: space)
        let others = try XCTUnwrap(w.addFolder(named: "Other bookmarks", in: nil, of: space))
        w.addBookmark(slack, title: "Slack too", into: others, in: space)
        let items = w.spaces[0].bookmarks
        let read = BookmarkFile.parse(BookmarkFile.export(items))
        // The one marked bar is the bar; Favorites and Other bookmarks stay folders, as they were.
        XCTAssertEqual(Self.shape(read.items), Self.shape(items))
        XCTAssertEqual(read.items.filter(Bookmarks.isBar).count, 1)
        XCTAssertEqual(Bookmarks.bar(in: read.items)?.children?.map(\.title),
                       Bookmarks.find(bar, in: items)?.children?.map(\.title))

        let fresh = w.addSpace(named: "Fresh")
        XCTAssertTrue(w.importBookmarks(read, into: fresh).isComplete)
        XCTAssertEqual(Self.shape(try XCTUnwrap(w.space(fresh)).bookmarks), Self.shape(items))
    }

    func testRepeatsInEglusOwnExportComeBackAsTheyWereAndOnlyOnce() throws {
        var (w, space, _, _) = space()
        // The same address twice, and two folders called Docs side by side at the top.
        w.addBookmark(figma, title: "Figma again", into: nil, in: space)
        let first = try XCTUnwrap(w.addFolder(named: "Docs", in: nil, of: space))
        let second = try XCTUnwrap(w.addFolder(named: "Docs", in: nil, of: space))
        w.addBookmark(notion, title: "Notion", into: first, in: space)
        w.addBookmark(slack, title: "Slack", into: second, in: space)
        let items = w.spaces[0].bookmarks
        let read = BookmarkFile.parse(BookmarkFile.export(items))
        XCTAssertEqual(Self.shape(read.items), Self.shape(items))

        let fresh = w.addSpace(named: "Fresh")
        XCTAssertTrue(w.importBookmarks(read, into: fresh).isComplete)
        XCTAssertEqual(Self.shape(try XCTUnwrap(w.space(fresh)).bookmarks), Self.shape(items))
        // Again: each of the file's is matched with one there, so nothing is added.
        XCTAssertEqual(w.importBookmarks(read, into: fresh), .duplicates(total: read.count, space: "Fresh"))
        XCTAssertEqual(Self.shape(try XCTUnwrap(w.space(fresh)).bookmarks), Self.shape(items))
    }

    func testAnotherBrowsersRepeatsStillComeInOnce() {
        var w = Workspace.onFigma()
        let space = w.spaces[0].id
        w.spaces[0].bookmarks = []
        let file = BookmarkImport(items: [Bookmark(title: "Figma", url: figma), Bookmark(title: "Figma again", url: figma),
                                          Bookmark(folder: "Docs", children: [Bookmark(title: "Notion", url: notion)]),
                                          Bookmark(folder: "Docs", children: [Bookmark(title: "Slack", url: slack)])],
                                  icons: [:])
        _ = w.importBookmarks(file, into: space)
        XCTAssertEqual(Self.shape(w.spaces[0].bookmarks), Self.shape([
            Bookmark(title: "Figma", url: figma),
            Bookmark(folder: "Docs", children: [Bookmark(title: "Notion", url: notion), Bookmark(title: "Slack", url: slack)]),
        ]))
    }

    func testAnotherBrowsersEmptyFoldersStayOut() throws {
        let chrome = """
        <DL><p>
            <DT><A HREF="https://www.figma.com/files">Figma</A>
            <DT><H3>Empty</H3>
            <DL><p>
            </DL><p>
        </DL><p>
        """
        let read = BookmarkFile.parse(Data(chrome.utf8))
        XCTAssertFalse(read.asWritten)
        XCTAssertEqual(read.items.map(\.title), ["Figma"])
        // And a folder with nothing in it, handed over some other way, is still left out by the merge.
        var w = Workspace.onFigma()
        let space = w.spaces[0].id
        w.spaces[0].bookmarks = []
        let file = BookmarkImport(items: [Bookmark(title: "Figma", url: figma), Bookmark(folder: "Empty", children: [])], icons: [:])
        _ = w.importBookmarks(file, into: space)
        XCTAssertEqual(w.spaces[0].bookmarks.map(\.title), ["Figma"])
    }

    func testTheBarIsWrittenFirstWhereverItStands() {
        let bar = Bookmark(folder: Bookmarks.barName, children: [Bookmark(title: "Slack", url: slack)])
        let items = [Bookmark(title: "Figma", url: figma), bar]
        let read = BookmarkFile.parse(BookmarkFile.export(items))
        XCTAssertEqual(read.items.map(\.title), [Bookmarks.barName, "Figma"])
    }

    /// Titles, addresses and nesting, without ids, which a file never keeps.
    private static func shape(_ items: [Bookmark]) -> [String] {
        items.flatMap { item -> [String] in
            let own = "\(item.title)|\(item.url?.absoluteString ?? "folder")"
            return [own] + shape(item.children ?? []).map { "  " + $0 }
        }
    }
}
