import AppKit
import WebKit

/// WebKit's own spell checking, off while Harper checks the pages' English,
/// so a word is not underlined twice, and back as it was once Harper stops
/// (Docs/Tasks/02 Decided 15). WebKit keeps it for the whole app, in its
/// defaults (WebContinuousSpellCheckingEnabled), so one page's switch is
/// every page's, the ones open now included.
@MainActor
public enum WebKitSpelling {
    private static let defaultsKey = "WebContinuousSpellCheckingEnabled"
    /// What it was before Harper took over; nil while Harper is off.
    private static let wasKey = "egluSpellingBeforeWriting"
    // WKWebView answers these as NSTextView does, under the same names.
    private static let isOn = #selector(getter: NSTextView.isContinuousSpellCheckingEnabled)
    private static let toggle = #selector(NSTextView.toggleContinuousSpellChecking(_:))

    /// Checking in pages turned on or off: WebKit's spell checking follows.
    /// Only on the change itself, so a person who turns it back on in Edit ›
    /// Spelling and Grammar keeps it.
    public static func follow(writing: Bool, views: [WKWebView]) {
        let defaults = UserDefaults.standard
        // A page that is open answers for WebKit as it runs; with none, its
        // defaults do, which it reads when the first page opens.
        let view = views.first { $0.responds(to: isOn) && $0.responds(to: toggle) }
        let current = view.flatMap { $0.value(forKey: "continuousSpellCheckingEnabled") as? Bool }
            ?? defaults.object(forKey: defaultsKey) as? Bool ?? true
        let wanted: Bool
        if writing {
            if defaults.object(forKey: wasKey) == nil { defaults.set(current, forKey: wasKey) }
            wanted = false
        } else {
            guard let was = defaults.object(forKey: wasKey) as? Bool else { return }
            defaults.removeObject(forKey: wasKey)
            wanted = was
        }
        guard wanted != current else { return }
        if let view {
            // Edit › Spelling and Grammar's own action: WebKit changes it
            // for every page at once and keeps it in its defaults itself.
            NSApp.sendAction(toggle, to: view, from: nil)
        } else {
            defaults.set(wanted, forKey: defaultsKey)
        }
    }
}
