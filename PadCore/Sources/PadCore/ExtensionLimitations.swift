import Foundation

public enum ExtensionLimitations {
    /// Fixed explanations for capabilities that cannot be supplied by this browser.
    public static func explanation(for api: String) -> String? {
        let specific: [String: String] = [
            "identity.getAuthToken": BrowserText.localized("This extension can't use Chrome's signed-in Google account. Use the extension's website sign-in when available."),
            "downloads.pause": BrowserText.localized("This extension can't pause downloads. Cancel and resume the download if the server supports it."),
            "downloads.open": BrowserText.localized("This extension can't open downloaded files automatically. Open the file from Downloads or Finder."),
            "downloads.setUiOptions": BrowserText.localized("This extension can't hide the browser's download controls."),
            "downloads.setShelfEnabled": BrowserText.localized("This extension can't hide the browser's download controls."),
            "downloads.acceptDanger": BrowserText.localized("This extension can't bypass download protections."),
            "bookmarks.getRecent": BrowserText.localized("This extension can't list bookmarks by creation date because this browser does not store bookmark creation dates."),
            "sessions.getDevices": BrowserText.localized("This extension can't read tabs from other devices. It can restore recently closed tabs in this space."),
            "tabs.setZoomSettings": BrowserText.localized("This extension can't change how page zoom is shared between tabs or websites."),
            "runtime.getPackageDirectoryEntry": BrowserText.localized("This extension can't access its package through Chrome's old file system API."),
            "declarativeNetRequest.updateStaticRules": BrowserText.localized("This extension can't turn individual rules in a static rule set on or off. Whole rule sets can still be enabled or disabled."),
            "declarativeNetRequest.testMatchOutcome": BrowserText.localized("This extension can't test network filtering rules through Chrome's debugging API."),
        ]
        if let words = specific[api] { return words }
        let namespace = api.split(separator: ".").first.map(String.init) ?? api
        let descriptions: [String: String] = [
            "tabCapture": BrowserText.localized("This extension can't record an individual tab. Use screen sharing when the extension offers it."),
            "pageCapture": BrowserText.localized("This extension can't save pages in Chrome's MHTML format."),
            "debugger": BrowserText.localized("This extension can't inspect or control pages through Chrome's debugging protocol."),
            "gcm": BrowserText.localized("This extension can't receive push messages through Google's extension messaging service."),
            "instanceID": BrowserText.localized("This extension can't register with Google's extension messaging service."),
            "readingList": BrowserText.localized("This extension can't manage a reading list because this browser does not have one."),
            "proxy": BrowserText.localized("This extension can't change this browser's proxy settings."),
            "privacy": BrowserText.localized("This extension can't change browser privacy settings. It can check whether this browser saves and fills passwords."),
            "contentSettings": BrowserText.localized("This extension can't change website permissions or browser content settings."),
            "declarativeContent": BrowserText.localized("This extension can't show or hide its button based on page contents."),
            "devtools": BrowserText.localized("This extension can't add panels to this browser's developer tools."),
            "webAuthenticationProxy": BrowserText.localized("This extension can't handle another device's passkey requests through Chrome's authentication service."),
            "ttsEngine": BrowserText.localized("This extension can't register its own speech engine. Installed macOS voices are available for reading text aloud."),
            "cookies": BrowserText.localized("This extension can't read or change website cookies. Google's sign-in data stays protected."),
        ]
        if let words = descriptions[namespace] { return words }
        if ["accessibilityFeatures", "audio", "certificateProvider", "documentScan", "enterprise", "fileBrowserHandler", "fileSystemProvider", "input", "loginState", "platformKeys", "printerProvider", "printing", "printingMetrics", "vpnProvider", "wallpaper"].contains(namespace) {
            return BrowserText.localized("This extension can't use ChromeOS or managed device features on this Mac.")
        }
        return nil
    }
}
