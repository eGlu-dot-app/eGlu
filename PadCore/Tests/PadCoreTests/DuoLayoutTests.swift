import Foundation
import Testing
@testable import PadCore

/// The sidebar against the iPhone Duo's fold (Docs/iPhoneDuoDesign.md §5).
struct DuoLayoutTests {
    /// A 932-point-wide window folded like a book: a 20-point fold, margins
    /// included, down its middle.
    private let book = CGRect(x: 456, y: 0, width: 20, height: 678)

    private func sidebar(start: CGFloat = 0, fold: CGRect?, rightToLeft: Bool = false) -> DuoLayout.Sidebar {
        DuoLayout.sidebar(start: start, fold: fold, rightToLeft: rightToLeft, standard: 248, minimum: 200, gap: 8)
    }

    @Test func `folded like a book, the sidebar reaches the fold and the page starts past it`() {
        #expect(sidebar(fold: book) == DuoLayout.Sidebar(width: 456, gap: 20))
    }

    @Test func `from where the sidebar starts, not the window's edge`() {
        #expect(sidebar(start: 12, fold: book).width == 444)
    }

    @Test func `right to left, the sidebar fills the right half`() {
        #expect(sidebar(start: 932, fold: book, rightToLeft: true) == DuoLayout.Sidebar(width: 456, gap: 20))
    }

    @Test(arguments: [
        nil,
        // Like a laptop: the fold runs across.
        CGRect(x: 0, y: 330, width: 932, height: 20),
        // Nearer the edge than a sidebar can be narrow.
        CGRect(x: 150, y: 0, width: 20, height: 678),
        // Behind where the sidebar starts.
        CGRect(x: 0, y: 0, width: 20, height: 678),
    ] as [CGRect?])
    func `otherwise the sidebar is its own width`(fold: CGRect?) {
        #expect(sidebar(fold: fold) == DuoLayout.Sidebar(width: 248, gap: 8))
    }
}

/// The strip's bands over a page that runs on under it (Docs/iPhoneDuoDesign.md §9).
struct StripBandsTests {
    private func bands(_ frames: [CGRect], pageTop: CGFloat = 0) -> [[CGFloat]] {
        DuoLayout.stripBands(of: frames, pageTop: pageTop, pageHeight: 586, margin: 4)
    }

    @Test func `each frame's top and bottom, a margin further out`() {
        #expect(bands([CGRect(x: 395, y: 180, width: 46, height: 96)]) == [[176, 280]])
    }

    @Test func `overlapping and touching frames are one band, top first`() {
        let frames = [
            CGRect(x: 382, y: 0, width: 84, height: 174),
            CGRect(x: 395, y: 284, width: 46, height: 52),
            CGRect(x: 395, y: 178, width: 46, height: 100),
            CGRect(x: 399.7, y: 29.3, width: 37, height: 37),
        ]
        #expect(bands(frames) == [[-4, 340]])
    }

    @Test func `apart, two bands`() {
        let frames = [CGRect(x: 395, y: 180, width: 46, height: 96), CGRect(x: 395, y: 542, width: 46, height: 102)]
        #expect(bands(frames) == [[176, 280], [538, 648]])
    }

    @Test func `in the page's points, wholly outside it left out`() {
        let frames = [CGRect(x: 395, y: 10, width: 46, height: 20), CGRect(x: 395, y: 700, width: 46, height: 40),
                      CGRect(x: 395, y: 200, width: 46, height: 40), CGRect(x: 395, y: 300, width: 46, height: 0)]
        #expect(bands(frames, pageTop: 40) == [[156, 204]])
    }

    @Test func `encoded for the page's script`() throws {
        let strip = DuoLayout.Strip(side: .right, width: 84, bands: [[0, 340], [538, 648]], ramp: 44)
        let json = String(decoding: try JSONEncoder().encode(strip), as: UTF8.self)
        #expect(json.contains("\"side\":\"right\""))
        #expect(json.contains("\"bands\":[[0,340],[538,648]]"))
    }
}
