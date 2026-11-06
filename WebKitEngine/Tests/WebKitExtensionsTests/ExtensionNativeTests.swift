#if os(macOS)
import Foundation
import XCTest
@testable import WebKitExtensions

final class ExtensionNativeTests: XCTestCase {
    @MainActor
    func testSearchOrderAndManifestOrigins() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folders = ExtensionNative.folders(home: home)
        let support = home.appendingPathComponent("Library/Application Support")
        XCTAssertEqual(folders.map(\.path), [
            support.appendingPathComponent("Safience/NativeMessagingHosts").path,
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts").path,
            support.appendingPathComponent("Chromium/NativeMessagingHosts").path,
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts").path,
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts").path,
            support.appendingPathComponent("Arc/User Data/NativeMessagingHosts").path,
            "/Library/Google/Chrome/NativeMessagingHosts",
            "/Library/Application Support/Chromium/NativeMessagingHosts",
            "/Library/Microsoft/Edge/NativeMessagingHosts",
            support.appendingPathComponent("Vivaldi/NativeMessagingHosts").path,
            support.appendingPathComponent("com.operasoftware.Opera/NativeMessagingHosts").path
        ])
        // Every lookup below is confined to our own folders and executables.
        let first = home.appendingPathComponent("first")
        let second = home.appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let program = folder.appendingPathComponent("fixture")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        }
        func manifest(_ folder: URL, origins: [String], path: String = "fixture") throws {
            let data = try JSONSerialization.data(withJSONObject: ["path": path, "allowed_origins": origins])
            try data.write(to: folder.appendingPathComponent("test.host.json"))
        }
        let origin = "chrome-extension://test/"
        try manifest(first, origins: [origin])
        try manifest(second, origins: [origin], path: second.appendingPathComponent("fixture").path)
        XCTAssertEqual(try ExtensionNative.host("test.host", for: "test", folders: [first, second]), first.appendingPathComponent("fixture"))
        try manifest(first, origins: ["chrome-extension://test", "chrome-extension://TEST/", "https://test/", "*"])
        XCTAssertThrowsError(try ExtensionNative.host("test.host", for: "test", folders: [first, second])) {
            XCTAssertEqual($0.localizedDescription, "Access to the specified native messaging host is forbidden.")
        }
        try manifest(first, origins: [origin], path: "missing")
        XCTAssertThrowsError(try ExtensionNative.host("test.host", for: "test", folders: [first, second])) {
            XCTAssertEqual($0.localizedDescription, "Specified native messaging host not found.")
        }
        try Data("{}".utf8).write(to: first.appendingPathComponent("test.host.json"))
        XCTAssertEqual(try ExtensionNative.host("test.host", for: "test", folders: [first, second]), second.appendingPathComponent("fixture"))
        for name in ["../test", "Test", "a..b", "", "a/b"] {
            XCTAssertThrowsError(try ExtensionNative.host(name, for: "test", folders: [first, second])) {
                XCTAssertEqual($0.localizedDescription, "Invalid native messaging host name")
            }
        }
        XCTAssertThrowsError(try ExtensionNative.host("absent", for: "test", folders: [first, second]))
    }

    func testOutgoingFramesUseLittleEndianByteLengthAndJSONFragments() throws {
        for message: Any in [["word": "한글"], [1, true], "text", 42, NSNull()] {
            let frame = try HostPipe.frame(message)
            let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            XCTAssertEqual(Int(length), frame.count - 4)
            let body = frame.dropFirst(4)
            let decoded = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: decoded, options: [.fragmentsAllowed, .sortedKeys]),
                           try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed, .sortedKeys]))
        }
        XCTAssertThrowsError(try HostPipe.frame(String(repeating: "x", count: HostPipe.frameCap)))
    }

    func testIncomingFramesHandlePartialAndMultipleMessagesAndSkipBadJSON() throws {
        // This pipe never starts a process. Feed the same parser used by stdout.
        let pipe = HostPipe(program: URL(fileURLWithPath: "/unused-fixture"), origin: "chrome-extension://test/")
        defer { pipe.stop() }
        var received: [String] = []
        pipe.onMessage = { received.append(String(describing: $0)) }
        let first = try HostPipe.frame("one")
        pipe.take(first.prefix(2))
        XCTAssertTrue(received.isEmpty)
        pipe.take(first.subdata(in: 2..<5))
        XCTAssertTrue(received.isEmpty)
        var rest = first.subdata(in: 5..<first.count)
        rest.append(contentsOf: [1, 0, 0, 0, 0xff])
        rest.append(try HostPipe.frame("two"))
        pipe.take(rest)
        XCTAssertEqual(received, ["one", "two"])
    }

    func testOverlongInputDeliversEarlierFramesThenEndsOnlyOnce() throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/unused-fixture"), origin: "chrome-extension://test/")
        defer { pipe.stop() }
        var received = 0
        var exits = 0
        pipe.onMessage = { _ in received += 1 }
        pipe.onExit = { exits += 1 }
        var frame = try HostPipe.frame("before")
        var length = UInt32(HostPipe.frameCap + 1).littleEndian
        frame.append(Data(bytes: &length, count: 4))
        pipe.take(frame)
        pipe.take(try HostPipe.frame("after"))
        pipe.stop()
        XCTAssertEqual(received, 1)
        XCTAssertEqual(exits, 1)
    }
}
#endif
