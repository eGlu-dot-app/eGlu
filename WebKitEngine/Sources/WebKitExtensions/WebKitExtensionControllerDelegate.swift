#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit

/// WebKit makes these configurations. Fixtures supply the same lazy reads.
@MainActor protocol ExtensionTabOpening {
    var url: URL? { get }
    var shouldBeActive: Bool { get }
    var shouldBePinned: Bool { get }
}
extension WKWebExtension.TabConfiguration: ExtensionTabOpening {}

@MainActor protocol ExtensionWindowOpening {
    var shouldBePrivate: Bool { get }
    var tabURLs: [URL] { get }
    var windowType: WKWebExtension.WindowType { get }
    var frame: CGRect { get }
    var shouldBeFocused: Bool { get }
}
extension WKWebExtension.WindowConfiguration: ExtensionWindowOpening {}

@MainActor protocol ExtensionActionPresenting {
    var popupWebView: WKWebView? { get }
    var associatedTab: (any WKWebExtensionTab)? { get }
    func closePopup()
}
extension WKWebExtension.Action: ExtensionActionPresenting {}

/// The controller retains its original callback actor and call order.
@MainActor
final class WebKitExtensionControllerDelegate: NSObject {
    static let scheme = WebKitExtensionControllers.scheme
    let unanswered: (String) -> any Error
    let tabs: ExtensionTabs
    let host: any ExtensionDispatchHost
    let auxiliaryHost: any ExtensionAuxiliaryPageHost
    let space: (WKWebExtensionController?) -> UUID?
    let permissionPrompts: () -> WebKitExtensionPermissions
    let runtimeAnswers: () -> WebKitExtensionRuntimeAnswers
    let browserAnswers: () -> WebKitExtensionBrowserAnswers

    init(tabs: ExtensionTabs, host: any ExtensionDispatchHost, auxiliaryHost: any ExtensionAuxiliaryPageHost,
         space: @escaping (WKWebExtensionController?) -> UUID?,
         permissions: @escaping () -> WebKitExtensionPermissions,
         answers: @escaping () -> WebKitExtensionRuntimeAnswers,
         browser: @escaping () -> WebKitExtensionBrowserAnswers,
         unanswered: @escaping (String) -> any Error) {
        self.unanswered = unanswered
        self.tabs = tabs; self.host = host; self.auxiliaryHost = auxiliaryHost; self.space = space
        self.permissionPrompts = permissions; self.runtimeAnswers = answers; self.browserAnswers = browser
        super.init()
    }

    func space(of controller: WKWebExtensionController?) -> UUID? { space(controller) }
}

