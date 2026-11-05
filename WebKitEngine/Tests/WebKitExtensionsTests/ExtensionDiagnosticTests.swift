#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit
import XCTest
import WebKit
import WebKitMacPlugin
@testable import WebKitExtensions

@MainActor
private final class DiagnosticHost: ExtensionDiagnosticHost {
    var verdict: [String] = []
    var onVerdict: (() -> Void)?
    func extensionDiagnosticVerdictLines(_ id: String, in space: UUID, number: Int) -> [String] {
        onVerdict?()
        return verdict
    }
}

@MainActor
private final class DiagnosticState: ExtensionDiagnosticContext {
    var reads: [String] = []
    var isLoaded: Bool { reads.append("loaded"); return true }
    var errors: [any Error] {
        reads.append("errors")
        return [NSError(domain: "fixture", code: 17, userInfo: [NSLocalizedDescriptionKey: "Fixture failure"])]
    }
    var cookies: Int { reads.append("cookies"); return -3 }
    var permissions: [String] { reads.append("permissions"); return ["tabs", "activeTab"] }
    var commands: [(id: String, key: String?, modifiers: UInt)] {
        reads.append("commands")
        return [("first", "k", 5), ("second", nil, 0)]
    }
    func permission(for url: URL) -> Int {
        reads.append(url.absoluteString)
        return url.scheme == "https" ? 2 : -2
    }
}

final class ExtensionDiagnosticTests: XCTestCase {
    @MainActor
    func testRuntimeLinesAndReadsKeepTheirOrderAroundTheAppsVerdict() throws {
        let host = DiagnosticHost(), state = DiagnosticState(), space = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stamp = folder.appendingPathComponent(ExtensionPreparation.stampFile)
        try FileManager.default.createDirectory(at: stamp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "fixture stamp\n".write(to: stamp, atomically: true, encoding: .utf8)
        host.verdict = ["space 2 verdict Works", "space 2 line A verdict line"]
        host.onVerdict = { state.reads.append("verdict") }
        let now = Date(timeIntervalSince1970: 1)
        let record = WebExtensionErrorRecord(id: "fixture", version: "1", eglu: "1", macOS: "fixture", shim: "1",
            place: "worker", api: "tabs.move", kind: "missing", count: 3, first: now, last: now)
        let runtime: any WebExtensionDiagnostics = WebKitExtensionDiagnostics(host: host, table: { nil }, context: {
            XCTAssertEqual($0, space); XCTAssertEqual($1, "fixture")
            state.reads.append("context")
            return state
        }, prepared: {
            XCTAssertEqual($0, "fixture"); XCTAssertEqual($1, "1")
            state.reads.append("prepared")
            return folder
        }, records: {
            XCTAssertEqual($0, "fixture")
            state.reads.append("records")
            return [record]
        }, scheme: "chrome-extension")
        let lines = runtime.diagnosticLines(id: "fixture", name: "Fixture", version: "1", in: space, number: 2,
            otherExtension: { state.reads.append("other"); return "other" })
        XCTAssertEqual(lines, [
            "space 2 extension Fixture loaded=true",
            "space 2 verdict Works", "space 2 line A verdict line",
            "space 2 error 17 Fixture failure", "space 2 cookies -3", "space 2 permissions activeTab tabs",
            "space 2 command first key k 5", "space 2 command second key - 0",
            "space 2 reaches https://example.com/=2 https://accounts.google.com/=2 chrome-extension://other/page.html=-2 file:///tmp/page.html=-2",
            "space 2 prepared fixture stamp\n", "space 2 record worker tabs.move missing x3"
        ])
        XCTAssertEqual(state.reads, ["context", "loaded", "verdict", "errors", "cookies", "permissions", "commands", "other",
            "https://example.com/", "https://accounts.google.com/", "chrome-extension://other/page.html", "file:///tmp/page.html", "prepared", "records"])
    }

    @MainActor
    func testMissingStateSentinelsAndMeasuredTableFiltering() {
        let host = DiagnosticHost()
        var table: ExtensionAPITable?
        let runtime = WebKitExtensionDiagnostics(host: host, table: { table }, context: { _, _ in nil },
            prepared: { _, _ in URL(fileURLWithPath: "/unused-fixture") }, records: { _ in [] }, scheme: "chrome-extension")
        XCTAssertEqual(runtime.diagnosticTableLines(), [])
        table = ExtensionAPITable(webKit: ["tabs": ["get", "query"], "alarms": [], "system.display": ["getInfo"]],
                                  shims: ["offscreen": .shim])
        XCTAssertEqual(runtime.diagnosticTableLines(), ["table 2: alarms tabs", "table tabs: 2 members"])
        XCTAssertEqual(runtime.diagnosticLines(id: "missing", name: "Missing", version: "1", in: UUID(), number: 1,
            otherExtension: { "abcdefghijklmnopabcdefghijklmnop" }), [
            "space 1 extension Missing loaded=false", "space 1 cookies 99", "space 1 permissions ",
            "space 1 reaches https://example.com/=99 https://accounts.google.com/=99 chrome-extension://abcdefghijklmnopabcdefghijklmnop/page.html=99 file:///tmp/page.html=99",
            "space 1 prepared -"
        ])
        XCTAssertEqual(runtime.diagnosticPageLine(nil, number: 3), "space 3 page -: -")
    }

    @MainActor
    func testPageLineReadsTheExistingViewWithoutLoadingOrShowingIt() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WebKitMacPage(configuration: configuration)
        defer { page.tearDown() }
        let runtime = WebKitExtensionDiagnostics(host: DiagnosticHost(), table: { nil }, context: { _, _ in nil },
            prepared: { _, _ in URL(fileURLWithPath: "/unused-fixture") }, records: { _ in [] }, scheme: "chrome-extension")
        XCTAssertEqual(runtime.diagnosticPageLine(page, number: 2),
            "space 2 page \(page.webView.url?.host() ?? "-"): \(page.webView.title ?? "-")")
        XCTAssertNil(page.webView.window)
        XCTAssertNil(page.webView.url)
        XCTAssertFalse(page.webView.isLoading)
    }

    @MainActor
    func testWordsRequireOptInAndStepsRequireAnOutputPath() throws {
        XCTAssertEqual(WebKitExtensionDiagnostics.words("fixture", enabled: false), "")
        XCTAssertEqual(WebKitExtensionDiagnostics.words(nil, enabled: true), "")
        XCTAssertEqual(WebKitExtensionDiagnostics.words(String(repeating: "한", count: 241), enabled: true),
                       ": " + String(repeating: "한", count: 240))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("report.txt")
        WebKitExtensionDiagnostics.note("ignored", outputPath: nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        WebKitExtensionDiagnostics.note("first", outputPath: out.path)
        WebKitExtensionDiagnostics.note("second", outputPath: out.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(try String(contentsOfFile: out.path + ".steps", encoding: .utf8), "first\nsecond\n")
    }
}
#endif
