#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit

/// The shim's browser and pane answers, on the original hub's main actor.
/// The host retains panel presentation and supplies current product values.
@MainActor
public final class WebKitExtensionBrowserAnswers: WebExtensionBrowserAnswers {
    private let host: any ExtensionBrowserAnswerHost
    private let unanswered: (String) -> any Error
    private let scheme: String
    public var popupPaths: [String: String] = [:]

    public init(host: any ExtensionBrowserAnswerHost, unanswered: @escaping (String) -> any Error, scheme: String) {
        self.host = host; self.unanswered = unanswered; self.scheme = scheme
    }

    public func answer(_ api: String, _ args: [Any], id: String, context: WKWebExtensionContext, in space: UUID) throws -> Any? {
        let first = args.first
        switch api {
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

        // MARK: the side panel (ExtensionSidePanel.swift)
        case "sidePanel.setOptions":
            let options = first as? [String: Any] ?? [:]
            let tab = options["tabId"] == nil ? nil : self.tab(at: options["__place"], in: space)
            // A tab it named that can't be found: nothing set, rather than every tab.
            if options["tabId"] != nil, tab == nil { return nil }
            host.setExtensionPanelOptions(id, in: space, tab: tab, path: options["path"] as? String, enabled: options["enabled"] as? Bool)
            return nil
        case "sidePanel.getOptions":
            let options = first as? [String: Any] ?? [:]
            return host.extensionPanelOptions(id, in: space, tab: self.tab(at: options["__place"], in: space))
        case "sidePanel.setPanelBehavior":
            let behavior = first as? [String: Any] ?? [:]
            if let on = behavior["openPanelOnActionClick"] as? Bool { host.setExtensionPanelOpensOnAction(id, in: space, on) }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": host.extensionPanelOpensOnAction(id, in: space)]
        case "sidePanel.open", "sidePanel.close":
            let options = first as? [String: Any] ?? [:]
            let tab = self.tab(at: options["__place"], in: space)
            // A tab it named that can't be found: an error, not the tab in front.
            if options["tabId"] != nil, tab == nil { throw unanswered("No tab with id: \(options["tabId"] ?? "").") }
            try host.presentExtensionPanel(api == "sidePanel.open" ? .open : .close, id, tab: tab, in: space)
            return nil

        // MARK: the popup its button opens, as it set it
        case "action.popup":
            popupPaths["\(space.uuidString)/\(id)"] = first as? String ?? ""
            return nil

        // MARK: which of eGlu's panes shows a page
        case "surface.kind":
            let url = first as? String
            let shows = { (surface: ExtensionAnswerSurface) in
                surface.extensionID == id && surface.space == space && surface.url?.absoluteString == url
            }
            if host.extensionAnswerSurfaces(.popup).contains(where: shows) { return "popup" }
            if host.extensionAnswerSurfaces(.sidePanel).contains(where: shows) { return "sidePanel" }
            return "tab"

        // MARK: tabs, by their place in the space (Search's)
        case "tabs.describe" where context.hasPermission(.tabs):
            let rows = host.extensionAnswerTabs(in: space)
            return ((first as? [Any]) ?? []).map { place -> Any in
                guard let index = (place as? NSNumber)?.intValue, rows.indices.contains(index) else { return NSNull() }
                let record = rows[index]
                let page = host.extensionAnswerPage(record.id)
                let url = Self.address(of: page, for: context, else: page?.url ?? record.url)
                // Another extension's page stays blank, as WebKit keeps it (ExtensionTab.sealed).
                if WebKitExtensionControllers.othersPage(url, for: context) || WebKitExtensionControllers.othersPage(record.url, for: context) { return ["url": "", "title": ""] }
                var described: [String: Any] = ["url": url?.absoluteString ?? "", "title": page?.title ?? record.title]
                if let icon = favIconURL(for: url) { described["favIconUrl"] = icon }
                return described
            }

        default:
            throw unanswered("eGlu doesn't answer \(api).")
        }
    }

