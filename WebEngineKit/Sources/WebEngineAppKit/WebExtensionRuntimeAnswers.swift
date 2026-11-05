import Foundation

/// The runtime answers' lifetime, composed by the last hub slice. The shim
/// and its WebKit delegate dispatch are private to the selected plugin.
@MainActor public protocol WebExtensionRuntimeAnswers: AnyObject {
    func releaseKeepAwake(_ key: String)
}
