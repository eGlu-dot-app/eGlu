import ImageIO
import WebKitSupport
import XCTest

final class WebKitSVGRasterTests: XCTestCase {
    private static let square = """
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <rect width="10" height="10" fill="red"/>
        </svg>
        """

    @MainActor
    func testFilledSquareIsPNGOfTheRequestedPixelSize() async throws {
        for side in [24, 96] {
            let drawn = await draw(Self.square, side: side)
            let png = try XCTUnwrap(drawn)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, side)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, side)
        }
    }

    @MainActor
    func testDarkLookChangesTheDrawnPixels() async throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <style>rect { fill: red } @media (prefers-color-scheme: dark) { rect { fill: blue } }</style>
              <rect width="10" height="10"/>
            </svg>
            """
        let lightPNG = await draw(svg, dark: false)
        let light = try XCTUnwrap(lightPNG)
        let darkPNG = await draw(svg, dark: true)
        let dark = try XCTUnwrap(darkPNG)
        func pixels(_ png: Data) throws -> Data {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        XCTAssertNotEqual(try pixels(light), try pixels(dark))
    }

    @MainActor
    func testTextThatIsNotSVGHasNoPNG() async {
        let png = await draw("This is not SVG.")
        XCTAssertNil(png)
    }

    func testForcingLightAndDarkAndLeavingOtherDrawingsAlone() {
        let svg = "@media (prefers-color-scheme: dark) { a } @media (prefers-color-scheme: light) { b }"
        XCTAssertEqual(WebKitSVGRaster.forcing(svg, dark: false), "@media (max-width: 0px) { a } @media (min-width: 0px) { b }")
        XCTAssertEqual(WebKitSVGRaster.forcing(svg, dark: true), "@media (min-width: 0px) { a } @media (max-width: 0px) { b }")
        XCTAssertEqual(WebKitSVGRaster.forcing("( PREFERS-COLOR-SCHEME : DARK )", dark: true), "(min-width: 0px)")
        for dark in [false, true] {
            XCTAssertEqual(WebKitSVGRaster.forcing(Self.square, dark: dark), Self.square)
        }
    }

    /// Bounds the test even if the sandbox cannot launch WebKit's content process.
    @MainActor
    private func draw(_ svg: String, side: Int = 24, dark: Bool = false) async -> Data? {
        let done = expectation(description: "SVG answered")
        var png: Data?
        let work = Task { @MainActor in
            png = await WebKitSVGRaster.shared.png(of: svg, side: side, dark: dark)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        work.cancel()
        return png
    }
}
