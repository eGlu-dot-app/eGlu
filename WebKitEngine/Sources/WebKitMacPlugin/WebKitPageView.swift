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

    /// A new view's first load paints WebKit's empty first document, white
    /// whatever the window's appearance, for as long as the page takes to
    /// answer: a white flash in dark mode. Until its first page commits the
    /// view paints no page ground (WebKit's `drawsBackground`, private), only
    /// the colour WebKit gives an empty view's layer, which follows the
    /// appearance. From the first commit on, WebKit paints as it always has:
    /// a page with no background of its own is white, and one that says it
    /// can be dark (`color-scheme`) is dark.
    private(set) var holdsBlank = false

    func holdBlankUntilFirstPage() {
        guard responds(to: NSSelectorFromString("_setDrawsBackground:")) else { return }
        setValue(false, forKey: "drawsBackground")
        holdsBlank = true
        needsDisplay = true
    }

    /// The first page has taken the empty document's place, so WebKit paints
    /// its page ground again: without it, a page with no background of its
    /// own would show the view's layer colour under its text instead of
    /// white. The navigation adapter calls it as each page commits; only the
    /// first changes anything.
    func pageCommitted() {
        guard holdsBlank else { return }
        holdsBlank = false
        setValue(true, forKey: "drawsBackground")
        needsDisplay = true
    }

    public override func updateLayer() {
        super.updateLayer()
        // WebKit takes its layer's colour away while it paints no ground;
        // the view keeps the one it has before any page, resolved in its
        // own appearance (AppKit's current one here).
        if holdsBlank { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }
    }

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
