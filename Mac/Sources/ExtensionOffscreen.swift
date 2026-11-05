import AppKit
import WebEngineAppKit
import WebKit

/// The app's question and the bridge to capture until its runtime moves.
/// Capture still takes WebKit views; the recording indicator takes NSView.
extension ExtensionHost: ExtensionAuxiliaryPageHost {
    func releaseExtensionPage(_ view: NSView) {
        guard let web = view as? WKWebView else { return }
        ExtensionCapture.shared.release(web)
    }

    func extensionDisplayDecision(for view: NSView) -> Int {
        guard let web = view as? WKWebView else { return 0 }
        return ExtensionCapture.shared.displayDecision(for: web)
    }

    func watchExtensionPage(_ view: NSView, id: String) {
        guard let web = view as? WKWebView else { return }
        ExtensionCapture.shared.watch(web, id: id)
    }

    func requestExtensionMedia(_ media: ExtensionPageMedia, name: String,
                               reply: @escaping @MainActor (Bool) -> Void) {
        guard let window = Session.shared.frontWindow, window.window?.isVisible == true else { return reply(false) }
        let alert = NSAlert()
        switch media {
        case .camera: alert.messageText = String(localized: "Let \u{201C}\(name)\u{201D} use your camera?")
        case .microphone: alert.messageText = String(localized: "Let \u{201C}\(name)\u{201D} use your microphone?")
        default: alert.messageText = String(localized: "Let \u{201C}\(name)\u{201D} use your camera and microphone?")
        }
        alert.informativeText = String(localized: "It asks from a page of its own you can't see. While it records, a pill at the foot of the screen says so, with Stop.")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        Task {
            let yes = await Extensions.shared.present(alert, in: window) == .alertFirstButtonReturn
            reply(yes)
        }
    }
}
