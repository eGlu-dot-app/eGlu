import AppKit
import WebEngineAppKit

/// The app's media question and neutral-view calls to the capture runtime.
extension ExtensionHost: ExtensionAuxiliaryPageHost {
    func releaseExtensionPage(_ view: NSView) {
        Extensions.shared.runtime.releaseCapture(view)
    }

    func extensionDisplayDecision(for view: NSView) -> Int {
        return Extensions.shared.runtime.displayCaptureDecision(for: view)
    }

    func watchExtensionPage(_ view: NSView, id: String) {
        Extensions.shared.runtime.watchCapture(view, id: id)
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
