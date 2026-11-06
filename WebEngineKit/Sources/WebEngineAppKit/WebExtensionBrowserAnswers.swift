import Foundation

/// Browser answers' state and queries, composed by the last hub slice.
/// Shim dispatch and its WebKit context stay private to the plugin.
@MainActor public protocol WebExtensionBrowserAnswers: AnyObject {
    var popupPaths: [String: String] { get set }
    func tab(at place: Any?, in space: UUID) -> UUID?
    func favIconURL(for url: URL?) -> String?
}
