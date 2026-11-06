#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import XCTest
@testable import WebKitExtensions

@MainActor
private final class MetadataHost: ExtensionMetadataHost {
    var installations: [String: WebExtensionMetadataInstallation] = [:]
    var asked: [String] = []

    func extensionMetadataInstallation(_ id: String) -> WebExtensionMetadataInstallation? {
        asked.append(id)
        return installations[id]
    }
}

final class ExtensionMetadataTests: XCTestCase {
    private struct Fixture {
        let package: WKWebExtension
        let file: URL
        let archive: Data
        let manifest: ExtensionManifest
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    @MainActor
    private func png(_ size: Int, blue: Bool = false) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: size * 4, bitsPerPixel: 32))
        let color = NSColor(deviceRed: blue ? 0 : 1, green: CGFloat(size) / 256, blue: blue ? 1 : 0, alpha: 1)
        for x in 0..<size {
            for y in 0..<size { bitmap.setColor(color, atX: x, y: y) }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func fixture(sizes: [Int] = [32, 64, 96], blue: Bool = false,
                         extra: [String: Any] = [:], files given: [String: Data] = [:]) async throws -> Fixture {
        let folder = try folder()
        var object: [String: Any] = ["manifest_version": 3, "name": "Metadata fixture", "version": "1"]
        var files = given
        if !sizes.isEmpty {
            object["icons"] = Dictionary(uniqueKeysWithValues: sizes.map { (String($0), "\($0).png") })
            for size in sizes { files["\(size).png"] = try png(size, blue: blue) }
        }
        object.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: object)
        files["manifest.json"] = data
        for (name, data) in files {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let archive = Self.zip(files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        let file = folder.appendingPathComponent("1.zip")
        try archive.write(to: file)
        // Parsed only. No controller, data store, web view or worker is made.
        let package = try await WKWebExtension(resourceBaseURL: folder)
        return Fixture(package: package, file: file, archive: archive, manifest: try ExtensionManifest(json: data))
    }

    @MainActor
    func testRetainedNamesResolveLocalizationAndKeepMissingPackagesAndMessages() async throws {
        let fixture = try await fixture(extra: ["name": "__MSG_title__", "default_locale": "en"], files: [
            "_locales/en/messages.json": Data(#"{"title":{"message":"Localized fixture"}}"#.utf8)
        ])
        let metadata = WebKitExtensionMetadata(host: MetadataHost(), contexts: { [:] }, package: { _, _ in fixture.file })
        let result = await Task.detached { metadata.packageName(at: fixture.file, fallback: "saved") }.value
        XCTAssertEqual(result.name, "Localized fixture")
        XCTAssertEqual(result.facts, .init(offersCookies: false, nativeRequired: false, nativeOptional: false))
        XCTAssertEqual(WebKitExtensionMetadata.name(in: fixture.archive, manifest: fixture.manifest, fallback: "saved"), result.name)
        let original = try Data(contentsOf: fixture.file)
        XCTAssertEqual(original, fixture.archive)
        let missing = metadata.packageName(at: fixture.file.appendingPathExtension("missing"), fallback: "saved")
        XCTAssertEqual(missing, .init(name: "saved", facts: nil))
        for name in ["", "__MSG_missing__"] {
            let file = try folder().appendingPathComponent("1.zip")
            let data = try JSONSerialization.data(withJSONObject: ["name": name, "version": "1"])
            try Self.zip([("manifest.json", data)]).write(to: file)
            XCTAssertEqual(metadata.packageName(at: file, fallback: "saved").name, "saved")
        }
        let absentName = try folder().appendingPathComponent("1.zip")
        try Self.zip([("manifest.json", Data(#"{"version":"1"}"#.utf8))]).write(to: absentName)
        XCTAssertEqual(metadata.packageName(at: absentName, fallback: "saved").name, "saved")
        for data in [Data("broken".utf8), Self.zip([("manifest.json", Data("{}".utf8))]), Self.zip([])] {
            try data.write(to: fixture.file)
            XCTAssertEqual(metadata.packageName(at: fixture.file, fallback: "saved"), .init(name: "saved", facts: nil))
        }
    }

    @MainActor
    func testFirstSuccessfulIconSizeIsSharedAcrossSpacesAndGlobalLookup() async throws {
        let fixture = try await fixture()
        let host = MetadataHost()
        host.installations["fixture"] = .init(id: "fixture", version: "1")
        let space = UUID(), other = UUID()
        let context = WKWebExtensionContext(for: fixture.package)
        var reads = 0
        var paths = 0
        var contexts = [space: ["fixture": context]]
        let metadata = WebKitExtensionMetadata(host: host, contexts: { reads += 1; return contexts }, package: { _, _ in paths += 1; return fixture.file })
        let small = try XCTUnwrap(metadata.icon(of: "fixture", in: space))
        XCTAssertEqual(small.tiffRepresentation, fixture.package.icon(for: CGSize(width: 32, height: 32))?.tiffRepresentation)
        contexts = [:]
        XCTAssertTrue(metadata.icon(of: "fixture") === small)
        XCTAssertTrue(metadata.icon(of: "fixture", in: other) === small)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(paths, 0)
        XCTAssertTrue(host.asked.isEmpty)
        metadata.forgetIcon("fixture")
        contexts = [space: ["fixture": context]]
        let large = try XCTUnwrap(metadata.icon(of: "fixture"))
        XCTAssertEqual(large.tiffRepresentation, fixture.package.icon(for: CGSize(width: 64, height: 64))?.tiffRepresentation)
        XCTAssertTrue(metadata.icon(of: "fixture", in: space) === large)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(paths, 0)
        XCTAssertEqual(host.asked, ["fixture"])
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor
    func testGlobalIconUsesFirstSuccessfulContextAndArchiveFallback() async throws {
        let pictured = try await fixture()
        let empty = try await fixture(sizes: [])
        let host = MetadataHost()
        host.installations["fixture"] = .init(id: "fixture", version: "1")
        let space = UUID(), other = UUID()
        let blank = WKWebExtensionContext(for: empty.package)
        let loaded = WKWebExtensionContext(for: pictured.package)
        var paths = 0
        var contexts = [space: ["fixture": blank], other: ["fixture": loaded]]
        let metadata = WebKitExtensionMetadata(host: host, contexts: { contexts }, package: { _, _ in paths += 1; return pictured.file })
        // Make the first entry fail, whatever order this dictionary has.
        let first = contexts.keys.first!
        contexts[first] = ["fixture": blank]
        contexts[first == space ? other : space] = ["fixture": loaded]
        let expected = contexts.values.lazy.compactMap { $0["fixture"]?.webExtension.icon(for: CGSize(width: 64, height: 64)) }.first
        XCTAssertEqual(metadata.icon(of: "fixture")?.tiffRepresentation, expected?.tiffRepresentation)
        XCTAssertEqual(paths, 0)
        metadata.forgetIcon("fixture")
        contexts = [space: ["fixture": blank]]
        let fallback = try XCTUnwrap(metadata.icon(of: "fixture"))
        let archiveIcon = try XCTUnwrap(WebKitExtensionMetadata.icon(in: pictured.archive, manifest: pictured.manifest))
        XCTAssertEqual(fallback.tiffRepresentation, archiveIcon.tiffRepresentation)
        XCTAssertEqual(paths, 1)
        metadata.forgetIcon("fixture")
        contexts = [:]
        XCTAssertEqual(metadata.icon(of: "fixture")?.tiffRepresentation, archiveIcon.tiffRepresentation)
        XCTAssertEqual(paths, 2)
        XCTAssertFalse(blank.isLoaded)
        XCTAssertFalse(loaded.isLoaded)
    }

    @MainActor
    func testArchiveIconsUseTheLargestManifestEntryAndActionFallback() async throws {
        let fixture = try await fixture()
        let icon = try XCTUnwrap(WebKitExtensionMetadata.icon(in: fixture.archive, manifest: fixture.manifest))
        let largest = try XCTUnwrap(ZipFile.file(in: fixture.archive, matching: { $0 == "96.png" }))
        XCTAssertEqual(icon.tiffRepresentation, NSImage(data: largest)?.tiffRepresentation)
        let action = try await self.fixture(sizes: [], extra: [
            "action": ["default_icon": ["32": "small.png", "96": "large.png"]]
        ], files: ["small.png": try png(32), "large.png": try png(96, blue: true)])
        let actionIcon = try XCTUnwrap(WebKitExtensionMetadata.icon(in: action.archive, manifest: action.manifest))
        let actionLargest = try XCTUnwrap(ZipFile.file(in: action.archive, matching: { $0 == "large.png" }))
        XCTAssertEqual(actionIcon.tiffRepresentation, NSImage(data: actionLargest)?.tiffRepresentation)
        let missing = try ExtensionManifest(json: Data(#"{"version":"1","icons":{"96":"missing.png"}}"#.utf8))
        XCTAssertNil(WebKitExtensionMetadata.icon(in: fixture.archive, manifest: missing))
        XCTAssertEqual(WebKitExtensionMetadata.name(of: fixture.package), fixture.package.displayName)
        XCTAssertEqual(WebKitExtensionMetadata.icon(of: fixture.package, size: CGSize(width: 96, height: 96))?.tiffRepresentation,
                       fixture.package.icon(for: CGSize(width: 96, height: 96))?.tiffRepresentation)
    }

    @MainActor
    func testMissingIconsAndSameVersionReplacementKeepCacheRules() async throws {
        let old = try await fixture()
        let replacement = try await fixture(blue: true, extra: ["name": "Replacement fixture"])
        let host = MetadataHost()
        host.installations["fixture"] = .init(id: "fixture", version: "1")
        var paths = 0
        let metadata = WebKitExtensionMetadata(host: host, contexts: { [:] }, package: { id, version in
            XCTAssertEqual(id, "fixture"); XCTAssertEqual(version, "1")
            paths += 1
            return old.file
        })
        let original = try XCTUnwrap(metadata.icon(of: "fixture"))
        XCTAssertEqual(metadata.packageName(at: old.file, fallback: "saved").name, "Metadata fixture")
        try replacement.archive.write(to: old.file, options: .atomic)
        XCTAssertEqual(metadata.packageName(at: old.file, fallback: "saved").name, "Replacement fixture")
        XCTAssertTrue(metadata.icon(of: "fixture") === original)
        XCTAssertEqual(paths, 1)
        metadata.forgetIcon("fixture")
        let changed = try XCTUnwrap(metadata.icon(of: "fixture"))
        XCTAssertNotEqual(changed.tiffRepresentation, original.tiffRepresentation)
        XCTAssertEqual(changed.tiffRepresentation, WebKitExtensionMetadata.icon(in: replacement.archive, manifest: replacement.manifest)?.tiffRepresentation)
        XCTAssertEqual(paths, 2)
        metadata.forgetIcon("fixture")
        try Self.zip([("manifest.json", Data(#"{"version":"1"}"#.utf8))]).write(to: old.file)
        XCTAssertNil(metadata.icon(of: "fixture"))
        try replacement.archive.write(to: old.file)
        XCTAssertNil(metadata.icon(of: "fixture"))
        XCTAssertEqual(paths, 3)
        metadata.forgetIcon("fixture")
        XCTAssertNotNil(metadata.icon(of: "fixture"))
        XCTAssertEqual(paths, 4)
    }

    @MainActor
    func testMissingGlobalIconDoesNotPreventAScopedSuccessAndScopedMissDoesNotCache() async throws {
        let fixture = try await fixture()
        let host = MetadataHost()
        let space = UUID()
        let context = WKWebExtensionContext(for: fixture.package)
        var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
        var paths = 0
        let metadata = WebKitExtensionMetadata(host: host, contexts: { contexts }, package: { _, _ in paths += 1; return fixture.file })
        XCTAssertNil(metadata.icon(of: "fixture"))
        XCTAssertNil(metadata.icon(of: "fixture", in: space))
        host.installations["fixture"] = .init(id: "fixture", version: "1")
        try Data("broken".utf8).write(to: fixture.file)
        XCTAssertNil(metadata.icon(of: "fixture"))
        contexts = [space: ["fixture": context]]
        XCTAssertNil(metadata.icon(of: "fixture"))
        let scoped = try XCTUnwrap(metadata.icon(of: "fixture", in: space))
        XCTAssertTrue(metadata.icon(of: "fixture") === scoped)
        XCTAssertEqual(paths, 1)
        XCTAssertFalse(context.isLoaded)
    }

    @MainActor
    func testFactsComeFromOriginalManifestWithRequiredNativeTakingPrecedence() async throws {
        let metadata = WebKitExtensionMetadata(host: MetadataHost(), contexts: { [:] }, package: { _, _ in URL(fileURLWithPath: "/unused") })
        for (permissions, optional, expected) in [
            ([String](), [String](), WebExtensionManifestFacts(offersCookies: false, nativeRequired: false, nativeOptional: false)),
            (["cookies"], ["nativeMessaging"], .init(offersCookies: false, nativeRequired: false, nativeOptional: true)),
            (["nativeMessaging"], ["cookies", "nativeMessaging"], .init(offersCookies: true, nativeRequired: true, nativeOptional: false))
        ] {
            let fixture = try await fixture(sizes: [], extra: ["permissions": permissions, "optional_permissions": optional])
            XCTAssertEqual(metadata.manifestFacts(permissions: fixture.manifest.permissions, optionalPermissions: fixture.manifest.optionalPermissions), expected)
            XCTAssertEqual(metadata.packageName(at: fixture.file, fallback: "saved").facts, expected)
        }
    }

    @MainActor
    func testAddressesReadCurrentUnloadedContextsWithoutCachingOrOpeningPages() async throws {
        let fixture = try await fixture(sizes: [], extra: [
            "options_ui": ["page": "options.html", "open_in_tab": true],
            "chrome_url_overrides": ["newtab": "newtab.html"], "side_panel": ["default_path": "panel.html"]
        ], files: ["options.html": Data(), "newtab.html": Data(), "panel.html": Data()])
        let space = UUID(), other = UUID()
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let context = WKWebExtensionContext(for: fixture.package)
        context.uniqueIdentifier = "fixture"
        context.baseURL = URL(string: "chrome-extension://fixture/")!
        var contexts = [space: ["fixture": context]]
        let metadata = WebKitExtensionMetadata(host: MetadataHost(), contexts: { contexts }, package: { _, _ in fixture.file })
        XCTAssertEqual(metadata.optionsPageURL("fixture", in: space), context.optionsPageURL)
        XCTAssertEqual(metadata.optionsPageURL("fixture", in: space)?.path, "/options.html")
        XCTAssertEqual(WebKitExtensionMetadata.optionsPageURL(for: context), context.optionsPageURL)
        XCTAssertEqual(metadata.newTabPageURL("fixture", in: space), context.overrideNewTabPageURL)
        let newTab = try XCTUnwrap(metadata.newTabPageURL("fixture", in: space))
        XCTAssertEqual(newTab.path, "/newtab.html")
        XCTAssertTrue(metadata.hasNewTabPage("fixture"))
        XCTAssertTrue(metadata.isNewTabPage(newTab, in: space))
        XCTAssertFalse(metadata.isNewTabPage(newTab, in: other))
        XCTAssertEqual(metadata.sidePanelDefaultPath("fixture", in: space), "panel.html")
        XCTAssertNil(metadata.optionsPageURL("missing", in: space))
        XCTAssertNil(metadata.newTabPageURL("fixture", in: other))
        contexts = [:]
        XCTAssertNil(metadata.optionsPageURL("fixture", in: space))
        XCTAssertNil(metadata.newTabPageURL("fixture", in: space))
        XCTAssertFalse(metadata.hasNewTabPage("fixture"))
        XCTAssertFalse(metadata.isNewTabPage(newTab, in: space))
        XCTAssertNil(metadata.sidePanelDefaultPath("fixture", in: space))
        XCTAssertFalse(context.isLoaded)
    }

    // Stored ZIP entries, as in PadCore's archive fixtures. Only our own
    // parser reads this archive; WebKit parses the fixture folder instead.
    private static func zip(_ files: [(String, Data)]) -> Data {
        var out: [UInt8] = [], central: [UInt8] = []
        func u16(_ value: Int, _ to: inout [UInt8]) { to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func u32(_ value: Int, _ to: inout [UInt8]) {
            to += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
        }
        for (name, data) in files {
            let nameBytes = Array(name.utf8), offset = out.count
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out); u32(0, &out)
            u32(data.count, &out); u32(data.count, &out); u16(nameBytes.count, &out); u16(0, &out)
            out += nameBytes; out += data
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(data.count, &central); u32(data.count, &central)
            u16(nameBytes.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central); central += nameBytes
        }
        let start = out.count
        out += central
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(central.count, &out); u32(start, &out); u16(0, &out)
        return Data(out)
    }
}
#endif
