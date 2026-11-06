#if os(macOS)
import Foundation
import WebEngineAppKit
import XCTest

// Only contracts: another engine can supply evidence without WebKit or PadCore.
@MainActor
private final class FakeCompatibility: WebExtensionCompatibility {
    var reads: [WebExtensionCompatibilityInstallation] = []
    var checks: [WebExtensionCompatibilityInstallation] = []
    var forgotten: [String] = []
    var measurements = 0
    func readCode(of item: WebExtensionCompatibilityInstallation) { reads.append(item) }
    func measureTable() async { measurements += 1 }
    func checkCopy(of item: WebExtensionCompatibilityInstallation) { checks.append(item) }
    func checkStamp(_ version: String) -> String { "fixture|\(version)" }
    func currentFailures(_ held: [String: String], installed: [String: String]) -> [String: String] {
        held.filter { id, stamp in installed[id].map { stamp == checkStamp($0) } ?? false }
    }
    func forgetCheck(_ id: String) { forgotten.append(id) }
}

final class ExtensionCompatibilityInterfaceTests: XCTestCase {
    @MainActor
    func testCompatibilityUsesOnlyCatalogIdentitiesAndPlainValues() async {
        let fake = FakeCompatibility()
        let runtime: any WebExtensionCompatibility = fake
        let item = WebExtensionCompatibilityInstallation(id: "fixture", version: "1")
        runtime.readCode(of: item)
        runtime.checkCopy(of: item)
        await runtime.measureTable()
        XCTAssertEqual(fake.reads, [item])
        XCTAssertEqual(fake.checks, [item])
        XCTAssertEqual(fake.measurements, 1)
        XCTAssertEqual(runtime.checkStamp("1"), "fixture|1")
        XCTAssertEqual(runtime.currentFailures(["fixture": "fixture|1", "removed": "fixture|1"], installed: ["fixture": "1"]), ["fixture": "fixture|1"])
        runtime.forgetCheck("fixture")
        XCTAssertEqual(fake.forgotten, ["fixture"])
        let result = WebExtensionCompatibilityResult(testPage: .skipped, popup: .notApplicable, optionsPage: .passed,
            problems: [.init(kind: .missing, api: "proxy", file: nil)])
        XCTAssertEqual(WebExtensionCompatibilityEvidence.checked(result), .checked(result))
        XCTAssertNotEqual(WebExtensionCompatibilityEvidence.notes([]), .checking(testPage: false, popup: false, optionsPage: false))
    }
}
#endif
