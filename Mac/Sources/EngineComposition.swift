import AppKit
import PadCore
import WebEngineAppKit
import WebKitExtensions
import WebKitSupport

/// The Mac's selected engine and extension runtime. Dependencies are
/// requested only where the original factories asked for them.
@MainActor
enum EngineComposition {
    static func makePageEngine() -> any MacPageEngine {
        AppPageEngine(factory: pageFactory)
    }

    @MainActor static let pageFactory = WebKitMacPageFactory(
        applicationNameForUserAgent: { Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion) },
        runtime: { Extensions.shared.runtime as! WebKitExtensionRuntime },
        isExtensionPage: { Extensions.shared.isExtensionPage($0) },
        captureRuntime: { captureRuntime })

    @MainActor private static var captureRuntime: WebKitExtensionRuntime {
        _ = ExtensionCapture.shared
        return Extensions.shared.runtime as! WebKitExtensionRuntime
    }

    static let pageCapture = WebKitMacPageFactory.pageCapture(runtime: { captureRuntime })

    @MainActor static func makeExtensionRuntime() -> any WebExtensionRuntime {
        WebKitExtensionRuntime(host: ExtensionHost.shared, storage: storage,
            pageFactory: {
                // Keep Session's first use at the original configuration lookup.
                _ = Session.shared.engine
                return pageFactory
            },
            unanswered: { Extensions.Unanswered(why: $0) },
            browserAnswers: { concreteBrowserAnswers }, scriptAnswers: { concreteScriptAnswers })
    }

    nonisolated static let storage: any WebExtensionStorage = ExtensionStorage(environment: {
        ExtensionHost.shared.extensionStorageEnvironment
    }, withoutShim: {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "extensionsWithoutShim")
        #else
        false
        #endif
    })
    @MainActor private static let concreteBrowserAnswers = WebKitExtensionBrowserAnswers(host: ExtensionHost.shared,
        unanswered: { Extensions.Unanswered(why: $0) }, scheme: scheme)
    @MainActor private static let concreteScriptAnswers = WebKitExtensionScriptAnswers(host: ExtensionHost.shared,
        prepared: { storage.prepared($0, $1) }, unanswered: { Extensions.Unanswered(why: $0) })
    @MainActor static var browserAnswers: any WebExtensionBrowserAnswers { concreteBrowserAnswers }
    @MainActor static var scriptAnswers: any WebExtensionScriptAnswers { concreteScriptAnswers }
    @MainActor static var pressed: [String: Date] {
        get { WebKitExtensionPermissions.pressed }
        set { WebKitExtensionPermissions.pressed = newValue }
    }
    @MainActor static let scheme = WebKitExtensionControllers.scheme
    @MainActor static let workersKey = ExtensionWorkers.workersKey
    @MainActor static let shimApplication = WebKitExtensionRuntimeAnswers.applicationIdentifier
    @MainActor static let largestFolder = WebKitExtensionInstallExecution.largestFolder
    @MainActor static let mostFiles = WebKitExtensionInstallExecution.mostFiles
    @MainActor static func registerScheme() { WebKitExtensionControllers.registerScheme() }
    @MainActor static func workersChanged() { ExtensionWorkers.markWorkersChanged() }
    @MainActor static func fingerprint(_ text: String) -> String { WebKitExtensionEvidence.fingerprint(text) }
    @MainActor static func zipped(_ folder: URL) async throws -> Data {
        try await WebKitExtensionInstallExecution.zipFolder(folder, refused: { Extensions.Refused($0) })
    }
    @MainActor static func sha256(_ data: Data) -> String { WebKitExtensionInstallExecution.checksum(data) }
    @MainActor static func words(_ text: String?, enabled: Bool) -> String { WebKitExtensionDiagnostics.words(text, enabled: enabled) }
    @MainActor static func note(_ line: String, outputPath: String?) { WebKitExtensionDiagnostics.note(line, outputPath: outputPath) }
    @MainActor static func appName(ofHost host: String) -> String { WebKitExtensionRuntimeAnswers.appName(ofHost: host) }
    @MainActor static func name(in archive: Data, manifest: ExtensionManifest, fallback: String) -> String {
        WebKitExtensionMetadata.name(in: archive, manifest: manifest, fallback: fallback)
    }
    @MainActor static func icon(in archive: Data, manifest: ExtensionManifest) -> NSImage? {
        WebKitExtensionMetadata.icon(in: archive, manifest: manifest)
    }
    @MainActor static func authOwner(of url: URL?) -> String? { WebKitExtensionAuth.owner(of: url) }
    @MainActor static let authNotLoaded = WebKitExtensionAuth.notLoaded
    @MainActor private static let nativeTransport: any WebExtensionNativeTransport = WebKitExtensionNativeConnection()
    @MainActor static func nativeConnection(program: URL, origin: String) -> any WebNativeConnection {
        nativeTransport.nativeConnection(program: program, origin: origin)
    }
    @MainActor static func sweepStores() { Stores.sweep(in: WebKitSpaceStores.shared) }
}
