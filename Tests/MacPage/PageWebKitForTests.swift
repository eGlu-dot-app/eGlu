import WebEngineAppKit
import WebEngineCore
import WebKit
import WebKitExtensions
import WebKitMacPlugin
@testable import eGluMac

// Concrete access belongs only to the WebKit-hosted test suite.
extension Page {
    var view: WebKitPageView { (enginePage as! WebKitMacPage).webView }
    static var world: WKContentWorld { WebKitMacPage.appWorld }
}

typealias PageView = WebKitPageView

@MainActor
enum PageWebKitForTests {
    static func page(configuration: WKWebViewConfiguration, extensionPage: Bool = false) -> WebKitMacPage {
        EngineComposition.pageFactory.page(configuration: configuration, extensionPage: extensionPage)
    }

    static func child(configuration: WKWebViewConfiguration) -> WebKitChildRequest {
        WebKitChildRequest(configuration: configuration,
            navigation: WebNavigation(request: URLRequest(url: URL(string: "about:blank")!),
                sourceOrigin: .opaque, targetIsMainFrame: nil, kind: .other, modifiers: [],
                buttonNumber: 0, requestsDownload: false, isServerRedirect: false,
                contentRuleRedirect: nil, sourceIsMainFrame: true),
            features: WebWindowFeatures(width: nil, height: nil))
    }
}
