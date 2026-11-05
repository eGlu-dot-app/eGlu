#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit

/// The shim dispatch belongs to this engine; product answers use the host.
@MainActor
final class WebKitExtensionDispatcher {
    let host: any ExtensionDispatchHost
    let tabs: ExtensionTabs
    let runtimeAnswers: () -> WebKitExtensionRuntimeAnswers
    let browserAnswers: () -> WebKitExtensionBrowserAnswers
    let scriptAnswers: () -> WebKitExtensionScriptAnswers
    let permissions: () -> WebKitExtensionPermissions
    let capture: () -> ExtensionCaptureRuntime
    let configuration: (UUID) -> WKWebViewConfiguration
    let unanswered: (String) -> any Error

    init(host: any ExtensionDispatchHost, tabs: ExtensionTabs,
         runtime: @escaping () -> WebKitExtensionRuntimeAnswers,
         browser: @escaping () -> WebKitExtensionBrowserAnswers,
         scripts: @escaping () -> WebKitExtensionScriptAnswers,
         permissions: @escaping () -> WebKitExtensionPermissions,
         capture: @escaping () -> ExtensionCaptureRuntime,
         configuration: @escaping (UUID) -> WKWebViewConfiguration,
         unanswered: @escaping (String) -> any Error) {
        self.host = host; self.tabs = tabs; self.runtimeAnswers = runtime; self.browserAnswers = browser
        self.scriptAnswers = scripts; self.permissions = permissions; self.capture = capture
        self.configuration = configuration; self.unanswered = unanswered
    }

    /// The answer, as JSON can carry it; nil for none.
    func answer(_ api: String, _ args: [Any], context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        let id = context.uniqueIdentifier
        let first = args.first
        switch api {
        case "report", "background.wake", "background.revive":
            return try await runtimeAnswers().answer(api, args, id: id, context: context, in: space)

        case "clients.pages", "runtime.getContexts":
            return try browserAnswers().answer(api, args, id: id, context: context, in: space)

        case "offscreen.createDocument", "offscreen.closeDocument", "offscreen.hasDocument",
             "i18n.detectLanguage", "eyeDropper.open", "permissions.native":
            return try await runtimeAnswers().answer(api, args, id: id, context: context, in: space)

        case "sidePanel.setOptions", "sidePanel.getOptions", "sidePanel.setPanelBehavior", "sidePanel.getPanelBehavior",
             "sidePanel.open", "sidePanel.close", "action.popup":
            return try browserAnswers().answer(api, args, id: id, context: context, in: space)

        // MARK: management, itself only
        case "management.getSelf", "management.get":
            return try scriptAnswers().management(api, first: first, id: id, context: context)

        // MARK: a function to inject, from a page in a website's frame (Search's)
        case "scripting.file":
            return try scriptAnswers().scripting(first, arguments: args, id: id, context: context)

        case "surface.kind":
            return try browserAnswers().answer(api, args, id: id, context: context, in: space)

        // MARK: idle and power, the Mac's own (Search's)
        case "idle.queryState", "idle.getAutoLockDelay", "power.requestKeepAwake", "power.releaseKeepAwake", "power.reportActivity":
            return try await runtimeAnswers().answer(api, args, id: id, context: context, in: space)

        case "tabs.describe":
            return try browserAnswers().answer(api, args, id: id, context: context, in: space)

        // MARK: a permissions.request a click made (Search's)
        case "permissions.afterClick":
            return try await permissions().requestAfterClick(first as? [String] ?? [], origins: args.dropFirst().first as? [String] ?? [],
                                               context: context, in: space)

        // MARK: user scripts, through WebKit's registered content scripts (Search's)
        case "userScripts.file" where WebKitExtensionRuntimeAnswers.asks(context, for: "userScripts"):
            return try scriptAnswers().userScriptFile(first, of: id)
        case "userScripts.list" where WebKitExtensionRuntimeAnswers.asks(context, for: "userScripts"):
            return scriptAnswers().userScripts(of: id, in: space)
        case "userScripts.change" where WebKitExtensionRuntimeAnswers.asks(context, for: "userScripts"):
            return try scriptAnswers().changeUserScripts(first, of: id, in: space)
        case "userScripts.world" where WebKitExtensionRuntimeAnswers.asks(context, for: "userScripts"), "userScripts.worlds" where WebKitExtensionRuntimeAnswers.asks(context, for: "userScripts"):
            if api == "userScripts.worlds" { return scriptAnswers().userScriptWorlds(of: id, in: space) }
            try scriptAnswers().setUserScriptWorld(first, of: id, in: space)
            return nil

        // MARK: a stream id for the worker, which has no page to record in (Search's)
        case "capture.grant" where WebKitExtensionRuntimeAnswers.asks(context, for: "desktopCapture"):
            return await capture().grant(for: context, in: space, sources: first as? [String] ?? [])

        // MARK: an extension's sign-in (Search's)
        case "identity.launchWebAuthFlow" where WebKitExtensionRuntimeAnswers.asks(context, for: "identity"):
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw unanswered("No authorization url.") }
            // As in Chrome, a flow is out of sight unless it says it is interactive.
            if spec["interactive"] as? Bool != true {
                let wait = (spec["timeoutMsForNonInteractive"] as? NSNumber).map { $0.doubleValue / 1000 }
                return try await WebKitExtensionAuth.quietly(url, extension: id, in: space,
                                                       abortOnLoad: spec["abortOnLoadForNonInteractive"] as? Bool ?? true,
                                                       timeout: wait,
                                                       configuration: { self.configuration(space) },
                                                       unanswered: unanswered).absoluteString
            }
            return try await host.runExtensionAuth(url, extension: id, in: space, openTab: {
                self.tabs.open(url, in: space, active: true, pinned: false, context: context)?.id
            }).absoluteString

        default:
            throw unanswered("eGlu doesn't answer \(api).")
        }
    }

}
#endif
