import Foundation
import Testing

@Suite("iPad window-control clearance")
struct WindowControlTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
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

    @Test func compactSpaceStripBoundsWidthWithoutLosingItsTouchCell() throws {
        let top = try source("App/Sources/TopTabs.swift")
        #expect(top.contains(".frame(maxWidth: width < 1000 ? Side.control * 2 + Side.gap * 4 : nil)"))
        let side = try source("App/Sources/SideTabs.swift")
        let scroller = try #require(side.range(of: "ScrollViewReader { reader in"))
        #expect(side[scroller.lowerBound...].contains(".frame(minWidth: Side.control + 6)"))
    }
}
