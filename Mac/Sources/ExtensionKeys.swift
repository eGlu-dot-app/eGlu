import AppKit
import PadCore
import SwiftUI
import WebKit
import WebKitExtensions

/// The keys the person gave extensions' commands in Settings › Extensions,
/// by extension and command, the same in every space; and what each
/// manifest suggests, offered there. WebKit takes a manifest's suggestion
/// as the command's key; eGlu clears it as the extension loads, so a
/// command has a key only once the person gives it one, and the extension
/// reads none before (commands.getAll), since ⌘ keys belong to the page.
/// A key given is the command's line's in the Extensions menu, so the menu
/// bar carries it out. (Search's 9bd1966, 5970529, 6da963a)
@MainActor
final class ExtensionKeys: ObservableObject {
    static let shared = ExtensionKeys()
    static let defaultsKey = "extensionCommandKeys"

    @Published private(set) var given: [String: ExtensionKey]
    /// What each manifest suggests, as WebKit read it at load.
    @Published private(set) var suggested: [String: ExtensionKey] = [:]
    /// The command whose recorder is waiting for a key: one at a time, as
    /// each takes every key typed in eGlu while it waits.
    @Published var recording: String?

    private init() {
        let kept = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        given = kept.compactMapValues(ExtensionKey.init(stored:))
    }

    static func name(_ id: String, _ command: String) -> String {
        "\(id)/\(command)"
    }

    /// At load: WebKit's command gets the person's key, or none. What the
    /// manifest suggests is read from the manifest, never from the command,
    /// whose key eGlu changes.
    func apply(to context: WKWebExtensionContext) {
        WebKitExtensionKeys.apply(to: context, given: { given[$0] }) { name, suggestion in
            if suggested[name] != suggestion { suggested[name] = suggestion }
        }
    }

    /// Gives `key` to a command, or takes its key back (nil); in every space
    /// it is loaded in. A command that had the key gives it up there too.
    func set(_ key: ExtensionKey?, for id: String, command: String) {
        let name = Self.name(id, command)
        given[name] = key
        var touched: Set<String> = [id]
        if let key {
            for (other, held) in given where other != name && held == key {
                given[other] = nil
                if let owner = other.split(separator: "/").first { touched.insert(String(owner)) }
            }
        }
        UserDefaults.standard.set(given.mapValues(\.stored), forKey: Self.defaultsKey)
        for owner in touched {
            for context in Extensions.shared.contexts.values.compactMap({ $0[owner] }) { apply(to: context) }
        }
    }

    /// An installed extension's commands as its manifest declares them, for
    /// Settings while it is loaded in no space; read once for each version.
    private var declared: [String: [ExtensionManifest.Command]] = [:]

