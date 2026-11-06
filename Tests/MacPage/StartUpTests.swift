import AppKit
import XCTest
@testable import eGluMac

/// The app hosting the page tests is kept out of the person's own: a data
/// folder, an identifier and preferences of its own, no browser window, and
/// none of the start-up services that reach shared or lasting state.
@MainActor
final class StartUpTests: PageTestCase {
    func testKnowsItHostsTests() {
        // XCTest's own variable, not a documented one: if XCTest stops
        // setting it, start-up runs every service under the tests again.
        XCTAssertTrue(Session.hostingTests, "XCTestConfigurationFilePath was not set for this run")
    }

    func testDataFolderIsTheRunsOwn() throws {
        let root = try XCTUnwrap(Session.dataRootOverride, "EGLU_DATA_ROOT is not set")
        XCTAssertEqual(Session.folder, root)
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let real = support.appendingPathComponent("Safience", isDirectory: true).standardizedFileURL.path
        let used = Session.folder.standardizedFileURL.path
        XCTAssertFalse(used == real || used.hasPrefix(real + "/"), "the tests use the real data folder, \(real)")
        XCTAssertEqual(Session.workspaceFile.deletingLastPathComponent().standardizedFileURL.path, used)
    }

    func testIdentifierIsTheRunsOwn() {
        // The tests' own identifier, as the host requires (AppDelegate), not
        // merely one that is not the real app's.
        XCTAssertEqual(Bundle.main.bundleIdentifier?.hasSuffix(".pagetests"), true)
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "net.taehee.safience")
    }

    func testStartUpFinishedWithoutAWindow() {
        XCTAssertTrue(LaunchState.shared.ready)
        XCTAssertTrue(Session.shared.started)
        XCTAssertTrue(Session.shared.canUseWorkspace)
        XCTAssertTrue(Session.shared.allWindows.isEmpty, "a browser window opened under the tests")
    }
}
