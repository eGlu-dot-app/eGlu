import AppKit

public enum WebExtensionRuntimeAnswerEvent: Sendable {
    case problem(WebExtensionEvidence.Problem)
    case unreachableApp(String)
}

/// Product consent, supplied-text detection and the Mac's colour picker.
/// Closures defer icon and debug text reads to their original points.
@MainActor public protocol ExtensionRuntimeAnswerHost: ExtensionAuxiliaryPageHost {
    func extensionRuntimeInstallation(_ id: String) -> WebExtensionEvidenceInstallation?
    func updateExtensionRuntimeAnswer(_ id: String, in space: UUID, event: WebExtensionRuntimeAnswerEvent)
    func extensionNativeIsOptional(_ id: String) -> Bool
    func extensionReachesApps(_ id: String) -> Bool
    func setExtensionNativeConsent(_ id: String, _ on: Bool)
    func requestExtensionNative(title: String, in space: UUID, icon: () -> NSImage?) async -> Bool
    func detectExtensionLanguage(_ text: String) -> [String: Any]
    func sampleExtensionColour() async -> NSColor?
    func noteExtensionRuntimeReport(_ api: String?, words: () -> String?)
}
