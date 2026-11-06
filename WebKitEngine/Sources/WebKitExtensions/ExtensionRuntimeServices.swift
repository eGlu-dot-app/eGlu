#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import WebEngineAppKit
import WebKit

/// Test seams never create an assertion, page, socket or native process.
@MainActor
protocol ExtensionRuntimeServices: AnyObject {
    func session() -> [String: Any]?
    func quiet() -> Double
    func createAssertion(_ kind: CFString, why: CFString) -> IOPMAssertionID?
    func release(_ assertion: IOPMAssertionID)
    func activity()
    func loadBackground(_ context: WKWebExtensionContext, completion: @escaping (Error?) -> Void)
    func after(_ seconds: TimeInterval, perform: @escaping () -> Void)
    func pause() async throws
    func createOffscreen(_ path: String, reasons: Set<String>, for context: WKWebExtensionContext, in space: UUID,
                         scheme: String, host: any ExtensionAuxiliaryPageHost) async throws
    func closeOffscreen(_ id: String, in space: UUID)
    func hasOffscreen(_ id: String, in space: UUID) -> Bool
}

@MainActor
final class RuntimeServices: ExtensionRuntimeServices {
    func session() -> [String: Any]? { CGSessionCopyCurrentDictionary() as? [String: Any] }
    func quiet() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    func createAssertion(_ kind: CFString, why: CFString) -> IOPMAssertionID? {
        var assertion: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn), why, &assertion) == kIOReturnSuccess {
            return assertion
        }
        return nil
    }
    func release(_ assertion: IOPMAssertionID) { IOPMAssertionRelease(assertion) }
    func activity() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("An extension in eGlu" as CFString, kIOPMUserActiveLocal, &assertion)
    }
    func loadBackground(_ context: WKWebExtensionContext, completion: @escaping (Error?) -> Void) {
        context.loadBackgroundContent(completionHandler: completion)
    }
    func after(_ seconds: TimeInterval, perform: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { perform() }
    }
    func pause() async throws { try await Task.sleep(for: .milliseconds(400)) }
    func createOffscreen(_ path: String, reasons: Set<String>, for context: WKWebExtensionContext, in space: UUID,
                         scheme: String, host: any ExtensionAuxiliaryPageHost) async throws {
        try await ExtensionOffscreen.create(path, reasons: reasons, for: context, in: space, scheme: scheme, host: host)
    }
    func closeOffscreen(_ id: String, in space: UUID) { ExtensionOffscreen.close(id, in: space) }
    func hasOffscreen(_ id: String, in space: UUID) -> Bool { ExtensionOffscreen.hasDocument(id, in: space) }
}

@MainActor
protocol ExtensionRuntimePort: AnyObject {
    var applicationIdentifier: String? { get }
}

@MainActor
final class RuntimeMessagePort: ExtensionRuntimePort {
    let port: WKWebExtension.MessagePort
    init(_ port: WKWebExtension.MessagePort) { self.port = port }
    var applicationIdentifier: String? { port.applicationIdentifier }
}

@MainActor
protocol ExtensionRuntimeTransports: AnyObject {
    func send(_ message: Any, to name: String, from id: String) async throws -> Any?
    func connectNative(_ port: any ExtensionRuntimePort, from id: String) throws
    func connectSocket(_ port: any ExtensionRuntimePort, from id: String, in space: UUID, policy: String?, scheme: String)
}

@MainActor
final class RuntimeTransports: ExtensionRuntimeTransports {
    func send(_ message: Any, to name: String, from id: String) async throws -> Any? {
        try await ExtensionNative.send(message, to: name, from: id)
    }
    func connectNative(_ port: any ExtensionRuntimePort, from id: String) throws {
        try ExtensionNative.connect((port as! RuntimeMessagePort).port, from: id)
    }
    func connectSocket(_ port: any ExtensionRuntimePort, from id: String, in space: UUID, policy: String?, scheme: String) {
        ExtensionSocket.connect((port as! RuntimeMessagePort).port, from: id, in: space, policy: policy, scheme: scheme)
    }
}
#endif
