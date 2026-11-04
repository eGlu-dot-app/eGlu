import AppKit
import PadCore
import SwiftUI

/// The menu bar: every command with its keys, as Safari and Arc have them.
/// A page hears each ⌘ key first, as in Safari; what it leaves comes here.
struct BrowserCommands: Commands {
    @FocusedObject private var window: WindowModel?
    @ObservedObject private var session = Session.shared
    @ObservedObject private var extensions = Extensions.shared
    @ObservedObject private var extensionKeys = ExtensionKeys.shared
    /// The little window with the keys, if one has them: ⌃⌥O, ⌘W, ⌘L, ⌘R, ⌘[,
    /// ⌘] and ⇧⌘C are its, as they are a browser window's (LittleWindow.swift).
    @ObservedObject private var littleWindows = LittleWindows.shared

    var body: some Commands {
        groups
        menus
    }

    /// SwiftUI builds a Commands body of ten at most: the groups and the
    /// menus, each within it.
    @CommandsBuilder private var groups: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { window?.perform(.newTab) }
                .keyboardShortcut("t")
            Button("New Window") { open(space: window?.spaceID) }
                .keyboardShortcut("n")
            // On ⌃⌥, the browser's own keys, which pages leave alone, as on the iPad.
            Button("New Little Window") { LittleWindow.open(nil, in: window?.spaceID) }
                .keyboardShortcut("n", modifiers: [.control, .option])
            Button("New Space") { window?.newSpace() }
            Divider()
            Button("Open Location…") {
                if let little = littleWindows.key { little.startTyping() } else { window?.commandBar = .here }
            }
            .keyboardShortcut("l")
            // A Peek's page, or a little window's, in a tab of its own (Arc's ⌘O),
            // on ⌃⌥ so a web app's own ⌘O stays the page's.
            Button("Open in New Tab") {
                if let little = littleWindows.key { little.openInTab() } else { window?.openPeekInTab() }
            }
            .keyboardShortcut("o", modifiers: [.control, .option])
            .disabled(littleWindows.key == nil && window?.peek == nil)
            Button("Reopen Closed Tab") { window?.reopenTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(session.workspace.closed.isEmpty)
        }
        BrowserCloseCommands()
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Bookmarks…") {
                guard let window, let owner = window.window else { return }
                session.chooseBookmarksFile(into: window.spaceID, in: owner)
            }
            .disabled(window?.window == nil || !session.canUseWorkspace)
            Divider()
            Button("Share…") { window?.pageActionsShown = true }
                .disabled(window?.url == nil)
            if session.preferences.handoff, session.hasIntelligence {
                Button("Handoff…") { window?.startHandoff() }
                    .disabled(window?.canHandoff != true)
                // On ⌃⌥, eGlu's own keys, as on the iPad (Shortcuts.chords); there on a new tab or a sign-in page too, a file being no page.
                Button("Handoff File…") { window?.startHandoffChoosing() }
                    .keyboardShortcut("h", modifiers: [.control, .option, .shift])
                    .disabled(window?.canHandoffFiles != true)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { window?.page?.print() }
                .keyboardShortcut("p")
                .disabled(window?.page == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Link") {
                if let little = littleWindows.key {
                    little.copyLink()
                } else if let peek = window?.peek {
                    if let link = peek.address { window?.copyAddress(link) }
                } else {
                    window?.copyLink()
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(littleWindows.key?.url == nil && window?.peek == nil && window?.url == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find on Page…") { window?.startFinding() }
                .keyboardShortcut("f")
                .disabled(window?.page == nil)
            Button("Find Next") { window?.find() }
                .keyboardShortcut("g")
                .disabled(window?.findText.isEmpty ?? true)
            Button("Find Previous") { window?.find(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(window?.findText.isEmpty ?? true)
            // Edit › Spelling and Grammar, with grammar checking's switch and
            // Accept Writing Suggestion, comes after these: AppKit's (WritingMenu).
        }
        CommandGroup(replacing: .sidebar) {
            Button(window?.sidebarShown == false ? String(localized: "Keep Sidebar Open") : String(localized: "Hide Sidebar")) { window?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(window?.tabsInSidebar == false)
            Button(session.preferences.tabsPlacement == .top ? String(localized: "Show Tabs in Sidebar") : String(localized: "Show Tabs Along the Top")) {
                session.preferences.tabsPlacement = session.preferences.tabsPlacement == .top ? .sidebar : .top
            }
            // The bar is under the tabs along the top; the sidebar has its own Bookmarks section.
            Button(session.preferences.bookmarksBar ? String(localized: "Hide Bookmarks Bar") : String(localized: "Show Bookmarks Bar")) {
                withAnimation(.bar) { session.preferences.bookmarksBar.toggle() }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(window?.tabsInSidebar != false)
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page") {
                if let little = littleWindows.key {
                    little.reload()
                } else if let peek = window?.peek {
                    peek.reload()
                } else {
                    window?.reload()
                }
            }
            .keyboardShortcut("r")
            Button("Stop Loading") { window?.stop() }
                .keyboardShortcut(".")
                .disabled(window?.loading != true)
            if window?.page?.hasPendingDialog == true {
                Button("Review Page Dialog…") { window?.page?.reviewPendingDialog() }
            }
            if window?.page?.refusedAppLink != nil {
                Button("Review External App Request…") { window?.page?.reviewExternalRequest() }
            }
            Divider()
            Button("Actual Size") { window?.zoom(by: 0) }
                .keyboardShortcut("0")
            // ⌘= is the key under +, as every browser takes it.
            Button("Zoom In") { window?.zoom(by: 1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { window?.zoom(by: -1) }
                .keyboardShortcut("-")
            Divider()
            Button(window?.blocksContentHere == false ? String(localized: "Block Ads on This Site") : String(localized: "Allow Ads on This Site")) {
                window?.toggleBlocking()
            }
            .disabled(window?.url?.host == nil || !session.preferences.blocksContent)
            Divider()
        }
    }

    @CommandsBuilder private var menus: some Commands {
        CommandMenu("History") {
            // A little window's page with the keys, or a Peek's while it is up:
            // the tab under a Peek is out of reach until it goes.
            Button("Back") {
                if let little = littleWindows.key {
                    little.back()
                } else if let peek = window?.peek {
                    peek.back()
                } else {
                    window?.back()
                }
            }
            .keyboardShortcut("[")
            .disabled(littleWindows.key == nil && window?.peek == nil && window?.canGoBack != true)
            Button("Forward") {
                if let little = littleWindows.key {
                    little.forward()
                } else if let peek = window?.peek {
                    peek.forward()
                } else {
                    window?.forward()
                }
            }
            .keyboardShortcut("]")
            .disabled(littleWindows.key == nil && window?.peek == nil && window?.canGoForward != true)
            Divider()
            Button("Show All History") { window?.historyShown = true }
                .keyboardShortcut("y")
                .disabled(window == nil)
            Button("Clear History…") { window?.historyClearing = true }
                .disabled(window == nil)
        }
        CommandMenu("Tabs") {
            Button("Show Next Tab") { window?.selectTab(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { window?.selectTab(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab") { window?.selectTab(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Tab") { window?.selectTab(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button(window?.tab?.isPinned == true ? String(localized: "Unpin Tab") : String(localized: "Pin Tab")) { window?.togglePin() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(window?.tab?.url == nil)
            Button(window?.isBookmarked == true ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page")) { window?.toggleBookmark() }
                .keyboardShortcut("d")
                .disabled(window?.url == nil)
            Button("Duplicate Tab") { window?.duplicate() }
                .disabled(window?.tab?.url == nil)
            Divider()
            // Split View: the tab on screen and another, side by side.
            Button(window?.split == nil ? String(localized: "Split with New Tab") : String(localized: "Separate Tabs")) { window?.perform(.splitTab) }
                .keyboardShortcut("\\", modifiers: [.command, .option])
                .disabled(window?.tab == nil || window?.tab?.isPinned == true)
            Button("Swap Sides") { window?.swapSides() }
                .disabled(window?.split == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? String(localized: "Last Tab") : String(localized: "Tab \(number)")) { window?.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
        CommandMenu("Spaces") {
            Button("Next Space") { window?.showSpace(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Space") { window?.showSpace(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            ForEach(Array(session.workspace.spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                Button {
                    window?.showSpace(space.id)
                } label: {
                    Label(space.name, systemImage: space.symbol)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            Divider()
            Button("Space Settings…") { window?.spacesPanel = .list }
            Button("New Space") { window?.newSpace() }
        }
        CommandMenu("Developer") {
            // The keys Settings picked (Preferences.developerKeys): eGlu's
            // own ⌃⌥, or Chrome's ⌥⌘, which then takes them from pages.
            let modifiers: EventModifiers = session.preferences.developerKeys == .optionCommand
                ? [.option, .command] : [.control, .option]
            // A little window's page while it has the keys, else the
            // window's (a Peek's while one is up), as Reload Page has it.
            let none = littleWindows.key == nil && window?.toolsPage == nil
            Button("Show Web Inspector") { tool(.inspector) }
                .keyboardShortcut("i", modifiers: modifiers)
                .disabled(none)
            Button("Show JavaScript Console") { tool(.console) }
                .keyboardShortcut("j", modifiers: modifiers)
                .disabled(none)
            Button("Select an Element") { tool(.selectElement) }
                .keyboardShortcut("c", modifiers: modifiers)
                .disabled(none)
            Button("Take a Picture of an Element") { tool(.elementPicture) }
                .keyboardShortcut("e", modifiers: modifiers)
                .disabled(none)
            Divider()
            Button("Reload from Origin") { tool(.reloadOrigin) }
                // Chrome's ⌥⌘R for a hard reload, ⌃⌥⇧R beside the rest of
                // eGlu's own keys.
                .keyboardShortcut("r", modifiers: session.preferences.developerKeys == .optionCommand
                                  ? [.option, .command] : [.control, .option, .shift])
                .disabled(none)
            Divider()
            // ⌃⌥M stays on ⌃⌥ where developerKeys moves the rest to ⌥⌘:
            // ⌥⌘M is macOS's own "minimize windows" key.
            Button(window?.title(for: .measure) ?? Command.measure.title) { window?.perform(.measure) }
            .keyboardShortcut("m", modifiers: [.control, .option])
            .disabled(window?.page == nil)
            Divider()
            Button(window?.developerModeHere == true
                   ? String(localized: "Turn Developer Mode Off for This Site")
                   : String(localized: "Turn Developer Mode On for This Site")) {
                window?.toggleDeveloperMode()
            }
            .keyboardShortcut("v", modifiers: [.control, .option, .shift])
            .disabled(window?.url?.host == nil)
        }
        CommandMenu("Extensions") {
            // This space's extensions, each with what the checks after its
            // install found (Docs/ExtensionsDesign.md, section 4).
            ForEach(extensions.installed) { item in
                if let window {
                    let on = item.spaces.contains(window.spaceID)
                    Menu(item.name) {
                        if on {
                            Button("Use \u{201C}\(item.name)\u{201D}") { extensions.run(item.id, in: window) }
                                .disabled(extensions.unavailableReason(item.id, in: window) != nil)
                            if let reason = extensions.unavailableReason(item.id, in: window) { Text(reason) }
                            if let verdict = extensions.verdicts[window.spaceID]?[item.id] {
                                Section(verdict.title) {
                                    ForEach(verdict.lines, id: \.self) { Text($0) }
                                }
                            }
                            Divider()
                            Button("Turn Off in This Space") { extensions.turn(item.id, on: false, in: window.spaceID) }
                            // Its data in this space goes too; turning it off keeps it.
                            Button("Remove Data from This Space…") { extensions.confirmRemoval(of: item.id, from: window.spaceID, in: window) }
                        } else {
                            Button("Turn On in This Space") { extensions.turn(item.id, on: true, in: window.spaceID) }
                                .disabled(extensions.isIncompatible(item.id))
                        }
                        if item.source == .unpacked {
                            Button("Reload") { extensions.reload(item.id) }
                        }
                        Button("Remove from eGlu…") { extensions.confirmRemoval(of: item.id, in: window) }
                    }
                }
            }
            if !extensions.installed.isEmpty { Divider() }
            Button("Add This Extension") {
                if let url = window?.url { extensions.add(fromStorePage: url, in: window) }
            }
            .disabled(window?.url.flatMap(ExtensionStore.id(ofPage:)) == nil)
            Button("Chrome Web Store") { window?.open(URL(string: "https://chromewebstore.google.com/category/extensions")!, newTab: true) }
            Button("Install from File\u{2026}") { extensions.addFromFile(in: window) }
            Button("Load Unpacked\u{2026}") { extensions.loadUnpacked(in: window) }
            // Their commands, by name; no keys unless the person gives them
            // (Settings › Extensions, ExtensionKeys), since ⌘ shortcuts
            // belong to the page. A key given is its line's.
            if let window {
                ForEach(extensions.commands(in: window.spaceID), id: \.id) { entry in
                    Section(entry.name) {
                        ForEach(entry.commands, id: \.id) { command in
                            Button(command.title) { extensions.perform(command, of: entry.id, in: window.spaceID) }
                                .keyboardShortcut(extensionKeys.given[ExtensionKeys.name(entry.id, command.id)].flatMap(ExtensionKeys.shortcut))
                        }
                    }
                }
            }
            Divider()
            Button("Check for Extension Updates…") {
                let host = NSApp.keyWindow
                Task {
                    let report = await extensions.checkForUpdates(now: true, host: host)
                    let alert = NSAlert()
                    alert.messageText = report.summary
                    alert.informativeText = report.entries.compactMap { entry in entry.detail.map { String(localized: "\(entry.name): \($0)") } }.joined(separator: "\n\n")
                    alert.addButton(withTitle: String(localized: "Done"))
                    _ = await extensions.present(alert, in: window, host: host)
                }
            }
                .disabled(!extensions.installed.contains { $0.source == .store })
        }
        CommandGroup(after: .appSettings) {
            Button("Make eGlu the Default Browser…") { DefaultBrowser.ask() }
                .disabled(DefaultBrowser.isDefault)
        }
    }

    private func open(space: UUID?) {
        session.openWindow?(space)
    }

    /// A developer tool, on a little window's page while it has the keys
    /// (with no toast there, an inspector out of reach is a beep), else on
    /// the window's.
    private func tool(_ command: Command) {
        guard let little = littleWindows.key else {
            window?.perform(command)
            return
        }
        let view = little.page.view
        switch command {
        case .inspector: if !WebInspector.show(.inspector, for: view) { NSSound.beep() }
        case .console: if !WebInspector.show(.console, for: view) { NSSound.beep() }
        case .selectElement: if !WebInspector.show(.elements, for: view) { NSSound.beep() }
        case .reloadOrigin: little.page.reloadFromOrigin()
        // On the clipboard, with no toast to offer Save in a little window.
        case .elementPicture: Task { _ = await WindowModel.copyElementPicture(of: little.page) }
        default: break
        }
    }
}

/// eGlu as the browser that opens links from other apps: macOS asks the
/// person first, in a dialog of its own.
enum DefaultBrowser {
    static var isDefault: Bool {
        guard let probe = URL(string: "https://example.com"),
              let browser = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return browser.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func ask() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
    }
}
