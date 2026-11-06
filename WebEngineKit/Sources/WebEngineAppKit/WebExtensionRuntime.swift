import Foundation

/// The plugin owns execution; the app owns its catalog and presentation.
@MainActor public protocol WebExtensionRuntime:
    WebExtensionStorage, WebExtensionMetadata, WebExtensionCompatibility,
    WebExtensionControllers, WebExtensionWorkers, WebExtensionEvidenceRuntime,
    WebExtensionCleanup, WebExtensionInstallExecution, WebExtensionRuntimeAnswers,
    WebExtensionScriptAnswers, WebExtensionBrowserAnswers, WebExtensionPermissions,
    WebExtensionAdapters, WebExtensionDiagnostics, WebExtensionDispatch {}
