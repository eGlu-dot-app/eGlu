import PadCore
import WebEngineCore

/// The measuring tool's word from the page (measure.js in the app's own
/// world): the element it told of, a distance, its ending. Everything it
/// draws stays in the page; everything it says comes through here.
@MainActor
final class MeasureChannel {
    static let name = "egluMeasure"

    private weak var page: Page?

    init(page: Page) {
        self.page = page
    }

    func received(_ message: WebMessage) {
        // Only the page's own main frame, in the app's own world.
        guard let page, message.isMainFrame, message.world == .app,
              let body = message.body.foundation as? [String: Any] else { return }
        page.measured(body)
    }
}
