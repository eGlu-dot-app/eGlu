#if os(macOS)
import AppKit
import WebEngineAppKit
import XCTest

/// This app-facing fake has no engine import or engine objects.
@MainActor
private final class DispatchFakeRuntime: WebExtensionRuntime {
    var recordsFile: URL { fatalError("Unused storage") }
    func package(_ id: String, _ version: String) -> URL { fatalError("Unused storage") }
    func prepared(_ id: String, _ version: String) -> URL { fatalError("Unused storage") }
    nonisolated func prepare(_ package: URL, into folder: URL) throws { fatalError("Unused storage") }
    var opened: [(String, UUID)] = []
    func icon(of id: String) -> NSImage? { fatalError("Unused fake operation: icon") }
    func icon(of id: String, in space: UUID) -> NSImage? { fatalError("Unused fake operation: icon") }
    func forgetIcon(_ id: String) { fatalError("Unused fake operation: forgetIcon") }
    func manifestFacts(permissions: [String], optionalPermissions: [String]) -> WebExtensionManifestFacts { fatalError("Unused fake operation: manifestFacts") }
    func optionsPageURL(_ id: String, in space: UUID) -> URL? { fatalError("Unused fake operation: optionsPageURL") }
    func newTabPageURL(_ id: String, in space: UUID) -> URL? { fatalError("Unused fake operation: newTabPageURL") }
    func hasNewTabPage(_ id: String) -> Bool { fatalError("Unused fake operation: hasNewTabPage") }
    func isNewTabPage(_ url: URL, in space: UUID) -> Bool { fatalError("Unused fake operation: isNewTabPage") }
    func sidePanelDefaultPath(_ id: String, in space: UUID) -> String? { fatalError("Unused fake operation: sidePanelDefaultPath") }
    nonisolated func packageName(at file: URL, fallback: String) -> WebExtensionPackageName { fatalError("Unused fake operation: packageName") }
    func readCode(of item: WebExtensionCompatibilityInstallation) { fatalError("Unused fake operation: readCode") }
    func measureTable() async { fatalError("Unused fake operation: measureTable") }
    func checkCopy(of item: WebExtensionCompatibilityInstallation) { fatalError("Unused fake operation: checkCopy") }
    func checkStamp(_ version: String) -> String { fatalError("Unused fake operation: checkStamp") }
    func currentFailures(_ held: [String: String], installed: [String: String]) -> [String: String] { fatalError("Unused fake operation: currentFailures") }
    func forgetCheck(_ id: String) { fatalError("Unused fake operation: forgetCheck") }
    func isLoaded(_ id: String, in space: UUID) -> Bool { true }
    func extensionID(for url: URL?) -> String? { fatalError("Unused fake operation: extensionID") }
    @discardableResult func load(_ item: WebExtensionInstallation, in space: UUID) async -> Bool { fatalError("Unused fake operation: load") }
    func unload(_ id: String, in space: UUID) { fatalError("Unused fake operation: unload") }
    func setSiteAccess(_ id: String, _ access: WebExtensionInstallation.SiteAccess) { fatalError("Unused fake operation: setSiteAccess") }
    func setReadsCookies(_ id: String, _ on: Bool, changed: (UUID) -> Void) { fatalError("Unused fake operation: setReadsCookies") }
    func forgetWorkersIfChanged() async { fatalError("Unused fake operation: forgetWorkersIfChanged") }
    func workersChanged() { fatalError("Unused fake operation: workersChanged") }
    @discardableResult func revive(_ id: String, in space: UUID, because reason: String) -> Bool { fatalError("Unused fake operation: revive") }
    @discardableResult func restart(_ id: String, in space: UUID, because reason: String) -> Bool { fatalError("Unused fake operation: restart") }
    var evidence: [UUID: [String: WebExtensionEvidence]] = [:]
    var lacking: [String: Set<String>] = [:]
    var recorded: [String: Set<String>] = [:]
    func recordOnce(_ key: String, _ text: String) -> Bool { fatalError("Unused fake operation: recordOnce") }
    func readRecords() { fatalError("Unused fake operation: readRecords") }
    func pruneRecords() { fatalError("Unused fake operation: pruneRecords") }
    func saveRecords() { fatalError("Unused fake operation: saveRecords") }
    func note(_ problem: WebExtensionEvidence.Problem, file: String?, of item: WebExtensionEvidenceInstallation) { fatalError("Unused fake operation: note") }
    func records(of id: String) -> [WebExtensionErrorRecord] { fatalError("Unused fake operation: records") }
    func update(_ id: String, in space: UUID, _ change: (inout WebExtensionEvidence) -> Void) { fatalError("Unused fake operation: update") }
    func record(_ seen: WebExtensionEvidence, _ id: String, in space: UUID) { fatalError("Unused fake operation: record") }
    func remove(_ id: String, from space: UUID) { fatalError("Unused fake operation: remove") }
    func removePackages(_ id: String, afterClearing spaces: [UUID]) { fatalError("Unused fake operation: removePackages") }
    @discardableResult func forget(_ id: String, in space: UUID) -> Task<Void, Never> { fatalError("Unused fake operation: forget") }
    func forgetLeftOver() { fatalError("Unused fake operation: forgetLeftOver") }
    @discardableResult func cleared(_ id: String, in space: UUID) async -> Bool { fatalError("Unused fake operation: cleared") }
    func removeSpace(_ space: UUID) { fatalError("Unused fake operation: removeSpace") }
    func closePages(of id: String, in space: UUID) { fatalError("Unused fake operation: closePages") }
    func download(_ id: String, from address: URL?) async throws -> Data { fatalError("Unused fake operation: download") }
    func readArchive(_ archive: Data) throws -> any WebExtensionInstallArchive { fatalError("Unused fake operation: readArchive") }
    func describeOffer(_ archive: Data, id: String) throws -> (any WebExtensionInstallArchive, String) { fatalError("Unused fake operation: describeOffer") }
    func verifyUpdate(_ crx: Data, id: String, size: Int?, sha256: String?, version: String) throws -> (Data, any WebExtensionInstallArchive, String) { fatalError("Unused fake operation: verifyUpdate") }
    func keepArchive(_ archive: Data, id: String, name: String, version: String) throws -> String { fatalError("Unused fake operation: keepArchive") }
    func unload(_ item: WebExtensionInstallation) { fatalError("Unused fake operation: unload") }
    func loadReplacement(_ item: WebExtensionInstallation,
                         completion: (Bool) -> WebExtensionInstallCompletion) async -> Bool { fatalError("Unused fake operation: loadReplacement") }
    func loadNew(_ item: WebExtensionInstallation, didLoad: () -> Void) async -> Bool { fatalError("Unused fake operation: loadNew") }
    func removeOtherVersions(of id: String, keeping version: String) { fatalError("Unused fake operation: removeOtherVersions") }
    func trial(_ archive: Data, id: String) async throws { fatalError("Unused fake operation: trial") }
    func snapshot(_ folder: URL) async throws -> WebExtensionFolderSnapshot { fatalError("Unused fake operation: snapshot") }
    func zipped(_ folder: URL) async throws -> Data { fatalError("Unused fake operation: zipped") }
    func sha256(_ data: Data) -> String { fatalError("Unused fake operation: sha256") }
    func releaseKeepAwake(_ key: String) { fatalError("Unused fake operation: releaseKeepAwake") }
    func kept(_ name: String, of id: String, in space: UUID) -> URL { fatalError("Unused fake operation: kept") }
    func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String { fatalError("Unused fake operation: scriptingFile") }
    func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool) throws -> String { fatalError("Unused fake operation: userScriptFile") }
    func userScripts(of id: String, in space: UUID) -> Any { fatalError("Unused fake operation: userScripts") }
    func changeUserScripts(_ first: Any?, of id: String, in space: UUID) throws -> [[String: Any]] { fatalError("Unused fake operation: changeUserScripts") }
    func userScriptWorlds(of id: String, in space: UUID) -> [[String: Any]] { fatalError("Unused fake operation: userScriptWorlds") }
    func setUserScriptWorld(_ first: Any?, of id: String, in space: UUID) throws { fatalError("Unused fake operation: setUserScriptWorld") }
    func pruneUserScripts(of id: String, in folder: URL) { fatalError("Unused fake operation: pruneUserScripts") }
    var popupPaths: [String: String] = [:]
    func tab(at place: Any?, in space: UUID) -> UUID? { fatalError("Unused fake operation: tab") }
    func favIconURL(for url: URL?) -> String? { fatalError("Unused fake operation: favIconURL") }
    var permissionPresses: [String: Date] = [:]
    func addressChanged(_ page: any WebMacPage, tab: UUID, in space: UUID) { fatalError("Unused fake operation: addressChanged") }
    func loadingChanged(tab: UUID, in space: UUID) { fatalError("Unused fake operation: loadingChanged") }
    func popupShows(_ page: any WebMacPage) -> Bool { fatalError("Unused fake operation: popupShows") }
    func diagnosticTableLines() -> [String] { fatalError("Unused fake operation: diagnosticTableLines") }
    func diagnosticLines(id: String, name: String, version: String, in space: UUID,
                         number: Int, otherExtension: () -> String) -> [String] { fatalError("Unused fake operation: diagnosticLines") }
    func diagnosticPageLine(_ page: (any WebMacPage)?, number: Int) -> String { fatalError("Unused fake operation: diagnosticPageLine") }
    static func words(_ text: String?, enabled: Bool) -> String { fatalError("Unused fake operation: words") }
    static func note(_ line: String, outputPath: String?) { fatalError("Unused fake operation: note") }
    func keepsCookiesBack(_ id: String, allowing on: Bool) -> Bool { fatalError("Unused fake operation: keepsCookiesBack") }
    func startTabs() { fatalError("Unused fake operation: startTabs") }
    func isLoaded(_ id: String) -> Bool { fatalError("Unused fake operation: isLoaded") }
    func asks(_ id: String, in space: UUID, for permission: String) -> Bool { permission == "identity" }
    func openTab(_ url: URL, extension id: String, in space: UUID) -> UUID? { opened.append((id, space)); return nil }
    func openOptions(_ id: String, in space: UUID) { fatalError("Unused fake operation: openOptions") }
    func permissionIcon(_ id: String, in space: UUID) -> NSImage? { fatalError("Unused fake operation: permissionIcon") }
    func commands(of id: String) -> [WebExtensionCommand]? { fatalError("Unused fake operation: commands") }
    func commands(of id: String, in space: UUID) -> [WebExtensionCommand]? { fatalError("Unused fake operation: commands") }
    func perform(_ command: WebExtensionCommand.Identity, of id: String, in space: UUID) { fatalError("Unused fake operation: perform") }
    func applyKeys(of id: String) { fatalError("Unused fake operation: applyKeys") }
    func action(for id: String, tab: UUID?, in space: UUID, iconSize: CGSize?) -> WebExtensionAction? { fatalError("Unused fake operation: action") }
    func run(_ id: String, tab: () -> UUID?, in space: UUID, popup: () -> Bool,
             panel: () -> Bool, pageURL: () -> URL?, togglePanel: () -> Void) { fatalError("Unused fake operation: run") }
    func sidePanelSource(_ id: String, in space: UUID) -> ExtensionPaneSource? { fatalError("Unused fake operation: sidePanelSource") }
    func webAccessible(_ url: URL, from source: URL, in space: UUID, fromRule: Bool) -> Bool { fatalError("Unused fake operation: webAccessible") }
    func externalListings(in space: UUID) -> [String: [String]] { fatalError("Unused fake operation: externalListings") }
    func forgetCapture(_ id: String) { fatalError("Unused fake operation: forgetCapture") }
    func releaseCapture(_ view: NSView) { fatalError("Unused fake operation: releaseCapture") }
    func displayCaptureDecision(for view: NSView) -> Int { fatalError("Unused fake operation: displayCaptureDecision") }
    func watchCapture(_ view: NSView, id: String) { fatalError("Unused fake operation: watchCapture") }
    func forgetRecords(_ id: String) { fatalError("Unused fake operation: forgetRecords") }
    func errorRecovery(_ id: String, in space: UUID, failed: Bool) -> WebExtensionErrorRecovery { fatalError("Unused fake operation: errorRecovery") }
}

final class ExtensionComposedRuntimeInterfaceTests: XCTestCase {
    @MainActor func testTheAppCanUseTheComposedInterfaceWithoutWebKit() {
        let fake = DispatchFakeRuntime()
        let runtime: any WebExtensionRuntime = fake
        let space = UUID()
        XCTAssertTrue(runtime.isLoaded("fixture", in: space))
        XCTAssertTrue(runtime.asks("fixture", in: space, for: "identity"))
        _ = runtime.openTab(URL(string: "https://example.invalid")!, extension: "fixture", in: space)
        XCTAssertEqual(fake.opened.first?.0, "fixture")
        XCTAssertEqual(fake.opened.first?.1, space)
        runtime.permissionPresses["fixture"] = .distantPast
        XCTAssertEqual(fake.permissionPresses["fixture"], .distantPast)
    }
}
#endif
