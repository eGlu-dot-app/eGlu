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
