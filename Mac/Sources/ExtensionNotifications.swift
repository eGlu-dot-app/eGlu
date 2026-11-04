import Foundation
import PadCore
import UserNotifications
import WebKit

@MainActor
final class ExtensionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ExtensionNotifications()
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        // Extension notifications are the app's only local notification source.
        center.delegate = self
    }

    private func key(_ notification: String, id: String, space: UUID) -> String {
        "eglu.extension.\(space.uuidString).\(id)." + Data(notification.utf8).base64EncodedString()
    }

    private func owned(_ content: UNNotificationContent, id: String, space: UUID) -> Bool {
        content.userInfo["egluExtension"] as? String == id && content.userInfo["egluSpace"] as? String == space.uuidString
    }

    func answer(_ api: String, _ args: [Any], context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        guard Extensions.asks(context, for: "notifications") else { throw Extensions.Unanswered(why: "This extension does not have notification access.") }
        let id = context.uniqueIdentifier
        if api == "notifications.getPermissionLevel" {
            let settings = await center.notificationSettings()
            return [.authorized, .provisional].contains(settings.authorizationStatus) ? "granted" : "denied"
        }
        if api == "notifications.getAll" {
            var found: [String: Bool] = [:]
            for notification in await center.deliveredNotifications() where owned(notification.request.content, id: id, space: space) {
                if let name = notification.request.content.userInfo["egluNotification"] as? String { found[name] = true }
            }
            for request in await center.pendingNotificationRequests() where owned(request.content, id: id, space: space) {
                if let name = request.content.userInfo["egluNotification"] as? String { found[name] = true }
            }
            return found
        }
        let name = args.first as? String ?? ""
        guard !name.isEmpty, name.utf8.count <= 512 else { throw Extensions.Unanswered(why: "Invalid notification id.") }
        let identifier = key(name, id: id, space: space)
        let delivered = await center.deliveredNotifications().first { $0.request.identifier == identifier }?.request
        let pending = await center.pendingNotificationRequests().first { $0.identifier == identifier }
        if api == "notifications.clear" {
            guard delivered != nil || pending != nil else { return false }
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            ExtensionEvents.shared.send("notifications.onClosed", arguments: [name, false], to: id, in: space)
            return true
        }
        guard ["notifications.create", "notifications.update"].contains(api) else { throw Extensions.Unanswered(why: "This notification action is unavailable.") }
        if api == "notifications.update", delivered == nil, pending == nil { return false }
        let options = args.dropFirst().first as? [String: Any] ?? [:]
        let content = ((delivered ?? pending)?.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let type = options["type"] as? String ?? "basic"
        guard ["basic", "list"].contains(type) else { throw Extensions.Unanswered(why: "This browser can show text and list notifications. Image and progress notifications are unavailable.") }
        if let title = options["title"] as? String { content.title = title }
        if let message = options["message"] as? String { content.body = message }
        if let subtitle = options["contextMessage"] as? String { content.subtitle = subtitle }
        if type == "list" {
            let items = options["items"] as? [[String: String]] ?? []
            content.body += "\n" + items.map { ($0["title"] ?? "") + ": " + ($0["message"] ?? "") }.joined(separator: "\n")
        }
        guard !content.title.isEmpty, !content.body.isEmpty else { throw Extensions.Unanswered(why: "A notification title and message are required.") }
        content.userInfo = ["egluExtension": id, "egluSpace": space.uuidString, "egluNotification": name]
        content.threadIdentifier = "\(space.uuidString)/\(id)"
        if let silent = options["silent"] as? Bool { content.sound = silent ? nil : .default }
        else if api == "notifications.create" { content.sound = .default }
        let buttons = options["buttons"] as? [[String: String]] ?? []
        guard buttons.count <= 2 else { throw Extensions.Unanswered(why: "A notification can have at most two buttons.") }
        if !buttons.isEmpty {
            let category = UNNotificationCategory(identifier: identifier, actions: buttons.enumerated().map {
                UNNotificationAction(identifier: "eglu.button.\($0.offset)", title: $0.element["title"] ?? "", options: [.foreground])
            }, intentIdentifiers: [], options: [.customDismissAction])
            var categories = await center.notificationCategories().filter { $0.identifier != identifier }
            categories.insert(category)
            center.setNotificationCategories(categories)
            content.categoryIdentifier = identifier
        } else if options["buttons"] != nil || api == "notifications.create" {
            let category = UNNotificationCategory(identifier: "eglu.extension.basic", actions: [], intentIdentifiers: [], options: [.customDismissAction])
            var categories = await center.notificationCategories()
            categories.insert(category)
            center.setNotificationCategories(categories)
            content.categoryIdentifier = category.identifier
        }
        let allowed = try await center.requestAuthorization(options: [.alert, .sound])
        guard allowed else { throw Extensions.Unanswered(why: "Notifications are off for eGlu. Allow notifications in macOS System Settings to see extension alerts.") }
        guard Extensions.shared.context(id, in: space) === context else { throw Extensions.Unanswered(why: "The extension was turned off.") }
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        return api == "notifications.update" ? true : name as Any
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let id = info["egluExtension"] as? String, let rawSpace = info["egluSpace"] as? String,
           let space = UUID(uuidString: rawSpace), let name = info["egluNotification"] as? String {
            let action = response.actionIdentifier
            Task { @MainActor in
                if action == UNNotificationDismissActionIdentifier {
                    ExtensionEvents.shared.send("notifications.onClosed", arguments: [name, true], to: id, in: space)
                } else if action.hasPrefix("eglu.button."), let index = Int(action.dropFirst("eglu.button.".count)) {
                    ExtensionEvents.shared.send("notifications.onButtonClicked", arguments: [name, index], to: id, in: space)
                } else if action == UNNotificationDefaultActionIdentifier {
                    ExtensionEvents.shared.send("notifications.onClicked", arguments: [name], to: id, in: space)
                }
            }
        }
        completionHandler()
    }
}
