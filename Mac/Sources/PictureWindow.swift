import AppKit
import PadCore
import SwiftUI
import WebEngineCore
import WebEngineAppKit

/// A site's picture-in-picture window (DocumentPicture.swift): the blank
/// page picture.js opened, floating above every window and every app, on
/// every Space and over full-screen apps, as Chrome's does. Google Meet
/// moves its call there when asked, or when its tab is left mid-call.
///
/// The page in it is the site's own, in the opener's process: the site
/// fills it and takes its elements back when it closes, on `pagehide`,
/// which WebKit fires as the web view goes. So the window goes by one way
/// only, `finish`, whoever closes it: its close button, Back to Tab, the
/// site, or the tab that opened it (Page.picture).
///
/// It is the site's to fill, not the app's: no script of the app's, no
/// address bar, nowhere to go but the blank page and its frames. A link in
/// it opens in a tab beside its opener.
///
/// It looks as an extension's popup does (PicturePane): a pane of glass,
/// the site's icon and host over the page, the page inset in it. A
/// borderless panel, so there is no system title bar: in eGlu, drawn
/// in Liquid Glass on macOS 27, a titled window's title bar covered what
/// the app put there, though AppKit laid it out and drew it.
@MainActor
final class PictureWindow: NSObject, NSWindowDelegate, WebPicturePageEvents {
    private(set) weak var opener: Page?
    let backend: any WebPicturePage
    var view: NSView { backend.view }
    private let panel: NSPanel
    /// Opened by the app when the tab was left (Page.leftScreen), and so
    /// closed when the tab is back on screen, as Chrome's is.
    var automatic = false
    private var finished = false
    private var closing = false
    /// Where its place and size are kept for its site, once it has arrived:
    /// kept by hand, not by AppKit's autosave, which would keep the place it
    /// rises from and refuses a name a window still fading out holds.
    private let frameName: String
    private var arrived = false

    /// The web view for the window picture.js opens, made with WebKit's
    /// `configuration` so the site keeps its hold on the page in it.
    init?(opener: Page, child: any WebChildRequest, request: DocumentPicture.Request) {
        self.opener = opener
        // The screen of the window the tab is in, or was in a moment ago (a
        // tab just left has no window of its own any more).
        let session = Session.shared
        let screen = opener.host?.hostWindow?.screen
            ?? session.allWindows.first(where: { $0.spaceID == opener.space })?.window?.screen ?? NSScreen.main
        let room = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // The page at the size the site asked for, the pane round it. At that
        // size from the start: a site reads the window's size as soon as it has it.
        let page = DocumentPicture.size(width: child.features.width, height: child.features.height, within: room.size)
        guard let backend = opener.enginePage.makePicturePage(from: child, size: page) else { return nil }
        self.backend = backend
        panel = PicturePanel(contentRect: NSRect(origin: .zero, size: PicturePane.window(around: page)),
                             styleMask: [.borderless, .resizable, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        let url = opener.committed ?? opener.pageURL
        let host = url?.host() ?? ""
        frameName = "Picture \(host)"
        super.init()
        backend.connect(events: self)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // See-through but for the pane, whose shape the window's own shadow follows.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.title = host
        panel.contentMinSize = PicturePane.window(around: DocumentPicture.smallest)
        let pane = PicturePane(url: url, host: host, web: view, returns: request.returnsToOpener,
                               back: { [weak self] in self?.backToTab() }, close: { [weak self] in self?.close() })
        panel.contentView = PictureHost(rootView: pane)
        (panel as? PicturePanel)?.onCloseKey = { [weak self] in self?.close() }
        // Where and how big it was last for this site, as Chrome reopens it,
        // unless the site asks for where it first opens.
        if request.initialPlacement || !panel.setFrameUsingName(frameName) {
            panel.setFrame(NSRect(origin: DocumentPicture.origin(for: panel.frame.size, in: room), size: panel.frame.size),
                           display: false)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        arrive()
    }

    /// In front, without taking the keys from the window or app in use: in
    /// from a little below, as it fades in (only fading, with Reduce Motion).
    private func arrive() {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = panel.frame
        panel.alphaValue = 0
        if !still { panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - 8)) }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            panel.animator().alphaValue = 1
            if !still { panel.animator().setFrame(frame, display: true) }
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.arrived = true
            // Its shadow drawn again from the glass as it now is.
            self.panel.invalidateShadow()
        }
    }

    /// Its place and size kept for its site, once it has arrived and not as it goes.
    private func keepFrame() {
        guard arrived, !closing else { return }
        panel.saveFrame(usingName: frameName)
    }

    /// The tab that opened the window, in front, and the window gone, as in Chrome.
    private func backToTab() {
        if let opener { Self.show(opener.tab, of: opener.space) }
        close()
    }

    /// The tab on screen: in the window showing it, or one showing its
    /// space, or the window in front; in a new window when none is open.
    private static func show(_ tab: UUID, of space: UUID) {
        let session = Session.shared
        NSApp.activate()
        guard let window = session.window(showing: tab) ?? session.allWindows.first(where: { $0.spaceID == space })
                ?? session.frontWindow
        else {
            session.change { $0.select(tab) }
            session.openWindow?(space)
            return
        }
        window.select(tab)
        window.window?.makeKeyAndOrderFront(nil)
    }

