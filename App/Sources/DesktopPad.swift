import CoreImage
import PadCore
import QuartzCore
import SwiftUI
import UIKit

/// The iPhone's desktop view, over the page: a web app laid out at an iPad
/// Pro 13-inch's size (DesktopView, in PadCore), and the phone's screen as a
/// trackpad for it, as in Jump Desktop's trackpad mode. For using a web app
/// from the phone now and then; the iPad is where the real trackpad is.
///
/// - One finger moves the cursor, further the faster it goes; the view
///   follows the cursor when it nears an edge, and against the desktop's
///   top or bottom, where the view can follow no further, the page scrolls.
/// - A tap clicks where the cursor is; two quick taps double-click.
/// - Touch and hold, then move: a drag with the button held.
/// - Two fingers tap: the right button. Two fingers move: a scroll, which
///   glides on after a flick. A pinch zooms the view, not the page.
/// - The minimap, top right, shows the whole desktop, in colour where it
///   shows and in black and white elsewhere; a tap on it goes there, and a
///   drag throws it to another corner, as a picture in picture goes.
/// - The keyboard button types into what the cursor last clicked.
///
/// What reaches the page is bridge.js's (Page.pointer, Page.wheel,
/// Page.type), never on a hands-off page, which has no desktop view.
@MainActor
final class DesktopPad: UIView, UIGestureRecognizerDelegate {
    private(set) weak var page: Page?
    private(set) var desktop: DesktopView

    private let cursor = CursorView()
    private let minimap = Minimap()
    private let keyboardButton = UIButton(configuration: DesktopPad.buttonStyle())
    private let typing = DesktopTyping()
    /// The row of controls over the page's foot, as the phone bar's tools
    /// are: Exit and the page's menu on discs of their own, the zoom's three
    /// on one capsule, the keyboard on a disc. Nothing behind them but glass.
    private let controls = UIView()
    private let exitDisc = DesktopPad.glass()
    private let zoomCapsule = DesktopPad.glass()
    private let keyboardDisc = DesktopPad.glass()
    private let moreDisc = DesktopPad.glass()
    private let exitButton = UIButton(configuration: DesktopPad.buttonStyle())
    private let zoomOutButton = UIButton(configuration: DesktopPad.buttonStyle())
    private let zoomInButton = UIButton(configuration: DesktopPad.buttonStyle())
    private let resetButton = UIButton(configuration: DesktopPad.buttonStyle())
    private let moreButton = UIButton(configuration: DesktopPad.buttonStyle())
    /// What just happened that the page doesn't show, said for a moment on
    /// glass over the row, then gone (showStatus).
    private let statusPill = DesktopPad.glass()
    private let statusLabel = UILabel()
    private var statusHide: DispatchWorkItem?
    var exitRequested: (() -> Void)?
    var helpRequested: (() -> Void)?

    private var clicks = ClickCount()
    private var lastMove: CGPoint = .zero
    /// The end of the desktop the cursor was against as the finger came down (DesktopView.cursorEnd).
    private var movedFromEnd = 0
    private var lastHold: CGPoint = .zero
    private var holding = false
    private var lastScroll: CGPoint = .zero
    private var lastPinch: CGFloat = 1
    /// The zoom a pinch asks for, which may be past what the view goes to;
    /// and while it is, how much the page gives beyond the limit, around
    /// the fingers, in the stage's points. It springs back as they let go.
    private var askedZoom = 1.0
    private var give: CGFloat = 1
    private var giveAround: CGPoint = .zero
    private var glide: Momentum?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var minimapSoon: DispatchWorkItem?
    private var minimapTimer: Timer?
    /// Where the minimap is: a corner of the view, top right to start.
    private var minimapCorner = Corner(rawValue: UserDefaults.standard.string(forKey: "desktopMinimapCorner") ?? "") ?? .topRight
    private var minimapDragging = false
    private var minimapGrab: CGPoint = .zero
    private let pressFeel = UIImpactFeedbackGenerator(style: .light)

