import AppKit
import PadCore
import SwiftUI
import WebEngineAppKit
import WebEngineCore

/// Back and forward by two fingers sideways on the trackpad: eGlu's own,
/// not WebKit's.
///
/// WebKit's swipe hands the fingers to AppKit, which decides how far they
/// go before letting go takes the step, as in Safari: most of the
/// trackpad's width, with nothing to make it shorter. Here the step is
/// taken after the trackpad's reach, as on the iPad (HistorySwipe).
///
/// Whether two fingers are a swipe at all is decided as WebKit's own swipe
/// decides it (ScrollSwipe): they set out sideways from where the page
/// was at its edge that way (`_pinnedState`), there is a page to go to, and
/// the page left their first sideways scroll unused
/// (`_webView:didNotHandleWheelEvent:`, the answer WebKit's swipe waits for). So a page that scrolls sideways
/// itself (a map, a canvas, a carousel, a wide table) keeps its scroll, as
/// in Safari. The page's edge doesn't bounce at the left with a page to go
/// back to, nor at the right with one to go forward to, as WebKit has it
/// for its own swipe: a scroll there is then left unused.
///
/// The arrow is the iPad's (BackSwipe): it comes in from the edge with the
/// swipe and fills, in the space's colour, when letting go would take the
/// step. System Settings › Trackpad › Swipe between pages is followed: off,
/// two fingers do nothing here; with three fingers AppKit sends a swipe of
/// its own (`swiped`).
///
/// It is all WebKit's private calls, as Safari's swipe is; a macOS without
/// them keeps WebKit's own swipe (Page.setUp).
@MainActor
final class PageSwipe {
    private weak var view: NSView?
    private weak var page: Page?
    private let service: any WebSwipe
    /// The two fingers on the trackpad now, or last.
    private var gesture: ScrollSwipe?
    /// Its first scroll with a sideways part, the one whose answer is waited for.
    private var asked: NSEvent?
    /// The fingers have left.
    private var released = false
    /// They left at this speed before the page had answered.
    private var leftAt: Double?
    /// The swipe had the fingers and was called off before they left: the
    /// rest of the gesture is still no page's, and takes no step.
    private var calledOff = false
    /// Where in the page's history the gesture began. A step taken meanwhile
    /// (⌘[, a link, the page's own) calls the swipe off, however WebKit tells
    /// of it: canGoBack and canGoForward change only when one turns true or false.
    private var from: AnyObject?
    /// The glide after a swipe: the swipe's as the fingers were, and no page's.
    private var gliding = false
    private var edges: Set<WebPageEdge>?
    private let arrow = SwipeArrow()
    private var showing: HistorySwipe.Way?
    /// How many times the arrow has set out to leave: only the last hides it.
    private var leaving = 0

    /// Whether this macOS's WebKit has what the swipe asks of it.
    static func works(on page: any WebMacPage) -> Bool {
        page.traits.isSuperset(of: [.rubberBandControl, .correlatedUnusedWheelEvents]) && page.swipe != nil
    }

    init(page: Page, service: any WebSwipe) {
        self.page = page
        self.service = service
        let view = page.surface.view
        self.view = view
        arrow.isHidden = true
        view.addSubview(arrow)
        bounce()
    }

    func stop() {
        arrow.removeFromSuperview()
    }

    // MARK: The fingers