    /// Out softer than it came in: a quick fade, then gone (finish). The
    /// opener hears at once, so its next window, or its next call on
    /// leaving, needn't wait for the fade; this window holds itself until
    /// its close has run, whoever else lets go of it.
    func close() {
        guard !closing else { return }
        keepFrame()
        closing = true
        opener?.pictureDidClose(self)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [self] in
            panel.close()
        }
    }

    /// The one way the window goes. The web view goes with it, and WebKit
    /// fires `pagehide` in its page as it does, for the site to take its
    /// elements home.
    private func finish() {
        guard !finished else { return }
        finished = true
        backend.tearDown()
        panel.contentView = nil
        panel.delegate = nil
        // The panel is in the middle of closing, and the opener lets go of
        // this window now: the panel is held until its close has run.
        let panel = self.panel
        DispatchQueue.main.async { withExtendedLifetime(panel) {} }
        opener?.pictureDidClose(self)
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    /// The window's shadow follows the pane's shape at its new size.
    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()
    }

    func windowDidEndLiveResize(_ notification: Notification) { keepFrame() }
    func windowDidMove(_ notification: Notification) { keepFrame() }

    // MARK: The page in it

    func decidePictureNavigation(url: URL?, targetIsMainFrame: Bool, reply: @MainActor (Bool) -> Void) {
        // Its frames go where they like; the window itself stays on its blank page.
        guard targetIsMainFrame else { return reply(true) }
        if url?.scheme?.lowercased() == "about" { return reply(true) }
        reply(false)
        if let url { openBesideOpener(url) }
    }

    /// A link in the window asking for a window of its own: a tab beside the opener's.
    func pictureRequestedWindow(url: URL?) {
        if let url { openBesideOpener(url) }
    }

    private func openBesideOpener(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let opener else { return }
        // The opener's window, or with its tab off screen, one showing its
        // space, or the window in front, brought forward; with no window
        // open, eGlu opens it as it would a link from another app.
        let session = Session.shared
        NSApp.activate()
        guard let window = (opener.host as? WindowModel) ?? session.window(showing: opener.tab)
                ?? session.allWindows.first(where: { $0.spaceID == opener.space }) ?? session.frontWindow
        else { return session.open([url]) }
        _ = window.page(opener, openInNewTab: url, inFront: true)
        window.window?.makeKeyAndOrderFront(nil)
    }

    /// The site closed it (`pipWindow.close()`).
    func pictureCloseRequested() {
        close()
    }

    /// The opener's process ended, and this page with it.
    func pictureProcessEnded() {
        close()
    }
}

/// The window's panel: takes the keys when clicked, for a call's chat,
/// without bringing eGlu in front of the app in use.
private final class PicturePanel: NSPanel {
    /// ⌘W, with the keys here.
    var onCloseKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘W closes this window, and not the tab of the window behind it,
    /// which the menu's Close Tab would otherwise reach.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCloseKey?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The window as an extension's popup is drawn (ExtensionPopup.swift,
/// PopupMetrics): a pane of glass with corners of 20, the site's icon and
/// host over the page, Back to Tab and × at the header's end, and the page
/// 10 in from the pane's sides and foot with corners of 10, so the two
/// curves run side by side. The header's ground moves the window.
struct PicturePane: View {
    let url: URL?
    let host: String
    let web: NSView
    /// Whether Back to Tab shows (the site didn't set `disallowReturnToOpener`).
    let returns: Bool
    let back: () -> Void
    let close: () -> Void

    /// The header's height with the room above and below it, as the popup's.
    static let header: CGFloat = 4 + Metrics.control + 6

    /// The window round a page of `page`'s size.
    static func window(around page: CGSize) -> CGSize {
        CGSize(width: page.width + 2 * PopupMetrics.inset, height: page.height + header + PopupMetrics.inset)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PopupMetrics.corner, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SiteIconView(url: url, size: 16)
                Text(host)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    if returns {
                        Button(action: back) {
                            Image(systemName: "pip.exit")
                        }
                        .buttonStyle(PressedIconStyle())
                        .help("Back to Tab")
                        .accessibilityLabel("Back to Tab")
                    }
                    Button(action: close) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(PressedIconStyle())
                    .help("Close")
                    .accessibilityLabel("Close Picture in Picture")
                }
                // The last glyph, not its 28-point cell, near the page's right edge.
                .padding(.trailing, -6)
            }
            .frame(height: Metrics.control)
            .padding(.top, 4)
            .padding(.horizontal, PopupMetrics.inset)
            // The header's ground moves the window, as a title bar does; what is on it are only buttons.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
            }
            PictureSurfaceView(web: web)
                .clipShape(RoundedRectangle(cornerRadius: PopupMetrics.page, style: .continuous))
                .padding([.horizontal, .bottom], PopupMetrics.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(shape)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.75)), in: shape)
    }
}

/// The pane's view: a click on its buttons works the first time, with
/// eGlu behind another app.
private final class PictureHost: NSHostingView<PicturePane> {
    required init(rootView: PicturePane) {
        super.init(rootView: rootView)
        // The window's own least size holds (contentMinSize), not the pane's.
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Places the engine's own view, with no wrapper around its responder chain.
private struct PictureSurfaceView: NSViewRepresentable {
    let web: NSView
    func makeNSView(context: Context) -> NSView { web }
    func updateNSView(_ view: NSView, context: Context) {}
}
