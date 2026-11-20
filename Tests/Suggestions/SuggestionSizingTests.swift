import PadCore
import SwiftUI
import UIKit
import XCTest
@testable import eGlu

/// Lay out the production rows: a row-count formula cannot stand in for
/// SwiftUI's fonts, wrapping, headings and vertical padding.
@MainActor
final class SuggestionSizingTests: XCTestCase {
    private let longRow = Suggestion(
        id: "setting", source: .setting, action: .setting(.diagnostics),
        phrase: "Diagnostics and browser troubleshooting", typed: [],
        detail: "Inspect the current page and collect detailed diagnostic information"
    )
    private let command = Suggestion(
        id: "command", source: .command, action: .command(.diagnostics),
        phrase: "Diagnostics", typed: []
    )

    func testAccessibilityTextGrowsTheNaturalContentHeight() async throws {
        let standard = try await height([longRow, command], type: .large)
        let accessible = try await height([longRow, command], type: .accessibility5)
        XCTAssertGreaterThan(accessible, standard)
    }

    func testNarrowWidthMeasuresWrappedContent() async throws {
        var row = longRow
        row.phrase = "Browser diagnostics"
        row.detail = ""
        let wide = try await height([row], width: 1000, type: .accessibility5)
        let narrow = try await height([row], width: 300, type: .accessibility5)
        XCTAssertGreaterThan(narrow, wide)
    }

    func testSectionHeadingsAreIncludedAtAccessibilitySize() async throws {
        let plain = try await height([command, longRow], type: .accessibility5)
        let grouped = try await height([command, longRow], type: .accessibility5, listing: true)
        XCTAssertGreaterThan(grouped, plain)
    }

    func testShortViewportDoesNotCompressTheMeasuredRows() async throws {
        let roomy = try await height([longRow, command], type: .accessibility5, viewport: 800)
        let constrained = try await height([longRow, command], type: .accessibility5, viewport: 100)
        XCTAssertEqual(constrained, roomy, accuracy: 1)
        XCTAssertGreaterThan(constrained, 100)
    }

    func testAllOffscreenRowsContributeToTheMeasurement() async throws {
        let one = try await height([longRow], type: .accessibility5, viewport: 100)
        let rows = (0..<12).map { index in
            var row = longRow
            row.id = "setting-\(index)"
            return row
        }
        let many = try await height(rows, type: .accessibility5, viewport: 100)
        XCTAssertEqual(many - 2 * SuggestionRows.inset,
                       12 * (one - 2 * SuggestionRows.inset), accuracy: 12)
    }

    func testEmptyContentHasNoResidualPadding() async throws {
        let empty = try await height([])
        XCTAssertEqual(empty, 0)
    }

    private func height(
        _ rows: [Suggestion], width: CGFloat = 380, type: DynamicTypeSize = .large,
        viewport: CGFloat = 600, listing: Bool = false
    ) async throws -> CGFloat {
        let measured = expectation(description: "Rendered suggestion content")
        var height: CGFloat = -1
        let view = SuggestionRows(rows: rows, listing: listing, heightChanged: { value in
            height = value
            measured.fulfill()
        }, choose: { _ in })
            .environment(\.dynamicTypeSize, type)
            .frame(width: width, height: viewport)
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        await fulfillment(of: [measured], timeout: 5)
        return height
    }
}

/// Exercise the production UIKit constraints with content that wants more
/// width than the page. A preferred width must not let the palette escape
/// the page's edges when a sidebar leaves less room in portrait.
@MainActor
final class CommandBarWidthTests: XCTestCase {
    func testPaletteFitsBesideSidebarWhileResizingInBothDirections() {
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            let (root, page, bar) = layout(sidebar: true, direction: direction)
            for size in [CGSize(width: 1210, height: 834), CGSize(width: 834, height: 1210), CGSize(width: 1210, height: 834)] {
                root.frame.size = size
                root.setNeedsLayout()
                root.layoutIfNeeded()
                assertFits(bar, in: page)
                if size.width == 1210 {
                    XCTAssertEqual(bar.bounds.width, 680, accuracy: 0.5, "Preserve the wide palette")
                }
            }
        }
    }

    func testPaletteFitsNarrowWindowWithoutSidebar() {
        let (root, page, bar) = layout(sidebar: false)
        root.frame.size = CGSize(width: 600, height: 834)
        root.setNeedsLayout()
        root.layoutIfNeeded()
        assertFits(bar, in: page)
    }

    private func layout(
        sidebar: Bool, direction: UISemanticContentAttribute = .forceLeftToRight
    ) -> (UIView, UIView, UIView) {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
        root.semanticContentAttribute = direction
        let page = UIView()
        let side = UIView()
        let bar = WidePalette()
        for child in [page, side, bar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        // Content can outrank a preferred width, but never its required bounds.
        bar.setContentCompressionResistancePriority(.init(751), for: .horizontal)
        let constraints = ChromeConstraints()
        constraints.pinStack(page, in: root)
        constraints.pinSidebar(side, to: root.safeAreaLayoutGuide, stack: page)
        constraints.placeStack(besideSidebar: sidebar)
        constraints.pinCommandBar(bar, to: page)
        bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 160).isActive = true
        return (root, page, bar)
    }

    private func assertFits(_ bar: UIView, in page: UIView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(bar.frame.minX, page.frame.minX + 16 - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(bar.frame.maxX, page.frame.maxX - 16 + 0.5, file: file, line: line)
        XCTAssertEqual(bar.frame.midX, page.frame.midX, accuracy: 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(bar.bounds.width, 680.5, file: file, line: line)
    }
}

@MainActor
private final class WidePalette: UIView {
    override var intrinsicContentSize: CGSize { CGSize(width: 1100, height: 160) }
}
