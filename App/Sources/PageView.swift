import PadCore
import UIKit
import WebKit

/// The web view of one page, with the keys the system would otherwise keep.
///
/// On iPad the system can take Tab and the arrow keys for itself, to move
/// the focus between controls or the text cursor, before the page sees
/// them. Where a site's adapter or Settings says so, they are registered
/// here with priority over the system and handed to the page as keydown
/// and keyup (bridge.js key()). The arrows stay the system's while the focus
/// is in a field someone can see, where they move the cursor.
final class PageView: WKWebView {
    weak var page: Page?

    /// The side the iPhone Duo's strip stands on while the page runs on
    /// under it (Page.strip). The page is told it has no safe area there,
    /// as on a phone without a strip, and lays itself out to the window's
    /// edge; strip.js makes the room, the same way for every page. A page
    /// that keeps clear of the safe area by itself (viewport-fit=cover and
    /// env()) would otherwise keep clear a second time over: Apple's
    /// header set its search and bag apart from its menu by the strip's
    /// width again. The scroll bar still keeps beside the strip: UIKit
    /// insets it by the scroll view's own safe area.
    var stripSide: CGRectEdge? {
        didSet { if stripSide != oldValue { safeAreaInsetsDidChange() } }
    }

    /// The page is laid out above a docked keyboard by the window
    /// (Browser.pageRoom), its view cut short to the keyboard's top. WebKit
    /// would make room for the keyboard a second time: as the keyboard
    /// starts to come it measures how much of the view it will cover, while
    /// the view is still whole, and keeps that much clear inside the view
    /// once it has been cut short, never measuring again. A page's foot sat
    /// a keyboard's height above the keyboard, the band between blank. So
    /// the view doesn't hear the keyboard move: only its frame
    /// changes. It still hears that the keyboard is up, and shows the field
    /// being typed in, in the view as it then is.
    /// A pop-up's view (`keyboardByWindow` false), which no window cuts
    /// short above the keyboard, leaves the keyboard to WebKit instead.
    init(frame: CGRect, configuration: WKWebViewConfiguration, keyboardByWindow: Bool) {
        super.init(frame: frame, configuration: configuration)
        // WebKit's own colour wherever it has none of the page's yet: as a
        // page commits, before its colour comes, and while the view is
        // see-through (holdBlankUntilFirstPage). Left to itself that is the
        // system's background, black in dark mode; the app's ground follows
        // the appearance as the rest of the window does, and is white in
        // light mode, as before. A page's own colour still wins.
        backgroundColor = Palette.UI.ground
        holdBlankUntilFirstPage()
        guard keyboardByWindow else { return }
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// A new view's first load paints WebKit's empty first document, white
    /// whatever the window's appearance, for as long as the page takes to
    /// answer: a white flash in dark mode. Until its first page commits the
    /// view is see-through to WebKit (its own colour, the app's ground,
    /// shows). From the first commit on, WebKit paints as it always has: a
    /// page with no background of its own is white, and one that says it can
    /// be dark (`color-scheme`) is dark.
    private(set) var holdsBlank = false

    private func holdBlankUntilFirstPage() {
        holdsBlank = true
        isOpaque = false
    }

    /// Page's navigation delegate, as each page commits.
    func pageCommitted() {
        guard holdsBlank else { return }
        holdsBlank = false
        isOpaque = true
    }

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        switch stripSide {
        case .maxXEdge?: insets.right = 0
        case .minXEdge?: insets.left = 0
        default: break
        }
        return insets
    }

    private static let arrows = [
        UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
        UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
    ]
    /// The arrow combinations design tools use: alone, a step; with ⇧, ten;
    /// with ⌥, ⌘ and their mixes, their own moves.
    private static let arrowModifiers: [UIKeyModifierFlags] = [
        [], [.shift], [.alternate], [.alternate, .shift], [.command], [.command, .shift],
    ]

    override var keyCommands: [UIKeyCommand]? {
        let own = super.keyCommands ?? []
        guard let page, !page.isHandsOff else { return own }
        let keys = page.bridges.keys
        var relayed: [UIKeyCommand] = []
        if keys.contains(.tab) {
            relayed.append(command("\t", []))
            relayed.append(command("\t", [.shift]))
        }
        if keys.contains(.arrows), !page.editing {
            for arrow in PageView.arrows {
                for flags in PageView.arrowModifiers { relayed.append(command(arrow, flags)) }
            }
        }
        return own + relayed
    }

    private func command(_ input: String, _ flags: UIKeyModifierFlags) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(relayKey(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func relayKey(_ sender: UIKeyCommand) {
        page?.relay(sender)
    }
}
