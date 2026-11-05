import AppKit
import CryptoKit
import IOKit.pwr_mgt
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

    /// A function an extension's page in a website's frame asked its worker
    /// to inject, which can't cross the message as a function: written as a
    /// file of the extension's own, called with its JSON arguments, for
    /// WebKit's scripting to take by path. A megabyte of source at most, and
    /// one more than a minute old is let go, so a page gone wrong can't fill
    /// the extension's folder. (Search's ba34243)
    static func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        guard !function.isEmpty, JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments), let given = String(data: data, encoding: .utf8)
        else { throw Unanswered(why: "Invalid script function or arguments") }
        let source = "(\(ExtensionPreparation.expression(of: function)))(...\(given))\n"
        // A megabyte in all, the arguments counted too.
        guard source.utf8.count <= 1_000_000 else { throw Unanswered(why: "Invalid script function or arguments") }
        let name = "script-" + SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let folder = folder.appendingPathComponent("_eglu", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) { try source.write(to: file, atomically: true, encoding: .utf8) }
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("script-") && old != file {
            let age = (try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if age > 60 { try? FileManager.default.removeItem(at: old) }
        }
        return "_eglu/" + name
    }

    /// The answer, as JSON can carry it; nil for none.
    func answer(_ api: String, _ args: [Any], context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        let id = context.uniqueIdentifier
        let first = args.first
        switch api {
        case "report":
            // An error nobody caught: [kind, its words, file, line]. Only
            // the API it names is kept, as for WebKit's own errors.
            let problem = args.count > 1 ? (args[1] as? String).flatMap { ExtensionError.problem(in: $0, missing: lacking[id] ?? []) } : nil
            #if DEBUG
            Self.note("shim report: \(problem?.api ?? "no API named")" + Self.words(args.count > 1 ? args[1] as? String : nil))
            #endif
            if let problem {
                update(id, in: space) { $0.problems.insert(problem) }
                // Into the records once, as WebKit's own errors go (errorsChanged).
                if let item = installed.first(where: { $0.id == id }),
                   recordOnce("\(space.uuidString)/\(id)", (args[1] as? String) ?? "") {
                    note(problem, file: args.count > 2 ? args[2] as? String : nil, of: item)
                }
            }
            return nil

        // MARK: the worker, up before a page talks to it (Search's)
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            // WebKit sometimes fails to start a worker again after unloading
            // it, and then never tries again: every message waits for ever.
            // Tried twice more, then the extension is taken up afresh.
            for attempt in 0..<3 {
                // WebKit never calls back after some failed starts; eight
                // seconds without an answer counts as a failure.
                let error: Error? = await withCheckedContinuation { done in
                    var finished = false
                    let finish: (Error?) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(returning: result)
                    }
                    context.loadBackgroundContent { error in MainActor.assumeIsolated { finish(error) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(Unanswered(why: "no answer from WebKit")) }
                }
                guard error != nil else { return nil }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
            revive(id, in: space, because: "its worker wouldn't start")
            return nil
        case "background.revive":
            // A page found the worker gone though WebKit believes it runs.
            return revive(id, in: space, because: "its worker stopped answering")

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

        // MARK: offscreen, a page with a DOM for a worker that has none
        case "offscreen.createDocument":
            guard let path = (first as? [String: Any])?["url"] as? String
            else { throw Unanswered(why: "No page for the offscreen document") }
            let reasons = Set(((first as? [String: Any])?["reasons"] as? [Any] ?? []).compactMap { $0 as? String })
            try await ExtensionOffscreen.create(path, reasons: reasons, for: context, in: space,
                                                scheme: Self.scheme, host: ExtensionHost.shared)
            return nil
        case "offscreen.closeDocument":
            ExtensionOffscreen.close(id, in: space)
            return nil
        case "offscreen.hasDocument":
            return ExtensionOffscreen.hasDocument(id, in: space)

        // Supplied text only. This endpoint never reads a tab or grants access.
        case "i18n.detectLanguage":
            guard let text = first as? String else { throw Unanswered(why: "Language detection requires text.") }
            return ExtensionLanguage.detect(text).json

        // WebKit has no EyeDropper: the Mac's own colour sampler answers,
        // and a cancel answers an AbortError, as Chrome's picker does.
        case "eyeDropper.open":
            let colour: NSColor? = await withCheckedContinuation { done in
                DispatchQueue.main.async { NSColorSampler().show { done.resume(returning: $0) } }
            }
            guard let colour, let srgb = colour.usingColorSpace(.sRGB) else { throw Unanswered(why: "AbortError") }
            return String(format: "#%02x%02x%02x",
                          Int((srgb.redComponent * 255).rounded()),
                          Int((srgb.greenComponent * 255).rounded()),
                          Int((srgb.blueComponent * 255).rounded()))

        // MARK: native messaging, asked for as Chrome asks
        case "permissions.native":
            // Only for an extension that asked for it as optional; one that
            // asked for it outright had it at install.
            guard asksForNativeOnlyOptionally(id) else { return reachesApps(id) }
            switch first as? String {
            case "has":
                return reachesApps(id)
            case "remove":
                setNativeConsent(id, false)
                return true
            default:
                if reachesApps(id) { return true }
                let title = String(localized: "\u{201C}\(context.webExtension.displayName ?? id)\u{201D} wants to talk to apps on this Mac")
                let yes = await askForMore(title: title, from: context, in: space, window: Session.shared.frontWindow) {
                    NativeAppsGroup()
                }
                if yes { setNativeConsent(id, true) }
                return yes
            }

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
            if api == "management.get", first as? String != id { throw Unanswered(why: "No extension with id \(first ?? "")") }
            return describe(context)

        // MARK: a function to inject, from a page in a website's frame (Search's)
        case "scripting.file":
            // Only for an extension WebKit lets inject scripts at all.
            guard context.hasPermission(.scripting) else { throw Unanswered(why: "The extension never asked for \u{201C}scripting\u{201D}") }
            guard let item = installed.first(where: { $0.id == id }) else { throw Unanswered(why: "No such extension.") }
            return try Self.scriptingFile(first as? String ?? "", arguments: args.dropFirst().first as? [Any] ?? [],
                                          in: Self.prepared(item.id, item.version))

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
        case "idle.queryState" where Self.asks(context, for: "idle"), "idle.getAutoLockDelay" where Self.asks(context, for: "idle"),
             "power.requestKeepAwake" where Self.asks(context, for: "power"), "power.releaseKeepAwake" where Self.asks(context, for: "power"),
             "power.reportActivity" where Self.asks(context, for: "power"):
            return try idleOrPower(api, first: first, id: id, context: context, in: space)

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
            guard let item = installed.first(where: { $0.id == id }) else { throw Unanswered(why: "No such extension.") }
            return try Self.userScriptFile(first as? [String: Any] ?? [:], in: Self.prepared(item.id, item.version))
        case "userScripts.list" where Self.asks(context, for: "userScripts"):
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.kept("userscripts", of: id, in: space)))) ?? []
        case "userScripts.change" where Self.asks(context, for: "userScripts"):
            // Read, changed and written in one go, here on the main actor: two
            // of the extension's pages registering at once both keep theirs.
            let file = Self.kept("userscripts", of: id, in: space)
            var scripts = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
            let change = first as? [String: Any] ?? [:]
            func named(_ script: [String: Any]) -> String { script["id"] as? String ?? "" }
            for added in change["add"] as? [[String: Any]] ?? [] {
                guard !scripts.contains(where: { named($0) == named(added) }) else { throw Unanswered(why: "Duplicate script id '\(named(added))'") }
                scripts.append(added)
            }
            for updated in change["update"] as? [[String: Any]] ?? [] {
                guard let at = scripts.firstIndex(where: { named($0) == named(updated) }) else {
                    throw Unanswered(why: "Script with id '\(named(updated))' does not exist")
                }
                scripts[at].merge(updated) { $1 }
            }
            let removed = Set(change["remove"] as? [String] ?? [])
            scripts.removeAll { removed.contains(named($0)) }
            guard JSONSerialization.isValidJSONObject(scripts) else { throw Unanswered(why: "Invalid scripts.") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: scripts).write(to: file, options: .atomic)
            if let item = installed.first(where: { $0.id == id }) { Self.pruneUserScripts(of: id, in: Self.prepared(item.id, item.version)) }
            return scripts
        case "userScripts.world" where Self.asks(context, for: "userScripts"), "userScripts.worlds" where Self.asks(context, for: "userScripts"):
            let file = Self.kept("worlds", of: id, in: space)
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let properties = first as? [String: Any] ?? [:]
            let world = properties["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if properties["reset"] as? Bool != true, JSONSerialization.isValidJSONObject(properties) { worlds.append(properties) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: file, options: .atomic)
            return nil

        // MARK: a stream id for the worker, which has no page to record in (Search's)
        case "capture.grant" where Self.asks(context, for: "desktopCapture"):
            return await ExtensionCapture.shared.grant(for: context, in: space, sources: first as? [String] ?? [])

        // MARK: an extension's sign-in (Search's)
        case "identity.launchWebAuthFlow" where Self.asks(context, for: "identity"):
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unanswered(why: "No authorization url.") }
            // As in Chrome, a flow is out of sight unless it says it is interactive.
            if spec["interactive"] as? Bool != true {
                let wait = (spec["timeoutMsForNonInteractive"] as? NSNumber).map { $0.doubleValue / 1000 }
                return try await ExtensionAuth.quietly(url, extension: id, in: space,
                                                       abortOnLoad: spec["abortOnLoadForNonInteractive"] as? Bool ?? true,
                                                       timeout: wait).absoluteString
            }
            return try await ExtensionAuth.run(url, extension: id, context: context, in: space).absoluteString

        default:
            throw Unanswered(why: "eGlu doesn't answer \(api).")
        }
    }

    /// What eGlu keeps for an extension in a space beside its versions
    /// (user scripts, their worlds), which an update leaves and a removal
    /// from the space takes (clear).
    static func kept(_ name: String, of id: String, in space: UUID) -> URL {
        folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent("_eglu", isDirectory: true)
            .appendingPathComponent("\(name)-\(space.uuidString).json")
    }

    /// A user script (chrome.userScripts) written into a file of the
    /// extension's, by its content, for WebKit to register as a content
    /// script: its code, or the extension's own files it names and nothing
    /// outside its folder, inside a block that leaves when the page isn't
    /// one its globs take. Outside the page's own world it gets only
    /// runtime's messages, tagged for onUserScriptMessage, as Chrome's
    /// USER_SCRIPT world has. (Search's)
    static func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool = true) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String, let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __egluUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "eglu-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* eGlu: a user script (chrome.userScripts) */
        eglu_user_script: {
          const __egluHref = location.href;
          const __egluGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __egluIn = \#(json(script["includeGlobs"] ?? [])), __egluOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__egluIn.length && !__egluIn.some((g) => __egluGlob(g).test(__egluHref))) || __egluOut.some((g) => __egluGlob(g).test(__egluHref))) break eglu_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        guard writing else { return "_eglu/" + name }
        let dir = folder.appendingPathComponent("_eglu", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return "_eglu/" + name
    }

    /// User-script files no space's list names any more, let go: an edited
    /// script gets a file of its own each time. One made in the last minute
    /// stays, as an execute's may still be on its way into a page.
    static func pruneUserScripts(of id: String, in folder: URL) {
        // At most once a minute for an extension, as it reads every space's
        // list: one asked for sooner runs when the minute is up.
        let since = Date().timeIntervalSince(pruned[id] ?? .distantPast)
        guard since > 60 else {
            guard !prunePending.contains(id) else { return }
            prunePending.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + (60 - since) + 1) {
                MainActor.assumeIsolated {
                    prunePending.remove(id)
                    pruneUserScripts(of: id, in: folder)
                }
            }
            return
        }
        pruned[id] = Date()
        let lists = kept("userscripts", of: id, in: UUID()).deletingLastPathComponent()
        var named = Set<String>()
        for list in (try? FileManager.default.contentsOfDirectory(at: lists, includingPropertiesForKeys: nil)) ?? []
        where list.lastPathComponent.hasPrefix("userscripts-") {
            for script in (try? JSONSerialization.jsonObject(with: Data(contentsOf: list))) as? [[String: Any]] ?? [] {
                if let file = try? userScriptFile(script, in: folder, writing: false) { named.insert((file as NSString).lastPathComponent) }
            }
        }
        let dir = folder.appendingPathComponent("_eglu", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where file.lastPathComponent.hasPrefix("us-") && !named.contains(file.lastPathComponent) {
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if age > 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static var pruned: [String: Date] = [:]
    private static var prunePending: Set<String> = []

    /// One of the extension's own files, and nothing outside its folder: a
    /// name is resolved, links and all, before it is read.
    private static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
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

    /// When each extension's button was last pressed, by space and id:
    /// a permissions.request made from that press is one the person asked
    /// for, even once WebKit no longer counts the press (an extension that
    /// awaits something first, Figma's).
    static var pressed: [String: Date] = [:]

    /// permissions.request for what WebKit grants, refused by WebKit for
    /// want of a click, within ten seconds of a press on the extension's
    /// button, once, and only for permissions and sites its manifest names
    /// (optional ones included): asked as WebKit's own question would be.
    /// Extension pages, files and Google's sign-in are never given, so
    /// never asked about. Cookies are asked about as what they are: a yes
    /// lets the extension read them in every space (setReadsCookies).
    private func requestAfterClick(_ names: [String], origins: [String], context: WKWebExtensionContext, in space: UUID) async throws -> Bool {
        let key = "\(space.uuidString)/\(context.uniqueIdentifier)"
        guard let when = Self.pressed[key], Date().timeIntervalSince(when) < 10 else {
            throw Unanswered(why: "Invalid call to permissions.request(). Must be called during a user gesture.")
        }
        Self.pressed[key] = nil
        let package = context.webExtension
        let wanted = names.map { WKWebExtension.Permission(rawValue: $0) }
        let patterns = origins.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        // One that can't be read is refused, as Chrome refuses it, never dropped.
        guard patterns.count == origins.count else { throw Unanswered(why: "Invalid value for origin pattern.") }
        let named = package.requestedPermissions.union(package.optionalPermissions)
        // A site the manifest's own patterns cover, as Chrome lets an
        // extension ask for part of what it declared (one site of https://*/*).
        let declared = package.allRequestedMatchPatterns.union(package.optionalPermissionMatchPatterns)
        guard wanted.allSatisfy(named.contains), patterns.allSatisfy({ asked in declared.contains { $0.matches(asked) } }) else {
            throw Unanswered(why: "Only permissions specified in the manifest may be requested.")
        }
        // What eGlu never gives (files, Google's sign-in) makes the whole
        // request a no, as Chrome answers one it can't grant whole.
        let blocked = { (pattern: WKWebExtension.MatchPattern) in
            Self.withheld(pattern) || HandsOff.covers(host: pattern.host.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 })
        }
        guard !patterns.contains(where: blocked) else { return false }
        let missing = wanted.filter { context.permissionStatus(for: $0) != .grantedExplicitly }
        let unreached = patterns.filter { context.permissionStatus(for: $0) != .grantedExplicitly }
        guard !missing.isEmpty || !unreached.isEmpty else { return true }
        guard let owner = Session.shared.allWindows.first(where: { $0.spaceID == space && $0.window?.isKeyWindow == true })
                ?? Session.shared.allWindows.first(where: { $0.spaceID == space && $0.window?.isVisible == true }) else { return false }
        let spaceName = Session.shared.workspace.space(space)?.name ?? String(localized: "this space")
        let alert = NSAlert()
        alert.messageText = String(localized: "\u{201C}\(package.displayName ?? String(localized: "An extension"))\u{201D} asks for more.")
        let lines = missing.map { ExtensionAccessDescription.capability($0.rawValue) } + unreached.map { ExtensionAccessDescription.site($0.string) }
        let cookies = missing.contains(.cookies)
        alert.informativeText = lines.sorted().joined(separator: "\n") + "\n\n" + String(localized: "Applies in \(spaceName). Google's sign-in pages remain blocked.")
            + (cookies ? " " + ExtensionAccessGroups.cookiesNote : "")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        guard await present(alert, in: owner) == .alertFirstButtonReturn else { return false }
        for permission in missing { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in unreached { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        Self.fence(context)
        if cookies { setReadsCookies(context.uniqueIdentifier, true, restarting: false) }
        return true
    }

    /// Whether the extension has `permission`: its manifest asks for it
    /// outright, as the permission it was added with, or as an optional one
    /// the person has since granted (permissions.request, afterClick). The
    /// native answers are held to that: an extension can't keep the Mac
    /// awake without having asked as it was added or since. The shim may
    /// show the namespace before, whose calls are then refused.
    static func asks(_ context: WKWebExtensionContext, for permission: String) -> Bool {
        let manifest = context.webExtension.manifest
        if (manifest["permissions"] as? [String] ?? []).contains(permission) { return true }
        return (manifest["optional_permissions"] as? [String] ?? []).contains(permission)
            && context.permissionStatus(for: WKWebExtension.Permission(rawValue: permission)) == .grantedExplicitly
    }

    private func idleOrPower(_ api: String, first: Any?, id: String, context: WKWebExtensionContext, in space: UUID) throws -> Any? {
        switch api {
        case "idle.queryState":
            // Locked when the Mac's screen is; idle once no key or pointer
            // has moved for the seconds asked (15 at least, as Chrome);
            // active otherwise. A password manager locks its vault by it.
            let threshold = max(15, (first as? Double) ?? 60)
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
               session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return quiet >= threshold ? "idle" : "active"
        case "idle.getAutoLockDelay":
            // Chrome's is ChromeOS's alone: zero, for a screen that locks when the Mac says.
            return 0
        case "power.requestKeepAwake":
            let key = "\(space.uuidString)/\(id)"
            if let old = keptAwake.removeValue(forKey: key) { IOPMAssertionRelease(old) }
            var assertion: IOPMAssertionID = 0
            let kind = ((first as? String) == "display" ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            let why = String(localized: "An extension in eGlu: \(context.webExtension.displayName ?? id)") as CFString
            if IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn), why, &assertion) == kIOReturnSuccess {
                keptAwake[key] = assertion
            }
            return nil
        case "power.releaseKeepAwake":
            if let old = keptAwake.removeValue(forKey: "\(space.uuidString)/\(id)") { IOPMAssertionRelease(old) }
            return nil
        case "power.reportActivity":
            var assertion: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("An extension in eGlu" as CFString, kIOPMUserActiveLocal, &assertion)
            return nil
        default:
            throw Unanswered(why: "eGlu doesn't answer \(api).")
        }
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

    /// management's ExtensionInfo, of the extension itself.
    private func describe(_ context: WKWebExtensionContext) -> [String: Any] {
        let package = context.webExtension
        let item = installed.first { $0.id == context.uniqueIdentifier }
        var info: [String: Any] = [
            "id": context.uniqueIdentifier,
            "name": package.displayName ?? item?.name ?? "",
            "shortName": package.displayShortName ?? package.displayName ?? "",
            "description": package.displayDescription ?? "",
            "version": package.version ?? item?.version ?? "",
            "enabled": true, "mayDisable": true, "offlineEnabled": false,
            "type": "extension",
            "installType": item?.source == .unsigned ? "development" : "normal",
            "permissions": package.requestedPermissions.map(\.rawValue).sorted(),
            "hostPermissions": package.allRequestedMatchPatterns.map(\.string).sorted(),
            "isApp": false,
        ]
        if let options = context.optionsPageURL { info["optionsUrl"] = options.absoluteString }
        return info
    }

    /// A desktop app a host stands for, in the words a person knows it by.
    static func appName(ofHost host: String) -> String {
        let known = ["com.8bit.bitwarden": "Bitwarden", "com.1password": "1Password", "com.apple.passwordmanager": String(localized: "iCloud Passwords"),
                     "com.dashlane": "Dashlane", "com.lastpass": "LastPass", "com.keepassxc": "KeePassXC", "org.keepassxc": "KeePassXC"]
        return known.first { host.hasPrefix($0.key) }?.value ?? host
    }
}
