import PadCore
import WebKit

extension NewTabClick {
    /// Whether a navigation is a ⌘-click (or ⌘⇧, or a middle click) to open
    /// in a new tab, from what WebKit says started it and the keys and the
    /// button each app finds made it.
    @MainActor
    static func choice(for action: WKNavigationAction, command: Bool, shift: Bool, middleButton: Bool) -> Choice {
        let kind: Kind
        switch action.navigationType {
        case .linkActivated: kind = .link
        case .formSubmitted: kind = .form
        case .other: kind = .script
        default: kind = .history
        }
        return choice(kind: kind, command: command, shift: shift, middleButton: middleButton,
                      method: action.request.httpMethod, scheme: action.request.url?.scheme,
                      mainFrame: action.targetFrame?.isMainFrame ?? true)
    }
}
