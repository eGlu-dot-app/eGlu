import GameController
import PadCore
import UIKit

/// The app's menus, which are mostly an absence.
///
/// Every menu iPadOS puts in an app by itself (File, Edit, Format, View,
/// Window, Help, and the app menu's own items; the menu bar of iPadOS 26
/// shows them all) comes with shortcuts on ⌘: ⌘F, ⌘W, ⌘N, ⌘Z, ⌘B. A menu's
/// shortcut answers before the page hears the key, so Figma's ⌘Z, a page's
/// own ⌘F, a document's ⌘B would never reach the page. They are all taken
/// out, whichever of them this iPadOS has, and the browser's own commands
/// go in their place on ⌃⌥, which pages leave alone, but for the few keys
/// every browser keeps for itself, ⌘T and the like (Chord.Base). Two of iPadOS's stay,
/// without their ⌘ keys: the Window menu, which iPadOS shows in any case,
/// and the app menu's item that opens eGlu's page in the Settings app.
/// What this device and a window of it can do. An iPhone's window has one
/// pane and no tab bar; the iPhone Duo open and a large iPhone turned have
/// windows as wide as an iPad's (Docs/iPhoneDuoPlan.md, Phase 4).
@MainActor
enum Device {
    /// The iPhone idiom: the hardware. No trackpad, rarely a keyboard, an
    /// iPhone's user agent, touch first. The iPhone Duo and every iPhone
    /// say so, however wide a window of theirs is.
    static var phone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The iPhone Duo: the phone idiom with more than one window. Nothing
    /// else names it; its Settings have both layouts' parts (decision 5).
    static var isDuo: Bool {
        phone && UIApplication.shared.supportsMultipleScenes
    }

    /// Diagnostics, the panel over the page: in a build run from Xcode
    /// only. The App Store's and TestFlight's have no switch for it, no
    /// command and no keys, and never show it.
    static var diagnostics: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The keys a command has, to show beside it: none where none work. An
    /// iPad has them; a phone only while a keyboard with keys is attached.
    static func keys(for command: Command) -> String? {
        guard !phone || GCKeyboard.coalesced != nil else { return nil }
        return Menus.keyCaps(for: command)?.joined()
    }

    /// Whether a window offers the command. An iPad's as the iPad does. A
    /// phone's by its width (compact: the bar at the bottom): the iPhone Duo
    /// open and a large iPhone turned show the iPad's bars, and have what
    /// goes with them. Every list of commands asks here, so nothing is
    /// offered that does nothing.
    static func offers(_ command: Command, compact: Bool) -> Bool {
        switch command {
        case .newWindow, .closeWindow: return UIApplication.shared.supportsMultipleScenes
        case .tabBar, .focusPage, .splitTab, .siteMode: return phone ? !compact : true
        // No Web Inspector to open in an iOS app: those stay the Mac's.
        case .inspector, .console, .selectElement: return false
        // Developer mode is the Mac's and the iPad's: an iPhone has none of
        // it, no bar, no keys, no menu.
        case .reloadOrigin, .developerMode, .elementPicture: return !phone
        // Only where Settings has turned it on, and only with Apple Intelligence to ask.
        case .handoff, .handoffFile: return Session.shared.preferences.handoff && Session.shared.hasIntelligence
        case .diagnostics: return diagnostics
        // Only where Settings has turned checking on (Writing).
        case .acceptWritingSuggestion: return Session.shared.preferences.writing
        default: return true
        }
    }

    /// Whether this window offers the command: as offers(_:compact:) for
    /// its width, and New Window only where it can open one.
    static func offers(_ command: Command, in window: WindowModel) -> Bool {
        if command == .contentBlocking { return window.blocking != nil }
        if command == .linkMenu { return window.ownMenus != nil }
        // A command of the open card only (Decided 8).
        if command == .acceptWritingSuggestion {
            return window.writingCardOpen && offers(command, compact: window.phone)
        }
        return command == .newWindow ? window.makesWindows : offers(command, compact: window.phone)
    }

    /// Whether a window on this screen can open another. Not on an iPhone;
    /// on the iPhone Duo not on its outer display, which Apple keeps to one
    /// window (told by the screen: 466 points across, measured, where the
    /// inner display is wider both ways).
    static func makesWindows(on screen: CGSize) -> Bool {
        guard UIApplication.shared.supportsMultipleScenes else { return false }
        return !isDuo || min(screen.width, screen.height) > 500
    }

    /// Which layouts' parts Settings has for a window: an iPad's, the
    /// iPad's; the iPhone Duo's, both; another phone's, its window's.
    static func settingsLayouts(compact: Bool) -> (phone: Bool, pad: Bool) {
        if !phone { return (false, true) }
        if isDuo { return (true, true) }
        return (compact, !compact)
    }

