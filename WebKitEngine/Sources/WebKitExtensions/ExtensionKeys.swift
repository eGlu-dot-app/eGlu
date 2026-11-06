#if os(macOS)
import AppKit
import PadCore
import WebKit

/// WebKit's commands get the keys chosen by the app, at load and when changed.
@MainActor
public enum WebKitExtensionKeys {
    public static func apply(to context: WKWebExtensionContext, given: (String) -> ExtensionKey?,
                             suggest: (String, ExtensionKey?) -> Void) {
        let declared = context.webExtension.manifest["commands"] as? [String: Any] ?? [:]
        for command in context.commands {
            let name = "\(context.uniqueIdentifier)/\(command.id)"
            let suggestion = ExtensionKey(suggestedKey: (declared[command.id] as? [String: Any])?["suggested_key"])
            suggest(name, suggestion)
            if let key = given(name) {
                command.activationKey = key.key
                command.modifierFlags = Self.flags(key.modifiers)
            } else {
                command.activationKey = nil
                command.modifierFlags = []
            }
        }
    }

    public static func modifiers(_ flags: NSEvent.ModifierFlags) -> ExtensionKey.Modifiers {
        var out: ExtensionKey.Modifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.shift) { out.insert(.shift) }
        return out
    }

    public static func flags(_ modifiers: ExtensionKey.Modifiers) -> NSEvent.ModifierFlags {
        var out: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.option) { out.insert(.option) }
        if modifiers.contains(.control) { out.insert(.control) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        return out
    }

}
#endif
