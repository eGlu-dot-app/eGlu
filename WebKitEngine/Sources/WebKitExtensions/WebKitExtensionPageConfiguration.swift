#if os(macOS)
import WebEngineAppKit
import WebKit

/// The extension's configuration, passed through the host to its page engine.
@MainActor
public final class WebKitExtensionPageConfiguration: ExtensionPageConfiguration {
    public let configuration: WKWebViewConfiguration
    public init(_ configuration: WKWebViewConfiguration) { self.configuration = configuration }
}
#endif
