import WebKitExtensions

extension ExtensionTabs {
    func addressChanged(_ page: Page) {
        addressChanged(page.enginePage, tab: page.tab, in: page.space)
    }

    func loadingChanged(_ page: Page) {
        loadingChanged(tab: page.tab, in: page.space)
    }
}
