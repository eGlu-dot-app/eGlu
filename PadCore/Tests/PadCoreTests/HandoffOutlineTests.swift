import Foundation
import Testing
@testable import PadCore

/// What the sheet lists of the file while it is made (Handoff.Outline):
/// read off the composed text, in the file's own words.
struct HandoffOutlineTests {
    static func composed(_ body: String, kind: PageKind = .article) -> Handoff.Composed {
        Handoff.Composed(kind: kind, body: body)
    }

    @Test func partsAreTheSecondLevelUnderAPageTitle() {
        let outline = Handoff.outline(of: Self.composed("""
        # Google is killing Gmail's basic HTML view

        Google is **sunsetting** the [basic HTML view](https://example.org/a) in January.

        ## What changes

        The Standard view takes its place.

        ### For older browsers

        They see a notice.

        ## Who it is for

        - People on slow connections
        - Old devices
        """))
        #expect(outline.sections.map(\.heading) == ["", "What changes", "Who it is for"])
        #expect(outline.sections[0].opening == "Google is sunsetting the basic HTML view in January.")
        #expect(outline.sections[1].opening == "The Standard view takes its place.")
        #expect(outline.sections[2].shape == .list)
        #expect(outline.sections[2].opening == "People on slow connections")
    }

    @Test func aPartOnlyStartedSaysSo() {
        let outline = Handoff.outline(of: Self.composed("""
        ## Plans

        Basic is free.

        [1,200 more characters here.]

        ## FAQ

        Questions people ask.
        """, kind: .landing))
        #expect(outline.sections.map(\.started) == [true, false])
        #expect(outline.sections[0].opening == "Basic is free.")
    }

    @Test func tablesAndCodeAreNamedByWhatTheyBeginWith() {
        let outline = Handoff.outline(of: Self.composed("""
        ## Prices

        | Plan | Price |
        | --- | --- |
        | Pro | $8 |

        ## Install

        ```
        # not a heading
        brew install tide
        ```
        """))
        #expect(outline.sections.map(\.heading) == ["Prices", "Install"])
        #expect(outline.sections[0].shape == .table)
        #expect(outline.sections[0].opening == "Plan · Price")
        #expect(outline.sections[1].shape == .code)
        #expect(outline.sections[1].opening == "# not a heading")
    }

    @Test func aHeadingWithOnlyLowerHeadingsNamesThem() {
        let outline = Handoff.outline(of: Self.composed("""
        ## Plans

        ### Basic

        ### Pro

        ## About

        Made in Seoul.
        """))
        #expect(outline.sections.first?.opening == "Basic · Pro")
    }

    @Test func aPageWithNoHeadingsIsOnePart() {
        let outline = Handoff.outline(of: Self.composed("First paragraph of the page.\n\nSecond one."))
        #expect(outline.sections == [Handoff.Outline.Section(heading: "", opening: "First paragraph of the page.")])
    }

    @Test func notesOfTheFileAreNotOpenings() {
        let outline = Handoff.outline(of: Self.composed("""
        [On screen down to here. The rest of the page follows.]

        ## Inbox

        [Message one](https://example.org/1): from Ana
        """, kind: .app))
        #expect(outline.sections.map(\.heading) == ["Inbox"])
        #expect(outline.sections[0].opening == "Message one: from Ana")
    }

    @Test func longOpeningsAreCut() {
        let words = String(repeating: "tide ", count: 80)
        let outline = Handoff.outline(of: Self.composed("## Notes\n\n" + words))
        let opening = outline.sections[0].opening
        #expect(opening.count <= Handoff.openingRoom + 1)
        #expect(opening.hasSuffix("…"))
    }

    @Test func selectionAndAsidesComeFromTheComposed() {
        var composed = Self.composed("## Talk\n\nWords.")
        composed.selection = "The **tide** comes in."
        composed.asides = [Handoff.Aside(name: "Comments", characters: 3_200)]
        let outline = Handoff.outline(of: composed)
        #expect(outline.selection == "The tide comes in.")
        #expect(outline.asides.map(\.name) == ["Comments"])
        #expect(!outline.transcript)
        #expect(!outline.isEmpty)
        #expect(Handoff.outline(of: Self.composed("")).isEmpty)
    }

    @Test func emphasisInsideWordsStays() {
        #expect(Handoff.outlinePlain("snake_case and *bold* and 2*3*4") == "snake_case and bold and 2*3*4")
    }
}

