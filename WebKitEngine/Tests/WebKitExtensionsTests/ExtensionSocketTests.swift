#if os(macOS)
import XCTest
@testable import WebKitExtensions

final class ExtensionSocketTests: XCTestCase {
    @MainActor
    func testRequestPreservesAddressOriginAgentAndProtocols() throws {
        let request = try XCTUnwrap(ExtensionSocket.request("wss://socket.example/path?q=1", protocols: ["one", "two"],
                                                          userAgent: "Fixture Agent", origin: "chrome-extension://test", policy: nil))
        XCTAssertEqual(request.url?.absoluteString, "wss://socket.example/path?q=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "chrome-extension://test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Fixture Agent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "one, two")
        let bare = try XCTUnwrap(ExtensionSocket.request("ws://localhost:1234/", protocols: [], userAgent: nil,
                                                       origin: "chrome-extension://test", policy: nil))
        XCTAssertNil(bare.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNil(bare.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"))
        XCTAssertEqual(ExtensionSocket.name(shimApplication: "eglu"), "eglu.socket")
    }

    @MainActor
    func testRefusesSchemesProtectedHostsAndConnectPolicyBeforeMakingATask() {
        for address in ["https://socket.example/", "file:///tmp/test", "wss://accounts.google.com/", "ws://sub.accounts.google.com/"] {
            XCTAssertNil(ExtensionSocket.request(address, protocols: [], userAgent: nil, origin: "chrome-extension://test", policy: nil), address)
        }
        XCTAssertNil(ExtensionSocket.request("wss://other.example/", protocols: [], userAgent: nil, origin: "chrome-extension://test",
                                            policy: "connect-src wss://socket.example"))
        XCTAssertNotNil(ExtensionSocket.request("wss://socket.example/", protocols: [], userAgent: nil, origin: "chrome-extension://test",
                                               policy: "connect-src wss://socket.example"))
        XCTAssertNil(ExtensionSocket.request("wss://socket.example/", protocols: [], userAgent: nil, origin: "chrome-extension://test",
                                            policy: "connect-src 'none'"))
        // Redirects retain the original broader scheme check.
        XCTAssertTrue(ExtensionSocket.allowed(URL(string: "https://socket.example/"), policy: nil))
        XCTAssertFalse(ExtensionSocket.allowed(URL(string: "https://accounts.google.com/"), policy: nil))
        XCTAssertFalse(ExtensionSocket.allowed(URL(string: "file:///tmp/test"), policy: nil))
        XCTAssertFalse(ExtensionSocket.allowed(nil, policy: nil))
    }
}
#endif
