import Foundation

/// The app answers the runtime with values and inline product operations.
@MainActor public protocol ExtensionRuntimeHost:
    ExtensionBrowserHost, ExtensionAuxiliaryPageHost, ExtensionMetadataHost,
    ExtensionCompatibilityHost, ExtensionControllerHost, ExtensionWorkerHost,
    ExtensionEvidenceHost, ExtensionCleanupHost, ExtensionInstallHost,
    ExtensionRuntimeAnswerHost, ExtensionScriptHost, ExtensionBrowserAnswerHost,
    ExtensionPermissionHost, ExtensionCaptureHost, ExtensionDiagnosticHost,
    ExtensionDispatchHost {}
