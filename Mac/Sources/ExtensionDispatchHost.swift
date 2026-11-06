import AppKit
import PadCore
import WebEngineAppKit

extension ExtensionHost: ExtensionDispatchHost {
    func extensionActionsChanged() { Extensions.shared.actionsDidChange() }
    func presentExtensionActionPopup(in space: UUID, tab: UUID?, address: () -> URL?,
                                     page: (URL, UUID) -> ExtensionPanePage?) {
        let windows = Session.shared.allWindows.filter { $0.spaceID == space }
        guard let window = windows.first(where: { $0.tabID == tab && $0.window?.isKeyWindow == true })
                ?? windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first,
              let url = address() else { return }
        ExtensionPopups.shared.show(in: window) { page(url, window.spaceID) }
    }
    func runExtensionAuth(_ url: URL, extension id: String, in space: UUID,
                          openTab: () -> UUID?) async throws -> URL {
        try await ExtensionAuth.run(url, extension: id, in: space, openTab: openTab)
    }
    func extensionFirstLookNativeFacts(_ facts: WebExtensionManifestFacts, of id: String) {
        Extensions.shared.noteNativeFacts(facts, of: id)
    }
    func extensionFirstLookEvidence(_ seen: WebExtensionEvidence, id: String) -> WebExtensionEvidence {
        Extensions.shared.firstLookProduct(seen, id: id)
    }
    func noteExtensionError(_ api: String, words: () -> String?) {
        #if DEBUG
        Extensions.note("webkit error: \(api)" + Extensions.words(words()))
        #endif
    }
    func extensionKey(_ name: String) -> String? { ExtensionKeys.shared.given[name]?.stored }
    func suggestExtensionKey(_ key: String?, for name: String) {
        ExtensionKeys.shared.suggest(key.flatMap(ExtensionKey.init(stored:)), for: name)
    }
    func extensionHasEnabledItems(in space: UUID) -> Bool { !Extensions.shared.on(in: space).isEmpty }
}

extension ExtensionHost: ExtensionRuntimeHost {}
