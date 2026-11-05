import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import WebKitExtensions

/// What the shim asks of the app (Scripts/extension-shim.js), through
/// native messaging to "eglu": what it tells of, and the APIs WebKit
/// lacks that the app answers. Each answer is for the extension that asked,
/// in the space it asked from. One that touches a site's data checks
/// ExtensionPolicy.mayTouchData first; none here does yet.
extension Extensions {
    struct Unanswered: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    private static let scriptAnswers = WebKitExtensionScriptAnswers(host: ExtensionHost.shared,
        prepared: { Extensions.prepared($0, $1) }, unanswered: { Unanswered(why: $0) })

    static func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        try scriptAnswers.scriptingFile(function, arguments: arguments, in: folder)
    }

    /// The answer, as JSON can carry it; nil for none.
    func answer(_ api: String, _ args: [Any], context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        let id = context.uniqueIdentifier
        let first = args.first
        switch api {
        case "report", "background.wake", "background.revive":
            return try await runtimeAnswers.answer(api, args, id: id, context: context, in: space)

        case "clients.pages", "runtime.getContexts":
            return try Self.browserAnswers.answer(api, args, id: id, context: context, in: space)

        case "offscreen.createDocument", "offscreen.closeDocument", "offscreen.hasDocument",
             "i18n.detectLanguage", "eyeDropper.open", "permissions.native":
            return try await runtimeAnswers.answer(api, args, id: id, context: context, in: space)

        case "sidePanel.setOptions", "sidePanel.getOptions", "sidePanel.setPanelBehavior", "sidePanel.getPanelBehavior",
             "sidePanel.open", "sidePanel.close", "action.popup":
            return try Self.browserAnswers.answer(api, args, id: id, context: context, in: space)

        // MARK: management, itself only
        case "management.getSelf", "management.get":
            return try Self.scriptAnswers.management(api, first: first, id: id, context: context)

        // MARK: a function to inject, from a page in a website's frame (Search's)
        case "scripting.file":
            return try Self.scriptAnswers.scripting(first, arguments: args, id: id, context: context)

        case "surface.kind":
            return try Self.browserAnswers.answer(api, args, id: id, context: context, in: space)

        // MARK: idle and power, the Mac's own (Search's)
        case "idle.queryState", "idle.getAutoLockDelay", "power.requestKeepAwake", "power.releaseKeepAwake", "power.reportActivity":
            return try await runtimeAnswers.answer(api, args, id: id, context: context, in: space)

        case "tabs.describe":
            return try Self.browserAnswers.answer(api, args, id: id, context: context, in: space)

        // MARK: a permissions.request a click made (Search's)
        case "permissions.afterClick":
            return try await requestAfterClick(first as? [String] ?? [], origins: args.dropFirst().first as? [String] ?? [],
                                               context: context, in: space)

        // MARK: user scripts, through WebKit's registered content scripts (Search's)
        case "userScripts.file" where Self.asks(context, for: "userScripts"):
            return try Self.scriptAnswers.userScriptFile(first, of: id)
        case "userScripts.list" where Self.asks(context, for: "userScripts"):
            return Self.scriptAnswers.userScripts(of: id, in: space)
        case "userScripts.change" where Self.asks(context, for: "userScripts"):
            return try Self.scriptAnswers.changeUserScripts(first, of: id, in: space)
        case "userScripts.world" where Self.asks(context, for: "userScripts"), "userScripts.worlds" where Self.asks(context, for: "userScripts"):
            if api == "userScripts.worlds" { return Self.scriptAnswers.userScriptWorlds(of: id, in: space) }
            try Self.scriptAnswers.setUserScriptWorld(first, of: id, in: space)
            return nil

        // MARK: a stream id for the worker, which has no page to record in (Search's)
        case "capture.grant" where Self.asks(context, for: "desktopCapture"):
            return await ExtensionCapture.shared.runtime.grant(for: context, in: space, sources: first as? [String] ?? [])

        // MARK: an extension's sign-in (Search's)
        case "identity.launchWebAuthFlow" where Self.asks(context, for: "identity"):
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unanswered(why: "No authorization url.") }
            // As in Chrome, a flow is out of sight unless it says it is interactive.
            if spec["interactive"] as? Bool != true {
                let wait = (spec["timeoutMsForNonInteractive"] as? NSNumber).map { $0.doubleValue / 1000 }
                return try await WebKitExtensionAuth.quietly(url, extension: id, in: space,
                                                       abortOnLoad: spec["abortOnLoadForNonInteractive"] as? Bool ?? true,
                                                       timeout: wait,
                                                       configuration: { Session.shared.engine.configuration(space: space) },
                                                       unanswered: { Unanswered(why: $0) }).absoluteString
            }
            return try await ExtensionAuth.run(url, extension: id, in: space, openTab: {
                Extensions.shared.tabs.open(url, in: space, active: true, pinned: false, context: context)
            }).absoluteString

        default:
            throw Unanswered(why: "eGlu doesn't answer \(api).")
        }
    }

    static func kept(_ name: String, of id: String, in space: UUID) -> URL {
        scriptAnswers.kept(name, of: id, in: space)
    }

    static func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool = true) throws -> String {
        try scriptAnswers.userScriptFile(script, in: folder, writing: writing)
    }

    static func pruneUserScripts(of id: String, in folder: URL) {
        scriptAnswers.pruneUserScripts(of: id, in: folder)
    }

    static let browserAnswers = WebKitExtensionBrowserAnswers(host: ExtensionHost.shared,
        unanswered: { Unanswered(why: $0) }, scheme: Extensions.scheme)

    static func favIconURL(for url: URL?) -> String? {
        browserAnswers.favIconURL(for: url)
    }

    /// Kept for the action button and capture's existing press allowance.
    static var pressed: [String: Date] {
        get { WebKitExtensionPermissions.pressed }
        set { WebKitExtensionPermissions.pressed = newValue }
    }

    private func requestAfterClick(_ names: [String], origins: [String], context: WKWebExtensionContext, in space: UUID) async throws -> Bool {
        try await permissionPrompts.requestAfterClick(names, origins: origins, context: context, in: space)
    }

    /// Whether the extension has `permission`: its manifest asks for it
    /// outright, as the permission it was added with, or as an optional one
    /// the person has since granted (permissions.request, afterClick). The
    /// native answers are held to that: an extension can't keep the Mac
    /// awake without having asked as it was added or since. The shim may
    /// show the namespace before, whose calls are then refused.
    static func asks(_ context: WKWebExtensionContext, for permission: String) -> Bool {
        WebKitExtensionRuntimeAnswers.asks(context, for: permission)
    }

    func tab(at place: Any?, in space: UUID) -> UUID? {
        Self.browserAnswers.tab(at: place, in: space)
    }

    /// A desktop app a host stands for, in the words a person knows it by.
    static func appName(ofHost host: String) -> String {
        WebKitExtensionRuntimeAnswers.appName(ofHost: host)
    }
}
