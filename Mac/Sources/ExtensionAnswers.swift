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

        // MARK: its own pages, for clients.matchAll() and getContexts
        case "clients.pages":
            var pages = ownPages(of: id, in: space)
            if let url = ExtensionOffscreen.url(id, in: space) {
                pages.append(["id": "offscreen", "url": url.absoluteString, "visible": false, "focused": false])
            }
            return pages
        case "runtime.getContexts":
            // The extension's own pages that Chrome would list: its worker,
            // its pages in tabs, its offscreen document. Bitwarden asks for
            // these to know where to send its messages.
            let filter = first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String]
            let urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?, contextID: String) {
                guard types == nil || types!.contains(type) else { return }
                let address = url?.absoluteString ?? ""
                guard urls == nil || urls!.contains(address) else { return }
                found.append([
                    "contextType": type, "contextId": contextID, "tabId": -1, "windowId": -1,
                    "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                    "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host() ?? "")" } ?? "",
                    "incognito": false,
                ])
            }
            if context.webExtension.hasBackgroundContent {
                let background = context.webExtension.manifest["background"] as? [String: Any] ?? [:]
                let script = background["service_worker"] as? String ?? background["page"] as? String
                add("BACKGROUND", script.flatMap { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL }, contextID: "\(id)-background")
            }
            for page in ownPages(of: id, in: space) {
                add(page["kind"] as? String ?? "TAB", (page["url"] as? String).flatMap(URL.init(string:)), contextID: page["id"] as? String ?? "")
            }
            found += ExtensionOffscreen.contexts(id, in: space, matching: filter)
            return found

        case "offscreen.createDocument", "offscreen.closeDocument", "offscreen.hasDocument",
             "i18n.detectLanguage", "eyeDropper.open", "permissions.native":
            return try await runtimeAnswers.answer(api, args, id: id, context: context, in: space)

        // MARK: the side panel (ExtensionSidePanel.swift)
        case "sidePanel.setOptions":
            let options = first as? [String: Any] ?? [:]
            let tab = options["tabId"] == nil ? nil : self.tab(at: options["__place"], in: space)
            // A tab it named that can't be found: nothing set, rather than every tab.
            if options["tabId"] != nil, tab == nil { return nil }
            ExtensionSidePanels.shared.setOptions(id, in: space, tab: tab, path: options["path"] as? String, enabled: options["enabled"] as? Bool)
            return nil
        case "sidePanel.getOptions":
            let options = first as? [String: Any] ?? [:]
            return ExtensionSidePanels.shared.options(id, in: space, tab: self.tab(at: options["__place"], in: space))
        case "sidePanel.setPanelBehavior":
            let behavior = first as? [String: Any] ?? [:]
            if let on = behavior["openPanelOnActionClick"] as? Bool { ExtensionSidePanels.shared.setOpensOnAction(id, in: space, on) }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": ExtensionSidePanels.shared.opensOnAction(id, in: space)]
        case "sidePanel.open", "sidePanel.close":
            let options = first as? [String: Any] ?? [:]
            let panels = ExtensionSidePanels.shared
            let tab = self.tab(at: options["__place"], in: space)
            // A tab it named that can't be found: an error, not the tab in front.
            if options["tabId"] != nil, tab == nil { throw Unanswered(why: "No tab with id: \(options["tabId"] ?? "").") }
            let windows = Session.shared.allWindows.filter { $0.spaceID == space }
            // A tab not on screen: its panel opens when it is.
            if let tab, !windows.contains(where: { $0.tabID == tab }) {
                if api == "sidePanel.open" { panels.open(id, whenShowing: tab, in: space) } else { panels.cancel(id, tab: tab, in: space) }
                return nil
            }
            guard let window = windows.first(where: { tab != nil && $0.tabID == tab }) ?? windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first
            else { throw Unanswered(why: "No window to open the side panel in.") }
            if api == "sidePanel.open" { ExtensionSidePanels.shared.open(id, in: window) } else if ExtensionSidePanels.shared.panel(in: window)?.surface.extensionID == id {
                ExtensionSidePanels.shared.close(in: window)
            }
            return nil

        // MARK: the popup its button opens, as it set it
        case "action.popup":
            popupPaths["\(space.uuidString)/\(id)"] = first as? String ?? ""
            return nil

        // MARK: management, itself only
        case "management.getSelf", "management.get":
            return try Self.scriptAnswers.management(api, first: first, id: id, context: context)

        // MARK: a function to inject, from a page in a website's frame (Search's)
        case "scripting.file":
            return try Self.scriptAnswers.scripting(first, arguments: args, id: id, context: context)

        // MARK: which of eGlu's panes shows a page
        case "surface.kind":
            let url = first as? String
            let shows = { (surface: any WebExtensionSurface) in
                surface.extensionID == id && surface.space == space && surface.url?.absoluteString == url
            }
            if ExtensionPopups.shared.shown.values.contains(where: { shows($0.surface) }) { return "popup" }
            if ExtensionSidePanels.shared.shown.values.contains(where: { shows($0.surface) }) { return "sidePanel" }
            return "tab"

        // MARK: idle and power, the Mac's own (Search's)
        case "idle.queryState", "idle.getAutoLockDelay", "power.requestKeepAwake", "power.releaseKeepAwake", "power.reportActivity":
            return try await runtimeAnswers.answer(api, args, id: id, context: context, in: space)

        // MARK: tabs, by their place in the space (Search's)
        case "tabs.describe" where context.hasPermission(.tabs):
            let rows = Session.shared.workspace.space(space)?.tabs ?? []
            return ((first as? [Any]) ?? []).map { place -> Any in
                guard let index = (place as? NSNumber)?.intValue, rows.indices.contains(index) else { return NSNull() }
                let record = rows[index]
                let page = Session.shared.pages.live[record.id]
                let url = ExtensionTab.address(of: page.map { ExtensionHost.shared.snapshot($0) }, for: context, owner: { ExtensionAuth.owner(of: $0) }, else: page?.view.url ?? record.url)
                // Another extension's page stays blank, as WebKit keeps it (ExtensionTab.sealed).
                if Self.othersPage(url, for: context) || Self.othersPage(record.url, for: context) { return ["url": "", "title": ""] }
                var described: [String: Any] = ["url": url?.absoluteString ?? "", "title": page?.view.title ?? record.title]
                if let icon = Self.favIconURL(for: url) { described["favIconUrl"] = icon }
                return described
            }

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

    /// A tab's icon for favIconUrl: the picture the tab wears, as a small
    /// PNG, since eGlu keeps icons as pictures, not addresses (Chrome's may
    /// be a data: address too). Made once for each site's picture, and made
    /// again when the site's picture is another.
    private static var favIcons: [String: (icon: NSImage, made: String)] = [:]

    static func favIconURL(for url: URL?) -> String? {
        guard let host = url?.host(), let icon = SiteIcons.shared.image(for: url) else { return nil }
        if let known = favIcons[host], known.icon === icon { return known.made }
        let side = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let made = "data:image/png;base64," + png.base64EncodedString()
        if favIcons.count > 500 { favIcons.removeAll() }
        favIcons[host] = (icon, made)
        return made
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

    /// The tab at a place the shim found for a tab number (its index in the
    /// space's window, and its address, which must still be there).
    func tab(at place: Any?, in space: UUID) -> UUID? {
        guard let place = place as? [String: Any], let index = place["index"] as? Int,
              let tabs = Session.shared.workspace.space(space)?.tabs, tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        if let address = place["url"] as? String, !address.isEmpty {
            let now = Session.shared.pages.live[tab.id]?.view.url ?? tab.url
            guard now?.absoluteString == address else { return nil }
        }
        return tab.id
    }

    /// The extension's own pages open in the space's tabs, as clients.matchAll lists them.
    private func ownPages(of id: String, in space: UUID) -> [[String: Any]] {
        let session = Session.shared
        var pages: [[String: Any]] = []
        for tab in session.workspace.space(space)?.tabs ?? [] {
            guard let view = session.pages.live[tab.id]?.view, let url = view.url,
                  url.scheme == Self.scheme, url.host() == id else { continue }
            let window = session.allWindows.first { $0.tabID == tab.id && $0.window?.occlusionState.contains(.visible) == true }
            pages.append(["id": tab.id.uuidString, "url": url.absoluteString,
                          "visible": window != nil, "focused": window?.window?.isKeyWindow == true])
        }
        // Its popup and side panel while they are up: 1Password's worker
        // sends its popup the app's news only when it finds it open. (Search's)
        let surfaces = ExtensionPopups.shared.shown.values.map { ($0.surface, $0.window, "POPUP") }
            + ExtensionSidePanels.shared.shown.values.map { ($0.surface, $0.window, "SIDE_PANEL") }
        for (surface, window, kind) in surfaces where surface.extensionID == id && surface.space == space {
            guard let url = surface.url else { continue }
            pages.append(["id": "\(kind.lowercased())-\(window.map { ObjectIdentifier($0).hashValue } ?? 0)", "url": url.absoluteString,
                          "visible": true, "focused": window?.window?.isKeyWindow == true, "kind": kind])
        }
        // A worker finds the popup windows it opened (windows.create) through
        // these, as Chrome lists their pages, among its tabs: without them it
        // can't send its own window a word.
        for popup in ExtensionPopupWindow.all(in: space) {
            guard let url = popup.page?.state.url, url.scheme == Self.scheme, url.host() == id else { continue }
            pages.append(["id": "window-\(ObjectIdentifier(popup).hashValue)", "url": url.absoluteString,
                          "visible": popup.snapshot?.isVisible == true, "focused": popup.snapshot?.isKey == true])
        }
        return pages
    }

    /// A desktop app a host stands for, in the words a person knows it by.
    static func appName(ofHost host: String) -> String {
        WebKitExtensionRuntimeAnswers.appName(ofHost: host)
    }
}
