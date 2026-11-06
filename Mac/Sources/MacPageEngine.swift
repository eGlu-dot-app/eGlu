import Foundation
import WebEngineAppKit
import WebEngineCore

/// Where a new page gets its configuration.
typealias MacPageSource = WebMacPageSource

/// Makes the Mac's pages and starts their engine services.
@MainActor
protocol MacPageEngine: AnyObject {
    var svgRasterizer: any WebSVGRasterizer { get }
    func ruleListStore() -> (any WebRuleListStore)?
    func makePage(tab: UUID, space: UUID, source: MacPageSource) -> Page
    func downloadStarter(space: UUID) -> any WebDownloadStarting
    func eraseStore(space: UUID)
    func sweepStores()
    func startContentBlocking()
    func startExtensions(afterLaunch: Bool)
    func spellingFollows(writing: Bool, pages: [Page])
}

/// The app's product page factory, over the selected engine's factory.
@MainActor
final class AppPageEngine: MacPageEngine {
    private let factory: any WebMacPageFactory

    init(factory: any WebMacPageFactory) {
        self.factory = factory
    }

    var svgRasterizer: any WebSVGRasterizer { factory.svgRasterizer }

    func spellingFollows(writing: Bool, pages: [Page]) {
        factory.spellingFollows(writing: writing, pages: pages.map(\.enginePage))
    }

    func ruleListStore() -> (any WebRuleListStore)? { factory.ruleListStore() }

    func makePage(tab: UUID, space: UUID, source: MacPageSource) -> Page {
        Page(tab: tab, space: space, enginePage: factory.makePage(space: space, source: source))
    }

    func downloadStarter(space: UUID) -> any WebDownloadStarting {
        factory.downloadStarter(space: space)
    }

    func eraseStore(space: UUID) { Stores.erase(space, in: factory.spaceStores) }
    func sweepStores() { Stores.sweep(in: factory.spaceStores) }
    func startContentBlocking() { ContentBlocker.shared.start() }
    func startExtensions(afterLaunch: Bool) { Extensions.shared.start(afterLaunch: afterLaunch) }
}

// The host passes the runtime's configuration straight to the app's engine.
extension MacPageEngine {
    func makeExtensionPopupPage(space: UUID, configuration: (any ExtensionPageConfiguration)?) -> Page {
        if let configuration {
            return makePage(tab: UUID(), space: space, source: .supplied(configuration))
        }
        return makePage(tab: UUID(), space: space, source: .space)
    }
}