/// What the outline leaves to the page's own words.
struct HandoffOutlineReadingTests {
    @Test func textReadInPicturesIsNotAPart() {
        let picture = Handoff.pictureText + "# Coastline in both\n\nCoastline in both maps and charts"
        let body = "# Tide\n\nTides rise and fall.\n\n## Characteristics\n\nThe range varies.\n\n" + picture + "\n\n## History\n\nPeople watched them."
        var reading = PageReading(blocks: [PageBlock(text: picture)])
        reading.blocks.append(PageBlock(text: "## History"))
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: body), reading: reading)
        #expect(outline.sections.map(\.heading) == ["", "Characteristics", "History"])
    }

    @Test func aLongParagraphOpensBeforeTabsAndNotes() {
        let long = String(repeating: "Tides are the periodic rise and fall of sea level. ", count: 5)
        let body = "- [Article](https://example.org/a)\n- [Talk](https://example.org/t)\n\nFor other uses, see Tide.\n\n" + long
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: body))
        #expect(outline.sections.first?.opening.hasPrefix("Tides are the periodic") == true)
        #expect(outline.sections.first?.shape == .text)
    }
}

struct HandoffOutlineWordsTests {
    @Test func linksWithParenthesesInTheirAddress() {
        #expect(Handoff.outlinePlain("Oscillating [currents](https://en.wikipedia.org/wiki/Current_(fluid)) flow.[^4][^:235]")
                == "Oscillating currents flow.")
    }

    @Test func aPartOpensWithItsFirstWordsEvenIfShort() {
        let long = String(repeating: "Oscillating currents produced by tides are tidal streams. ", count: 5)
        let body = "## Characteristics\n\nOcean tides are cyclic.\n\n" + long
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: body))
        #expect(outline.sections.first?.opening == "Ocean tides are cyclic.")
    }
}

struct HandoffOutlineOpeningTests {
    @Test func aLabelOrACaptionIsNotTheOpening() {
        let body = """
        ## Physics

        Main article: [Theory of tides](https://example.org/t)

        [![A chart of the tides.](https://example.org/c.png)](https://example.org/c)

        The forces of the Moon and the Sun pull on the oceans.
        """
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: body))
        #expect(outline.sections.first?.opening == "The forces of the Moon and the Sun pull on the oceans.")
    }

    @Test func aLinkedPictureIsItsWords() {
        #expect(Handoff.outlinePlain("[![A chart.](https://example.org/c.png)](https://example.org/c)") == "A chart.")
    }

    @Test func withNoSentenceTheFirstBlockOpens() {
        let outline = Handoff.outline(of: Handoff.Composed(kind: .landing, body: "## Links\n\nMain article: Tides"))
        #expect(outline.sections.first?.opening == "Main article: Tides")
    }
}

struct HandoffOutlineLeadTests {
    @Test func theLeadOpensWithItsSubjectInBold() {
        let caption = String(repeating: "Simplified schematic of the lunar portion of the tides. ", count: 5)
        let lead = "**Tides** are " + String(repeating: "the periodic rise and fall of sea level. ", count: 6)
        let body = "For other uses, see Tide.\n\n" + caption + "\n\n" + lead + "\n\n## History\n\nPeople watched them."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: body))
        #expect(outline.sections.first?.opening.hasPrefix("Tides are the periodic") == true)
    }
}

struct HandoffOutlineShapeTests {
    @Test func aPartThatBeginsWithATableStaysATable() {
        let body = "## Prices\n\n| Plan | Price |\n| --- | --- |\n| Pro | $8 |\n\nAll prices include tax."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .product, body: body))
        #expect(outline.sections.first?.shape == .table)
        #expect(outline.sections.first?.opening == "Plan · Price")
    }

    @Test func aLongerFenceHoldsAShorterOne() {
        let body = "## Code\n\n````\n```\n## not a part\n```\n````\n\n## After\n\nWords."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: body))
        #expect(outline.sections.map(\.heading) == ["Code", "After"])
    }

    @Test func partsAreTheHighestHeadingsUsedMoreThanOnce() {
        let body = "# Book\n\n## Chapter 1\n\n### One\n\nFirst.\n\n### Two\n\nSecond."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .document, body: body))
        #expect(outline.sections.map(\.heading) == ["One", "Two"])
    }

    @Test func aMarkerInBracketsIsNotAnOpening() {
        let outline = Handoff.outline(of: Handoff.Composed(kind: .media, body: "## Clip\n\n[Video]\n\nThe tide comes in."))
        #expect(outline.sections.first?.opening == "The tide comes in.")
    }
}

