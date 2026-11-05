#if os(macOS)
import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit
import WebKitMacPlugin
import WebKitSupport

/// The selected engine's page factory, including extension delegate wiring.
@MainActor
public final class WebKitMacPageFactory: WebMacPageFactory {
    private let applicationNameForUserAgent: () -> String
    private let extensionController: (UUID) -> WKWebExtensionController?
    private let extensionConfiguration: (URL, UUID) -> (any ExtensionPageConfiguration)?
    private let capture: () -> ExtensionCaptureRuntime
    private let store: @MainActor (UUID) -> WKWebsiteDataStore

    public init(applicationNameForUserAgent: @escaping () -> String,
                extensionController: @escaping (UUID) -> WKWebExtensionController?,
                extensionConfiguration: @escaping (URL, UUID) -> (any ExtensionPageConfiguration)?,
                capture: @escaping () -> ExtensionCaptureRuntime,
                store: @escaping @MainActor (UUID) -> WKWebsiteDataStore = { WebKitStores.store(for: $0) }) {
        self.applicationNameForUserAgent = applicationNameForUserAgent
        self.extensionController = extensionController
        self.extensionConfiguration = extensionConfiguration
        self.capture = capture
        self.store = store
    }

    /// The app supplies its catalog check; WebKit objects stay in the plugin.
    public convenience init(applicationNameForUserAgent: @escaping () -> String,
                            runtime: @escaping () -> WebKitExtensionRuntime,
                            isExtensionPage: @escaping (URL) -> Bool,
                            captureRuntime: @escaping () -> WebKitExtensionRuntime) {
        self.init(applicationNameForUserAgent: applicationNameForUserAgent,
            extensionController: { runtime().controllers.controller(for: $0) },
            extensionConfiguration: { url, space in
                let runtime = runtime()
                guard isExtensionPage(url), let id = url.host() else { return nil }
                return (runtime.controllers.contexts[space]?[id]?.webViewConfiguration).map { WebKitExtensionPageConfiguration($0) }
            }, capture: { captureRuntime().capture })
    }

    public static func pageCapture(runtime: @escaping () -> WebKitExtensionRuntime) -> WebExtensionPageCapture {
        WebExtensionPageCapture(screen: { ExtensionCaptureRuntime.screen($0) }, release: { runtime().capture.release($0) })
    }

    public var svgRasterizer: any WebSVGRasterizer { WebKitSVGRaster.shared }
    public var spaceStores: any WebSpaceStores { WebKitSpaceStores.shared }

    public func spellingFollows(writing: Bool, pages: [any WebMacPage]) {
        WebKitSpelling.follow(writing: writing, views: pages.map { page in
            guard let page = page as? WebKitMacPage else {
                preconditionFailure("Page.view requires a WebKitMacPage")
            }
            return page.webView
        })
    }

    public func ruleListStore() -> (any WebRuleListStore)? {
        WebKitRuleListStore.makeDefault()
    }

    /// A supplied configuration stays supplied, including an extension's controller.
    public func makePage(space: UUID, source: WebMacPageSource) -> any WebMacPage {
        switch source {
        case .space:
            return page(configuration: configuration(space: space))
        case .tab(let url):
            if let configuration = url.flatMap({ extensionConfiguration($0, space) }) {
                return page(configuration: supplied(configuration), extensionPage: true)
            }
            return page(configuration: configuration(space: space))
        case .child(let request):
            guard let request = request as? WebKitChildRequest else {
                preconditionFailure("AppWebKitEngine requires a WebKitChildRequest")
            }
            return page(configuration: request.configuration, extensionPage: false)
        case .supplied(let configuration):
            return page(configuration: supplied(configuration), extensionPage: true)
        }
    }

    func supplied(_ configuration: any ExtensionPageConfiguration) -> WKWebViewConfiguration {
        guard let configuration = configuration as? WebKitExtensionPageConfiguration else {
            preconditionFailure("AppWebKitEngine requires a WebKitExtensionPageConfiguration")
        }
        return configuration.configuration
    }

    public func page(configuration: WKWebViewConfiguration, extensionPage: Bool = false) -> WebKitMacPage {
        WebKitMacPage(configuration: configuration, extensionPage: extensionPage,
                      extensionUIDelegate: { [capture] in ExtensionPageDelegate(next: $0, capture: capture) })
    }

    /// The space's store and extension controller, with the app's user agent.
    public func configuration(space: UUID) -> WKWebViewConfiguration {
        WebKitConfiguration.make(store: store(space),
                                extensionController: extensionController(space),
                                applicationNameForUserAgent: applicationNameForUserAgent())
    }

    public func downloadStarter(space: UUID) -> any WebDownloadStarting {
        WebKitDownloadStarter(store: store(space))
    }
}
#endif
