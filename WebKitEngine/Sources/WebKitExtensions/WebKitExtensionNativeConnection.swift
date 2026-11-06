#if os(macOS)
import Foundation
import WebEngineAppKit

/// The connection is the existing pipe itself, with the same ownership,
/// callbacks, framing and queues as native extension messaging.
extension HostPipe: WebNativeConnection {
    public var onEnd: (() -> Void)? {
        get { onExit }
        set { onExit = newValue }
    }

    public func send(_ message: Any) throws { try write(message) }
}

public final class WebKitExtensionNativeConnection: WebExtensionNativeTransport {
    public init() {}

    public func nativeConnection(program: URL, origin: String) -> any WebNativeConnection {
        HostPipe(program: program, origin: origin)
    }
}
#endif
