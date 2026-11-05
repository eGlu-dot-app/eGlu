import AppKit
import Combine
import WebEngineAppKit
import WebKitExtensions

/// The app's consent, remembered answer and recording pill.
@MainActor
final class ExtensionCapture: NSObject, ObservableObject {
    static let shared = ExtensionCapture()
    private(set) var runtime: ExtensionCaptureRuntime!

    override private init() {
        super.init()
        runtime = ExtensionCaptureRuntime(scheme: Extensions.scheme, host: ExtensionHost.shared,
            space: { Extensions.shared.space(of: $0) },
            context: { Extensions.shared.context($0, in: $1) },
            declares: { Extensions.asks($0, for: "desktopCapture") })
    }

    static func key(_ id: String) -> String { "extensionCapture.\(id)" }

    /// You let it record.
    static func allowed(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: key(id)) }

    /// Taken back: asked again the next time it wants to record, and any
    /// id it was given and hasn't used is good no more.
    static func forget(_ id: String) {
        UserDefaults.standard.removeObject(forKey: key(id))
        shared.runtime.forget(id)
        shared.refused.remove(id)
        shared.objectWillChange.send()
    }

    /// Refused this launch: not asked again until eGlu starts afresh, so an
    /// extension can't wear you down with the question.
    private var refused: Set<String> = []

    /// Yes from you: now, or before and you have just used this extension
    /// (its button within the last minute, Loom's Start being in its menu
    /// over the page; its popup or its pages within the last five seconds).
    /// Otherwise it is asked again: a remembered yes never lets an
    /// extension take the screen on its own.
    func consent(_ id: String, in space: UUID, used: () -> Bool, name: () -> String) async -> Bool {
        let pressed = Extensions.pressed["\(space.uuidString)/\(id)"].map { Date().timeIntervalSince($0) < 60 } ?? false
        let used = used()
        if Self.allowed(id), pressed || used { return true }
        guard !refused.contains(id) else { return false }
        let name = name()
        let alert = NSAlert()
        alert.messageText = String(localized: "Let \u{201C}\(name)\u{201D} record your screen?")
        alert.informativeText = String(localized: "The Mac then asks what to share. eGlu asks again unless you've just used the extension. You can take this back in Settings › Extensions.")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        let window = Session.shared.allWindows.first { $0.spaceID == space && $0.window?.isKeyWindow == true }
            ?? Session.shared.allWindows.first { $0.spaceID == space && $0.window?.isVisible == true }
        guard let window, await Extensions.shared.present(alert, in: window) == .alertFirstButtonReturn else {
            if window != nil { refused.insert(id) }
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.key(id))
        objectWillChange.send()
        return true
    }

}

extension ExtensionHost: ExtensionCaptureHost {
    func setExtensionCaptureStop(_ stop: @escaping (String) -> Void) {
        RecordingIndicator.shared.onStop = stop
    }

    func extensionCaptureAllowed(_ id: String) -> Bool { ExtensionCapture.allowed(id) }

    func requestExtensionCapture(_ id: String, in space: UUID, used: () -> Bool, name: () -> String) async -> Bool {
        await ExtensionCapture.shared.consent(id, in: space, used: used, name: name)
    }

    func bringExtensionCaptureForward(_ web: NSView) {
        let session = Session.shared
        if let (tab, page) = session.pages.live.first(where: { $0.value.enginePage.contentView === web }).map({ ($0.key, $0.value) }) {
            let window = session.allWindows.first { $0.shows(tab) }
                ?? session.allWindows.first { $0.spaceID == page.space }
            if let window {
                if !window.shows(tab) { window.select(tab) }
                window.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            web.window?.makeKeyAndOrderFront(nil)
        }
    }

    func lendExtensionCaptureView(_ view: NSView) { RecordingIndicator.shared.host(view) }
    func giveBackExtensionCaptureView(_ view: NSView) { RecordingIndicator.shared.release(view) }

    func extensionCaptureName(_ id: String) -> String {
        Extensions.shared.installed.first { $0.id == id }?.name ?? String(localized: "An extension")
    }

    func updateExtensionCapture(_ lines: [ExtensionCaptureState]) {
        let shown = lines.map { line -> RecordingLine in
            let what = line.screen ? String(localized: "is recording your screen")
                : line.camera && line.microphone ? String(localized: "is using your camera and microphone")
                : line.camera ? String(localized: "is using your camera") : String(localized: "is using your microphone")
            return RecordingLine(id: line.id, name: line.name, what: what)
        }.sorted { $0.name < $1.name }
        RecordingIndicator.shared.update(shown)
    }
}
