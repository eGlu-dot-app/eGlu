import WebKit

/// The settings for a new page in a space.
@MainActor
public enum WebKitConfiguration {
    public static func make(store: WKWebsiteDataStore,
                            extensionController: WKWebExtensionController?,
                            applicationNameForUserAgent: String) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        // Safari, by name: the end of the user agent that WebKit leaves to
        // the app (Identity.swift). Without it sites read the app as a web
        // view inside an app, and Google refuses to sign in.
        config.applicationNameForUserAgent = applicationNameForUserAgent
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.preferences.isElementFullscreenEnabled = true
        // window.open only from a click or a key, as Safari's pop-up
        // blocking has it; a sign-in window opened by its button opens.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // macOS's own picture in picture for a video (appWentBehind, and a
        // site's own button): WebKit has it, and turns it off in an app's
        // web views on macOS, with no public switch. This one is private: a
        // DMG has no App Review, and a macOS that takes it away leaves
        // picture in picture off, as it was. With the underscore the key
        // finds no setter and throws; without it, `_setAllows…:` is found.
        if config.preferences.responds(to: Selector(("_setAllowsPictureInPictureMediaPlayback:"))) {
            config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        // Right-click Inspect Element and console logging to the page's own
        // inspector: the same private switch Safari has, found the same way.
        // The developer tools need the _inspector object, not this; it only
        // opens WebKit's own inspector for a page that asks to be inspected.
        if config.preferences.responds(to: Selector(("_setDeveloperExtrasEnabled:"))) {
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        // The space's extensions (Extensions): WebKit takes a page's
        // controller only before the page's view is made.
        config.webExtensionController = extensionController
        return config
    }
}
