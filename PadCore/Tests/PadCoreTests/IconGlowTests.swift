import XCTest
@testable import PadCore

final class IconGlowTests: XCTestCase {
    private let side = 24

    /// An icon `side` pixels a side, opaque, each pixel the colour `paint` gives it.
    private func icon(_ paint: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<side {
            for x in 0..<side {
                let (r, g, b) = paint(x, y)
                bytes += [r, g, b, 255]
            }
        }
        return bytes
    }

    /// The light's colour at a pixel, its premultiplication taken out, and its alpha.
    private func colour(of light: IconGlow.Light, x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let i = (y * light.side + x) * 4
        let a = Double(light.pixels[i + 3]) / 255
        guard a > 0 else { return (0, 0, 0, 0) }
        return (Double(light.pixels[i]) / 255 / a, Double(light.pixels[i + 1]) / 255 / a, Double(light.pixels[i + 2]) / 255 / a, a)
    }

    private func chroma(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        let lab = IconGlow.oklab(min(c.r, 1), min(c.g, 1), min(c.b, 1))
        return (lab.a * lab.a + lab.b * lab.b).squareRoot()
    }

    func testAnIconOfNoColourGivesNoLight() {
        XCTAssertNil(IconGlow.light(of: icon { _, _ in (0, 0, 0) }, side: side), "black")
        XCTAssertNil(IconGlow.light(of: icon { _, _ in (255, 255, 255) }, side: side), "white")
        XCTAssertNil(IconGlow.light(of: icon { x, _ in x < 12 ? (0, 0, 0) : (240, 240, 240) }, side: side), "black and white")
    }

    func testOnlyItsColourGivesLightNotItsWhiteGround() throws {
        // A white square with a red block in its top-left corner.
        let light = try XCTUnwrap(IconGlow.light(of: icon { x, y in x < 10 && y < 10 ? (230, 30, 30) : (255, 255, 255) }, side: side))
        XCTAssertGreaterThan(light.side, side, "room round the icon for the light to spread")
        let pad = (light.side - side) / 2
        let red = colour(of: light, x: pad + 4, y: pad + 4)
        let farCorner = colour(of: light, x: pad + side - 2, y: pad + side - 2)
        XCTAssertGreaterThan(red.a, 0.8)
        XCTAssertLessThan(farCorner.a, 0.1, "the white ground gives no light")
        XCTAssertGreaterThan(red.r, red.g + 0.3, "red where the red is")
        XCTAssertGreaterThan(light.tint.red, light.tint.green + 0.3)
    }

    func testTheCoreIsTheStrongestColourNotTheirMean() throws {
        // Blue over two thirds, yellow over one: the tint goes grey, the core stays blue.
        let light = try XCTUnwrap(IconGlow.light(of: icon { x, _ in x < 16 ? (30, 90, 240) : (250, 210, 20) }, side: side))
        XCTAssertGreaterThan(light.core.blue, light.core.red + 0.3)
        XCTAssertGreaterThan(light.core.blue, light.core.green + 0.1)
        let lab = IconGlow.oklab(light.core.red, light.core.green, light.core.blue)
        XCTAssertGreaterThan((lab.a * lab.a + lab.b * lab.b).squareRoot(), 0.1, "a colour, not a grey")
    }

    func testTwoColoursMeetWithoutADullSpot() throws {
        // Blue on the left, yellow on the right: spread as RGB they would meet in grey.
        let light = try XCTUnwrap(IconGlow.light(of: icon { x, _ in x < 12 ? (30, 90, 240) : (250, 210, 20) }, side: side))
        let pad = (light.side - side) / 2
        let meeting = colour(of: light, x: pad + 12, y: pad + 12)
        // The two half and half as RGB: nearly grey.
        let mixed = chroma((r: (30 + 250) / 510.0, g: (90 + 210) / 510.0, b: (240 + 20) / 510.0, a: 1))
        XCTAssertLessThan(mixed, 0.04)
        XCTAssertGreaterThan(chroma(meeting), 0.08, "where they meet is still a colour")
        // Hues apart: the glass takes their mean, which is all but grey.
        XCTAssertLessThan(chroma((r: light.tint.red, g: light.tint.green, b: light.tint.blue, a: 1)), 0.05)
    }

    func testTheLightIsNeverDarkerThanLight() throws {
        // A deep navy still lights the tile: its lightness is raised.
        let light = try XCTUnwrap(IconGlow.light(of: icon { _, _ in (20, 30, 120) }, side: side))
        let pad = (light.side - side) / 2
        let middle = colour(of: light, x: pad + 12, y: pad + 12)
        XCTAssertGreaterThan(IconGlow.oklab(min(middle.r, 1), min(middle.g, 1), min(middle.b, 1)).l, 0.55)
    }
}
