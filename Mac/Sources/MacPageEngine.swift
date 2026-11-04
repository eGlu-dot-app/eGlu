import Foundation
import PadCore
import WebKit
import WebKitMacPlugin

/// Where a new page gets its configuration.
enum MacPageSource {
    /// A new page in the space's store.
    case space
    /// An enabled extension's configuration for the address, or the space's.
    case tab(URL?)
    /// WebKit's or an extension's configuration, used as given.
    case supplied(WKWebViewConfiguration, extensionPage: Bool)
}

/// Makes the Mac's pages and starts their engine services.
@MainActor
protocol MacPageEngine: AnyObject {
    /// A page for the tab, space and configuration source.
    func makePage(tab: UUID, space: UUID, source: MacPageSource) -> Page
    /// A new configuration in the space's store.
    func configuration(space: UUID) -> WKWebViewConfiguration
    /// Removes website stores no space uses.
    func sweepStores()
    /// Starts the content blocker's lists and rules.
    func startContentBlocking()
    /// Starts the extensions enabled in each space.
    func startExtensions(afterLaunch: Bool)
}

/// The app's WebKit page factory until Page moves into the plugin.
@MainActor
final class AppWebKitEngine: MacPageEngine {
    /// A supplied configuration stays supplied, including an extension's controller.
    func makePage(tab: UUID, space: UUID, source: MacPageSource) -> Page {
        switch source {
        case .space:
            return Page(tab: tab, space: space, configuration: configuration(space: space))
        case .tab(let url):
            if let configuration = url.flatMap({ Extensions.shared.configuration(for: $0, in: space) }) {
                return Page(tab: tab, space: space, configuration: configuration, extensionPage: true)
            }
            return Page(tab: tab, space: space, configuration: configuration(space: space))
        case .supplied(let configuration, let extensionPage):
            return Page(tab: tab, space: space, configuration: configuration, extensionPage: extensionPage)
        }
    }

    /// The space's store and extension controller, with the app's user agent.
    func configuration(space: UUID) -> WKWebViewConfiguration {
        WebKitConfiguration.make(store: Stores.store(for: space),
                                extensionController: Extensions.shared.controller(for: space),
                                applicationNameForUserAgent: Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion))
    }

    /// Removes website stores no space uses.
    func sweepStores() {
        Stores.sweep()
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
