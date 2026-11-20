import AppKit
import PadCore
import SwiftUI
import XCTest
@testable import eGluMac

/// Hosted controls, not a copy of their width calculation: inspect the real scroll view's viewport.
@MainActor
final class SpaceBarTests: PageTestCase {
    private var saved: Workspace?
    private var window: NSWindow?
    private var host: NSView?
    private var spaces: [Space] = []

    override func setUp() async throws {
        try await super.setUp()
        saved = Session.shared.workspace
        spaces = (1...41).map { Space(name: "Space \($0)", symbol: "circle") }
        Session.shared.change { $0 = Workspace(spaces: spaces) }
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        host = nil
        if let saved { Session.shared.change { $0 = saved } }
        try await super.tearDown()
    }

    func testRevealsRestoredLastSpace() async throws {
        let model = WindowModel(space: spaces.last?.id)
        show(SpaceBar(model: model), width: 220)
        try await atEnd()
    }

    func testRevealsFirstMiddleAndLastAfterSelectionChanges() async throws {
        let model = WindowModel(space: spaces[0].id)
        show(SpaceBar(model: model), width: 220)
        try await atStart()
        model.showSpace(spaces[40].id)
        try await atEnd()
        model.showSpace(spaces[20].id)
        try await eventually("middle Space centered") {
            guard let scroll = self.overflow, let document = scroll.documentView else { return false }
            return abs(scroll.documentVisibleRect.midX - document.bounds.midX) < 2
        }
        model.showSpace(number: 1)
        try await atStart()
    }

    func testRevealsReorderedSelectionWithoutChangingSpace() async throws {
        let model = WindowModel(space: spaces[0].id)
        show(SpaceBar(model: model), width: 220)
        try await atStart()
        Session.shared.change { $0.spaces.append($0.spaces.removeFirst()) }
        try await atEnd()
        XCTAssertEqual(model.spaceID, spaces[0].id)
    }

    func testRevealsSelectionWhenFittingRowBecomesOverflow() async throws {
        spaces = Array(spaces.prefix(5))
        Session.shared.change { $0 = Workspace(spaces: spaces) }
        let model = WindowModel(space: spaces[4].id)
        show(SpaceBar(model: model), width: 420)
        host?.layoutSubtreeIfNeeded()
        XCTAssertNil(overflow, "The five-Space row initially fits without scrolling")
        window?.setContentSize(NSSize(width: 180, height: 44))
        try await atEnd()
        window?.setContentSize(NSSize(width: 160, height: 44))
        try await atEnd()
    }

    func testTopRowHasBoundedSpaceOverflow() async throws {
        let model = WindowModel(space: spaces[40].id)
        show(TopTabBar(model: model), width: 1000)
        try await atEnd()
        let scroll = try XCTUnwrap(overflow)
        XCTAssertLessThan(scroll.frame.width, 170)
        let host = try XCTUnwrap(host)
        let frame = scroll.convert(scroll.bounds, to: host)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX)
    }

    func testSidebarKeepsOverflowCompactWhenWidened() async throws {
        let model = WindowModel(space: spaces[40].id)
        show(SpaceBar(model: model), width: 420)
        try await atEnd()
        let scroll = try XCTUnwrap(overflow)
        XCTAssertLessThan(scroll.frame.width, 170)
    }

    func testNarrowTopRowRevealsNewEmptyThirdTab() async throws {
        let model = topRowWithTwoTabs()
        show(TopTabBar(model: model).padding(.horizontal, Metrics.bezel), width: 647)
        try await eventually("initial tabs laid out") { (self.tabRow?.documentView?.bounds.width ?? 0) > 300 }

        let tab = try XCTUnwrap(Session.shared.change { $0.openTab(nil, in: model.spaceID) })
        withAnimation(.bar) { model.show(tab: tab, inSpace: model.spaceID) }

        try await atEnd("selected third tab revealed")
        XCTAssertGreaterThan(try XCTUnwrap(tabRow).contentSize.width, 160)
        XCTAssertNil(model.url)
        XCTAssertEqual(model.tabID, tab)
    }

    func testNarrowTopRowRevealsPopulatedThirdTabAfterSpaceRestore() async throws {
        let model = topRowWithTwoTabs()
        let space = model.spaceID
        let tab = try XCTUnwrap(Session.shared.change { $0.openTab(Self.address("Audit page C"), in: space) })
        model.show(tab: tab, inSpace: space)
        show(TopTabBar(model: model).padding(.horizontal, Metrics.bezel), width: 644)
        try await eventually("initial tabs laid out") { (self.tabRow?.documentView?.bounds.width ?? 0) > 300 }

        model.showSpace(spaces[0].id)
        try await eventually("other Space has no tab") { (self.tabRow?.documentView?.bounds.width ?? .infinity) < 10 }
        model.showSpace(space)

        try await atEnd("restored third tab revealed")
        XCTAssertGreaterThan(try XCTUnwrap(tabRow).contentSize.width, 160)
        XCTAssertEqual(model.tabID, tab)
        XCTAssertEqual(model.url, Self.address("Audit page C"))
    }

    func testTopRowKeepsSelectedTabVisibleWhenNarrowed() async throws {
        let model = topRowWithTwoTabs()
        let tab = try XCTUnwrap(Session.shared.change { $0.openTab(Self.address("Audit page C"), in: model.spaceID) })
        model.show(tab: tab, inSpace: model.spaceID)
        show(TopTabBar(model: model).padding(.horizontal, Metrics.bezel), width: 1000)
        try await eventually("initial tabs laid out") { (self.tabRow?.documentView?.bounds.width ?? 0) > 300 }

        window?.setContentSize(NSSize(width: 644, height: 44))

        try await atEnd("selected third tab revealed after resize")
        XCTAssertEqual(model.tabID, tab)
    }

    private func topRowWithTwoTabs() -> WindowModel {
        spaces = (1...42).map { Space(name: "Space \($0)", symbol: "circle") }
        let tabs = [TabRecord(url: Self.address("Audit page A")), TabRecord(url: Self.address("Audit page B"))]
        spaces[20].tabs = tabs
        spaces[20].selected = tabs[1].id
        Session.shared.change { $0 = Workspace(spaces: spaces) }
        let model = WindowModel(space: spaces[20].id)
        model.show(tab: tabs[1].id, inSpace: spaces[20].id)
        return model
    }

    private var tabRow: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return host.flatMap(find)
    }

    private func show<Content: View>(_ content: Content, width: CGFloat) {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 44),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        self.host = host
    }

    private var overflow: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView,
               let document = scroll.documentView, document.bounds.width > scroll.contentSize.width + 1,
               scroll.contentSize.width > 0 {
                return scroll
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return host.flatMap(find)
    }

    private func atStart(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually("first Space visible", file: file, line: line) {
            guard let scroll = self.overflow else { return false }
            return abs(scroll.documentVisibleRect.minX) < 2
        }
    }

    private func atEnd(_ description: String = "last Space visible", file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually(description, file: file, line: line) {
            guard let scroll = self.overflow, let document = scroll.documentView else { return false }
            return abs(scroll.documentVisibleRect.maxX - document.bounds.maxX) < 2
        }
    }

    private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host?.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail(description, file: file, line: line)
    }
}
