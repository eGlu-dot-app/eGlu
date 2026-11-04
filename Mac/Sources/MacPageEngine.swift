import Foundation
import PadCore
import WebEngineCore
import WebKit
import WebKitSupport
import WebKitMacPlugin

/// Where a new page gets its configuration.
enum MacPageSource {
    /// A new page in the space's store.
    case space
    /// An enabled extension's configuration for the address, or the space's.
    case tab(URL?)
    /// A website's child, made from its request before the call returns.
    case child(any WebChildRequest)
    /// An extension's configuration, used as given.
    case supplied(WKWebViewConfiguration, extensionPage: Bool)
}

/// Makes the Mac's pages and starts their engine services.
@MainActor
protocol MacPageEngine: AnyObject {
    var svgRasterizer: any WebSVGRasterizer { get }
    /// The engine's compiled content-blocking lists.
    func ruleListStore() -> (any WebRuleListStore)?
    /// A page for the tab, space and configuration source.
    func makePage(tab: UUID, space: UUID, source: MacPageSource) -> Page
    /// A new configuration in the space's store.
    func configuration(space: UUID) -> WKWebViewConfiguration
    /// The space's session for a download retry.
    func downloadStarter(space: UUID) -> any WebDownloadStarting
    /// Empties a removed space's store and schedules its removal.
    func eraseStore(space: UUID)
    /// Removes website stores no space uses.
    func sweepStores()
    /// Starts the content blocker's lists and rules.
    func startContentBlocking()
    /// Starts the extensions enabled in each space.
    func startExtensions(afterLaunch: Bool)
    /// WebKit's own spell checking follows the writing setting.
    func spellingFollows(writing: Bool, pages: [Page])
}

/// The app's WebKit page factory.
@MainActor
final class AppWebKitEngine: MacPageEngine {
    var svgRasterizer: any WebSVGRasterizer { WebKitSVGRaster.shared }

    func spellingFollows(writing: Bool, pages: [Page]) {
        WebKitSpelling.follow(writing: writing, views: pages.map(\.view))
    }

    func ruleListStore() -> (any WebRuleListStore)? {
        WebKitRuleListStore.makeDefault()
    }

    /// A supplied configuration stays supplied, including an extension's controller.
    func makePage(tab: UUID, space: UUID, source: MacPageSource) -> Page {
        switch source {
        case .space:
            return Page(tab: tab, space: space, enginePage: AppWebKitEngine.page(configuration: configuration(space: space)))
        case .tab(let url):
            if let configuration = url.flatMap({ Extensions.shared.configuration(for: $0, in: space) }) {
                return Page(tab: tab, space: space, enginePage: AppWebKitEngine.page(configuration: configuration, extensionPage: true))
            }
            return Page(tab: tab, space: space, enginePage: AppWebKitEngine.page(configuration: configuration(space: space)))
        case .child(let request):
            guard let request = request as? WebKitChildRequest else {
                preconditionFailure("AppWebKitEngine requires a WebKitChildRequest")
            }
            return Page(tab: tab, space: space, enginePage: AppWebKitEngine.page(configuration: request.configuration, extensionPage: false))
        case .supplied(let configuration, let extensionPage):
            return Page(tab: tab, space: space, enginePage: AppWebKitEngine.page(configuration: configuration, extensionPage: extensionPage))
        }
    }

    static func page(configuration: WKWebViewConfiguration, extensionPage: Bool = false) -> WebKitMacPage {
        WebKitMacPage(configuration: configuration, extensionPage: extensionPage,
                      extensionUIDelegate: { ExtensionPageDelegate(next: $0) })
    }

    /// The space's store and extension controller, with the app's user agent.
    func configuration(space: UUID) -> WKWebViewConfiguration {
        WebKitConfiguration.make(store: WebKitStores.store(for: space),
                                extensionController: Extensions.shared.controller(for: space),
                                applicationNameForUserAgent: Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion))
    }

    func downloadStarter(space: UUID) -> any WebDownloadStarting {
        WebKitDownloadStarter(store: WebKitStores.store(for: space))
    }

    func eraseStore(space: UUID) {
        Stores.erase(space, in: WebKitSpaceStores.shared)
    }

    /// Removes website stores no space uses.
    func sweepStores() {
        Stores.sweep(in: WebKitSpaceStores.shared)
    }

    /// Starts the content blocker's lists and rules.
    func startContentBlocking() {
        ContentBlocker.shared.start()
    }

    /// Starts the extensions enabled in each space.
    func startExtensions(afterLaunch: Bool) {
        Extensions.shared.start(afterLaunch: afterLaunch)
    }
}