    private lazy var move = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
    private lazy var scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var click = UITapGestureRecognizer(target: self, action: #selector(clicked(_:)))
    private lazy var rightClick = UITapGestureRecognizer(target: self, action: #selector(rightClicked(_:)))
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
    /// Each touch as it lands, before any of the others can tell what it is.
    private let landing = TouchDown(target: nil, action: nil)
    /// Whether the fingers now down stopped a glide as they landed: then
    /// they click, hold and right-click nothing, as a touch that stops a
    /// scroll view presses nothing. Moved on, they move the cursor or scroll.
    private var caught = false

    init(page: Page, size: CGSize) {
        self.page = page
        desktop = DesktopView(viewWidth: Double(size.width), viewHeight: Double(size.height))
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityLabel = String(localized: "Trackpad View controls")
        typing.isAccessibilityElement = false
        cursor.isAccessibilityElement = false

        move.maximumNumberOfTouches = 1
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        rightClick.numberOfTouchesRequired = 2
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 12
        // A tap is a click once it can't be the start of a hold: at once
        // when the finger lifts, so nothing waits.
        click.require(toFail: hold)
        for recognizer in [move, scroll, pinch, click, rightClick, hold] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        // The others hear of a touch only once it moves, holds or lifts; a
        // finger put down to stop the page gliding does none of that.
        landing.landed = { [weak self] _ in
            guard let self else { return }
            self.caught = self.glide != nil
            self.stopGlide()
        }
        addGestureRecognizer(landing)

        addSubview(typing)
        addSubview(cursor)
        addSubview(minimap)
        configureControls()
        minimap.isHidden = UserDefaults.standard.bool(forKey: "desktopMinimapHidden")
        updateControlsMenu()
        minimap.dragged = { [weak self] pan in self?.dragMinimap(pan) }
        minimap.moved = { [weak self] x, y in
            guard let self else { return }
            self.desktop.center(onX: x * DesktopView.width, y: y * DesktopView.height)
            self.apply()
            self.cursorMoved()
        }
        keyboardButton.addAction(UIAction { [weak self] _ in self?.toggleKeyboard() }, for: .primaryActionTriggered)
        keyboardButton.accessibilityLabel = String(localized: "Keyboard")
        typing.typed = { [weak self] text, back in
            self?.lastTouched = CACurrentMediaTime()
            guard self?.page?.editing == true else { return }
            self?.page?.type(text, back: back)
        }
        typing.pressed = { [weak self] key in
            self?.lastTouched = CACurrentMediaTime()
            if key == "Hide" { self?.typing.resignFirstResponder() } else { self?.page?.press(key) }
        }
        typing.changed = { [weak self] in self?.updateKeyboardButton() }
        page.pointer?.changed = { [weak self] in self?.updateCursorPicture() }
        page.desktopFocusChanged = { [weak self] _ in self?.updateKeyboardButton() }
        page.desktopContextResult = { [weak self] kept in
            if kept { self?.cursor.pulse() }
            else { self?.showStatus(String(localized: "No menu here. Use normal browsing for link menus.")) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        updateCursorPicture()
        updateKeyboardButton()
        minimapTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] timer in
            // Gone without leave(), its window closed: the timer goes too.
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.refreshQuietMinimap() }
        }
        refreshMinimapSoon()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Done with: the page's own view as it was, nothing left running.
    func leave() {
        stopGlide()
        minimapTimer?.invalidate()
        minimapTimer = nil
        minimapSoon?.cancel()
        typing.resignFirstResponder()
        page?.pointer?.changed = nil
        page?.desktopFocusChanged = nil
        page?.desktopContextResult = nil
        if let view = page?.view { view.transform = .identity }
        removeFromSuperview()
    }

    // MARK: Where everything goes

    /// The pad over `frame` of the stage, the page view placed under it as
    /// the desktop view says.
    /// `covered`: the bottom the phone bar covers. The page goes on under
    /// it, as every page does there; the cursor, the view and the buttons
    /// keep above it.
    func layout(in frame: CGRect, covered bar: CGFloat) {
        if self.frame != frame { self.frame = frame }
        if desktop.viewWidth != Double(frame.width) || desktop.viewHeight != Double(frame.height) {
            desktop.resize(viewWidth: Double(frame.width), viewHeight: Double(frame.height))
        }
        barCovered = bar
        updateCover()
        apply()
        if !minimapDragging { minimap.frame = minimapFrame(at: minimapCorner) }
        layoutKeyboardButton()
    }

    // MARK: The minimap's corner

    private enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The minimap in `corner`, clear of the keyboard and, bottom right, of
    /// the keyboard button.
    private func minimapFrame(at corner: Corner) -> CGRect {
        let inset: CGFloat = 12
        let width: CGFloat = 112
        let size = CGSize(width: width, height: width * CGFloat(DesktopView.height / DesktopView.width))
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let bottom = bounds.height - CGFloat(desktop.covered) - inset
        return CGRect(x: left ? inset : bounds.width - size.width - inset,
                      y: top ? inset : max(inset, bottom - size.height),
                      width: size.width, height: size.height)
    }

    /// The minimap follows the finger from where it was grabbed, and on
    /// letting go goes to the corner nearest where the throw would come to
    /// rest, at the speed the finger had, as a picture in picture does.
    private func dragMinimap(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            // Caught on its way to a corner: from where it is now.
            if let now = minimap.layer.presentation()?.position { minimap.layer.position = now }
            minimap.layer.removeAllAnimations()
            minimapDragging = true
            minimapGrab = minimap.center
            minimap.active(true)
        case .changed:
            let moved = pan.translation(in: self)
            minimap.center = CGPoint(x: minimapGrab.x + moved.x, y: minimapGrab.y + moved.y)
        case .ended, .cancelled, .failed:
            minimapDragging = false
            let velocity = pan.velocity(in: self)
            // Where a throw would carry it, as a scroll's flick does.
            let resting = CGPoint(x: minimap.center.x + Throw.carry(velocity.x), y: minimap.center.y + Throw.carry(velocity.y))
            let corner = Corner.allCases.min {
                let a = minimapFrame(at: $0), b = minimapFrame(at: $1)
                return hypot(a.midX - resting.x, a.midY - resting.y) < hypot(b.midX - resting.x, b.midY - resting.y)
            } ?? minimapCorner
            minimapCorner = corner
            UserDefaults.standard.set(corner.rawValue, forKey: "desktopMinimapCorner")
            updateControlsMenu()
            let target = minimapFrame(at: corner)
            let distance = hypot(target.midX - minimap.center.x, target.midY - minimap.center.y)
            let speed = hypot(velocity.x, velocity.y)
            UIView.animate(springDuration: 0.4, bounce: 0, initialSpringVelocity: distance > 1 ? speed / distance : 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.minimap.center = CGPoint(x: target.midX, y: target.midY)
            }
            minimap.active(false)
        default:
            break
        }
    }

    /// The row's height: a finger's, as the phone bar's buttons are.
    private let controlsHeight: CGFloat = 44
    private static let controlGap: CGFloat = 10

    private func layoutKeyboardButton() {
        let side = controlsHeight
        let capsule = side * 3 + 8
        let gap = Self.controlGap
        let width = side * 3 + capsule + gap * 3
        // Browser's phone-bar backdrop begins 24 points above the bar.
        let barClearance = barCovered > 0 ? barCovered + 24 : 0
        let above = max(barClearance, keyboardCovered)
        controls.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: max(0, bounds.height - above - side - 8),
                                width: width, height: side)
        var x: CGFloat = 0
        for (glass, room) in [(exitDisc, side), (zoomCapsule, capsule), (keyboardDisc, side), (moreDisc, side)] {
            glass.frame = CGRect(x: x, y: 0, width: room, height: side)
            x += room + gap
        }
        for (index, button) in [zoomOutButton, resetButton, zoomInButton].enumerated() {
            button.frame = CGRect(x: 4 + CGFloat(index) * side, y: 0, width: side, height: side)
        }
        for (button, disc) in [(exitButton, exitDisc), (keyboardButton, keyboardDisc), (moreButton, moreDisc)] {
            button.frame = disc.bounds
        }
        layoutStatus()
    }

