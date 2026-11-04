import UIKit

/// The constraints a Browser moves its chrome by, between its layouts
/// (Browser.show(_:)) and as its page turns into a card and back
/// (Browser.card(_:)): the stack's edges, its start at the window's edge or
/// beside the sidebar, the sidebar's width, and the phone bar's height and
/// bottom. Each is made once, as its view goes on screen (Browser.build).
@MainActor
final class ChromeConstraints {
    private var stackTop: NSLayoutConstraint?
    private var stackAtEdge: NSLayoutConstraint?
    private var stackTrailing: NSLayoutConstraint?
    /// The stack's bottom: the window's own, on a phone so the page runs on
    /// under the bar and the home indicator, and in a wide window a bezel
    /// above it, as far as the card's right side is from that edge.
    private var screenBottom: NSLayoutConstraint?
    private var stackBeside: NSLayoutConstraint?
    /// The sidebar's width: its own, or as far as the iPhone Duo's fold (Browser.placeSidebar).
    private var sideWidth: NSLayoutConstraint?
    /// The phone bar's height: shorter while an address is typed (PhoneBar.typingHeight).
    private var phoneHeight: NSLayoutConstraint?
    /// The phone bar's bottom: the safe area's, or the keyboard's while an
    /// address is typed.
    private var barSafeBottom: NSLayoutConstraint?
    private var barKeyboardBottom: NSLayoutConstraint?

    /// The stack in the safe area, at the window's edge, and to the
    /// window's foot, whatever the safe area says there: a phone's bar goes
    /// under the home indicator, and a wide window's card stops a bezel
    /// short of it as of its right side, the indicator (or a window's corner
    /// to size it by) over the page, as over Safari's (Browser.card).
    func pinStack(_ stack: UIView, in view: UIView) {
        let safe = view.safeAreaLayoutGuide
        let bottom = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        let edge = stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        let top = stack.topAnchor.constraint(equalTo: safe.topAnchor)
        let trailing = stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        screenBottom = bottom
        stackAtEdge = edge
        stackTop = top
        stackTrailing = trailing
        NSLayoutConstraint.activate([top, edge, trailing, bottom])
    }

    /// The sidebar down the safe area's leading side, and the stack's start
    /// beside it, for when it shows (placeStack).
    func pinSidebar(_ side: UIView, to safe: UILayoutGuide, stack: UIView) {
        let width = side.widthAnchor.constraint(equalToConstant: SideTabs.width)
        sideWidth = width
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: safe.topAnchor),
            side.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            width,
        ])
        stackBeside = stack.leadingAnchor.constraint(equalTo: side.trailingAnchor)
    }

    /// The phone bar across the safe area, on its bottom until it rides the keyboard (rideKeyboard).
    func pinPhoneBar(_ bar: UIView, to safe: UILayoutGuide, keyboard: UIKeyboardLayoutGuide) {
        let height = bar.heightAnchor.constraint(equalToConstant: PhoneBar.height)
        let bottom = bar.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        barSafeBottom = bottom
        barKeyboardBottom = bar.bottomAnchor.constraint(equalTo: keyboard.topAnchor)
        NSLayoutConstraint.activate([
            height, bottom,
            bar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        phoneHeight = height
    }

    /// The stack's start beside the sidebar or at the window's edge. The
    /// one going first, so the two are never on together.
    func placeStack(besideSidebar: Bool) {
        if besideSidebar {
            stackAtEdge?.isActive = false
            stackBeside?.isActive = true
        } else {
            stackBeside?.isActive = false
            stackAtEdge?.isActive = true
        }
    }

    /// The stack a bezel in from the window's edges, or none.
    func inset(by bezel: CGFloat) {
        self.bezel = bezel
        stackTop?.constant = bezel
        screenBottom?.constant = -bezel
        placeSides()
    }

    private var bezel: CGFloat = 0
    /// How far past the safe area the stack reaches at its leading and
    /// trailing sides: under the iPhone Duo's strip, to the window's edge.
    private var beyond: (leading: CGFloat, trailing: CGFloat) = (0, 0)

    /// The stack on under the iPhone Duo's strip to the window's edge, on
    /// the strip's side, `width` past the safe area; or, with no side, back
    /// in the safe area (Browser.placeUnderStrip). The side as it is on
    /// screen: in right-to-left languages the trailing side is the left.
    func reachUnderStrip(_ side: CGRectEdge?, width: CGFloat, rightToLeft: Bool) {
        let trailingSide: CGRectEdge = rightToLeft ? .minXEdge : .maxXEdge
        beyond = switch side {
        case nil: (0, 0)
        case trailingSide?: (0, width)
        default: (width, 0)
        }
        placeSides()
    }

    private func placeSides() {
        stackAtEdge?.constant = bezel - beyond.leading
        stackTrailing?.constant = -bezel + beyond.trailing
    }

    /// The sidebar's width and the gap between it and the stack, once both are made.
    var sidebar: (width: CGFloat, gap: CGFloat)? {
        guard let sideWidth, let stackBeside else { return nil }
        return (sideWidth.constant, stackBeside.constant)
    }

    func placeSidebar(width: CGFloat, gap: CGFloat) {
        sideWidth?.constant = width
        stackBeside?.constant = gap
    }

    /// The phone bar's height as `height`; whether that changed it.
    func setPhoneHeight(_ height: CGFloat) -> Bool {
        guard let phoneHeight, phoneHeight.constant != height else { return false }
        phoneHeight.constant = height
        return true
    }

    /// The phone bar on the keyboard while an address is typed, on the safe area's bottom otherwise.
    func rideKeyboard(_ typing: Bool) {
        if typing, barSafeBottom?.isActive == true {
            barSafeBottom?.isActive = false
            barKeyboardBottom?.isActive = true
        } else if !typing, barKeyboardBottom?.isActive == true {
            barKeyboardBottom?.isActive = false
            barSafeBottom?.isActive = true
        }
    }
}
