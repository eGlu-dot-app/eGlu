import WebKit

/// WebKit's own Web Inspector, a private API (WKWebViewPrivate.h: every
/// WKWebView keeps an `_inspector`, a _WKInspector with show(), showConsole()
/// and toggleElementSelection()) gone at behind responds(to:), as the DMG
/// may and the other private calls in WebKitConfiguration.make do. A WebKit that
/// takes it away leaves show() false, and the caller says Safari's Develop
/// menu is the way instead.
enum WebInspector {
    enum Part {
        case inspector
        case console
        case elements
    }

    /// The part asked for, opened for the page in `view`. False where this
    /// WebKit doesn't answer; the inspector opens in its own window.
    @discardableResult
    static func show(_ part: Part, for view: WKWebView) -> Bool {
        guard view.responds(to: Selector(("_inspector"))),
              let inspector = view.value(forKey: "_inspector") as? NSObject
        else { return false }
        let verb: Selector
        switch part {
        case .inspector: verb = NSSelectorFromString("show")
        case .console: verb = NSSelectorFromString("showConsole")
        case .elements: verb = NSSelectorFromString("toggleElementSelection")
        }
        guard inspector.responds(to: verb) else { return false }
        inspector.perform(verb)
        return true
    }

    /// What is shown where WebKit doesn't answer (the menu, the command
    /// bar's row, the developer bar's buttons, all going through show()).
    static let unavailable = String(localized: "Open it from Safari › Develop › eGlu.")
}
