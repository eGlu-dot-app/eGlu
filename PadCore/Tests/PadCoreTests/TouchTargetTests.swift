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
        #expect(top.contains(".fixedSize(horizontal: true, vertical: false)"))
        let side = try source("App/Sources/SideTabs.swift")
        #expect(side.contains("if inRow, let space {"))
        #expect(side.contains("spacePicker(space)"))
        #expect(side.contains(".frame(width: 152, height: 34)"))
        #expect(side.contains(".accessibilityValue(current.name)"))
        #expect(side.contains("Picker(\"Space\", selection:"))
        #expect(side.contains("Label(space.name, systemImage: space.symbol).tag(space.id)"))
        // The sidebar keeps its directly selectable, scrollable Space cells.
        #expect(side.contains("ScrollView(.horizontal) { spaces(compact: true, glass: false) }"))
        #expect(side.contains("reader.scrollTo(space, anchor: .center)"))
    }

    @Test func compactTopBarKeepsCurrentTabAndItsActionsOutsideTheScroller() throws {
        let top = try source("App/Sources/TopTabs.swift")
        let compact = try #require(top.range(of: "if compact, let tab = pinnedOnScreen"))
        let scroller = try #require(top.range(of: "ScrollViewReader { reader in"))
        let current = top[compact.lowerBound..<scroller.lowerBound]
        #expect(current.contains("width: max(box.size.width, 0), compact: true"))
        #expect(top.contains("AllTabsButton(count:"))
        #expect(top.contains("SidePageMenu(window: window, act: act, inTab: true, compactToolbar: compact)"))
        #expect(top.contains("SideClose { act(.close(tab.id)) }"))
        let side = try source("App/Sources/SideTabs.swift")
        #expect(side.contains("if compactToolbar {"))
        #expect(side.contains("Label(\"Show Bookmarks Bar\", systemImage:"))
        #expect(side.contains("Section { AppItems(act: act) }"))
    }
}