    func declaredCommands(of item: Extensions.Installed) -> [ExtensionManifest.Command] {
        // The package's date too: an unpacked one reloaded keeps its version.
        let package = Extensions.package(item.id, item.version)
        let made = (try? package.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = item.id + "@" + item.version + "@\(made)"
        if let known = declared[key] { return known }
        let archive = (try? Data(contentsOf: package)) ?? Data()
        let commands = ZipFile.file(in: archive, matching: { $0 == "manifest.json" })
            .map { ExtensionManifest.commands(json: $0, in: archive, untitled: item.name) } ?? []
        declared[key] = commands
        for command in commands { declaredSuggestions[Self.name(item.id, command.id)] = command.suggested }
        return commands
    }

    /// Read while Settings draws, so not published.
    private var declaredSuggestions: [String: ExtensionKey] = [:]

    /// What a command's manifest suggests: as loaded, while the extension is
    /// loaded somewhere; otherwise as its installed package declares it,
    /// which an update may have changed since it was last loaded.
    func suggestion(_ name: String) -> ExtensionKey? {
        let id = String(name.prefix { $0 != "/" })
        return Extensions.shared.contexts.values.contains { $0[id] != nil } ? suggested[name] : declaredSuggestions[name]
    }

    /// An extension's keys, as it goes from eGlu.
    func forget(_ id: String) {
        given = given.filter { !$0.key.hasPrefix(id + "/") }
        UserDefaults.standard.set(given.mapValues(\.stored), forKey: Self.defaultsKey)
    }

    /// Why `key` can't be this command's, or nil when it can: the Mac's or
    /// eGlu's own, or one of eGlu's menu commands as the menus stand now.
    /// Another extension's command may give its key up (`holder`).
    func refusal(of key: ExtensionKey) -> String? {
        if key.isReserved { return String(localized: "\(key.shown) is eGlu's own.") }
        let extensionKeys = Set(given.values)
        for item in Self.menuItems(NSApp.mainMenu) {
            guard let held = Self.key(of: item), held == key, !extensionKeys.contains(held) else { continue }
            return String(localized: "\(key.shown) is eGlu's \u{201C}\(item.title)\u{201D}.")
        }
        return nil
    }

    /// The extension command that has `key` now, other than `name`.
    func holder(of key: ExtensionKey, besides name: String) -> String? {
        given.first { $0.key != name && $0.value == key }?.key
    }

    private static func menuItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + menuItems($0.submenu) }
    }

    /// A menu item's key, as an extension's would be.
    private static func key(of item: NSMenuItem) -> ExtensionKey? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var modifiers = modifiers(item.keyEquivalentModifierMask)
        let character = item.keyEquivalent
        if character != character.lowercased() { modifiers.insert(.shift) }
        return ExtensionKey(key: character, modifiers: modifiers)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ExtensionKey.Modifiers {
        WebKitExtensionKeys.modifiers(flags)
    }

    static func flags(_ modifiers: ExtensionKey.Modifiers) -> NSEvent.ModifierFlags {
        WebKitExtensionKeys.flags(modifiers)
    }

    /// The menu line's key, for a command that has one.
    static func shortcut(_ key: ExtensionKey) -> KeyboardShortcut? {
        guard let character = key.key.first else { return nil }
        var modifiers: EventModifiers = []
        if key.modifiers.contains(.command) { modifiers.insert(.command) }
        if key.modifiers.contains(.option) { modifiers.insert(.option) }
        if key.modifiers.contains(.control) { modifiers.insert(.control) }
        if key.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

/// One command's key in Settings › Extensions: shown, and recorded from
/// the next key typed after a click (Esc stops, Delete takes it away),
/// with the manifest's suggestion offered.
struct ExtensionKeyRecorder: View {
    let id: String
    let command: String
    let title: String
    @ObservedObject private var keys = ExtensionKeys.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?
    /// A key another extension's command has, waiting for "Use It Here".
    @State private var taking: ExtensionKey?

    private var name: String { ExtensionKeys.name(id, command) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack {
                    Button(recording ? String(localized: "Type a Shortcut") : keys.given[name]?.shown ?? String(localized: "None")) {
                        recording ? stop() : start()
                    }
                    .accessibilityLabel(String(localized: "Shortcut for \(title)"))
                    if keys.given[name] != nil, !recording {
                        Button("Clear") { keys.set(nil, for: id, command: command) }
                    }
                }
            }
            if let suggestion = keys.suggestion(name), keys.given[name] != suggestion, !recording {
                Button("Use Its Suggestion, \(suggestion.shown)") { take(suggestion) }
                    .buttonStyle(.link)
            }
            if let problem {
                Text(problem).foregroundStyle(.secondary).font(.callout)
            }
            if let taking {
                Button("Use \(taking.shown) Here") {
                    keys.set(taking, for: id, command: command)
                    self.taking = nil
                    problem = nil
                }
            }
        }
        .onDisappear(perform: stop)
        // Another recorder started: this one stops waiting.
        .onChange(of: keys.recording) { _, now in
            if recording, now != name { stop() }
        }
    }

    private func start() {
        problem = nil
        taking = nil
        recording = true
        keys.recording = name
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch event.keyCode {
                case 53: stop()
                case 51, 117:
                    keys.set(nil, for: id, command: command)
                    stop()
                default:
                    guard let typed = event.charactersIgnoringModifiers,
                          let key = ExtensionKey(key: typed, modifiers: ExtensionKeys.modifiers(event.modifierFlags)) else {
                        problem = String(localized: "A shortcut needs ⌘, ⌥ or ⌃, and a key that types a character.")
                        return
                    }
                    stop()
                    take(key)
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if keys.recording == name { keys.recording = nil }
    }

    private func take(_ key: ExtensionKey) {
        if let refused = keys.refusal(of: key) {
            problem = refused
            return
        }
        if let other = keys.holder(of: key, besides: name) {
            let owner = other.split(separator: "/").first.map(String.init) ?? ""
            let extensionName = Extensions.shared.installed.first { $0.id == owner }?.name ?? String(localized: "another extension")
            problem = String(localized: "\(key.shown) is \(extensionName)'s now.")
            taking = key
            return
        }
        problem = nil
        keys.set(key, for: id, command: command)
    }
}
