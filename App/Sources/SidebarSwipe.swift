import PadCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// To the space beside by sweeping sideways across the sidebar, as on the
/// Mac (its ReaderView): two fingers on the trackpad, or one finger on the
/// glass. The rules are SpaceSwipe's; this is UIKit's half.
///
/// It is on the sidebar's hosting view, over all of it, and comes first:
/// the list's scroll view waits for it to fail, which it does at once for a
/// drag that sets out up or down, so a sweep sideways doesn't also scroll
/// the tabs a little; and SwiftUI's buttons, which keep a drag that starts
/// on one to themselves, don't prevent it. It leaves alone what is its own
/// to slide sideways (the spaces' row, when it scrolls), and a finger that
/// rests before it moves, which is picking a tab up to drag it.
@MainActor
final class SidebarSwipe: NSObject, UIGestureRecognizerDelegate {
    private let pan = SidebarPan()
    private var swipe = SpaceSwipe()
    /// Two fingers on the trackpad, which have no flick (SpaceSwipe.flick).
    private var scrolling = false
    /// Goes `way` along the row of spaces (Browser.stepSpace).
    private let step: (Int) -> Void

    init(on view: UIView, step: @escaping (Int) -> Void) {
        self.step = step
        super.init()
        pan.addTarget(self, action: #selector(swiped(_:)))
        pan.delegate = self
        // A finger, and the trackpad's two, which the Mac's sweep needs
        // (hasPreciseScrollingDeltas); not a mouse's wheel. The pointer's
        // touches let its scrolls come; its click and drag is left alone.
        pan.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        pan.allowedScrollTypesMask = .continuous
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = pan.view, Session.shared.workspace.spaces.count > 1 else { return false }
        // Scrolled on the trackpad, it has no touches.
        scrolling = pan.numberOfTouches == 0
        if !scrolling, pan.clicked || pan.held { return false }
        let moved = pan.travel(in: view) ?? pan.translation(in: view)
        let going = moved == .zero ? pan.velocity(in: view) : moved
        guard SpaceSwipe.isSideways(dx: Double(going.x), dy: Double(going.y)) else { return false }
        let start = CGPoint(x: pan.location(in: view).x - moved.x, y: pan.location(in: view).y - moved.y)
        return !slidesSideways(at: start, in: view)
    }

    /// Whether what is under `point` scrolls sideways itself.
    private func slidesSideways(at point: CGPoint, in view: UIView) -> Bool {
        var hit = view.hitTest(point, with: nil)
        while let shown = hit, shown !== view {
            if let scroll = shown as? UIScrollView, scroll.slidesSideways { return true }
            hit = shown.superview
        }
        return false
    }

    @objc private func swiped(_ pan: SidebarPan) {
        guard let view = pan.view else { return }
        let dx = Double((pan.travel(in: view) ?? pan.translation(in: view)).x)
        switch pan.state {
        case .began:
            swipe = SpaceSwipe(rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            go(swipe.moved(to: dx))
        case .changed:
            go(swipe.moved(to: dx))
        case .ended where !scrolling:
            go(swipe.letGo(at: dx, velocity: Double(pan.velocity(in: view).x)))
        default:
            break
        }
    }

    private func go(_ way: Int?) {
        if let way { step(way) }
    }
}

/// The sidebar's pan: first, before the list's scroll view and SwiftUI's
/// own recognizers (SidebarSwipe).
private final class SidebarPan: UIPanGestureRecognizer {
    /// Slower than this to set out, a finger rested first: it is picking
    /// up what it is on (a tab's drag lifts at about half a second), not
    /// sweeping, which sets out at once.
    private static let rest: TimeInterval = 0.3
    private var touched: TimeInterval?
    private var latest: TimeInterval?
    /// The pointer's click and drag, not a finger.
    private(set) var clicked = false
    /// The touch it follows, and where it came down.
    private var finger: (touch: UITouch, at: CGPoint)?

    /// How far the finger has gone since it came down, in `view`; nil for
    /// the trackpad's scrolls, which have no finger. A pan's translation
    /// leaves out the way it went before the pan began, past its slack; a
    /// sweep counts all of it, as the Mac's counts every scroll of the
    /// gesture, and touches that come late, all in one jump, still go somewhere.
    func travel(in view: UIView) -> CGPoint? {
        guard let finger else { return nil }
        let now = finger.touch.location(in: view)
        let at = self.view.map { view.convert(finger.at, from: $0) } ?? finger.at
        return CGPoint(x: now.x - at.x, y: now.y - at.y)
    }

    /// The finger took longer than a sweep's start to go as far as a pan begins at.
    var held: Bool {
        guard let touched, let latest else { return false }
        return latest - touched > Self.rest
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touched == nil, let touch = touches.first {
            touched = event.timestamp
            clicked = touch.type == .indirectPointer
            finger = (touch, touch.location(in: view))
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        latest = event.timestamp
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        touched = nil
        latest = nil
        clicked = false
        finger = nil
    }

    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool {
        false
    }

    override func shouldRequireFailure(of other: UIGestureRecognizer) -> Bool {
        false
    }

    /// The tabs' scroll view waits for a sweep to fail before it scrolls;
    /// one that scrolls sideways itself (the spaces' row) doesn't, as a
    /// sweep never begins on it.
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        guard let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer, let view else { return false }
        return scroll.isDescendant(of: view) && !scroll.slidesSideways
    }
}

extension UIScrollView {
    /// It has more to show sideways than fits.
    fileprivate var slidesSideways: Bool {
        contentSize.width > bounds.width + 1
    }
}
