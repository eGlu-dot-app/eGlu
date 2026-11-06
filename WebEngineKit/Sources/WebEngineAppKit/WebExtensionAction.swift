import AppKit

/// An action read for one render, with its icon at the size the app asked for.
/// No icon is requested when only the action's enabled state is needed.
public struct WebExtensionAction {
    public let icon: NSImage?
    public let label: String
    public let badgeText: String
    public let isEnabled: Bool

    public init(icon: NSImage?, label: String, badgeText: String, isEnabled: Bool) {
        self.icon = icon
        self.label = label
        self.badgeText = badgeText
        self.isEnabled = isEnabled
    }
}

/// A command's menu line. Its identity is local to its extension context;
/// the app supplies the extension and space when asking to perform it.
/// The menu's key comes from the person's settings, not the runtime's key.
public struct WebExtensionCommand: Sendable {
    public struct Identity: Hashable, Sendable {
        public let context: UUID
        public let command: String

        public init(context: UUID, command: String) {
            self.context = context
            self.command = command
        }
    }

    public let id: String
    public let title: String
    public let identity: Identity

    public init(identity: Identity, title: String) {
        self.id = identity.command
        self.title = title
        self.identity = identity
    }
}
