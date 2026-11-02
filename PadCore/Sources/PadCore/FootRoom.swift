import Foundation

/// Whether a page stands clear of the bar at the bottom of a phone's window,
/// or runs on under it.
///
/// A page runs on under the phone's bar, which floats over it and shows it
/// through its blur: a page to scroll loses nothing by that, its end coming
/// up over the bar as it is scrolled. A page that only fills the window does:
/// one built to the window's height (`100vh`, which WebKit gives as the
/// whole view's, bar and all, and for which a web view has no setting), or
/// one a little shorter than the window. It has nothing to scroll by, so
/// what it puts at its bottom (a chat's field, an editor's tools, a form's
/// button, a short page's foot) stays under the bar, where it can be
/// neither seen nor pressed. Such a page is laid out in the window less the
/// bar instead, and stands clear of it.
///
/// Told by how tall the page is as it is laid out now, which is another
/// height once it stands clear (the window it fills is the smaller one), so
/// the answer goes by where the page stands as well: it stays clear for as
/// long as it would fit the whole window, and runs under again only when it
/// has grown past that. Without that it would go back and forth: a page
/// that fills the window fills the smaller one too.
public enum FootRoom {
    /// Sizes come as fractions of a point: within one, two heights are the same.
    static let slack = 1.0

    /// The page's native viewport above a docked keyboard. Insets alone
    /// leave `100vh` layouts at their old height, with their fields covered.
    /// A hidden guide occupies only the bottom safe area; a floating or
    /// partial-width keyboard must not shorten the whole page.
    public static func aboveKeyboard(_ room: CGRect, keyboard: CGRect, bottomSafeArea: CGFloat,
                                     avoiding: Bool = true) -> CGRect {
        let slack = CGFloat(Self.slack)
        guard avoiding, room.width > 0, room.height > 0,
              keyboard.height > bottomSafeArea + slack,
              keyboard.minX <= room.minX + slack, keyboard.maxX >= room.maxX - slack,
              keyboard.maxY >= room.maxY - slack, keyboard.minY < room.maxY
        else { return room }
        var frame = room
        frame.size.height = max(1, keyboard.minY - room.minY)
        return frame
    }

    /// - Parameters:
    ///   - content: how tall the page is as it is laid out now, in the window's points, at the smallest it zooms to.
    ///   - window: how tall the window's room for the page is, bar and all.
    ///   - covered: how much of that the bar covers, at the bottom.
    ///   - standing: whether the page stands clear now, and so was laid out in the window less the bar.
    public static func standsClear(content: Double, window: Double, covered: Double, standing: Bool) -> Bool {
        guard covered > 0, window > covered, content > 0 else { return false }
        // Taller than the window, bar and all: a page to scroll.
        if content > window + slack { return false }
        // Clear already, and still no taller than the window.
        if standing { return true }
        // Else only if some of it is under the bar as it stands.
        return content > window - covered + slack
    }
}
