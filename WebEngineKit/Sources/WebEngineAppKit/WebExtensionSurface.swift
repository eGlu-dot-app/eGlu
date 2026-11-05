import AppKit

/// An extension's popup or side panel page. The app owns its presentation,
/// timers and focus restoration; the runtime owns its view and delegates.
@MainActor public protocol WebExtensionSurface: WebEngineSurface {
    var extensionID: String { get }
    var space: UUID { get }
    var url: URL? { get }
    var hasFocus: Bool { get }
    var onClose: (() -> Void)? { get set }
    func measure() async -> (size: NSSize, named: Bool)?
    func close()
}

/// A runtime page and the values its pane shows. Made together after the
/// previous pane closes, without exposing the runtime's configuration.
public struct ExtensionPanePage {
    public let surface: any WebExtensionSurface
    public let name: String
    public let icon: NSImage?

    public init(surface: any WebExtensionSurface, name: String, icon: NSImage?) {
        self.surface = surface
        self.name = name
        self.icon = icon
    }
}

public enum ExtensionPageMedia: Sendable { case camera, microphone, cameraAndMicrophone }

/// The app's permission question and recording service for auxiliary pages.
/// Views are the engine's own, also when lent to the recording indicator.
/// Calls stay inline; a permission question may reply asynchronously.
@MainActor public protocol ExtensionAuxiliaryPageHost: AnyObject {
    func releaseExtensionPage(_ view: NSView)
    func extensionDisplayDecision(for view: NSView) -> Int
    func watchExtensionPage(_ view: NSView, id: String)
    func requestExtensionMedia(_ media: ExtensionPageMedia, name: String,
                               reply: @escaping @MainActor (Bool) -> Void)
}