    /// The pill as wide as its words, centred over the row, 8 points above it.
    private func layoutStatus() {
        let room = max(bounds.width - 32, 1)
        let size = statusLabel.sizeThatFits(CGSize(width: room - 28, height: .greatestFiniteMagnitude))
        let width = min(ceil(size.width) + 28, room)
        let height = max(ceil(size.height) + 14, 32)
        statusPill.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        statusPill.center = CGPoint(x: controls.frame.midX, y: controls.frame.minY - 8 - height / 2)
        statusLabel.frame = statusPill.bounds.insetBy(dx: 14, dy: 7)
        Self.round(statusPill, height: height)
    }

    private func configureControls() {
        addSubview(controls)
        for (glass, buttons) in [(exitDisc, [exitButton]), (zoomCapsule, [zoomOutButton, resetButton, zoomInButton]),
                                 (keyboardDisc, [keyboardButton]), (moreDisc, [moreButton])] {
            controls.addSubview(glass)
            Self.round(glass, height: controlsHeight)
            for button in buttons { glass.contentView.addSubview(button) }
        }
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 2
        statusPill.contentView.addSubview(statusLabel)
        statusPill.alpha = 0
        statusPill.isUserInteractionEnabled = false
        addSubview(statusPill)
        let exit = exitButton
        configure(exit, symbol: "xmark", label: String(localized: "Exit Trackpad View")) { [weak self] in self?.exitRequested?() }
        configure(zoomOutButton, symbol: "minus.magnifyingglass", label: String(localized: "Zoom Out")) { [weak self] in self?.changeZoom(by: 0.8) }
        configure(resetButton, symbol: "arrow.counterclockwise", label: String(localized: "Reset Zoom")) { [weak self] in
            guard let self else { return }
            self.stopGlide()
            self.desktop.resetZoom()
            self.apply()
        }
        configure(zoomInButton, symbol: "plus.magnifyingglass", label: String(localized: "Zoom In")) { [weak self] in self?.changeZoom(by: 1.25) }
        keyboardButton.configuration?.image = UIImage(systemName: "keyboard")
        // The page's menu's own sign, as the phone bar's … disc has it.
        moreButton.configuration?.image = UIImage(systemName: "ellipsis")
        moreButton.accessibilityLabel = String(localized: "Trackpad View Help and Options")
        moreButton.showsMenuAsPrimaryAction = true
        updateControlsMenu()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: DesktopPad, _) in
            self.layoutKeyboardButton()
        }
    }

    /// Glass, as the phone bar's discs and capsules are: Liquid Glass, or a
    /// thin material before iOS 26. Rounded to a capsule by `round`.
    private static func glass() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            return glass
        }
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        blur.clipsToBounds = true
        blur.layer.cornerCurve = .continuous
        return blur
    }

    private static func round(_ glass: UIVisualEffectView, height: CGFloat) {
        if #available(iOS 26.0, *) {
            glass.cornerConfiguration = .corners(radius: .fixed(height / 2))
        } else {
            glass.layer.cornerRadius = height / 2
        }
    }

    private func configure(_ button: UIButton, symbol: String, label: String, action: @escaping () -> Void) {
        button.configuration?.image = UIImage(systemName: symbol)
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    }

    private func changeZoom(by factor: Double) {
        stopGlide()
        desktop.zoom(by: factor, aroundX: desktop.viewWidth / 2, y: max(desktop.viewHeight - desktop.covered, 1) / 2)
        apply()
        cursorMoved()
    }

    private func updateControlsMenu() {
        let help = UIAction(title: String(localized: "Trackpad View Help"), image: UIImage(systemName: "questionmark.circle")) { [weak self] _ in self?.helpRequested?() }
        let menu = UIAction(title: String(localized: "Secondary Click at Cursor"), image: UIImage(systemName: "cursorarrow.click.2")) { [weak self] _ in self?.secondaryClick() }
        let hide = UIAction(title: minimap.isHidden ? String(localized: "Show Minimap") : String(localized: "Hide Minimap"), image: UIImage(systemName: "map")) { [weak self] _ in
            guard let self else { return }
            self.minimap.isHidden.toggle()
            UserDefaults.standard.set(self.minimap.isHidden, forKey: "desktopMinimapHidden")
            self.updateControlsMenu()
            if !self.minimap.isHidden { self.refreshMinimapSoon() }
        }
        let corners = Corner.allCases.map { corner in
            let names: [Corner: String] = [.topLeft: String(localized: "Top Left"), .topRight: String(localized: "Top Right"),
                                           .bottomLeft: String(localized: "Bottom Left"), .bottomRight: String(localized: "Bottom Right")]
            return UIAction(title: names[corner] ?? String(localized: "Corner"), state: corner == minimapCorner ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.minimapCorner = corner
                UserDefaults.standard.set(corner.rawValue, forKey: "desktopMinimapCorner")
                self.minimap.frame = self.minimapFrame(at: corner)
                self.updateControlsMenu()
            }
        }
        moreButton.menu = UIMenu(children: [help, menu, hide, UIMenu(title: String(localized: "Minimap Position"), children: corners)])
    }

    /// Said for a moment over the row, and to VoiceOver: in from 4 points
    /// below with a fade, out the same way, quicker; a fade alone with
    /// Reduce Motion.
    private func showStatus(_ text: String) {
        statusLabel.text = text
        layoutStatus()
        let still = UIAccessibility.isReduceMotionEnabled
        let shown = statusPill.alpha > 0
        if !shown { statusPill.transform = still ? .identity : CGAffineTransform(translationX: 0, y: 4) }
        UIView.animate(springDuration: 0.25, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.statusPill.alpha = 1
            self.statusPill.transform = .identity
        }
        UIAccessibility.post(notification: .announcement, argument: text)
        statusHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.statusPill.alpha = 0
                if !still { self.statusPill.transform = CGAffineTransform(translationX: 0, y: 4) }
            }
        }
        statusHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: hide)
    }

    /// The page view, the cursor and the minimap where the desktop view has
    /// them now, with no animation: they follow the finger.
    private func apply() {
        guard let view = page?.view else { return }
        resetButton.accessibilityValue = String(localized: "\(Int((desktop.zoom * 100).rounded())) percent")
        zoomOutButton.isEnabled = desktop.zoom > desktop.fitZoom + 0.001
        zoomInButton.isEnabled = desktop.zoom < DesktopView.maxZoom - 0.001
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = CGSize(width: DesktopView.width, height: DesktopView.height)
        if view.bounds.size != size { view.bounds = CGRect(origin: .zero, size: size) }
        placePage(view)
        let point = desktop.viewPoint(x: desktop.cursorX, y: desktop.cursorY)
        cursor.place(at: CGPoint(x: point.x, y: point.y))
        let shown = desktop.shown
        minimap.show(shown, cursorX: desktop.cursorX / DesktopView.width, cursorY: desktop.cursorY / DesktopView.height)
        page?.desktopShown = CGRect(x: shown.x * DesktopView.width, y: shown.y * DesktopView.height,
                                    width: shown.width * DesktopView.width, height: shown.height * DesktopView.height)
        CATransaction.commit()
    }

    /// The page view at the desktop view's zoom and origin, with the give
    /// past a zoom limit around the fingers.
    private func placePage(_ view: UIView) {
        let size = CGSize(width: DesktopView.width, height: DesktopView.height)
        let zoom = CGFloat(desktop.zoom)
        view.transform = CGAffineTransform(scaleX: zoom * give, y: zoom * give)
        // The page view is the pad's sibling on the stage, so in the stage's points.
        let center = CGPoint(x: frame.minX + (size.width / 2 - CGFloat(desktop.originX)) * zoom,
                             y: frame.minY + (size.height / 2 - CGFloat(desktop.originY)) * zoom)
        view.center = CGPoint(x: giveAround.x + (center.x - giveAround.x) * give,
                              y: giveAround.y + (center.y - giveAround.y) * give)
    }

    /// A pinch let go past a zoom limit: the page springs back to it.
    private func springBack() {
        guard give != 1 else { return }
        give = 1
        guard let view = page?.view else { return }
        guard !UIAccessibility.isReduceMotionEnabled else { return placePage(view) }
        UIView.animate(springDuration: 0.35, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.placePage(view)
        }
    }

    /// Where the cursor is, in the page view's points: the desktop's.
    private var cursorPoint: CGPoint {
        CGPoint(x: desktop.cursorX, y: desktop.cursorY)
    }

    private func cursorMoved(buttons: Int = 0) {
        page?.pointer("move", at: cursorPoint, buttons: buttons)
    }

    // MARK: The trackpad

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two fingers can scroll and zoom at once, as on a map.
        (gestureRecognizer === scroll && other === pinch) || (gestureRecognizer === pinch && other === scroll)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // The minimap and the keyboard button take their own touches.
        let point = gestureRecognizer.location(in: self)
        return (minimap.isHidden || !minimap.frame.contains(point))
            && ![exitDisc, zoomCapsule, keyboardDisc, moreDisc].contains { $0.frame.contains(convert(point, to: controls)) }
    }

    @objc private func moved(_ pan: UIPanGestureRecognizer) {
        let moved = pan.translation(in: self)
        switch pan.state {
        case .began:
            stopGlide()
            lastMove = .zero
            movedFromEnd = desktop.cursorEnd
            minimap.active(true)
        case .changed:
            let velocity = pan.velocity(in: self)
            let push = desktop.moveCursor(dx: Double(moved.x - lastMove.x), dy: Double(moved.y - lastMove.y),
                                          speed: Double(hypot(velocity.x, velocity.y)),
                                          scale: Session.shared.preferences.cursorSpeed)
            lastMove = moved
            apply()
            // Past the desktop's top or bottom the cursor can't go, so the
            // page scrolls by as much: what is further down comes up to it.
            wheel(dx: 0, dy: push)
            cursorMoved()
        case .ended, .cancelled, .failed:
            // A flick that set out from the desktop's end, to scroll, glides
            // on as two fingers' does. One that only got there stops with
            // the finger: a cursor sent down to a button at the bottom
            // shouldn't send the page off as well.
            let velocity = pan.velocity(in: self)
            if pan.state == .ended, movedFromEnd != 0, desktop.cursorEnd == movedFromEnd,
               Double(velocity.y) * Double(movedFromEnd) > 0, abs(velocity.y) > abs(velocity.x) {
                let travel = desktop.travel(speed: Double(hypot(velocity.x, velocity.y)),
                                            scale: Session.shared.preferences.cursorSpeed)
                let speed = Momentum(velocityX: 0, velocityY: Double(velocity.y) * travel)
                if !speed.isDone { startGlide(speed) }
            }
            minimap.active(false)
            refreshMinimapSoon()
        default:
            break
        }
    }

    @objc private func clicked(_ tap: UITapGestureRecognizer) {
        guard !caught else { return }
        stopGlide()
        let at = tap.location(in: self)
        let count = clicks.click(at: CACurrentMediaTime(), x: Double(at.x), y: Double(at.y))
        page?.pointer("click", at: cursorPoint, detail: count)
        cursor.pulse()
        refreshMinimapSoon()
    }

    @objc private func rightClicked(_ tap: UITapGestureRecognizer) {
        guard !caught else { return }
        secondaryClick()
    }

    private func secondaryClick() {
        stopGlide()
        page?.pointer("context", at: cursorPoint)
    }

    /// Touch and hold, then move: the button goes down where the cursor is
    /// and stays down until the finger lifts. A light tap says it is down.
    @objc private func held(_ press: UILongPressGestureRecognizer) {
        guard !caught || holding else { return }
        let at = press.location(in: self)
        switch press.state {
        case .began:
            stopGlide()
            holding = true
            lastHold = at
            pressFeel.impactOccurred()
            cursor.pressed(true)
            minimap.active(true)
            page?.pointer("down", at: cursorPoint, buttons: 1, detail: 1)
        case .changed:
            // One to one while dragging: a drag aims at where it lets go.
            let push = desktop.moveCursor(dx: Double(at.x - lastHold.x), dy: Double(at.y - lastHold.y), speed: 0,
                                          scale: Session.shared.preferences.cursorSpeed)
            lastHold = at
            apply()
            // A drag pushed past the desktop's end scrolls too, as a
            // selection dragged to a window's edge does.
            wheel(dx: 0, dy: push)
            cursorMoved(buttons: 1)
        case .ended, .cancelled, .failed:
            guard holding else { return }
            holding = false
            cursor.pressed(false)
            minimap.active(false)
            page?.pointer("up", at: cursorPoint, detail: 1)
            refreshMinimapSoon()
        default:
            break
        }
    }

    /// Two fingers: wheel events at the cursor, the page following the
    /// fingers as a trackpad's natural scrolling has it; a flick glides on.
    @objc private func scrolled(_ pan: UIPanGestureRecognizer) {
        let moved = pan.translation(in: self)
        switch pan.state {
        case .began:
            stopGlide()
            lastScroll = .zero
        case .changed:
            let step = CGPoint(x: moved.x - lastScroll.x, y: moved.y - lastScroll.y)
            lastScroll = moved
            // While the fingers mostly pinch, they don't also scroll.
            if pinch.state == .changed && abs(pinch.scale - 1) > 0.04 { return }
            wheel(dx: -Double(step.x) / desktop.zoom, dy: -Double(step.y) / desktop.zoom)
        case .ended:
            let velocity = pan.velocity(in: self)
            let speed = Momentum(velocityX: -Double(velocity.x) / desktop.zoom, velocityY: -Double(velocity.y) / desktop.zoom)
            if !speed.isDone { startGlide(speed) }
            refreshMinimapSoon()
        default:
            break
        }
    }

    private func wheel(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        // A point inside the page: on the desktop's last row or column
        // nothing is under the cursor, and what it is over would never
        // hear of the scroll.
        let at = CGPoint(x: min(desktop.cursorX, DesktopView.width - 1), y: min(desktop.cursorY, DesktopView.height - 1))
        // Reaching: the cursor is where the last move left it, and pushed to the view's top or
        // bottom it is on whatever bar the page keeps there, with nothing under it to scroll.
        page?.wheel(at: at, dx: dx, dy: dy, modifiers: [], zoom: false, guarded: "scroll", reaching: true) { [weak self] outcome in
            // A page the bridge is not in (a PDF) is scrolled as its own view is.
            if outcome == "absent" { self?.page?.nudge(dx: dx, dy: dy) }
        }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            stopGlide()
            lastPinch = 1
            askedZoom = desktop.zoom
            minimap.active(true)
        case .changed:
            let at = pinch.location(in: self)
            askedZoom *= Double(pinch.scale / lastPinch)
            lastPinch = pinch.scale
            // The view goes as far as its limits allow (DesktopView.zoom); a
            // pinch back from past one takes back the give first.
            desktop.zoom(by: askedZoom / desktop.zoom, aroundX: Double(at.x), y: Double(at.y))
            // Past a limit the page gives a little, the less the further, as
            // a scroll view's edge does, rather than stopping dead.
            let past = log(askedZoom / desktop.zoom)
            give = CGFloat(exp(Throw.rubberband(past, range: log(1.12))))
            giveAround = CGPoint(x: frame.minX + at.x, y: frame.minY + at.y)
            apply()
        case .ended, .cancelled, .failed:
            springBack()
            minimap.active(false)
            cursorMoved()
        default:
            break
        }
    }

    // MARK: The glide after a flick

    private func startGlide(_ momentum: Momentum) {
        glide = momentum
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopGlide() {
        glide = nil
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard var glide, let step = glide.advance(by: now - lastTick) else {
            stopGlide()
            refreshMinimapSoon()
            return
        }
        self.glide = glide
        wheel(dx: step.x, dy: step.y)
    }

    // MARK: The cursor's picture

    /// The page's own cursor when it has one (Figma's arrow, its tools'),
    /// the one CSS names when it names one (a hand over a link, the beam
    /// over text, arrows to resize), the arrow otherwise; none for `cursor: none`.
    private func updateCursorPicture() {
        let pointer = page?.pointer
        if pointer?.hidden == true {
            cursor.show(.hidden)
        } else if let picture = pointer?.picture {
            cursor.show(.picture(picture.image, size: picture.size, hotspot: picture.hotspot))
        } else if let name = pointer?.keyword, let drawn = KeywordCursor.picture(for: name) {
            cursor.show(.picture(drawn.image, size: drawn.size, hotspot: drawn.hotspot))
        } else {
            cursor.show(.arrow)
        }
    }

    // MARK: The minimap

    /// When the page was last touched through the pad, or typed in.
    private var lastTouched = CACurrentMediaTime()

    /// The minimap taken again by the clock: for a while after the page was
    /// touched, for what it goes on doing by itself, and while it loads. A
    /// picture of the page every two and a half seconds for as long as the
    /// desktop view was up, touched or not, kept WebKit drawing for nothing.
    private func refreshQuietMinimap() {
        guard CACurrentMediaTime() - lastTouched < 15 || page?.view.isLoading == true else { return }
        refreshMinimap()
    }

    private func refreshMinimapSoon() {
        lastTouched = CACurrentMediaTime()
        minimapSoon?.cancel()
        let soon = DispatchWorkItem { [weak self] in self?.refreshMinimap() }
        minimapSoon = soon
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: soon)
    }

    private func refreshMinimap() {
        guard !minimap.isHidden else { return }
        page?.preview(width: minimap.bounds.width) { [weak self] image in
            if let image { self?.minimap.image = image }
        }
    }

    // MARK: Typing

    private func toggleKeyboard() {
        if typing.isFirstResponder { typing.resignFirstResponder() }
        else if page?.editing == true { typing.becomeFirstResponder() }
        else { showStatus(String(localized: "Click a text field before opening the keyboard.")) }
    }

    private func updateKeyboardButton() {
        if page?.editing != true, typing.isFirstResponder { typing.resignFirstResponder() }
        let up = typing.isFirstResponder
        let focused = page?.editing == true
        // Never greyed out: with no field clicked it is quieter, and a tap
        // says what to do first (toggleKeyboard), where a disabled button
        // would say nothing.
        keyboardButton.configuration?.baseForegroundColor = focused || up ? .label : .tertiaryLabel
        keyboardButton.accessibilityHint = focused ? String(localized: "Types into the selected page field") : String(localized: "Click a text field on the page first")
        keyboardButton.configuration?.image = UIImage(systemName: up ? "keyboard.chevron.compact.down" : "keyboard")
        keyboardButton.accessibilityLabel = up ? String(localized: "Hide Keyboard") : String(localized: "Keyboard")
    }

    /// What covers the bottom of the view: the bar, or the keyboard over it.
    private var barCovered: CGFloat = 0
    private var keyboardCovered: CGFloat = 0

    private func updateCover() {
        desktop.cover(bottom: Double(max(barCovered, keyboardCovered) + controlsHeight + 16))
    }

    /// The keyboard covers the bottom of the view: the cursor stays above
    /// it, and so does the keyboard button, at the keyboard's own pace.
    @objc private func keyboardChanged(_ note: Notification) {
        guard let window, let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboard = convert(window.convert(end, from: nil), from: window)
        let covered = max(0, bounds.maxY - keyboard.minY)
        // Only the keyboard this view brought up; the address's is the bar's.
        keyboardCovered = typing.isFirstResponder || covered == 0 ? covered : 0
        updateCover()
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        // On the keyboard's own curve, so they stay on its top edge all the way.
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curve << 16)]) {
            self.layoutKeyboardButton()
            if !self.minimapDragging { self.minimap.frame = self.minimapFrame(at: self.minimapCorner) }
        }
        apply()
        updateKeyboardButton()
    }

    /// A plain symbol on the glass it sits on: the glass is the disc's or
    /// the capsule's, so the zoom's three share one, as back and forward do
    /// on the phone bar. Dimmed a little while pressed.
    private static func buttonStyle() -> UIButton.Configuration {
        var style = UIButton.Configuration.plain()
        style.baseForegroundColor = .label
        style.contentInsets = .zero
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        return style
    }
}

