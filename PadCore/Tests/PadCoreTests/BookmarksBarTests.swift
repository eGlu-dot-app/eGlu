import XCTest
@testable import PadCore

/// The bookmarks bar: the folder whose bookmarks stand under the pinned
/// tiles, each opening in a tab of its own that stands in the bar's row.
final class BookmarksBarTests: XCTestCase {
    let figma = URL(string: "https://www.figma.com/files")!
    let slack = URL(string: "https://app.slack.com/client")!
    let notion = URL(string: "https://www.notion.so/")!
    let elsewhere = URL(string: "https://www.figma.com/design/AbC/Product")!

    /// A space with a bar of Slack and a folder holding Notion, and one tab on Figma.
    private func spaceWithBar() throws -> (Workspace, space: UUID, slack: UUID, folder: UUID, notion: UUID) {
        var w = Workspace.onFigma()
        let space = w.spaces[0].id
        let tab = try XCTUnwrap(w.spaces[0].selected)
        w.record(tab, url: figma, title: "Figma")
        let notionMark = Bookmark(title: "Notion", url: notion)
        let folder = Bookmark(folder: "Docs", children: [notionMark])
        let slackMark = Bookmark(title: "Slack", url: slack)
        w.spaces[0].bookmarks = [Bookmark(title: "Elsewhere", url: elsewhere),
                                 Bookmark(folder: "Bookmarks bar", children: [slackMark, folder])]
        return (w, space, slackMark.id, folder.id, notionMark.id)
    }

    func testTheBarIsKnownByItsNameAndTheRestAreOthers() throws {
        let (w, _, slackMark, folder, notionMark) = try spaceWithBar()
        let space = w.spaces[0]
        XCTAssertEqual(space.bar?.label, "Bookmarks bar")
        XCTAssertEqual(Bookmarks.others(in: space.bookmarks).map(\.label), ["Elsewhere"])
        XCTAssertEqual(Bookmarks.barIDs(in: space.bookmarks), [slackMark, folder, notionMark])
        // Chrome's older spelling is the same bar.
        XCTAssertTrue(Bookmarks.isBar(Bookmark(folder: "Bookmarks Bar", children: [])))
        XCTAssertFalse(Bookmarks.isBar(Bookmark(title: "Bookmarks bar", url: figma)))
    }

    func testOpeningFromTheBarMakesOneTabForTheBookmarkAfterThePinned() throws {
        var (w, space, slackMark, _, notionMark) = try spaceWithBar()
        let first = try XCTUnwrap(w.spaces[0].selected)
        XCTAssertTrue(w.pin(first))
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        XCTAssertEqual(w.spaces[0].tabs.map(\.id), [first, tab])
        XCTAssertEqual(w.spaces[0].selected, tab)
        XCTAssertEqual(w.tab(tab)?.url, slack)
        XCTAssertEqual(w.spaces[0].barTabs[slackMark]?.id, tab)
        XCTAssertTrue(w.spaces[0].otherTabs.isEmpty, "a bar tab is not one of the others")
        // Again: the same tab, not a second.
        w.select(first)
        XCTAssertEqual(w.openFromBar(slackMark, in: space), tab)
        XCTAssertEqual(w.spaces[0].tabs.count, 2)
        XCTAssertEqual(w.spaces[0].selected, tab)
        // In a folder of the bar, too; a folder itself is no tab.
        XCTAssertNotNil(w.openFromBar(notionMark, in: space))
        XCTAssertNil(w.openFromBar(w.spaces[0].bar!.children![1].id, in: space))
        XCTAssertNil(w.openFromBar(w.spaces[0].bookmarks[0].id, in: space), "not in the bar")
    }

    func testClosingABarTabTakesItAwayAndLeavesNothingToReopen() throws {
        var (w, space, slackMark, _, _) = try spaceWithBar()
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        w.record(tab, url: elsewhere, title: "Product")
        w.closeTab(tab)
        XCTAssertNil(w.tab(tab))
        XCTAssertTrue(w.closed.isEmpty)
        XCTAssertNotNil(w.spaces[0].bar?.children?.first { $0.id == slackMark }, "the bookmark stays")
    }

