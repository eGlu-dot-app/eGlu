import WebEngineAppKit

extension ExtensionHost: ExtensionInstallHost {
    func extensionInstallRefusal(_ refusal: WebExtensionInstallRefusal) -> any Error {
        Extensions.Refused(refusal)
    }

    func noteExtensionInstallFacts(_ facts: WebExtensionManifestFacts?, of id: String) {
        Extensions.shared.noteInstallFacts(facts, of: id)
    }
}
