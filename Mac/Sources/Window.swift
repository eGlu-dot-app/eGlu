import AppKit
import SwiftUI

/// Reaches the window SwiftUI made, to make it the browser's: no title bar
/// drawn, the content under where it was, no system tabs (the sidebar has
/// the tabs), and AppKit's own close, minimise and zoom buttons hidden: the
/// sidebar has its own (WindowButtons).
struct WindowReader: NSViewRepresentable {
    let model: WindowModel

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(model: model)
    }

    func updateNSView(_ view: ReaderView, context: Context) {}
}

final class ReaderView: NSView {
    private weak var model: WindowModel?
    private var swipe: Any?
    /// How far a two-finger swipe across the sidebar has gone, sideways.
    private var swiped: CGFloat = 0
    private var swipeDone = false
    /// Whether the gesture under way is a sideways one, decided by its first
    /// move and kept to its end: a scroll down the tabs that drifts sideways
    /// stays a scroll.
    private var sideways: Bool?
    private var fullScreen: NSObjectProtocol?

    init(model: WindowModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let swipe {
            NSEvent.removeMonitor(swipe)
            self.swipe = nil
        }
        if let fullScreen {
            NotificationCenter.default.removeObserver(fullScreen)
            self.fullScreen = nil
        }
        guard let window else { return }
        MainActor.assumeIsolated { model?.window = window }
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        // Clear, for its ground's glass to show what is behind the window (Backdrop).
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior.insert(.fullScreenPrimary)
        hideLights()
        // Full screen lays the title bar out anew, and shows them again.
        fullScreen = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideLights() }
        }
        watchSwipes()
    }

    private func hideLights() {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = true
        }
    }

    /// Arc's way between spaces: two fingers swept sideways over the
    /// sidebar go to the next space or the one before. Only a sweep that is
    /// more sideways than up and down counts; the tabs scroll otherwise.
    private func watchSwipes() {
        swipe = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            // Events come on the main thread; the monitor's closure just doesn't say so.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { self.handle(event, in: window) ? nil : event }
        }
    }

    @MainActor
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let model, model.tabsInSidebar, model.sidebarShown || model.peeking, event.hasPreciseScrollingDeltas else { return false }
        let x = event.locationInWindow.x
        // Out over the page, the pane is a gap in and a gap wider.
        let width = model.sidebarWidth + (model.sidebarShown ? 0 : Metrics.gap * 2)
        guard x < width else { return false }
        if event.phase == .began {
            swiped = 0
            swipeDone = false
            sideways = nil
        }
        guard event.phase == .began || event.phase == .changed else {
            let was = sideways == true
            swiped = 0
            sideways = nil
            return was
        }
        if sideways == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
        }
        guard sideways == true else { return false }
        swiped += event.scrollingDeltaX
        if !swipeDone, abs(swiped) > 70 {
            swipeDone = true
            // Content follows the fingers: a sweep to the left brings in the space on the right.
            model.showSpace(by: swiped < 0 ? 1 : -1)
        }
        return true
    }

    deinit {
        if let swipe { NSEvent.removeMonitor(swipe) }
        if let fullScreen { NotificationCenter.default.removeObserver(fullScreen) }
    }
}

/// The window's close, minimise and zoom buttons, as AppKit makes them
/// (`standardWindowButton(_:for:)`), standing in the sidebar's top row:
/// on its grid, centred in a cell as high as the row's glass buttons, and
/// going where the sidebar goes, out over the page with it, hidden with it.
/// AppKit's own stay hidden (ReaderView): it keeps them 9 points from the
/// window's corner, level with nothing of the sidebar's, and lays them out
/// there again whenever it likes.
struct WindowButtons: NSViewRepresentable {
    /// From one button's start to the next's, as AppKit spaces its own, and
    /// each button's side.
    static let step: CGFloat = 23
    static let side: CGFloat = 14
    static var width: CGFloat { side + 2 * step }

    func makeNSView(context: Context) -> WindowButtonsView {
        WindowButtonsView()
    }

    func updateNSView(_ view: WindowButtonsView, context: Context) {}
}

final class WindowButtonsView: NSView {
    private var buttons: [NSButton] = []
    /// The pointer is over the buttons: each then shows its sign, as AppKit's own do together.
    private var inside = false {
        didSet { if inside != oldValue { buttons.forEach { $0.needsDisplay = true } } }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: WindowButtons.width, height: WindowButtons.side)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, buttons.isEmpty else { return }
        for (place, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(kind, for: window.styleMask) else { continue }
            button.setFrameOrigin(NSPoint(x: CGFloat(place) * WindowButtons.step, y: 0))
            addSubview(button)
            buttons.append(button)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        inside = true
    }

    override func mouseExited(with event: NSEvent) {
        inside = false
    }

    /// AppKit's buttons ask the view they stand in whether the pointer is
    /// over their group, to show their signs together.
    @objc(_mouseInGroup:)
    func mouseInGroup(_ button: NSButton) -> Bool {
        inside
    }
}

/// The page's web view, in the card. The view is the page's own and only
/// visits: when the window shows another tab, or another window takes this
/// tab, it leaves.
struct PageSurface: NSViewRepresentable {
    let page: Page?

    func makeNSView(context: Context) -> PageHolder {
        PageHolder()
    }

    func updateNSView(_ holder: PageHolder, context: Context) {
        holder.show(page?.surface.view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageHolder, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }

    /// The card going: the page leaves with it, unless another card has it by now.
    static func dismantleNSView(_ holder: PageHolder, coordinator: ()) {
        holder.show(nil)
    }
}