extension WebKitExtensionControllerDelegate: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let space = space(of: controller) else { return [] }
        return tabs.openWindows(in: space)
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let space = space(of: controller) else { return nil }
        return tabs.focusedWindow(in: space)
    }

    /// Where an extension may not send a tab: to javascript:, which would
    /// run its code in whatever page the tab shows, a site it may have no
    /// access to, nor to a file on this Mac. Chrome refuses both. (Search)
    nonisolated static func refusal(opening url: URL?, unanswered: (String) -> any Error) -> Error? {
        guard let scheme = url?.scheme?.lowercased(), ["javascript", "file"].contains(scheme) else { return nil }
        return unanswered("Cannot navigate to a \(scheme): URL.")
    }

    /// The same, for `context`, and never another extension's page: a
    /// tab it opened or sent there would load that page, a password
    /// manager's vault among them, and eGlu's own load of it passes the
    /// check websites are held to.
    static func refusal(opening url: URL?, by context: WKWebExtensionContext, unanswered: (String) -> any Error) -> Error? {
        if let refused = refusal(opening: url, unanswered: unanswered) { return refused }
        guard WebKitExtensionControllers.othersPage(url, for: context) else { return nil }
        return unanswered("Cannot navigate to another extension's page.")
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        openNewTab(controller, using: configuration, for: extensionContext, completionHandler: completionHandler)
    }

    func openNewTab(_ controller: WKWebExtensionController, using configuration: any ExtensionTabOpening,
                     for extensionContext: WKWebExtensionContext,
                     completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        if let refused = Self.refusal(opening: configuration.url, by: extensionContext, unanswered: unanswered) { return completionHandler(nil, refused) }
        guard let space = space(of: controller) else { return completionHandler(nil, nil) }
        let tab = tabs.open(configuration.url, in: space, active: configuration.shouldBeActive,
                            pinned: configuration.shouldBePinned, context: extensionContext)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        openNewWindow(controller, using: configuration, for: extensionContext, completionHandler: completionHandler)
    }

    func openNewWindow(_ controller: WKWebExtensionController, using configuration: any ExtensionWindowOpening,
                     for extensionContext: WKWebExtensionContext,
                     completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // eGlu has no private windows: made as a normal one, its pages would
        // land in the space's store and History while the extension believed
        // them private. Refused, as Chrome refuses an extension not allowed
        // in incognito. (Search)
        if configuration.shouldBePrivate {
            return completionHandler(nil, tabs.host.privateWindowRefusal())
        }
        if let refused = configuration.tabURLs.lazy.compactMap({ Self.refusal(opening: $0, by: extensionContext, unanswered: self.unanswered) }).first { return completionHandler(nil, refused) }
        guard let space = space(of: controller) else { return completionHandler(nil, nil) }
        // A popup, as a password manager's vault or a sign-in opens: a small
        // window of its page (ExtensionPopupWindow), only a website or the
        // extension's own page.
        if configuration.windowType == .popup, let url = configuration.tabURLs.first ?? URL(string: "about:blank") {
            guard let made = ExtensionPopupWindow.open(url, for: extensionContext, in: space, controller: controller,
                                                       frame: configuration.frame, focused: configuration.shouldBeFocused, owner: tabs, scheme: Self.scheme)
            else { return completionHandler(nil, unanswered("Cannot open a popup window at that address.")) }
            return completionHandler(made, nil)
        }
        // A space is one window to extensions: a new one shows the same space,
        // with its first address in a tab.
        for url in configuration.tabURLs.prefix(1) {
            _ = tabs.open(url, in: space, active: true, pinned: false, context: extensionContext)
        }
        tabs.host.ensureWindow(in: space)
        completionHandler(tabs.window(for: space), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let space = space(of: controller), let url = WebKitExtensionMetadata.optionsPageURL(for: extensionContext) else { return completionHandler(nil) }
        _ = tabs.open(url, in: space, active: true, pinned: false, context: extensionContext)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        permissionPrompts().promptForPermissions(permissions, controller: controller, tab: tab, context: extensionContext,
                                               completionHandler: completionHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        permissionPrompts().promptForPermissionToAccess(urls, completionHandler: completionHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        permissionPrompts().promptForPermissionMatchPatterns(matchPatterns, controller: controller, tab: tab, context: extensionContext,
                                                          completionHandler: completionHandler)
    }

    /// The popup, in eGlu's own pane (ExtensionPopup), in the window
    /// showing the tab it was asked for, or the space's front window. At
    /// the page WebKit opened for it, which is the one set for that tab if
    /// there is one; WebKit's own is closed at once, as Search's is, so
    /// WebKit doesn't take it for open still and a second press works.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        presentPopup(controller, action: action, for: context, completionHandler: completionHandler)
    }

    func presentPopup(_ controller: WKWebExtensionController, action: any ExtensionActionPresenting,
                      for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let opened = action.popupWebView?.url
        action.closePopup()
        guard let space = space(of: controller) else { return completionHandler(nil) }
        let tab = (action.associatedTab as? ExtensionTab)?.id
        host.presentExtensionActionPopup(in: space, tab: tab, address: {
            opened.flatMap { $0.scheme == Self.scheme ? $0 : nil } ?? browserAnswers().popupURL(for: context, in: space)
        }, page: { url, space in
            ExtensionSurface.page(url, for: context, in: space, scheme: Self.scheme,
                                  tabs: tabs, host: auxiliaryHost)
        })
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        host.extensionActionsChanged()
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        runtimeAnswers().webExtensionController(controller, sendMessage: message, toApplicationWithIdentifier: applicationIdentifier,
                                             for: extensionContext, replyHandler: replyHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtimeAnswers().webExtensionController(controller, connectUsing: port, for: extensionContext, completionHandler: completionHandler)
    }
}

#endif