// MARK: CSS's own cursors

/// The cursors CSS names, drawn as a Mac draws them, black with a white
/// edge so they show on anything: the system's symbols for most, the text
/// beam and the crosshair drawn line by line, each once. The names WebKit
/// has no picture for here (copy, alias, context-menu) are the arrow.
@MainActor
enum KeywordCursor {
    struct Drawn {
        let image: UIImage
        let size: CGSize
        let hotspot: CGPoint
    }

    private static var drawn: [String: Drawn] = [:]
    private static let edge: CGFloat = 1.5

    static func picture(for name: String) -> Drawn? {
        if let known = drawn[name] { return known }
        guard let made = make(name) else { return nil }
        drawn[name] = made
        return made
    }

    private static func make(_ name: String) -> Drawn? {
        switch name {
        case "pointer": return symbol("hand.point.up.left.fill", size: 21, hotspot: CGPoint(x: 0.19, y: 0.1))
        case "text": return beam(vertical: false)
        case "vertical-text": return beam(vertical: true)
        case "crosshair": return cross(thin: true)
        case "cell": return cross(thin: false)
        case "move", "all-scroll": return symbol("arrow.up.and.down.and.arrow.left.and.right", size: 20)
        case "grab", "grabbing": return symbol("hand.raised.fill", size: name == "grab" ? 20 : 18)
        case "not-allowed", "no-drop": return symbol("nosign", size: 18)
        case "wait", "progress": return symbol("hourglass", size: 18)
        case "help": return symbol("questionmark.circle.fill", size: 18)
        case "zoom-in": return symbol("plus.magnifyingglass", size: 19, hotspot: CGPoint(x: 0.4, y: 0.4))
        case "zoom-out": return symbol("minus.magnifyingglass", size: 19, hotspot: CGPoint(x: 0.4, y: 0.4))
        case "ew-resize", "e-resize", "w-resize", "col-resize": return symbol("arrow.left.and.right", size: 19)
        case "ns-resize", "n-resize", "s-resize", "row-resize": return symbol("arrow.up.and.down", size: 19)
        case "nwse-resize", "nw-resize", "se-resize": return symbol("arrow.up.left.and.arrow.down.right", size: 17)
        case "nesw-resize", "ne-resize", "sw-resize": return symbol("arrow.down.left.and.arrow.up.right", size: 17)
        default: return nil
        }
    }

