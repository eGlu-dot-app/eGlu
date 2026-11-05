#if os(macOS)
import Foundation
import WebEngineAppKit
import XCTest
@testable import WebKitExtensions

private final class NativeMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Any]] = []
    private var ends = 0
    private var mainQueue = false
    func message(_ value: Any) {
        lock.lock()
        defer { lock.unlock() }
        if let value = value as? [String: Any] { values.append(value) }
        mainQueue = mainQueue || Thread.isMainThread
    }
    func end() { lock.lock(); ends += 1; lock.unlock() }
    var snapshot: (messages: [[String: Any]], ends: Int, mainQueue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (values, ends, mainQueue)
    }
}

final class ExtensionNativeConnectionTests: XCTestCase {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let program = folder.appendingPathComponent("native-fixture")
        // This test's own executable only. No native-host lookup is made.
        try #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        use JSON::PP;
        binmode STDIN;
        binmode STDOUT;
        $| = 1;
        my $json = JSON::PP->new->utf8;
        sub exact {
            my ($length) = @_;
            my $body = '';
            while (length($body) < $length) {
                my $n = sysread(STDIN, my $part, $length - length($body));
                exit 0 unless $n;
                $body .= $part;
            }
            return $body;
        }
        sub send_frame {
            my ($value) = @_;
            my $body = $json->encode($value);
            my $header = pack('V', length($body));
            syswrite(STDOUT, substr($header, 0, 2));
            syswrite(STDOUT, substr($header, 2));
            syswrite(STDOUT, $body);
        }
        send_frame({origin => $ARGV[0], pid => $$});
        while (1) {
            my $length = unpack('V', exact(4));
            my $value = $json->decode(exact($length));
            send_frame({seen => $value});
            exit 0 if $value->{exit};
        }
        """#.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        return program
    }

    func testNeutralConnectionFramesOriginAndLastReplyBeforeExit() async throws {
        let program = try fixture()
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let connection: any WebNativeConnection = WebKitExtensionNativeConnection().nativeConnection(program: program, origin: "chrome-extension://fixture/")
        defer { connection.stop() }
        let messages = NativeMessages()
        let started = expectation(description: "startup frame")
        let replies = expectation(description: "two framed replies")
        replies.expectedFulfillmentCount = 2
        let ended = expectation(description: "process ended after final frame")
        connection.onMessage = { value in
            messages.message(value)
            if (value as? [String: Any])?["origin"] != nil { started.fulfill() } else { replies.fulfill() }
        }
        connection.onEnd = { messages.end(); ended.fulfill() }
        XCTAssertTrue(messages.snapshot.messages.isEmpty)
        try connection.start()
        await fulfillment(of: [started], timeout: 5)
        try connection.send(["word": "한글", "number": 42])
        try connection.send(["exit": true])
        await fulfillment(of: [replies, ended], timeout: 5, enforceOrder: true)
        let result = messages.snapshot
        XCTAssertEqual(result.messages.count, 3)
        XCTAssertEqual(result.messages.first?["origin"] as? String, "chrome-extension://fixture/")
        XCTAssertGreaterThan(result.messages.first?["pid"] as? Int ?? 0, 0)
        XCTAssertEqual((result.messages.dropFirst().first?["seen"] as? [String: Any])?["word"] as? String, "한글")
        XCTAssertEqual((result.messages.last?["seen"] as? [String: Any])?["exit"] as? Bool, true)
        XCTAssertFalse(result.mainQueue)
        XCTAssertEqual(result.ends, 1)
        connection.stop()
        connection.stop()
        XCTAssertEqual(messages.snapshot.ends, 1)
    }

    func testStopEndsFixtureAndDoesNotKeepTheConnectionAlive() async throws {
        let program = try fixture()
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        var connection: (any WebNativeConnection)? = WebKitExtensionNativeConnection().nativeConnection(program: program, origin: "fixture-origin")
        weak var pipe: HostPipe?
        pipe = connection as? HostPipe
        let started = expectation(description: "fixture started")
        let ended = expectation(description: "fixture stopped")
        let messages = NativeMessages()
        connection?.onMessage = { value in messages.message(value); started.fulfill() }
        connection?.onEnd = { messages.end(); ended.fulfill() }
        try connection?.start()
        await fulfillment(of: [started], timeout: 5)
        let pid = try XCTUnwrap(messages.snapshot.messages.first?["pid"] as? Int32)
        connection?.stop()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(messages.snapshot.ends, 1)
        // Process termination precedes onEnd after an explicit stop.
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        connection = nil
        // HostPipe's existing kill-grace closure retains it for two seconds.
        let deadline = Date().addingTimeInterval(4)
        while pipe != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(pipe)
    }

    func testCallbacksAreDirectAliasesAndAnUnstartedPipeIsReleased() {
        var connection: (any WebNativeConnection)? = WebKitExtensionNativeConnection().nativeConnection(
            program: URL(fileURLWithPath: "/unused-fixture"), origin: "fixture")
        weak var pipe: HostPipe?
        pipe = connection as? HostPipe
        var values = 0
        var ends = 0
        connection?.onMessage = { _ in values += 1 }
        connection?.onEnd = { ends += 1 }
        pipe?.onMessage?("fixture")
        pipe?.onExit?()
        XCTAssertEqual(values, 1)
        XCTAssertEqual(ends, 1)
        connection?.onMessage = nil
        connection?.onEnd = nil
        XCTAssertNil(pipe?.onMessage)
        XCTAssertNil(pipe?.onExit)
        connection = nil
        XCTAssertNil(pipe)
    }
}
#endif
