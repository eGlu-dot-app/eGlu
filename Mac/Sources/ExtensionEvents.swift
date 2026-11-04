import Foundation
import PadCore
import WebKit

/// Events stay within the extension and space that opened the port.
@MainActor
final class ExtensionEvents {
    static let shared = ExtensionEvents()
    static let application = "eglu.events"
    private struct Listener {
        let port: WKWebExtension.MessagePort
        weak var context: WKWebExtensionContext?
        let space: UUID
        var events: Set<String> = []
    }
    private var listeners: [ObjectIdentifier: Listener] = [:]
    private var subscriptions: [String: Set<String>] = [:]
    private var pending: [String: [[String: Any]]] = [:]

    private func key(_ id: String, _ space: UUID) -> String { "\(space.uuidString)/\(id)" }

    func workspaceChanged(from before: Workspace, to next: Workspace) {
        for space in next.spaces {
            let old = before.space(space.id)
            if old?.bookmarks != space.bookmarks {
                let from = ExtensionBookmarks(old?.bookmarks ?? []), to = ExtensionBookmarks(space.bookmarks)
                let previous = Dictionary(uniqueKeysWithValues: from.entries.map { ($0.item.id, $0) })
                let current = Dictionary(uniqueKeysWithValues: to.entries.map { ($0.item.id, $0) })
                let kept = Set(to.entries.filter { previous[$0.item.id]?.parent == $0.parent }.map { $0.item.id })
                func positions(_ tree: ExtensionBookmarks) -> [UUID: Int] {
                    let groups = Dictionary(grouping: tree.entries.filter { kept.contains($0.item.id) }, by: \.parent)
                    return groups.values.reduce(into: [:]) { result, group in
                        for (index, row) in group.enumerated() { result[row.item.id] = index }
                    }
                }
                let oldPositions = positions(from), newPositions = positions(to)
                for row in to.entries {
                    let node = to.node(row.item, parent: row.parent, index: row.index)
                    guard let was = previous[row.item.id] else {
                        send("bookmarks.onCreated", arguments: [row.item.id.uuidString, node], permission: "bookmarks", in: space.id)
                        continue
                    }
                    if was.item.title != row.item.title || was.item.url != row.item.url {
                        var change: [String: Any] = ["title": row.item.title]
                        if let url = row.item.url { change["url"] = url.absoluteString }
                        send("bookmarks.onChanged", arguments: [row.item.id.uuidString, change], permission: "bookmarks", in: space.id)
                    }
                    if was.parent != row.parent || oldPositions[row.item.id] != newPositions[row.item.id] {
                        send("bookmarks.onMoved", arguments: [row.item.id.uuidString, ["parentId": row.parent, "index": row.index,
                                                                                   "oldParentId": was.parent, "oldIndex": was.index]], permission: "bookmarks", in: space.id)
                    }
                }
                for row in from.entries where current[row.item.id] == nil {
                    if let parent = UUID(uuidString: row.parent), current[parent] == nil { continue }
                    send("bookmarks.onRemoved", arguments: [row.item.id.uuidString, ["parentId": row.parent, "index": row.index,
                                                                                   "node": from.node(row.item, parent: row.parent, index: row.index, recursive: true)]], permission: "bookmarks", in: space.id)
                }
            }
            if before.closed.filter({ $0.space == space.id }) != next.closed.filter({ $0.space == space.id }) {
                send("sessions.onChanged", arguments: [], permission: "sessions", in: space.id)
            }
        }
    }

    func visited(_ visit: HistoryVisit) {
        send("history.onVisited", arguments: [["id": History.pageKey(visit.url), "url": visit.url.absoluteString,
                                             "title": visit.title, "lastVisitTime": visit.time.timeIntervalSince1970 * 1000]], permission: "history", in: visit.space)
    }

    func connect(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext, space: UUID) {
        listeners = listeners.filter { !$0.value.port.isDisconnected && $0.value.context != nil }
        let key = ObjectIdentifier(port)
        listeners[key] = Listener(port: port, context: context, space: space)
        port.disconnectHandler = { [weak self] _ in self?.listeners[key] = nil }
        let owner = self.key(context.uniqueIdentifier, space)
        port.messageHandler = { [weak self, weak context, weak port] value, _ in
            guard let self, let context, let port, let message = value as? [String: Any] else { return }
            guard Extensions.shared.context(context.uniqueIdentifier, in: space) === context else { port.disconnect(); return }
            // The worker's native-port shim waits for this acknowledgment.
            if message["__egluNative"] as? String == "here?" {
                port.sendMessage(["__egluNative": "here"], completionHandler: nil)
                return
            }
            guard let asked = message["__egluEvents"] as? [String: Any], let names = asked["events"] as? [String] else { return }
            let events = Set(names.prefix(64).filter(ExtensionError.isAPIPath))
            self.listeners[key]?.events = events
            // Only the worker's listeners survive its port closing. A page's
            // subscriptions end with the page and never replace the worker's.
            if asked["background"] as? Bool == true {
                self.subscriptions[owner] = events
                let queued = self.pending.removeValue(forKey: owner) ?? []
                for message in queued {
                    if let name = message["event"] as? String, events.contains(name) { port.sendMessage(message, completionHandler: nil) }
                    else { self.pending[owner, default: []].append(message) }
                }
            }
        }
    }

    func send(_ event: String, arguments: [Any], permission: String, in space: UUID) {
        for context in Extensions.shared.contexts[space]?.values ?? [:].values where Extensions.asks(context, for: permission) {
            send(event, arguments: arguments, to: context.uniqueIdentifier, in: space)
        }
    }

    func send(_ event: String, arguments: [Any], to id: String, in space: UUID) {
        let owner = key(id, space)
        guard let context = Extensions.shared.context(id, in: space) else { return }
        let ports = listeners.values.filter { $0.space == space && $0.context === context && !$0.port.isDisconnected && $0.events.contains(event) }
        let message: [String: Any] = ["event": event, "args": arguments]
        if !ports.isEmpty {
            for listener in ports { listener.port.sendMessage(message, completionHandler: nil) }
            return
        }
        guard subscriptions[owner]?.contains(event) == true, context.webExtension.hasBackgroundContent else { return }
        let waking = pending[owner] != nil
        if pending[owner, default: []].count < 64 { pending[owner, default: []].append(message) }
        guard !waking else { return }
        context.loadBackgroundContent { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.pending[owner] = nil }
    }

    func close(_ id: String, in space: UUID) {
        let owner = key(id, space)
        subscriptions[owner] = nil
        pending[owner] = nil
        for (key, listener) in Array(listeners) where listener.space == space && listener.context?.uniqueIdentifier == id {
            listeners[key] = nil
            listener.port.disconnect()
        }
    }
}