    /// A scroll on the page: whether the swipe has it, and it goes no further.
    func scrolled(_ event: NSEvent) -> Bool {
        // The glide's every step, to its end, even with the fingers down again meanwhile.
        if gliding, event.phase.isEmpty, !event.momentumPhase.isEmpty {
            if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) { gliding = false }
            return true
        }
        if event.phase.contains(.began) {
            gliding = false
            begin(with: event)
        }
        guard var gesture, !released else { return false }
        // The gesture's end goes to WebKit, which had its beginning, whoever had the rest.
        if !event.phase.isDisjoint(with: [.ended, .cancelled]) {
            release(at: event, gesture)
            return false
        }
        guard !event.phase.isDisjoint(with: [.began, .changed, .stationary]) else { return false }
        if calledOff { return true }
        let scroll = gesture.moved(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), at: event.timestamp)
        self.gesture = gesture
        if scroll == .asked { asked = event }
        // Before WebKit has the scroll, which it takes with the edges as they are then.
        if gesture.isScroll { bounce() }
        show()
        return scroll == .swipe
    }

    /// A new gesture. It may become a swipe only by a trackpad (or a Magic
    /// Mouse) with swiping between pages on, and no key held, which makes it
    /// something else; only where the page is at its edge, as it begins.
    private func begin(with event: NSEvent) {
        finish(taken: false)
        released = false
        calledOff = false
        leftAt = nil
        asked = nil
        from = page?.enginePage.services.currentEntry
        var open: Set<HistorySwipe.Way> = []
        if let page, NSEvent.isSwipeTrackingFromScrollEventsEnabled, event.hasPreciseScrollingDeltas,
           event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
           !service.isInFullscreen {
            let pinned = service.pinnedEdges
            if pinned.contains(.left), page.canGoBack { open.insert(.back) }
            if pinned.contains(.right), page.state.canGoForward { open.insert(.forward) }
        }
        gesture = ScrollSwipe(open: open)
        bounce()
    }

    /// The fingers left: a swipe that had them takes the step or not.
    private func release(at event: NSEvent, _ gesture: ScrollSwipe) {
        released = true
        guard gesture.taken else {
            if gesture.awaitsAnswer, event.phase.contains(.ended) { wait(at: gesture.speed(at: event.timestamp)) }
            return
        }
        gliding = true
        if calledOff || event.phase.contains(.cancelled) {
            finish(taken: false)
        } else {
            settle(at: gesture.speed(at: event.timestamp))
        }
    }

    /// WebKit's word that the page left a scroll unused: for the asked
    /// scroll, the answer the swipe waits for.
    func leftAlone(_ event: NSEvent) {
        guard let asked, event === asked || (event.timestamp == asked.timestamp && event.phase == asked.phase),
              gesture != nil, !calledOff else { return }
        gesture?.leftAlone()
        guard released else {
            show()
            return
        }
        guard let leftAt, gesture?.taken == true else { return }
        self.leftAt = nil
        // The page has had the whole gesture: the rest of its glide too, unless it goes elsewhere.
        gliding = settle(at: leftAt)
    }

    /// Somewhere else to go, or nowhere: a step taken meanwhile (⌘[, a link
    /// the page followed) calls off the swipe under way.
    func wentSomewhere() {
        callOff()
        bounce()
    }

    /// The page went elsewhere, or out of its window, with the swipe under
    /// way: it takes no step, and the arrow goes. A swipe that had the
    /// fingers keeps them to the gesture's end; one that didn't leaves the
    /// rest of the gesture to the page.
    func callOff() {
        leftAt = nil
        finish(taken: false)
        guard let gesture, !released else { return }
        if gesture.taken {
            calledOff = true
        } else {
            self.gesture = nil
        }
    }

    /// The fingers left before the page answered: as on the iPad
    /// (Pointer.leave), the answer gets a moment more, and without it the
    /// swipe goes nowhere.
    private func wait(at speed: Double) {
        leftAt = speed
        let asked = asked
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.asked === asked, self.leftAt != nil else { return }
            self.leftAt = nil
        }
    }

    /// Whether the step is taken.
    @discardableResult
    private func settle(at speed: Double) -> Bool {
        guard let page, let way = gesture?.commits(velocity: speed), canGo(way), stillWhereItBegan else {
            finish(taken: false)
            return false
        }
        finish(taken: true)
        if way == .back { page.goBack() } else { page.goForward() }
        return true
    }

    private func canGo(_ way: HistorySwipe.Way) -> Bool {
        guard let page else { return false }
        return way == .back ? page.canGoBack : page.state.canGoForward
    }

    /// Three fingers, where System Settings has them swipe between pages:
    /// AppKit sends one swipe, a step at once, as WebKit takes it with its own swipe on.
    func swiped(_ event: NSEvent) -> Bool {
        guard let page, !service.isInFullscreen, event.deltaX != 0 else { return false }
        let way: HistorySwipe.Way = event.deltaX > 0 ? .back : .forward
        guard canGo(way) else { return false }
        leftAt = nil
        if way == .back { page.goBack() } else { page.goForward() }
        return true
    }

    // MARK: The page's edges

    /// Which of the page's edges bounce: not the left with a page to go
    /// back to, nor the right with one to go forward to, while two fingers
    /// may be a swipe; every one once they are a scroll, to the gesture's
    /// end, as WebKit has it (rubberBandableEdgesRespectingHistorySwipe).
    /// Again whenever there is somewhere else to go.
    private func bounce() {
        guard let page else { return }
        var edges = Set(WebPageEdge.allCases)
        if NSEvent.isSwipeTrackingFromScrollEventsEnabled, gesture?.isScroll != true {
            if page.canGoBack { edges.remove(.left) }
            if page.state.canGoForward { edges.remove(.right) }
        }
        guard edges != self.edges else { return }
        self.edges = edges
        service.setRubberBandingEnabled(edges)
    }

    // MARK: The arrow

    /// The page is on the history entry the gesture began on.
    private var stillWhereItBegan: Bool {
        page?.enginePage.services.currentEntry === from
    }

    private func show() {
        guard stillWhereItBegan else {
            callOff()
            return
        }
        guard !released, let way = gesture?.way, canGo(way), let view else {
            finish(taken: false)
            return
        }
        let progress = HistorySwipe.progress(distance: gesture?.distance ?? 0, reach: HistorySwipe.trackpadReach)
        let armed = progress >= 1
        if showing != way {
            showing = way
            arrow.set(way: way)
            // Filled in the space's colour, the chevron in the ink that reads on it (dark on yellow).
            let colour = page.flatMap { Session.shared.workspace.space($0.space) }?.color
            arrow.colour = colour?.nsColor ?? .controlAccentColor
            arrow.armedInk = colour.map { NSColor($0.ink) } ?? .white
            arrow.set(armed: false, animated: false)
            arrow.isHidden = false
            view.addSubview(arrow, positioned: .above, relativeTo: nil)
        }
        if armed != arrow.armed {
            arrow.set(armed: armed)
            // The point past which letting go takes the step, felt in the trackpad as well as seen.
            if armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        arrow.place(in: view.bounds, way: way, progress: CGFloat(progress))
    }

    /// The swipe is over: the arrow leaves the way it came, quicker when the step was taken.
    private func finish(taken: Bool) {
        guard let way = showing, let view else { return }
        showing = nil
        leaving += 1
        let leaving = leaving
        let arrow = arrow
        let bounds = view.bounds
        NSAnimationContext.runAnimationGroup { context in
            context.duration = taken ? 0.25 : 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arrow.place(in: bounds, way: way, progress: 0, animated: true)
        } completionHandler: { [weak self] in
            // A new swipe may have begun meanwhile, and perhaps ended: the arrow is its then.
            guard let self, self.showing == nil, self.leaving == leaving else { return }
            arrow.isHidden = true
        }
    }
}

