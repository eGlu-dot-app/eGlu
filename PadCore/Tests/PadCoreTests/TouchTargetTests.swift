import Foundation
import Testing

@Suite("iPad touch cells")
struct TouchTargetTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // These views belong to the iOS app, not PadCore. Keep their layout
    // contracts covered here alongside the Simulator's boundary-tap checks.
    @Test func barsAndRowsAllocateFullTouchCells() throws {
        let side = try source("App/Sources/SideTabs.swift")
        for measure in ["control", "field", "row"] {
            #expect(side.contains("static let \(measure): CGFloat = 44"))
        }
        let design = try source("App/Sources/Design.swift")
        #expect(design.contains("static let bar: CGFloat = 44"))
        #expect(design.contains("static let target: CGFloat = 44"))
        #expect(design.contains("static let control: CGFloat = 32"))
        #expect(side.contains(".frame(minHeight: Side.row)"))
        let top = try source("App/Sources/TopTabs.swift")
        #expect(top.contains(".frame(width: width, height: Side.control)"))
    }

    @Test func smallMarksHaveSeparateNonoverlappingRectangularCells() throws {
        let side = try source("App/Sources/SideTabs.swift")
        for name in ["SideClose", "SidePageMenu", "SideSpaceButton"] {
            let declaration = try #require(side.range(of: "struct \(name): View {"))
            let rest = side[declaration.upperBound...]
            let body = String(rest).components(separatedBy: "\n///").first ?? ""
            let cell = try #require(body.range(of: ".frame(width: Side.control, height: Side.control)"))
            let shape = try #require(body.range(of: ".contentShape(Rectangle())"))
            #expect(cell.lowerBound < shape.lowerBound, "\(name) hit-tests its whole allocated cell")
            #expect(!body.contains("Circle().inset(by: -6)"))
        }
        #expect(side.contains("let side: CGFloat = compact ? 24 : 28"))
        #expect(side.contains(".frame(height: compact ? 30 : 34)"))
        #expect(side.contains("row.padding(.horizontal, 3).background"))
    }

    @Test func overflowingSpacesCannotPushTheTopToolbarOffscreen() throws {
        let top = try source("App/Sources/TopTabs.swift")
        #expect(top.contains(".frame(maxWidth: max(width / 4, Side.control))"))
        let side = try source("App/Sources/SideTabs.swift")
        #expect(side.contains("ScrollView(.horizontal) { spaces(compact: true, glass: false) }"))
        #expect(side.contains(".frame(minWidth: Side.control + 6)"))
        #expect(side.contains("reader.scrollTo(space, anchor: .center)"))
    }

    @Test func customNavigationBarsRespectWindowControlCorners() throws {
        let browser = try source("App/Sources/Browser.swift")
        for name in ["TopBar", "AddressBar"] {
            #expect(browser.contains("embedBar(\(name)("))
        }
        let constraints = try source("App/Sources/ChromeConstraints.swift")
        #expect(constraints.contains(".safeArea(cornerAdaptation: .horizontal)"))
        #expect(constraints.contains("horizontal = view.safeAreaLayoutGuide"))
        #expect(constraints.contains("content.safeAreaRegions = []"))
        #expect(constraints.contains("content.view.leadingAnchor.constraint(equalTo: horizontal.leadingAnchor)"))
        #expect(constraints.contains("content.view.trailingAnchor.constraint(equalTo: horizontal.trailingAnchor)"))
        #expect(browser.contains("view.convert(item.anchor, from: topBar?.content.view)"))
    }
}