    /// A symbol, white round its edge and black inside; the hotspot as a
    /// share of the symbol's size, its middle unless said.
    private static func symbol(_ name: String, size: CGFloat, hotspot: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Drawn? {
        let shape = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let glyph = UIImage(systemName: name, withConfiguration: shape) else { return nil }
        let pad = edge + 1
        let box = CGSize(width: glyph.size.width + pad * 2, height: glyph.size.height + pad * 2)
        let white = glyph.withTintColor(.white, renderingMode: .alwaysOriginal)
        let black = glyph.withTintColor(.black, renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: box).image { _ in
            for dx in [-edge, 0, edge] {
                for dy in [-edge, 0, edge] where dx != 0 || dy != 0 {
                    white.draw(at: CGPoint(x: pad + dx, y: pad + dy))
                }
            }
            black.draw(at: CGPoint(x: pad, y: pad))
        }
        return Drawn(image: image, size: box,
                     hotspot: CGPoint(x: pad + glyph.size.width * hotspot.x, y: pad + glyph.size.height * hotspot.y))
    }

    /// The text beam: a stem with a short bar at each end, its middle the hotspot.
    private static func beam(vertical: Bool) -> Drawn {
        let long: CGFloat = 18
        let bar: CGFloat = 7
        let box = CGSize(width: vertical ? long + 6 : bar + 6, height: vertical ? bar + 6 : long + 6)
        let image = UIGraphicsImageRenderer(size: box).image { context in
            let path = UIBezierPath()
            let mid = CGPoint(x: box.width / 2, y: box.height / 2)
            if vertical {
                path.move(to: CGPoint(x: mid.x - long / 2, y: mid.y))
                path.addLine(to: CGPoint(x: mid.x + long / 2, y: mid.y))
                for x in [mid.x - long / 2, mid.x + long / 2] {
                    path.move(to: CGPoint(x: x, y: mid.y - bar / 2))
                    path.addLine(to: CGPoint(x: x, y: mid.y + bar / 2))
                }
            } else {
                path.move(to: CGPoint(x: mid.x, y: mid.y - long / 2))
                path.addLine(to: CGPoint(x: mid.x, y: mid.y + long / 2))
                for y in [mid.y - long / 2, mid.y + long / 2] {
                    path.move(to: CGPoint(x: mid.x - bar / 2, y: y))
                    path.addLine(to: CGPoint(x: mid.x + bar / 2, y: y))
                }
            }
            stroke(path, in: context.cgContext)
        }
        return Drawn(image: image, size: box, hotspot: CGPoint(x: box.width / 2, y: box.height / 2))
    }

    /// A cross: thin for the crosshair, thick for a cell.
    private static func cross(thin: Bool) -> Drawn {
        let arm: CGFloat = thin ? 9 : 7
        let box = CGSize(width: arm * 2 + 6, height: arm * 2 + 6)
        let image = UIGraphicsImageRenderer(size: box).image { context in
            let path = UIBezierPath()
            let mid = CGPoint(x: box.width / 2, y: box.height / 2)
            path.move(to: CGPoint(x: mid.x - arm, y: mid.y))
            path.addLine(to: CGPoint(x: mid.x + arm, y: mid.y))
            path.move(to: CGPoint(x: mid.x, y: mid.y - arm))
            path.addLine(to: CGPoint(x: mid.x, y: mid.y + arm))
            stroke(path, in: context.cgContext, width: thin ? 1.5 : 3)
        }
        return Drawn(image: image, size: box, hotspot: CGPoint(x: box.width / 2, y: box.height / 2))
    }

    private static func stroke(_ path: UIBezierPath, in context: CGContext, width: CGFloat = 1.5) {
        path.lineCapStyle = .square
        UIColor.white.setStroke()
        path.lineWidth = width + edge * 2
        path.stroke()
        UIColor.black.setStroke()
        path.lineWidth = width
        path.stroke()
    }
}

// MARK: The cursor

/// The cursor the finger moves: the page's own picture, or an arrow drawn
/// as a Mac's is, black with a white edge so it shows on anything. It stays
/// the same size on screen whatever the zoom, as a pointer does.
private final class CursorView: UIView {
    enum Look {
        case arrow
        case picture(UIImage, size: CGSize, hotspot: CGPoint)
        case hidden
    }

