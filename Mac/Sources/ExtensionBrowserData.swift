import AppKit
import PadCore
import WebKit

extension Extensions {
    /// APIs backed by the browser's data. Every operation stays in its originating space.
    func browserData(_ api: String, _ args: [Any], context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        let namespace = String(api.prefix { $0 != "." })
        guard Self.asks(context, for: namespace), Session.shared.canUseWorkspace else {
            throw Unanswered(why: "This extension does not have access to this feature in this space.")
        }
        let first = args.first
        let options = first as? [String: Any] ?? [:]
        if namespace == "bookmarks" {
            let session = Session.shared
            guard let index = session.workspace.spaces.firstIndex(where: { $0.id == space }) else { throw Unanswered(why: "The space was removed.") }
            let before = session.workspace.spaces[index].bookmarks
            var tree = ExtensionBookmarks(before)
            let value = try tree.answer(String(api.dropFirst("bookmarks.".count)), arguments: args)
            if tree.items != before {
                session.change { workspace in
                    guard let index = workspace.spaces.firstIndex(where: { $0.id == space }) else { return }
                    workspace.spaces[index].bookmarks = tree.items
                }
            }
            return value
        }
        if namespace == "history" || namespace == "topSites" {
            let history = HistoryRecorder.shared
            switch api {
            case "history.search", "topSites.get":
                let from = Self.extensionDate(options["startTime"], fallback: api == "history.search" ? Date().addingTimeInterval(-86_400) : .distantPast)
                let to = Self.extensionDate(options["endTime"], fallback: .distantFuture)
                let text = options["text"] as? String ?? ""
                let limit = api == "topSites.get" ? 20 : options["maxResults"] as? Int ?? 100
                guard from <= to, (0...10_000).contains(limit) else { throw Unanswered(why: "Invalid history time range or result limit.") }
                let pages = try await history.readOutcome {
                    try await $0.extensionSearch(space: space, text: text, from: from, to: to, limit: limit, mostVisited: api == "topSites.get")
                }.get()
                return pages.map { page -> [String: Any] in
                    if api == "topSites.get" { return ["url": page.url.absoluteString, "title": page.title] }
                    return ["id": page.key, "url": page.url.absoluteString, "title": page.title,
                            "lastVisitTime": page.last.timeIntervalSince1970 * 1000, "visitCount": page.count]
                }
            case "history.getVisits":
                guard let url = (options["url"] as? String).flatMap(URL.init(string:)) else { throw Unanswered(why: "A history address is required.") }
                let visits = try await history.readOutcome { try await $0.extensionVisits(space: space, url: url) }.get()
                return visits.map { visit in ["id": History.pageKey(visit.url), "visitId": visit.id.uuidString,
                                             "visitTime": visit.time.timeIntervalSince1970 * 1000, "referringVisitId": "0",
                                             "transition": visit.kind == .typed ? "typed" : visit.kind == .bookmark ? "auto_bookmark" : "link"] as [String: Any] }
            case "history.addUrl":
                guard let url = (options["url"] as? String).flatMap(URL.init(string:)), History.keeps(url) else {
                    throw Unanswered(why: "This browser cannot save sign-in pages, credentials, or local files in history.")
                }
                guard history.visit(space: space, url: url, title: nil, kind: .link) != nil else { throw Unanswered(why: "This page cannot be added to history.") }
                let written = await history.writeAcknowledged { _ in }
                guard written else { throw Unanswered(why: "History could not be saved. Check History settings and try again.") }
                return nil
            case "history.deleteUrl", "history.deleteRange", "history.deleteAll":
                let scope: HistoryRemoval.Scope
                if api == "history.deleteUrl" {
                    guard let url = (options["url"] as? String).flatMap(URL.init(string:)) else { throw Unanswered(why: "A history address is required.") }
                    scope = .page(History.digest(ofKey: History.pageKey(url)))
                } else if api == "history.deleteRange" {
                    guard options["startTime"] != nil, options["endTime"] != nil else { throw Unanswered(why: "A history time range is required.") }
                    let from = Self.extensionDate(options["startTime"], fallback: .distantPast)
                    let to = Self.extensionDate(options["endTime"], fallback: .distantFuture)
                    guard from <= to else { throw Unanswered(why: "Invalid history time range.") }
                    scope = .range(from: from, to: to)
                } else { scope = .all }
                try await history.clear(history.clearing(space: space, scope: scope)).get()
                ExtensionEvents.shared.send("history.onVisitRemoved", arguments: [["allHistory": api == "history.deleteAll",
                                                                                   "urls": (options["url"] as? String).map { [$0] } ?? []]], permission: "history", in: space)
                return nil
            default: break
            }
        }
        if namespace == "sessions" {
            switch api {
            case "sessions.getRecentlyClosed":
                let limit = options["maxResults"] as? Int ?? Workspace.closedKept
                guard (0...Workspace.closedKept).contains(limit) else { throw Unanswered(why: "Invalid recently closed tab limit.") }
                return Session.shared.workspace.closed.reversed().filter { $0.space == space && $0.tab.url.map(History.keeps) == true }.prefix(limit).map { closed in
                    ["lastModified": closed.tab.shown.timeIntervalSince1970,
                     "tab": ["sessionId": closed.tab.id.uuidString, "url": closed.tab.url?.absoluteString ?? "", "title": closed.tab.title,
                             "index": closed.index, "pinned": false, "incognito": false]] as [String: Any]
                }
            case "sessions.restore":
                let session = Session.shared
                let requested = (first as? String).flatMap(UUID.init(uuidString:))
                if first != nil, requested == nil { throw Unanswered(why: "Invalid session id.") }
                guard let closed = session.workspace.closed.last(where: { $0.space == space && (requested == nil || $0.tab.id == requested) }),
                      let url = closed.tab.url, History.keeps(url) else { throw Unanswered(why: "No recently closed tab in this space.") }
                // Restore the selected record without changing another space's closed tabs.
                guard let tab = tabs.open(url, in: space, active: true, pinned: false, context: context) else { throw Unanswered(why: "The tab could not be restored.") }
                session.change { $0.closed.removeAll { $0.space == space && $0.tab.id == closed.tab.id } }
                return ["lastModified": Date().timeIntervalSince1970, "tab": ["url": url.absoluteString, "title": closed.tab.title, "index": tab.indexInWindow(for: context), "incognito": false]]
            default: break
            }
        }
        if api == "search.query" {
            guard let text = options["text"] as? String, !text.isEmpty,
                  let url = Destination.search(text, engine: Session.shared.preferences.engine) else { throw Unanswered(why: "Search text is required.") }
            let disposition = options["disposition"] as? String ?? "CURRENT_TAB"
            guard options["tabId"] == nil else { throw Unanswered(why: "This browser cannot search in a tab selected by its numeric id. Use the current tab or a new tab.") }
            guard ["CURRENT_TAB", "NEW_TAB", "NEW_WINDOW"].contains(disposition) else { throw Unanswered(why: "Invalid search disposition.") }
            if disposition == "CURRENT_TAB", let record = Session.shared.workspace.space(space)?.selected {
                let tab = tabs.tab(record, in: space)
                tab.loadURL(url, for: context) { _ in }
            } else {
                _ = tabs.open(url, in: space, active: true, pinned: false, context: context)
                if disposition == "NEW_WINDOW" { Session.shared.openWindow?(space) }
            }
            return nil
        }
        if namespace == "browsingData" { return try await browsingData(api, options: options, arguments: args, context: context, in: space) }
        throw Unanswered(why: "This browser cannot perform this extension action.")
    }

