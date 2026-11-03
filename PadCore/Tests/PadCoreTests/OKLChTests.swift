@testable import PadCore
import XCTest

final class OKLChTests: XCTestCase {
    private let orange = SiteColor(red: 1, green: 0.4, blue: 0)
    private let blue = SiteColor(red: 0, green: 0.48, blue: 1)

    private func close(_ a: SiteColor, _ b: SiteColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.01, file: file, line: line)
    }

    func testEndsAreTheColoursThemselves() {
        let steps = OKLCh.blend(orange, blue, count: 7)
        XCTAssertEqual(steps.count, 7)
        close(steps[0], orange)
        close(steps[6], blue)
    }

    func testTheMiddleStaysStrongWhereRGBWouldGoGrey() {
        let middle = OKLCh.blend(orange, blue, count: 3)[1]
        let chroma = OKLCh.lch(middle).c
        let ends = min(OKLCh.lch(orange).c, OKLCh.lch(blue).c)
        // Fitted into sRGB it may give a little, never most of it.
        XCTAssertGreaterThan(chroma, ends * 0.6)
        // Halfway in sRGB, by contrast, is nearly grey.
        let rgb = SiteColor(red: 0.5, green: 0.44, blue: 0.5)
        XCTAssertLessThan(OKLCh.lch(rgb).c, ends * 0.3)
    }

    func testAGreyTakesTheOtherColoursHue() {
        let grey = SiteColor(red: 0.5, green: 0.5, blue: 0.5)
        let steps = OKLCh.blend(grey, blue, count: 5)
        let hue = OKLCh.lch(blue).h
        for step in steps.dropFirst() {
            XCTAssertEqual(OKLCh.lch(step).h, hue, accuracy: 0.05)
        }
    }

    func testTheHueTurnsTheShorterWayRound() {
        // Pink to orange passes through red, not through blue and green.
        let pink = SiteColor(red: 1, green: 0.2, blue: 0.6)
        let steps = OKLCh.blend(pink, orange, count: 5)
        for step in steps {
            XCTAssertGreaterThan(step.red, max(step.green, step.blue))
        }
    }

    func testOneOrNone() {
        XCTAssertEqual(OKLCh.blend(orange, blue, count: 1).count, 1)
        XCTAssertTrue(OKLCh.blend(orange, blue, count: 0).isEmpty)
    }
}
