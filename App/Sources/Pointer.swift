import PadCore
import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The trackpad, as a Mac's WebKit would hand it to the page.
///
/// Hover, click and move are WebKit's own: on iPad it already sends a page
/// mouse and pointer events for them. What it doesn't send is a pinch on the
/// trackpad (it zooms the whole page instead, which is off here), and, with
/// its own scrolling off, maybe not two fingers moving either. So:
///
/// - The cursor's position comes from a hover recognizer: wheel events need
///   a place on the page, and a pinch has no pointer position of its own.
/// - A pinch on the trackpad, and only the trackpad (`.indirectPointer`, a
///   finger pinch on the glass is not one), becomes wheel events with
///   ctrlKey at the cursor: what Chrome sends for a pinch, and what Figma
///   and other canvas apps zoom on (Pinch.wheelDelta).
/// - Two fingers with ⌘ held zoom the same way.
/// - Two fingers alone become wheel events too (the wheel bridge), unless
///   WebKit is sending the page its own, which bridge.js checks event by
///   event; a release with speed glides on, as on a Mac.
/// - A page's own cursor picture, which WebKit on iPad never shows, is
///   drawn where the pointer is, over the hidden system pointer (below).
@MainActor
final class Pointer: NSObject, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private weak var page: Page?
    private let hover: UIHoverGestureRecognizer
    private let pinch: UIPinchGestureRecognizer
    private let scroll: UIPanGestureRecognizer
    private let press: PressWatcher
    private let keys: PressKeys

    /// Where the cursor last was over the page, in the page view's points.
    private(set) var cursor: CGPoint?
    private var lastScale: CGFloat = 1
    private var lastTranslation: CGPoint = .zero
    /// This pan's own: whether it is a scroll at all (not a click-drag),
    /// whether WebKit's wheel events were arriving, whether any of it
    /// zoomed, how many steps it had, and where the last one was sent.
    private var isScroll = false
    private var webKitScrolls = false
    private var zoomed = false
    private var steps = 0
    private var lastPoint: CGPoint = .zero
    /// This pan as a swipe back or forward, while it may still be one
    /// (TrackpadSwipe); which pan it is, so a late answer to the one before
    /// isn't taken for this one's; and the speed the fingers left at, while
    /// the page's last answers are still to come.
    private var swipe: TrackpadSwipe?
    private var pan = 0
    private var leftAt: CGFloat?

    private var glide: Momentum?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    /// The page's own cursor: the one it asks for, the pictures it has sent
    /// by bridge.js's id, the view that draws the one showing, and the
    /// interaction that hides the system pointer while it shows.
    private(set) var pageCursor: PageCursor = .system
    /// The page asked for another cursor: the iPhone's desktop view draws
    /// its own cursor, and draws this one.
    var changed: (() -> Void)?
    private var pictures: [Int: CursorPicture] = [:]
    /// The pictures' ids, oldest first: past 128, the oldest goes. The page
    /// names by id only its last 65 (bridge.js showCursor), so those stay.
    private var pictureOrder: [Int] = []
    private let drawn = UIImageView()
    private var hider: UIPointerInteraction?
    private var hiding = false
    /// Where the pointer is while its button is down, which the hover
    /// recognizer doesn't follow; and when the hover recognizer last did.
    private var pressed: CGPoint?
    private var lastHover: CFTimeInterval = 0
    /// The last press on the page: when, the keys held, and whether it was a
    /// mouse's middle button. What a click asks for (NewTabClick) where
    /// WebKit doesn't say: before iPadOS 18.4, and for a button whose own
    /// script goes somewhere.
    private var lastPress: (time: CFTimeInterval, flags: UIKeyModifierFlags, middle: Bool, secondary: Bool)?

    init(page: Page) {
        self.page = page
        hover = UIHoverGestureRecognizer()
        pinch = UIPinchGestureRecognizer()
        scroll = UIPanGestureRecognizer()
        press = PressWatcher()
        keys = PressKeys()
        super.init()
        hover.addTarget(self, action: #selector(hovered(_:)))
        pinch.addTarget(self, action: #selector(pinched(_:)))
        scroll.addTarget(self, action: #selector(scrolled(_:)))
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        press.allowedTouchTypes = pointer
        press.moved = { [weak self] point in self?.pressMoved(point) }
        keys.began = { [weak self] flags, buttons in
            // A finger on the glass or a click stops a glide where it is, as
            // a touch stops a scroll view; the touch itself stays the page's.
            self?.stopGlide()
            // A secondary click is the trackpad's or the mouse's second button, or a click with Control held.
            let secondary = buttons.contains(.secondary) || (buttons.contains(.primary) && flags.contains(.control))
            self?.lastPress = (CACurrentMediaTime(), flags, buttons.contains(.button(3)), secondary)
        }
        pinch.allowedTouchTypes = pointer
        // Scroll events, from a trackpad or a mouse wheel. Fingers on the
        // glass never reach it; a click-drag with the pointer does, and is
        // told apart in scrolled(_:) by having a touch, which a scroll
        // doesn't. Either stays the page's.
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = pointer
        for recognizer in [hover, pinch, scroll, press, keys] as [UIGestureRecognizer] {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            page.view.addGestureRecognizer(recognizer)
        }

        drawn.isUserInteractionEnabled = false
        drawn.isHidden = true
        drawn.accessibilityElementsHidden = true
        page.view.addSubview(drawn)
        let hider = UIPointerInteraction(delegate: self)
        hider.isEnabled = false
        page.view.addInteraction(hider)
        self.hider = hider
    }

    func stop() {
        stopGlide()
        swipe = nil
        leftAt = nil
        for recognizer in [hover, pinch, scroll, press, keys] as [UIGestureRecognizer] {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        hideSystemPointer(false)
        if let hider { hider.view?.removeInteraction(hider) }
        hider = nil
        drawn.removeFromSuperview()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: The cursor

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            cursor = recognizer.location(in: recognizer.view)
            lastHover = CACurrentMediaTime()
        default:
            // Gone from the page, or hidden while typing: the gestures' own
            // location stands in until it is back.
            cursor = nil
        }
        updateCursor()
    }

    /// The button went down, moved or came up (nil). On the way up the
    /// pointer is taken to stay where it was, until the hover recognizer
    /// says otherwise, so the page's cursor doesn't blink between the two.
    private func pressMoved(_ point: CGPoint?) {
        if let point {
            pressed = point
        } else if let last = pressed {
            pressed = nil
            cursor = page.map { $0.view.bounds.contains(last) } == true ? last : nil
            let released = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.pressed == nil, self.lastHover < released else { return }
                self.cursor = nil
                self.updateCursor()
            }
        }
        updateCursor()
    }

    /// When the last press began, if it was a secondary click within
    /// `seconds`: a menu asked for just after one came from it, not from a
    /// finger held down (Page's link menu).
    func secondaryClick(within seconds: CFTimeInterval) -> CFTimeInterval? {
        guard let lastPress, lastPress.secondary, CACurrentMediaTime() - lastPress.time < seconds else { return nil }
        return lastPress.time
    }

    /// The keys held and the middle button for a press within `seconds`, if one was.
    func recentPress(within seconds: CFTimeInterval) -> (flags: UIKeyModifierFlags, middle: Bool)? {
        guard let lastPress, CACurrentMediaTime() - lastPress.time < seconds else { return nil }
        return (lastPress.flags, lastPress.middle)
    }

    // MARK: The page's own cursor

    /// What bridge.js says the page asks for under the pointer. A picture
    /// that doesn't decode, or one this page never sent, is the system's
    /// pointer: never no pointer at all.
    func show(_ asked: PageCursor) {
        var asked = asked
        if case .image(let image) = asked {
            if let png = image.png {
                if let picture = UIImage(data: png, scale: CGFloat(image.scale)) {
                    pictureOrder.removeAll { $0 == image.id }
                    pictureOrder.append(image.id)
                    if pictureOrder.count > 128 {
                        pictures[pictureOrder.removeFirst()] = nil
                    }
                    pictures[image.id] = CursorPicture(
                        image: picture,
                        size: CGSize(width: image.width, height: image.height),
                        hotspot: CGPoint(x: image.hotspotX, y: image.hotspotY)
                    )
                } else {
                    asked = .system
                }
            } else if pictures[image.id] == nil {
                asked = .system
            }
        }
        pageCursor = asked
        updateCursor()
        changed?()
    }

    /// The page's own cursor as a picture with its hotspot, in points; nil
    /// for the system's pointer, and `hidden` for `cursor: none`.
    var picture: (image: UIImage, size: CGSize, hotspot: CGPoint)? {
        guard case .image(let image) = pageCursor, let picture = pictures[image.id] else { return nil }
        return (picture.image, picture.size, picture.hotspot)
    }

    var hidden: Bool {
        pageCursor == .hidden
    }

    /// One of CSS's own cursors the page names (pointer, text…), for the
    /// iPhone's desktop view to draw; nil for the default arrow or a picture.
    var keyword: String? {
        guard case .keyword(let name) = pageCursor else { return nil }
        return name
    }

    /// Over the page, the page's cursor: its picture drawn at the pointer,
    /// the system pointer hidden under it. Anywhere else, or for a keyword,
    /// the system pointer as WebKit chooses it.
    private func updateCursor() {
        let point = pressed ?? cursor
        var picture: CursorPicture?
        var hide = false
        if point != nil {
            switch pageCursor {
            case .system, .keyword:
                break
            case .hidden:
                hide = true
            case .image(let image):
                picture = pictures[image.id]
                hide = picture != nil
            }
        }
        hideSystemPointer(hide)
        guard let point, let picture else {
            drawn.isHidden = true
            return
        }
        UIView.performWithoutAnimation {
            if drawn.image !== picture.image { drawn.image = picture.image }
            drawn.frame = CGRect(x: point.x - picture.hotspot.x, y: point.y - picture.hotspot.y,
                                 width: picture.size.width, height: picture.size.height)
            if drawn.isHidden {
                drawn.superview?.bringSubviewToFront(drawn)
                drawn.isHidden = false
            }
        }
    }

    /// WebKit's own pointer interactions choose the pointer over the page,
    /// and choose the system's whatever the page asks. While the page's own
    /// cursor shows they are turned off, so that this one, which hides the
    /// pointer, chooses instead; turned on again, the beam over text and the
    /// rest are WebKit's as before.
    private func hideSystemPointer(_ hide: Bool) {
        guard hide != hiding, let view = page?.view, let hider else { return }
        hiding = hide
        for interaction in Self.pointerInteractions(in: view) where interaction !== hider {
            interaction.isEnabled = !hide
        }
        hider.isEnabled = hide
        hider.invalidate()
    }

    private static func pointerInteractions(in view: UIView) -> [UIPointerInteraction] {
        view.interactions.compactMap { $0 as? UIPointerInteraction } + view.subviews.flatMap(pointerInteractions(in:))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    /// For Diagnostics: the cursor, and where its place comes from (a press,
    /// the hover recognizer, or nowhere) with how long ago the hover
    /// recognizer last spoke, which tells a frozen picture apart from a
    /// frozen page.
    var cursorSummary: String {
        let shape: String
        switch pageCursor {
        case .system:
            shape = "the system's"
        case .keyword(let name):
            shape = "the system's (\(name))"
        case .hidden:
            shape = "none, the pointer hidden"
        case .image(let image):
            if let picture = pictures[image.id] {
                let size = "\(Int(picture.size.width))×\(Int(picture.size.height)) at \(Int(picture.hotspot.x)),\(Int(picture.hotspot.y))"
                shape = "the page's, \(size)\(hiding ? "" : ", pointer elsewhere")"
            } else {
                shape = "the system's (picture missing)"
            }
        }
        let place: String
        if let pressed {
            place = "pressed at \(Int(pressed.x)),\(Int(pressed.y))"
        } else if let cursor {
            place = "hover at \(Int(cursor.x)),\(Int(cursor.y))"
        } else {
            place = "off the page"
        }
        let ago = lastHover == 0 ? "never" : String(format: "%.1f s ago", CACurrentMediaTime() - lastHover)
        return "\(shape); \(place), hover \(ago), \(hover.state.rawValue)"
    }

    private func place(of recognizer: UIGestureRecognizer) -> CGPoint {
        cursor ?? recognizer.location(in: recognizer.view)
    }

    // MARK: Pinch

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let page, page.bridges.pinch else { return }
        switch recognizer.state {
        case .began:
            stopGlide()
            lastScale = 1
            send(pinch: recognizer)
        case .changed:
            send(pinch: recognizer)
        default:
            lastScale = 1
        }
    }

    private func send(pinch recognizer: UIPinchGestureRecognizer) {
        guard let page, lastScale > 0 else { return }
        let step = Double(recognizer.scale / lastScale)
        lastScale = recognizer.scale
        let delta = Pinch.wheelDelta(step: step, factor: page.bridges.pinchFactor)
        guard delta != 0 else { return }
        page.stats.pinchSteps += 1
        page.wheel(at: place(of: recognizer), dx: 0, dy: delta, modifiers: recognizer.modifierFlags,
                   zoom: true, guarded: "pinch")
    }

    // MARK: Two fingers

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard let page, let view = recognizer.view else { return }
        switch recognizer.state {
        case .began:
            isScroll = recognizer.numberOfTouches == 0
            guard isScroll else { return }
            stopGlide()
            lastTranslation = .zero
            webKitScrolls = false
            zoomed = false
            steps = 0
            endSwipe(taken: false)
            pan += 1
            swipe = page.backSwipe?.isEnabled == true ? TrackpadSwipe() : nil
            moved(recognizer, in: view)
        case .changed:
            guard isScroll else { return }
            moved(recognizer, in: view)
        case .ended:
            // A swipe sideways the page left alone goes back or forward, or nowhere: nothing to glide.
            if isScroll, swipe?.way != nil {
                leave(at: recognizer.velocity(in: view).x)
                return
            }
            endSwipe(taken: false)
            // A glide follows a swipe on the trackpad, not a notch or two of
            // a mouse wheel, which ends after a step or two.
            guard isScroll, !zoomed, !webKitScrolls, steps >= 3, page.bridges.wheel != .off else { return }
            let velocity = recognizer.velocity(in: view)
            let speed = Wheel.delta(translationX: Double(velocity.x), translationY: Double(velocity.y))
            startGlide(Momentum(velocityX: speed.x, velocityY: speed.y))
        default:
            endSwipe(taken: false)
        }
    }

    private func moved(_ recognizer: UIPanGestureRecognizer, in view: UIView) {
        guard let page else { return }
        let translation = recognizer.translation(in: view)
        let fingers = (x: Double(translation.x - lastTranslation.x), y: Double(translation.y - lastTranslation.y))
        let delta = Wheel.delta(translationX: fingers.x, translationY: fingers.y)
        lastTranslation = translation
        guard delta.x != 0 || delta.y != 0 else { return }
        let point = place(of: recognizer)
        lastPoint = point
        steps += 1
        // With a key held it is something else: ⌘ zooms, ⇧ turns a mouse's wheel sideways.
        if !recognizer.modifierFlags.isDisjoint(with: [.command, .shift, .alternate, .control]) { endSwipe(taken: false) }
        // ⌘ is read at every step, as a Mac reads it with every wheel event.
        if page.bridges.commandZoom && recognizer.modifierFlags.contains(.command) {
            zoomed = true
            // ⌘ itself is not passed on: the page sees a pinch.
            page.stats.commandZoomSteps += 1
            page.wheel(at: point, dx: 0, dy: delta.y, modifiers: recognizer.modifierFlags.subtracting(.command),
                       zoom: true, guarded: "scroll") { [weak self] outcome in
                if outcome == "native" { self?.webKitScrolls = true }
            }
            return
        }
        guard page.bridges.wheel != .off else {
            endSwipe(taken: false)
            return
        }
        swipe?.moved(dx: fingers.x, dy: fingers.y)
        let pan = pan
        page.wheel(at: point, dx: delta.x, dy: delta.y, modifiers: recognizer.modifierFlags,
                   zoom: false, guarded: "scroll") { [weak self] outcome in
            if outcome == "native" { self?.webKitScrolls = true }
            self?.answered(outcome, sideways: delta.x != 0, pan: pan)
        }
    }

    // MARK: Two fingers sideways, back and forward

    /// The page's answer to one step of this pan. 'free' is a sideways part
    /// nothing used; a step with no sideways part says nothing either way,
    /// unless the page took it, and a page that takes one takes them all.
    private func answered(_ outcome: String?, sideways: Bool, pan: Int) {
        guard pan == self.pan, swipe != nil else { return }
        let free = outcome == "free" || (!sideways && (outcome == "scrolled" || outcome == "ignored"))
        swipe?.answered(free: free)
        showSwipe()
        if let leftAt, swipe?.settled == true { settle(at: leftAt) }
    }

    private func showSwipe() {
        guard let page, let swipe, let way = swipe.way, page.canGo(way) else {
            page?.backSwipe?.finish(taken: false)
            return
        }
        page.backSwipe?.show(way, progress: HistorySwipe.progress(distance: swipe.distance, reach: HistorySwipe.trackpadReach))
    }

    /// The fingers left. The step is taken once the page has answered for
    /// every wheel event of the swipe, and not at all if an answer never comes.
    private func leave(at velocity: CGFloat) {
        guard swipe?.settled != true else {
            settle(at: velocity)
            return
        }
        leftAt = velocity
        let pan = pan
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.pan == pan, self.leftAt != nil else { return }
            self.endSwipe(taken: false)
        }
    }

    private func settle(at velocity: CGFloat) {
        guard let page, let way = swipe?.commits(velocity: Double(velocity)), page.canGo(way) else {
            endSwipe(taken: false)
            return
        }
        endSwipe(taken: true)
        page.go(way)
    }

    private func endSwipe(taken: Bool) {
        guard swipe != nil || leftAt != nil else { return }
        swipe = nil
        leftAt = nil
        page?.backSwipe?.finish(taken: taken)
    }

    // MARK: The glide after the fingers leave

    private func startGlide(_ momentum: Momentum) {
        guard !momentum.isDone else { return }
        glide = momentum
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
    }

    private func stopGlide() {
        link?.invalidate()
        link = nil
        glide = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let page, var glide else {
            stopGlide()
            return
        }
        let now = link.timestamp
        let elapsed = lastTick == 0 ? link.duration : now - lastTick
        lastTick = now
        guard let step = glide.advance(by: elapsed) else {
            stopGlide()
            return
        }
        self.glide = glide
        page.wheel(at: cursor ?? lastPoint, dx: step.x, dy: step.y, modifiers: [], zoom: false, guarded: "scroll")
    }
}

