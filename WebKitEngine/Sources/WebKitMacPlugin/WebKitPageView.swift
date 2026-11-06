import AppKit
import WebEngineAppKit
import WebKit

/// WebKit's own view. The app gets each event at the same point as before.
public final class WebKitPageView: WKWebView, WebContextMenu {
    var menus: (any WebPageMenus)?
    public weak var events: (any WebPageViewEvents)?

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        prepareMenu(menu)
        super.willOpenMenu(menu, with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        forwardScrollWheel(event) { super.scrollWheel(with: event) }
    }

    func forwardScrollWheel(_ event: NSEvent, otherwise: () -> Void) {
        if events?.scrollWheel(event) == true { return }
        otherwise()
    }

    public override func swipe(with event: NSEvent) {
        forwardSwipe(event) { super.swipe(with: event) }
    }

    func forwardSwipe(_ event: NSEvent, otherwise: () -> Void) {
        if events?.swipe(event) == true { return }
        otherwise()
    }

    func prepareMenu(_ menu: NSMenu) { menus?.willOpenMenu(menu, context: self) }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        events?.movedToWindow()
    }

    @objc private func handOffLinkedFile(_ sender: NSMenuItem) { menus?.handOffLinkedFile(sender) }
    @objc private func openLinkInPeek(_ sender: NSMenuItem) { menus?.openLinkInPeek(sender) }

    public var actionTarget: AnyObject { self }
    public let openLinkInNewWindowIdentifier = "WKMenuItemIdentifierOpenLinkInNewWindow"

    private static let renamed: [String: String] = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": String(localized: "Open Link in New Tab", bundle: .main),
        "WKMenuItemIdentifierOpenImageInNewWindow": String(localized: "Open Image in New Tab", bundle: .main),
        "WKMenuItemIdentifierOpenMediaInNewWindow": String(localized: "Open Video in New Tab", bundle: .main),
        "WKMenuItemIdentifierOpenFrameInNewWindow": String(localized: "Open Frame in New Tab", bundle: .main),
    ]

    public func title(for identifier: String) -> String? { Self.renamed[identifier] }

    public func isExtensionItem(_ item: NSMenuItem) -> Bool {
        NSStringFromClass(type(of: item)) == "_WKWebExtensionMenuItem"
    }
}