struct HandoffOutlineReviewTests {
    @Test func aPartWhoseWordsAreAllCountedStays() {
        let body = "## Archive\n\n[1,200 more characters here.]\n\n## Next\n\nWords of the next part."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .app, body: body))
        #expect(outline.sections.map(\.heading) == ["Archive", "Next"])
        #expect(outline.sections[0] == Handoff.Outline.Section(heading: "Archive", opening: "", started: true, left: 1_200))
        #expect(outline.sections[1].left == 0)
    }

    @Test func aPartOnlyStartedCountsWhatIsLeftOut() {
        let body = "## Plans\n\nBasic is free.\n\n[300 more characters here.]\n\n[1,000 more characters here.]"
        let outline = Handoff.outline(of: Handoff.Composed(kind: .landing, body: body))
        #expect(outline.sections.first?.started == true)
        #expect(outline.sections.first?.left == 1_300)
    }

    /// A reading with the site's transcript added (PageReading.adding).
    static func spoken() -> PageReading {
        var reading = PageReading(blocks: [])
        reading.spoken = PageReading.Spoken(lines: 1)
        return reading
    }

    @Test func theSitesTranscriptIsNotAlsoAPart() {
        var composed = Handoff.Composed(kind: .media, body: "## Description\n\nA video about tides.\n\n## Transcript\n\n0:00 Hello there.")
        composed.transcript = true
        let outline = Handoff.outline(of: composed, reading: Self.spoken())
        #expect(outline.sections.map(\.heading) == ["Description"])
        #expect(outline.transcript)
    }

    @Test func aPartOfThePagesCalledTranscriptStays() {
        let body = "## Transcript\n\nThe page's own notes on the talk.\n\n## Description\n\nA video about tides.\n\n## Transcript\n\n0:00 Hello there."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .media, body: body), reading: Self.spoken())
        #expect(outline.sections.map(\.heading) == ["Transcript", "Description"])
        #expect(outline.sections.first?.opening == "The page's own notes on the talk.")
    }

    @Test func theSitesTranscriptIsItsOwnPartUnderTopHeadings() {
        let body = "# Intro\n\nWords of the page.\n\n# Details\n\nA label\n\n## Transcript\n\n0:00 Hello there.\n\n## Notes\n\n1. A note."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .media, body: body), reading: Self.spoken())
        #expect(outline.sections.map(\.heading) == ["Intro", "Details", "Notes"])
        #expect(outline.sections[1].opening == "A label")
        #expect(outline.transcript)
    }

    @Test func theSitesTranscriptIsNotTakenForAPageTitle() {
        let body = "### Intro\n\nWords of the page.\n\n### Details\n\nA label\n\n## Transcript\n\n0:00 Hello there."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .media, body: body), reading: Self.spoken())
        #expect(outline.sections.map(\.heading) == ["Intro", "Details"])
        #expect(outline.sections[1].opening == "A label")
    }

    @Test func aLoneHigherHeadingAfterThePartsIsAPart() {
        let body = "### Intro\n\nWords.\n\n### Details\n\nMore words.\n\n## Appendix\n\nExtra text.\n\n## Transcript\n\n0:00 Hello there."
        let spoken = Handoff.outline(of: Handoff.Composed(kind: .media, body: body), reading: Self.spoken())
        #expect(spoken.sections.map(\.heading) == ["Intro", "Details", "Appendix"])
        let plain = Handoff.outline(of: Handoff.Composed(kind: .article, body: "### Intro\n\nWords.\n\n### Details\n\nMore.\n\n## Appendix\n\nExtra."))
        #expect(plain.sections.map(\.heading) == ["Intro", "Details", "Appendix"])
    }

    @Test func withNoLevelTwiceAHeadingBeforeTheHighestIsAPart() {
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: "### Intro\n\nWords.\n\n## Appendix\n\nExtra."))
        #expect(outline.sections.map(\.heading) == ["Intro", "Appendix"])
        #expect(outline.sections.map(\.opening) == ["Words.", "Extra."])
    }

    @Test func withNoLevelTwiceAHeadingUnderTheHighestGoesWithIt() {
        let body = "# Guide\n\n## Installation\n\n### macOS\n\nDrag the app to Applications."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .article, body: body))
        #expect(outline.sections.map(\.heading) == ["Installation"])
        #expect(outline.sections.first?.opening == "Drag the app to Applications.")
    }

    @Test func aPageWithNoHeadingsButTheTranscript() {
        let body = "The page's only paragraph.\n\n## Transcript\n\n0:00 Hello there."
        let outline = Handoff.outline(of: Handoff.Composed(kind: .media, body: body), reading: Self.spoken())
        #expect(outline.sections == [Handoff.Outline.Section(heading: "", opening: "The page's only paragraph.")])
        #expect(outline.transcript)
    }

    @Test func aTranscriptOfThePagesOwnIsAPart() {
        var composed = Handoff.Composed(kind: .media, body: "## Description\n\nA video.\n\n## Transcript\n\n0:00 Hello there.")
        composed.transcript = true
        let outline = Handoff.outline(of: composed)
        #expect(outline.sections.map(\.heading) == ["Description", "Transcript"])
        #expect(!outline.transcript)
    }
}
