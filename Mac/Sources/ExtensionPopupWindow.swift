import WebEngineAppKit

extension Extensions {
    func popupShows(_ page: Page) -> Bool {
        adapters.popupShows(page.enginePage)
    }
}