    /// Whether Settings has that part for a window (settingsLayouts): App
    /// Icon only where the system lets an app change it, Handoff only where
    /// the device has Apple Intelligence, Diagnostics only in a build from Xcode.
    @MainActor static func offers(_ anchor: SettingsAnchor, compact: Bool) -> Bool {
        if anchor == .appIcon, !UIApplication.shared.supportsAlternateIcons { return false }
        if anchor == .handoff, !Session.shared.hasIntelligence { return false }
        if anchor == .diagnostics, !diagnostics { return false }
        // No developer mode on an iPhone (the Mac's and the iPad's).
        if anchor == .developer, phone { return false }
        let layouts = settingsLayouts(compact: compact)
        return anchor.isOffered(phoneLayout: layouts.phone, padLayout: layouts.pad)
    }

    /// "iPhone" or "iPad", for what the app says about this device.
    static var name: String {
        phone ? "iPhone" : "iPad"
    }
}

extension Command {
    /// An SF Symbol for the command, beside its name in the command bar.
    var symbol: String {
        switch self {
        case .everything: return "command"
        case .newTab: return "plus"
        case .closeTab: return "xmark"
        case .reopenTab: return "arrow.uturn.backward"
        case .address: return "link"
        case .reload: return "arrow.clockwise"
        case .stop: return "xmark.circle"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .nextTab: return "arrow.right.square"
        case .previousTab: return "arrow.left.square"
        case .nextSpace: return "arrow.down.square"
        case .previousSpace: return "arrow.up.square"
        case .newSpace: return "plus.square.on.square"
        case .newWindow: return "macwindow.badge.plus"
        case .closeWindow: return "xmark.rectangle"
        case .tabBar: return "menubar.rectangle"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gearshape"
        case .focusPage: return "keyboard"
        case .pinTab: return "pin"
        case .splitTab: return "rectangle.split.2x1"
        case .bookmark: return "star"
        case .bookmarkManager: return "book"
        case .share: return "square.and.arrow.up"
        case .copyLink: return "doc.on.doc"
        case .siteMode: return "desktopcomputer"
        case .spaceSettings: return "slider.horizontal.3"
        case .importBookmarks: return "square.and.arrow.down"
        case .contentBlocking: return "shield"
        case .linkMenu: return "contextualmenu.and.cursorarrow"
        case .find: return "text.magnifyingglass"
        // Passed on, as a message is forwarded: not the share sheet's own arrow, which sits beside it.
        case .handoff: return "arrowshape.turn.up.right"
        // A file going up and out, apart from the page's own arrow.
        case .handoffFile: return "arrow.up.doc"
        case .history: return "clock"
        case .acceptWritingSuggestion: return "character.cursor.ibeam"
        case .inspector: return "hammer"
        case .console: return "terminal"
        case .selectElement: return "cursorarrow.rays"
        case .elementPicture: return "camera.viewfinder"
        case .reloadOrigin: return "arrow.clockwise.circle"
        case .measure: return "ruler"
        case .developerMode: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

@MainActor
enum Menus {
    static let controlShortcutsKey = "browserControlShortcuts"
    static var controlShortcuts: Bool { UserDefaults.standard.bool(forKey: controlShortcutsKey) }

    static func keyCaps(for command: Command) -> [String]? {
        guard let chord = Shortcuts.chord(for: command) else { return nil }
        // The developer tools' keys as Settings picked: ⌥⌘, as Chrome has
        // them (Reload from Origin's ⇧ goes with the move, to ⌥⌘R).
        if Shortcuts.developer.contains(command),
           Session.shared.preferences.developerKeys == .optionCommand {
            return ["⌥", "⌘", chord.caps[chord.caps.count - 1]]
        }
        return controlShortcuts && chord.base == .controlOption ? chord.caps.filter { $0 != "⌥" } : chord.caps
    }
    /// Whether UIKit has asked for the main menu in this run: on iPad and
    /// Mac it does; on the iPhone idiom (the iPhone Duo too) it may not.
    private(set) static var built = false

    static func build(_ builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        built = true
        for child in builder.menu(for: .root)?.children ?? [] {
            // The app menu and the Window menu stay. iPadOS shows a Window
            // menu of its own whatever the app does (tiling, the open
            // windows), so the window's commands join it, not a second one.
            guard let menu = child as? UIMenu, menu.identifier != .application, menu.identifier != .window else { continue }
            builder.remove(menu: menu.identifier)
        }

        // The app menu: eGlu's settings, where an app's settings go, and
        // iPadOS's own item, which opens eGlu's page in the Settings app
        // (permissions, the default browser). iPadOS names that one
        // "eGlu Settings…" too; it is named for where it goes instead.
        builder.replaceChildren(ofMenu: .application) { children in
            let system = children.compactMap { $0 as? UIMenu }.filter { $0.identifier == .preferences }
                .flatMap(\.children).map(withoutCommandKeys)
            for case let command as UICommand in system { command.title = String(localized: "iPadOS Settings…") }
            let own = [keyCommand(.settings, title: String(localized: "Settings…"))].compactMap { $0 }
            return [UIMenu(title: "", identifier: Identifier.settings, options: .displayInline, children: own + system)]
        }

        // Each menu's commands are a group's (ShortcutGroup), the order the
        // command bar lists them in too.
        builder.insertSibling(menu(.go), afterMenu: .application)
        builder.insertSibling(tabsMenu(), afterMenu: Identifier.go)
        builder.insertSibling(menu(.spaces), afterMenu: Identifier.tabs)
        if !Device.phone { builder.insertSibling(menu(.developer), afterMenu: Identifier.spaces) }

        // Settings has its place in the app menu, above.
        let window = ShortcutGroup.window.commands.filter { $0 != .settings && Device.offers($0, compact: false) }
            .compactMap { keyCommand($0) }
        if let system = builder.menu(for: .window) {
            // Its own items keep their place, without ⌘ keys; the window's commands go first.
            builder.replace(menu: .window, with: system.replacingChildren(
                [UIMenu(title: "", identifier: Identifier.window, options: .displayInline, children: window)]
                    + system.children.map(withoutCommandKeys)
            ))
        } else {
            builder.insertSibling(UIMenu(title: String(localized: "Window"), identifier: Identifier.window, children: window),
                                  afterMenu: Identifier.spaces)
        }
    }

    /// A system item as it was, without its ⌘ shortcut: a shortcut on ⌘ answers
    /// before the page hears the key. The item still does what it did.
    private static func withoutCommandKeys(_ element: UIMenuElement) -> UIMenuElement {
        if let menu = element as? UIMenu {
            return menu.replacingChildren(menu.children.map(withoutCommandKeys))
        }
        guard let key = element as? UIKeyCommand, key.modifierFlags.contains(.command), let action = key.action else {
            return element
        }
        return UICommand(title: key.title, image: key.image, action: action, propertyList: key.propertyList,
                         alternates: key.alternates, discoverabilityTitle: key.discoverabilityTitle,
                         attributes: key.attributes, state: key.state)
    }

    enum Identifier {
        static let go = UIMenu.Identifier("eGlu.Go")
        static let tabs = UIMenu.Identifier("eGlu.Tabs")
        static let spaces = UIMenu.Identifier("eGlu.Spaces")
        static let developer = UIMenu.Identifier("eGlu.Developer")
        static let window = UIMenu.Identifier("eGlu.Window")
        static let settings = UIMenu.Identifier("eGlu.Settings")

        static func of(_ group: ShortcutGroup) -> UIMenu.Identifier {
            switch group {
            case .go: return go
            case .tabs: return tabs
            case .spaces: return spaces
            case .developer: return developer
            case .window: return window
            }
        }
    }

    /// Every command a window of this device can have: a window that can't
    /// hides it (Browser.validate).
    private static func menu(_ group: ShortcutGroup) -> UIMenu {
        UIMenu(title: group.title, identifier: Identifier.of(group),
               children: group.commands.filter { Device.offers($0, compact: false) }.compactMap { keyCommand($0) })
    }

    private static func tabsMenu() -> UIMenu {
        let main = ShortcutGroup.tabs.commands.compactMap { keyCommand($0) }
        return UIMenu(title: String(localized: "Tabs"), identifier: Identifier.tabs, children: main + [
            UIMenu(title: "", options: .displayInline, children: tabNumbers()),
        ])
    }

    /// Tab 1 to Tab 8, and the last tab.
    static func tabNumbers() -> [UIKeyCommand] {
        Shortcuts.tabNumbers.enumerated().map { index, chord -> UIKeyCommand in
            let title = index == 8 ? String(localized: "Last Tab") : String(localized: "Tab \(index + 1)")
            return UIKeyCommand(title: title, action: #selector(Browser.browserTab(_:)), input: input(chord.key),
                                modifierFlags: flags(chord), propertyList: index + 1)
        }
    }

    static func keyCommand(_ command: Command, title: String? = nil) -> UIKeyCommand? {
        guard let chord = Shortcuts.chord(for: command) else { return nil }
        return UIKeyCommand(title: title ?? command.title, action: #selector(Browser.browserCommand(_:)),
                            input: input(chord.key), modifierFlags: flags(chord, for: command), propertyList: command.rawValue)
    }

    private static func flags(_ chord: Chord, for command: Command? = nil) -> UIKeyModifierFlags {
        // The developer tools' keys, as Chrome has them, take ⌥⌘ over the
        // whole map below (Shortcuts.developer, Preferences.developerKeys).
        if let command, Shortcuts.developer.contains(command),
           Session.shared.preferences.developerKeys == .optionCommand {
            return [.alternate, .command]
        }
        var flags: UIKeyModifierFlags
        switch chord.base {
        case .controlOption: flags = controlShortcuts ? [.control] : [.control, .alternate]
        case .command: flags = .command
        case .control: flags = .control
        }
        if chord.shift { flags.insert(.shift) }
        return flags
    }

    private static func input(_ key: Key) -> String {
        switch key {
        case .character(let c): return c
        case .left: return UIKeyCommand.inputLeftArrow
        case .right: return UIKeyCommand.inputRightArrow
        case .up: return UIKeyCommand.inputUpArrow
        case .down: return UIKeyCommand.inputDownArrow
        case .escape: return UIKeyCommand.inputEscape
        case .tab: return "\t"
        }
    }
}