    func testGoingBackTakesABarTabToItsBookmark() throws {
        var (w, space, slackMark, _, _) = try spaceWithBar()
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        XCTAssertFalse(w.spaces[0].isAwayFromHome(w.tab(tab)!))
        // What the site adds as it loads is the same page.
        w.record(tab, url: URL(string: "https://app.slack.com/client/?redirect=1#top"), title: "Slack")
        XCTAssertFalse(w.spaces[0].isAwayFromHome(w.tab(tab)!))
        w.record(tab, url: elsewhere, title: "Product")
        XCTAssertTrue(w.spaces[0].isAwayFromHome(w.tab(tab)!))
        XCTAssertEqual(w.backToPinned(tab), slack)
        XCTAssertEqual(w.tab(tab)?.url, slack)
    }

    func testABookmarkLeavingTheBarLeavesItsTabAmongTheOthers() throws {
        var (w, space, slackMark, folder, notionMark) = try spaceWithBar()
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        let inFolder = try XCTUnwrap(w.openFromBar(notionMark, in: space))
        w.removeBookmark(slackMark, in: space)
        XCTAssertNil(w.tab(tab)?.bookmark)
        XCTAssertTrue(w.spaces[0].otherTabs.contains { $0.id == tab })
        // A folder moved out of the bar takes its bookmarks with it.
        w.moveBookmark(folder, into: nil, in: space)
        XCTAssertNil(w.tab(inFolder)?.bookmark)
        // Closing it now remembers it, as any other tab.
        w.closeTab(tab)
        XCTAssertEqual(w.closed.last?.tab.id, tab)
    }

    func testTheBarKeepsItsNameAndItsPlace() throws {
        var (w, space, _, folder, _) = try spaceWithBar()
        let bar = try XCTUnwrap(w.spaces[0].bar?.id)
        w.renameBookmark(bar, to: "Mine", in: space)
        XCTAssertEqual(w.spaces[0].bar?.id, bar)
        w.moveBookmark(bar, into: folder, in: space)
        XCTAssertEqual(w.spaces[0].bar?.id, bar, "never into a folder")
    }

    func testAddingATabMakesTheBarAndPutsTheTabInIt() throws {
        var w = Workspace.onFigma()
        let space = w.spaces[0].id
        let a = try XCTUnwrap(w.spaces[0].selected)
        w.record(a, url: figma, title: "Figma")
        let b = try XCTUnwrap(w.openTab(slack, in: space))
        w.record(b, url: slack, title: "Slack")
        XCTAssertTrue(w.split(a, with: b))
        XCTAssertNil(w.spaces[0].bar)
        let mark = try XCTUnwrap(w.addToBar(b))
        XCTAssertEqual(w.spaces[0].bookmarks.first?.title, Bookmarks.barName, "made at the top")
        XCTAssertEqual(w.spaces[0].bar?.children?.map(\.title), ["Slack"])
        XCTAssertEqual(w.tab(b)?.bookmark, mark)
        XCTAssertTrue(w.spaces[0].splits.isEmpty, "out of its split")
        // A pinned tab leaves the tiles for the bar, before the one there.
        XCTAssertTrue(w.pin(a))
        XCTAssertNotNil(w.addToBar(a, before: mark))
        XCTAssertFalse(w.tab(a)!.isPinned)
        XCTAssertEqual(w.spaces[0].bar?.children?.map(\.title), ["Figma", "Slack"])
        // The bar named as the folder is the bar itself.
        let c = try XCTUnwrap(w.openTab(notion, in: space))
        w.record(c, url: notion, title: "Notion")
        XCTAssertNotNil(w.addToBar(c, into: w.spaces[0].bar?.id))
        XCTAssertEqual(w.spaces[0].bar?.children?.last?.title, "Notion")
        // Pinned from the bar, it goes to the tiles and its bookmark stays.
        XCTAssertTrue(w.pin(b))
        XCTAssertNil(w.tab(b)?.bookmark)
        XCTAssertEqual(w.spaces[0].bar?.children?.count, 3)
    }