    /// A tab's icon for favIconUrl: the picture the tab wears, as a small
    /// PNG, since eGlu keeps icons as pictures, not addresses (Chrome's may
    /// be a data: address too). Made once for each site's picture, and made
    /// again when the site's picture is another.
    private static var favIcons: [String: (icon: NSImage, made: String)] = [:]

    public func favIconURL(for url: URL?) -> String? {
        guard let host = url?.host(), let icon = self.host.extensionAnswerIcon(for: url) else { return nil }
        if let known = Self.favIcons[host], known.icon === icon { return known.made }
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
        if Self.favIcons.count > 500 { Self.favIcons.removeAll() }
        Self.favIcons[host] = (icon, made)
        return made
    }

    /// The tab at a place the shim found for a tab number (its index in the
    /// space's window, and its address, which must still be there).
    public func tab(at place: Any?, in space: UUID) -> UUID? {
        guard let place = place as? [String: Any], let index = place["index"] as? Int,
              case let tabs = host.extensionAnswerTabs(in: space), tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        if let address = place["url"] as? String, !address.isEmpty {
            let now = host.extensionAnswerPage(tab.id)?.url ?? tab.url
            guard now?.absoluteString == address else { return nil }
        }
        return tab.id
    }

    /// The same held-address rule as ExtensionTab.address, over host values.
    private static func address(of page: ExtensionAnswerPage?, for context: WKWebExtensionContext, else shown: @autoclosure () -> URL?) -> URL? {
        guard page?.held != nil else { return shown() }
        guard let held = page?.held, WebKitExtensionAuth.owner(of: held) == context.uniqueIdentifier.lowercased() else { return nil }
        return held
    }

    /// The extension's own pages open in the space's tabs, as clients.matchAll lists them.
    private func ownPages(of id: String, in space: UUID) -> [[String: Any]] {
        var pages: [[String: Any]] = []
        for tab in host.extensionAnswerTabs(in: space) {
            guard let url = host.extensionAnswerPage(tab.id)?.url,
                  url.scheme == scheme, url.host() == id else { continue }
            let window = host.extensionAnswerVisibleWindow(showing: tab.id)
            pages.append(["id": tab.id.uuidString, "url": url.absoluteString,
                          "visible": window != nil, "focused": window?.focused == true])
        }
        // Its popup and side panel while they are up: 1Password's worker
        // sends its popup the app's news only when it finds it open. (Search's)
        let surfaces = host.extensionAnswerSurfaces(.popup) + host.extensionAnswerSurfaces(.sidePanel)
        for surface in surfaces where surface.extensionID == id && surface.space == space {
            guard let url = surface.url else { continue }
            let kind = surface.kind.rawValue
            pages.append(["id": "\(kind.lowercased())-\(surface.window)", "url": url.absoluteString,
                          "visible": true, "focused": surface.focused, "kind": kind])
        }
        // A worker finds the popup windows it opened (windows.create) through
        // these, as Chrome lists their pages, among its tabs: without them it
        // can't send its own window a word.
        for popup in ExtensionPopupWindow.all(in: space) {
            guard let url = popup.page?.state.url, url.scheme == scheme, url.host() == id else { continue }
            pages.append(["id": "window-\(ObjectIdentifier(popup).hashValue)", "url": url.absoluteString,
                          "visible": popup.snapshot?.isVisible == true, "focused": popup.snapshot?.isKey == true])
        }
        return pages
    }

    /// The popup an extension's button opens: the one it set, or its manifest's.
    public func popupURL(for context: WKWebExtensionContext, in space: UUID) -> URL? {
        let key = "\(space.uuidString)/\(context.uniqueIdentifier)"
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        let path = popupPaths[key] ?? action?["default_popup"] as? String
        guard let path, !path.isEmpty else { return nil }
        // Relative to the extension, keeping a query it may carry.
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

}
#endif
