import AppKit
import SwiftUI
import WebEngineAppKit

extension ExtensionHost: ExtensionRuntimeAnswerHost {
    func extensionRuntimeInstallation(_ id: String) -> WebExtensionEvidenceInstallation? {
        Extensions.shared.installed.first { $0.id == id }.map { .init(id: $0.id, version: $0.version) }
    }
    func updateExtensionRuntimeAnswer(_ id: String, in space: UUID, event: WebExtensionRuntimeAnswerEvent) {
        switch event {
        case .problem(let problem): Extensions.shared.update(id, in: space) { $0.problems.insert(problem.policyProblem) }
        case .unreachableApp(let name): Extensions.shared.update(id, in: space) { $0.unreachableApp = name }
        }
    }
    func extensionNativeIsOptional(_ id: String) -> Bool { Extensions.shared.asksForNativeOnlyOptionally(id) }
    func extensionReachesApps(_ id: String) -> Bool { Extensions.shared.reachesApps(id) }
    func setExtensionNativeConsent(_ id: String, _ on: Bool) { Extensions.shared.setNativeConsent(id, on) }

    func requestExtensionNative(title: String, in space: UUID, icon: () -> NSImage?) async -> Bool {
        let window = Session.shared.frontWindow
        // The same sheet as askForMore, with its image supplied by the runtime.
        // Keep the window, image, space and content reads in their old order.
        let image = icon()
        let place = Session.shared.workspace.space(space)
        let content = NativeAppsGroup()
        return await Extensions.shared.ask(in: window) { answer in
            ExtensionAskSheet(image: image, title: title,
                              subtitle: place.map { place in AnyView(Label { Text("In \(place.name)") } icon: { SpaceName(space: place, showsName: false) }) },
                              note: nil, cancel: String(localized: "Don't Allow"), confirm: String(localized: "Allow"),
                              answer: { answer($0) }) { content }
        } == true
    }

    func detectExtensionLanguage(_ text: String) -> [String: Any] { ExtensionLanguage.detect(text).json }
    func sampleExtensionColour() async -> NSColor? {
        await withCheckedContinuation { done in
            DispatchQueue.main.async { NSColorSampler().show { done.resume(returning: $0) } }
        }
    }
    func noteExtensionRuntimeReport(_ api: String?, words: () -> String?) {
        #if DEBUG
        Extensions.note("shim report: \(api ?? "no API named")" + Extensions.words(words()))
        #endif
    }
}