/// The arrow a swipe back or forward brings in from the page's edge, as the
/// iPad's: on glass, filled in its colour once letting go would take the step.
private final class SwipeArrow: NSView {
    static let side: CGFloat = 40
    private let glass = NSGlassEffectView()
    private let fill = NSView()
    private let chevron = NSImageView()
    private(set) var armed = false
    var colour = NSColor.controlAccentColor
    /// The chevron's colour on the filled disc: the space colour's ink.
    var armedInk = NSColor.white

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        glass.frame = bounds
        glass.cornerRadius = Self.side / 2
        addSubview(glass)
        fill.frame = bounds
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Self.side / 2
        fill.alphaValue = 0
        addSubview(fill)
        chevron.frame = bounds
        chevron.imageScaling = .scaleNone
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        chevron.setAccessibilityElement(false)
        addSubview(chevron)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Clicks go through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func set(way: HistorySwipe.Way) {
        chevron.image = NSImage(systemSymbolName: way == .back ? "chevron.left" : "chevron.right", accessibilityDescription: nil)
    }

    /// Filled in its colour once letting go would take the step.
    func set(armed: Bool, animated: Bool = true) {
        self.armed = armed
        fill.layer?.backgroundColor = colour.cgColor
        chevron.contentTintColor = armed ? armedInk : .labelColor
        guard animated else {
            fill.layer?.removeAllAnimations()
            fill.alphaValue = armed ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.animator().alphaValue = armed ? 1 : 0
        }
    }

    /// In from outside the edge to 16 points inside it, halfway up the
    /// page. With Reduce Motion it stays where it ends and fades in.
    func place(in bounds: NSRect, way: HistorySwipe.Way, progress: CGFloat, animated: Bool = false) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let inset = still ? 16 + Self.side / 2 : -Self.side / 2 + (16 + Self.side) * progress
        let centre = NSPoint(x: way == .back ? bounds.minX + inset : bounds.maxX - inset, y: bounds.midY)
        // Where it is now, not where an animation still under way was taking it.
        if !animated { layer?.removeAllAnimations() }
        let target = animated ? animator() : self
        target.frame = NSRect(x: centre.x - Self.side / 2, y: centre.y - Self.side / 2, width: Self.side, height: Self.side)
        target.alphaValue = min(1, progress * 3)
    }
}

extension Page {
    func makePageSwipe() -> PageSwipe? {
        guard PageSwipe.works(on: enginePage), let service = enginePage.swipe else { return nil }
        return PageSwipe(page: self, service: service)
    }
}
