#if os(macOS)
import AppKit
import PadCore
import WebKit
import XCTest
@testable import WebKitExtensions

final class ExtensionKeysTests: XCTestCase {
    @MainActor
    func testEveryModifierCombinationAndUnknownFlags() {
        for bits in 0..<16 {
            let modifiers = ExtensionKey.Modifiers(rawValue: bits)
            let flags = WebKitExtensionKeys.flags(modifiers)
            XCTAssertEqual(WebKitExtensionKeys.modifiers(flags.union([.capsLock, .numericPad, .function])), modifiers)
        }
        XCTAssertEqual(WebKitExtensionKeys.flags([.command, .control, .option, .shift]), [.command, .control, .option, .shift])
    }

    @MainActor
    func testManifestParsingAndApplyingKeepsSuggestionsAndClearsUnassignedKeys() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"Fixture","version":"1","commands":{"one":{"description":"One","suggested_key":{"default":"Ctrl+Shift+Y","mac":"MacCtrl+Alt+Comma"}},"two":{"description":"Two","suggested_key":"Alt+Shift+U"}}}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let package = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: package)
        context.uniqueIdentifier = "fixture"
        XCTAssertEqual(Set(context.commands.map(\.id)), ["one", "two"])
        let chosen = try XCTUnwrap(ExtensionKey(stored: "cmd+shift+k"))
        var suggestions: [String: ExtensionKey] = [:]
        var events: [String] = []
        WebKitExtensionKeys.apply(to: context, given: { name in
            events.append("get " + name)
            return name == "fixture/one" ? chosen : nil
        }, suggest: { name, key in
            events.append("suggest " + name)
            suggestions[name] = key
        })
        XCTAssertEqual(suggestions["fixture/one"], ExtensionKey(key: ",", modifiers: [.control, .option]))
        XCTAssertEqual(suggestions["fixture/two"], ExtensionKey(key: "u", modifiers: [.option, .shift]))
        XCTAssertEqual(events.count, 4)
        for offset in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[offset].replacingOccurrences(of: "suggest ", with: ""), events[offset + 1].replacingOccurrences(of: "get ", with: ""))
        }
        let one = try XCTUnwrap(context.commands.first { $0.id == "one" })
        let two = try XCTUnwrap(context.commands.first { $0.id == "two" })
        XCTAssertEqual(one.activationKey, "k")
        XCTAssertEqual(one.modifierFlags, [.command, .shift])
        XCTAssertNil(two.activationKey)
        XCTAssertEqual(two.modifierFlags, [])
        WebKitExtensionKeys.apply(to: context, given: { _ in nil }, suggest: { _, _ in })
        XCTAssertNil(one.activationKey)
        XCTAssertEqual(one.modifierFlags, [])
        XCTAssertNil(ExtensionKey(suggestedKey: "MediaPlayPause"))
        XCTAssertNil(ExtensionKey(suggestedKey: ["mac": "invalid", "default": "Ctrl+Y"]))
        XCTAssertEqual(ExtensionKey(suggestedKey: ["default": "Ctrl+Y"])?.modifiers, .command)
    }
}
#endif
