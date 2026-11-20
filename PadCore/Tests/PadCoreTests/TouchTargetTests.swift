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
        #expect(side.contains("row.padding(.horizontal, 3).background"))
    }

    @Test func spaceMarksUseDesktopScaleInsideFullTouchCells() throws {
        let side = try source("App/Sources/SideTabs.swift")
        #expect(side.contains("let side: CGFloat = compact ? 22 : 26"))
        #expect(side.contains(".font(.system(size: compact ? 10 : 12, weight: .semibold))"))
        let glass = try #require(side.range(of: "private func spaceGlass() -> some View {"))
        let surface = side[glass.upperBound...].prefix(250)
        #expect(surface.contains(".frame(height: Metrics.control)"))
        #expect(!side.contains(".frame(height: compact ? 34 : 38)"))
    }

    @Test func topTabSurfacesLeaveAirInsideTheirFullTouchCells() throws {
        let top = try source("App/Sources/TopTabs.swift")
        #expect(top.contains("Capsule().fill(Side.wash).padding(.vertical, Metrics.ring)"))
        let tab = try #require(top.range(of: "private struct TopTab: View {"))
        let surfaceStart = try #require(top[tab.upperBound...].range(of: ".frame(width: width, height: Side.control)"))
        let surfaceEnd = try #require(top[surfaceStart.upperBound...].range(of: ".contentShape(shape)"))
        let surface = top[surfaceStart.upperBound..<surfaceEnd.lowerBound]
        #expect(surface.components(separatedBy: ".padding(.vertical, Metrics.ring)").count == 3)
        let design = try source("App/Sources/Design.swift")
        #expect(design.contains("static let ring: CGFloat = (target - control) / 2"))
    }

    @Test func overflowingSpacesCannotPushTheTopToolbarOffscreen() throws {
        let top = try source("App/Sources/TopTabs.swift")
        #expect(top.contains(".frame(maxWidth: max(width / 4, Side.control * 2 + Side.gap * 4))"))
        let side = try source("App/Sources/SideTabs.swift")
        #expect(!side.contains("spacePicker"))
        #expect(side.contains(".frame(minWidth: Side.control + 6)"))
        // Main's icon-only, directly selectable Space cells remain on both bars.
        #expect(side.contains("ScrollView(.horizontal) { spaces(compact: true, glass: false) }"))
        #expect(side.contains("reader.scrollTo(space, anchor: .center)"))
        #expect(side.contains("DispatchQueue.main.async { reader.scrollTo(window.spaceID, anchor: .center) }"))
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

    @Test func compactEmptyTabUsesALegiblePromptWithoutChangingTheCommandField() throws {
        let top = try source("App/Sources/TopTabs.swift")
        #expect(top.contains("Text(compact ? String(localized: \"Search or address\") : AddressEditor.placeholder)"))
        #expect(top.contains(".truncationMode(window.url == nil ? .tail : .head)"))
        #expect(top.contains(".accessibilityHint(address ? \"Type a new address or a search\" : \"\")"))
    }
}
