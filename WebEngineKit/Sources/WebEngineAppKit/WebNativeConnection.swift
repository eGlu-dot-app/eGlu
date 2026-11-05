import Foundation

/// A native process using length-prefixed JSON. Callbacks run on the
/// transport's reading and termination queues; the caller chooses any hop.
/// Keeping the connection keeps its transport, with no extra owner or timer.
public protocol WebNativeConnection: AnyObject {
    var onMessage: ((Any) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    func start() throws
    func send(_ message: Any) throws
    func stop()
}

/// The native transport part of the runtime. Creation does not start it.
public protocol WebExtensionNativeTransport: AnyObject {
    func nativeConnection(program: URL, origin: String) -> any WebNativeConnection
}
