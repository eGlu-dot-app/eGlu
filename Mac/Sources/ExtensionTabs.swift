import WebEngineAppKit

extension Extensions {
    func addressChanged(_ page: Page) {
        adapters.addressChanged(page.enginePage, tab: page.tab, in: page.space)
    }

    func loadingChanged(_ page: Page) {
        adapters.loadingChanged(tab: page.tab, in: page.space)
    }
}