    private let arrow = CAShapeLayer()
    private let image = UIImageView()
    private var hotspot: CGPoint = .zero
    private var point: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let path = UIBezierPath()
        let corners: [CGPoint] = [(0, 0), (0, 17), (4.3, 13.1), (7.1, 19.4), (9.6, 18.3), (6.9, 12.2), (12.4, 12.2)]
            .map { CGPoint(x: $0.0 * 1.1, y: $0.1 * 1.1) }
        path.move(to: corners[0])
        corners.dropFirst().forEach { path.addLine(to: $0) }
        path.close()
        arrow.path = path.cgPath
        arrow.fillColor = UIColor.black.cgColor
        arrow.strokeColor = UIColor.white.cgColor
        arrow.lineWidth = 1.4
        arrow.lineJoin = .round
        arrow.shadowColor = UIColor.black.cgColor
        arrow.shadowOpacity = 0.3
        arrow.shadowRadius = 2
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(arrow)
        addSubview(image)
        // Placed and scaled from the top left, where the arrow points.
        layer.anchorPoint = .zero
        show(.arrow)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(_ look: Look) {
        switch look {
        case .arrow:
            arrow.isHidden = false
            image.isHidden = true
            hotspot = .zero
            bounds = CGRect(x: 0, y: 0, width: 14, height: 22)
        case .picture(let picture, let size, let spot):
            arrow.isHidden = true
            image.isHidden = false
            image.image = picture
            image.frame = CGRect(origin: .zero, size: size)
            hotspot = spot
            bounds = CGRect(origin: .zero, size: size)
        case .hidden:
            arrow.isHidden = true
            image.isHidden = true
        }
        place(at: point)
    }

