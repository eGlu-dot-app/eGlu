import Foundation
import IOKit.pwr_mgt
import WebEngineAppKit

extension ExtensionHost: ExtensionWorkerHost {
    var extensionWorkerSpaces: [UUID] { Session.shared.workspace.spaces.map(\.id) }
    var extensionWorkerInstallations: [WebExtensionWorkerInstallation] {
        Extensions.shared.installed.map { Extensions.shared.workerInstallation($0) }
    }
    func extensionWorkerCheckStamp(_ version: String) -> String { Extensions.shared.workerCheckStamp(version) }
    func resetExtensionWorkerCompatibility(_ id: String) { Extensions.shared.resetWorkerCompatibility(id) }
    func markExtensionWorkerIncompatible(_ id: String, version: String) {
        Extensions.shared.markWorkerIncompatible(id, version: version)
    }
    func updateExtensionWorker(_ id: String, in space: UUID, event: WebExtensionWorkerEvent) {
        Extensions.shared.updateWorker(id, in: space, event: event)
    }
    func releaseExtensionWorkerPower(_ key: String) {
        if let assertion = Extensions.shared.keptAwake.removeValue(forKey: key) { IOPMAssertionRelease(assertion) }
    }
    func noteExtensionWorker(_ line: String) {
        #if DEBUG
        Extensions.note(line)
        #endif
    }
}