    static func extensionDate(_ value: Any?, fallback: Date) -> Date {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return fallback }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    private func browsingData(_ api: String, options: [String: Any], arguments: [Any], context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        let supported: [String: String] = ["cache": WKWebsiteDataTypeDiskCache, "localStorage": WKWebsiteDataTypeLocalStorage,
                                          "indexedDB": WKWebsiteDataTypeIndexedDBDatabases, "serviceWorkers": WKWebsiteDataTypeServiceWorkerRegistrations,
                                          "history": "", "downloads": ""]
        if api == "browsingData.settings" {
            return ["options": ["since": 0, "originTypes": ["unprotectedWeb": true, "protectedWeb": false, "extension": false]],
                    "dataToRemove": supported.mapValues { _ in false }, "dataRemovalPermitted": supported.mapValues { _ in true }]
        }
        let method = String(api.dropFirst("browsingData.".count))
        let names = method == "remove" ? (arguments.dropFirst().first as? [String: Bool] ?? [:]).filter(\.value).map(\.key)
            : [String(method.dropFirst("remove".count)).prefix(1).lowercased() + String(method.dropFirst("remove".count + 1))]
        guard method == "remove" || method.hasPrefix("remove"), names.allSatisfy({ supported[$0] != nil }),
              options["origins"] == nil, options["excludeOrigins"] == nil else {
            throw Unanswered(why: "This browser can clear website caches, local storage, databases, service workers, history, and finished download activity in this space. It cannot clear cookies, passwords, or data selected by origin through an extension.")
        }
        let origins = options["originTypes"] as? [String: Bool] ?? [:]
        guard origins["extension"] != true, origins["protectedWeb"] != true else { throw Unanswered(why: "Extensions cannot clear protected sign-in or extension data.") }
        guard options["since"] == nil || (options["since"] as? NSNumber)?.doubleValue == 0 else {
            throw Unanswered(why: "This browser cannot clear website data by a time range. Clear all time in this space instead.")
        }
        if origins["unprotectedWeb"] == false { return nil }
        if names.contains("history") {
            let recorder = HistoryRecorder.shared
            try await recorder.clear(recorder.clearing(space: space, scope: .all)).get()
        }
        if names.contains("downloads") {
            let finished = Downloads.shared.items.filter { $0.space == space && $0.phase != .downloading }
            Downloads.shared.eraseExtensionActivity(Set(finished.map(\.id)), in: space)
        }
        let types = Set(names.compactMap { supported[$0] }.filter { !$0.isEmpty })
        guard !types.isEmpty else { return nil }
        let store = Stores.store(for: space)
        let records = await store.dataRecords(ofTypes: types)
        guard contexts[space]?[context.uniqueIdentifier] === context else { throw Unanswered(why: "The extension was turned off.") }
        let allowed = records.filter { ExtensionPolicy.mayTouchData(ofDomain: $0.displayName) }
        await store.removeData(ofTypes: types, for: allowed)
        return nil
    }
}
