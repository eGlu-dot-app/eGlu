import PadCore
import WebKit

/// The measuring tool's word from the page (measure.js in the app's own
/// world): the element it told of, a distance, its ending. Everything it
/// draws stays in the page; everything it says comes through here.
@MainActor
final class MeasureHandler: NSObject, WKScriptMessageHandler {
    static let name = "egluMeasure"

    private weak var page: Page?

    init(page: Page) {
        self.page = page
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            // Only the page's own main frame, in the app's own world.
            guard let page, message.frameInfo.isMainFrame, message.world == Page.world,
                  let body = message.body as? [String: Any] else { return }
            page.measured(body)
        }
    }
}
