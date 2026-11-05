#if os(macOS)
import AppKit
import WebEngineAppKit
import WebKit

public enum WebKitExtensionActions {
    @MainActor
    public static func look(of action: WKWebExtension.Action, iconSize: CGSize? = nil) -> WebExtensionAction {
        WebExtensionAction(icon: iconSize.flatMap { action.icon(for: $0) }, label: action.label,
                           badgeText: action.badgeText, isEnabled: action.isEnabled)
    }
}

public enum WebKitExtensionCommands {
    // A menu kept across a reload must not run a replacement context's command.
    // Weak keys keep these identities from extending a context's lifetime.
    @MainActor
    private static let identities = NSMapTable<WKWebExtensionContext, NSUUID>.weakToStrongObjects()

    @MainActor
    private static func identity(of context: WKWebExtensionContext) -> UUID {
        if let known = identities.object(forKey: context) { return known as UUID }
        let made = UUID()
        identities.setObject(made as NSUUID, forKey: context)
        return made
    }

    @MainActor
    public static func commands(in context: WKWebExtensionContext) -> [WebExtensionCommand] {
        let owner = identity(of: context)
        return context.commands.map {
            WebExtensionCommand(identity: .init(context: owner, command: $0.id), title: $0.title)
        }
    }

    @MainActor
    public static func perform(_ identity: WebExtensionCommand.Identity, in context: WKWebExtensionContext) {
        guard identity.context == self.identity(of: context),
              let command = context.commands.first(where: { $0.id == identity.command }) else { return }
        context.performCommand(command)
    }
}
#endif