    func testSeparatingLeavesTheBookmarkAndMakesTheTabAnOrdinaryOne() throws {
        var (w, space, slackMark, _, _) = try spaceWithBar()
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        XCTAssertTrue(w.separateFromBar(tab))
        XCTAssertTrue(w.spaces[0].otherTabs.contains { $0.id == tab })
        XCTAssertNil(w.spaces[0].barTabs[slackMark])
        XCTAssertFalse(w.separateFromBar(tab))
        // The bookmark opens a tab of its own again.
        XCTAssertNotEqual(w.openFromBar(slackMark, in: space), tab)
    }

    func testBarTabsStayOutOfSplits() throws {
        var (w, space, slackMark, _, _) = try spaceWithBar()
        let first = try XCTUnwrap(w.spaces[0].selected)
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        XCTAssertFalse(w.split(first, with: tab))
        XCTAssertNil(w.splitWithNewTab(tab))
        XCTAssertEqual(w.spaces[0].tabs.count, 2, "no tab left behind")
        // Beside an ordinary tab, its page in a tab of its own.
        let copy = try XCTUnwrap(w.splitWithNewTab(first, url: slack))
        XCTAssertEqual(w.split(containing: first)?.right, copy)
        XCTAssertNil(w.tab(copy)?.bookmark)
    }

    func testMovingABarTabToAnotherSpaceMakesItAnOrdinaryTab() throws {
        var (w, space, slackMark, _, _) = try spaceWithBar()
        let other = w.addSpace(named: "Home")
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        XCTAssertTrue(w.moveTab(tab, to: other))
        XCTAssertNil(w.tab(tab)?.bookmark)
    }

    func testRowsInAShutFolderKeepTheOpenOnes() throws {
        let (w, _, slackMark, folder, notionMark) = try spaceWithBar()
        let items = w.spaces[0].bar?.children ?? []
        XCTAssertEqual(Bookmarks.rows(of: items, opening: [], keeping: []).map(\.item.id), [slackMark, folder])
        let kept = Bookmarks.rows(of: items, opening: [], keeping: [notionMark])
        XCTAssertEqual(kept.map(\.item.id), [slackMark, folder, notionMark])
        XCTAssertEqual(kept.last?.depth, 1)
        XCTAssertEqual(Bookmarks.rows(of: items, opening: [folder], keeping: []).map(\.item.id), [slackMark, folder, notionMark])
    }

    func testRepairLetsGoOfABookmarkNoLongerInTheBar() throws {
        var (w, space, slackMark, _, _) = try spaceWithBar()
        let tab = try XCTUnwrap(w.openFromBar(slackMark, in: space))
        // As iCloud may leave it: the bookmark gone from under the tab.
        w.spaces[0].bookmarks = []
        w.repair()
        XCTAssertNil(w.tab(tab)?.bookmark)
    }

    func testAnImportedBarIsTheBarAndMergesWithIt() throws {
        var (w, space, _, _, _) = try spaceWithBar()
        let file = BookmarkImport(items: [Bookmark(folder: "Bookmarks bar", children: [Bookmark(title: "Linear", url: URL(string: "https://linear.app/")!)])],
                                  icons: [:])
        _ = w.importBookmarks(file, into: space)
        XCTAssertEqual(w.spaces[0].bookmarks.filter(Bookmarks.isBar).count, 1)
        XCTAssertEqual(w.spaces[0].bar?.children?.map(\.label), ["Slack", "Docs", "Linear"])
    }

    func testAnOldFileWithoutTheLinkStillReads() throws {
        let json = #"{"id":"6B4C3E1A-1111-4B0B-9A77-2E1E9B9C0001","title":"A","shown":0,"url":"https://example.com/"}"#
        let tab = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        XCTAssertNil(tab.bookmark)
    }
}
