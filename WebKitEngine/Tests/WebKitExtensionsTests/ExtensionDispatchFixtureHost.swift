#if os(macOS)
import AppKit
import WebEngineAppKit
import XCTest

/// Unexpected execution fails before a store, connection or page can be made.
@MainActor
final class DispatchFixtureHost: ExtensionRuntimeHost {
    let browser = BrowserHost()
    let root: URL
    var log: [String] = []
    var popupAddress: URL?
    var hasPageMaker = false
    init(root: URL) { self.root = root }
    var workspace: ExtensionBrowserWorkspace { browser.workspace }
    func observe(workspace: @escaping @MainActor (ExtensionBrowserWorkspace) -> Void,
                 focus: @escaping @MainActor (ExtensionBrowserFocus) -> Void) { browser.observe(workspace: workspace, focus: focus) }
    func record(_ tab: UUID) -> ExtensionBrowserTab? { browser.record(tab) }
    func livePage(_ tab: UUID) -> ExtensionBrowserPage? { browser.livePage(tab) }
    func window(in space: UUID) -> ExtensionBrowserWindow { browser.window(in: space) }
    func isFocused(in space: UUID) -> Bool { browser.isFocused(in: space) }
    func openTab(_ url: URL?, in space: UUID, active: Bool, pinned: Bool, extensionID: () -> String,
                 configuration: () -> (any ExtensionPageConfiguration)?) -> UUID? { browser.openTab(url, in: space, active: active, pinned: pinned, extensionID: extensionID, configuration: configuration) }
    func activateTab(_ tab: UUID, in space: UUID) { browser.activateTab(tab, in: space) }
    func closeTab(_ tab: UUID) { browser.closeTab(tab) }
    func loadTab(_ tab: UUID, in space: UUID, url: URL) { browser.loadTab(tab, in: space, url: url) }
    func reloadTab(_ tab: UUID, fromOrigin: Bool) { browser.reloadTab(tab, fromOrigin: fromOrigin) }
    func goBack(_ tab: UUID) { browser.goBack(tab) }
    func goForward(_ tab: UUID) { browser.goForward(tab) }
    func detectLocale(_ tab: UUID, in space: UUID, hasAccess: @escaping @MainActor (URL) -> Bool,
                      completionHandler: @escaping (Locale?, (any Error)?) -> Void) { browser.detectLocale(tab, in: space, hasAccess: hasAccess, completionHandler: completionHandler) }
    func setWindowFrame(_ frame: CGRect, in space: UUID) { browser.setWindowFrame(frame, in: space) }
    func focusWindow(in space: UUID) { browser.focusWindow(in: space) }
    func closeWindow(in space: UUID) -> (any Error)? { browser.closeWindow(in: space) }
    func ensureWindow(in space: UUID) { browser.ensureWindow(in: space) }
    func privateWindowRefusal() -> any Error { browser.privateWindowRefusal() }
    func openPopup(in space: UUID, configuration: (any ExtensionPageConfiguration)?, frame: CGRect,
                   closed: @escaping @MainActor () -> Void) -> UUID { browser.openPopup(in: space, configuration: configuration, frame: frame, closed: closed) }
    func startPopup(_ popup: UUID, url: URL) { browser.startPopup(popup, url: url) }
    func popupPage(_ popup: UUID) -> ExtensionBrowserPage? { browser.popupPage(popup) }
    func popupWindow(_ popup: UUID) -> ExtensionBrowserWindow { browser.popupWindow(popup) }
    func loadPopup(_ popup: UUID, url: URL) -> (any Error)? { browser.loadPopup(popup, url: url) }
    func reloadPopup(_ popup: UUID, fromOrigin: Bool) { browser.reloadPopup(popup, fromOrigin: fromOrigin) }
    func goBackInPopup(_ popup: UUID) { browser.goBackInPopup(popup) }
    func goForwardInPopup(_ popup: UUID) { browser.goForwardInPopup(popup) }
    func setPopupFrame(_ frame: CGRect, popup: UUID) { browser.setPopupFrame(frame, popup: popup) }
    func focusPopup(_ popup: UUID) { browser.focusPopup(popup) }
    func closePopup(_ popup: UUID) { browser.closePopup(popup) }
    func refocusFrontWindow() { browser.refocusFrontWindow() }
    func releaseExtensionPage(_ view: NSView) { fatalError("Unused fixture operation: releaseExtensionPage") }
    func extensionDisplayDecision(for view: NSView) -> Int { fatalError("Unused fixture operation: extensionDisplayDecision") }
    func watchExtensionPage(_ view: NSView, id: String) { fatalError("Unused fixture operation: watchExtensionPage") }
    func requestExtensionMedia(_ media: ExtensionPageMedia, name: String,
                               reply: @escaping @MainActor (Bool) -> Void) { fatalError("Unused fixture operation: requestExtensionMedia") }
    func extensionMetadataInstallation(_ id: String) -> WebExtensionMetadataInstallation? { fatalError("Unused fixture operation: extensionMetadataInstallation") }
    var extensionCompatibilityInstallations: [WebExtensionCompatibilityInstallation] { fatalError("Unused fixture value: extensionCompatibilityInstallations") }
    func extensionCompatibilityInstallation(_ id: String) -> WebExtensionCompatibilityInstallation? { fatalError("Unused fixture operation: extensionCompatibilityInstallation") }
    func extensionCompatibilityEvidence(_ evidence: WebExtensionCompatibilityEvidence, id: String, in space: UUID) { fatalError("Unused fixture operation: extensionCompatibilityEvidence") }
    func extensionCompatibilityProblem(_ problem: WebExtensionCompatibilityResult.Problem,
                                       of item: WebExtensionCompatibilityInstallation) { fatalError("Unused fixture operation: extensionCompatibilityProblem") }
    var extensionControllerMockCapture: Bool { false }
    func extensionInstallation(_ id: String) -> WebExtensionInstallation? { nil }
    func extensionSpaceExists(_ space: UUID) -> Bool { true }
    func extensionIsIncompatible(_ id: String) -> Bool { false }
    func extensionCleared(_ id: String, in space: UUID) async -> Bool { true }
    func markExtensionLoadIncompatible(_ id: String, version: String) { fatalError("Unused fixture operation: markExtensionLoadIncompatible") }
    func releaseExtensionLoadPower(_ key: String) { fatalError("Unused fixture operation: releaseExtensionLoadPower") }
    func closeExtensionLoadPopup(_ id: String, in space: UUID) { fatalError("Unused fixture operation: closeExtensionLoadPopup") }
    func closeExtensionLoadSidePanel(_ id: String, in space: UUID) { fatalError("Unused fixture operation: closeExtensionLoadSidePanel") }
    func noteExtensionLoadFailure(_ error: any Error) { fatalError("Unused fixture operation: noteExtensionLoadFailure") }
    var extensionWorkerSpaces: [UUID] { fatalError("Unused fixture value: extensionWorkerSpaces") }
    var extensionWorkerInstallations: [WebExtensionWorkerInstallation] { fatalError("Unused fixture value: extensionWorkerInstallations") }
    func extensionWorkerCheckStamp(_ version: String) -> String { fatalError("Unused fixture operation: extensionWorkerCheckStamp") }
    func resetExtensionWorkerCompatibility(_ id: String) { fatalError("Unused fixture operation: resetExtensionWorkerCompatibility") }
    func markExtensionWorkerIncompatible(_ id: String, version: String) { fatalError("Unused fixture operation: markExtensionWorkerIncompatible") }
    func updateExtensionWorker(_ id: String, in space: UUID, event: WebExtensionWorkerEvent) { fatalError("Unused fixture operation: updateExtensionWorker") }
    func releaseExtensionWorkerPower(_ key: String) { fatalError("Unused fixture operation: releaseExtensionWorkerPower") }
    func noteExtensionWorker(_ line: String) { fatalError("Unused fixture operation: noteExtensionWorker") }
    var extensionEvidenceAppVersion: String { fatalError("Unused fixture value: extensionEvidenceAppVersion") }
    var extensionEvidenceOSVersion: String { fatalError("Unused fixture value: extensionEvidenceOSVersion") }
    func extensionErrorsChanged(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery { fatalError("Unused fixture operation: extensionErrorsChanged") }
    func extensionEvidenceChanged(_ seen: WebExtensionEvidence, _ id: String, in space: UUID) { fatalError("Unused fixture operation: extensionEvidenceChanged") }
    func extensionCleanupIsInstalled(_ id: String) -> Bool { fatalError("Unused fixture operation: extensionCleanupIsInstalled") }
    func extensionCleanupIDs(in space: UUID) -> [String] { fatalError("Unused fixture operation: extensionCleanupIDs") }
    func removeExtensionCleanupMembership(in space: UUID) { fatalError("Unused fixture operation: removeExtensionCleanupMembership") }
    func clearExtensionCleanupVerdicts(in space: UUID) { fatalError("Unused fixture operation: clearExtensionCleanupVerdicts") }
    func closeExtensionCleanupPages(of id: String, in space: UUID) { fatalError("Unused fixture operation: closeExtensionCleanupPages") }
    func closeExtensionCleanupPopups(in space: UUID) { fatalError("Unused fixture operation: closeExtensionCleanupPopups") }
    func closeExtensionCleanupSidePanels(in space: UUID) { fatalError("Unused fixture operation: closeExtensionCleanupSidePanels") }
    func scheduleExtensionCleanupStoreSweep() { fatalError("Unused fixture operation: scheduleExtensionCleanupStoreSweep") }
    func noteExtensionCleanup(_ message: () -> String) { fatalError("Unused fixture operation: noteExtensionCleanup") }
    func extensionInstallRefusal(_ refusal: WebExtensionInstallRefusal) -> any Error { fatalError("Unused fixture operation: extensionInstallRefusal") }
    func noteExtensionInstallFacts(_ facts: WebExtensionManifestFacts?, of id: String) { fatalError("Unused fixture operation: noteExtensionInstallFacts") }
    var extensionStorageEnvironment: WebExtensionStorageEnvironment { .init(root: root, temporaryRoot: root) }
    func extensionRuntimeInstallation(_ id: String) -> WebExtensionEvidenceInstallation? { nil }
    func updateExtensionRuntimeAnswer(_ id: String, in space: UUID, event: WebExtensionRuntimeAnswerEvent) { log.append("runtime event") }
    func extensionNativeIsOptional(_ id: String) -> Bool { false }
    func extensionReachesApps(_ id: String) -> Bool { false }
    func setExtensionNativeConsent(_ id: String, _ on: Bool) { fatalError("Unused fixture operation: setExtensionNativeConsent") }
    func requestExtensionNative(title: String, in space: UUID, icon: () -> NSImage?) async -> Bool { fatalError("Unused fixture operation: requestExtensionNative") }
    func detectExtensionLanguage(_ text: String) -> [String: Any] { log.append("language"); return ["isReliable": true] }
    func sampleExtensionColour() async -> NSColor? { log.append("colour"); return nil }
    func noteExtensionRuntimeReport(_ api: String?, words: () -> String?) { log.append("report") }
    var extensionScriptRoot: URL { root }
    func extensionScriptInstallation(_ id: () -> String) -> WebExtensionScriptInstallation? { .init(id: id(), name: "Fixture", version: "1", isUnsigned: false) }
    func extensionAnswerTabs(in space: UUID) -> [ExtensionBrowserTab] { browser.workspace.space(space)?.tabs ?? [] }
    func extensionAnswerPage(_ tab: UUID) -> ExtensionAnswerPage? { nil }
    func extensionAnswerVisibleWindow(showing tab: UUID) -> ExtensionAnswerVisibility? { nil }
    func extensionAnswerSurfaces(_ kind: ExtensionAnswerSurfaceKind) -> [ExtensionAnswerSurface] { [] }
    func extensionAnswerIcon(for url: URL?) -> NSImage? { nil }
    func setExtensionPanelOptions(_ id: String, in space: UUID, tab: UUID?, path: String?, enabled: Bool?) { log.append("set panel") }
    func extensionPanelOptions(_ id: String, in space: UUID, tab: UUID?) -> [String: Any] { log.append("get panel"); return [:] }
    func setExtensionPanelOpensOnAction(_ id: String, in space: UUID, _ on: Bool) { log.append("set behavior") }
    func extensionPanelOpensOnAction(_ id: String, in space: UUID) -> Bool { log.append("get behavior"); return false }
    func presentExtensionPanel(_ presentation: ExtensionAnswerPanelPresentation, _ id: String, tab: UUID?, in space: UUID) throws { log.append("present panel") }
    func extensionPermissionTarget(in space: UUID, tab: UUID?, kind: ExtensionPermissionPromptKind) -> (any ExtensionPermissionTarget)? { log.append("permission target"); return nil }
    func extensionPermissionTitle(name: String?, kind: ExtensionPermissionPromptKind) -> String { fatalError("Unused fixture operation: extensionPermissionTitle") }
    func requestExtensionPermission(_ request: ExtensionPermissionRequest, target: any ExtensionPermissionTarget) async -> Bool { fatalError("Unused fixture operation: requestExtensionPermission") }
    func allowExtensionPermissionCookies(_ id: String) { fatalError("Unused fixture operation: allowExtensionPermissionCookies") }
    func setExtensionCaptureStop(_ stop: @escaping (String) -> Void) {  }
    func extensionCaptureAllowed(_ id: String) -> Bool { fatalError("Unused fixture operation: extensionCaptureAllowed") }
    func requestExtensionCapture(_ id: String, in space: UUID, used: () -> Bool, name: () -> String) async -> Bool { log.append("capture"); return false }
    func bringExtensionCaptureForward(_ view: NSView) { fatalError("Unused fixture operation: bringExtensionCaptureForward") }
    func lendExtensionCaptureView(_ view: NSView) { fatalError("Unused fixture operation: lendExtensionCaptureView") }
    func giveBackExtensionCaptureView(_ view: NSView) { fatalError("Unused fixture operation: giveBackExtensionCaptureView") }
    func extensionCaptureName(_ id: String) -> String { fatalError("Unused fixture operation: extensionCaptureName") }
    func updateExtensionCapture(_ lines: [ExtensionCaptureState]) { fatalError("Unused fixture operation: updateExtensionCapture") }
    func extensionDiagnosticVerdictLines(_ id: String, in space: UUID, number: Int) -> [String] { fatalError("Unused fixture operation: extensionDiagnosticVerdictLines") }
    func clearExtensionLoadVerdict(_ id: String, in space: UUID) { fatalError("Unused fixture operation: clearExtensionLoadVerdict") }
    func extensionActionsChanged() { log.append("action") }
    func presentExtensionActionPopup(in space: UUID, tab: UUID?, address: () -> URL?,
                                     page: (URL, UUID) -> ExtensionPanePage?) { log.append("popup"); popupAddress = address(); hasPageMaker = true }
    func runExtensionAuth(_ url: URL, extension id: String, in space: UUID,
                          openTab: () -> UUID?) async throws -> URL { log.append("auth"); return URL(string: "https://fixture.chromiumapp.org/done")! }
    func extensionFirstLookNativeFacts(_ facts: WebExtensionManifestFacts, of id: String) { fatalError("Unused fixture operation: extensionFirstLookNativeFacts") }
    func extensionFirstLookEvidence(_ seen: WebExtensionEvidence, id: String) -> WebExtensionEvidence { fatalError("Unused fixture operation: extensionFirstLookEvidence") }
    func noteExtensionError(_ api: String, words: () -> String?) { fatalError("Unused fixture operation: noteExtensionError") }
    func extensionKey(_ name: String) -> String? { fatalError("Unused fixture operation: extensionKey") }
    func suggestExtensionKey(_ key: String?, for name: String) { fatalError("Unused fixture operation: suggestExtensionKey") }
    func extensionHasEnabledItems(in space: UUID) -> Bool { true }
}
#endif
