import CoreFoundation
import Foundation
import WebEngineCore
import XCTest

final class WebMessagesTests: XCTestCase {
    func testFoundationScalars() {
        XCTAssertEqual(WebJSON(foundation: NSNull()), .null)
        XCTAssertEqual(WebJSON(foundation: kCFBooleanTrue as Any), .bool(true))
        XCTAssertEqual(WebJSON(foundation: kCFBooleanFalse as Any), .bool(false))
        XCTAssertEqual(WebJSON(foundation: NSNumber(value: 17)), .number(17))
        XCTAssertEqual(WebJSON(foundation: NSNumber(value: 2.5)), .number(2.5))
        XCTAssertEqual(WebJSON(foundation: "word"), .string("word"))
        XCTAssertEqual(WebJSON(foundation: NSDate(timeIntervalSince1970: 0)), .null)
        XCTAssertTrue(WebJSON.null.foundation is NSNull)
        XCTAssertEqual(CFGetTypeID(WebJSON.bool(true).foundation as! NSNumber), CFBooleanGetTypeID())
        XCTAssertEqual(CFGetTypeID(WebJSON.bool(false).foundation as! NSNumber), CFBooleanGetTypeID())
        XCTAssertNotEqual(CFGetTypeID(WebJSON.number(1).foundation as! NSNumber), CFBooleanGetTypeID())
    }

    func testNativeSwiftValuesInCollectionsAndNesting() throws {
        let values: [Any] = [Int(17), Double(2.5), true, false, "word", NSNull()]
        let expected: WebJSON = .array([.number(17), .number(2.5), .bool(true), .bool(false), .string("word"), .null])
        XCTAssertEqual(WebJSON(foundation: values), expected)
        let native: [String: Any] = ["int": 17, "double": 2.5, "bool": true, "string": "word",
                                    "array": values, "nested": ["off": false, "missing": NSNull()],
                                    "date": NSDate(timeIntervalSince1970: 0)]
        let json = WebJSON(foundation: native)
        XCTAssertEqual(json, .object(["int": .number(17), "double": .number(2.5), "bool": .bool(true),
                                     "string": .string("word"), "array": expected,
                                     "nested": .object(["off": .bool(false), "missing": .null]), "date": .null]))
        let restored = try XCTUnwrap(json.foundation as? [String: Any])
        XCTAssertEqual(restored["int"] as? Int, 17)
        XCTAssertEqual(restored["double"] as? Double, 2.5)
        XCTAssertEqual(restored["bool"] as? Bool, true)
        XCTAssertEqual(restored["string"] as? String, "word")
        XCTAssertEqual((restored["int"] as? NSNumber)?.intValue, 17)
        let array = try XCTUnwrap(restored["array"] as? [Any])
        XCTAssertEqual(array[0] as? Int, 17)
        XCTAssertEqual(array[1] as? Double, 2.5)
        XCTAssertEqual(array[2] as? Bool, true)
        XCTAssertEqual(array[3] as? Bool, false)
        XCTAssertEqual(array[4] as? String, "word")
        XCTAssertTrue(array[5] is NSNull)
        XCTAssertEqual((restored["nested"] as? [String: Any])?["off"] as? Bool, false)
        XCTAssertTrue(restored["date"] is NSNull)
        XCTAssertEqual(WebJSON(foundation: json.foundation), json)
    }

    func testRoundTripKeepsFoundationHandlerReads() throws {
        // WebKit's incoming numbers are NSNumbers, including CFBooleans.
        let originals: [Any] = [NSNull(), NSNumber(value: true), NSNumber(value: false),
                                NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 17),
                                NSNumber(value: -4), NSNumber(value: 2.5), "word",
                                ["answer": NSNumber(value: 17)] as [String: Any]]
        for original in originals {
            let restored = WebJSON(foundation: original).foundation
            XCTAssertEqual(restored as? Bool, original as? Bool)
            XCTAssertEqual(restored as? Int, original as? Int)
            XCTAssertEqual(restored as? Double, original as? Double)
            XCTAssertEqual((restored as? NSNumber)?.intValue, (original as? NSNumber)?.intValue)
            XCTAssertEqual(restored as? String, original as? String)
            XCTAssertEqual(restored is NSNull, original is NSNull)
            XCTAssertEqual(restored as? NSDictionary, original as? NSDictionary)
        }
        let object: [String: Any] = ["integer": NSNumber(value: 17), "real": NSNumber(value: 2.5),
                                     "flag": NSNumber(value: true), "text": "word"]
        let restored = try XCTUnwrap(WebJSON(foundation: object).foundation as? [String: Any])
        for key in object.keys {
            XCTAssertEqual(restored[key] as? Bool, object[key] as? Bool)
            XCTAssertEqual(restored[key] as? Int, object[key] as? Int)
            XCTAssertEqual(restored[key] as? Double, object[key] as? Double)
            XCTAssertEqual((restored[key] as? NSNumber)?.intValue, (object[key] as? NSNumber)?.intValue)
            XCTAssertEqual(restored[key] as? String, object[key] as? String)
        }
    }

    func testNativeNumberRepresentationBecomesFoundationNumber() {
        // A JSON number has no Swift numeric type identity. WebKit delivers
        // NSNumbers on input and serializes Swift lint answers on output.
        let native: Any = Int(17)
        XCTAssertNil(native as? Double)
        let restored = WebJSON(foundation: native).foundation
        XCTAssertEqual(restored as? Int, 17)
        XCTAssertEqual(restored as? Double, 17)
        XCTAssertEqual((restored as? NSNumber)?.intValue, 17)
    }

    func testMessageKeepsEngineMetadata() {
        let origin = WebOrigin.tuple(scheme: "https", host: "fixture", port: 8443)
        let message = WebMessage(channel: "test", world: .app, isMainFrame: false,
                                 origin: origin, body: .object(["world": .string("page")]))
        XCTAssertEqual(message.channel, "test")
        XCTAssertEqual(message.world, .app)
        XCTAssertFalse(message.isMainFrame)
        XCTAssertEqual(message.origin, origin)
        XCTAssertEqual(message.body, .object(["world": .string("page")]))
    }

    @MainActor
    func testContractCallsAndRepliesSynchronouslyOrLater() {
        let channels = MessageChannels()
        let contract: any WebMessageChannels = channels
        var events: [String] = []
        var later: (@MainActor (WebJSON?) -> Void)?
        contract.open("post", in: .app) { _ in events.append("post") }
        contract.open("request", in: .page, replying: { _, reply in
            events.append("request")
            later = reply
        })
        let message = WebMessage(channel: "post", world: .app, isMainFrame: true, origin: .opaque, body: .null)
        channels.post?(message)
        XCTAssertEqual(events, ["post"])
        channels.request?(message) { answer in
            XCTAssertEqual(answer, .bool(true))
            events.append("reply")
        }
        XCTAssertEqual(events, ["post", "request"])
        later?(.bool(true))
        XCTAssertEqual(events, ["post", "request", "reply"])
        XCTAssertEqual(channels.worlds, [.app, .page])
    }
}

@MainActor
private final class MessageChannels: WebMessageChannels {
    let bridgeScript = "fixture"
    var post: WebMessageHandler?
    var request: WebMessageReplyHandler?
    var worlds: [WebWorld] = []

    func open(_ channel: String, in world: WebWorld, handler: @escaping WebMessageHandler) {
        worlds.append(world)
        post = handler
    }

    func open(_ channel: String, in world: WebWorld, replying handler: @escaping WebMessageReplyHandler) {
        worlds.append(world)
        request = handler
    }
}