/// A page's cursor picture, ready to draw: its size and hotspot in points.
private struct CursorPicture {
    let image: UIImage
    let size: CGSize
    let hotspot: CGPoint
}

/// Follows the pointer while its button is down, a click or a drag, which
/// the hover recognizer doesn't. It never recognizes anything, so every
/// touch stays the page's.
private final class PressWatcher: UIGestureRecognizer {
    var moved: ((CGPoint?) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        moved?(nil)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        moved?(nil)
        state = .failed
    }

    private func report(_ touches: Set<UITouch>) {
        if let touch = touches.first { moved?(touch.location(in: view)) }
    }
}

/// Tells the keys held and the buttons down at every press on the page, a
/// finger's as well as the pointer's, so a tap after a ⌘-click isn't
/// taken for one; then stands aside for the rest of the touch.
private final class PressKeys: UIGestureRecognizer {
    var began: ((UIKeyModifierFlags, UIEvent.ButtonMask) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        began?(event.modifierFlags, event.buttonMask)
        state = .failed
    }
}

/// Holds the page's zoom where ZoomLock says, whatever tries to change it:
/// the scroll view's pinch is off, and anything else that zooms (a double
/// tap a page didn't turn off, WebKit zooming in on a field) is set back.
@MainActor
final class ZoomHold: NSObject {
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var holding = false

    init(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()
        let changed: @Sendable (UIScrollView, NSKeyValueObservedChange<CGFloat>) -> Void = { [weak self] _, _ in
            let hold = self
            DispatchQueue.main.async { hold?.keep() }
        }
        observations = [
            scrollView.observe(\.zoomScale, changeHandler: changed),
            scrollView.observe(\.minimumZoomScale, changeHandler: changed),
            scrollView.observe(\.maximumZoomScale, changeHandler: changed),
        ]
    }

    /// Let go: the page's own zoom, pinched by a finger, as in Safari.
    private var free = false

    func release() {
        free = true
        scrollView?.pinchGestureRecognizer?.isEnabled = true
        scrollView?.bouncesZoom = true
    }

    func hold() {
        free = false
        keep()
    }

    private func keep() {
        guard let scrollView, !holding, !free else { return }
        holding = true
        defer { holding = false }
        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.bouncesZoom = false
        let target = CGFloat(ZoomLock.scale(webKitMinimum: Double(scrollView.minimumZoomScale)))
        if abs(scrollView.zoomScale - target) > 0.001 {
            scrollView.setZoomScale(target, animated: false)
        }
    }
}