    /// The hotspot at `point`, in the pad's points.
    func place(at point: CGPoint) {
        self.point = point
        frame.origin = CGPoint(x: point.x - hotspot.x, y: point.y - hotspot.y)
    }

    /// A click shows: the cursor gives a little and comes back, from its tip.
    func pulse() {
        layer.removeAnimation(forKey: "pulse")
        let give = CAKeyframeAnimation(keyPath: "transform.scale")
        give.values = [1, 0.85, 1]
        give.keyTimes = [0, 0.35, 1]
        give.duration = 0.18
        layer.add(give, forKey: "pulse")
    }

    /// Held down: a little smaller while the button is.
    func pressed(_ down: Bool) {
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = down ? CGAffineTransform(scaleX: 0.85, y: 0.85) : .identity
        }
    }

}

// MARK: The minimap

/// All of the desktop, small and see-through: in colour where it shows, in
/// black and white and fainter elsewhere, so what shows stands out, with a
/// frame round it and a dot for the cursor. A tap goes there; a drag moves
/// the minimap itself (DesktopPad.dragMinimap).
private final class Minimap: UIView {
    private let backdrop: UIVisualEffectView
    /// The whole desktop in black and white, under the part that shows in colour.
    private let plain = UIImageView()
    private let colour = UIImageView()
    private let colourShown = CALayer()
    private let shown = UIView()
    private let dot = UIView()
    var moved: ((Double, Double) -> Void)?
    var dragged: ((UIPanGestureRecognizer) -> Void)?

    private static let context = CIContext()

