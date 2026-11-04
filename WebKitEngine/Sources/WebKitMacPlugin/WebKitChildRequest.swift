import WebEngineCore
import WebKit

/// The configuration is the one WebKit handed over, which the child must
/// be made with, in the same call, to keep its tie to the page that opened it.
@MainActor
public final class WebKitChildRequest: WebChildRequest {
    public let configuration: WKWebViewConfiguration
    public let navigation: WebNavigation
    public let features: WebWindowFeatures

    public init(configuration: WKWebViewConfiguration, action: WKNavigationAction, features: WKWindowFeatures) {
        self.configuration = configuration
        navigation = WebKitNavigationAdapter.translate(action)
        self.features = WebWindowFeatures(width: features.width?.doubleValue, height: features.height?.doubleValue)
    }
}
