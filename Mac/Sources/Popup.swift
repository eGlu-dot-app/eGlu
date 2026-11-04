import AppKit
import PadCore
import WebKit

/// A window a page opened at a size of its own (a sign-in with Google or
/// Apple, a share dialog) where no Peek can have it: from a page in a Peek,
/// a little window or a pop-up itself, or from a tab not on screen. A tab's
/// page on screen has its pop-ups in a Peek (PeekPage). It sits over the
/// window that opened it, in the same space's store, and closes by itself
/// when the page closes it.
@MainActor
final class Popup: NSObject, PageHost, NSWindowDelegate {
    /// The pop-ups open now: each holds itself until its window closes.
    private static var open: Set<Popup> = []

    let page: Page
    /// The page that opened it, so a Peek going takes its pop-ups with it (close(openedBy:)).
    private weak var opener: Page?
    private let panel: NSWindow
    private let address = NSTextField(labelWithString: String(localized: "Loading…"))
    private let security = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: String(localized: "Loading page…"))
    private let progress = NSProgressIndicator()
    private let recovery = NSButton(title: String(localized: "Reload"), target: nil, action: nil)
    private let statusBox = NSStackView()
    private var announced: String?
    /// The window it stands over closing: it closes too.
    private var parentClosing: NSObjectProtocol?

    static func open(from opener: Page, configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                     over parent: NSWindow?) -> WKWebView {
        // A page of no tab: what it says about itself is kept nowhere.
        let page = Session.shared.engine.makePage(tab: UUID(), space: opener.space, source: .supplied(configuration, extensionPage: false))
        page.openedFrom = opener.tab
        let size = NSSize(width: features.width?.doubleValue ?? 520, height: features.height?.doubleValue ?? 640)
        let popup = Popup(page: page, opener: opener, size: size, over: parent)
        open.insert(popup)
        return popup.page.view
    }

    /// An extension's popup window (windows.create with type "popup"): a
    /// page the extension's window made, at `frame` or in the middle of the
    /// screen, over no window. `closed` is told when it goes.
    static func open(page: Page, frame: NSRect?, minimum: NSSize, closed: @escaping () -> Void) -> Popup {
        let popup = Popup(page: page, opener: nil, size: frame?.size ?? NSSize(width: 480, height: 600), minimum: minimum, over: nil)
        if let frame { popup.panel.setFrame(frame, display: false) }
        popup.closed = closed
        open.insert(popup)
        return popup
    }

    /// Told when the window goes, however it went.
    private var closed: (() -> Void)?

    var window: NSWindow {
        panel
    }

    /// Each pop-up `opener` opened, closed: a Peek's, as the Peek goes, so
    /// none is left over the window with nothing under it that opened it.
    static func close(openedBy opener: Page) {
        for popup in open where popup.opener === opener {
            popup.panel.close()
        }
    }

    private init(page: Page, opener: Page?, size: NSSize, minimum: NSSize = NSSize(width: 320, height: 240), over parent: NSWindow?) {
        self.page = page
        self.opener = opener
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(size.width, minimum.width), height: max(size.height, minimum.height)),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        page.host = self
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        makeContent()
        panel.title = String(localized: "Loading…")
        if let parent {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            parent.addChildWindow(panel, ordered: .above)
            parentClosing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel.close() }
            }
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeContent() {
        let close = NSButton(title: String(localized: "Close"), target: self, action: #selector(closePopup))
        security.imageScaling = .scaleProportionallyDown
        security.setAccessibilityElement(true)
        address.lineBreakMode = .byTruncatingMiddle
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [security, address, close])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        statusBox.orientation = .vertical
        statusBox.alignment = .leading
        statusBox.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        statusBox.spacing = 6
        recovery.target = self
        recovery.action = #selector(recoverPage)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        [status, progress, recovery].forEach(statusBox.addArrangedSubview)
        let stack = NSStackView(views: [header, statusBox, page.surface.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let content = NSView()
        panel.contentView = content
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            page.surface.view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: statusBox.widthAnchor, constant: -24),
            security.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @objc private func closePopup() { panel.close() }
    @objc private func recoverPage() {
        if page.googleRefused, page.state.canGoBack { page.goBack() } else { page.reload() }
    }

    func windowWillClose(_ notification: Notification) {
        if let parentClosing { NotificationCenter.default.removeObserver(parentClosing) }
        panel.parent?.removeChildWindow(panel)
        page.tearDown()
        Popup.open.remove(self)
        closed?()
        closed = nil
    }

    // MARK: PageHost

    var hostWindow: NSWindow? {
        panel
    }

    func pageDidChange(_ page: Page) {
        let url = page.displayURL
        let state = page.state
        let title = state.title ?? ""
        panel.title = title.isEmpty ? (url?.host ?? String(localized: "Loading…")) : title
        // An extension's own page (its popup window, ExtensionPopupWindow)
        // is named by its extension, and has no connection to vouch for.
        let owner = page.isExtensionPage ? url?.host().flatMap { id in Extensions.shared.installed.first { $0.id == id }?.name } : nil
        address.stringValue = owner ?? url.map(Destination.pretty) ?? String(localized: "Loading…")
        address.setAccessibilityLabel(url?.absoluteString ?? String(localized: "Loading page"))
        let secure = url?.scheme == "https" && state.hasOnlySecureContent && page.failure == nil
        security.image = NSImage(systemSymbolName: secure ? "lock.fill" : "exclamationmark.triangle", accessibilityDescription: nil)
        security.contentTintColor = secure ? .systemGreen : .systemOrange
        security.setAccessibilityLabel(secure ? String(localized: "Secure connection") : String(localized: "Connection is not verified as secure"))
        security.isHidden = url == nil || page.isExtensionPage
        let problem = page.googleRefused ? SignIn.fallback : page.failure
            ?? (page.exhausted ? String(localized: "This page stopped after repeated memory problems. Close another tab, then reload.") : nil)
        status.stringValue = problem ?? String(localized: "Loading page…")
        statusBox.isHidden = problem == nil && !state.isLoading
        progress.isHidden = problem != nil || !state.isLoading
        progress.doubleValue = state.estimatedProgress
        recovery.isHidden = problem == nil
        recovery.title = page.googleRefused && state.canGoBack ? String(localized: "Go Back") : String(localized: "Reload")
        if let problem, problem != announced {
            announced = problem
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: problem, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        } else if problem == nil { announced = nil }

    }

    func isShowing(_ page: Page) -> Bool {
        panel.isVisible
    }

    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView? {
        Popup.open(from: page, configuration: configuration, features: features, over: panel)
    }

    /// No tabs here: the page goes there itself.
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool {
        false
    }

    func pageDidClose(_ page: Page) {
        panel.close()
    }
}