    var image: UIImage? {
        didSet {
            colour.image = image
            plain.image = image.flatMap(Self.blackAndWhite)
        }
    }

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            backdrop = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        backdrop.layer.cornerRadius = 10
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        for picture in [plain, colour] {
            picture.contentMode = .scaleAspectFill
            picture.clipsToBounds = true
            picture.layer.cornerRadius = 7
            picture.layer.cornerCurve = .continuous
            backdrop.contentView.addSubview(picture)
        }
        // Faint enough to recede behind the part in colour, not so faint the page shows through it.
        plain.alpha = 0.7
        colourShown.backgroundColor = UIColor.black.cgColor
        colourShown.cornerRadius = 3
        colour.layer.mask = colourShown
        shown.layer.borderColor = UIColor.white.cgColor
        shown.layer.borderWidth = 1.5
        shown.layer.cornerRadius = 3
        shown.layer.shadowColor = UIColor.black.cgColor
        shown.layer.shadowOpacity = 0.35
        shown.layer.shadowRadius = 2
        shown.layer.shadowOffset = .zero
        addSubview(shown)
        dot.backgroundColor = .white
        dot.layer.borderColor = UIColor.black.withAlphaComponent(0.6).cgColor
        dot.layer.borderWidth = 1
        dot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        dot.layer.cornerRadius = 3
        addSubview(dot)
        alpha = 0.75
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Minimap")
        accessibilityHint = String(localized: "Shows where on the page you are. Tap to go there; drag to move it to another corner.")
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        plain.frame = area
        colour.frame = area
    }

    private var area: CGRect {
        bounds.insetBy(dx: 3, dy: 3)
    }

    /// What shows, as fractions of the desktop, and the cursor.
    func show(_ part: (x: Double, y: Double, width: Double, height: Double), cursorX: Double, cursorY: Double) {
        let area = self.area
        let frame = CGRect(x: area.minX + area.width * part.x, y: area.minY + area.height * part.y,
                           width: max(6, area.width * part.width), height: max(6, area.height * part.height))
        shown.frame = frame
        colourShown.frame = frame.offsetBy(dx: -area.minX, dy: -area.minY)
        dot.center = CGPoint(x: area.minX + area.width * cursorX, y: area.minY + area.height * cursorY)
    }

    /// Clearer while the view or the minimap moves, fainter at rest, so the page shows through.
    func active(_ on: Bool) {
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = on ? 1 : 0.75
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let area = self.area
        moved?(Double(min(max((point.x - area.minX) / area.width, 0), 1)),
               Double(min(max((point.y - area.minY) / area.height, 0), 1)))
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        dragged?(pan)
    }

    private static func blackAndWhite(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image), let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        filter.setValue(1.1, forKey: kCIInputContrastKey)
        guard let output = filter.outputImage, let made = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: made, scale: image.scale, orientation: image.imageOrientation)
    }
}

// MARK: Typing

/// The field the phone's keyboard types into in the desktop view, out of
/// sight: what changes in it goes to the page as characters taken away and
/// characters put in, so a keyboard that builds a character in steps (a
/// Korean syllable) reaches the page as it does a field. Return, Backspace
/// on nothing, and the keys over the keyboard go as keys.
private final class DesktopTyping: UITextField, UITextFieldDelegate {
    var typed: ((String, Int) -> Void)?
    var pressed: ((String) -> Void)?
    var changed: (() -> Void)?
    /// What the page has been given of this field's text.
    private var sent = ""

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        alpha = 0.02
        tintColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        delegate = self
        addTarget(self, action: #selector(edited), for: .editingChanged)
        inputAccessoryView = KeysBar { [weak self] key in self?.pressed?(key) }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func becomeFirstResponder() -> Bool {
        text = ""
        sent = ""
        let became = super.becomeFirstResponder()
        changed?()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        changed?()
        return resigned
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty { pressed?("Backspace") } else { super.deleteBackward() }
    }

    @objc private func edited() {
        let now = text ?? ""
        let same = zip(sent, now).prefix { $0 == $1 }.count
        let back = sent.count - same
        let added = String(now.dropFirst(same))
        if back > 0 || !added.isEmpty { typed?(added, back) }
        sent = now
        // Kept short, but never in the middle of a character being built.
        if markedTextRange == nil, now.count > 24 {
            text = ""
            sent = ""
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        pressed?("Enter")
        return false
    }
}

/// The keys a phone's keyboard lacks, over it: Escape, Tab and the arrows,
/// and one to put the keyboard away.
private final class KeysBar: UIInputView {
    init(press: @escaping (String) -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let keys: [(String, String?, String)] = [
            ("esc", nil, "Escape"), ("tab", nil, "Tab"),
            ("", "arrow.left", "ArrowLeft"), ("", "arrow.up", "ArrowUp"),
            ("", "arrow.down", "ArrowDown"), ("", "arrow.right", "ArrowRight"),
            ("", "keyboard.chevron.compact.down", "Hide"),
        ]
        let row = UIStackView(arrangedSubviews: keys.map { title, symbol, key in
            var style = UIButton.Configuration.plain()
            style.baseForegroundColor = .label
            if let symbol {
                style.image = UIImage(systemName: symbol)
                style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            } else {
                var words = AttributedString(title)
                words.font = .systemFont(ofSize: 15, weight: .medium)
                style.attributedTitle = words
            }
            let button = UIButton(configuration: style, primaryAction: UIAction { _ in press(key) })
            button.accessibilityLabel = key == "Hide" ? String(localized: "Hide Keyboard") : key
            return button
        })
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

// MARK: Help

/// Trackpad View's gestures, a row each: the hand's sign, what it is and
/// what it does, as iOS's own trackpad settings list theirs; Continue, or
/// back to the page as it was.
struct DesktopHelp: View {
    let done: () -> Void
    let leave: () -> Void

    private struct Row: Identifiable {
        let symbol: String
        let gesture: String
        let does: String
        var id: String { symbol }
    }

    private var rows: [Row] {
        [
            Row(symbol: "hand.point.up.left", gesture: String(localized: "Move one finger"), does: String(localized: "Moves the cursor")),
            Row(symbol: "hand.tap", gesture: String(localized: "Tap"), does: String(localized: "Clicks; twice to double-click")),
            Row(symbol: "hand.draw", gesture: String(localized: "Hold, then move"), does: String(localized: "Drags")),
            Row(symbol: "arrow.up.and.down", gesture: String(localized: "Move two fingers"), does: String(localized: "Scrolls")),
            Row(symbol: "cursorarrow.click.2", gesture: String(localized: "Tap with two fingers"), does: String(localized: "Opens the site's own menu")),
            Row(symbol: "arrow.up.left.and.arrow.down.right", gesture: String(localized: "Pinch"), does: String(localized: "Zooms")),
            Row(symbol: "map", gesture: String(localized: "Tap the minimap"), does: String(localized: "Goes there; drag it to another corner")),
        ]
    }

    /// As tall as its rows; scrolling where the sheet is shorter than that,
    /// as on a phone turned sideways or with large type.
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trackpad View")
                .font(.title2.weight(.bold))
            Text("The site's desktop version, with your screen as a trackpad. Click a text field, then the keyboard button, to type.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    HStack(spacing: 14) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(.tint)
                            .frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.gesture).font(.body.weight(.medium))
                            Text(row.does).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 22)
            VStack(spacing: 8) {
                Button(action: done) {
                    Text("Continue").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Button(action: leave) {
                    Text("Use Normal Browsing").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.large)
            .padding(.top, 26)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }
}
