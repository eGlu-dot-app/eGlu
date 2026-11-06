import Foundation
import WebEngineAppKit

extension ExtensionHost: ExtensionStorageHost {
    var extensionStorageEnvironment: WebExtensionStorageEnvironment {
        WebExtensionStorageEnvironment(root: Extensions.folder, temporaryRoot: FileManager.default.temporaryDirectory)
    }
}
