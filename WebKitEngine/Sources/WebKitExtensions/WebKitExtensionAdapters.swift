#if os(macOS)
import Foundation
import WebEngineAppKit

@MainActor
public final class WebKitExtensionAdapters: WebExtensionAdapters {
    private let tabs: ExtensionTabs

    public init(tabs: ExtensionTabs) { self.tabs = tabs }

    public func addressChanged(_ page: any WebMacPage, tab: UUID, in space: UUID) {
        tabs.addressChanged(page, tab: tab, in: space)
    }

    public func loadingChanged(tab: UUID, in space: UUID) {
        tabs.loadingChanged(tab: tab, in: space)
    }

    public func popupShows(_ page: any WebMacPage) -> Bool {
        ExtensionPopupWindow.showing(page) != nil
    }
}
#endif
