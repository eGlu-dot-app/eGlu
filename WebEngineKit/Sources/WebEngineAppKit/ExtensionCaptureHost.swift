import AppKit

/// A recording's values; the app chooses the pill's words and ordering.
public struct ExtensionCaptureState: Sendable {
    public let id: String
    public let name: String
    public let screen: Bool
    public let camera: Bool
    public let microphone: Bool

    public init(id: String, name: String, screen: Bool, camera: Bool, microphone: Bool) {
        self.id = id
        self.name = name
        self.screen = screen
        self.camera = camera
        self.microphone = microphone
    }
}

/// Capture's interface work, separate from auxiliary pages because tabs
/// record too. Calls stay inline except for the existing consent wait.
/// The deferred values keep the consent checks in their original order.
@MainActor public protocol ExtensionCaptureHost: AnyObject {
    func setExtensionCaptureStop(_ stop: @escaping (String) -> Void)
    func extensionCaptureAllowed(_ id: String) -> Bool
    func requestExtensionCapture(_ id: String, in space: UUID, used: () -> Bool, name: () -> String) async -> Bool
    func bringExtensionCaptureForward(_ view: NSView)
    func lendExtensionCaptureView(_ view: NSView)
    func giveBackExtensionCaptureView(_ view: NSView)
    func extensionCaptureName(_ id: String) -> String
    func updateExtensionCapture(_ lines: [ExtensionCaptureState])
}
