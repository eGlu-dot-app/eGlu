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
