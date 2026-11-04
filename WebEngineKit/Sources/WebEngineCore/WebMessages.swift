import CoreFoundation
import Foundation

/// A value a page script and the app hand each other (egluBridge).
public indirect enum WebJSON: Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([WebJSON]), object([String: WebJSON])
}

extension WebJSON {
    /// Foundation's script values; unsupported values become null.
    public init(foundation value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { WebJSON(foundation: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { WebJSON(foundation: $0) })
        default:
            self = .null
        }
    }

    /// Foundation's form, read by the app's existing message parsers.
    public var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): NSNumber(value: value)
        case .number(let value): NSNumber(value: value)
        case .string(let value): value
        case .array(let values): values.map(\.foundation)
        case .object(let values): values.mapValues(\.foundation)
        }
    }
}

public enum WebWorld: Sendable, Equatable { case app, page }

/// Where a message came from, recorded by the engine, never by its body.
public struct WebMessage: Sendable {
    public let channel: String
    public let world: WebWorld
    public let isMainFrame: Bool
    public let origin: WebOrigin
    public let body: WebJSON

    public init(channel: String, world: WebWorld, isMainFrame: Bool, origin: WebOrigin, body: WebJSON) {
        self.channel = channel
        self.world = world
        self.isMainFrame = isMainFrame
        self.origin = origin
        self.body = body
    }
}

/// Called synchronously from the engine's callback.
public typealias WebMessageHandler = @MainActor (WebMessage) -> Void
/// Reply once, now or later; nil resolves the script's promise with undefined.
public typealias WebMessageReplyHandler =
    @MainActor (WebMessage, _ reply: @escaping @MainActor (WebJSON?) -> Void) -> Void

@MainActor
public protocol WebMessageChannels: AnyObject {
    /// Prefix each script that uses egluBridge, in that script's world.
    var bridgeScript: String { get }
    func open(_ channel: String, in world: WebWorld, handler: @escaping WebMessageHandler)
    func open(_ channel: String, in world: WebWorld, replying handler: @escaping WebMessageReplyHandler)
}
