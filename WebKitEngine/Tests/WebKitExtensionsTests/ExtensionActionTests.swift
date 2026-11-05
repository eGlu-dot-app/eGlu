#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

@MainActor
private final class CommandContext: WKWebExtensionContext {
    var performed: [WKWebExtension.Command] = []

    override func performCommand(_ command: WKWebExtension.Command) {
        performed.append(command)
    }
}

final class ExtensionActionTests: XCTestCase {
    @MainActor
    private func fixture(action: Bool = true) async throws -> WKWebExtension {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("action-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var manifest: [String: Any] = [
            "manifest_version": 3, "name": "Action fixture", "version": "1",
            "commands": ["zebra": ["description": "Last named", "suggested_key": "Ctrl+Shift+Y"],
                         "alpha": ["description": "First named", "suggested_key": "Alt+Shift+U"]]
        ]
        if action {
            manifest["action"] = ["default_title": "Fixture action",
                                  "default_icon": ["20": "20.png", "24": "24.png"]]
            for size in [20, 24] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                                          bytesPerRow: size * 4, bitsPerPixel: 32))
                let color = NSColor(deviceRed: size == 20 ? 1 : 0, green: 0, blue: size == 24 ? 1 : 0, alpha: 1)
                for x in 0..<size {
                    for y in 0..<size { bitmap.setColor(color, atX: x, y: y) }
                }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("\(size).png"))
            }
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        // Parsed only. No controller, store, web view or background is made.
        return try await WKWebExtension(resourceBaseURL: folder)
    }

    @MainActor
    func testActionLookUsesTheRequestedIconAndCurrentFieldsWithoutLoading() async throws {
        let package = try await fixture()
        let context = WKWebExtensionContext(for: package)
        XCTAssertFalse(context.isLoaded)
        let action = try XCTUnwrap(context.action(for: nil))
        for size in [20, 24] {
            let requested = CGSize(width: size, height: size)
            let look = WebKitExtensionActions.look(of: action, iconSize: requested)
            let icon = try XCTUnwrap(look.icon)
            XCTAssertEqual(icon.tiffRepresentation, action.icon(for: requested)?.tiffRepresentation)
            XCTAssertEqual(look.label, action.label)
            XCTAssertEqual(look.label, "Fixture action")
            XCTAssertEqual(look.badgeText, action.badgeText)
            XCTAssertEqual(look.isEnabled, action.isEnabled)
        }
        let stateOnly = WebKitExtensionActions.look(of: action)
        XCTAssertNil(stateOnly.icon)
        XCTAssertEqual(stateOnly.label, action.label)
        XCTAssertEqual(stateOnly.badgeText, "")
        XCTAssertTrue(stateOnly.isEnabled)
        // Badges and tab-specific changes set by scripts need a loaded extension.
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor
    func testCommandsKeepWebKitsOrderTitlesAndContextLocalIdentities() async throws {
        let package = try await fixture(action: false)
        let first = CommandContext(for: package)
        let second = CommandContext(for: package)
        first.uniqueIdentifier = "fixture"
        second.uniqueIdentifier = "fixture"
        let commands = WebKitExtensionCommands.commands(in: first)
        XCTAssertEqual(commands.map(\.id), first.commands.map(\.id))
        XCTAssertEqual(commands.map(\.title), first.commands.map(\.title))
        XCTAssertEqual(Set(commands.map(\.id)), ["zebra", "alpha"])
        XCTAssertEqual(commands.map(\.identity), WebKitExtensionCommands.commands(in: first).map(\.identity))
        let otherCommands = WebKitExtensionCommands.commands(in: second)
        for value in commands {
            let other = try XCTUnwrap(otherCommands.first { $0.id == value.id })
            XCTAssertNotEqual(value.identity, other.identity)
            WebKitExtensionCommands.perform(value.identity, in: first)
            WebKitExtensionCommands.perform(other.identity, in: second)
            XCTAssertTrue(first.performed.last === first.commands.first { $0.id == value.id })
            XCTAssertTrue(second.performed.last === second.commands.first { $0.id == value.id })
            XCTAssertTrue(first.performed.last?.webExtensionContext === first)
            XCTAssertTrue(second.performed.last?.webExtensionContext === second)
            XCTAssertFalse(first.performed.last === second.performed.last)
            WebKitExtensionCommands.perform(value.identity, in: second)
            WebKitExtensionCommands.perform(other.identity, in: first)
        }
        let owner = try XCTUnwrap(commands.first).identity.context
        WebKitExtensionCommands.perform(.init(context: owner, command: "missing"), in: first)
        XCTAssertEqual(first.performed.count, commands.count)
        XCTAssertEqual(second.performed.count, commands.count)
        XCTAssertFalse(first.isLoaded)
        XCTAssertFalse(second.isLoaded)
        // The override observes dispatch. A worker receiving it needs a load.
    }

    @MainActor
    func testCommandValuesDoNotKeepTheirContextAliveOrMatchItsReplacement() async throws {
        let package = try await fixture(action: false)
        var context: WKWebExtensionContext? = WKWebExtensionContext(for: package)
        context?.uniqueIdentifier = "fixture"
        weak var weakContext: WKWebExtensionContext?
        weakContext = context
        let values = WebKitExtensionCommands.commands(in: try XCTUnwrap(context))
        context = nil
        XCTAssertNil(weakContext)
        let replacement = CommandContext(for: package)
        replacement.uniqueIdentifier = "fixture"
        let newValues = WebKitExtensionCommands.commands(in: replacement)
        for value in values {
            XCTAssertNotEqual(value.identity, newValues.first { $0.id == value.id }?.identity)
            WebKitExtensionCommands.perform(value.identity, in: replacement)
        }
        XCTAssertTrue(replacement.performed.isEmpty)
        XCTAssertFalse(replacement.isLoaded)
    }

    @MainActor
    func testApplyingKeysThroughThePluginKeepsTheMenuValuesAndContextSeparate() async throws {
        let package = try await fixture(action: false)
        let first = WKWebExtensionContext(for: package)
        let second = WKWebExtensionContext(for: package)
        first.uniqueIdentifier = "fixture"
        second.uniqueIdentifier = "fixture"
        let before = WebKitExtensionCommands.commands(in: first)
        let untouched = second.commands.map { ($0.activationKey, $0.modifierFlags) }
        let chosen = ExtensionKey(key: "k", modifiers: [.command, .shift])
        var events: [String] = []
        WebKitExtensionKeys.apply(to: first, given: { name in
            events.append("get " + name)
            return name == "fixture/alpha" ? chosen : nil
        }, suggest: { name, _ in events.append("suggest " + name) })
        XCTAssertEqual(events, first.commands.flatMap { ["suggest fixture/\($0.id)", "get fixture/\($0.id)"] })
        XCTAssertEqual(WebKitExtensionCommands.commands(in: first).map(\.id), before.map(\.id))
        XCTAssertEqual(WebKitExtensionCommands.commands(in: first).map(\.title), before.map(\.title))
        XCTAssertEqual(WebKitExtensionCommands.commands(in: first).map(\.identity), before.map(\.identity))
        let alpha = try XCTUnwrap(first.commands.first { $0.id == "alpha" })
        let zebra = try XCTUnwrap(first.commands.first { $0.id == "zebra" })
        XCTAssertEqual(alpha.activationKey, "k")
        XCTAssertEqual(alpha.modifierFlags, [.command, .shift])
        XCTAssertNil(zebra.activationKey)
        XCTAssertEqual(zebra.modifierFlags, [])
        for (command, original) in zip(second.commands, untouched) {
            XCTAssertEqual(command.activationKey, original.0)
            XCTAssertEqual(command.modifierFlags, original.1)
        }
        WebKitExtensionKeys.apply(to: first, given: { _ in nil }, suggest: { _, _ in })
        XCTAssertTrue(first.commands.allSatisfy { $0.activationKey == nil && $0.modifierFlags.isEmpty })
        XCTAssertFalse(first.isLoaded)
        XCTAssertFalse(second.isLoaded)
    }
}
#endif
