import AppKit
import Combine
import PadCore
import WebEngineCore

/// The Chrome Web Store's "Add to eGlu" button (Scripts/extension-store.js,
/// after Search's StoreRelay). What gets installed is read from the tab's
/// own address, never from what the page says: the page only asks, and the
/// install sheet still stands between the asking and the installing.
@MainActor
final class StoreButton {
    static let name = "egluStore"

    private weak var page: Page?

    init(page: Page) {
        self.page = page
    }

    static func isStore(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host() == "chromewebstore.google.com"
    }

    func received(_ message: WebMessage) {
        // Only the store page's main frame, in the app's own world.
        guard let page, message.isMainFrame, message.world == .app,
              let url = page.view.url, Self.isStore(url), let body = message.body.foundation as? [String: Any] else { return }
        // Only the extension of the page the button was put on, and still
        // the tab's: the store's own navigation can change the address
        // under a button still on screen. Into the page's own space.
        if let clicked = body["add"] as? String {
            guard let id = ExtensionStore.id(ofPage: url), id == clicked else { return }
            let window = Session.shared.allWindows.first { $0.tabID == page.tab && $0.spaceID == page.space }
            Extensions.shared.add(fromStorePage: url, in: window, space: page.space)
        }
        if body["placed"] != nil { Self.tell(page) }
    }

    /// Tells a store page what is installed and what is on its way, so its
    /// button can say "Added to eGlu" or "Adding…".
    static func tell(_ page: Page) {
        guard isStore(page.view.url) else { return }
        let extensions = Extensions.shared
        let state: [String: Any] = ["installed": extensions.installed.map(\.id), "busy": extensions.busy ?? NSNull()]
        guard let json = try? JSONSerialization.data(withJSONObject: state),
              let text = String(data: json, encoding: .utf8) else { return }
        page.tellStore(text)
    }

    /// And tells every store page again whenever either changes.
    static func follow() -> AnyCancellable {
        let extensions = Extensions.shared
        return extensions.$installed.map { _ in () }
            .merge(with: extensions.$busy.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink {
                MainActor.assumeIsolated {
                    for page in Session.shared.pages.live.values where isStore(page.view.url) { tell(page) }
                }
            }
    }
}
